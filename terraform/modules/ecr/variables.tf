variable "repository_name" {
  description = "Name of the ECR repository"
  type        = string
}

variable "image_retention_count" {
  description = "Number of images to keep in ECR (older images are deleted automatically)"
  type        = number
  default     = 5
}

variable "force_delete" {
  description = "Allow repository deletion even when images still exist"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
