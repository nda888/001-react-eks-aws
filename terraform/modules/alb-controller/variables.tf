variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — passed to the Helm chart so the controller knows which VPC to manage"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS cluster (for IRSA)"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL without https:// prefix"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

variable "backend_security_group" {
  description = "Security group ID for the ALB controller to use as the shared backend SG for managed backend rules"
  type        = string
  default     = null
}
