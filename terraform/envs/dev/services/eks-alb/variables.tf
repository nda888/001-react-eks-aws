variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = "S3 bucket name for Terraform remote state"
  type        = string
  default     = "demo-react-express-s3"
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
  description = "ACM certificate ARN used by the Kubernetes ALB Ingress"
  type        = string
  default     = "arn:aws:acm:us-east-1:654654604308:certificate/ed9119c0-c6a7-49ac-84cf-ded38b29491c"
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

