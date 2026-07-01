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
  default     = "eks-react-prod"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "node_instance_types" {
  description = "EC2 instance types for general worker nodes. Use ARM64 types because app images are built for linux/arm64. Multiple values improve Spot capacity availability."
  type        = list(string)
  default     = ["t4g.small"]
}

variable "capacity_type" {
  description = "Capacity type for worker nodes (ON_DEMAND or SPOT)"
  type        = string
  default     = "SPOT"
}

variable "node_volume_size" {
  description = "Root EBS volume size in GiB for EKS worker nodes"
  type        = number
  default     = 15
}

variable "node_desired_size" {
  description = "Desired number of worker nodes — matches k8s/deployment.yaml replicas"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "ebs_csi_addon_version" {
  description = "Version of the EBS CSI driver addon"
  type        = string
  default     = "v1.62.0-eksbuild.1"
}

variable "vpc_cni_addon_version" {
  description = "Version of the VPC CNI addon"
  type        = string
  default     = "v1.22.2-eksbuild.1"
}

variable "coredns_addon_version" {
  description = "Version of the CoreDNS addon"
  type        = string
  default     = "v1.14.3-eksbuild.3"
}

variable "kube_proxy_addon_version" {
  description = "Version of the kube-proxy addon"
  type        = string
  default     = "v1.36.0-eksbuild.9"
}

# --- Stateful workload node group (dedicated on-demand, specific AZ for EBS volume affinity) ---
variable "stateful_node_group_enabled" {
  description = "Whether to create a dedicated node group for stateful workloads"
  type        = bool
  default     = false
}

variable "stateful_subnet_ids" {
  description = "Subnet IDs for the stateful node group (must be in the same AZ as existing EBS PVs, e.g. us-east-1a)"
  type        = list(string)
  default     = []
}

variable "stateful_instance_type" {
  description = "EC2 instance type for stateful node group"
  type        = string
  default     = "t4g.small"
}

variable "stateful_capacity_type" {
  description = "Capacity type for stateful node group (ON_DEMAND recommended for stateful workloads)"
  type        = string
  default     = "ON_DEMAND"
}

variable "stateful_desired_size" {
  description = "Desired number of stateful worker nodes"
  type        = number
  default     = 1
}

variable "stateful_min_size" {
  description = "Minimum number of stateful worker nodes"
  type        = number
  default     = 1
}

variable "stateful_max_size" {
  description = "Maximum number of stateful worker nodes"
  type        = number
  default     = 1
}

# --- EKS public API endpoint CIDR allowlist controls ---
variable "include_current_public_ip" {
  description = "Whether to append Terraform runner public IP to EKS public API endpoint allowlist"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Static CIDR blocks allowed to access EKS public API endpoint"
  type        = list(string)
  default     = []
}
