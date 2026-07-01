aws_region          = "us-east-1"
cluster_name        = "eks-react-dev-uat"
environment         = "dev"
kubernetes_version  = "1.36"
node_instance_types = ["t4g.small", "t4g.medium"]
capacity_type       = "SPOT"
node_volume_size    = 20
node_desired_size   = 5
node_min_size       = 5
node_max_size       = 7
state_bucket        = "demo-react-express-s3"

# Set true to append current Terraform runner public IP to EKS public API endpoint allowlist.
include_current_public_ip = true

# Optional static allowed CIDRs, such as office/VPN/static IPs.
# If both this list and include_current_public_ip are empty/disabled, the public-access-allowlist module fails closed.
public_access_cidrs = []

ebs_csi_addon_version    = "v1.62.0-eksbuild.1"
vpc_cni_addon_version    = "v1.22.2-eksbuild.1"
coredns_addon_version    = "v1.14.3-eksbuild.3"
kube_proxy_addon_version = "v1.36.0-eksbuild.9"

# Pin instance us-east-1a EBS & instance for mongodb
stateful_node_group_enabled = true
stateful_subnet_ids         = ["subnet-0d5b19984b533f703"]
stateful_instance_type      = "t4g.small"
stateful_capacity_type      = "ON_DEMAND"
stateful_desired_size       = 1
stateful_min_size           = 1
stateful_max_size           = 1
