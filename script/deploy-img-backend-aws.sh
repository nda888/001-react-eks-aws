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

if [[ "${ENV}" == "all" ]]; then
  echo "==> Deploying backend ALL environments: dev, then uat"
  "${BASH_SOURCE[0]}" dev "$@"
  "${BASH_SOURCE[0]}" uat "$@"
  echo "==> ALL environments backend deployed (dev + uat)"
  exit 0
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
PLATFORM="${PLATFORM:-linux/arm64}"

case "${ENV}" in
  dev)
    EKS_CLUSTER="${EKS_CLUSTER:-demo-eks-dev}"
    NAMESPACE="${NAMESPACE:-dev}"
    REPOSITORY_NAME="${BACKEND_REPOSITORY_NAME:-dev-demo-backend}"
    ;;
  uat)
    EKS_CLUSTER="${EKS_CLUSTER:-demo-eks-dev}"
    NAMESPACE="${NAMESPACE:-uat}"
    REPOSITORY_NAME="${BACKEND_REPOSITORY_NAME:-uat-demo-backend}"
    ;;
esac

command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }

aws sts get-caller-identity >/dev/null \
  || { echo "ERROR: AWS credentials not configured" >&2; exit 1; }

[[ -z "${AWS_ACCOUNT_ID}" ]] && AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

docker buildx version >/dev/null 2>&1 \
  || { echo "ERROR: docker buildx not available" >&2; exit 1; }

[[ -n "${PROJECT_DIR}" && -d "${PROJECT_DIR}" ]] \
  || { echo "ERROR: PROJECT_DIR invalid or missing" >&2; exit 1; }
[[ -d "${PROJECT_DIR}/src/backend" ]] \
  || { echo "ERROR: src/backend directory not found" >&2; exit 1; }
[[ -f "${PROJECT_DIR}/src/backend/Dockerfile" ]] \
  || { echo "ERROR: src/backend/Dockerfile not found" >&2; exit 1; }

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_IMAGE="${ECR_REGISTRY}/${REPOSITORY_NAME}:${IMAGE_TAG}"

echo "[1/5] Login to ECR"

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}" \
  || { echo "ERROR: ECR login failed" >&2; exit 1; }

echo
echo "[2/5] Build and push backend image"

docker buildx build \
  --platform "${PLATFORM}" \
  --push \
  --provenance=false \
  -t "${BACKEND_IMAGE}" \
  --target development \
  "${PROJECT_DIR}/src/backend" \
  || { echo "ERROR: backend image build/push failed" >&2; exit 1; }

echo
echo "[3/5] Verify backend image in ECR"

IMAGE_DIGEST="$(aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"

[[ -n "${IMAGE_DIGEST}" && "${IMAGE_DIGEST}" != "None" ]] \
  || { echo "ERROR: backend image digest not found in ECR" >&2; exit 1; }

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${IMAGE_TAG}" \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt,digest:imageDigest}' \
  --output table

echo
echo "[4/5] Update kubeconfig and restart backend"

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER}" \
  || { echo "ERROR: kubeconfig update failed" >&2; exit 1; }

kubectl -n "${NAMESPACE}" set image \
  deployment/backend \
  backend="${ECR_REGISTRY}/${REPOSITORY_NAME}@${IMAGE_DIGEST}" \
  || { echo "ERROR: backend image update failed" >&2; exit 1; }

kubectl -n "${NAMESPACE}" rollout restart deployment/backend \
  || { echo "ERROR: backend rollout restart failed" >&2; exit 1; }

echo
echo "[5/5] Wait for backend rollout"

kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" get pods -l app=backend -o wide

echo
echo "Backend deployed: ${ECR_REGISTRY}/${REPOSITORY_NAME}@${IMAGE_DIGEST}"
echo "Backend API port-forward: kubectl -n ${NAMESPACE} port-forward svc/backend 3001:3000"
