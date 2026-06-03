variable "vpc_id" {
  description = "Existing VPC ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name for subnet tagging"
  type        = string
  default     = ""
}

variable "name" {
  description = "Name prefix for NAT GW and private subnets"
  type        = string
  default     = ""
}

variable "create_private_networking" {
  description = "Create private subnets, NAT GW, and route table"
  type        = bool
  default     = false
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (only used when create_private_networking = true)"
  type        = list(string)
  default     = []
}

variable "azs" {
  description = "Availability zones for private subnets (only used when create_private_networking = true)"
  type        = list(string)
  default     = []
}

variable "edge_public_subnet_azs" {
  description = "Optional AZ allowlist for edge-facing consumers (ALB). Empty means all public subnet AZs."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
