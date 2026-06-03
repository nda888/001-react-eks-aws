#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
EKS_CLUSTER="${EKS_CLUSTER:-demo-eks-dev}"
NAMESPACE="${NAMESPACE:-dev}"
FORCE_RESTART="${FORCE_RESTART:-true}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
SSM_PREFIX="${SSM_PREFIX:-/demo-eks-dev/mongo}"
ACM_CERTIFICATE_ARN="${ACM_CERTIFICATE_ARN:-}"
ALB_SUBNET_IDS="${ALB_SUBNET_IDS:-}"
REQUIRED_TERRAFORM_ORDER="cd ${PROJECT_DIR}/terraform && ./an-deploy be-init && ./an-deploy dev eks && ./an-deploy dev eks-alb && ./an-deploy dev secrets"
TERRAFORM_SECRETS_DIR="${PROJECT_DIR}/terraform/envs/dev/services/secrets"

command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }

aws sts get-caller-identity >/dev/null \
  || { echo "ERROR: AWS credentials not configured" >&2; exit 1; }

if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

: "${ACM_CERTIFICATE_ARN:?Set ACM_CERTIFICATE_ARN (ACM certificate ARN for ALB HTTPS listener)}"
: "${ALB_SUBNET_IDS:?Set ALB_SUBNET_IDS as comma-separated subnet IDs for ALB}"

docker buildx version >/dev/null 2>&1 \
  || { echo "ERROR: docker buildx not available" >&2; exit 1; }

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_IMAGE="${ECR_REGISTRY}/dev-demo-backend:latest"
FRONTEND_IMAGE="${ECR_REGISTRY}/dev-demo-frontend:latest"

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
  for attempt in $(seq 1 60); do
    if kubectl -n "${NAMESPACE}" get secret "${secret_name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  echo "ERROR: secret/${secret_name} was not created by External Secrets within 5 minutes" >&2
  return 1
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
FRONTEND_SG="$(kubectl -n "${NAMESPACE}" get configmap alb-security-groups -o jsonpath='{.data.frontend_sg}' 2>/dev/null || true)"
BACKEND_SG="$(kubectl -n "${NAMESPACE}" get configmap alb-security-groups -o jsonpath='{.data.backend_sg}' 2>/dev/null || true)"

if [[ -z "${FRONTEND_SG}" || -z "${BACKEND_SG}" ]]; then
  echo "ERROR: alb-security-groups ConfigMap missing frontend_sg/backend_sg. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

# External Secrets Operator SA in external-secrets namespace
if ! kubectl -n external-secrets get serviceaccount external-secrets >/dev/null 2>&1; then
  echo "ERROR: external-secrets ServiceAccount missing. Run: ${REQUIRED_TERRAFORM_ORDER}" >&2
  exit 1
fi

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

echo "[4/9] Verify images in ECR"

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name dev-demo-backend \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt,digest:imageDigest}' \
  --output table \
  || { echo "ERROR: backend image not found in ECR" >&2; exit 1; }

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name dev-demo-frontend \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt,digest:imageDigest}' \
  --output table \
  || { echo "ERROR: frontend image not found in ECR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 5: Apply namespace and storage prerequisites
# ---------------------------------------------------------------------------

echo "[5/9] Apply namespace and storage prerequisites"

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/namespace.yaml" \
  || { echo "ERROR: namespace apply failed" >&2; exit 1; }

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
  if kubectl -n "${NAMESPACE}" get pvc "${pvc_name}" >/dev/null 2>&1; then
    echo "  PVC ${pvc_name} exists, skipping apply (immutable storageClassName)"
  else
    echo "  Creating PVC ${pvc_name} from ${manifest}"
    kubectl -n "${NAMESPACE}" apply -f "${manifest}" \
      || { echo "ERROR: PVC ${pvc_name} apply failed" >&2; exit 1; }
  fi
done

# ---------------------------------------------------------------------------
# Step 6: Stage External Secrets and wait for generated secrets
# ---------------------------------------------------------------------------

echo "[6/9] Stage External Secrets resources"

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/external-secrets/secretstore.yaml" \
  || { echo "ERROR: ESO SecretStore apply failed" >&2; exit 1; }

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/external-secrets/mongo-root-external-secret.yaml" \
  || { echo "ERROR: mongo-root-external-secret apply failed" >&2; exit 1; }

kubectl apply -f "${PROJECT_DIR}/k8s-infra-aws-ssm/external-secrets/mongo-app-external-secret.yaml" \
  || { echo "ERROR: mongo-app-external-secret apply failed" >&2; exit 1; }

kubectl -n "${NAMESPACE}" wait externalsecret/mongo-root-secret --for=condition=Ready --timeout=180s \
  || { echo "ERROR: mongo-root-secret ExternalSecret did not become Ready" >&2; exit 1; }

kubectl -n "${NAMESPACE}" wait externalsecret/mongo-app-secret --for=condition=Ready --timeout=180s \
  || { echo "ERROR: mongo-app-secret ExternalSecret did not become Ready" >&2; exit 1; }

wait_for_secret mongo-root-secret
wait_for_secret mongo-app-secret

# ---------------------------------------------------------------------------
# Step 7: Render Kustomize and replace ALB security group placeholders
# ---------------------------------------------------------------------------

echo "[7/9] Render manifests and replace placeholders"

# Copy manifests to temp dir so we can mutate placeholders without touching source
KUSTOMIZE_DIR="$(mktemp -d /tmp/k8s-infra-aws-ssm.XXXXXX)"
cp -r "${PROJECT_DIR}/k8s-infra-aws-ssm/." "${KUSTOMIZE_DIR}/"

# Replace ECR registry placeholder in kustomization
sed -i "s|PLACEHOLDER_ECR_REGISTRY|${ECR_REGISTRY}|g" "${KUSTOMIZE_DIR}/kustomization.yaml"

RENDERED_MANIFEST="$(mktemp /tmp/k8s-infra-aws-ssm.XXXXXX.yaml)"
kubectl kustomize "${KUSTOMIZE_DIR}" > "${RENDERED_MANIFEST}"

python3 - "${RENDERED_MANIFEST}" "${FRONTEND_SG}" "${BACKEND_SG}" "${ACM_CERTIFICATE_ARN}" "${ALB_SUBNET_IDS}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
frontend_sg = sys.argv[2]
backend_sg = sys.argv[3]
acm_arn = sys.argv[4]
alb_subnets = sys.argv[5]
text = path.read_text()
text = text.replace('PLACEHOLDER_FRONTEND_SG,PLACEHOLDER_BACKEND_SG', f'{frontend_sg},{backend_sg}')
text = text.replace('PLACEHOLDER_ACM_CERTIFICATE_ARN', acm_arn)
text = text.replace('PLACEHOLDER_ALB_SUBNET_IDS', alb_subnets)
if 'PLACEHOLDER_' in text:
    remaining = set()
    for line in text.splitlines():
        if 'PLACEHOLDER_' in line:
            remaining.add(line.strip())
    raise SystemExit(f'placeholders remain after render:\n' + '\n'.join(remaining))
path.write_text(text)
PY

rm -rf "${KUSTOMIZE_DIR}"

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

  kubectl -n "${NAMESPACE}" rollout restart deployment/loki \
    || { echo "ERROR: loki rollout restart failed" >&2; exit 1; }

  kubectl -n "${NAMESPACE}" rollout restart deployment/prometheus \
    || { echo "ERROR: prometheus rollout restart failed" >&2; exit 1; }

  kubectl -n "${NAMESPACE}" rollout restart deployment/grafana \
    || { echo "ERROR: grafana rollout restart failed" >&2; exit 1; }

  kubectl -n "${NAMESPACE}" rollout restart daemonset/alloy \
    || { echo "ERROR: alloy rollout restart failed" >&2; exit 1; }
else
  echo "Skipped (FORCE_RESTART != true). Set FORCE_RESTART=true to force pull of latest images."
fi

kubectl -n "${NAMESPACE}" rollout status statefulset/mongo --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/prometheus --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/loki --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status daemonset/alloy --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" rollout status deployment/grafana --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" get pods,svc,pvc

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
echo "Grafana login: admin / admin"
echo "kubectl -n ${NAMESPACE} port-forward svc/grafana 3002:3000"
echo "Open: http://localhost:3002"

echo
echo "++ Prometheus URL:"
echo "kubectl -n ${NAMESPACE} port-forward svc/prometheus 9090:9090"
echo "Open: http://localhost:9090"

echo
echo "++ Loki internal endpoint: http://loki.${NAMESPACE}.svc.cluster.local:3100"
echo "Alloy runs as daemonset/alloy and forwards logs to Loki (no external service)."
