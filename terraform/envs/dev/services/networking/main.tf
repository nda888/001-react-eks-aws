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

module "networking" {
  source                 = "../../../../modules/networking"
  aws_region             = var.aws_region
  vpc_id                 = var.vpc_id
  cluster_name           = var.cluster_name
  edge_public_subnet_azs = var.edge_public_subnet_azs
}
