variable "include_current_public_ip" {
  description = "Include Terraform runner public IP in public access allowlist."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Static CIDR blocks allowed to access public EKS API and public ALB endpoints."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.public_access_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "public_access_cidrs must contain valid CIDR blocks."
  }
}
