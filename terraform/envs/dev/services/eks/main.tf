terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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

# --- EKS API endpoint public access CIDR allowlist ---
# Resolved by shared public-access-allowlist module (fails closed if empty).
module "public_access_allowlist" {
  source                    = "../../../../modules/public-access-allowlist"
  include_current_public_ip = var.include_current_public_ip
  public_access_cidrs       = var.public_access_cidrs
}

locals {
  edge_public_subnet_ids = try(
    data.terraform_remote_state.networking.outputs.edge_public_subnet_ids,
    data.terraform_remote_state.networking.outputs.public_subnet_ids
  )
  common_tags = {
    Project     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "eks"
  }
}

module "eks" {
  source = "../../../../modules/eks"

  cluster_name        = var.cluster_name
  aws_region          = var.aws_region
  kubernetes_version  = var.kubernetes_version
  vpc_id              = data.terraform_remote_state.networking.outputs.vpc_id
  public_subnet_ids   = local.edge_public_subnet_ids
  private_subnet_ids  = data.terraform_remote_state.networking.outputs.private_subnet_ids
  node_subnet_ids     = local.edge_public_subnet_ids
  node_instance_types = var.node_instance_types
  capacity_type       = var.capacity_type
  node_volume_size    = var.node_volume_size
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  ebs_csi_addon_version                = var.ebs_csi_addon_version
  vpc_cni_addon_version                = var.vpc_cni_addon_version
  coredns_addon_version                = var.coredns_addon_version
  kube_proxy_addon_version             = var.kube_proxy_addon_version
  cluster_endpoint_public_access_cidrs = module.public_access_allowlist.effective_public_access_cidrs
  tags                                 = local.common_tags

  # Stateful workload node group (on-demand, single-AZ for EBS volume affinity)
  stateful_node_group_enabled = var.stateful_node_group_enabled
  stateful_subnet_ids         = var.stateful_subnet_ids
  stateful_instance_type      = var.stateful_instance_type
  stateful_capacity_type      = var.stateful_capacity_type
  stateful_desired_size       = var.stateful_desired_size
  stateful_min_size           = var.stateful_min_size
  stateful_max_size           = var.stateful_max_size
}
