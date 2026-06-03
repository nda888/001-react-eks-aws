#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

NAMESPACE="${NAMESPACE:-dev}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-${PROJECT_DIR}/k8s-infra-aws-ssm}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
RESTART_GRAFANA="${RESTART_GRAFANA:-true}"

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "ERROR: yq not found" >&2; exit 1; }

if [[ ! -f "${KUSTOMIZE_DIR}/kustomization.yaml" ]]; then
  echo "ERROR: kustomization.yaml not found under ${KUSTOMIZE_DIR}" >&2
  exit 1
fi

RENDERED_MANIFEST="$(mktemp)"
FILTERED_MANIFEST="$(mktemp)"
cleanup() {
  rm -f "${RENDERED_MANIFEST}" "${FILTERED_MANIFEST}"
}
trap cleanup EXIT

echo "[1/4] Render Kustomize: ${KUSTOMIZE_DIR}"
kubectl kustomize "${KUSTOMIZE_DIR}" >"${RENDERED_MANIFEST}"

echo "[2/4] Filter Grafana dashboard ConfigMaps"
yq -y 'select(.kind == "ConfigMap" and (.metadata.name == "grafana-dashboard-provider" or .metadata.name == "grafana-dashboards"))' \
  "${RENDERED_MANIFEST}" >"${FILTERED_MANIFEST}"

for configmap_name in grafana-dashboard-provider grafana-dashboards; do
  if ! yq -e "select(.kind == \"ConfigMap\" and .metadata.name == \"${configmap_name}\")" "${FILTERED_MANIFEST}" >/dev/null; then
    echo "ERROR: rendered Grafana ConfigMap missing: ${configmap_name}" >&2
    exit 1
  fi
done

echo "[3/4] Apply Grafana dashboard ConfigMaps only"
kubectl apply -f "${FILTERED_MANIFEST}"

if [[ "${RESTART_GRAFANA}" == "true" ]]; then
  echo "[4/4] Restart Grafana deployment"
  kubectl -n "${NAMESPACE}" rollout restart deploy/grafana
  kubectl -n "${NAMESPACE}" rollout status deploy/grafana --timeout="${ROLLOUT_TIMEOUT}"
else
  echo "[4/4] Skip Grafana restart because RESTART_GRAFANA=${RESTART_GRAFANA}"
fi

echo "Applied dashboard keys:"
kubectl -n "${NAMESPACE}" get configmap grafana-dashboards -o json | yq '.data | keys | .[]'
