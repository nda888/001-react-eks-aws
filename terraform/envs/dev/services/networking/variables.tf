variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name for subnet tagging"
  type        = string
  default     = "eks-react-dev-uat"
}

variable "vpc_id" {
  description = "Existing VPC ID to use"
  type        = string
  default     = "vpc-01f1e8c8953103c93"
}

variable "edge_public_subnet_azs" {
  description = "AZ allowlist for edge-facing ALB traffic"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
