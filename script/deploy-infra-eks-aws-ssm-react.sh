#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

ENV="${1:-dev}"
if [[ "${ENV}" != "dev" && "${ENV}" != "uat" && "${ENV}" != "all" ]]; then
  echo "Usage: $0 <dev|uat|all>" >&2
  exit 1
fi
(($# > 0)) && shift

# all = deploy dev then uat sequentially. Each env uses its own defaults.
if [[ "${ENV}" == "all" ]]; then
  echo "==> Deploying ALL environments: dev, then uat"
  "${BASH_SOURCE[0]}" dev "$@"
  "${BASH_SOURCE[0]}" uat "$@"
  echo "==> ALL environments deployed (dev + uat)"
  exit 0
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
EKS_CLUSTER="${EKS_CLUSTER:-demo-eks-dev}"
NAMESPACE="${NAMESPACE:-${ENV}}"
MONITOR_NAMESPACE="${MONITOR_NAMESPACE:-monitor}"
FORCE_RESTART="${FORCE_RESTART:-true}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3002}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD must be set (refusing default 'admin')}"
GRAFANA_SERVICE_ACCOUNT_NAME="${GRAFANA_SERVICE_ACCOUNT_NAME:-dashboard-folder-provisioner}"
GRAFANA_SERVICE_ACCOUNT_ROLE="${GRAFANA_SERVICE_ACCOUNT_ROLE:-Admin}"
GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME="${GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME:-dashboard-folder-deploy-token}"
GRAFANA_TOKEN_SECRET_NAME="${GRAFANA_TOKEN_SECRET_NAME:-grafana-folder-api-token}"
GRAFANA_TOKEN_SECRET_KEY="${GRAFANA_TOKEN_SECRET_KEY:-token}"
GRAFANA_PARENT_FOLDER_TITLE="${GRAFANA_PARENT_FOLDER_TITLE:-React App}"

# Shared-infra resources (ALB security groups, etc.) live in the namespace
# owned by Terraform eks-alb. UAT runs on the same EKS cluster and shares them.
SHARED_INFRA_NAMESPACE="${SHARED_INFRA_NAMESPACE:-dev}"

case "${ENV}" in
  dev)
    GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE:-Dev}"
    SSM_PREFIX="${SSM_PREFIX:-/demo-eks-dev/mongo}"
    BACKEND_IMAGE_REPO_NAME="${BACKEND_IMAGE_REPO_NAME:-dev-demo-backend}"
    FRONTEND_IMAGE_REPO_NAME="${FRONTEND_IMAGE_REPO_NAME:-dev-demo-frontend}"
    ROTATOR_IMAGE_REPO_NAME="${ROTATOR_IMAGE_REPO_NAME:-dev-mongo-rotator}"
    REQUIRED_TERRAFORM_ORDER="cd ${PROJECT_DIR}/terraform && ./an-deploy be-init && ./an-deploy dev eks && ./an-deploy dev eks-alb && ./an-deploy dev secrets"
    TERRAFORM_SECRETS_DIR="${TERRAFORM_SECRETS_DIR:-${PROJECT_DIR}/terraform/envs/dev/services/secrets}"
    ;;
  uat)
    GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE:-Uat}"
    SSM_PREFIX="${SSM_PREFIX:-/demo-eks-uat/mongo}"
    BACKEND_IMAGE_REPO_NAME="${BACKEND_IMAGE_REPO_NAME:-uat-demo-backend}"
    FRONTEND_IMAGE_REPO_NAME="${FRONTEND_IMAGE_REPO_NAME:-uat-demo-frontend}"
    ROTATOR_IMAGE_REPO_NAME="${ROTATOR_IMAGE_REPO_NAME:-uat-mongo-rotator}"
    REQUIRED_TERRAFORM_ORDER="cd ${PROJECT_DIR}/terraform && ./an-deploy be-init && ./an-deploy dev eks && ./an-deploy dev eks-alb && ./an-deploy uat secrets"
    TERRAFORM_SECRETS_DIR="${TERRAFORM_SECRETS_DIR:-${PROJECT_DIR}/terraform/envs/uat/services/secrets}"
    ;;
esac

# Per-env ExternalSecret manifest suffix.
# DEV files use `-dev`; UAT files use `-uat`.
case "${ENV}" in
  dev) ES_SUFFIX="-dev" ;;
  uat) ES_SUFFIX="-uat" ;;
esac

command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }

aws sts get-caller-identity >/dev/null \
  || { echo "ERROR: AWS credentials not configured" >&2; exit 1; }

if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

docker buildx version >/dev/null 2>&1 \
  || { echo "ERROR: docker buildx not available" >&2; exit 1; }

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_IMAGE="${ECR_REGISTRY}/${BACKEND_IMAGE_REPO_NAME}:latest"
FRONTEND_IMAGE="${ECR_REGISTRY}/${FRONTEND_IMAGE_REPO_NAME}:latest"
ROTATOR_IMAGE="${ECR_REGISTRY}/${ROTATOR_IMAGE_REPO_NAME}:latest"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

terraform_output_raw() {
  local output_name="$1"
  terraform -chdir="${TERRAFORM_SECRETS_DIR}" output -raw "${output_name}" 2>/dev/null || true
}

verify_ssm_parameter_exists() {
  local name="$1"
  if ! aws ssm get-parameter --name "${name}" --with-decryption --region "${AWS_REGION}" --query 'Parameter.Name' --output text >/dev/null 2>&1; then
    echo "ERROR: required SSM parameter missing: ${name}. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
    exit 1
  fi
}

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
  kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/image-renderer-external-secret.yaml" \
    || { echo "ERROR: grafana-image-renderer ExternalSecret apply failed" >&2; exit 1; }
  kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/image-renderer-service.yaml" \
    || { echo "ERROR: grafana-image-renderer service apply failed" >&2; exit 1; }
  kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/image-renderer-deployment.yaml" \
    || { echo "ERROR: grafana-image-renderer deployment apply failed" >&2; exit 1; }
  kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/datasources.yaml" \
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
    --from-file=dev-app-logs.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/dev-app-logs.json" \
    --from-file=dev-mongodb-storage.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/dev-mongodb-storage.json" \
    --from-file=dev-app-cpu-resources.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/dev-app-cpu-resources.json" \
    --from-file=dev-app-memory-resources.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/dev-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap grafana-uat-dashboards \
    --namespace=monitor \
    --from-file=uat-app-logs.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/uat-app-logs.json" \
    --from-file=uat-mongodb-storage.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/uat-mongodb-storage.json" \
    --from-file=uat-app-cpu-resources.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/uat-app-cpu-resources.json" \
    --from-file=uat-app-memory-resources.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/uat-app-memory-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap grafana-logs-dashboards \
    --namespace=monitor \
    --from-file=alloy-observability.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/alloy-observability.json" \
    --from-file=loki-resources.json="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/dashboards/loki-resources.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/service.yaml" \
    || { echo "ERROR: grafana service apply failed" >&2; exit 1; }
  kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/deployment.yaml" \
    || { echo "ERROR: grafana deployment apply failed" >&2; exit 1; }
  kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/grafana --timeout "${ROLLOUT_TIMEOUT}" \
    || { echo "ERROR: grafana baseline rollout failed" >&2; exit 1; }
}

ensure_grafana_folder_tree() {
  local helper_script="${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/script/grafana-folder-uid.sh"

  if ! kubectl -n "${MONITOR_NAMESPACE}" get svc/grafana >/dev/null 2>&1; then
    echo "ERROR: svc/grafana not found in namespace/${MONITOR_NAMESPACE}. Deploy Grafana first, then rerun to create React App > ${GRAFANA_CHILD_FOLDER_TITLE}." >&2
    exit 1
  fi

  [[ -x "${helper_script}" ]] \
    || { echo "ERROR: Grafana folder helper is missing or not executable: ${helper_script}" >&2; exit 1; }

  echo "  Ensuring Grafana folder tree ${GRAFANA_PARENT_FOLDER_TITLE} > ${GRAFANA_CHILD_FOLDER_TITLE} / ${GRAFANA_UAT_CHILD_FOLDER_TITLE:-Uat} / ${GRAFANA_LOGS_CHILD_FOLDER_TITLE:-Logs}" >&2
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
    "${helper_script}" \
    || { echo "ERROR: Grafana folder tree ensure failed" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Step 1: Connect to EKS cluster
# ---------------------------------------------------------------------------

echo "[1/9] Connect to EKS cluster"

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER}" \
  || { echo "ERROR: kubeconfig update failed" >&2; exit 1; }

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

# ALB security groups ConfigMap (hard fail)
FRONTEND_SG="$(kubectl -n "${SHARED_INFRA_NAMESPACE}" get configmap alb-security-groups -o jsonpath='{.data.frontend_sg}' 2>/dev/null || true)"
BACKEND_SG="$(kubectl -n "${SHARED_INFRA_NAMESPACE}" get configmap alb-security-groups -o jsonpath='{.data.backend_sg}' 2>/dev/null || true)"

if [[ -z "${FRONTEND_SG}" || -z "${BACKEND_SG}" ]]; then
  echo "ERROR: alb-security-groups ConfigMap missing frontend_sg/backend_sg in namespace/${SHARED_INFRA_NAMESPACE}. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

# External Secrets Operator SA in external-secrets namespace
if ! kubectl -n external-secrets get serviceaccount external-secrets >/dev/null 2>&1; then
  echo "ERROR: external-secrets ServiceAccount missing. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
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
  -t "${FRONTEND_IMAGE}" \
  --target development \
  "${PROJECT_DIR}/src/frontend" \
  || { echo "ERROR: frontend image build/push failed" >&2; exit 1; }

docker buildx build \
  --platform linux/arm64 \
  --push \
  --provenance=false \
  -t "${ROTATOR_IMAGE}" \
  "${PROJECT_DIR}/k8s-infra-aws-ssm/mongo" \
  -f "${PROJECT_DIR}/k8s-infra-aws-ssm/mongo/scripts/Dockerfile.rotator" \
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

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/namespace.yaml" \
  || { echo "ERROR: namespace apply failed" >&2; exit 1; }

kubectl get namespace "${MONITOR_NAMESPACE}" >/dev/null \
  || { echo "ERROR: namespace/${MONITOR_NAMESPACE} missing after namespace apply" >&2; exit 1; }

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/storageclass-gp3.yaml" \
  || { echo "ERROR: storageclass apply failed" >&2; exit 1; }

PVC_MANIFESTS=(
  "prometheus-data:${PROJECT_DIR}/k8s-infra-aws-ssm/prometheus/prometheus-pvc.yaml"
  "grafana-data:${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/grafana-pvc.yaml"
  "loki-data:${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/loki-pvc.yaml"
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

# ---------------------------------------------------------------------------
# Step 6: Stage External Secrets and wait for generated secrets
# ---------------------------------------------------------------------------

echo "[6/9] Stage External Secrets resources"

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/external-secrets/secretstore.yaml" \
  || { echo "ERROR: ESO SecretStore apply failed" >&2; exit 1; }

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/external-secrets/mongo-root-external-secret${ES_SUFFIX}.yaml" \
  || { echo "ERROR: mongo-root-external-secret${ES_SUFFIX} apply failed" >&2; exit 1; }

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/external-secrets/mongo-app-external-secret${ES_SUFFIX}.yaml" \
  || { echo "ERROR: mongo-app-external-secret${ES_SUFFIX} apply failed" >&2; exit 1; }

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/grafana/image-renderer-external-secret.yaml" \
  || { echo "ERROR: grafana-image-renderer ExternalSecret apply failed" >&2; exit 1; }

kubectl -n "${NAMESPACE}" wait externalsecret/mongo-root-secret --for=condition=Ready --timeout=180s \
  || { echo "ERROR: mongo-root-secret ExternalSecret did not become Ready" >&2; exit 1; }

kubectl -n "${NAMESPACE}" wait externalsecret/mongo-app-secret --for=condition=Ready --timeout=180s \
  || { echo "ERROR: mongo-app-secret ExternalSecret did not become Ready" >&2; exit 1; }

kubectl -n "${MONITOR_NAMESPACE}" wait externalsecret/grafana-image-renderer --for=condition=Ready --timeout=180s \
  || { echo "ERROR: grafana-image-renderer ExternalSecret did not become Ready" >&2; exit 1; }

wait_for_secret mongo-root-secret
wait_for_secret mongo-app-secret
wait_for_secret grafana-image-renderer "${MONITOR_NAMESPACE}"
bootstrap_grafana_if_missing

# ---------------------------------------------------------------------------
# Step 7: Render Kustomize and replace ALB security group placeholders
# ---------------------------------------------------------------------------

echo "[7/9] Render manifests and replace ALB security group placeholders"

RENDERED_MANIFEST="$(mktemp /tmp/k8s-infra-aws-ssm.XXXXXX.yaml)"
kubectl kustomize "${PROJECT_DIR}/k8s-infra-aws-ssm/" > "${RENDERED_MANIFEST}"

python3 - "${RENDERED_MANIFEST}" "${FRONTEND_SG}" "${BACKEND_SG}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
frontend_sg = sys.argv[2]
backend_sg = sys.argv[3]
text = path.read_text()
text = text.replace('PLACEHOLDER_FRONTEND_SG,PLACEHOLDER_BACKEND_SG', f'{frontend_sg},{backend_sg}')
if 'PLACEHOLDER_FRONTEND_SG' in text or 'PLACEHOLDER_BACKEND_SG' in text:
    raise SystemExit('security group placeholders remain after render')
path.write_text(text)
PY

if grep -q 'PLACEHOLDER_DEV_FOLDER_UID\|PLACEHOLDER_UAT_FOLDER_UID\|PLACEHOLDER_LOGS_FOLDER_UID' "${RENDERED_MANIFEST}"; then
  FOLDER_OUTPUT="$(ensure_grafana_folder_tree)"
  GRAFANA_REACT_APP_DEV_FOLDER_UID="$(echo "${FOLDER_OUTPUT}" | grep '^DEV_FOLDER_UID=' | cut -d= -f2)"
  GRAFANA_REACT_APP_UAT_FOLDER_UID="$(echo "${FOLDER_OUTPUT}" | grep '^UAT_FOLDER_UID=' | cut -d= -f2)"
  GRAFANA_REACT_APP_LOGS_FOLDER_UID="$(echo "${FOLDER_OUTPUT}" | grep '^LOGS_FOLDER_UID=' | cut -d= -f2)"
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
fi

if grep -q 'PLACEHOLDER_DEV_FOLDER_UID\|PLACEHOLDER_UAT_FOLDER_UID\|PLACEHOLDER_LOGS_FOLDER_UID' "${RENDERED_MANIFEST}"; then
  echo "ERROR: unresolved Grafana folder UID placeholder remains in rendered manifest" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 8: Dry-run and apply rendered manifests
# ---------------------------------------------------------------------------

echo "[8/9] Dry-run and apply rendered manifests"

if grep -qE '^[^#]*PLACEHOLDER_' "${RENDERED_MANIFEST}"; then
  echo "ERROR: unresolved PLACEHOLDER_* in rendered manifest — aborting apply" >&2
  grep -nE 'PLACEHOLDER_' "${RENDERED_MANIFEST}" >&2
  rm -f "${RENDERED_MANIFEST}"
  exit 2
fi

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


# Wait for create-mongo-app-user Job to complete before starting backend.
# Without this, backend can start before the Mongo app user exists.
echo "  Waiting for job/create-mongo-app-user to complete..."
kubectl -n "${NAMESPACE}" wait job/create-mongo-app-user --for=condition=complete --timeout=120s \
  || { echo "ERROR: job/create-mongo-app-user did not complete in 120s" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 9: Rollout restart and wait
# ---------------------------------------------------------------------------

echo "[9/9] Rollout restart and wait for workloads"

if [[ "${FORCE_RESTART}" == "true" ]]; then
  kubectl -n "${NAMESPACE}" rollout restart deployment/backend \
    || { echo "ERROR: backend rollout restart failed" >&2; exit 1; }

  kubectl -n "${NAMESPACE}" rollout restart deployment/frontend \
    || { echo "ERROR: frontend rollout restart failed" >&2; exit 1; }

  kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/loki \
    || { echo "ERROR: loki rollout restart failed" >&2; exit 1; }

  kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/prometheus \
    || { echo "ERROR: prometheus rollout restart failed" >&2; exit 1; }

  kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/grafana \
    || { echo "ERROR: grafana rollout restart failed" >&2; exit 1; }

  kubectl -n "${MONITOR_NAMESPACE}" rollout restart deployment/grafana-image-renderer \
    || { echo "ERROR: grafana-image-renderer rollout restart failed" >&2; exit 1; }
else
  echo "Skipped (FORCE_RESTART != true). Set FORCE_RESTART=true to force pull of latest images."
fi

kubectl -n "${NAMESPACE}" rollout status statefulset/mongo --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/prometheus --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/loki --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/grafana --timeout "${ROLLOUT_TIMEOUT}"

kubectl -n "${MONITOR_NAMESPACE}" rollout status deployment/grafana-image-renderer --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" get pods,svc,pvc
kubectl -n "${MONITOR_NAMESPACE}" get pods,svc,pvc

echo
echo "++ FrontEnd access"
echo "++ App URL:"
echo "kubectl -n ${NAMESPACE} port-forward svc/frontend 3000:3000"
echo "Open: http://localhost:3000"

echo
echo "++ Backend API:"
echo "kubectl -n ${NAMESPACE} port-forward svc/backend 3001:3000"
echo "Open: http://localhost:3001"

echo
echo "++ Grafana URL:"
echo "Grafana login: admin / <set via GRAFANA_ADMIN_PASSWORD>"
echo "kubectl -n ${MONITOR_NAMESPACE} port-forward svc/grafana 3002:3000"
echo "Open: http://localhost:3002"

echo
echo "++ Prometheus URL:"
echo "kubectl -n ${MONITOR_NAMESPACE} port-forward svc/prometheus 9090:9090"
echo "Open: http://localhost:9090"

echo
echo "++ Loki internal endpoint: http://loki.${MONITOR_NAMESPACE}.svc.cluster.local:3100"
echo "Alloy runs as daemonset/alloy and forwards logs to Loki (no external service)."
