#!/bin/bash
set -euo pipefail

# Tools (aws, kubectl, mongosh) are pre-installed in the rotator image.
# See k8s-infra-aws-ssm/mongo/scripts/Dockerfile.rotator for pinned versions + sha256 verification.

# --- Constants ---
SSM_PREFIX="${SSM_PREFIX:-/demo-eks-dev/mongo}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-dev}"
MONGO_HOST="${MONGO_HOST:-mongo:27017}"
MONGO_DATABASE="${MONGO_DATABASE:-dev_be_db}"
FORCE_REFRESH_CMD='{"metadata":{"annotations":{"external-secrets.io/last-refresh":"'$(date +%s)'"}}}'

echo "[rotate] Starting Mongo app-user rotation"

# --- Step 1: Generate new password ---
NEW_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
NEW_URI="mongodb://${MONGO_APP_USERNAME}:${NEW_PASSWORD}@${MONGO_HOST}/${MONGO_DATABASE}?authSource=admin"

echo "[rotate] Generated new password for ${MONGO_APP_USERNAME} (length=${#NEW_PASSWORD})"

# --- Step 2: Update MongoDB user password ---
mongosh "mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@${MONGO_HOST}/admin" \
  --quiet --eval "
    try {
      const adminDb = db.getSiblingDB('admin');
      adminDb.updateUser('${MONGO_APP_USERNAME}', {
        pwd: '${NEW_PASSWORD}',
        roles: [{ role: 'readWrite', db: '${MONGO_DATABASE}' }]
      });
      print('MongoDB app_user password updated');
    } catch (err) {
      print('ERROR updating MongoDB: ' + err.message);
      quit(1);
    }
  " || { echo "[rotate] ERROR: MongoDB update failed"; exit 1; }

echo "[rotate] MongoDB app_user password updated"

# --- Step 3: Update SSM parameters ---
aws ssm put-parameter \
  --name "${SSM_PREFIX}/app_password" \
  --value "${NEW_PASSWORD}" \
  --type SecureString \
  --overwrite \
  --region "${AWS_REGION}" >/dev/null \
  || { echo "[rotate] ERROR: SSM app_password update failed"; exit 1; }

aws ssm put-parameter \
  --name "${SSM_PREFIX}/app_mongodb_uri" \
  --value "${NEW_URI}" \
  --type SecureString \
  --overwrite \
  --region "${AWS_REGION}" >/dev/null \
  || { echo "[rotate] ERROR: SSM app_mongodb_uri update failed"; exit 1; }

echo "[rotate] SSM parameters updated"

# --- Step 4: Force ESO refresh ---
kubectl -n "${NAMESPACE}" patch externalsecret mongo-app-secret \
  --type merge -p "${FORCE_REFRESH_CMD}" >/dev/null \
  || { echo "[rotate] ERROR: ExternalSecret patch failed"; exit 1; }

echo "[rotate] ExternalSecret patched for immediate refresh"

# --- Step 5: Wait for secret sync ---
echo "[rotate] Waiting for mongo-app-secret to update..."
for i in $(seq 1 60); do
  CURRENT_PASS=$(kubectl -n "${NAMESPACE}" get secret mongo-app-secret \
    -o jsonpath='{.data.MONGO_APP_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [ -n "${CURRENT_PASS}" ] && [ "${CURRENT_PASS}" != "${MONGO_APP_PASSWORD}" ]; then
    echo "[rotate] mongo-app-secret updated"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[rotate] WARNING: Secret sync timed out after 5 minutes"
  fi
  sleep 5
done

# --- Step 6: Restart backend ---
kubectl -n "${NAMESPACE}" rollout restart deployment/backend >/dev/null \
  || { echo "[rotate] ERROR: Backend restart failed"; exit 1; }

echo "[rotate] Backend deployment restarting"

# --- Step 7: Wait for rollout ---
kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout=180s >/dev/null \
  || { echo "[rotate] WARNING: Backend rollout status check failed or timed out"; }

echo "[rotate] Rotation complete"
