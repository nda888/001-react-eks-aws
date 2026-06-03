terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dev/services/eks/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_eks_cluster" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

resource "kubernetes_service_account_v1" "cluster_autoscaler" {
  metadata {
    name      = var.cluster_autoscaler_service_account_name
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.eks.outputs.cluster_autoscaler_role_arn
    }

    labels = {
      "app.kubernetes.io/name"       = var.cluster_autoscaler_service_account_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
