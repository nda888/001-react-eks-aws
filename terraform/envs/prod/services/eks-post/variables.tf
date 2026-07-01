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

variable "cluster_autoscaler_service_account_name" {
  description = "Cluster Autoscaler ServiceAccount name"
  type        = string
  default     = "cluster-autoscaler-prod"
}
