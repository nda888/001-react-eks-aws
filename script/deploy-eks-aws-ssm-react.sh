#!/usr/bin/env bash
set -euo pipefail

# Save user's kubectl context; restore on exit so `aws eks update-kubeconfig`
# (Step 1) doesn't permanently hijack the default context across clusters.
trap 'if [[ -n "${__PREV_KUBECONTEXT:-}" ]]; then kubectl config use-context "${__PREV_KUBECONTEXT}" >/dev/null 2>&1 || true; fi' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

ENV="${1:-dev}"
SUBCMD="${2:-deploy}"
if [[ "${ENV}" != "dev" && "${ENV}" != "uat" && "${ENV}" != "prod" && "${ENV}" != "all" ]]; then
  echo "Usage: $0 <dev|uat|prod|all> [bootstrap-prometheus]" >&2
  exit 1
fi
if [[ "${SUBCMD}" != "deploy" && "${SUBCMD}" != "bootstrap-prometheus" ]]; then
  echo "Usage: $0 <dev|uat|prod> [deploy|bootstrap-prometheus]" >&2
  exit 1
fi
(($# > 0)) && shift

# all = deploy dev, then uat, then prod.
if [[ "${ENV}" == "all" ]]; then
  if [[ "${SUBCMD}" != "deploy" ]]; then
    echo "ERROR: 'all' only supports the deploy subcommand" >&2
    exit 1
  fi
  echo "==> Deploying dev, then uat, then prod"
  "${BASH_SOURCE[0]}" dev deploy
  "${BASH_SOURCE[0]}" uat deploy
  "${BASH_SOURCE[0]}" prod deploy
  echo "==> dev + uat + prod deployed"
  exit 0
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
EKS_CLUSTER="${EKS_CLUSTER:-}"
NAMESPACE="${NAMESPACE:-${ENV}}"
MONITOR_NAMESPACE="${MONITOR_NAMESPACE:-monitor}"
FORCE_RESTART="${FORCE_RESTART:-true}"
# Monitoring stack (Prometheus/Grafana/Loki) is shared on dev cluster (monitor ns).
# Prod has its own Prometheus + Alloy that push metrics+logs to dev receivers via
# internal NLB (see plan-174). MONITORING_ENABLED=false for prod skips the local
# monitor stack; the prod cluster's writer deployments live in the `prod` ns.
MONITORING_ENABLED="${MONITORING_ENABLED:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3002}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?required: set GRAFANA_ADMIN_PASSWORD env var}"
GRAFANA_SERVICE_ACCOUNT_NAME="${GRAFANA_SERVICE_ACCOUNT_NAME:-dashboard-folder-provisioner}"
GRAFANA_SERVICE_ACCOUNT_ROLE="${GRAFANA_SERVICE_ACCOUNT_ROLE:-Admin}"
GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME="${GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME:-dashboard-folder-deploy-token}"
GRAFANA_TOKEN_SECRET_NAME="${GRAFANA_TOKEN_SECRET_NAME:-grafana-folder-api-token}"
GRAFANA_TOKEN_SECRET_KEY="${GRAFANA_TOKEN_SECRET_KEY:-token}"
GRAFANA_PARENT_FOLDER_TITLE="${GRAFANA_PARENT_FOLDER_TITLE:-React App}"
MONITOR_SSM_PREFIX="${MONITOR_SSM_PREFIX:-}"
PROMETHEUS_SSM_BASIC_AUTH_PARAM="${PROMETHEUS_SSM_BASIC_AUTH_PARAM:-${MONITOR_SSM_PREFIX}/prometheus_basic_auth}"

# Shared-infra resources (ALB SGs) live in namespace owned by Terraform eks-alb. UAT shares dev's.
SHARED_INFRA_NAMESPACE="${SHARED_INFRA_NAMESPACE:-}"
# External Secrets Operator namespace (prod runs ESO in its own ns on a separate cluster).
ESO_NAMESPACE="${ESO_NAMESPACE:-}"
# Kustomize build target. Dev/uat share one kustomization; prod is a separate dir.
KUSTOMIZE_TARGET="${KUSTOMIZE_TARGET:-}"
# Manifest root for the current env. All `${INFRA_DIR}/...` paths resolve here.
INFRA_DIR="${INFRA_DIR:-}"

case "${ENV}" in
  dev)
    EKS_CLUSTER="${EKS_CLUSTER:-eks-react-dev-uat}"
    SHARED_INFRA_NAMESPACE="${SHARED_INFRA_NAMESPACE:-dev}"
    ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
    MONITORING_ENABLED="${MONITORING_ENABLED:-true}"
    MONITOR_SSM_PREFIX="${MONITOR_SSM_PREFIX:-/demo-eks-dev/monitor}"
    INFRA_DIR="${INFRA_DIR:-${PROJECT_DIR}/k8s-infra-aws-ssm-dev-uat/}"
    KUSTOMIZE_TARGET="${KUSTOMIZE_TARGET:-${INFRA_DIR}}"
    GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE:-Dev}"
    SSM_PREFIX="${SSM_PREFIX:-/demo-eks-dev/mongo}"
    MONGO_DATABASE="${MONGO_DATABASE:-dev_be_db}"
    BACKEND_IMAGE_REPO_NAME="${BACKEND_IMAGE_REPO_NAME:-dev-demo-backend}"
    FRONTEND_IMAGE_REPO_NAME="${FRONTEND_IMAGE_REPO_NAME:-dev-demo-frontend}"
    ROTATOR_IMAGE_REPO_NAME="${ROTATOR_IMAGE_REPO_NAME:-dev-mongo-rotator}"
    REQUIRED_TERRAFORM_ORDER="cd ${PROJECT_DIR}/terraform && ./an-deploy be-init && ./an-deploy dev eks && ./an-deploy dev eks-alb && ./an-deploy dev secrets"
    TERRAFORM_SECRETS_DIR="${TERRAFORM_SECRETS_DIR:-${PROJECT_DIR}/terraform/envs/dev/services/secrets}"
    ;;
  uat)
    EKS_CLUSTER="${EKS_CLUSTER:-eks-react-dev-uat}"
    SHARED_INFRA_NAMESPACE="${SHARED_INFRA_NAMESPACE:-dev}"
    ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
    MONITORING_ENABLED="${MONITORING_ENABLED:-true}"
    MONITOR_SSM_PREFIX="${MONITOR_SSM_PREFIX:-/demo-eks-dev/monitor}"
    INFRA_DIR="${INFRA_DIR:-${PROJECT_DIR}/k8s-infra-aws-ssm-dev-uat/}"
    KUSTOMIZE_TARGET="${KUSTOMIZE_TARGET:-${INFRA_DIR}}"
    GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE:-Uat}"
    SSM_PREFIX="${SSM_PREFIX:-/demo-eks-uat/mongo}"
    MONGO_DATABASE="${MONGO_DATABASE:-uat_be_db}"
    BACKEND_IMAGE_REPO_NAME="${BACKEND_IMAGE_REPO_NAME:-uat-demo-backend}"
    FRONTEND_IMAGE_REPO_NAME="${FRONTEND_IMAGE_REPO_NAME:-uat-demo-frontend}"
    ROTATOR_IMAGE_REPO_NAME="${ROTATOR_IMAGE_REPO_NAME:-uat-mongo-rotator}"
    REQUIRED_TERRAFORM_ORDER="cd ${PROJECT_DIR}/terraform && ./an-deploy be-init && ./an-deploy dev eks && ./an-deploy dev eks-alb && ./an-deploy uat secrets"
    TERRAFORM_SECRETS_DIR="${TERRAFORM_SECRETS_DIR:-${PROJECT_DIR}/terraform/envs/uat/services/secrets}"
    ;;
  prod)
    EKS_CLUSTER="${EKS_CLUSTER:-eks-react-prod}"
    NAMESPACE="${NAMESPACE:-prod}"
    SHARED_INFRA_NAMESPACE="${SHARED_INFRA_NAMESPACE:-prod}"
    ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets-prod}"
    INFRA_DIR="${INFRA_DIR:-${PROJECT_DIR}/k8s-infra-aws-ssm-prod/}"
    KUSTOMIZE_TARGET="${KUSTOMIZE_TARGET:-${INFRA_DIR}}"
    GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE:-Prod}"
    SSM_PREFIX="${SSM_PREFIX:-/demo-eks-prod/mongo}"
    MONGO_DATABASE="${MONGO_DATABASE:-prod_be_db}"
    BACKEND_IMAGE_REPO_NAME="${BACKEND_IMAGE_REPO_NAME:-prod-demo-backend}"
    FRONTEND_IMAGE_REPO_NAME="${FRONTEND_IMAGE_REPO_NAME:-prod-demo-frontend}"
    ROTATOR_IMAGE_REPO_NAME="${ROTATOR_IMAGE_REPO_NAME:-prod-mongo-rotator}"
    MONITOR_SSM_PREFIX="${MONITOR_SSM_PREFIX:-/demo-eks-prod/monitor}"
    REQUIRED_TERRAFORM_ORDER="cd ${PROJECT_DIR}/terraform && ./an-deploy prod networking && ./an-deploy prod ecr && ./an-deploy prod eks && ./an-deploy prod eks-alb && ./an-deploy prod secrets"
    TERRAFORM_SECRETS_DIR="${TERRAFORM_SECRETS_DIR:-${PROJECT_DIR}/terraform/envs/prod/services/secrets}"
    MONITORING_ENABLED="${MONITORING_ENABLED:-false}"
    ;;
esac

# Per-env ExternalSecret manifest suffix.
# DEV files use `-dev`; UAT files use `-uat`; PROD files use `-prod`.
case "${ENV}" in
  dev) ES_SUFFIX="-dev"; SECRETSTORE_FILE="secretstore.yaml"; NAMESPACE_FILE="namespace.yaml" ;;
  uat) ES_SUFFIX="-uat"; SECRETSTORE_FILE="secretstore.yaml"; NAMESPACE_FILE="namespace.yaml" ;;
  prod) ES_SUFFIX="-prod"; SECRETSTORE_FILE="secretstore-prod.yaml"; NAMESPACE_FILE="namespace-prod.yaml" ;;
esac

# App-level SSM prefix (parent of mongo prefix). API token lives here,
# separate from mongo credentials so the rotate script can update it
# without touching mongo params.
APP_SSM_PREFIX="${SSM_PREFIX%/mongo}/app"
API_TOKEN_SSM_PARAM="${APP_SSM_PREFIX}/api_token"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

terraform_output_raw() {
  local output_name="$1"
  terraform -chdir="${TERRAFORM_SECRETS_DIR}" output -raw "${output_name}" 2>/dev/null || true
}

sensitive_echo() {
  local label="$1"
  local value="$2"
  printf '  %s = ******** (%d chars)\n' "${label}" "${#value}"
}

generate_and_store_api_token() {
  # Generate random 64-char hex token and push to SSM on first run.
  # Idempotent: skips if SSM already holds a valid-looking token (>= 32 chars).
  local existing
  existing="$(aws ssm get-parameter \
    --name "${API_TOKEN_SSM_PARAM}" \
    --with-decryption --region "${AWS_REGION}" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [[ -n "${existing}" && ${#existing} -ge 32 ]]; then
    echo "  API token SSM param exists (${#existing} chars); skipping bootstrap"
    return 0
  fi

  echo "  Bootstrapping API token (first run)"
  local new_token
  new_token="$(openssl rand -hex 32)"
  sensitive_echo "API token" "${new_token}"

  aws ssm put-parameter \
    --name "${API_TOKEN_SSM_PARAM}" \
    --value "${new_token}" \
    --type SecureString --overwrite --region "${AWS_REGION}" >/dev/null \
    || { echo "ERROR: SSM put-parameter failed for API token" >&2; exit 1; }

  echo "  API token stored in SSM: ${API_TOKEN_SSM_PARAM}"
}

generate_prometheus_hash() {
  local password="$1"
  local hash_line
  if command -v htpasswd >/dev/null 2>&1; then
    # htpasswd -nb writes the line to STDERR; with empty user output is `:<hash>`. sed strips prefix.
    hash_line="$(htpasswd -nbBC 10 "" "${password}" 2>&1 | head -1 | sed -E 's/^[^:]*://')"
  else
    hash_line="$(python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt(rounds=10)).decode())' "${password}")"
  fi
  [[ -n "${hash_line}" ]] || { echo "ERROR: hash generation produced empty result" >&2; return 1; }
  [[ "${hash_line}" == \$2* ]] || { echo "ERROR: hash does not look like bcrypt: ${hash_line}" >&2; return 1; }
  echo "${hash_line}"
}

bootstrap_prometheus_auth_standalone() {
  command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not installed" >&2; return 1; }
  command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not installed" >&2; return 1; }
  aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: AWS credentials not configured" >&2; return 1; }
  if ! command -v htpasswd >/dev/null 2>&1; then
    command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not installed (needed for bcrypt fallback)" >&2; return 1; }
    python3 -c 'import bcrypt' >/dev/null 2>&1 || { echo "ERROR: python3 bcrypt module not installed (pip install bcrypt)" >&2; return 1; }
  fi

  local prom_new_pw
  prom_new_pw="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-32)"
  sensitive_echo "Generated password" "${prom_new_pw}"

  local prom_hash_line
  prom_hash_line="$(generate_prometheus_hash "${prom_new_pw}")" || return 1

  echo "  Hash: admin:${prom_hash_line:0:8}...(${#prom_hash_line} chars)"

  aws ssm put-parameter \
    --name "${PROMETHEUS_SSM_BASIC_AUTH_PARAM}" \
    --value "admin:${prom_hash_line}" \
    --type SecureString --overwrite --region "${AWS_REGION}" >/dev/null \
    || { echo "ERROR: SSM put-parameter failed" >&2; return 1; }

  echo "  SSM updated: ${PROMETHEUS_SSM_BASIC_AUTH_PARAM}"
  echo
  echo "=== SAVE THIS — shown once ==="
  echo "  Prometheus password: ${prom_new_pw}"
  echo "=== END ==="
  echo
  echo "Next: $0 ${ENV}"
}

verify_ssm_parameter_exists() {
  local name="$1"
  if ! aws ssm get-parameter --name "${name}" --with-decryption --region "${AWS_REGION}" --query 'Parameter.Name' --output text >/dev/null 2>&1; then
    echo "ERROR: required SSM parameter missing: ${name}. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
    exit 1
  fi
}

bootstrap_prometheus_basic_auth() {
  local existing
  local existing_hash
  existing="$(aws ssm get-parameter \
    --name "${PROMETHEUS_SSM_BASIC_AUTH_PARAM}" \
    --with-decryption --region "${AWS_REGION}" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  # Skip only if SSM holds a real admin:<bcrypt-hash>. bcrypt hashes are >= 60 chars;
  # 20-char floor rejects placeholders like the literal "admin:" that previously slipped through.
  # PROMETHEUS_FORCE_REBOOTSTRAP=1 forces re-bootstrap even on a valid hash.
  existing_hash="${existing#admin:}"
  if [[ -n "${existing}" && "${existing}" == admin:* && ${#existing_hash} -ge 20 && "${PROMETHEUS_FORCE_REBOOTSTRAP:-0}" != "1" ]]; then
    echo "  Prometheus basic-auth SSM param exists; skipping bootstrap"
    return 0
  fi

  echo "  Bootstrapping Prometheus basic-auth (first run)"

  local prom_new_pw
  prom_new_pw="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-32)"
  sensitive_echo "Prometheus new password" "${prom_new_pw}"

  local prom_hash_line
  prom_hash_line="$(generate_prometheus_hash "${prom_new_pw}")" || exit 1

  aws ssm put-parameter \
    --name "${PROMETHEUS_SSM_BASIC_AUTH_PARAM}" \
    --value "admin:${prom_hash_line}" \
    --type SecureString --overwrite --region "${AWS_REGION}" >/dev/null \
    || { echo "ERROR: SSM put-parameter failed" >&2; exit 1; }

  echo "  Prometheus bootstrap plaintext: ${prom_new_pw}"
  echo "  ^ SAVE THIS; required for curl verification at end of deploy"
}

# Subcommand dispatch: bootstrap-prometheus. Runs after function defs but
# before the full deploy preflight (no docker/kubectl needed for SSM-only rotation).
if [[ "${SUBCMD}" == "bootstrap-prometheus" ]]; then
  bootstrap_prometheus_auth_standalone
  exit $?
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }

aws sts get-caller-identity >/dev/null \
  || { echo "ERROR: AWS credentials not configured" >&2; exit 1; }

if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_IMAGE="${ECR_REGISTRY}/${BACKEND_IMAGE_REPO_NAME}:latest"
FRONTEND_IMAGE="${ECR_REGISTRY}/${FRONTEND_IMAGE_REPO_NAME}:latest"
ROTATOR_IMAGE="${ECR_REGISTRY}/${ROTATOR_IMAGE_REPO_NAME}:latest"

docker buildx version >/dev/null 2>&1 \
  || { echo "ERROR: docker buildx not available" >&2; exit 1; }

wait_for_secret() {
  local secret_name="$1"
  local secret_namespace="${2:-${NAMESPACE}}"
  for attempt in $(seq 1 60); do
    if kubectl -n "${secret_namespace}" get secret "${secret_name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  echo "ERROR: secret/${secret_name} in namespace/${secret_namespace} was not created by External Secrets within 5 minutes" >&2
  return 1
}

bootstrap_grafana_if_missing() {
  echo "  Ensuring Grafana baseline resources"
  kubectl apply -f "${INFRA_DIR}grafana/image-renderer-external-secret.yaml" \
    || { echo "ERROR: grafana-image-renderer ExternalSecret apply failed" >&2; exit 1; }
  kubectl apply -f "${INFRA_DIR}grafana/image-renderer-service.yaml" \
    || { echo "ERROR: grafana-image-renderer service apply failed" >&2; exit 1; }
  kubectl apply -f "${INFRA_DIR}grafana/image-renderer-deployment.yaml" \
    || { echo "ERROR: grafana-image-renderer deployment apply failed" >&2; exit 1; }
  kubectl apply -f "${INFRA_DIR}grafana/datasources.yaml" \
    || { echo "ERROR: grafana datasources apply failed" >&2; exit 1; }

  kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-provider
  namespace: monitor
data:
  dashboards.yaml: |
    apiVersion: 1
    providers: []
YAML

  kubectl create configmap grafana-dashboards \
    --namespace=monitor \
    --from-file=dev-app-logs.json="${INFRA_DIR}grafana/dashboards/dev-app-logs.json" \
    --from-file=dev-mongodb-storage.json="${INFRA_DIR}grafana/dashboards/dev-mongodb-storage.json" \
    --from-file=dev-app-cpu-resources.json="${INFRA_DIR}grafana/dashboards/dev-app-cpu-resources.json" \
    --from-file=dev-app-memory-resources.json="${INFRA_DIR}grafana/dashboards/dev-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap grafana-uat-dashboards \
    --namespace=monitor \
    --from-file=uat-app-logs.json="${INFRA_DIR}grafana/dashboards/uat-app-logs.json" \
    --from-file=uat-mongodb-storage.json="${INFRA_DIR}grafana/dashboards/uat-mongodb-storage.json" \
    --from-file=uat-app-cpu-resources.json="${INFRA_DIR}grafana/dashboards/uat-app-cpu-resources.json" \
    --from-file=uat-app-memory-resources.json="${INFRA_DIR}grafana/dashboards/uat-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Create prod + logs dashboard ConfigMaps before Grafana deployment
  # (the deployment mounts them as volumes — must exist at deploy time).
  local prod_dashboards_dir="${PROJECT_DIR}/k8s-infra-aws-ssm-prod/grafana/dashboards"
  kubectl create configmap grafana-prod-dashboards \
    --namespace="${MONITOR_NAMESPACE}" \
    --from-file=prod-app-logs.json="${prod_dashboards_dir}/prod-app-logs.json" \
    --from-file=prod-mongodb-storage.json="${prod_dashboards_dir}/prod-mongodb-storage.json" \
    --from-file=prod-app-cpu-resources.json="${prod_dashboards_dir}/prod-app-cpu-resources.json" \
    --from-file=prod-app-memory-resources.json="${prod_dashboards_dir}/prod-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap grafana-logs-dashboards \
    --namespace="${MONITOR_NAMESPACE}" \
    --from-file=alloy-observability.json="${INFRA_DIR}grafana/dashboards/alloy-observability.json" \
    --from-file=loki-resources.json="${INFRA_DIR}grafana/dashboards/loki-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${INFRA_DIR}grafana/service.yaml" \
    || { echo "ERROR: grafana service apply failed" >&2; exit 1; }
  if kubectl -n "${MONITOR_NAMESPACE}" get deployment/grafana >/dev/null 2>&1 \
     && kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/grafana --timeout=10s >/dev/null 2>&1; then
    echo "  Grafana deployment already healthy; skipping apply"
  else
    kubectl apply -f "${INFRA_DIR}grafana/deployment.yaml" \
      || { echo "ERROR: grafana deployment apply failed" >&2; exit 1; }
    kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/grafana --timeout "${ROLLOUT_TIMEOUT}" \
      || { echo "ERROR: grafana baseline rollout failed" >&2; exit 1; }
  fi
}

apply_grafana_dashboard_configmaps() {
  # Grafana runs on the dev cluster only; the four dashboard CMs land in dev's
  # `monitor` ns and are served by that single Grafana. The prod CM is read
  # from the prod infra dir on disk — there is no Prometheus/Loki on the prod
  # cluster, only the JSON definitions that dev Grafana renders.
  if ! kubectl -n "${MONITOR_NAMESPACE}" get svc/grafana >/dev/null 2>&1; then
    echo "  Grafana not present in monitor ns; skipping dashboard CM apply"
    return 0
  fi

  kubectl create configmap grafana-dashboards \
    --namespace="${MONITOR_NAMESPACE}" \
    --from-file=dev-app-logs.json="${INFRA_DIR}grafana/dashboards/dev-app-logs.json" \
    --from-file=dev-mongodb-storage.json="${INFRA_DIR}grafana/dashboards/dev-mongodb-storage.json" \
    --from-file=dev-app-cpu-resources.json="${INFRA_DIR}grafana/dashboards/dev-app-cpu-resources.json" \
    --from-file=dev-app-memory-resources.json="${INFRA_DIR}grafana/dashboards/dev-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap grafana-uat-dashboards \
    --namespace="${MONITOR_NAMESPACE}" \
    --from-file=uat-app-logs.json="${INFRA_DIR}grafana/dashboards/uat-app-logs.json" \
    --from-file=uat-mongodb-storage.json="${INFRA_DIR}grafana/dashboards/uat-mongodb-storage.json" \
    --from-file=uat-app-cpu-resources.json="${INFRA_DIR}grafana/dashboards/uat-app-cpu-resources.json" \
    --from-file=uat-app-memory-resources.json="${INFRA_DIR}grafana/dashboards/uat-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  # prod dashboards live in the prod dir on disk but are served by dev Grafana
  local prod_dashboards_dir="${PROJECT_DIR}/k8s-infra-aws-ssm-prod/grafana/dashboards"
  kubectl create configmap grafana-prod-dashboards \
    --namespace="${MONITOR_NAMESPACE}" \
    --from-file=prod-app-logs.json="${prod_dashboards_dir}/prod-app-logs.json" \
    --from-file=prod-mongodb-storage.json="${prod_dashboards_dir}/prod-mongodb-storage.json" \
    --from-file=prod-app-cpu-resources.json="${prod_dashboards_dir}/prod-app-cpu-resources.json" \
    --from-file=prod-app-memory-resources.json="${prod_dashboards_dir}/prod-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap grafana-logs-dashboards \
    --namespace="${MONITOR_NAMESPACE}" \
    --from-file=alloy-observability.json="${INFRA_DIR}grafana/dashboards/alloy-observability.json" \
    --from-file=loki-resources.json="${INFRA_DIR}grafana/dashboards/loki-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -
}

sync_dev_nlb_dns_to_prod_configmaps() {
  # Consolidated receiver NLB (plan-178): one terraform-managed NLB with
  # 2 listeners (9090, 3100). Read the single DNS from terraform output
  # and patch both prod ConfigMaps with the same hostname + different ports.
  # Cross-cluster wiring owned by this script; prod ConfigMaps are not edited
  # by hand. plan-177, plan-178.
  if [[ "${EKS_CLUSTER}" != "eks-react-dev-uat" ]]; then
    return 0
  fi
  local nlb_dns
  nlb_dns="$(terraform -chdir="${PROJECT_DIR}/terraform/envs/dev/services/receiver-nlb" output -raw dns_name 2>/dev/null || true)"
  if [[ -z "${nlb_dns}" ]]; then
    echo "  Skipping prod ConfigMap sync: NLB DNS not available (run terraform apply in receiver-nlb first)"
    return 0
  fi
  local prod_cm_dir="${PROJECT_DIR}/k8s-infra-aws-ssm-prod"
  local prom_cm="${prod_cm_dir}/prometheus/configmap.yaml"
  local alloy_cm="${prod_cm_dir}/alloy/configmap.yaml"
  local changed=0
  if ! grep -q "${nlb_dns}:9090/api/v1/write" "${prom_cm}" 2>/dev/null; then
    sed -i -E "s|(- url: http://)[^:]+(:9090/api/v1/write)|\1${nlb_dns}\2|" "${prom_cm}"
    changed=1
  fi
  if ! grep -q "${nlb_dns}:3100" "${alloy_cm}" 2>/dev/null; then
    sed -i -E "s|(url = \"http://)[^ ]+(:3100/loki/api/v1/push)|\1${nlb_dns}\2|" "${alloy_cm}"
    changed=1
  fi
  if [[ "${changed}" -eq 1 ]]; then
    echo "  Updated prod ConfigMaps with current NLB DNS: ${nlb_dns}"
    echo "  Commit the changes as part of your normal git workflow."
  else
    echo "  Prod ConfigMaps already match current NLB DNS"
  fi
}

ensure_grafana_folder_tree() {
  local helper_script="${INFRA_DIR}grafana/script/grafana-folder-uid.sh"

  if ! kubectl -n "${MONITOR_NAMESPACE}" get svc/grafana >/dev/null 2>&1; then
    echo "ERROR: svc/grafana not found in namespace/${MONITOR_NAMESPACE}. Deploy Grafana first, then rerun to create React App > ${GRAFANA_CHILD_FOLDER_TITLE}." >&2
    exit 1
  fi

  [[ -x "${helper_script}" ]] \
    || { echo "ERROR: Grafana folder helper is missing or not executable: ${helper_script}" >&2; exit 1; }

  echo "  Ensuring Grafana folder tree ${GRAFANA_PARENT_FOLDER_TITLE} > ${GRAFANA_CHILD_FOLDER_TITLE} / ${GRAFANA_UAT_CHILD_FOLDER_TITLE:-Uat} / ${GRAFANA_LOGS_CHILD_FOLDER_TITLE:-Logs} / ${GRAFANA_PROD_CHILD_FOLDER_TITLE:-Prod}" >&2
  MONITOR_NAMESPACE="${MONITOR_NAMESPACE}" \
  GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT}" \
  GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER}" \
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}" \
  GRAFANA_SERVICE_ACCOUNT_NAME="${GRAFANA_SERVICE_ACCOUNT_NAME}" \
  GRAFANA_SERVICE_ACCOUNT_ROLE="${GRAFANA_SERVICE_ACCOUNT_ROLE}" \
  GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME="${GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME}" \
  GRAFANA_TOKEN_SECRET_NAME="${GRAFANA_TOKEN_SECRET_NAME}" \
  GRAFANA_TOKEN_SECRET_KEY="${GRAFANA_TOKEN_SECRET_KEY}" \
  GRAFANA_PARENT_FOLDER_TITLE="${GRAFANA_PARENT_FOLDER_TITLE}" \
  GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE}" \
  GRAFANA_UAT_CHILD_FOLDER_TITLE="${GRAFANA_UAT_CHILD_FOLDER_TITLE:-Uat}" \
  GRAFANA_LOGS_CHILD_FOLDER_TITLE="${GRAFANA_LOGS_CHILD_FOLDER_TITLE:-Logs}" \
  GRAFANA_PROD_CHILD_FOLDER_TITLE="${GRAFANA_PROD_CHILD_FOLDER_TITLE:-Prod}" \
    "${helper_script}" \
    || { echo "ERROR: Grafana folder tree ensure failed" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Step 1: Connect to EKS cluster
# ---------------------------------------------------------------------------

echo ""
echo "========================================"
echo "  DEPLOYING: ${ENV^^}"
echo "========================================"
echo ""

echo "[1/9] Connect to EKS cluster"

__PREV_KUBECONTEXT="$(kubectl config current-context 2>/dev/null || true)"

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER}" \
  || { echo "ERROR: kubeconfig update failed" >&2; exit 1; }

# Ensure dev cluster SG allows NLB traffic from the two receiver NLBs
# (prometheus-receiver-nlb, loki-receiver-nlb). Idempotent: `aws ec2
# authorize-security-group-ingress` returns success if the rule already
# exists. Runs only on the dev cluster; prod cluster has no monitor ns
# and no NLBs to wire. plan-174.
if [[ "${EKS_CLUSTER}" == "eks-react-dev-uat" && "${MONITORING_ENABLED}" == "true" ]]; then
  DEV_CLUSTER_SG="$(aws eks describe-cluster --name "${EKS_CLUSTER}" --region "${AWS_REGION}" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || true)"
  if [[ -n "${DEV_CLUSTER_SG}" && "${DEV_CLUSTER_SG}" != "None" ]]; then
    NLB_SGS="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
      --query 'LoadBalancers[?Type==`network` && Scheme==`internal`].SecurityGroups | []' \
      --output json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(sorted(set(json.load(sys.stdin)))))' 2>/dev/null || true)"
    for nlb_sg in ${NLB_SGS}; do
      for port in 30503 30471; do
        aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
          --group-id "${DEV_CLUSTER_SG}" --protocol tcp --port "${port}" \
          --source-group "${nlb_sg}" >/dev/null 2>&1 || true
      done
    done
    if [[ -n "${NLB_SGS}" ]]; then
      echo "  Dev cluster SG ${DEV_CLUSTER_SG} ingress: 9090/3100 from NLB SGs ${NLB_SGS}"
    fi
  fi
fi

# Sync current dev NLB DNS into the prod ConfigMaps so the next prod deploy
# pushes to the right place. Cross-cluster wiring owned by this script.
# plan-177.
sync_dev_nlb_dns_to_prod_configmaps

# ---------------------------------------------------------------------------
# Step 2: Preflight infrastructure gates (before image publication)
# ---------------------------------------------------------------------------

echo "[2/9] Preflight infrastructure gates"

# Namespace must exist (owned by eks-alb Terraform)
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: namespace/${NAMESPACE} missing. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

# Mongo rotator ServiceAccount and strict IRSA check
if ! kubectl -n "${NAMESPACE}" get serviceaccount mongo-credential-rotator >/dev/null 2>&1; then
  echo "ERROR: mongo-credential-rotator ServiceAccount missing. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

ROTATOR_ROLE_ARN="$(kubectl -n "${NAMESPACE}" get serviceaccount mongo-credential-rotator -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)"
EXPECTED_ROTATOR_ROLE_ARN="$(terraform_output_raw mongo_rotation_role_arn)"

if [[ -z "${ROTATOR_ROLE_ARN}" ]]; then
  echo "ERROR: mongo-credential-rotator ServiceAccount missing eks.amazonaws.com/role-arn annotation. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

if [[ "${ROTATOR_ROLE_ARN}" == "PLACEHOLDER_MONGO_ROTATION_ROLE_ARN" ]]; then
  echo "ERROR: mongo-credential-rotator ServiceAccount still has placeholder IRSA annotation. Import/delete old ServiceAccount, then run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

if [[ ! "${ROTATOR_ROLE_ARN}" =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
  echo "ERROR: mongo-credential-rotator IRSA annotation is not an IAM role ARN: ${ROTATOR_ROLE_ARN}" >&2
  exit 1
fi

if [[ -n "${EXPECTED_ROTATOR_ROLE_ARN}" && "${ROTATOR_ROLE_ARN}" != "${EXPECTED_ROTATOR_ROLE_ARN}" ]]; then
  echo "ERROR: mongo-credential-rotator IRSA annotation differs from Terraform output." >&2
  echo "  live:      ${ROTATOR_ROLE_ARN}" >&2
  echo "  terraform: ${EXPECTED_ROTATOR_ROLE_ARN}" >&2
  exit 1
fi

# SSM parameter existence checks
verify_ssm_parameter_exists "${SSM_PREFIX}/root_username"
verify_ssm_parameter_exists "${SSM_PREFIX}/root_password"
verify_ssm_parameter_exists "${SSM_PREFIX}/app_username"
verify_ssm_parameter_exists "${SSM_PREFIX}/app_password"
verify_ssm_parameter_exists "${SSM_PREFIX}/app_mongodb_uri"
verify_ssm_parameter_exists "${API_TOKEN_SSM_PARAM}"

# ALB security groups ConfigMap (hard fail)
FRONTEND_SG="$(kubectl -n "${SHARED_INFRA_NAMESPACE}" get configmap alb-security-groups -o jsonpath='{.data.frontend_sg}' 2>/dev/null || true)"
BACKEND_SG="$(kubectl -n "${SHARED_INFRA_NAMESPACE}" get configmap alb-security-groups -o jsonpath='{.data.backend_sg}' 2>/dev/null || true)"

if [[ -z "${FRONTEND_SG}" || -z "${BACKEND_SG}" ]]; then
  echo "ERROR: alb-security-groups ConfigMap missing frontend_sg/backend_sg in namespace/${SHARED_INFRA_NAMESPACE}. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

# Prod ALB edge public subnets from terraform (substituted into the ingress manifest at render time).
# Only prod has this output; dev/uat skip and get an empty PROD_SUBNETS (no substitution).
PROD_SUBNETS=""
if [[ "${ENV}" == "prod" ]]; then
  PROD_SUBNETS="$(terraform -chdir="${PROJECT_DIR}/terraform/envs/prod/services/networking" output -json edge_public_subnet_ids 2>/dev/null | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))' 2>/dev/null)"
  if [[ -z "${PROD_SUBNETS}" ]]; then
    echo "ERROR: could not read edge_public_subnet_ids from terraform prod networking." >&2
    echo "       Run: cd terraform && ./an-deploy prod networking" >&2
    exit 1
  fi
fi

# External Secrets Operator SA in its namespace
if ! kubectl -n "${ESO_NAMESPACE}" get serviceaccount external-secrets >/dev/null 2>&1; then
  echo "ERROR: external-secrets ServiceAccount missing in namespace/${ESO_NAMESPACE}. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

# ECR repository existence check
echo "  Verifying ECR repositories exist"
aws ecr describe-repositories --region "${AWS_REGION}" \
  --repository-names "${BACKEND_IMAGE_REPO_NAME}" "${FRONTEND_IMAGE_REPO_NAME}" "${ROTATOR_IMAGE_REPO_NAME}" >/dev/null 2>&1 \
  || { echo "ERROR: ECR repositories missing (${BACKEND_IMAGE_REPO_NAME}, ${FRONTEND_IMAGE_REPO_NAME}, ${ROTATOR_IMAGE_REPO_NAME}). Run: cd ${PROJECT_DIR}/terraform && ./an-deploy ${ENV} ecr" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 3: Build and push images to ECR
# ---------------------------------------------------------------------------

echo "[3/9] Build and push ARM64 images to ECR"

# Bootstrap API token in SSM (idempotent — skips if already exists).
# Must happen before frontend build so the build-arg gets the current value.
generate_and_store_api_token
api_token="$(aws ssm get-parameter \
  --name "${API_TOKEN_SSM_PARAM}" \
  --with-decryption --region "${AWS_REGION}" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)"
if [[ -z "${api_token}" || ${#api_token} -lt 8 ]]; then
  echo "ERROR: unable to read API token from SSM param ${API_TOKEN_SSM_PARAM}" >&2
  exit 1
fi
sensitive_echo "API token from SSM" "${api_token}"

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}" \
  || { echo "ERROR: ECR login failed" >&2; exit 1; }

docker buildx build \
  --platform linux/arm64 \
  --push \
  --provenance=false \
  -t "${BACKEND_IMAGE}" \
  --target development \
  "${PROJECT_DIR}/src/backend" \
  || { echo "ERROR: backend image build/push failed" >&2; exit 1; }

docker buildx build \
  --platform linux/arm64 \
  --push \
  --provenance=false \
  --build-arg VITE_API_TOKEN="${api_token}" \
  -t "${FRONTEND_IMAGE}" \
  --target development \
  "${PROJECT_DIR}/src/frontend" \
  || { echo "ERROR: frontend image build/push failed" >&2; exit 1; }

docker buildx build \
  --platform linux/arm64 \
  --push \
  --provenance=false \
  -t "${ROTATOR_IMAGE}" \
  "${INFRA_DIR}mongo" \
  -f "${INFRA_DIR}mongo/scripts/Dockerfile.rotator" \
  || { echo "ERROR: mongo-rotator image build/push failed" >&2; exit 1; }

echo "[4/9] Verify images in ECR"

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${BACKEND_IMAGE_REPO_NAME}" \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt,digest:imageDigest}' \
  --output table \
  || { echo "ERROR: backend image not found in ECR" >&2; exit 1; }

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${FRONTEND_IMAGE_REPO_NAME}" \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt,digest:imageDigest}' \
  --output table \
  || { echo "ERROR: frontend image not found in ECR" >&2; exit 1; }

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${ROTATOR_IMAGE_REPO_NAME}" \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt,digest:imageDigest}' \
  --output table \
  || { echo "ERROR: mongo-rotator image not found in ECR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 5: Apply namespace and storage prerequisites
# ---------------------------------------------------------------------------

echo "[5/9] Apply namespace and storage prerequisites"

kubectl apply -f "${INFRA_DIR}${NAMESPACE_FILE}" \
  || { echo "ERROR: namespace apply failed" >&2; exit 1; }

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  kubectl get namespace "${MONITOR_NAMESPACE}" >/dev/null \
    || { echo "ERROR: namespace/${MONITOR_NAMESPACE} missing after namespace apply" >&2; exit 1; }
fi

kubectl apply -f "${INFRA_DIR}storageclass-gp3.yaml" \
  || { echo "ERROR: storageclass apply failed" >&2; exit 1; }

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  PVC_MANIFESTS=(
    "prometheus-data:${INFRA_DIR}prometheus/prometheus-pvc.yaml"
    "grafana-data:${INFRA_DIR}grafana/grafana-pvc.yaml"
    "loki-data:${INFRA_DIR}grafana/loki-pvc.yaml"
  )

  for entry in "${PVC_MANIFESTS[@]}"; do
    pvc_name="${entry%%:*}"
    manifest="${entry#*:}"
    pvc_namespace="${NAMESPACE}"
    case "${pvc_name}" in
      prometheus-data|grafana-data|loki-data) pvc_namespace="${MONITOR_NAMESPACE}" ;;
    esac

    if kubectl -n "${pvc_namespace}" get pvc "${pvc_name}" >/dev/null 2>&1; then
      echo "  PVC ${pvc_namespace}/${pvc_name} exists, skipping apply (immutable storageClassName)"
    else
      echo "  Creating PVC ${pvc_namespace}/${pvc_name} from ${manifest}"
      kubectl -n "${pvc_namespace}" apply -f "${manifest}" \
        || { echo "ERROR: PVC ${pvc_namespace}/${pvc_name} apply failed" >&2; exit 1; }
    fi
  done
else
  echo "  Monitoring disabled for ${ENV}; skipping monitor PVCs"
fi

# ---------------------------------------------------------------------------
# Step 5.5: Bootstrap Prometheus basic-auth SSM credential
# ---------------------------------------------------------------------------

echo "[5.5/9] Bootstrap Prometheus basic-auth SSM credential"
if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  bootstrap_prometheus_basic_auth

  kubectl -n "${MONITOR_NAMESPACE}" annotate externalsecret/prometheus-basic-auth \
    "force-sync=$(date +%s)" --overwrite 2>/dev/null || true
  for _ in $(seq 1 30); do
    prom_new_hash="$(kubectl -n "${MONITOR_NAMESPACE}" get secret prometheus-basic-auth \
      -o jsonpath='{.data.auth}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ "${prom_new_hash}" =~ ^admin:.+ ]]; then
      echo "  Prometheus K8s Secret populated by ESO"
      break
    fi
    sleep 1
  done
else
  echo "  Monitoring disabled for ${ENV}; skipping Prometheus basic-auth bootstrap"
fi

# ---------------------------------------------------------------------------
# Step 6: Stage External Secrets and wait for generated secrets
# ---------------------------------------------------------------------------

echo "[6/9] Stage External Secrets resources"

kubectl apply -f "${INFRA_DIR}external-secrets/${SECRETSTORE_FILE}" \
  || { echo "ERROR: ESO SecretStore apply failed" >&2; exit 1; }

kubectl apply -f "${INFRA_DIR}external-secrets/mongo-root-external-secret${ES_SUFFIX}.yaml" \
  || { echo "ERROR: mongo-root-external-secret${ES_SUFFIX} apply failed" >&2; exit 1; }

kubectl apply -f "${INFRA_DIR}external-secrets/mongo-app-external-secret${ES_SUFFIX}.yaml" \
  || { echo "ERROR: mongo-app-external-secret${ES_SUFFIX} apply failed" >&2; exit 1; }

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  kubectl apply -f "${INFRA_DIR}grafana/image-renderer-external-secret.yaml" \
    || { echo "ERROR: grafana-image-renderer ExternalSecret apply failed" >&2; exit 1; }
fi

kubectl -n "${NAMESPACE}" wait externalsecret/mongo-root-secret --for=condition=Ready --timeout=180s \
  || { echo "ERROR: mongo-root-secret ExternalSecret did not become Ready" >&2; exit 1; }

kubectl -n "${NAMESPACE}" wait externalsecret/mongo-app-secret --for=condition=Ready --timeout=180s \
  || { echo "ERROR: mongo-app-secret ExternalSecret did not become Ready" >&2; exit 1; }

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  kubectl -n "${MONITOR_NAMESPACE}" wait externalsecret/grafana-image-renderer --for=condition=Ready --timeout=180s \
    || { echo "ERROR: grafana-image-renderer ExternalSecret did not become Ready" >&2; exit 1; }
fi

wait_for_secret mongo-root-secret
wait_for_secret mongo-app-secret

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  wait_for_secret grafana-image-renderer "${MONITOR_NAMESPACE}"

  kubectl -n "${MONITOR_NAMESPACE}" delete secret prometheus-basic-auth --ignore-not-found \
    || true

  kubectl apply -f "${INFRA_DIR}external-secrets/prometheus-basic-auth-external-secret.yaml" \
    || { echo "ERROR: prometheus-basic-auth ExternalSecret apply failed" >&2; exit 1; }

  kubectl -n "${MONITOR_NAMESPACE}" wait externalsecret/prometheus-basic-auth --for=condition=Ready --timeout=180s \
    || { echo "ERROR: prometheus-basic-auth ExternalSecret did not become Ready" >&2; exit 1; }

  kubectl -n "${MONITOR_NAMESPACE}" annotate externalsecret/prometheus-basic-auth \
    "force-sync=$(date +%s)" --overwrite
  for _ in $(seq 1 30); do
    prom_line="$(kubectl -n "${MONITOR_NAMESPACE}" get secret prometheus-basic-auth \
      -o jsonpath='{.data.auth}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ "${prom_line}" =~ ^admin:.+ ]] && break
    sleep 1
  done

  wait_for_secret prometheus-basic-auth "${MONITOR_NAMESPACE}"

  prom_line="$(kubectl -n "${MONITOR_NAMESPACE}" get secret prometheus-basic-auth -o jsonpath='{.data.auth}' | base64 -d)"
  if [[ ! "${prom_line}" =~ ^admin:.+ ]]; then
    echo "ERROR: prometheus-basic-auth secret malformed: ${prom_line}" >&2
    exit 1
  fi
  sensitive_echo "Prometheus basic-auth line loaded" "${prom_line}"

  bootstrap_grafana_if_missing
else
  echo "  Monitoring disabled for ${ENV}; skipping grafana/prometheus ExternalSecrets"
fi

# Dashboard CMs are served by dev Grafana; create them on every env so prod folder is not empty.
# On prod this is a no-op (Grafana not present), but the helper guards that internally.
apply_grafana_dashboard_configmaps

# ---------------------------------------------------------------------------
# Step 7: Render Kustomize and replace ALB security group placeholders
# ---------------------------------------------------------------------------

echo "[7/9] Render manifests and replace ALB security group placeholders"

RENDERED_MANIFEST="$(mktemp /tmp/k8s-infra-aws-ssm.XXXXXX.yaml)"
"${SCRIPT_DIR}/render-k8s.sh" "${KUSTOMIZE_TARGET}" > "${RENDERED_MANIFEST}"

python3 - "${RENDERED_MANIFEST}" "${FRONTEND_SG}" "${BACKEND_SG}" "${PROD_SUBNETS}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
frontend_sg = sys.argv[2]
backend_sg = sys.argv[3]
prod_subnets = sys.argv[4]
text = path.read_text()
text = text.replace('PLACEHOLDER_FRONTEND_SG,PLACEHOLDER_BACKEND_SG', f'{frontend_sg},{backend_sg}')
if 'PLACEHOLDER_FRONTEND_SG' in text or 'PLACEHOLDER_BACKEND_SG' in text:
    raise SystemExit('security group placeholders remain after render')
if prod_subnets:
    if 'PLACEHOLDER_PROD_SUBNETS' not in text:
        raise SystemExit('PLACEHOLDER_PROD_SUBNETS not found in rendered manifest (was the sentinel removed from ingress-prod.yaml?)')
    text = text.replace('PLACEHOLDER_PROD_SUBNETS', prod_subnets)
    if 'PLACEHOLDER_PROD_SUBNETS' in text:
        raise SystemExit('PLACEHOLDER_PROD_SUBNETS still present after substitution')
path.write_text(text)
PY

if grep -q 'PLACEHOLDER_DEV_FOLDER_UID\|PLACEHOLDER_UAT_FOLDER_UID\|PLACEHOLDER_LOGS_FOLDER_UID\|PLACEHOLDER_PROD_FOLDER_UID' "${RENDERED_MANIFEST}"; then
  FOLDER_OUTPUT="$(ensure_grafana_folder_tree)"
  GRAFANA_REACT_APP_DEV_FOLDER_UID="$(echo "${FOLDER_OUTPUT}" | grep '^DEV_FOLDER_UID=' | cut -d= -f2)"
  GRAFANA_REACT_APP_UAT_FOLDER_UID="$(echo "${FOLDER_OUTPUT}" | grep '^UAT_FOLDER_UID=' | cut -d= -f2)"
  GRAFANA_REACT_APP_LOGS_FOLDER_UID="$(echo "${FOLDER_OUTPUT}" | grep '^LOGS_FOLDER_UID=' | cut -d= -f2)"
  GRAFANA_REACT_APP_PROD_FOLDER_UID="$(echo "${FOLDER_OUTPUT}" | grep '^PROD_FOLDER_UID=' | cut -d= -f2)"
  if [[ ! "${GRAFANA_REACT_APP_DEV_FOLDER_UID}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: invalid Grafana DEV folder UID returned by helper" >&2
    exit 1
  fi
  python3 - "${RENDERED_MANIFEST}" "${GRAFANA_REACT_APP_DEV_FOLDER_UID}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
folder_uid = sys.argv[2]
text = path.read_text().replace('PLACEHOLDER_DEV_FOLDER_UID', folder_uid)
if 'PLACEHOLDER_DEV_FOLDER_UID' in text:
    raise SystemExit('Grafana DEV folder UID placeholder remains after render')
path.write_text(text)
PY
  if [[ -n "${GRAFANA_REACT_APP_UAT_FOLDER_UID:-}" ]] && grep -q 'PLACEHOLDER_UAT_FOLDER_UID' "${RENDERED_MANIFEST}"; then
    if [[ ! "${GRAFANA_REACT_APP_UAT_FOLDER_UID}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "ERROR: invalid Grafana UAT folder UID returned by helper" >&2
      exit 1
    fi
    python3 - "${RENDERED_MANIFEST}" "${GRAFANA_REACT_APP_UAT_FOLDER_UID}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
folder_uid = sys.argv[2]
text = path.read_text().replace('PLACEHOLDER_UAT_FOLDER_UID', folder_uid)
if 'PLACEHOLDER_UAT_FOLDER_UID' in text:
    raise SystemExit('Grafana UAT folder UID placeholder remains after render')
path.write_text(text)
PY
  fi
  if [[ -n "${GRAFANA_REACT_APP_LOGS_FOLDER_UID:-}" ]] && grep -q 'PLACEHOLDER_LOGS_FOLDER_UID' "${RENDERED_MANIFEST}"; then
    if [[ ! "${GRAFANA_REACT_APP_LOGS_FOLDER_UID}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "ERROR: invalid Grafana LOGS folder UID returned by helper" >&2
      exit 1
    fi
    python3 - "${RENDERED_MANIFEST}" "${GRAFANA_REACT_APP_LOGS_FOLDER_UID}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
folder_uid = sys.argv[2]
text = path.read_text().replace('PLACEHOLDER_LOGS_FOLDER_UID', folder_uid)
if 'PLACEHOLDER_LOGS_FOLDER_UID' in text:
    raise SystemExit('Grafana LOGS folder UID placeholder remains after render')
path.write_text(text)
PY
  fi
  if [[ -n "${GRAFANA_REACT_APP_PROD_FOLDER_UID:-}" ]] && grep -q 'PLACEHOLDER_PROD_FOLDER_UID' "${RENDERED_MANIFEST}"; then
    if [[ ! "${GRAFANA_REACT_APP_PROD_FOLDER_UID}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "ERROR: invalid Grafana PROD folder UID returned by helper" >&2
      exit 1
    fi
    python3 - "${RENDERED_MANIFEST}" "${GRAFANA_REACT_APP_PROD_FOLDER_UID}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
folder_uid = sys.argv[2]
text = path.read_text().replace('PLACEHOLDER_PROD_FOLDER_UID', folder_uid)
if 'PLACEHOLDER_PROD_FOLDER_UID' in text:
    raise SystemExit('Grafana PROD folder UID placeholder remains after render')
path.write_text(text)
PY
  fi
fi

if grep -q 'PLACEHOLDER_DEV_FOLDER_UID\|PLACEHOLDER_UAT_FOLDER_UID\|PLACEHOLDER_LOGS_FOLDER_UID\|PLACEHOLDER_PROD_FOLDER_UID' "${RENDERED_MANIFEST}"; then
  echo "ERROR: unresolved Grafana folder UID placeholder remains in rendered manifest" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 8: Dry-run and apply rendered manifests
# ---------------------------------------------------------------------------

echo "[8/9] Dry-run and apply rendered manifests"

# Recreate create-mongo-app-user before dry-run: Job templates are immutable,
# and applying a completed Job will not run it again after secret/config changes.
if kubectl -n "${NAMESPACE}" get job create-mongo-app-user >/dev/null 2>&1; then
  echo "  Deleting existing job/create-mongo-app-user so it reruns"
  kubectl -n "${NAMESPACE}" delete job create-mongo-app-user --ignore-not-found \
    || { echo "ERROR: failed to delete job/create-mongo-app-user" >&2; exit 1; }
fi

kubectl apply --dry-run=server -f "${RENDERED_MANIFEST}" \
  || { echo "ERROR: manifest dry-run failed" >&2; exit 1; }

echo "  Removing old dev Grafana/Prometheus ingresses before monitor cutover"
kubectl -n "${NAMESPACE}" delete ingress grafana prometheus --ignore-not-found \
  || { echo "ERROR: failed to delete old observability ingresses" >&2; exit 1; }

kubectl apply -f "${RENDERED_MANIFEST}" \
  || { echo "ERROR: manifest apply failed" >&2; exit 1; }

# Fail fast if any ingress still has unresolved subnet placeholders. Catches
# a class of bugs where the manifest ships a TODO stub that the script's
# SG-substitution does not touch (e.g. subnet-REPLACE_ME_PROD_AZ1).
if grep -E 'subnet-REPLACE_ME|subnet-replace_me' "${RENDERED_MANIFEST}" >/dev/null 2>&1; then
  echo "ERROR: rendered manifest still has unresolved ingress subnet placeholders." >&2
  echo "       Replace them in k8s-infra-aws-ssm-prod/.../ingress-prod.yaml with the" >&2
  echo "       canonical IDs from 'terraform -chdir=terraform/envs/prod/services/networking output edge_public_subnet_ids'." >&2
  exit 1
fi

# Preflight: confirm the mongo StatefulSet's required node affinity can be satisfied
# by at least one Ready node. Catches the case where a nodegroup was moved/recreated
# without re-applying the manifest: the pod template's frozen zone is now empty,
# so mongo-0 sits Pending forever instead of failing fast with a useful error.
echo "  Verifying mongo affinity can be satisfied by current nodes"
AFFINITY_ZONE="$(python3 - "${RENDERED_MANIFEST}" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
  if not d:
    continue
  if d.get("kind") == "StatefulSet" and d.get("metadata", {}).get("name") == "mongo":
    terms = (d["spec"]["template"]["spec"]
                .get("affinity", {})
                .get("nodeAffinity", {})
                .get("requiredDuringSchedulingIgnoredDuringExecution", {})
                .get("nodeSelectorTerms", []))
    for t in terms:
      for e in t.get("matchExpressions", []):
        if e.get("key") == "topology.kubernetes.io/zone":
          print(e["values"][0])
          sys.exit(0)
PY
)"
if [[ -n "${AFFINITY_ZONE}" ]]; then
  MATCHING="$(kubectl get nodes -l workload=stateful \
    -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' \
    | grep -cFx "${AFFINITY_ZONE}" || true)"
  if [[ "${MATCHING}" -eq 0 ]]; then
    echo "ERROR: mongo affinity requires zone '${AFFINITY_ZONE}' with label workload=stateful," >&2
    echo "       but no node matches. Create the stateful nodegroup in that zone first," >&2
    echo "       or update the affinity in k8s-infra-aws-ssm-prod/.../statefulset-prod.yaml." >&2
    exit 1
  fi
  echo "  Found ${MATCHING} node(s) in zone ${AFFINITY_ZONE} with workload=stateful"
fi

# Wait for every Ingress to get an ADDRESS (i.e. the AWS Load Balancer Controller
# has provisioned the ALB and the targets are registered). Without this, the
# deploy script "succeeds" while LBC silently fails reconcile on bad config.
echo "  Waiting for ingress(es) to be provisioned by AWS Load Balancer Controller"
INGRESS_TIMEOUT="${INGRESS_TIMEOUT:-6m}"
INGRESS_DEADLINE=$((SECONDS + ${INGRESS_TIMEOUT%m} * 60))
while (( SECONDS < INGRESS_DEADLINE )); do
  PENDING=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    ADDR=$(kubectl get ingress "${line##*/}" -n "${line%%/*}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -z "${ADDR}" ]; then
      PENDING=$((PENDING + 1))
    else
      echo "    ${line} -> ${ADDR}"
    fi
  done < <(kubectl get ingress -n "${NAMESPACE}" --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | awk '{print $1"/"$2}')
  [ "${PENDING}" -eq 0 ] && break
  sleep 10
done
if (( SECONDS >= INGRESS_DEADLINE )); then
  echo "ERROR: ${PENDING} ingress(es) in ns/${NAMESPACE} did not get an ADDRESS in ${INGRESS_TIMEOUT}." >&2
  echo "       Check AWS Load Balancer Controller logs:" >&2
  echo "         kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50" >&2
  echo "       Common causes: bad subnet IDs, bad SG IDs, ACM cert ARN region mismatch, subnet not tagged for ALB." >&2
  exit 1
fi

# Wait for Mongo StatefulSet to be ready before running the create-app-user Job.
# Without this, on a fresh cluster the Job starts before Mongo accepts connections and times out.
echo "  Waiting for statefulset/mongo to be ready..."
kubectl -n "${NAMESPACE}" rollout status statefulset/mongo --timeout "${ROLLOUT_TIMEOUT}" \
  || { echo "ERROR: statefulset/mongo did not become ready" >&2; exit 1; }

echo "  Syncing MongoDB passwords with SSM"
NAMESPACE="${NAMESPACE}" \
MONGO_HOST="mongo:27017" \
MONGO_DATABASE="${MONGO_DATABASE}" \
  "${SCRIPT_DIR}/sync-pass-mongodb.sh" \
  || { echo "ERROR: Mongo password sync failed" >&2; exit 1; }

# Wait for create-mongo-app-user Job to complete before starting backend.
# Without this, backend can start before the Mongo app user exists.
echo "  Waiting for job/create-mongo-app-user to complete..."
kubectl -n "${NAMESPACE}" wait job/create-mongo-app-user --for=condition=complete --timeout="${ROLLOUT_TIMEOUT}" \
  || { echo "ERROR: job/create-mongo-app-user did not complete in ${ROLLOUT_TIMEOUT}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 9: Rollout restart and wait
# ---------------------------------------------------------------------------

echo "[9/9] Rollout restart and wait for workloads"

if [[ "${FORCE_RESTART}" == "true" ]]; then
  kubectl -n "${NAMESPACE}" rollout restart deployment/backend \
    || { echo "ERROR: backend rollout restart failed" >&2; exit 1; }

  kubectl -n "${NAMESPACE}" rollout restart deployment/frontend \
    || { echo "ERROR: frontend rollout restart failed" >&2; exit 1; }

  if [[ "${MONITORING_ENABLED}" == "true" ]]; then
    kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/loki \
      || { echo "ERROR: loki rollout restart failed" >&2; exit 1; }

    kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/prometheus \
      || { echo "ERROR: prometheus rollout restart failed" >&2; exit 1; }

    kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/grafana \
      || { echo "ERROR: grafana rollout restart failed" >&2; exit 1; }

    kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/grafana-image-renderer \
      || { echo "ERROR: grafana-image-renderer rollout restart failed" >&2; exit 1; }
  fi
else
  echo "Skipped (FORCE_RESTART != true). Set FORCE_RESTART=true to force pull of latest images."
fi

kubectl -n "${NAMESPACE}" rollout status statefulset/mongo --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout "${ROLLOUT_TIMEOUT}"

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/prometheus --timeout "${ROLLOUT_TIMEOUT}"
  kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/loki --timeout "${ROLLOUT_TIMEOUT}"
  kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/grafana --timeout "${ROLLOUT_TIMEOUT}"
  kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/grafana-image-renderer --timeout "${ROLLOUT_TIMEOUT}"
fi

kubectl -n "${NAMESPACE}" get pods,svc,pvc
if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  kubectl -n "${MONITOR_NAMESPACE}" get pods,svc,pvc
fi

echo
echo "++ FrontEnd access"
echo "++ App URL:"
echo "kubectl -n ${NAMESPACE} port-forward svc/frontend 3000:3000"
echo "Open: http://localhost:3000"

echo
echo "++ Backend API:"
echo "kubectl -n ${NAMESPACE} port-forward svc/backend 3001:3000"
echo "Open: http://localhost:3001"

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
  echo
  echo "++ Grafana URL:"
  echo "Grafana login: admin / admin"
  echo "kubectl -n ${MONITOR_NAMESPACE} port-forward svc/grafana 3002:3000"
  echo "Open: http://localhost:3002"

  echo
  echo "++ Prometheus URL:"
  echo "kubectl -n ${MONITOR_NAMESPACE} port-forward svc/prometheus 9090:9090"
  echo "Open: http://localhost:9090"

  echo
  echo "++ Loki internal endpoint: http://loki.${MONITOR_NAMESPACE}.svc.cluster.local:3100"
  echo "Alloy runs as daemonset/alloy and forwards logs to Loki (no external service)."
else
  echo
  echo "++ Monitoring disabled for ${ENV} (no Prometheus/Grafana/Loki on this cluster)."
fi
