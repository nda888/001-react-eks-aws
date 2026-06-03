variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = "Terraform remote state bucket. Provide through backend config or local tfvars."
  type        = string
  nullable    = false
}

variable "cluster_autoscaler_service_account_name" {
  description = "Cluster Autoscaler ServiceAccount name"
  type        = string
  default     = "cluster-autoscaler"
}
