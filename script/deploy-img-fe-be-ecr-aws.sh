#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"

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
BACKEND_IMAGE="${ECR_REGISTRY}/dev-demo-backend:latest"
FRONTEND_IMAGE="${ECR_REGISTRY}/dev-demo-frontend:latest"

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
  --repository-name dev-demo-backend \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt}' \
  --output table \
  || { echo "ERROR: backend image not found in ECR" >&2; exit 1; }

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name dev-demo-frontend \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt}' \
  --output table \
  || { echo "ERROR: frontend image not found in ECR" >&2; exit 1; }

echo
echo "Images pushed:"
echo "  ${BACKEND_IMAGE}"
echo "  ${FRONTEND_IMAGE}"
