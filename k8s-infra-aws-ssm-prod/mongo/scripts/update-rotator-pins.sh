#!/usr/bin/env bash
set -euo pipefail
# Regenerate AWS CLI SHA256 pins for Dockerfile.rotator.
# Usage: ./update-rotator-pins.sh <aws-cli-version>
# Example: ./update-rotator-pins.sh 2.25.0

AWS_CLI_VERSION="${1:?usage: $0 <aws-cli-version>}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "# Paste into Dockerfile.rotator ARG block:"
for arch in aarch64 x86_64; do
  url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWS_CLI_VERSION}.zip"
  curl -fsSL "$url" -o "$TMPDIR/aws-${arch}.zip"
  hash=$(sha256sum "$TMPDIR/aws-${arch}.zip" | awk '{print $1}')
  var="AWS_CLI_SHA256_$(echo "$arch" | tr '[:lower:]' '[:upper:]')"
  echo "ARG ${var}=${hash}"
done
