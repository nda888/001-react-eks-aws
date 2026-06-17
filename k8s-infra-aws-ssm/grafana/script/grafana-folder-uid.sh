#!/usr/bin/env bash
set -euo pipefail

MONITOR_NAMESPACE="${MONITOR_NAMESPACE:-monitor}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3002}"
GRAFANA_PARENT_FOLDER_TITLE="${GRAFANA_PARENT_FOLDER_TITLE:-React App}"
GRAFANA_CHILD_FOLDER_TITLE="${GRAFANA_CHILD_FOLDER_TITLE:-Dev}"
GRAFANA_UAT_CHILD_FOLDER_TITLE="${GRAFANA_UAT_CHILD_FOLDER_TITLE:-Uat}"
GRAFANA_LOGS_CHILD_FOLDER_TITLE="${GRAFANA_LOGS_CHILD_FOLDER_TITLE:-Logs}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:?GRAFANA_ADMIN_USER must be set}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD must be set (refusing default)}"
GRAFANA_SERVICE_ACCOUNT_NAME="${GRAFANA_SERVICE_ACCOUNT_NAME:-dashboard-folder-provisioner}"
GRAFANA_SERVICE_ACCOUNT_ROLE="${GRAFANA_SERVICE_ACCOUNT_ROLE:-Admin}"
GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME="${GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME:-dashboard-folder-deploy-token}"
GRAFANA_TOKEN_SECRET_NAME="${GRAFANA_TOKEN_SECRET_NAME:-grafana-folder-api-token}"
GRAFANA_TOKEN_SECRET_KEY="${GRAFANA_TOKEN_SECRET_KEY:-token}"
GRAFANA_URL="http://127.0.0.1:${GRAFANA_LOCAL_PORT}"
FOLDER_API_PATH="/apis/folder.grafana.app/v1/namespaces/default/folders"
PORT_FORWARD_PID=""
PORT_FORWARD_LOG="$(mktemp /tmp/grafana-folder-port-forward.XXXXXX.log)"

log() { echo "INFO: $*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]] && kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  rm -f "${PORT_FORWARD_LOG}"
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null || fail "$1 not found"
}

require_inputs() {
  require_command kubectl
  require_command curl
  require_command python3
  kubectl -n "${MONITOR_NAMESPACE}" get svc/grafana >/dev/null 2>&1 \
    || fail "svc/grafana not found in namespace/${MONITOR_NAMESPACE}"

  [[ -n "${GRAFANA_ADMIN_USER:-}" ]]     || fail "GRAFANA_ADMIN_USER must be set"
  [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] || fail "GRAFANA_ADMIN_PASSWORD must be set"
}

start_port_forward() {
  log "starting Grafana port-forward on localhost:${GRAFANA_LOCAL_PORT}"
  kubectl -n "${MONITOR_NAMESPACE}" port-forward svc/grafana "${GRAFANA_LOCAL_PORT}:3000" >"${PORT_FORWARD_LOG}" 2>&1 &
  PORT_FORWARD_PID="$!"

  for _ in $(seq 1 30); do
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
      fail "Grafana port-forward exited early: $(tr '\n' ' ' < "${PORT_FORWARD_LOG}")"
    fi
    if curl -fsS "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
      log "Grafana API reachable"
      return 0
    fi
    sleep 1
  done

  fail "Grafana API not reachable through localhost:${GRAFANA_LOCAL_PORT}"
}

validate_bearer_token() {
  local token="$1"
  [[ -n "${token}" ]] || return 1
  curl -fsS -H "Authorization: Bearer ${token}" "${GRAFANA_URL}${FOLDER_API_PATH}" >/dev/null 2>&1
}

read_saved_token_secret() {
  kubectl -n "${MONITOR_NAMESPACE}" get secret "${GRAFANA_TOKEN_SECRET_NAME}" \
    -o "jsonpath={.data.${GRAFANA_TOKEN_SECRET_KEY}}" 2>/dev/null \
    | python3 -c 'import base64,sys; data=sys.stdin.read().strip(); print(base64.b64decode(data).decode() if data else "")'
}

save_token_secret() {
  local token="$1"
  kubectl -n "${MONITOR_NAMESPACE}" create secret generic "${GRAFANA_TOKEN_SECRET_NAME}" \
    --from-literal="${GRAFANA_TOKEN_SECRET_KEY}=${token}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

delete_invalid_token_secret() {
  kubectl -n "${MONITOR_NAMESPACE}" delete secret "${GRAFANA_TOKEN_SECRET_NAME}" --ignore-not-found >/dev/null
}

admin_get() {
  curl -fsS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "${GRAFANA_URL}$1"
}

admin_post_json() {
  local path="$1"
  local body_file="$2"
  curl -fsS \
    -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary "@${body_file}" \
    "${GRAFANA_URL}${path}"
}

validate_admin_credentials() {
  admin_get "/api/user" >/dev/null 2>&1 \
    || fail "Grafana admin credentials invalid; verify GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD are correct"
}

find_service_account_id() {
  local response_file search_query
  response_file="$(mktemp /tmp/grafana-service-account-search.XXXXXX.json)"
  search_query="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${GRAFANA_SERVICE_ACCOUNT_NAME}")"
  admin_get "/api/serviceaccounts/search?query=${search_query}" >"${response_file}"
  python3 - "${GRAFANA_SERVICE_ACCOUNT_NAME}" "${response_file}" <<'PY'
import json
import sys

name, response_path = sys.argv[1:3]
with open(response_path) as fh:
    payload = json.load(fh)
items = payload.get("serviceAccounts") or payload.get("serviceaccounts") or payload.get("items") or []
for item in items:
    if item.get("name") == name:
        print(item.get("id"))
        break
PY
  rm -f "${response_file}"
}

create_service_account() {
  local body_file response_file
  body_file="$(mktemp /tmp/grafana-service-account.XXXXXX.json)"
  response_file="$(mktemp /tmp/grafana-service-account-response.XXXXXX.json)"
  python3 - "${GRAFANA_SERVICE_ACCOUNT_NAME}" "${GRAFANA_SERVICE_ACCOUNT_ROLE}" "${body_file}" <<'PY'
import json
import sys

name, role, path = sys.argv[1:4]
with open(path, "w") as fh:
    json.dump({"name": name, "role": role}, fh)
PY
  admin_post_json "/api/serviceaccounts" "${body_file}" >"${response_file}" \
    || fail "failed to create Grafana service account"
  rm -f "${body_file}"
  python3 - "${response_file}" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    payload = json.load(fh)
print(payload.get("id") or payload.get("serviceAccount", {}).get("id") or "")
PY
  rm -f "${response_file}"
}

create_service_account_token() {
  local service_account_id="$1"
  local body_file response_file
  body_file="$(mktemp /tmp/grafana-service-token.XXXXXX.json)"
  response_file="$(mktemp /tmp/grafana-service-token-response.XXXXXX.json)"
  python3 - "${GRAFANA_SERVICE_ACCOUNT_TOKEN_NAME}" "${body_file}" <<'PY'
import json
import sys

name, path = sys.argv[1:3]
with open(path, "w") as fh:
    json.dump({"name": name}, fh)
PY
  admin_post_json "/api/serviceaccounts/${service_account_id}/tokens" "${body_file}" >"${response_file}" \
    || { rm -f "${body_file}" "${response_file}"; fail "failed to create Grafana service account token"; }
  rm -f "${body_file}"
  local parsed_token parse_status
  set +e
  parsed_token="$(python3 - "${response_file}" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    payload = json.load(fh)
print(payload.get("key") or payload.get("token") or "")
PY
)"
  parse_status="$?"
  set -e
  rm -f "${response_file}"
  [[ "${parse_status}" -eq 0 ]] || fail "failed to parse Grafana service account token response"
  printf '%s\n' "${parsed_token}"
}

bootstrap_token_from_admin() {
  local service_account_id token
  validate_admin_credentials
  service_account_id="$(find_service_account_id)"
  if [[ -z "${service_account_id}" ]]; then
    log "creating Grafana service account ${GRAFANA_SERVICE_ACCOUNT_NAME}"
    service_account_id="$(create_service_account)"
  else
    log "found Grafana service account ${GRAFANA_SERVICE_ACCOUNT_NAME}"
  fi
  [[ -n "${service_account_id}" ]] || fail "Grafana service account id not found"

  token="$(create_service_account_token "${service_account_id}")"
  [[ -n "${token}" ]] || fail "Grafana service account token was empty"
  validate_bearer_token "${token}" || fail "created Grafana service account token failed validation"
  save_token_secret "${token}"
  log "saved Grafana API token to secret ${MONITOR_NAMESPACE}/${GRAFANA_TOKEN_SECRET_NAME}"
  printf '%s\n' "${token}"
}

get_valid_grafana_token() {
  local saved_token
  if [[ -n "${GRAFANA_API_TOKEN:-}" ]]; then
    validate_bearer_token "${GRAFANA_API_TOKEN}" \
      || fail "GRAFANA_API_TOKEN is invalid or lacks folder API permission"
    log "using Grafana API token from environment"
    printf '%s\n' "${GRAFANA_API_TOKEN}"
    return 0
  fi

  saved_token="$(read_saved_token_secret)"
  if [[ -n "${saved_token}" ]]; then
    if validate_bearer_token "${saved_token}"; then
      log "using Grafana API token from secret ${MONITOR_NAMESPACE}/${GRAFANA_TOKEN_SECRET_NAME}"
      printf '%s\n' "${saved_token}"
      return 0
    fi
    log "saved Grafana API token invalid; replacing secret"
    delete_invalid_token_secret
  fi

  bootstrap_token_from_admin
}

grafana_get() {
  local token="$1"
  local path="$2"
  curl -fsS -H "Authorization: Bearer ${token}" "${GRAFANA_URL}${path}"
}

grafana_post_json() {
  local token="$1"
  local body_file="$2"
  curl -fsS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary "@${body_file}" \
    "${GRAFANA_URL}${FOLDER_API_PATH}"
}

folder_uid_by_title_and_parent() {
  local title="$1"
  local parent_uid="$2"
  local folders_file="$3"
  python3 - "${title}" "${parent_uid}" "${folders_file}" <<'PY'
import json
import sys

title, parent_uid, folders_path = sys.argv[1:4]
with open(folders_path) as fh:
    payload = json.load(fh)
if isinstance(payload, list):
    items = payload
elif isinstance(payload, dict):
    items = payload.get("items", [])
else:
    items = []
matches = []
for item in items:
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    annotations = metadata.get("annotations") or {}
    item_title = spec.get("title") or item.get("title")
    item_uid = metadata.get("name") or item.get("uid")
    item_parent = annotations.get("grafana.app/folder") or item.get("parentUid") or ""
    if item_title == title and item_parent == parent_uid:
        matches.append(item_uid)
if len(matches) > 1:
    raise SystemExit(f"ambiguous folder title={title!r} parent={parent_uid!r}: {matches}")
if matches:
    print(matches[0])
PY
}

create_folder() {
  local token="$1"
  local title="$2"
  local generate_name="$3"
  local parent_uid="$4"
  local body_file response_file
  body_file="$(mktemp /tmp/grafana-folder-create.XXXXXX.json)"
  response_file="$(mktemp /tmp/grafana-folder-response.XXXXXX.json)"

  python3 - "${title}" "${generate_name}" "${parent_uid}" "${body_file}" <<'PY'
import json
import sys

title, generate_name, parent_uid, body_path = sys.argv[1:5]
metadata = {"generateName": generate_name}
if parent_uid:
    metadata["annotations"] = {"grafana.app/folder": parent_uid}
body = {"metadata": metadata, "spec": {"title": title}}
with open(body_path, "w") as fh:
    json.dump(body, fh)
PY

  grafana_post_json "${token}" "${body_file}" >"${response_file}" \
    || fail "failed to create Grafana folder ${title}"
  rm -f "${body_file}"
  python3 - "${response_file}" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    payload = json.load(fh)
uid = payload.get("metadata", {}).get("name") or payload.get("uid")
if not uid:
    raise SystemExit("created folder response did not include UID")
print(uid)
PY
  rm -f "${response_file}"
}

ensure_folder_tree() {
  local token="$1"
  local folders_file parent_uid dev_child_uid uat_child_uid logs_child_uid
  folders_file="$(mktemp /tmp/grafana-folders.XXXXXX.json)"
  grafana_get "${token}" "${FOLDER_API_PATH}" >"${folders_file}"

  parent_uid="$(folder_uid_by_title_and_parent "${GRAFANA_PARENT_FOLDER_TITLE}" "" "${folders_file}")"
  if [[ -z "${parent_uid}" ]]; then
    log "creating parent folder ${GRAFANA_PARENT_FOLDER_TITLE}"
    parent_uid="$(create_folder "${token}" "${GRAFANA_PARENT_FOLDER_TITLE}" "react-app-" "")"
  else
    log "found parent folder ${GRAFANA_PARENT_FOLDER_TITLE}"
  fi

  grafana_get "${token}" "${FOLDER_API_PATH}" >"${folders_file}"
  dev_child_uid="$(folder_uid_by_title_and_parent "${GRAFANA_CHILD_FOLDER_TITLE}" "${parent_uid}" "${folders_file}")"
  if [[ -z "${dev_child_uid}" ]]; then
    log "creating child folder ${GRAFANA_CHILD_FOLDER_TITLE} under ${GRAFANA_PARENT_FOLDER_TITLE}"
    dev_child_uid="$(create_folder "${token}" "${GRAFANA_CHILD_FOLDER_TITLE}" "dev-" "${parent_uid}")"
  else
    log "found child folder ${GRAFANA_CHILD_FOLDER_TITLE}"
  fi

  grafana_get "${token}" "${FOLDER_API_PATH}" >"${folders_file}"
  uat_child_uid="$(folder_uid_by_title_and_parent "${GRAFANA_UAT_CHILD_FOLDER_TITLE}" "${parent_uid}" "${folders_file}")"
  if [[ -z "${uat_child_uid}" ]]; then
    log "creating child folder ${GRAFANA_UAT_CHILD_FOLDER_TITLE} under ${GRAFANA_PARENT_FOLDER_TITLE}"
    uat_child_uid="$(create_folder "${token}" "${GRAFANA_UAT_CHILD_FOLDER_TITLE}" "uat-" "${parent_uid}")"
  else
    log "found child folder ${GRAFANA_UAT_CHILD_FOLDER_TITLE}"
  fi

  grafana_get "${token}" "${FOLDER_API_PATH}" >"${folders_file}"
  logs_child_uid="$(folder_uid_by_title_and_parent "${GRAFANA_LOGS_CHILD_FOLDER_TITLE}" "${parent_uid}" "${folders_file}")"
  if [[ -z "${logs_child_uid}" ]]; then
    log "creating child folder ${GRAFANA_LOGS_CHILD_FOLDER_TITLE} under ${GRAFANA_PARENT_FOLDER_TITLE}"
    logs_child_uid="$(create_folder "${token}" "${GRAFANA_LOGS_CHILD_FOLDER_TITLE}" "react-app-logs-" "${parent_uid}")"
  else
    log "found child folder ${GRAFANA_LOGS_CHILD_FOLDER_TITLE}"
  fi

  rm -f "${folders_file}"
  printf 'DEV_FOLDER_UID=%s\n' "${dev_child_uid}"
  printf 'UAT_FOLDER_UID=%s\n' "${uat_child_uid}"
  printf 'LOGS_FOLDER_UID=%s\n' "${logs_child_uid}"
}

main() {
  local token
  require_inputs
  start_port_forward
  token="$(get_valid_grafana_token)"
  ensure_folder_tree "${token}"
}

main "$@"
