#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
EKS_CLUSTER="${EKS_CLUSTER:-demo-eks-dev}"
NAMESPACE="${NAMESPACE:-dev}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
REPOSITORY_NAME="${FRONTEND_REPOSITORY_NAME:-dev-demo-frontend}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
PLATFORM="${PLATFORM:-linux/arm64}"

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
[[ -d "${PROJECT_DIR}/src/frontend" ]] \
  || { echo "ERROR: src/frontend directory not found" >&2; exit 1; }
[[ -f "${PROJECT_DIR}/src/frontend/Dockerfile" ]] \
  || { echo "ERROR: src/frontend/Dockerfile not found" >&2; exit 1; }

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
FRONTEND_IMAGE="${ECR_REGISTRY}/${REPOSITORY_NAME}:${IMAGE_TAG}"

echo "[1/5] Login to ECR"

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}" \
  || { echo "ERROR: ECR login failed" >&2; exit 1; }

echo
echo "[2/5] Build and push frontend image"

docker buildx build \
  --platform "${PLATFORM}" \
  --push \
  --provenance=false \
  -t "${FRONTEND_IMAGE}" \
  --target development \
  "${PROJECT_DIR}/src/frontend" \
  || { echo "ERROR: frontend image build/push failed" >&2; exit 1; }

echo
echo "[3/5] Verify frontend image in ECR"

IMAGE_DIGEST="$(aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"

[[ -n "${IMAGE_DIGEST}" && "${IMAGE_DIGEST}" != "None" ]] \
  || { echo "ERROR: frontend image digest not found in ECR" >&2; exit 1; }

aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${IMAGE_TAG}" \
  --query 'imageDetails[0].{repository:repositoryName,tag:imageTags[0],pushedAt:imagePushedAt,digest:imageDigest}' \
  --output table

echo
echo "[4/5] Update kubeconfig and restart frontend"

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER}" \
  || { echo "ERROR: kubeconfig update failed" >&2; exit 1; }

kubectl -n "${NAMESPACE}" set image \
  deployment/frontend \
  frontend="${ECR_REGISTRY}/${REPOSITORY_NAME}@${IMAGE_DIGEST}" \
  || { echo "ERROR: frontend image update failed" >&2; exit 1; }

kubectl -n "${NAMESPACE}" rollout restart deployment/frontend \
  || { echo "ERROR: frontend rollout restart failed" >&2; exit 1; }

echo
echo "[5/5] Wait for frontend rollout"

kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout "${ROLLOUT_TIMEOUT}"
kubectl -n "${NAMESPACE}" get pods -l app=frontend -o wide

echo
echo "Frontend deployed: ${ECR_REGISTRY}/${REPOSITORY_NAME}@${IMAGE_DIGEST}"
echo "Frontend URL: kubectl -n ${NAMESPACE} port-forward svc/frontend 3000:3000"
echo "Open: http://localhost:3000"
