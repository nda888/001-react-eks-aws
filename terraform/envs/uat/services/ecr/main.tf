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

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "ecr"
  }
}

module "backend_ecr" {
  source                = "../../../../modules/ecr"
  repository_name       = var.backend_repository_name
  image_retention_count = var.image_retention_count
  force_delete          = var.force_delete
  tags                  = merge(local.common_tags, { Component = "backend" })
}

module "frontend_ecr" {
  source                = "../../../../modules/ecr"
  repository_name       = var.frontend_repository_name
  image_retention_count = var.image_retention_count
  force_delete          = var.force_delete
  tags                  = merge(local.common_tags, { Component = "frontend" })
}

module "rotator_ecr" {
  source                = "../../../../modules/ecr"
  repository_name       = var.rotator_repository_name
  image_retention_count = var.image_retention_count
  force_delete          = var.force_delete
  tags                  = merge(local.common_tags, { Component = "mongo-rotator" })
}
