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

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "demo-eks-dev"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "namespace" {
  description = "Application namespace"
  type        = string
  default     = "dev"
}

variable "external_secrets_namespace" {
  description = "External Secrets Operator namespace"
  type        = string
  default     = "external-secrets"
}

variable "ssm_prefix" {
  description = "SSM parameter prefix for Mongo secrets"
  type        = string
  default     = "/demo-eks-dev/mongo"
}

variable "external_secrets_chart_version" {
  description = "External Secrets Operator Helm chart version"
  type        = string
  default     = "0.10.4"
}

variable "mongo_root_username" {
  description = "Initial MongoDB root username stored in SSM"
  type        = string
  default     = "admin"
}

variable "mongo_app_username" {
  description = "Initial MongoDB application username stored in SSM"
  type        = string
  default     = "app_user"
}

variable "mongo_database_name" {
  description = "MongoDB application database name"
  type        = string
  default     = "be_db"
}

variable "mongo_host" {
  description = "MongoDB in-cluster host and port used in app connection URI"
  type        = string
  default     = "mongo:27017"
}
