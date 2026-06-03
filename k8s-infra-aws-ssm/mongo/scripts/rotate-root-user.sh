#!/bin/bash
set -euo pipefail

# --- Install tools if missing ---
if ! command -v aws >/dev/null 2>&1; then
  echo "[rotate-root] Installing aws-cli..."
  apt-get update -qq -y >/dev/null 2>&1
  apt-get install -qq -y curl unzip >/dev/null 2>&1
  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ]; then
    AWS_ARCH="aarch64"
  else
    AWS_ARCH="x86_64"
  fi
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[rotate-root] Installing kubectl..."
  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ]; then
    K8S_ARCH="arm64"
  else
    K8S_ARCH="amd64"
  fi
  curl -sSL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${K8S_ARCH}/kubectl" -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
fi

# --- Constants ---
SSM_PREFIX="${SSM_PREFIX:-/demo-eks-dev/mongo}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-dev}"
MONGO_HOST="${MONGO_HOST:-mongo:27017}"
FORCE_REFRESH_CMD='{"metadata":{"annotations":{"external-secrets.io/last-refresh":"'$(date +%s)'"}}}'

OLD_PASSWORD="${MONGO_INITDB_ROOT_PASSWORD}"
NEW_PASSWORD="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)"

echo "[rotate-root] Starting Mongo root password rotation"

# --- Preflight: verify app-user rotation is not still running ---
ACTIVE_APP_ROTATION_JOBS="$(kubectl -n "${NAMESPACE}" get jobs \
  -l batch.kubernetes.io/cronjob-name=rotate-mongo-app-user \
  -o jsonpath='{range .items[?(@.status.active>0)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -z "${ACTIVE_APP_ROTATION_JOBS}" ]; then
  ACTIVE_APP_ROTATION_JOBS="$(kubectl -n "${NAMESPACE}" get jobs \
    -l cronjob-name=rotate-mongo-app-user \
    -o jsonpath='{range .items[?(@.status.active>0)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
fi
if [ -n "${ACTIVE_APP_ROTATION_JOBS}" ]; then
  echo "[rotate-root] ERROR: App-user rotation job still exists. Skipping root rotation."
  exit 1
fi

# --- Preflight: verify AWS SSM write access ---
if ! aws ssm get-parameter \
  --name "${SSM_PREFIX}/root_password" \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "[rotate-root] WARNING: Cannot read current root_password from SSM. Proceeding anyway."
fi

# --- Step 1: Change Mongo root password ---
echo "[rotate-root] Updating MongoDB root password"
mongosh "mongodb://${MONGO_INITDB_ROOT_USERNAME}:${OLD_PASSWORD}@${MONGO_HOST}/admin" \
  --quiet --eval "
    const adminDb = db.getSiblingDB('admin');
    adminDb.updateUser('${MONGO_INITDB_ROOT_USERNAME}', {
      pwd: '${NEW_PASSWORD}',
      roles: [{ role: 'root', db: 'admin' }]
    });
  " || { echo "[rotate-root] ERROR: MongoDB root password update failed"; exit 1; }

echo "[rotate-root] MongoDB root password updated"

# --- Step 2: Update SSM root_password. Rollback Mongo if this fails ---
if ! aws ssm put-parameter \
  --name "${SSM_PREFIX}/root_password" \
  --value "${NEW_PASSWORD}" \
  --type SecureString \
  --overwrite \
  --region "${AWS_REGION}" >/dev/null; then
  echo "[rotate-root] ERROR: SSM root_password update failed. Attempting Mongo rollback."
  mongosh "mongodb://${MONGO_INITDB_ROOT_USERNAME}:${NEW_PASSWORD}@${MONGO_HOST}/admin" \
    --quiet --eval "
      const adminDb = db.getSiblingDB('admin');
      adminDb.updateUser('${MONGO_INITDB_ROOT_USERNAME}', {
        pwd: '${OLD_PASSWORD}',
        roles: [{ role: 'root', db: 'admin' }]
      });
    " || true
  exit 1
fi

echo "[rotate-root] SSM root_password updated"

# --- Step 3: Force ESO refresh and wait for Kubernetes Secret sync ---
echo "[rotate-root] Patching ExternalSecret for immediate refresh"
kubectl -n "${NAMESPACE}" patch externalsecret mongo-root-secret \
  --type merge -p "${FORCE_REFRESH_CMD}" >/dev/null \
  || { echo "[rotate-root] ERROR: ExternalSecret patch failed"; exit 1; }

echo "[rotate-root] Waiting for mongo-root-secret to sync..."
SYNCED=false
for i in $(seq 1 60); do
  CURRENT_PASS=$(kubectl -n "${NAMESPACE}" get secret mongo-root-secret \
    -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [ -n "${CURRENT_PASS}" ] && [ "${CURRENT_PASS}" = "${NEW_PASSWORD}" ]; then
    SYNCED=true
    echo "[rotate-root] mongo-root-secret synced"
    break
  fi
  sleep 5
done

# --- Step 4: Verify new root password works ---
echo "[rotate-root] Verifying new root password"
mongosh "mongodb://${MONGO_INITDB_ROOT_USERNAME}:${NEW_PASSWORD}@${MONGO_HOST}/admin" \
  --quiet --eval "db.runCommand({ ping: 1 })" \
  || { echo "[rotate-root] ERROR: New root password verification failed"; exit 1; }

if [ "${SYNCED}" = false ]; then
  echo "[rotate-root] ERROR: Secret sync timed out after 5 minutes"
  exit 1
fi

echo "[rotate-root] Root password rotation complete"
