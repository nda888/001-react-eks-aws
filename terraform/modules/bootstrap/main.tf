terraform {
  required_version = ">= 1.10"
  # Uses LOCAL backend intentionally — this service creates the remote backend itself.
  # After applying, all envs/{env}/services/*/backend.tf reference the bucket created here.
  # State locking uses S3 native lockfile (use_lockfile = true) — no DynamoDB needed.
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

# --- S3 Bucket for Terraform Remote State ---
resource "aws_s3_bucket" "tfstate" {
  bucket        = var.state_bucket_name
  force_destroy = false
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 15
    }
  }
}

locals {
  common_tags = {
    Project   = var.app_name
    ManagedBy = "terraform"
    Service   = "bootstrap"
  }
}
