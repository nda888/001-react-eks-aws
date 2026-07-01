#!/usr/bin/env bash
set -uo pipefail
# -e not used to allow graceful handling of individual deletion failures

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

ALL_ENVS=("dev")
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_TAG="demo-react-express-mongodb"
NAME_TAG_PATTERNS="*eks-react*,*eks-eks*,*ekscluster*,*demoeks*,*demoreact*,*demo-eks*,*demo-react*,*alb-backend*,*alb-frontend*,*nlb-*"
GROUP_NAME_PATTERNS="*eks-react*,*eks-eks*,*ekscluster*,*demo-eks*,*demo-react*,*demoeks*,*demoreact*,*alb-backend*,*alb-frontend*,*nlb-*"
LOG_FILE="/tmp/check-exist-svc-$(date +%s).log"
EXIT_CODE=0
SERVICES_CHECKED=0
RESOURCES_FOUND=0
BUCKET_EXISTS=0
INSTANCES_FOUND=0
ELASTIC_IPS_FOUND=0
SNAPSHOTS_FOUND=0
VOLUMES_FOUND=0
ALBS_FOUND=0
EKS_CLUSTERS_FOUND=0
NAT_GATEWAYS_FOUND=0
TARGET_GROUPS_FOUND=0
ECR_REPOS_FOUND=0
SGS_FOUND=0
LTS_FOUND=0
IAM_ROLES_FOUND=0
VPCS_FOUND=0
SUBNETS_FOUND=0
IGWS_FOUND=0
PROTECTED_SGS=0
PROTECTED_VPCS=0
PROTECTED_SUBNETS=0
PROTECTED_IGWS=0

DELETE_MODE=0
AUTO_YES=0
DRY_RUN=0
TARGET="all"

usage() {
  cat <<USAGE
Usage: $0 [dev|all] [delete] [-y] [--dry-run]

Check Terraform service states, shared S3 backend bucket, EKS clusters, EC2 instances, Elastic IPs,
EBS volumes, EBS snapshots, and ALB/NLB load balancers for remaining resources.
Default: all

Commands:
  delete      Enable deletion mode (prompts for confirmation)

Options:
  -y          Auto-confirm deletion (requires delete)
  --dry-run   Show what would be deleted without executing

Environment:
  AWS_REGION       AWS region for S3/EC2/Elastic IP/EBS/ALB checks (default: us-east-1)

Exit codes:
  0  no service resources found and backend bucket absent
  1  warnings (skipped/unknown states or bucket check failed)
  2  resources found in service states, backend bucket, EKS clusters, EC2 instances, Elastic IPs,
     EBS volumes, EBS snapshots, or ALB/NLB load balancers
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      delete) DELETE_MODE=1; shift ;;
      -y) AUTO_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      dev|all) TARGET="$1"; shift ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

array_contains() {
  local needle="$1"
  shift
  for item; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

is_terraform_init_current() {
  local dir="$1"
  local init_state="$dir/.terraform/terraform.tfstate"
  local backend="$dir/backend.tf"
  [[ -f "$init_state" ]] || return 1
  [[ -f "$backend" ]] || return 0
  [[ "$init_state" -nt "$backend" ]] || return 1
}

get_services() {
  local env="$1"
  local root="envs/$env/services"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

get_assignment_value_from_file() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  awk -F'"' -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print $2
      exit
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Phase 1: Dynamic EKS cluster name discovery from Terraform tfvars
# ---------------------------------------------------------------------------

get_eks_cluster_names_from_tfvars() {
  local cluster_name
  cluster_name="$(get_assignment_value_from_file "envs/dev/services/eks/terraform.tfvars" "cluster_name" || true)"
  if [[ -n "$cluster_name" ]]; then
    printf '%s\n' "$cluster_name"
  else
    printf 'eks-react-dev-uat\n'
  fi
}

detect_backend_bucket_name() {
  get_assignment_value_from_file "modules/bootstrap/terraform.tfvars" "state_bucket_name"
}

format_count() {
  local count="$1"
  if [[ "$count" -eq 0 ]]; then
    printf "%b%s%b" "$GREEN" "$count" "$NC"
  else
    printf "%b%s%b" "$RED" "$count" "$NC"
  fi
}

format_protected_count() {
  local count="$1"
  if [[ "$count" -eq 0 ]]; then
    printf "%b%s%b" "$GREEN" "$count" "$NC"
  else
    printf "%b%s%b" "$YELLOW" "$count" "$NC"
  fi
}

# ---------------------------------------------------------------------------
# AWS credential validation
# ---------------------------------------------------------------------------

validate_aws_credentials() {
  if ! command -v aws >/dev/null 2>&1; then
    echo -e "${RED}ERROR:${NC} AWS CLI not installed"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}ERROR:${NC} jq not installed"
    exit 1
  fi
  if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
    echo -e "${RED}ERROR:${NC} AWS credentials not configured or expired"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Error logging helper
# ---------------------------------------------------------------------------

log_error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $*" >> "$LOG_FILE"
}

# Check if AWS resource is already absent (not found / already deleted)
is_resource_absent() {
  local error_text="$1"
  grep -qiE 'NotFound|NoSuch|does not exist|InvalidAllocationID|InvalidGroup\.NotFound|NoSuchBucket|InvalidVolume\.NotFound|InvalidSnapshot\.NotFound|ResourceNotFoundException' <<<"$error_text"
}

is_target_group_delete_retryable() {
  local error_text="$1"
  grep -qiE 'ResourceInUse|in use|dependency|currently associated|currently in use' <<<"$error_text"
}

first_error_line() {
  local error_text="$1"
  grep -m 1 -E '[^[:space:]]' <<<"$error_text" | sed 's/^[[:space:]]*//'
}

print_target_group_delete_failure() {
  local error_text="$1"
  local reason
  reason="$(first_error_line "$error_text")"
  if [[ -n "$reason" ]]; then
    echo -e "${RED}FAIL${NC} ($reason)"
  else
    echo -e "${RED}FAIL${NC}"
  fi
}

get_target_group_load_balancer_arns() {
  local arn="$1"
  aws elbv2 describe-target-groups --region "$AWS_REGION" \
    --target-group-arns "$arn" \
    --query 'TargetGroups[0].LoadBalancerArns' --output text 2>&1
}

wait_target_group_detached() {
  local arn="$1"
  local attempt refs

  for attempt in {1..6}; do
    refs="$(get_target_group_load_balancer_arns "$arn")"
    if is_resource_absent "$refs"; then
      return 0
    fi
    if [[ -z "$refs" || "$refs" == "None" ]]; then
      return 0
    fi
    [[ $attempt -lt 6 ]] && sleep 10
  done

  log_error "target group still reports load balancer refs before delete: $arn refs=$refs"
  return 1
}

# ELBv2 can release target group dependencies after the load balancer waiter completes.
delete_target_group_with_retry() {
  local arn="$1"
  local attempt err_file error_text

  for attempt in {1..6}; do
    err_file="$(mktemp)"
    if aws elbv2 delete-target-group --target-group-arn "$arn" --region "$AWS_REGION" 2>"$err_file"; then
      rm -f "$err_file"
      return 0
    fi

    error_text="$(cat "$err_file")"
    cat "$err_file" >> "$LOG_FILE"
    rm -f "$err_file"

    if is_resource_absent "$error_text"; then
      return 2
    fi
    if is_target_group_delete_retryable "$error_text" && [[ $attempt -lt 6 ]]; then
      sleep 10
      continue
    fi

    TARGET_GROUP_DELETE_LAST_ERROR="$error_text"
    return 1
  done
}

print_processed_summary() {
  echo "Processed:"
  echo "  Services checked: ${SERVICES_CHECKED}"
  echo -e "  State resources found(Terraform): $(format_count "$RESOURCES_FOUND")"
  echo -e "  Backend bucket exists(S3): $(format_count "$BUCKET_EXISTS")"
  echo -e "  EC2 instances exist: $(format_count "$INSTANCES_FOUND")"
  echo -e "  Elastic IPs exist: $(format_count "$ELASTIC_IPS_FOUND")"
  echo -e "  EBS volumes exist: $(format_count "$VOLUMES_FOUND")"
  echo -e "  EBS snapshot groups exist: $(format_count "$SNAPSHOTS_FOUND")"
  echo -e "  ALBs exist: $(format_count "$ALBS_FOUND")"
  echo -e "  EKS clusters exist: $(format_count "$EKS_CLUSTERS_FOUND")"
  echo -e "  NAT Gateways exist: $(format_count "$NAT_GATEWAYS_FOUND")"
  echo -e "  Target Groups exist: $(format_count "$TARGET_GROUPS_FOUND")"
  echo -e "  ECR Repos exist: $(format_count "$ECR_REPOS_FOUND")"
  echo -e "  Security Groups exist: $(format_count "$SGS_FOUND")"
  echo -e "  Launch Templates exist: $(format_count "$LTS_FOUND")"
  echo -e "  IAM Roles exist: $(format_count "$IAM_ROLES_FOUND")"
  echo -e "  VPCs exist: $(format_count "$VPCS_FOUND")"
  echo -e "  Subnets exist: $(format_count "$SUBNETS_FOUND")"
  echo -e "  Internet Gateways exist: $(format_count "$IGWS_FOUND")"
  echo -e "  Protected default Security Groups: $(format_protected_count "$PROTECTED_SGS")"
  echo -e "  Protected default VPCs: $(format_protected_count "$PROTECTED_VPCS")"
  echo -e "  Protected default Subnets: $(format_protected_count "$PROTECTED_SUBNETS")"
  echo -e "  Protected default Internet Gateways: $(format_protected_count "$PROTECTED_IGWS")"
}

check_service_state() {
  local env="$1" svc="$2"
  local dir="envs/$env/services/$svc"
  local resources=() init_log

  printf "Checking service %s/%s ... " "$env" "$svc"
  SERVICES_CHECKED=$((SERVICES_CHECKED + 1))

  [[ -d "$dir" ]] || { echo -e "${YELLOW}SKIP${NC} (missing)"; EXIT_CODE=1; return 0; }

  if ! is_terraform_init_current "$dir"; then
    init_log="$(mktemp)"
    terraform -chdir="$dir" init -input=false -no-color >"$init_log" 2>&1 || {
      echo -e "${YELLOW}SKIP${NC} (init failed)"; sed -n '1,4p' "$init_log"
      rm -f "$init_log"; EXIT_CODE=1; return 0
    }
    rm -f "$init_log"
  fi

  local output rc
  output="$(terraform -chdir="$dir" state list -no-color 2>&1)" && rc=0 || rc=$?

  if grep -qiE 'No state file|Backend initialization required|NoSuchBucket' <<<"$output"; then
    echo -e "${GREEN}OK${NC} (no state)"
    return 0
  fi

  if [[ $rc -ne 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (state list failed)"
    echo "$output" | sed -n '1,4p'
    EXIT_CODE=1
    return 0
  fi

  if [[ -z "$output" ]]; then
    echo -e "${GREEN}OK${NC} (no resources)"
    return 0
  fi

  while IFS= read -r line; do [[ -n "$line" ]] && resources+=("$line"); done <<<"$output"

  if [[ ${#resources[@]} -eq 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (unexpected output)"; echo "$output" | sed -n '1,4p'
    EXIT_CODE=1; return 0
  fi

  echo -e "${RED}FOUND${NC} (${#resources[@]} resources)"
  printf '  - %s\n' "${resources[@]}"
  RESOURCES_FOUND=$((RESOURCES_FOUND + ${#resources[@]}))
  EXIT_CODE=2
}

check_backend_bucket() {
  local bucket output rc

  bucket="$(detect_backend_bucket_name || true)"
  if [[ -z "$bucket" ]]; then
    echo -e "${YELLOW}SKIP${NC} backend bucket (bucket name not found)"
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  printf "Checking backend bucket %s ... " "$bucket"

  if ! command -v aws >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP${NC} (aws cli not found)"
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  output="$(aws s3api head-bucket --bucket "$bucket" 2>&1)" && rc=0 || rc=$?

  if [[ $rc -eq 0 ]]; then
    echo -e "${RED}FOUND${NC} (exists)"
    BUCKET_EXISTS=1
    EXIT_CODE=2
    return 0
  fi

  if grep -qiE 'Not Found|NoSuchBucket|404|does not exist' <<<"$output"; then
    echo -e "${GREEN}OK${NC} (absent)"
    return 0
  fi

  echo -e "${YELLOW}WARN${NC} (could not verify)"
  echo "$output" | sed -n '1,4p'
  [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
}

check_ec2_instances() {
  local instance_ids instance_count instance_table rc cluster_name node_group_name empty_node_names

  printf "Checking EC2 instances (region: %s) ... " "$AWS_REGION"

  if ! command -v aws >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP${NC} (aws cli not found)"
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  # Filter by project tag
  instance_ids="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (instance lookup failed)"
    echo "$instance_ids" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  if [[ -z "$instance_ids" || "$instance_ids" == "None" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  instance_count="$(wc -w <<<"$instance_ids" | tr -d ' ')"
  echo -e "${RED}FOUND${NC} (${instance_count} instances)"

  instance_table="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids $instance_ids \
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,Name:Tags[?Key==`Name`].Value|[0]}' \
    --output table 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "$instance_table" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  echo "$instance_table"

  cluster_name="$(get_assignment_value_from_file "envs/dev/services/eks/terraform.tfvars" "cluster_name" || true)"
  if [[ -n "$cluster_name" ]]; then
    node_group_name="${cluster_name}-nodes"
    empty_node_names="$(aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --filters "Name=tag:eks:nodegroup-name,Values=${node_group_name}" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[?!not_null(Tags[?Key==`Name`].Value|[0])].InstanceId' \
      --output text 2>&1)" && rc=0 || rc=$?

    if [[ $rc -ne 0 ]]; then
      echo -e "${YELLOW}WARN${NC} (EKS node Name tag check failed)"
      echo "$empty_node_names" | sed -n '1,4p'
      [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    elif [[ -n "$empty_node_names" && "$empty_node_names" != "None" ]]; then
      echo -e "${RED}FAIL${NC} EKS node instances missing Name tag: $empty_node_names"
      EXIT_CODE=2
    fi
  fi

  INSTANCES_FOUND=$instance_count
  EXIT_CODE=2
}

check_elastic_ips() {
  local allocation_ids address_count address_table rc

  printf "Checking Elastic IPs (region: %s) ... " "$AWS_REGION"

  if ! command -v aws >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP${NC} (aws cli not found)"
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  allocation_ids="$(aws ec2 describe-addresses \
    --region "$AWS_REGION" \
    --query 'Addresses[*].AllocationId' \
    --output text 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (Elastic IP lookup failed)"
    echo "$allocation_ids" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  if [[ -z "$allocation_ids" || "$allocation_ids" == "None" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  address_count="$(wc -w <<<"$allocation_ids" | tr -d ' ')"
  echo -e "${RED}FOUND${NC} (${address_count} addresses)"

  address_table="$(aws ec2 describe-addresses \
    --region "$AWS_REGION" \
    --allocation-ids $allocation_ids \
    --query 'Addresses[*].{AllocationId:AllocationId,PublicIp:PublicIp,AssociationId:AssociationId,InstanceId:InstanceId,Name:Tags[?Key==`Name`].Value|[0]}' \
    --output table 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "$address_table" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  echo "$address_table"
  ELASTIC_IPS_FOUND=$address_count
  EXIT_CODE=2
}

check_ebs_volumes() {
  local volume_ids volume_count volume_table rc

  printf "Checking EBS volumes (region: %s) ... " "$AWS_REGION"

  if ! command -v aws >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP${NC} (aws cli not found)"
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  volume_ids="$(aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=status,Values=creating,available,in-use,modifying,optimizing,error" \
    --query 'Volumes[*].VolumeId' \
    --output text 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (volume lookup failed)"
    echo "$volume_ids" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  if [[ -z "$volume_ids" || "$volume_ids" == "None" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  volume_count="$(wc -w <<<"$volume_ids" | tr -d ' ')"
  echo -e "${RED}FOUND${NC} (${volume_count} volumes)"

  volume_table="$(aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --volume-ids $volume_ids \
    --query 'Volumes[*].{VolumeId:VolumeId,State:State,AZ:AvailabilityZone,SizeGiB:Size,Type:VolumeType,Name:Tags[?Key==`Name`].Value|[0]}' \
    --output table 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "$volume_table" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  echo "$volume_table"
  VOLUMES_FOUND=$volume_count
  EXIT_CODE=2
}

check_ebs_snapshots() {
  local snapshot_output rc

  printf "Checking EBS snapshots (region: %s) ... " "$AWS_REGION"

  if ! command -v aws >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP${NC} (aws cli not found)"
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  snapshot_output="$(aws ec2 describe-snapshots \
    --region "$AWS_REGION" \
    --owner-ids self \
    --query 'Snapshots[*].{SnapshotId:SnapshotId,VolumeId:VolumeId,State:State,Started:StartTime,SizeGiB:VolumeSize,Description:Description}' \
    --output table 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (snapshot lookup failed)"
    echo "$snapshot_output" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  if grep -q 'SnapshotId' <<<"$snapshot_output"; then
    echo -e "${RED}FOUND${NC}"
    echo "$snapshot_output"
    SNAPSHOTS_FOUND=1
    EXIT_CODE=2
    return 0
  fi

  echo -e "${GREEN}OK${NC} (none)"
}

# ---------------------------------------------------------------------------
# ALB/NLB check function
# ---------------------------------------------------------------------------

check_load_balancers() {
  local lb_output rc

  printf "Checking Load Balancers (region: %s) ... " "$AWS_REGION"

  if ! command -v aws >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP${NC} (aws cli not found)"
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  lb_output="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query 'LoadBalancers[*].{Name:LoadBalancerName,Type:Type,DNSName:DNSName,State:State.Code}' \
    --output table 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (ALB lookup failed)"
    echo "$lb_output" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  if grep -q 'LoadBalancerName' <<<"$lb_output"; then
    echo -e "${RED}FOUND${NC}"
    echo "$lb_output"
    ALBS_FOUND=1
    EXIT_CODE=2
    return 0
  fi

  echo -e "${GREEN}OK${NC} (none)"
}

check_eks_clusters() {
  local cluster_names rc

  printf "Checking EKS clusters (region: %s) ... " "$AWS_REGION"

  cluster_names="$(aws eks list-clusters --region "$AWS_REGION" \
    --query 'clusters[]' --output text 2>&1)" && rc=0 || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo -e "${YELLOW}WARN${NC} (EKS lookup failed)"
    echo "$cluster_names" | sed -n '1,4p'
    [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
    return 0
  fi

  if [[ -z "$cluster_names" || "$cluster_names" == "None" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  local count=0
  local cluster
  for cluster in $cluster_names; do
    local cluster_info project_tag

    cluster_info="$(aws eks describe-cluster --name "$cluster" --region "$AWS_REGION" \
      --query '{Status:cluster.status,Version:cluster.version,VpcId:cluster.resourcesVpcConfig.vpcId,Project:cluster.tags.Project}' \
      --output json 2>/dev/null)" || continue

    project_tag="$(echo "$cluster_info" | jq -r '.Project // empty')"

    if [[ -n "$project_tag" && "$project_tag" != "null" && "$project_tag" != "$PROJECT_TAG" ]]; then
      continue
    fi
    if [[ -z "$project_tag" || "$project_tag" == "null" ]]; then
      if [[ ! "$cluster" =~ demo-eks && ! "$cluster" =~ demo-react ]]; then
        continue
      fi
    fi

    if [[ $count -eq 0 ]]; then
      echo -e "${RED}FOUND${NC}"
    fi

    local status version vpc_id
    status="$(echo "$cluster_info" | jq -r '.Status')"
    version="$(echo "$cluster_info" | jq -r '.Version')"
    vpc_id="$(echo "$cluster_info" | jq -r '.VpcId')"
    printf '  - %s (status=%s, version=%s, vpc=%s)\n' "$cluster" "$status" "$version" "$vpc_id"

    local ng_output
    ng_output="$(aws eks list-nodegroups --cluster-name "$cluster" --region "$AWS_REGION" \
      --query 'nodegroups[]' --output text 2>/dev/null)"
    if [[ -n "$ng_output" && "$ng_output" != "None" ]]; then
      printf '    nodegroups: %s\n' "$ng_output"
    fi

    local addon_output
    addon_output="$(aws eks list-addons --cluster-name "$cluster" --region "$AWS_REGION" \
      --query 'addons[]' --output text 2>/dev/null)"
    if [[ -n "$addon_output" && "$addon_output" != "None" ]]; then
      printf '    add-ons: %s\n' "$addon_output"
    fi

    local fp_output
    fp_output="$(aws eks list-fargate-profiles --cluster-name "$cluster" --region "$AWS_REGION" \
      --query 'fargateProfileNames[]' --output text 2>/dev/null)"
    if [[ -n "$fp_output" && "$fp_output" != "None" ]]; then
      printf '    fargate-profiles: %s\n' "$fp_output"
    fi

    count=$((count + 1))
  done

  EKS_CLUSTERS_FOUND=$count
  if [[ $count -gt 0 ]]; then
    EXIT_CODE=2
  else
    echo -e "${GREEN}OK${NC} (none)"
  fi
}

check_nat_gateways() {
  local nat_output rc
  printf "Checking NAT Gateways (region: %s) ... " "$AWS_REGION"

  nat_output="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'NatGateways[*].{NatGatewayId:NatGatewayId,State:State,VpcId:VpcId,SubnetId:SubnetId}' \
    --output table 2>&1)" && rc=0 || rc=$?
  [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (NAT lookup failed)"; return 0; }

  if ! grep -q 'NatGatewayId' <<<"$nat_output"; then
    nat_output="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
      --filter "Name=tag:Name,Values=*demo-react*,*demo-eks*" \
      --query 'NatGateways[*].{NatGatewayId:NatGatewayId,State:State,VpcId:VpcId,SubnetId:SubnetId,Name:Tags[?Key==`Name`].Value|[0]}' \
      --output table 2>&1)" && rc=0 || rc=$?
  fi

  if grep -q 'NatGatewayId' <<<"$nat_output"; then
    echo -e "${RED}FOUND${NC}"
    echo "$nat_output"
    NAT_GATEWAYS_FOUND=1
    EXIT_CODE=2
    return 0
  fi
  echo -e "${GREEN}OK${NC} (none)"
}

check_ecr_repos() {
  local repo_output rc
  printf "Checking ECR Repositories (region: %s) ... " "$AWS_REGION"
  repo_output="$(aws ecr describe-repositories --region "$AWS_REGION" \
    --query 'repositories[?contains(repositoryName, `demo-react`) || contains(repositoryName, `demo-express`)].{Name:repositoryName,URI:repositoryUri}' \
    --output table 2>&1)" && rc=0 || rc=$?
  [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (ECR lookup failed)"; return 0; }
  if grep -q '|' <<<"$repo_output"; then
    echo -e "${RED}FOUND${NC}"
    echo "$repo_output"
    ECR_REPOS_FOUND=1
    EXIT_CODE=2
    return 0
  fi
  echo -e "${GREEN}OK${NC} (none)"
}

# Collect ARNs of project-related target groups created by AWS Load Balancer Controller
# and NLB target groups provisioned by Terraform.
#   k8s-dev-*     (dev namespace services, ALB/NLB via Load Balancer Controller)
#   k8s-uat-*     (uat namespace services)
#   k8s-prod-*    (prod namespace services)
#   k8s-monitor-* (monitoring namespace services: grafana, prometheus, etc.)
#   nlb-dev-*     (NLB target groups provisioned by Terraform: loki, prometheus, etc.)
collect_target_group_arns() {
  aws elbv2 describe-target-groups --region "$AWS_REGION" \
    --query 'TargetGroups[?starts_with(TargetGroupName, `k8s-dev-`) || starts_with(TargetGroupName, `k8s-uat-`) || starts_with(TargetGroupName, `k8s-prod-`) || starts_with(TargetGroupName, `k8s-monitor-`) || starts_with(TargetGroupName, `nlb-dev-`)].TargetGroupArn' \
    --output text 2>/dev/null
}

check_target_groups() {
  local tg_output rc tg_arns tg_count
  printf "Checking Target Groups (region: %s) ... " "$AWS_REGION"
  # AWS Load Balancer Controller target group names encode the Kubernetes namespace.
  # Include k8s-dev-* (dev), k8s-uat-* (uat), k8s-prod-* (prod), k8s-monitor-* (monitoring services),
  # and nlb-dev-* (NLB target groups from Terraform: loki, prometheus, etc.)
  tg_arns="$(collect_target_group_arns || true)"
  if [[ -z "$tg_arns" || "$tg_arns" == "None" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi
  tg_count="$(wc -w <<<"$tg_arns" | tr -d ' ')"
  tg_output="$(aws elbv2 describe-target-groups --region "$AWS_REGION" \
    --target-group-arns $tg_arns \
    --query 'TargetGroups[*].{Name:TargetGroupName,Type:TargetType,VpcId:VpcId,Protocol:Protocol}' \
    --output table 2>&1)" && rc=0 || rc=$?
  [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (TG lookup failed)"; return 0; }
  echo -e "${RED}FOUND${NC} (${tg_count})"
  echo "$tg_output"
  TARGET_GROUPS_FOUND=$tg_count
  EXIT_CODE=2
}

check_vpcs() {
  local vpc_ids prot_vpc_ids vpc_count prot_count vpc_output prot_output rc
  printf "Checking VPCs (region: %s) ... " "$AWS_REGION"

  vpc_ids="$(collect_project_vpc_ids || true)"
  prot_vpc_ids="$(collect_protected_default_vpc_ids || true)"

  if [[ -z "$vpc_ids" && -z "$prot_vpc_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  if [[ -n "$vpc_ids" && "$vpc_ids" != "None" ]]; then
    vpc_output="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
      --vpc-ids $vpc_ids \
      --query 'Vpcs[*].{VpcId:VpcId,State:State,CidrBlock:CidrBlock,Name:Tags[?Key==`Name`].Value|[0],Project:Tags[?Key==`Project`].Value|[0]}' \
      --output table 2>&1)" && rc=0 || rc=$?
    [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (VPC lookup failed)"; return 0; }
    if grep -q 'VpcId' <<<"$vpc_output"; then
      vpc_count="$(wc -w <<<"$vpc_ids" | tr -d ' ')"
      echo -e "${RED}FOUND${NC} (${vpc_count} report-only, no auto-delete)"
      echo "$vpc_output"
      VPCS_FOUND=$vpc_count
      EXIT_CODE=2
    fi
  fi

  if [[ -n "$prot_vpc_ids" && "$prot_vpc_ids" != "None" ]]; then
    prot_count="$(wc -w <<<"$prot_vpc_ids" | tr -d ' ')"
    prot_output="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
      --vpc-ids $prot_vpc_ids \
      --query 'Vpcs[*].{VpcId:VpcId,IsDefault:IsDefault,CidrBlock:CidrBlock,Name:Tags[?Key==`Name`].Value|[0]}' \
      --output table 2>&1)"
    echo -e "${YELLOW}Protected (default)${NC} (${prot_count})"
    echo "$prot_output"
    PROTECTED_VPCS=$prot_count
  fi

  if [[ -z "$vpc_ids" && -n "$prot_vpc_ids" ]]; then
    echo -e "${GREEN}OK${NC} (project VPCs: none, protected defaults present)"
  elif [[ -z "$vpc_ids" && -z "$prot_vpc_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
  fi
}

check_subnets() {
  local subnet_ids prot_subnet_ids subnet_count prot_count subnet_output prot_output rc
  printf "Checking Subnets (region: %s) ... " "$AWS_REGION"

  subnet_ids="$(collect_project_subnet_ids || true)"
  prot_subnet_ids="$(collect_protected_default_subnet_ids || true)"

  if [[ -z "$subnet_ids" && -z "$prot_subnet_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  if [[ -n "$subnet_ids" && "$subnet_ids" != "None" ]]; then
    subnet_output="$(aws ec2 describe-subnets --region "$AWS_REGION" \
      --subnet-ids $subnet_ids \
      --query 'Subnets[*].{SubnetId:SubnetId,VpcId:VpcId,AZ:AvailabilityZone,Name:Tags[?Key==`Name`].Value|[0],Project:Tags[?Key==`Project`].Value|[0]}' \
      --output table 2>&1)" && rc=0 || rc=$?
    [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (subnet lookup failed)"; return 0; }
    if grep -q 'SubnetId' <<<"$subnet_output"; then
      subnet_count="$(wc -w <<<"$subnet_ids" | tr -d ' ')"
      echo -e "${RED}FOUND${NC} (${subnet_count} report-only, no auto-delete)"
      echo "$subnet_output"
      SUBNETS_FOUND=$subnet_count
      EXIT_CODE=2
    fi
  fi

  if [[ -n "$prot_subnet_ids" && "$prot_subnet_ids" != "None" ]]; then
    prot_count="$(wc -w <<<"$prot_subnet_ids" | tr -d ' ')"
    prot_output="$(aws ec2 describe-subnets --region "$AWS_REGION" \
      --subnet-ids $prot_subnet_ids \
      --query 'Subnets[*].{SubnetId:SubnetId,VpcId:VpcId,AZ:AvailabilityZone,DefaultForAz:DefaultForAz,Name:Tags[?Key==`Name`].Value|[0]}' \
      --output table 2>&1)"
    echo -e "${YELLOW}Protected (default)${NC} (${prot_count})"
    echo "$prot_output"
    PROTECTED_SUBNETS=$prot_count
  fi

  if [[ -z "$subnet_ids" && -n "$prot_subnet_ids" ]]; then
    echo -e "${GREEN}OK${NC} (project subnets: none, protected defaults present)"
  elif [[ -z "$subnet_ids" && -z "$prot_subnet_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
  fi
}

check_internet_gateways() {
  local igw_ids prot_igw_ids igw_count prot_count igw_output prot_output rc
  printf "Checking Internet Gateways (region: %s) ... " "$AWS_REGION"

  igw_ids="$(collect_project_igw_ids || true)"
  prot_igw_ids="$(collect_protected_default_igw_ids || true)"

  if [[ -z "$igw_ids" && -z "$prot_igw_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  if [[ -n "$igw_ids" && "$igw_ids" != "None" ]]; then
    igw_output="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
      --internet-gateway-ids $igw_ids \
      --query 'InternetGateways[*].{InternetGatewayId:InternetGatewayId,Name:Tags[?Key==`Name`].Value|[0],Project:Tags[?Key==`Project`].Value|[0],Attachments:Attachments[*].{VpcId:VpcId,State:State}}' \
      --output table 2>&1)" && rc=0 || rc=$?
    [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (IGW lookup failed)"; return 0; }
    if grep -q 'InternetGatewayId' <<<"$igw_output"; then
      igw_count="$(wc -w <<<"$igw_ids" | tr -d ' ')"
      echo -e "${RED}FOUND${NC} (${igw_count} report-only, no auto-delete)"
      echo "$igw_output"
      IGWS_FOUND=$igw_count
      EXIT_CODE=2
    fi
  fi

  if [[ -n "$prot_igw_ids" && "$prot_igw_ids" != "None" ]]; then
    prot_count="$(wc -w <<<"$prot_igw_ids" | tr -d ' ')"
    prot_output="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
      --internet-gateway-ids $prot_igw_ids \
      --query 'InternetGateways[*].{InternetGatewayId:InternetGatewayId,Name:Tags[?Key==`Name`].Value|[0],Attachments:Attachments[*].{VpcId:VpcId,State:State}}' \
      --output table 2>&1)"
    echo -e "${YELLOW}Protected (default)${NC} (${prot_count})"
    echo "$prot_output"
    PROTECTED_IGWS=$prot_count
  fi

  if [[ -z "$igw_ids" && -n "$prot_igw_ids" ]]; then
    echo -e "${GREEN}OK${NC} (project IGWs: none, protected defaults present)"
  elif [[ -z "$igw_ids" && -z "$prot_igw_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
  fi
}

check_security_groups() {
  local sg_ids prot_sg_ids sg_count prot_count sg_output prot_output rc
  printf "Checking Security Groups (region: %s) ... " "$AWS_REGION"

  sg_ids="$(collect_project_security_group_ids || true)"
  prot_sg_ids="$(collect_protected_default_security_group_ids || true)"

  if [[ -z "$sg_ids" && -z "$prot_sg_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
    return 0
  fi

  if [[ -n "$sg_ids" && "$sg_ids" != "None" ]]; then
    sg_output="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
      --group-ids $sg_ids \
      --query 'SecurityGroups[*].{GroupId:GroupId,GroupName:GroupName,VpcId:VpcId,Name:Tags[?Key==`Name`].Value|[0],Project:Tags[?Key==`Project`].Value|[0]}' \
      --output table 2>&1)" && rc=0 || rc=$?
    [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (SG lookup failed)"; return 0; }
    if grep -q 'GroupId' <<<"$sg_output"; then
      sg_count="$(wc -w <<<"$sg_ids" | tr -d ' ')"
      echo -e "${RED}FOUND${NC} (${sg_count})"
      echo "$sg_output"
      SGS_FOUND=$sg_count
      EXIT_CODE=2
    fi
  fi

  if [[ -n "$prot_sg_ids" && "$prot_sg_ids" != "None" ]]; then
    prot_count="$(wc -w <<<"$prot_sg_ids" | tr -d ' ')"
    prot_output="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
      --group-ids $prot_sg_ids \
      --query 'SecurityGroups[*].{GroupId:GroupId,GroupName:GroupName,VpcId:VpcId}' \
      --output table 2>&1)"
    echo -e "${YELLOW}Protected (default)${NC} (${prot_count})"
    echo "$prot_output"
    PROTECTED_SGS=$prot_count
  fi

  if [[ -z "$sg_ids" && -n "$prot_sg_ids" ]]; then
    echo -e "${GREEN}OK${NC} (project SGs: none, protected defaults present)"
  elif [[ -z "$sg_ids" && -z "$prot_sg_ids" ]]; then
    echo -e "${GREEN}OK${NC} (none)"
  fi
}

check_launch_templates() {
  local lt_output rc
  printf "Checking Launch Templates (region: %s) ... " "$AWS_REGION"
  lt_output="$(aws ec2 describe-launch-templates --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'LaunchTemplates[*].{TemplateId:LaunchTemplateId,Name:LaunchTemplateName,Version:LatestVersionNumber}' \
    --output table 2>&1)" && rc=0 || rc=$?
  [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (LT lookup failed)"; return 0; }
  if grep -q '|' <<<"$lt_output"; then
    echo -e "${RED}FOUND${NC}"
    echo "$lt_output"
    LTS_FOUND=1
    EXIT_CODE=2
    return 0
  fi
  echo -e "${GREEN}OK${NC} (none)"
}

check_iam_roles() {
  local role_output rc
  printf "Checking IAM Roles ... "

  role_output="$(aws iam list-roles \
    --query 'Roles[?contains(RoleName, `demo-eks`) || contains(RoleName, `demo-react`)].{RoleName:RoleName,Arn:Arn}' \
    --output table 2>&1)" && rc=0 || rc=$?
  [[ $rc -ne 0 ]] && { echo -e "${YELLOW}WARN${NC} (IAM lookup failed)"; return 0; }

  if grep -q '|' <<<"$role_output"; then
    echo -e "${RED}FOUND${NC}"
    echo "$role_output"
    IAM_ROLES_FOUND=1
    EXIT_CODE=2
    return 0
  fi
  echo -e "${GREEN}OK${NC} (none)"
}

# ---------------------------------------------------------------------------
# Resource collection functions (for deletion mode)
# ---------------------------------------------------------------------------

# Filter by project tag
collect_instance_ids() {
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null
}

collect_eip_ids() {
  aws ec2 describe-addresses \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'Addresses[*].AllocationId' \
    --output text 2>/dev/null
}

collect_volume_ids() {
  aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=status,Values=available,in-use" \
    --query 'Volumes[?State!=`deleting`].VolumeId' \
    --output text 2>/dev/null
}

collect_snapshot_ids() {
  aws ec2 describe-snapshots \
    --region "$AWS_REGION" \
    --owner-ids self \
    --query 'Snapshots[*].SnapshotId' \
    --output text 2>/dev/null
}

collect_eks_cluster_names() {
  aws eks list-clusters --region "$AWS_REGION" \
    --query 'clusters[]' --output text 2>/dev/null
}

dedupe_ids() {
  tr '\t' '\n' | tr ' ' '\n' | awk 'NF && $0 != "None"' | sort -u | xargs
}

# Is an AWS VPC the default VPC for the account?
is_default_vpc_id() {
  local vpc="$1"
  local result
  result="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --vpc-ids "$vpc" \
    --query 'Vpcs[0].IsDefault' --output text 2>/dev/null || true)"
  [[ "$result" == "True" ]]
}

# Is a security group the AWS default security group?
is_default_security_group_id() {
  local sg="$1"
  local name
  name="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --group-ids "$sg" \
    --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null || true)"
  [[ "$name" == "default" ]]
}

# Split space-separated IDs into lines, dedupe, filter to project-owned (non-default VPCs)
filter_non_default_vpc_ids() {
  local vpc
  for vpc in $(tr '\t' '\n' | tr ' ' '\n' | awk 'NF && $0 != "None"' | sort -u); do
    if ! is_default_vpc_id "$vpc"; then
      echo "$vpc"
    fi
  done | xargs
}

# Split space-separated IDs into lines, dedupe, keep only default VPCs
filter_default_vpc_ids() {
  local vpc
  for vpc in $(tr '\t' '\n' | tr ' ' '\n' | awk 'NF && $0 != "None"' | sort -u); do
    if is_default_vpc_id "$vpc"; then
      echo "$vpc"
    fi
  done | xargs
}

collect_security_group_ids() {
  local tagged_ids named_ids groupname_ids eks_ids alb_ids vpc_ids

  tagged_ids="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)"
  named_ids="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${NAME_TAG_PATTERNS}" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)"
  groupname_ids="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=group-name,Values=${GROUP_NAME_PATTERNS}" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)"
  eks_ids="$(collect_eks_cluster_security_group_ids || true)"
  alb_ids="$(collect_alb_controller_security_group_ids || true)"
  vpc_ids="$(collect_eks_vpc_security_group_ids || true)"

  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$tagged_ids" "$named_ids" "$groupname_ids" "$eks_ids" "$alb_ids" "$vpc_ids" | dedupe_ids
}

# Collect SG IDs by EKS ownership tags (aws:eks:cluster-name, kubernetes.io/cluster/<name>=owned)
collect_eks_cluster_security_group_ids() {
  local cluster
  for cluster in $(get_eks_cluster_names_from_tfvars || true); do
    printf '%s\n' "$(aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=tag:aws:eks:cluster-name,Values=${cluster}" \
      --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)"
    printf '%s\n' "$(aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=tag:kubernetes.io/cluster/${cluster},Values=owned" \
      --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)"
  done | dedupe_ids
}

# Collect SG IDs tagged by AWS Load Balancer Controller (elbv2.k8s.aws/cluster=<name>).
# Catches ALB-managed SGs that lack Project tag.
collect_alb_controller_security_group_ids() {
  local cluster
  for cluster in $(get_eks_cluster_names_from_tfvars || true); do
    aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=tag:elbv2.k8s.aws/cluster,Values=${cluster}" \
      --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true
  done | dedupe_ids
}

# SGs in EKS cluster VPCs. Skips AWS default + cluster control-plane SGs.
collect_eks_vpc_security_group_ids() {
  local cluster vpc vpc_csv
  for cluster in $(get_eks_cluster_names_from_tfvars || true); do
    vpc="$(aws eks describe-cluster --name "$cluster" --region "$AWS_REGION" \
      --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
    [[ -z "$vpc" || "$vpc" == "None" ]] && continue
    vpc_csv="${vpc// /,}"
    aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${vpc_csv}" \
      --query 'SecurityGroups[?GroupName != `default` && !starts_with(GroupName, `eks-cluster-sg-`)].GroupId' \
      --output text 2>/dev/null || true
  done | dedupe_ids
}

collect_project_security_group_ids() {
  local all_sgs sg result=()
  all_sgs="$(collect_security_group_ids || true)"
  [[ -z "$all_sgs" || "$all_sgs" == "None" ]] && return 0
  for sg in $all_sgs; do
    if ! is_default_security_group_id "$sg"; then
      result+=("$sg")
    fi
  done
  [[ ${#result[@]} -eq 0 ]] && return 0
  printf '%s\n' "${result[@]}" | dedupe_ids
}

collect_protected_default_security_group_ids() {
  local related_default_vpcs vpc_csv sg_ids
  related_default_vpcs="$(filter_default_vpc_ids <<<"$(collect_related_vpc_ids || true)")"
  [[ -z "$related_default_vpcs" || "$related_default_vpcs" == "None" ]] && return 0
  vpc_csv="${related_default_vpcs// /,}"
  sg_ids="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=group-name,Values=default" "Name=vpc-id,Values=${vpc_csv}" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)"
  [[ -z "$sg_ids" || "$sg_ids" == "None" ]] && return 0
  printf '%s' "$sg_ids" | dedupe_ids
}

collect_related_vpc_ids() {
  local tagged_vpc_ids sg_ids sg_vpc_ids

  tagged_vpc_ids="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'Vpcs[*].VpcId' --output text 2>/dev/null || true)"

  sg_ids="$(collect_security_group_ids || true)"
  if [[ -n "$sg_ids" && "$sg_ids" != "None" ]]; then
    sg_vpc_ids="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
      --group-ids $sg_ids \
      --query 'SecurityGroups[*].VpcId' --output text 2>/dev/null || true)"
  else
    sg_vpc_ids=""
  fi

  printf '%s\n%s\n' "$tagged_vpc_ids" "$sg_vpc_ids" | dedupe_ids
}

# Project VPCs only — excludes default VPCs
collect_project_vpc_ids() {
  local all_vpcs
  all_vpcs="$(collect_related_vpc_ids || true)"
  [[ -z "$all_vpcs" || "$all_vpcs" == "None" ]] && return 0
  filter_non_default_vpc_ids <<<"$all_vpcs"
}

# Default VPCs discovered from project-related VPC set
collect_protected_default_vpc_ids() {
  local all_vpcs
  all_vpcs="$(collect_related_vpc_ids || true)"
  [[ -z "$all_vpcs" || "$all_vpcs" == "None" ]] && return 0
  filter_default_vpc_ids <<<"$all_vpcs"
}

collect_related_subnet_ids() {
  local tagged_subnet_ids vpc_ids vpc_subnet_ids vpc_csv

  tagged_subnet_ids="$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null || true)"

  vpc_ids="$(collect_related_vpc_ids || true)"
  if [[ -n "$vpc_ids" && "$vpc_ids" != "None" ]]; then
    vpc_csv="${vpc_ids// /,}"
    vpc_subnet_ids="$(aws ec2 describe-subnets --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${vpc_csv}" \
      --query 'Subnets[*].SubnetId' --output text 2>/dev/null || true)"
  else
    vpc_subnet_ids=""
  fi

  printf '%s\n%s\n' "$tagged_subnet_ids" "$vpc_subnet_ids" | dedupe_ids
}

# Project subnets — subnets in non-default project VPCs plus project-tagged
collect_project_subnet_ids() {
  local all_subnets vpc_ids vpc_csv project_subnets

  all_subnets="$(collect_related_subnet_ids || true)"
  if [[ -z "$all_subnets" || "$all_subnets" == "None" ]]; then
    return 0
  fi

  # Tagged project subnets directly
  project_subnets="$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null || true)"

  # Subnets in non-default project VPCs
  vpc_ids="$(collect_project_vpc_ids || true)"
  local vpc_subnet_ids=""
  if [[ -n "$vpc_ids" && "$vpc_ids" != "None" ]]; then
    vpc_csv="${vpc_ids// /,}"
    vpc_subnet_ids="$(aws ec2 describe-subnets --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${vpc_csv}" \
      --query 'Subnets[*].SubnetId' --output text 2>/dev/null || true)"
  fi

  printf '%s\n%s\n' "$project_subnets" "$vpc_subnet_ids" | dedupe_ids
}

# Default subnets in protected default VPCs
collect_protected_default_subnet_ids() {
  local vpc_ids vpc_csv
  vpc_ids="$(collect_protected_default_vpc_ids || true)"
  [[ -z "$vpc_ids" || "$vpc_ids" == "None" ]] && return 0
  vpc_csv="${vpc_ids// /,}"
  aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_csv}" \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null | dedupe_ids
}

collect_related_igw_ids() {
  local tagged_igw_ids vpc_ids vpc_igw_ids vpc_csv

  tagged_igw_ids="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || true)"

  vpc_ids="$(collect_related_vpc_ids || true)"
  if [[ -n "$vpc_ids" && "$vpc_ids" != "None" ]]; then
    vpc_csv="${vpc_ids// /,}"
    vpc_igw_ids="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
      --filters "Name=attachment.vpc-id,Values=${vpc_csv}" \
      --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || true)"
  else
    vpc_igw_ids=""
  fi

  printf '%s\n%s\n' "$tagged_igw_ids" "$vpc_igw_ids" | dedupe_ids
}

# Project IGWs — IGWs attached to non-default project VPCs plus project-tagged
collect_project_igw_ids() {
  local vpc_ids vpc_csv igw_ids
  vpc_ids="$(collect_project_vpc_ids || true)"
  if [[ -n "$vpc_ids" && "$vpc_ids" != "None" ]]; then
    vpc_csv="${vpc_ids// /,}"
    igw_ids="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
      --filters "Name=attachment.vpc-id,Values=${vpc_csv}" \
      --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || true)"
  else
    igw_ids=""
  fi
  local tagged_igw_ids
  tagged_igw_ids="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || true)"
  printf '%s\n%s\n' "$tagged_igw_ids" "$igw_ids" | dedupe_ids
}

# Default IGWs attached to protected default VPCs
collect_protected_default_igw_ids() {
  local vpc_ids vpc_csv
  vpc_ids="$(collect_protected_default_vpc_ids || true)"
  [[ -z "$vpc_ids" || "$vpc_ids" == "None" ]] && return 0
  vpc_csv="${vpc_ids// /,}"
  aws ec2 describe-internet-gateways --region "$AWS_REGION" \
    --filters "Name=attachment.vpc-id,Values=${vpc_csv}" \
    --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null | dedupe_ids
}

collect_ecr_repos() {
  aws ecr describe-repositories --region "$AWS_REGION" \
    --query 'repositories[?contains(repositoryName, `demo-react`) || contains(repositoryName, `demo-express`)].repositoryName' \
    --output text 2>/dev/null
}

# ---------------------------------------------------------------------------
# Deletion helper functions
# ---------------------------------------------------------------------------

delete_ec2_instances() {
  local ids="$1"
  [[ -z "$ids" ]] && return 0
  echo "Terminating EC2 instances..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi
  local id rc=0 err_file
  for id in $ids; do
    echo -n "  $id ... "
    err_file="$(mktemp)"
    if aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$id" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "terminate-instances failed for $id"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

delete_elastic_ips() {
  local ids="$1"
  [[ -z "$ids" ]] && return 0
  echo "Releasing Elastic IPs..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi
  local id rc=0 assoc_id err_file
  for id in $ids; do
    echo -n "  $id ... "
    # Disassociate EIP before releasing
    assoc_id="$(aws ec2 describe-addresses --region "$AWS_REGION" --allocation-ids "$id" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null)"
    if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
      aws ec2 disassociate-address --region "$AWS_REGION" --association-id "$assoc_id" 2>>"$LOG_FILE" || true
    fi
    err_file="$(mktemp)"
    if aws ec2 release-address --region "$AWS_REGION" --allocation-id "$id" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "release-address failed for $id"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

delete_ebs_volumes() {
  local ids="$1"
  [[ -z "$ids" ]] && return 0
  echo "Deleting EBS volumes..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi
  local id rc=0 err_file
  for id in $ids; do
    echo -n "  $id ... "
    # In-use volumes: force-detach attachments then wait for available state.
    local vol_state
    vol_state="$(aws ec2 describe-volumes --region "$AWS_REGION" \
      --volume-ids "$id" \
      --query 'Volumes[0].State' --output text 2>/dev/null || true)"
    if [[ "$vol_state" == "in-use" ]]; then
      local attachments att
      attachments="$(aws ec2 describe-volumes --region "$AWS_REGION" \
        --volume-ids "$id" \
        --query 'Volumes[0].Attachments[*].AttachmentId' \
        --output text 2>/dev/null || true)"
      for att in $attachments; do
        aws ec2 detach-volume --region "$AWS_REGION" \
          --volume-id "$id" --attachment-id "$att" \
          --force 2>>"$LOG_FILE" || true
      done
      local _i
      for _i in 1 2 3 4 5 6 7 8 9 10; do
        vol_state="$(aws ec2 describe-volumes --region "$AWS_REGION" \
          --volume-ids "$id" \
          --query 'Volumes[0].State' --output text 2>/dev/null || true)"
        [[ "$vol_state" == "available" ]] && break
        sleep 5
      done
    fi
    err_file="$(mktemp)"
    if aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$id" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-volume failed for $id"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

delete_ebs_snapshots() {
  local ids="$1"
  [[ -z "$ids" ]] && return 0
  echo "Deleting EBS snapshots..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi
  local id rc=0 err_file
  for id in $ids; do
    echo -n "  $id ... "
    err_file="$(mktemp)"
    if aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$id" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-snapshot failed for $id"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

count_s3_object_versions() {
  local bucket="$1" output

  output="$(aws s3api list-object-versions \
    --bucket "$bucket" \
    --region "$AWS_REGION" \
    --output json 2>&1)" || {
    if is_resource_absent "$output"; then
      printf '0\n'
      return 0
    fi
    printf 'unknown\n'
    return 1
  }

  jq '((.Versions // []) + (.DeleteMarkers // [])) | length' <<<"$output"
}

empty_versioned_s3_bucket() {
  local bucket="$1" total_deleted=0
  local list_output delete_json object_count err_file delete_response deleted_count error_count

  while true; do
    err_file="$(mktemp)"
    if ! list_output="$(aws s3api list-object-versions \
        --bucket "$bucket" \
        --region "$AWS_REGION" \
        --max-keys 1000 \
        --output json 2>"$err_file")"; then
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        rm -f "$err_file"
        return 0
      fi
      log_error "list-object-versions failed for $bucket"
      rm -f "$err_file"
      return 1
    fi
    rm -f "$err_file"

    delete_json="$(jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key: .Key, VersionId: .VersionId})), Quiet: false}' <<<"$list_output")" || {
      log_error "jq failed building delete_json for $bucket"
      return 1
    }
    object_count="$(jq '.Objects | length' <<<"$delete_json")" || {
      log_error "jq failed counting objects for $bucket"
      return 1
    }

    [[ "$object_count" -eq 0 ]] && break

    err_file="$(mktemp)"
    delete_response="$(aws s3api delete-objects \
        --bucket "$bucket" \
        --region "$AWS_REGION" \
        --delete "$delete_json" 2>"$err_file")"
    if [[ $? -ne 0 ]]; then
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        rm -f "$err_file"
        return 0
      fi
      log_error "delete-objects failed for $bucket"
      rm -f "$err_file"
      return 1
    fi
    rm -f "$err_file"

    error_count="$(jq '(.Errors // []) | length' <<<"$delete_response")" || {
      log_error "jq failed parsing delete-objects errors for $bucket"
      return 1
    }
    if [[ "$error_count" -gt 0 ]]; then
      log_error "delete-objects returned $error_count errors for $bucket: $delete_response"
      return 1
    fi

    deleted_count="$(jq '(.Deleted // []) | length' <<<"$delete_response")" || {
      log_error "jq failed counting deleted objects for $bucket"
      return 1
    }
    total_deleted=$((total_deleted + deleted_count))

    if [[ "$deleted_count" -eq 0 ]]; then
      log_error "delete-objects made no progress for $bucket (expected $object_count, deleted 0)"
      return 1
    fi
  done

  if [[ "$total_deleted" -gt 0 ]]; then
    printf '  Removed %s object versions/delete markers\n' "$total_deleted"
  fi
}

delete_s3_bucket() {
  local bucket="$1" version_count s3_err
  [[ -z "$bucket" ]] && return 0
  echo "Deleting S3 bucket: $bucket ... "

  if [[ "$DRY_RUN" -eq 1 ]]; then
    version_count="$(count_s3_object_versions "$bucket" 2>/dev/null || true)"
    if [[ -n "$version_count" && "$version_count" != "unknown" ]]; then
      echo -e "${CYAN}DRY-RUN${NC} ($version_count object versions/delete markers would be removed)"
    else
      echo -e "${CYAN}DRY-RUN${NC}"
    fi
    return 0
  fi

  if ! empty_versioned_s3_bucket "$bucket"; then
    echo -e "${RED}FAIL${NC}"
    log_error "versioned S3 cleanup failed for $bucket"
    return 1
  fi

  s3_err="$(mktemp)"
  if aws s3 rb "s3://$bucket" --force 2>"$s3_err"; then
    echo -e "${GREEN}OK${NC}"
  else
    cat "$s3_err" >> "$LOG_FILE"
    if is_resource_absent "$(cat "$s3_err")"; then
      echo -e "${GREEN}OK${NC} (already absent)"
    else
      echo -e "${RED}FAIL${NC}"
      log_error "s3 rb failed for $bucket"
      rm -f "$s3_err"
      return 1
    fi
  fi
  rm -f "$s3_err"
}

destroy_terraform_service() {
  local env="$1" svc="$2"
  local dir="envs/$env/services/$svc"
  [[ -d "$dir" ]] || return 0
  echo "Destroying Terraform state $env/$svc ... "
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi
  # Show terraform destroy output summary instead of hiding it
  if terraform -chdir="$dir" destroy -auto-approve -input=false -no-color 2>>"$LOG_FILE" | tee -a "$LOG_FILE" | tail -5; then
    echo -e "  ${GREEN}OK${NC}"
  else
    echo -e "  ${RED}FAIL${NC}"
    log_error "terraform destroy failed for $env/$svc"
  fi
}

# ---------------------------------------------------------------------------
# NAT Gateway deletion (must run before EIP release)
# ---------------------------------------------------------------------------

delete_nat_gateways() {
  local nat_ids
  nat_ids="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'NatGateways[?State==`available`].NatGatewayId' \
    --output text 2>/dev/null)"
  if [[ -z "$nat_ids" || "$nat_ids" == "None" ]]; then
    nat_ids="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
      --filter "Name=tag:Name,Values=*demo-react*,*demo-eks*" \
      --query 'NatGateways[?State==`available`].NatGatewayId' \
      --output text 2>/dev/null)"
  fi
  [[ -z "$nat_ids" || "$nat_ids" == "None" ]] && return 0
  echo "Deleting NAT Gateways..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi
  local id rc=0 err_file
  for id in $nat_ids; do
    echo -n "  $id ... "
    err_file="$(mktemp)"
    if aws ec2 delete-nat-gateway --region "$AWS_REGION" --nat-gateway-id "$id" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
      echo -n "  Waiting for $id to delete... "
      aws ec2 wait nat-gateway-deleted --region "$AWS_REGION" --nat-gateway-id "$id" 2>>"$LOG_FILE" || {
        echo -e "${YELLOW}timeout${NC}"
        log_error "timeout waiting for nat-gateway $id deletion"
      }
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-nat-gateway failed for $id"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

# ---------------------------------------------------------------------------
# ALB/NLB deletion function
# ---------------------------------------------------------------------------

delete_load_balancers() {
  local lb_arns
  lb_arns="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null)"
  [[ -z "$lb_arns" || "$lb_arns" == "None" ]] && return 0
  echo "Deleting Load Balancers..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi
  local arn rc=0 err_file
  for arn in $lb_arns; do
    echo -n "  $arn ... "
    err_file="$(mktemp)"
    if aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$arn" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
      echo -n "  Waiting for load balancer deletion... "
      if aws elbv2 wait load-balancers-deleted --region "$AWS_REGION" --load-balancer-arns "$arn" 2>>"$LOG_FILE"; then
        echo -e "${GREEN}done${NC}"
      else
        echo -e "${YELLOW}timeout${NC}"
        log_error "timeout waiting for load balancer deletion: $arn"
      fi
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-load-balancer failed for $arn"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

delete_eks_clusters() {
  local cluster_names
  cluster_names="$(collect_eks_cluster_names || true)"
  [[ -z "$cluster_names" || "$cluster_names" == "None" ]] && return 0

  echo "Deleting EKS clusters..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}DRY-RUN${NC}"
    return 0
  fi

  local cluster rc=0 err_file
  for cluster in $cluster_names; do
    local project_tag
    project_tag="$(aws eks describe-cluster --name "$cluster" --region "$AWS_REGION" \
      --query 'cluster.tags.Project' --output text 2>/dev/null)"
    if [[ "$project_tag" != "None" && -n "$project_tag" && "$project_tag" != "$PROJECT_TAG" ]]; then
      # Allow cluster whose name starts with the project token (e.g. eks-react-dev-uat).
      if [[ "$cluster" == eks-react-dev-uat* || "$cluster" == demo-react* ]]; then
        echo -e "  ${YELLOW}Note: $cluster tag Project=$project_tag, but name matches project pattern; proceeding.${NC}"
      else
        echo -e "  ${YELLOW}Skipping $cluster (tag Project=$project_tag)${NC}"
        continue
      fi
    fi
    echo -e "  ${CYAN}Cluster: ${cluster}${NC}"

    local fp_names
    fp_names="$(aws eks list-fargate-profiles --cluster-name "$cluster" --region "$AWS_REGION" \
      --query 'fargateProfileNames[]' --output text 2>/dev/null)"
    if [[ -n "$fp_names" && "$fp_names" != "None" ]]; then
      local fp
      for fp in $fp_names; do
        echo -n "    Fargate profile $fp ... "
        err_file="$(mktemp)"
        if aws eks delete-fargate-profile --cluster-name "$cluster" --fargate-profile-name "$fp" \
            --region "$AWS_REGION" 2>"$err_file"; then
          echo -e "${GREEN}OK${NC}"
          echo -n "    Waiting for fargate profile $fp deletion... "
          aws eks wait fargate-profile-deleted --cluster-name "$cluster" --fargate-profile-name "$fp" \
            --region "$AWS_REGION" 2>>"$LOG_FILE" || {
            echo -e "${YELLOW}timeout${NC}"
            log_error "timeout waiting for fargate profile $fp in $cluster"
          }
          echo -e "${GREEN}done${NC}"
        else
          cat "$err_file" >> "$LOG_FILE"
          if is_resource_absent "$(cat "$err_file")"; then
            echo -e "${GREEN}OK${NC} (already absent)"
          else
            echo -e "${RED}FAIL${NC}"
            log_error "delete-fargate-profile failed for $fp in $cluster"
            rc=1
          fi
        fi
        rm -f "$err_file"
      done
    fi

    local addon_names
    addon_names="$(aws eks list-addons --cluster-name "$cluster" --region "$AWS_REGION" \
      --query 'addons[]' --output text 2>/dev/null)"
    if [[ -n "$addon_names" && "$addon_names" != "None" ]]; then
      local addon
      for addon in $addon_names; do
        echo -n "    Add-on $addon ... "
        err_file="$(mktemp)"
        if aws eks delete-addon --cluster-name "$cluster" --addon-name "$addon" \
            --region "$AWS_REGION" 2>"$err_file"; then
          echo -e "${GREEN}OK${NC}"
          echo -n "    Waiting for add-on $addon deletion... "
          aws eks wait addon-deleted --cluster-name "$cluster" --addon-name "$addon" \
            --region "$AWS_REGION" 2>>"$LOG_FILE" || {
            echo -e "${YELLOW}timeout${NC}"
            log_error "timeout waiting for add-on $addon in $cluster"
          }
          echo -e "${GREEN}done${NC}"
        else
          cat "$err_file" >> "$LOG_FILE"
          if is_resource_absent "$(cat "$err_file")"; then
            echo -e "${GREEN}OK${NC} (already absent)"
          else
            echo -e "${RED}FAIL${NC}"
            log_error "delete-addon failed for $addon in $cluster"
            rc=1
          fi
        fi
        rm -f "$err_file"
      done
    fi

    local ng_names
    ng_names="$(aws eks list-nodegroups --cluster-name "$cluster" --region "$AWS_REGION" \
      --query 'nodegroups[]' --output text 2>/dev/null)"
    if [[ -n "$ng_names" && "$ng_names" != "None" ]]; then
      local ng
      for ng in $ng_names; do
        echo -n "    Node group $ng ... "
        err_file="$(mktemp)"
        if aws eks delete-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" \
            --region "$AWS_REGION" 2>"$err_file"; then
          echo -e "${GREEN}OK${NC}"
          echo -n "    Waiting for $ng deletion... "
          aws eks wait nodegroup-deleted --cluster-name "$cluster" --nodegroup-name "$ng" \
            --region "$AWS_REGION" 2>>"$LOG_FILE" || {
            echo -e "${YELLOW}timeout${NC}"
            log_error "timeout waiting for nodegroup $ng in $cluster"
          }
          echo -e "${GREEN}done${NC}"
        else
          cat "$err_file" >> "$LOG_FILE"
          if is_resource_absent "$(cat "$err_file")"; then
            echo -e "${GREEN}OK${NC} (already absent)"
          else
            echo -e "${RED}FAIL${NC}"
            log_error "delete-nodegroup failed for $ng in $cluster"
            rc=1
          fi
        fi
        rm -f "$err_file"
      done
    fi

    echo -n "    Cluster $cluster ... "
    err_file="$(mktemp)"
    if aws eks delete-cluster --name "$cluster" --region "$AWS_REGION" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
      echo -n "    Waiting for cluster deletion... "
      aws eks wait cluster-deleted --name "$cluster" --region "$AWS_REGION" 2>>"$LOG_FILE" || {
        echo -e "${YELLOW}timeout${NC}"
        log_error "timeout waiting for cluster $cluster deletion"
      }
      echo -e "${GREEN}done${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-cluster failed for $cluster"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

delete_target_groups() {
  local tg_arns
  tg_arns="$(collect_target_group_arns || true)"
  [[ -z "$tg_arns" || "$tg_arns" == "None" ]] && return 0
  echo "Deleting Target Groups..."
  [[ "$DRY_RUN" -eq 1 ]] && { echo -e "${CYAN}DRY-RUN${NC}"; return 0; }
  local arn rc=0 tg_name delete_rc
  for arn in $tg_arns; do
    tg_name="$(aws elbv2 describe-target-groups --region "$AWS_REGION" \
      --target-group-arns "$arn" \
      --query 'TargetGroups[0].TargetGroupName' --output text 2>/dev/null || echo "$arn")"
    echo -n "  $tg_name ($arn) ... "
    wait_target_group_detached "$arn" || true
    TARGET_GROUP_DELETE_LAST_ERROR=""
    delete_target_group_with_retry "$arn"
    delete_rc=$?
    if [[ $delete_rc -eq 0 ]]; then
      echo -e "${GREEN}OK${NC}"
    elif [[ $delete_rc -eq 2 ]]; then
      echo -e "${GREEN}OK${NC} (already absent)"
    else
      print_target_group_delete_failure "$TARGET_GROUP_DELETE_LAST_ERROR"
      log_error "delete-target-group failed for $arn"
      rc=1
    fi
  done
  return $rc
}

delete_ecr_repos() {
  local repos
  repos="$(collect_ecr_repos || true)"
  [[ -z "$repos" || "$repos" == "None" ]] && return 0
  echo "Deleting ECR repositories..."
  [[ "$DRY_RUN" -eq 1 ]] && { echo -e "${CYAN}DRY-RUN${NC}"; return 0; }
  local repo rc=0 err_file
  for repo in $repos; do
    echo -n "  $repo ... "
    err_file="$(mktemp)"
    if aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-repository failed for $repo"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

delete_orphan_network_interfaces_for_sg() {
  local sg="$1" eni_json eni_ids eni rc=0 err_file

  eni_json="$(aws ec2 describe-network-interfaces \
    --region "$AWS_REGION" \
    --filters Name=group-id,Values="$sg" \
    --output json 2>>"$LOG_FILE")" || {
    log_error "describe-network-interfaces failed for $sg"
    return 1
  }

  eni_ids="$(jq -r '
    (.NetworkInterfaces // [])[]
    | select(.Status == "available")
    | select((.Attachment // null) == null)
    | select(.RequesterManaged == false)
    | select(
        ((.TagSet // []) | any(.[]; .Key == "eks:eni:owner" and .Value == "amazon-vpc-cni"))
        or ((.Description // "") | startswith("aws-K8S-"))
      )
    | .NetworkInterfaceId
  ' <<<"$eni_json")" || {
    log_error "jq failed filtering orphan ENIs for $sg"
    return 1
  }

  [[ -z "$eni_ids" ]] && return 0

  for eni in $eni_ids; do
    echo -n "    orphan ENI $eni ... "
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo -e "${CYAN}DRY-RUN${NC}"
      continue
    fi
    err_file="$(mktemp)"
    if aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-network-interface failed for $eni"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done

  return $rc
}

log_security_group_dependency_context() {
  local sg="$1" vpc_id eni_context ref_context

  eni_context="$(aws ec2 describe-network-interfaces \
    --region "$AWS_REGION" \
    --filters Name=group-id,Values="$sg" \
    --query 'NetworkInterfaces[].{NetworkInterfaceId:NetworkInterfaceId,Status:Status,RequesterManaged:RequesterManaged,InterfaceType:InterfaceType,Description:Description,AttachmentId:Attachment.AttachmentId,InstanceId:Attachment.InstanceId,VpcId:VpcId,SubnetId:SubnetId}' \
    --output json 2>&1 || true)"
  log_error "security group $sg ENI dependency context: $eni_context"

  vpc_id="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$sg" \
    --query 'SecurityGroups[0].VpcId' \
    --output text 2>/dev/null || true)"
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    return 0
  fi

  ref_context="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters Name=vpc-id,Values="$vpc_id" \
    --output json 2>/dev/null | jq -c --arg sg "$sg" '
      [(.SecurityGroups // [])[]
      | {
          GroupId,
          GroupName,
          InRefs: [(.IpPermissions // [])[]? | (.UserIdGroupPairs // [])[]? | select(.GroupId == $sg) | .GroupId],
          EgressRefs: [(.IpPermissionsEgress // [])[]? | (.UserIdGroupPairs // [])[]? | select(.GroupId == $sg) | .GroupId]
        }
      | select((.InRefs | length) > 0 or (.EgressRefs | length) > 0)]
    ' 2>&1 || true)"
  log_error "security group $sg rule reference context: $ref_context"
}

# ---------------------------------------------------------------------------
# Proactive SG dependency inspection
# ---------------------------------------------------------------------------

# inspect_sg_dependencies - check for blockers that prevent SG deletion
# Returns 0 if no blockers (safe to delete), 1 if blockers found
# Echoes blocker descriptions to stdout
# $1 = target SG ID
# $2 = space-separated list of project SG IDs
inspect_sg_dependencies() {
  local sg="$1" project_sgs="$2"
  local eni_json vpc_id ref_json blocker_count=0

  # --- ENI dependency check ---
  eni_json="$(aws ec2 describe-network-interfaces \
    --region "$AWS_REGION" \
    --filters Name=group-id,Values="$sg" \
    --output json 2>>"$LOG_FILE")" || {
    echo "    ENI: API failure"
    return 1
  }

  local eni_count
  eni_count="$(jq '(.NetworkInterfaces // []) | length' <<<"$eni_json" 2>/dev/null || echo 0)"

  if [[ "$eni_count" -gt 0 ]]; then
    # Blocked: in-use, attached, requester-managed, or unrecognized orphan
    local blocked_eni_lines
    blocked_eni_lines="$(jq -r '
      (.NetworkInterfaces // [])[]
      | select(
          (.Status != "available")
          or ((.Attachment // null) != null)
          or (.RequesterManaged == true)
          or (
            (.Status == "available")
            and ((.Attachment // null) == null)
            and (.RequesterManaged == false)
            and (((.TagSet // []) | any(.[]; .Key == "eks:eni:owner" and .Value == "amazon-vpc-cni")) | not)
            and (((.Description // "") | startswith("aws-K8S-")) | not)
          )
        )
      | "    ENI blocker: \(.NetworkInterfaceId) [\(.Status)] \(.InterfaceType // "iface") \(.Description // "n/a")"
    ' <<<"$eni_json" 2>/dev/null || true)"

    if [[ -n "$blocked_eni_lines" ]]; then
      echo "$blocked_eni_lines"
      local blocked_eni_count
      blocked_eni_count="$(wc -l <<<"$blocked_eni_lines" | tr -d ' ')"
      blocker_count=$((blocker_count + blocked_eni_count))
    fi
  fi

  # --- SG rule reference check ---
  vpc_id="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$sg" \
    --query 'SecurityGroups[0].VpcId' \
    --output text 2>/dev/null || true)"

  if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
    ref_json="$(aws ec2 describe-security-groups \
      --region "$AWS_REGION" \
      --filters Name=vpc-id,Values="$vpc_id" \
      --output json 2>>"$LOG_FILE" || true)"

    if [[ -n "$ref_json" ]]; then
      # Find SGs referencing target SG in ingress or egress rules
      local ref_sg_ids
      ref_sg_ids="$(printf '%s\n%s\n' \
        "$(echo "$ref_json" | jq -r --arg sg "$sg" '
          (.SecurityGroups // [])[]
          | . as $parent |
          (.IpPermissions // [])[]?
          | (.UserIdGroupPairs // [])[]?
          | select(.GroupId == $sg)
          | $parent.GroupId
        ' 2>/dev/null || true)" \
        "$(echo "$ref_json" | jq -r --arg sg "$sg" '
          (.SecurityGroups // [])[]
          | . as $parent |
          (.IpPermissionsEgress // [])[]?
          | (.UserIdGroupPairs // [])[]?
          | select(.GroupId == $sg)
          | $parent.GroupId
        ' 2>/dev/null || true)" \
        | sort -u | awk 'NF')"

      if [[ -n "$ref_sg_ids" ]]; then
        local ref_sg
        for ref_sg in $ref_sg_ids; do
          [[ "$ref_sg" == "$sg" ]] && continue
          if is_default_security_group_id "$ref_sg"; then
            echo "    SG ref blocker: $ref_sg (default SG) -> $sg"
            blocker_count=$((blocker_count + 1))
          # ponytail: non-default SGs handled by remove_safe_sg_rule_refs
          fi
        done
      fi
    fi
  fi

  [[ "$blocker_count" -gt 0 ]] && return 1
  return 0
}

# remove_safe_sg_rule_refs - revoke rules in project SGs that reference target SG
# Only revokes rules from SGs in the project SG candidate list
# $1 = target SG ID (being deleted)
# $2 = space-separated list of project SG IDs
remove_safe_sg_rule_refs() {
  local sg="$1" project_sgs="$2"
  local vpc_id ref_json rc=0

  vpc_id="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$sg" \
    --query 'SecurityGroups[0].VpcId' \
    --output text 2>/dev/null || true)"

  [[ -z "$vpc_id" || "$vpc_id" == "None" ]] && return 0

  ref_json="$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters Name=vpc-id,Values="$vpc_id" \
    --output json 2>>"$LOG_FILE" || true)"

  [[ -z "$ref_json" ]] && return 0

  local ingress_ref_sgs egress_ref_sgs ref_sg permission err_file

  ingress_ref_sgs="$(echo "$ref_json" | jq -r --arg sg "$sg" '
    (.SecurityGroups // [])[]
    | . as $parent |
    (.IpPermissions // [])[]?
    | (.UserIdGroupPairs // [])[]?
    | select(.GroupId == $sg)
    | $parent.GroupId
  ' 2>/dev/null | sort -u | awk 'NF' || true)"

  egress_ref_sgs="$(echo "$ref_json" | jq -r --arg sg "$sg" '
    (.SecurityGroups // [])[]
    | . as $parent |
    (.IpPermissionsEgress // [])[]?
    | (.UserIdGroupPairs // [])[]?
    | select(.GroupId == $sg)
    | $parent.GroupId
  ' 2>/dev/null | sort -u | awk 'NF' || true)"

  if [[ -n "$ingress_ref_sgs" ]]; then
    for ref_sg in $ingress_ref_sgs; do
      [[ "$ref_sg" == "$sg" ]] && continue
      # ponytail: skip only default SGs — all non-default SGs in VPC get refs revoked
      is_default_security_group_id "$ref_sg" && continue
      while IFS= read -r permission; do
        [[ -z "$permission" ]] && continue
        echo -n "    revoke ingress $ref_sg -> $sg ... "
        if [[ "$DRY_RUN" -eq 1 ]]; then
          echo -e "${CYAN}DRY-RUN${NC}"
          continue
        fi
        err_file="$(mktemp)"
        if aws ec2 revoke-security-group-ingress --region "$AWS_REGION" \
          --group-id "$ref_sg" \
          --ip-permissions "$permission" \
          2>"$err_file"; then
          echo -e "${GREEN}OK${NC}"
        else
          cat "$err_file" >> "$LOG_FILE"
          if is_resource_absent "$(cat "$err_file")" || grep -q 'InvalidPermission.NotFound' <<<"$(cat "$err_file")"; then
            echo -e "${GREEN}OK${NC} (already absent)"
          else
            echo -e "${RED}FAIL${NC}"
            log_error "revoke-security-group-ingress failed for $ref_sg -> $sg"
            rc=1
          fi
        fi
        rm -f "$err_file"
      done < <(echo "$ref_json" | jq -c --arg parent "$ref_sg" --arg sg "$sg" '
        (.SecurityGroups // [])[]
        | select(.GroupId == $parent)
        | (.IpPermissions // [])[]?
        | select((.UserIdGroupPairs // []) | any(.GroupId == $sg))
        | {
            IpProtocol: .IpProtocol,
            FromPort: .FromPort,
            ToPort: .ToPort,
            UserIdGroupPairs: ((.UserIdGroupPairs // []) | map(select(.GroupId == $sg) | {GroupId, UserId, VpcId} | with_entries(select(.value != null))))
          }
        | with_entries(select(.value != null and ((.value | type) != "array" or (.value | length) > 0)))
        | [ . ]
      ' 2>/dev/null || true)
    done
  fi

  if [[ -n "$egress_ref_sgs" ]]; then
    for ref_sg in $egress_ref_sgs; do
      [[ "$ref_sg" == "$sg" ]] && continue
      # ponytail: skip only default SGs — all non-default SGs in VPC get refs revoked
      is_default_security_group_id "$ref_sg" && continue
      while IFS= read -r permission; do
        [[ -z "$permission" ]] && continue
        echo -n "    revoke egress $ref_sg -> $sg ... "
        if [[ "$DRY_RUN" -eq 1 ]]; then
          echo -e "${CYAN}DRY-RUN${NC}"
          continue
        fi
        err_file="$(mktemp)"
        if aws ec2 revoke-security-group-egress --region "$AWS_REGION" \
          --group-id "$ref_sg" \
          --ip-permissions "$permission" \
          2>"$err_file"; then
          echo -e "${GREEN}OK${NC}"
        else
          cat "$err_file" >> "$LOG_FILE"
          if is_resource_absent "$(cat "$err_file")" || grep -q 'InvalidPermission.NotFound' <<<"$(cat "$err_file")"; then
            echo -e "${GREEN}OK${NC} (already absent)"
          else
            echo -e "${RED}FAIL${NC}"
            log_error "revoke-security-group-egress failed for $ref_sg -> $sg"
            rc=1
          fi
        fi
        rm -f "$err_file"
      done < <(echo "$ref_json" | jq -c --arg parent "$ref_sg" --arg sg "$sg" '
        (.SecurityGroups // [])[]
        | select(.GroupId == $parent)
        | (.IpPermissionsEgress // [])[]?
        | select((.UserIdGroupPairs // []) | any(.GroupId == $sg))
        | {
            IpProtocol: .IpProtocol,
            FromPort: .FromPort,
            ToPort: .ToPort,
            UserIdGroupPairs: ((.UserIdGroupPairs // []) | map(select(.GroupId == $sg) | {GroupId, UserId, VpcId} | with_entries(select(.value != null))))
          }
        | with_entries(select(.value != null and ((.value | type) != "array" or (.value | length) > 0)))
        | [ . ]
      ' 2>/dev/null || true)
    done
  fi

  return $rc
}

retry_delete_security_group_after_dependency_cleanup() {
  local sg="$1" attempt max_attempts=6 sleep_seconds=10 err_file err_text

  delete_orphan_network_interfaces_for_sg "$sg" || true

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    echo -n "    retry ${attempt}/${max_attempts} after ${sleep_seconds}s ... "
    sleep "$sleep_seconds"

    err_file="$(mktemp)"
    if aws ec2 delete-security-group --group-id "$sg" --region "$AWS_REGION" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
      rm -f "$err_file"
      return 0
    fi

    err_text="$(cat "$err_file")"
    cat "$err_file" >> "$LOG_FILE"
    rm -f "$err_file"

    if is_resource_absent "$err_text"; then
      echo -e "${GREEN}OK${NC} (already absent)"
      return 0
    fi

    if grep -q 'DependencyViolation' <<<"$err_text"; then
      echo -e "${YELLOW}DependencyViolation${NC}"
      continue
    fi

    echo -e "${RED}FAIL${NC}"
    log_error "delete-security-group retry failed for $sg: $err_text"
    return 1
  done

  log_security_group_dependency_context "$sg"
  log_error "delete-security-group retry exhausted for $sg"
  return 1
}

delete_security_groups() {
  local sg_ids
  sg_ids="$(collect_project_security_group_ids || true)"
  [[ -z "$sg_ids" || "$sg_ids" == "None" ]] && return 0
  echo "Deleting Security Groups..."
  local sg rc=0 err_file blockers
  for sg in $sg_ids; do
    # Hard guard: never delete AWS default security group
    if is_default_security_group_id "$sg"; then
      echo -e "  $sg ... ${YELLOW}SKIP (default SG, protected)${NC}"
      continue
    fi

    # --- Proactive dependency inspection ---
    blockers="$(inspect_sg_dependencies "$sg" "$sg_ids" 2>/dev/null || true)"
    if [[ -n "$blockers" ]]; then
      echo -e "  $sg ... ${YELLOW}SKIP (blockers found)${NC}"
      echo "$blockers"
      log_error "security group $sg deletion blocked by dependencies: $blockers"
      log_security_group_dependency_context "$sg"
      rc=1
      continue
    fi

    # --- Remove safe dependents before deletion ---
    if ! remove_safe_sg_rule_refs "$sg" "$sg_ids"; then
      echo -e "  $sg ... ${RED}FAIL${NC} (SG rule cleanup failed)"
      rc=1
      continue
    fi
    if ! delete_orphan_network_interfaces_for_sg "$sg"; then
      echo -e "  $sg ... ${RED}FAIL${NC} (orphan ENI cleanup failed)"
      rc=1
      continue
    fi

    echo -n "  $sg ... "
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo -e "${CYAN}DRY-RUN${NC}"
      continue
    fi
    err_file="$(mktemp)"
    if aws ec2 delete-security-group --group-id "$sg" --region "$AWS_REGION" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      local err_text
      err_text="$(cat "$err_file")"
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$err_text"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      elif grep -q 'DependencyViolation' <<<"$err_text"; then
        echo -e "${YELLOW}DependencyViolation${NC} — cleaning orphan ENIs..."
        retry_delete_security_group_after_dependency_cleanup "$sg" || rc=1
      elif grep -q 'Cannot delete default security group' <<<"$err_text"; then
        echo -e "${YELLOW}SKIP (default SG, protected by AWS)${NC}"
        continue
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-security-group failed for $sg"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done

  # Sweep EKS cluster SGs that lost their cluster-ownership tag during cluster delete.
  echo "Sweeping EKS cluster security groups (post-delete)..."
  local eks_sg_arns eks_sg eks_err eks_err_text
  eks_sg_arns="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=group-name,Values=eks-cluster-sg-*" \
    --query 'SecurityGroups[?VpcId != \`null\`].GroupId' \
    --output text 2>/dev/null || true)"
  if [[ -n "$eks_sg_arns" && "$eks_sg_arns" != "None" ]]; then
    for eks_sg in $eks_sg_arns; do
      if is_default_security_group_id "$eks_sg"; then continue; fi
      echo -n "  $eks_sg ... "
      delete_orphan_network_interfaces_for_sg "$eks_sg" || true
      eks_err="$(mktemp)"
      if aws ec2 delete-security-group --group-id "$eks_sg" \
          --region "$AWS_REGION" 2>"$eks_err"; then
        echo -e "${GREEN}OK${NC}"
      else
        eks_err_text="$(cat "$eks_err")"
        cat "$eks_err" >> "$LOG_FILE"
        if is_resource_absent "$eks_err_text"; then
          echo -e "${GREEN}OK${NC} (already absent)"
        elif grep -q 'DependencyViolation' <<<"$eks_err_text"; then
          echo -e "${YELLOW}DependencyViolation${NC} — cleaning..."
          retry_delete_security_group_after_dependency_cleanup "$eks_sg" || rc=1
        else
          echo -e "${RED}FAIL${NC}"
          log_error "delete-security-group failed for $eks_sg"
          rc=1
        fi
      fi
      rm -f "$eks_err"
    done
  fi
  return $rc
}

delete_launch_templates() {
  local lt_ids
  lt_ids="$(aws ec2 describe-launch-templates --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query 'LaunchTemplates[*].LaunchTemplateId' --output text 2>/dev/null)"
  [[ -z "$lt_ids" || "$lt_ids" == "None" ]] && return 0
  echo "Deleting Launch Templates..."
  [[ "$DRY_RUN" -eq 1 ]] && { echo -e "${CYAN}DRY-RUN${NC}"; return 0; }
  local lt rc=0 err_file
  for lt in $lt_ids; do
    echo -n "  $lt ... "
    err_file="$(mktemp)"
    if aws ec2 delete-launch-template --launch-template-id "$lt" --region "$AWS_REGION" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-launch-template failed for $lt"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

delete_iam_roles() {
  local roles
  roles="$(aws iam list-roles \
    --query 'Roles[?contains(RoleName, `demo-eks`) || contains(RoleName, `demo-react`)].RoleName' \
    --output text 2>/dev/null)"
  [[ -z "$roles" || "$roles" == "None" ]] && return 0
  echo "Deleting IAM Roles..."
  [[ "$DRY_RUN" -eq 1 ]] && { echo -e "${CYAN}DRY-RUN${NC}"; return 0; }
  local role rc=0 err_file
  for role in $roles; do
    echo -e "  ${CYAN}Role: ${role}${NC}"
    local policies
    policies="$(aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null)"
    if [[ -n "$policies" && "$policies" != "None" ]]; then
      local pol
      for pol in $policies; do
        echo -n "    Detach policy $pol ... "
        if aws iam detach-role-policy --role-name "$role" --policy-arn "$pol" 2>>"$LOG_FILE"; then
          echo -e "${GREEN}OK${NC}"
        else
          echo -e "${RED}FAIL${NC}"
          log_error "detach-role-policy failed for $pol on $role"
        fi
      done
    fi
    # EKS node roles carry an instance profile; aws iam delete-role rejects otherwise.
    echo -n "    Remove instance profiles ... "
    local profiles prof
    profiles="$(aws iam list-instance-profiles-for-role \
      --role-name "$role" \
      --query 'InstanceProfiles[*].InstanceProfileName' \
      --output text 2>/dev/null || true)"
    if [[ -n "$profiles" && "$profiles" != "None" ]]; then
      for prof in $profiles; do
        aws iam remove-role-from-instance-profile \
          --instance-profile-name "$prof" --role-name "$role" \
          2>>"$LOG_FILE" || true
        aws iam delete-instance-profile \
          --instance-profile-name "$prof" \
          2>>"$LOG_FILE" || true
      done
      echo -e "${GREEN}OK${NC}"
    else
      echo -e "${GREEN}OK${NC} (none)"
    fi
    echo -n "    Delete role $role ... "
    err_file="$(mktemp)"
    if aws iam delete-role --role-name "$role" 2>"$err_file"; then
      echo -e "${GREEN}OK${NC}"
    else
      cat "$err_file" >> "$LOG_FILE"
      if is_resource_absent "$(cat "$err_file")"; then
        echo -e "${GREEN}OK${NC} (already absent)"
      else
        echo -e "${RED}FAIL${NC}"
        log_error "delete-role failed for $role"
        rc=1
      fi
    fi
    rm -f "$err_file"
  done
  return $rc
}

# ---------------------------------------------------------------------------
# User confirmation prompt
# ---------------------------------------------------------------------------

confirm_deletion() {
  [[ "$DELETE_MODE" -ne 1 ]] && return 1
  [[ "$EXIT_CODE" -ne 2 ]] && return 1

  if [[ "$AUTO_YES" -eq 1 ]]; then
    echo -e "${YELLOW}Auto-confirm enabled. Proceeding with deletion...${NC}"
    return 0
  fi

  echo
  echo -e "${RED}WARNING: This will permanently delete all found resources.${NC}"
  printf "%bDelete%b all found resources? [y/N] " "$RED" "$NC"
  read -r response
  [[ "$response" =~ ^[Yy]$ ]] && return 0
  echo "Deletion cancelled."
  return 1
}

# ---------------------------------------------------------------------------
# Deletion orchestration (safe order)
# ---------------------------------------------------------------------------

execute_deletions() {
  echo -e "\n${YELLOW}=== Starting Resource Deletion ===${NC}"

  local instance_ids eip_ids volume_ids snapshot_ids bucket

  # 0. EKS clusters (fargate, addons, nodegroups, then cluster)
  delete_eks_clusters

  # 0.5. Wait for EKS node EC2 instances to fully terminate so root EBS volumes detach.
  echo "Waiting for EKS node EC2 termination..."
  local _i remaining
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    remaining="$(aws ec2 describe-instances --region "$AWS_REGION" \
      --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
      "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
      --query 'Reservations[].Instances[].InstanceId' \
      --output text 2>/dev/null || true)"
    [[ -z "$remaining" || "$remaining" == "None" ]] && break
    sleep 10
  done

  # 1. NAT Gateways (must delete before EIP release)
  delete_nat_gateways

  # 2. EC2 instances first (releases attached volumes/EIPs)
  instance_ids="$(collect_instance_ids || true)"
  if [[ -n "$instance_ids" && "$instance_ids" != "None" ]]; then
    delete_ec2_instances "$instance_ids"

    # Wait for instance termination before proceeding to volumes
    if [[ "$DRY_RUN" -ne 1 ]]; then
      echo "Waiting for instance termination..."
      aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $instance_ids 2>>"$LOG_FILE" || {
        echo -e "${YELLOW}WARN: Timeout waiting for instance termination${NC}"
        log_error "timeout waiting for instance termination"
      }
    fi
  fi

  # 3. Load Balancers (delete before dependent resources)
  delete_load_balancers

  # 4. Target Groups (after LBs)
  delete_target_groups

  # 5. Elastic IPs
  eip_ids="$(collect_eip_ids || true)"
  [[ -n "$eip_ids" && "$eip_ids" != "None" ]] && delete_elastic_ips "$eip_ids"

  # 6. EBS volumes (only available/detached ones)
  volume_ids="$(collect_volume_ids || true)"
  [[ -n "$volume_ids" && "$volume_ids" != "None" ]] && delete_ebs_volumes "$volume_ids"

  # 7. EBS snapshots
  snapshot_ids="$(collect_snapshot_ids || true)"
  [[ -n "$snapshot_ids" && "$snapshot_ids" != "None" ]] && delete_ebs_snapshots "$snapshot_ids"

  # 8. Security Groups (after EKS deleted — ENIs released)
  delete_security_groups

  # 9. Launch Templates (after EKS deleted)
  delete_launch_templates

  # 10. IAM Roles (after EKS deleted — cluster IAM deps released)
  delete_iam_roles

  # 11. ECR Repos (after EKS deleted — no pulling images)
  delete_ecr_repos

  # 12. S3 backend bucket
  bucket="$(detect_backend_bucket_name || true)"
  [[ -n "$bucket" ]] && delete_s3_bucket "$bucket"

  # 13. Terraform states (reverse order)
  local envs=()
  if [[ "$TARGET" == "all" ]]; then
    envs=("${ALL_ENVS[@]}")
  else
    envs=("$TARGET")
  fi

  for env in "${envs[@]}"; do
    local services=()
    mapfile -t services < <(get_services "$env" | sort -r)
    for svc in "${services[@]}"; do
      local dir="envs/$env/services/$svc"
      [[ -d "$dir" ]] || continue
      local state_output
      state_output="$(terraform -chdir="$dir" state list -no-color 2>/dev/null || true)"
      [[ -n "$state_output" && ! "$state_output" =~ (No state file|Backend initialization required|NoSuchBucket) ]] && \
        destroy_terraform_service "$env" "$svc"
    done
  done

  # Show error log summary if any failures occurred
  if [[ -s "$LOG_FILE" ]]; then
    echo -e "\n${YELLOW}Some deletions failed. See log: $LOG_FILE${NC}"
  fi

  echo -e "${GREEN}Deletion complete.${NC}"
}

# ---------------------------------------------------------------------------
# Run all checks (refactored for reuse in verification pass)
# ---------------------------------------------------------------------------

run_all_checks() {
  local envs=()
  if [[ "$TARGET" == "all" ]]; then
    envs=("${ALL_ENVS[@]}")
  else
    array_contains "$TARGET" "${ALL_ENVS[@]}" || {
      echo -e "${RED}ERROR:${NC} Invalid env '$TARGET'"; usage; exit 1
    }
    envs=("$TARGET")
  fi

  for env in "${envs[@]}"; do
    echo -e "\n${YELLOW}=== ${env^^} ===${NC}"
    local services=()
    mapfile -t services < <(get_services "$env")
    [[ ${#services[@]} -eq 0 ]] && { echo -e "${YELLOW}No services${NC}"; continue; }
    for svc in "${services[@]}"; do check_service_state "$env" "$svc"; done
  done

  echo -e "\n${YELLOW}=== Shared S3 Backend ===${NC}"
  check_backend_bucket

  echo -e "\n${YELLOW}=== EC2 Instances ===${NC}"
  check_ec2_instances

  echo -e "\n${YELLOW}=== Load Balancers ===${NC}"
  check_load_balancers

  echo -e "\n${YELLOW}=== EKS Clusters ===${NC}"
  check_eks_clusters

  echo -e "\n${YELLOW}=== Elastic IPs ===${NC}"
  check_elastic_ips

  echo -e "\n${YELLOW}=== EBS Volumes ===${NC}"
  check_ebs_volumes

  echo -e "\n${YELLOW}=== EBS Snapshots ===${NC}"
  check_ebs_snapshots

  echo -e "\n${YELLOW}=== NAT Gateways ===${NC}"
  check_nat_gateways

  echo -e "\n${YELLOW}=== ECR Repositories ===${NC}"
  check_ecr_repos

  echo -e "\n${YELLOW}=== Target Groups ===${NC}"
  check_target_groups

  echo -e "\n${YELLOW}=== VPCs ===${NC}"
  check_vpcs

  echo -e "\n${YELLOW}=== Subnets ===${NC}"
  check_subnets

  echo -e "\n${YELLOW}=== Internet Gateways ===${NC}"
  check_internet_gateways

  echo -e "\n${YELLOW}=== Security Groups ===${NC}"
  check_security_groups

  echo -e "\n${YELLOW}=== Launch Templates ===${NC}"
  check_launch_templates

  echo -e "\n${YELLOW}=== IAM Roles ===${NC}"
  check_iam_roles

  echo
  print_processed_summary
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"

  # Validate AWS credentials before any operations
  validate_aws_credentials

  echo "Starting checks. Terraform may take a moment."

  run_all_checks

  # After summary, handle deletion
  if [[ "$DELETE_MODE" -eq 1 && "$EXIT_CODE" -eq 2 ]]; then
    if confirm_deletion; then
      execute_deletions

      # Re-run checks to verify cleanup
      echo -e "\n${YELLOW}=== Re-running verification checks ===${NC}"
      EXIT_CODE=0
      RESOURCES_FOUND=0
      BUCKET_EXISTS=0
      INSTANCES_FOUND=0
      ELASTIC_IPS_FOUND=0
      SNAPSHOTS_FOUND=0
      VOLUMES_FOUND=0
      ALBS_FOUND=0
      EKS_CLUSTERS_FOUND=0
      NAT_GATEWAYS_FOUND=0
      TARGET_GROUPS_FOUND=0
      ECR_REPOS_FOUND=0
      SGS_FOUND=0
      LTS_FOUND=0
      IAM_ROLES_FOUND=0
      VPCS_FOUND=0
      SUBNETS_FOUND=0
      IGWS_FOUND=0
      PROTECTED_SGS=0
      PROTECTED_VPCS=0
      PROTECTED_SUBNETS=0
      PROTECTED_IGWS=0
      SERVICES_CHECKED=0

      run_all_checks
    fi
  fi

  case "$EXIT_CODE" in
    0) echo -e "${GREEN}Result: clean${NC}" ;;
    1) echo -e "${YELLOW}Result: warnings${NC}" ;;
    2) echo -e "${RED}Result: resources remain${NC}" ;;
  esac
  exit "$EXIT_CODE"
}

# Allow sourcing for tests without executing main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
