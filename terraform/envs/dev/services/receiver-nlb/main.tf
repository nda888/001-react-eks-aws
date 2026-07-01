terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

data "terraform_remote_state" "prod_eks" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod/services/eks/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_instances" "eks_nodes" {
  filter {
    name   = "tag:kubernetes.io/cluster/${var.cluster_name}"
    values = ["owned"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

module "receiver" {
  source = "../../../../modules/receiver-nlb"

  name_prefix            = "nlb-dev"
  vpc_id                 = data.terraform_remote_state.networking.outputs.vpc_id
  subnet_ids             = var.nlb_subnet_ids
  instance_ids           = data.aws_instances.eks_nodes.ids
  prometheus_target_port = var.prometheus_nodeport
  loki_target_port       = var.loki_nodeport
}

resource "aws_security_group_rule" "nlb_prometheus_ingress_prod" {
  type                     = "ingress"
  security_group_id        = module.receiver.security_group_id
  protocol                 = "tcp"
  from_port                = 9090
  to_port                  = 9090
  source_security_group_id = data.terraform_remote_state.prod_eks.outputs.cluster_security_group_id
  description              = "Allow PROD Prometheus remote_write to NLB"
}

resource "aws_security_group_rule" "nlb_loki_ingress_prod" {
  type                     = "ingress"
  security_group_id        = module.receiver.security_group_id
  protocol                 = "tcp"
  from_port                = 3100
  to_port                  = 3100
  source_security_group_id = data.terraform_remote_state.prod_eks.outputs.cluster_security_group_id
  description              = "Allow PROD Alloy log push to Loki via NLB"
}

# --- Node SG ingress rules: allow NLB health checks + forwarded traffic to NodePorts ---
# The NLB targets worker nodes on NodePorts. Health checks come from NLB private IPs
# within the VPC; client traffic comes through the NLB with client IP preserved.
# Both paths need the node SG to allow these ports.

data "aws_vpc" "main" {
  id = data.terraform_remote_state.networking.outputs.vpc_id
}

resource "aws_security_group_rule" "node_sg_prometheus_nlb" {
  type              = "ingress"
  security_group_id = data.terraform_remote_state.eks.outputs.cluster_security_group_id
  protocol          = "tcp"
  from_port         = var.prometheus_nodeport
  to_port           = var.prometheus_nodeport
  cidr_blocks       = [data.aws_vpc.main.cidr_block]
  description       = "Allow NLB health check + remote_write to Prometheus NodePort"
}

resource "aws_security_group_rule" "node_sg_loki_nlb" {
  type              = "ingress"
  security_group_id = data.terraform_remote_state.eks.outputs.cluster_security_group_id
  protocol          = "tcp"
  from_port         = var.loki_nodeport
  to_port           = var.loki_nodeport
  cidr_blocks       = [data.aws_vpc.main.cidr_block]
  description       = "Allow NLB health check + log push to Loki NodePort"
}
