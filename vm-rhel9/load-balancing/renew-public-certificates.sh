#!/usr/bin/env bash
# Run with a current Doormat session. This operator workflow intentionally stores no long-lived AWS keys.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/notebook-env.sh"
aws sts get-caller-identity --query '{Account:Account}' --output json
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-$HOME/.vault-demo/letsencrypt-vm}"
podman run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  -e AWS_REGION -e AWS_DEFAULT_REGION -v "$LETSENCRYPT_DIR:/etc/letsencrypt" \
  certbot/dns-route53:latest renew --cert-name vault-vm --non-interactive
# Atomic certificate replacement on all nodes; SIGHUP reloads certificates when HCL is unchanged.
bash "$ROOT/load-balancing/install-public-certificates.sh"
