#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/notebook-env.sh"
: > "$STATE/response-header-nodes.jsonl"
while read -r node public fqdn; do
  ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo cat /etc/vault.d/vault.hcl' > "$STATE/$node.verified.hcl"
  grep -Eq '^enable_response_header_hostname[[:space:]]*=[[:space:]]*true$' "$STATE/$node.verified.hcl"
  grep -Eq '^enable_response_header_raft_node_id[[:space:]]*=[[:space:]]*true$' "$STATE/$node.verified.hcl"
  ! grep -Eq '^[[:space:]]*resolver_discover_servers[[:space:]]*=' "$STATE/$node.verified.hcl"
  curl --connect-timeout 5 --max-time 10 -sS -D "$STATE/$node.headers" \
    "https://$fqdn:8200/v1/sys/health" > "$STATE/$node.health.json"
  jq -e '.initialized and (.sealed|not)' "$STATE/$node.health.json" >/dev/null
  hostname=$(tr -d '\r' < "$STATE/$node.headers" | awk 'tolower($1)=="x-vault-hostname:" {print $2}')
  raft_id=$(tr -d '\r' < "$STATE/$node.headers" | awk 'tolower($1)=="x-vault-raft-node-id:" {print $2}')
  [[ -n "$hostname" && "$raft_id" == "$node" ]]
  # retry_join must list every other node in this cluster, never this node itself.
  jq -r --arg node "$node" '.nodes as $nodes | $nodes[$node].cluster as $cluster |
    $nodes | to_entries[] | select(.value.cluster==$cluster and .key!=$node) |
    "https://"+.value.internal_fqdn+":8200"' "$STATE/infrastructure.json" | sort > "$STATE/$node.expected-peers"
  sed -nE 's/^[[:space:]]*leader_api_addr[[:space:]]*=[[:space:]]*"([^"]+)"/\1/p' \
    "$STATE/$node.verified.hcl" | sort > "$STATE/$node.actual-peers"
  cmp "$STATE/$node.expected-peers" "$STATE/$node.actual-peers"
  jq -nc --arg node "$node" --arg hostname "$hostname" --arg raft_id "$raft_id" \
    '{node:$node,hostname:$hostname,raft_node_id:$raft_id,resolver_override_absent:true,retry_join_peers_correct:true}' \
    >> "$STATE/response-header-nodes.jsonl"
  echo "$node: both headers verified; resolver uses default; retry_join peers correct"
done < <(jq -r '.nodes|to_entries[]|select(.value.cluster!="app")|[.key,.value.public_ip,.value.api_fqdn]|@tsv' "$STATE/infrastructure.json")
: > "$STATE/response-header-endpoints.jsonl"
for endpoint in "$VAULT_ADMIN_ADDR" "$VAULT_APPLICATION_ADDR"; do
  for port in 443 8200; do
    curl --connect-timeout 5 --max-time 10 -fsS -D "$STATE/lb.headers" \
      "$endpoint:$port/v1/sys/health?perfstandbyok=true" > "$STATE/lb.headers-health.json"
    hostname=$(tr -d '\r' < "$STATE/lb.headers" | awk 'tolower($1)=="x-vault-hostname:" {print $2}')
    raft_id=$(tr -d '\r' < "$STATE/lb.headers" | awk 'tolower($1)=="x-vault-raft-node-id:" {print $2}')
    [[ -n "$hostname" && "$raft_id" == primary-* ]]
    jq -nc --arg endpoint "$endpoint:$port" --arg hostname "$hostname" --arg raft_id "$raft_id" \
      '{endpoint:$endpoint,hostname:$hostname,raft_node_id:$raft_id}' >> "$STATE/response-header-endpoints.jsonl"
  done
done
jq -n --arg date "$(date -u +%FT%TZ)" \
  --slurpfile nodes "$STATE/response-header-nodes.jsonl" \
  --slurpfile endpoints "$STATE/response-header-endpoints.jsonl" \
  '{evaluated_at:$date,status:"passed",resolver_discover_servers:"default (true)",nodes:$nodes,endpoints:$endpoints}' \
  > "$VM_ROOT/load-balancing/response-headers-results.json"
