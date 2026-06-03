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

variable "app_domain_name" {
  description = "Public domain routed to the Kubernetes ALB Ingress"
  type        = string
  default     = "demo-react-eks.h0m3.xyz"
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for ALB HTTPS listener. Provide through local tfvars or CI variable."
  type        = string
  nullable    = false
}

variable "alb_frontend_sg_id" {
  description = "Existing frontend ALB security group ID (imported)"
  type        = string
  default     = ""
}

variable "alb_backend_sg_id" {
  description = "Existing backend ALB security group ID (imported)"
  type        = string
  default     = ""
}

variable "include_current_public_ip" {
  description = "Include Terraform runner public IP in public access allowlist."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Static CIDR blocks allowed to access public EKS API and public ALB endpoints."
  type        = list(string)
  default     = []
}

