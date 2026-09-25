#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/notebook-env.sh"
mkdir -p "$STATE/aap"
vault secrets list -format=json | jq -e 'has("aap-demo/")' >/dev/null || vault secrets enable -path=aap-demo kv-v2
for attempt in $(seq 1 30); do vault read aap-demo/config >/dev/null 2>&1 && break; sleep 1; done
if ! vault kv get -format=json aap-demo/credentials/test > "$STATE/aap/demo-secret.json" 2>/dev/null; then
  openssl rand -hex 32 | tr -d '\n' > "$STATE/aap/demo-password"
  vault kv put aap-demo/credentials/test password=@"$STATE/aap/demo-password" purpose=aap-vm-demo >/dev/null
  vault kv get -format=json aap-demo/credentials/test > "$STATE/aap/demo-secret.json"
fi
jq -jr .data.data.password "$STATE/aap/demo-secret.json" | shasum -a 256 | awk '{print $1}' > "$STATE/aap/expected-digest"
vault policy write aap-demo-read - <<'HCL'
path "aap-demo/data/credentials/test" {
  capabilities = ["read"]
}
HCL
vault auth list -format=json | jq -e 'has("aap-approle/")' >/dev/null || vault auth enable -path=aap-approle approle
vault write auth/aap-approle/role/aap-demo \
  token_policies=aap-demo-read token_ttl=15m token_max_ttl=30m \
  secret_id_ttl=720h secret_id_num_uses=0 >/dev/null
vault read -format=json auth/aap-approle/role/aap-demo/role-id > "$STATE/aap/role-id.json"
if [[ ! -s "$STATE/aap/secret-id.json" ]] || ! vault write auth/aap-approle/role/aap-demo/secret-id-accessor/lookup \
    secret_id_accessor="$(jq -r .data.secret_id_accessor "$STATE/aap/secret-id.json")" >/dev/null 2>&1; then
  vault write -f -format=json auth/aap-approle/role/aap-demo/secret-id > "$STATE/aap/secret-id.json"
fi
jq -n --arg role "$(jq -r .data.role_id "$STATE/aap/role-id.json")" \
  --arg secret "$(jq -r .data.secret_id "$STATE/aap/secret-id.json")" \
  '{role_id:$role,secret_id:$secret}' > "$STATE/aap/approle-login-payload.json"
# Exercise the same application endpoint used by AAP external credentials.
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
curl -fsS -H 'Content-Type: application/json' --data @"$STATE/aap/approle-login-payload.json" \
  "$VAULT_ADDR/v1/auth/aap-approle/login" > "$STATE/aap/approle-login.json"
TOKEN=$(jq -er .auth.client_token "$STATE/aap/approle-login.json")
trap 'VAULT_TOKEN="$TOKEN" vault token revoke -self >/dev/null' EXIT
VAULT_TOKEN="$TOKEN" vault kv get -field=password aap-demo/credentials/test > "$STATE/aap/approle-read"
[[ "$(tr -d '\n' < "$STATE/aap/approle-read" | shasum -a 256 | awk '{print $1}')" == "$(cat "$STATE/aap/expected-digest")" ]]
[[ "$(VAULT_TOKEN="$TOKEN" vault token capabilities aap-demo/data/outside-demo)" == deny ]]
if VAULT_TOKEN="$TOKEN" vault kv get aap-demo/outside-demo > "$STATE/aap/denied.log" 2>&1; then
  echo 'Unexpected access outside the demo policy' >&2; exit 1
fi
grep -q '403' "$STATE/aap/denied.log"
echo 'AppRole: login, authorized read, denied read and token revocation verified'
