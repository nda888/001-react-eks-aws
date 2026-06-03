terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dev/services/networking/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dev/services/eks/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

data "aws_eks_cluster" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

# VPC CIDR used for ALB egress rules to pod targets
data "aws_vpc" "main" {
  id = data.terraform_remote_state.networking.outputs.vpc_id
}


provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

# --- Public access CIDR allowlist ---
# Shared module resolves effective CIDRs (fails closed if empty).
module "public_access_allowlist" {
  source                    = "../../../../modules/public-access-allowlist"
  include_current_public_ip = var.include_current_public_ip
  public_access_cidrs       = var.public_access_cidrs
}

locals {
  common_tags = {
    Project     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "eks-alb"
  }
}

module "alb_controller" {
  source                 = "../../../../modules/alb-controller"
  cluster_name           = data.terraform_remote_state.eks.outputs.cluster_name
  aws_region             = var.aws_region
  vpc_id                 = data.terraform_remote_state.networking.outputs.vpc_id
  oidc_provider_arn      = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url      = data.terraform_remote_state.eks.outputs.oidc_provider_url
  backend_security_group = aws_security_group.alb_backend.id
  tags                   = local.common_tags
}

resource "aws_security_group" "alb_frontend" {
  name        = "demo-eks-dev-alb-frontend"
  name_prefix = null
  description = "ALB frontend SG - internet-facing rules managed by AWS Load Balancer Controller"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  tags = merge(local.common_tags, {
    Name = "demo-eks-dev-alb-frontend"
  })

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_security_group" "alb_backend" {
  name        = "demo-eks-dev-alb-backend"
  name_prefix = null
  description = "ALB backend SG - worker-to-pod rules managed by AWS Load Balancer Controller"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  tags = merge(local.common_tags, {
    Name = "demo-eks-dev-alb-backend"
  })

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

# --- Custom SG rules for ALB listener ingress and target egress ---
# Terraform owns these rules (independent of `aws_security_group.alb_frontend` inline
# `ingress`/`egress` blocks). The controller manages backend rules on node SGs.

resource "aws_security_group_rule" "alb_frontend_http_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_frontend.id
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = module.public_access_allowlist.effective_public_access_cidrs
  description       = "Allow public HTTP to ALB for redirect to HTTPS"
}

resource "aws_security_group_rule" "alb_frontend_https_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.alb_frontend.id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = module.public_access_allowlist.effective_public_access_cidrs
  description       = "Allow public HTTPS to ALB"
}

resource "aws_security_group_rule" "alb_frontend_egress_app_targets" {
  type              = "egress"
  security_group_id = aws_security_group.alb_frontend.id
  protocol          = "tcp"
  from_port         = 3000
  to_port           = 3000
  cidr_blocks       = [data.aws_vpc.main.cidr_block]
  description       = "Allow ALB to reach frontend and backend pod targets on port 3000"
}

resource "aws_security_group_rule" "alb_frontend_egress_healthcheck" {
  type              = "egress"
  security_group_id = aws_security_group.alb_frontend.id
  protocol          = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_blocks       = [data.aws_vpc.main.cidr_block]
  description       = "Allow ALB to reach prometheus pod targets on port 8080 for health checks and traffic"
}

# --- Dev namespace (prerequisite for ConfigMap and kustomize resources) ---
resource "kubernetes_namespace" "dev" {
  metadata {
    name = "dev"
  }
}

# --- ConfigMap for Kustomize to inject SG IDs into Ingress annotations ---
resource "kubernetes_manifest" "alb_security_groups_configmap" {
  manifest = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "alb-security-groups"
      namespace = "dev"
    }
    data = {
      frontend_sg = aws_security_group.alb_frontend.id
      backend_sg  = aws_security_group.alb_backend.id
    }
  }

  depends_on = [kubernetes_namespace.dev]
}
