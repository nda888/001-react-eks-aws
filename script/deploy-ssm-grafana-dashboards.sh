#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

NAMESPACE="${NAMESPACE:-monitor}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-${PROJECT_DIR}/k8s-infra-aws-ssm}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
RESTART_GRAFANA="${RESTART_GRAFANA:-true}"
DEV_FOLDER_UID="${DEV_FOLDER_UID:-}"
UAT_FOLDER_UID="${UAT_FOLDER_UID:-}"
PROD_FOLDER_UID="${PROD_FOLDER_UID:-}"

GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3002}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
GRAFANA_SERVICE_ACCOUNT_NAME="${GRAFANA_SERVICE_ACCOUNT_NAME:-dashboard-folder-provisioner}"
GRAFANA_SERVICE_ACCOUNT_ROLE="${GRAFANA_SERVICE_ACCOUNT_ROLE:-Admin}"
GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME="${GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME:-dashboard-folder-deploy-token}"
GRAFANA_TOKEN_SECRET_NAME="${GRAFANA_TOKEN_SECRET_NAME:-grafana-folder-api-token}"
GRAFANA_TOKEN_SECRET_KEY="${GRAFANA_TOKEN_SECRET_KEY:-token}"
GRAFANA_PARENT_FOLDER_TITLE="${GRAFANA_PARENT_FOLDER_TITLE:-React App}"
GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE:-Dev}"
GRAFANA_UAT_CHILD_FOLDER_TITLE="${GRAFANA_UAT_CHILD_FOLDER_TITLE:-Uat}"
GRAFANA_PROD_CHILD_FOLDER_TITLE="${GRAFANA_PROD_CHILD_FOLDER_TITLE:-Prod}"
GRAFANA_LOGS_CHILD_FOLDER_TITLE="${GRAFANA_LOGS_CHILD_FOLDER_TITLE:-Logs}"
LOGS_FOLDER_UID="${LOGS_FOLDER_UID:-}"

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "ERROR: yq not found" >&2; exit 1; }

if [[ ! -f "${KUSTOMIZE_DIR}/kustomization.yaml" ]]; then
  echo "ERROR: kustomization.yaml not found under ${KUSTOMIZE_DIR}" >&2
  exit 1
fi

ensure_grafana_folder_uids() {
  local helper_script="${SCRIPT_DIR}/../k8s-infra-aws-ssm/grafana/script/grafana-folder-uid.sh"
  local folder_output

  [[ -x "${helper_script}" ]] \
    || { echo "ERROR: grafana-folder-uid.sh missing or not executable: ${helper_script}" >&2; exit 1; }

  echo "[1/5] Resolve Grafana folder UIDs (React App > Dev / Uat / Logs)"
  folder_output="$(
    MONITOR_NAMESPACE="${NAMESPACE}" \
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
    GRAFANA_UAT_CHILD_FOLDER_TITLE="${GRAFANA_UAT_CHILD_FOLDER_TITLE}" \
    GRAFANA_PROD_CHILD_FOLDER_TITLE="${GRAFANA_PROD_CHILD_FOLDER_TITLE}" \
    GRAFANA_LOGS_CHILD_FOLDER_TITLE="${GRAFANA_LOGS_CHILD_FOLDER_TITLE}" \
      "${helper_script}"
  )" || { echo "ERROR: Grafana folder UID resolution failed" >&2; exit 1; }

  DEV_FOLDER_UID="$(echo "${folder_output}" | grep '^DEV_FOLDER_UID=' | cut -d= -f2)"
  UAT_FOLDER_UID="$(echo "${folder_output}" | grep '^UAT_FOLDER_UID=' | cut -d= -f2)"
  PROD_FOLDER_UID="$(echo "${folder_output}" | grep '^PROD_FOLDER_UID=' | cut -d= -f2)"
  LOGS_FOLDER_UID="$(echo "${folder_output}" | grep '^LOGS_FOLDER_UID=' | cut -d= -f2)"
}

ensure_grafana_folder_uids

RENDERED_MANIFEST="$(mktemp)"
FILTERED_MANIFEST="$(mktemp)"
cleanup() {
  rm -f "${RENDERED_MANIFEST}" "${FILTERED_MANIFEST}"
}
trap cleanup EXIT

echo "[2/5] Render Kustomize: ${KUSTOMIZE_DIR}"
kubectl kustomize "${KUSTOMIZE_DIR}" >"${RENDERED_MANIFEST}"

if [[ -n "${DEV_FOLDER_UID}" ]]; then
  echo "Replacing PLACEHOLDER_DEV_FOLDER_UID with ${DEV_FOLDER_UID}"
  sed -i "s/PLACEHOLDER_DEV_FOLDER_UID/${DEV_FOLDER_UID}/g" "${RENDERED_MANIFEST}"
fi
if [[ -n "${UAT_FOLDER_UID}" ]]; then
  echo "Replacing PLACEHOLDER_UAT_FOLDER_UID with ${UAT_FOLDER_UID}"
  sed -i "s/PLACEHOLDER_UAT_FOLDER_UID/${UAT_FOLDER_UID}/g" "${RENDERED_MANIFEST}"
fi
if [[ -n "${PROD_FOLDER_UID}" ]]; then
  echo "Replacing PLACEHOLDER_PROD_FOLDER_UID with ${PROD_FOLDER_UID}"
  sed -i "s/PLACEHOLDER_PROD_FOLDER_UID/${PROD_FOLDER_UID}/g" "${RENDERED_MANIFEST}"
fi
if [[ -n "${LOGS_FOLDER_UID}" ]]; then
  echo "Replacing PLACEHOLDER_LOGS_FOLDER_UID with ${LOGS_FOLDER_UID}"
  sed -i "s/PLACEHOLDER_LOGS_FOLDER_UID/${LOGS_FOLDER_UID}/g" "${RENDERED_MANIFEST}"
fi

echo "[3/5] Filter Grafana dashboard ConfigMaps"
yq -y 'select(.kind == "ConfigMap" and (.metadata.name == "grafana-dashboard-provider" or .metadata.name == "grafana-dashboards" or .metadata.name == "grafana-uat-dashboards" or .metadata.name == "grafana-prod-dashboards"))' \
  "${RENDERED_MANIFEST}" >"${FILTERED_MANIFEST}"

for configmap_name in grafana-dashboard-provider grafana-dashboards; do
  if ! yq -s -e "any(.[]; .kind == \"ConfigMap\" and .metadata.name == \"${configmap_name}\")" "${FILTERED_MANIFEST}" >/dev/null; then
    echo "ERROR: rendered Grafana ConfigMap missing: ${configmap_name}" >&2
    exit 1
  fi
done

if yq -s -e "any(.[]; .kind == \"ConfigMap\" and .metadata.namespace != \"${NAMESPACE}\")" "${FILTERED_MANIFEST}" >/dev/null; then
  echo "ERROR: rendered Grafana ConfigMap namespace does not match NAMESPACE=${NAMESPACE}" >&2
  yq -r 'select(.kind == "ConfigMap") | "- " + .metadata.name + ": " + (.metadata.namespace // "<missing>")' "${FILTERED_MANIFEST}" >&2
  exit 1
fi

echo "[4/5] Apply Grafana dashboard ConfigMaps only"
kubectl apply -f "${FILTERED_MANIFEST}"

if [[ "${RESTART_GRAFANA}" == "true" ]]; then
  echo "[5/5] Restart Grafana deployment"
  kubectl -n "${NAMESPACE}" rollout restart deploy/grafana
  kubectl -n "${NAMESPACE}" rollout status deploy/grafana --timeout="${ROLLOUT_TIMEOUT}"
else
  echo "[5/5] Skip Grafana restart because RESTART_GRAFANA=${RESTART_GRAFANA}"
fi

echo "Applied dashboard keys:"
kubectl -n "${NAMESPACE}" get configmap grafana-dashboards -o json | yq '.data | keys | .[]'
if kubectl -n "${NAMESPACE}" get configmap grafana-uat-dashboards >/dev/null 2>&1; then
  echo "Applied UAT dashboard keys:"
  kubectl -n "${NAMESPACE}" get configmap grafana-uat-dashboards -o json | yq '.data | keys | .[]'
fi
if kubectl -n "${NAMESPACE}" get configmap grafana-prod-dashboards >/dev/null 2>&1; then
  echo "Applied Prod dashboard keys:"
  kubectl -n "${NAMESPACE}" get configmap grafana-prod-dashboards -o json | yq '.data | keys | .[]'
fi
