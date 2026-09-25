#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/notebook-env.sh"
DOMAIN=${VAULT_ADMIN_ADDR#https://}
SUFFIX=${DOMAIN#*.}
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-$HOME/.vault-demo/letsencrypt-vm}"
mkdir -p "$LETSENCRYPT_DIR"
podman run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  -e AWS_REGION -e AWS_DEFAULT_REGION -v "$LETSENCRYPT_DIR:/etc/letsencrypt" \
  certbot/dns-route53:latest certonly --dns-route53 --non-interactive --agree-tos \
  --register-unsafely-without-email --keep-until-expiring --cert-name vault-vm \
  -d "$DOMAIN" -d "${VAULT_APPLICATION_ADDR#https://}" \
  -d "vault-vm-secondary.$SUFFIX" -d "*.vm-vault.$SUFFIX"
CERT_DIR="$LETSENCRYPT_DIR/live/vault-vm"
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -issuer -dates -ext subjectAltName
if [[ $(uname) == Darwin ]]; then
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain > "$STATE/ca.pem"
else
  cp /etc/pki/tls/certs/ca-bundle.crt "$STATE/ca.pem"
fi
while read -r node; do
  cp "$CERT_DIR/fullchain.pem" "$STATE/$node.pem"
  cp "$CERT_DIR/privkey.pem" "$STATE/$node.key"
done < <(jq -r '.nodes | to_entries[] | select(.value.cluster!="app") | .key' "$STATE/infrastructure.json")
