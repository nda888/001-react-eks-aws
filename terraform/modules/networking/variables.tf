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

variable "internal_elb_subnet_ids" {
  description = "Subnet IDs where the kubernetes.io/role/internal-elb tag is set. Restricts where the EKS in-tree LB provider places internal NLBs. The 3 chosen subnets host NLB nodes; the rest are untagged so the provider skips them. See plan-176."
  type        = list(string)
  default     = ["subnet-0d5b19984b533f703", "subnet-0ca21f0f484edd27d", "subnet-0fb4f83c51e6e3cc8"]
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
