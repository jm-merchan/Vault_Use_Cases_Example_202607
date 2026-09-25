#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/notebook-env.sh"
export VAULT_ADDR="$VAULT_ADMIN_ADDR"
# Repeating enable on this primary updates its advertised address without disabling PR.
vault write sys/replication/performance/primary/enable primary_cluster_addr="${VAULT_ADMIN_ADDR}:8201" >/dev/null
SECONDARY="https://$(jq -r '.nodes["secondary-0"].api_fqdn' "$STATE/infrastructure.json"):8200"
CURRENT_PR_ADDR=$(curl -fsS "$SECONDARY/v1/sys/replication/status" | jq -r .data.performance.primary_cluster_addr)
if [[ "$CURRENT_PR_ADDR" != "${VAULT_ADMIN_ADDR}:8201" ]]; then
vault policy write pr-nlb-operator - <<'HCL'
path "sys/replication/performance/secondary/update-primary" { capabilities = ["update", "sudo"] }
path "sys/replication/status" { capabilities = ["read"] }
HCL
vault auth list -format=json | jq -e 'has("pr-userpass/")' >/dev/null || vault auth enable -path=pr-userpass userpass
openssl rand -hex 24 | tr -d '\n' > "$STATE/pr-nlb-password"
vault write auth/pr-userpass/users/nlb-operator password=@"$STATE/pr-nlb-password" \
  token_policies=pr-nlb-operator token_ttl=15m token_max_ttl=30m >/dev/null
for attempt in $(seq 1 30); do
  if VAULT_ADDR="$SECONDARY" VAULT_TOKEN='' vault write -format=json auth/pr-userpass/login/nlb-operator \
    password=@"$STATE/pr-nlb-password" > "$STATE/pr-nlb-login.json" 2>/dev/null; then break; fi
  sleep 2
done
SECONDARY_TOKEN=$(jq -er .auth.client_token "$STATE/pr-nlb-login.json")
# Refresh only the connection parameters. update-primary does not reinitialize Raft storage.
vault write -format=json sys/replication/performance/primary/secondary-token id="rhel9-secondary-nlb-$(date -u +%Y%m%d%H%M%S)" \
  > "$STATE/pr-nlb-activation.json"
VAULT_ADDR="$SECONDARY" VAULT_TOKEN="$SECONDARY_TOKEN" vault write sys/replication/performance/secondary/update-primary \
  token="$(jq -er .wrap_info.token "$STATE/pr-nlb-activation.json")" primary_api_addr="$VAULT_ADMIN_ADDR" \
  ca_file=/etc/pki/tls/certs/ca-bundle.crt >/dev/null
else
  echo "The secondary already advertises the NLB; keeping its existing replication identity."
fi
for attempt in $(seq 1 90); do
  curl -fsS "$SECONDARY/v1/sys/replication/status" > "$STATE/pr-nlb-status.json"
  jq -e --arg expected "${VAULT_ADMIN_ADDR}:8201" \
    '.data.performance | .primary_cluster_addr==$expected and .state=="stream-wals" and .connection_state=="ready"' \
    "$STATE/pr-nlb-status.json" >/dev/null && break
  sleep 2
done
jq -e --arg expected "${VAULT_ADMIN_ADDR}:8201" \
  '.data.performance | .primary_cluster_addr==$expected and .state=="stream-wals" and .connection_state=="ready"' \
  "$STATE/pr-nlb-status.json" >/dev/null
if [[ -n "${SECONDARY_TOKEN:-}" ]]; then
  VAULT_ADDR="$SECONDARY" VAULT_TOKEN="$SECONDARY_TOKEN" vault token revoke -self >/dev/null
fi
vault delete auth/pr-userpass/users/nlb-operator >/dev/null
vault policy delete pr-nlb-operator >/dev/null
jq '.data.performance | {mode,state,connection_state,primary_cluster_addr,known_primary_cluster_addrs}' "$STATE/pr-nlb-status.json"
