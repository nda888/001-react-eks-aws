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
  echo "==> Pushing frontend+backend ECR images ALL environments: dev, then uat"
  "${BASH_SOURCE[0]}" dev "$@"
  "${BASH_SOURCE[0]}" uat "$@"
  echo "==> ALL environments ECR images pushed (dev + uat)"
  exit 0
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"

case "${ENV}" in
  dev)
    BACKEND_REPO="dev-demo-backend"
    FRONTEND_REPO="dev-demo-frontend"
    ;;
  uat)
    BACKEND_REPO="uat-demo-backend"
    FRONTEND_REPO="uat-demo-frontend"
    ;;
esac

command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }

aws sts get-caller-identity >/dev/null \
  || { echo "ERROR: AWS credentials not configured" >&2; exit 1; }

[[ -z "${AWS_ACCOUNT_ID}" ]] && AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

docker buildx version >/dev/null 2>&1 \
  || { echo "ERROR: docker buildx not available" >&2; exit 1; }

[[ -n "${PROJECT_DIR}" && -d "${PROJECT_DIR}" ]] \
  || { echo "ERROR: PROJECT_DIR invalid or missing" >&2; exit 1; }
[[ -d "${PROJECT_DIR}/src/backend" ]] \
  || { echo "ERROR: src/backend directory not found" >&2; exit 1; }
[[ -d "${PROJECT_DIR}/src/frontend" ]] \
  || { echo "ERROR: src/frontend directory not found" >&2; exit 1; }

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_IMAGE="${ECR_REGISTRY}/${BACKEND_REPO}:latest"
FRONTEND_IMAGE="${ECR_REGISTRY}/${FRONTEND_REPO}:latest"

echo "[1/4] Login to ECR"

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}" \
  || { echo "ERROR: ECR login failed" >&2; exit 1; }

echo "[2/4] Build and push backend image"

docker buildx build \
  --platform linux/arm64 \
  --push \
  --provenance=false \
  -t "${BACKEND_IMAGE}" \
  --target development \
  "${PROJECT_DIR}/src/backend" \
  || { echo "ERROR: backend image build/push failed" >&2; exit 1; }

echo "[3/4] Build and push frontend image"

docker buildx build \
  --platform linux/arm64 \
  --push \
  --provenance=false \
  -t "${FRONTEND_IMAGE}" \
  --target development \
  "${PROJECT_DIR}/src/frontend" \
  || { echo "ERROR: frontend image build/push failed" >&2; exit 1; }

echo "[4/4] Verify images in ECR"

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${BACKEND_REPO}" \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt}' \
  --output table \
  || { echo "ERROR: backend image not found in ECR" >&2; exit 1; }

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${FRONTEND_REPO}" \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt}' \
  --output table \
  || { echo "ERROR: frontend image not found in ECR" >&2; exit 1; }

echo
echo "Images pushed:"
echo "  ${BACKEND_IMAGE}"
echo "  ${FRONTEND_IMAGE}"
