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
  default     = "eks-react-dev-uat"
}

variable "nlb_subnet_ids" {
  description = "3-AZ internal-elb tagged subnet IDs for NLB placement (plan-176 restricted)"
  type        = list(string)
}

variable "prometheus_nodeport" {
  description = "NodePort assigned to prometheus-receiver-nlb Service"
  type        = number
  default     = 30503
}

variable "loki_nodeport" {
  description = "NodePort assigned to loki-receiver-nlb Service"
  type        = number
  default     = 30471
}
