#!/usr/bin/env bash
set -euo pipefail

# Render a Kustomize directory and substitute __AWS_ACCOUNT_ID__ with the current
# AWS account ID (from env or aws sts get-caller-identity).

KUSTOMIZE_TARGET="${1:-.}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

kubectl kustomize "${KUSTOMIZE_TARGET}" | sed "s/__AWS_ACCOUNT_ID__/${AWS_ACCOUNT_ID}/g"
