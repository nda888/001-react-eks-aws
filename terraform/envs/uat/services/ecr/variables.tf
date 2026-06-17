variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "backend_repository_name" {
  description = "ECR repository name for backend image"
  type        = string
  default     = "dev-demo-backend"
}

variable "frontend_repository_name" {
  description = "ECR repository name for frontend image"
  type        = string
  default     = "dev-demo-frontend"
}

variable "rotator_repository_name" {
  description = "ECR repository name for mongo rotator image"
  type        = string
  default     = "dev-mongo-rotator"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "image_retention_count" {
  description = "Number of images to keep in ECR"
  type        = number
  default     = 5
}

variable "force_delete" {
  description = "Allow repository deletion even when images still exist"
  type        = bool
  default     = false
}
