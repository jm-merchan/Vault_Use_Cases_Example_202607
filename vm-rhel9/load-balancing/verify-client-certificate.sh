#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/notebook-env.sh"
export VAULT_ADDR="$VAULT_APPLICATION_ADDR"
mkdir -p "$STATE/client-cert"
CERT_TEST="$STATE/client-cert"
if [[ ! -f "$CERT_TEST/ca.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=VM demo client CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -keyout "$CERT_TEST/ca.key" -out "$CERT_TEST/ca.pem" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -subj '/CN=vm-demo-client' \
    -keyout "$CERT_TEST/client.key" -out "$CERT_TEST/client.csr" 2>/dev/null
  printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n' > "$CERT_TEST/client.ext"
  openssl x509 -req -days 14 -in "$CERT_TEST/client.csr" -CA "$CERT_TEST/ca.pem" \
    -CAkey "$CERT_TEST/ca.key" -CAcreateserial -extfile "$CERT_TEST/client.ext" -out "$CERT_TEST/client.pem" 2>/dev/null
fi
vault auth list -format=json | jq -e 'has("vm-cert/")' >/dev/null || vault auth enable -path=vm-cert cert
vault secrets list -format=json | jq -e 'has("tls-check/")' >/dev/null || vault secrets enable -path=tls-check kv-v2
vault policy write vm-cert-read - <<'HCL'
path "tls-check/data/probe" { capabilities = ["read"] }
HCL
for attempt in $(seq 1 30); do
  vault kv put tls-check/probe value=certificate-login-verified >/dev/null 2>&1 && break
  sleep 1
done
[[ "$(vault kv get -field=value tls-check/probe)" == certificate-login-verified ]]
vault write auth/vm-cert/certs/demo certificate=@"$CERT_TEST/ca.pem" \
  allowed_common_names=vm-demo-client token_policies=vm-cert-read token_ttl=5m token_max_ttl=10m >/dev/null
printf '[]' > "$STATE/client-cert-results.json"
for base in "$VAULT_ADMIN_ADDR" "$VAULT_APPLICATION_ADDR"; do
  for port in 443 8200; do
    url="$base:$port"
    curl --connect-timeout 5 --max-time 20 -fsS --cert "$CERT_TEST/client.pem" --key "$CERT_TEST/client.key" \
      -H 'Content-Type: application/json' --data '{"name":"demo"}' "$url/v1/auth/vm-cert/login" > "$CERT_TEST/login.json"
    token=$(jq -er .auth.client_token "$CERT_TEST/login.json")
    value=$(VAULT_ADDR="$url" VAULT_TOKEN="$token" vault kv get -field=value tls-check/probe)
    [[ "$value" == certificate-login-verified ]]
    denied=$(curl -sS -o "$CERT_TEST/denied.json" -w '%{http_code}' -H "X-Vault-Token: $token" "$url/v1/secret/data/forbidden")
    [[ "$denied" == 403 ]]
    VAULT_ADDR="$url" VAULT_TOKEN="$token" vault token revoke -self >/dev/null
    unauthenticated=$(curl -sS -o "$CERT_TEST/no-cert.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data '{"name":"demo"}' "$url/v1/auth/vm-cert/login")
    [[ "$unauthenticated" == 400 || "$unauthenticated" == 403 ]]
    jq --arg url "$url" '. + [{endpoint:$url,client_certificate_login:"passed",authorized_read:"passed",unauthorized_read:"denied",login_without_certificate:"denied"}]' \
      "$STATE/client-cert-results.json" > "$STATE/client-cert-results.tmp"
    mv "$STATE/client-cert-results.tmp" "$STATE/client-cert-results.json"
    echo "$url: client certificate login, policy and negative tests passed"
  done
done
cp "$STATE/client-cert-results.json" "$VM_ROOT/load-balancing/client-cert-results.json"
