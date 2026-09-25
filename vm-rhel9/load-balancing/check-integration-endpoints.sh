#!/usr/bin/env bash
# Read-only inventory after executing the migrated integration notebooks.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../aap/aap-env.sh"
: "${VAULT_APPLICATION_ADDR:?Application endpoint missing}"
: > "$STATE/apps-endpoints.jsonl"

record() {
  jq -nc --arg consumer "$1" --arg endpoint "$VAULT_APPLICATION_ADDR" \
    '{consumer:$consumer,endpoint:$endpoint,verified:true}' >> "$STATE/apps-endpoints.jsonl"
}

for method in AppRole OIDC; do
  backend=$(jq -er --arg method "$method" '.[$method].backend' "$STATE/aap/controller-resources.json")
  "${AAP_CURL[@]}" "$AAP_API/credentials/$backend/" > "$STATE/aap/backend-check.json"
  jq -e --arg endpoint "$VAULT_APPLICATION_ADDR" '.inputs.url==$endpoint' "$STATE/aap/backend-check.json" >/dev/null
  record "AAP $method"
done
vault read -format=json auth/aap-jwt/role/aap-demo |
  jq -e --arg endpoint "$VAULT_APPLICATION_ADDR" '.data.bound_audiences==[$endpoint]' >/dev/null
vault read -format=json identity/oidc/config |
  jq -e --arg issuer "$VAULT_ADMIN_ADDR" '.data.issuer==$issuer' >/dev/null

"${KUBECTL[@]}" -n vm-consumers get vaultconnections -o json > "$STATE/apps-vso-connections.json"
jq -e --arg endpoint "$VAULT_APPLICATION_ADDR" '(.items|length==2) and all(.items[]; .spec.address==$endpoint)' "$STATE/apps-vso-connections.json" >/dev/null
record 'VSO Kubernetes and JWT connections'
"${KUBECTL[@]}" -n vm-consumers get secretproviderclass vm-vault -o json |
  jq -e --arg endpoint "$VAULT_APPLICATION_ADDR" '.spec.parameters.vaultAddress==$endpoint' >/dev/null
record CSI

ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" "sudo bash -se" <<EOF
for config in /opt/vm-agent-static/agent.hcl /opt/vm-agent-db/agent.hcl /opt/vm-agent-db/oneshot.hcl; do
  grep -Fq 'address = "$VAULT_APPLICATION_ADDR"' "\$config"
done
systemctl is-active --quiet vm-agent-static
systemctl is-active --quiet vm-agent-db-once.timer
EOF
record 'Vault Agent static and dynamic, including timer'

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
for workflow in vault-oidc.yml vault-k8s-engine-vso.yml; do
  gh api "repos/$REPO/contents/.github/workflows/$workflow?ref=codex/vm-rhel9-poc" --jq .content |
    tr -d '\n' | openssl base64 -d -A > "$STATE/apps-$workflow"
  grep -Fq "VAULT_ADDR: $VAULT_APPLICATION_ADDR" "$STATE/apps-$workflow"
  record "GitHub $workflow"
done

"${KUBECTL[@]}" -n vm-benchmark get job benchmark -o json |
  jq -e --arg endpoint "$VAULT_APPLICATION_ADDR" 'any(.spec.template.spec.containers[].env[]; .name=="VAULT_ADDR" and .value==$endpoint)' >/dev/null
record 'Vault benchmark'
for provider in aws azure; do
  grep -Fq "address = \"$VAULT_APPLICATION_ADDR\"" "$STATE/$provider-import.hcl"
  record "Secrets Import $provider"
done

jq -s --arg date "$(date -u +%FT%TZ)" \
  '{verified_at:$date,status:"passed",scope:"Deployed consumer addresses; functional results are in notebook reports and aap/evaluation.json",consumers:.}' \
  "$STATE/apps-endpoints.jsonl" > "$VM_ROOT/load-balancing/integration-endpoints.json"
cat "$VM_ROOT/load-balancing/integration-endpoints.json"
