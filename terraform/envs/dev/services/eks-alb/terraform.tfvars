aws_region   = "us-east-1"
cluster_name = "eks-react-dev-uat"
environment  = "dev"
state_bucket = "demo-react-express-s3"

# Public access allowlist: runner IP only by default.
include_current_public_ip = true
public_access_cidrs       = []
