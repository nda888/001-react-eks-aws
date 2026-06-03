variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name for subnet tagging"
  type        = string
  default     = "demo-eks-dev"
}

variable "vpc_id" {
  description = "Existing VPC ID for dev networking. Provide through local tfvars or CI variable."
  type        = string
  nullable    = false
}

variable "edge_public_subnet_azs" {
  description = "AZ allowlist for edge-facing ALB traffic"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
