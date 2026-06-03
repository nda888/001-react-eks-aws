variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC ID for EKS cluster security group"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (used in cluster vpc_config)"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for managed node group"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Optional explicit subnet IDs for managed node group. If empty, module falls back to private_subnet_ids then public_subnet_ids."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = "EC2 instance types for general worker nodes. Must remain ARM64 while AMI type is AL2023_ARM_64_STANDARD."
  type        = list(string)
  default     = ["t4g.small"]
}

variable "capacity_type" {
  description = "Capacity type for worker nodes (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_volume_size" {
  description = "Root EBS volume size in GiB for EKS worker nodes"
  type        = number
  default     = 15
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
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
  default     = "v1.39.0-eksbuild.1"
}

variable "vpc_cni_addon_version" {
  description = "Version of the VPC CNI addon"
  type        = string
  default     = "v1.19.2-eksbuild.1"
}

variable "coredns_addon_version" {
  description = "Version of the CoreDNS addon"
  type        = string
  default     = "v1.11.4-eksbuild.1"
}

variable "kube_proxy_addon_version" {
  description = "Version of the kube-proxy addon"
  type        = string
  default     = "v1.31.3-eksbuild.2"
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# --- Stateful workload node group (optional) ---
variable "stateful_node_group_enabled" {
  description = "Whether to create a dedicated node group for stateful workloads"
  type        = bool
  default     = false
}

variable "stateful_subnet_ids" {
  description = "Subnet IDs for the stateful node group (should target the EBS volume AZ, e.g. us-east-1a)"
  type        = list(string)
  default     = []
}

variable "stateful_instance_type" {
  description = "EC2 instance type for stateful node group"
  type        = string
  default     = "t4g.small"
}

variable "stateful_capacity_type" {
  description = "Capacity type for stateful node group (ON_DEMAND recommended)"
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

# --- EKS endpoint public access CIDR allowlist ---
variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to access EKS public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
