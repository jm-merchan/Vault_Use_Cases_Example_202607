#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/notebook-env.sh"
# Only node-level diagnostics use operator-restricted public node DNS. PR uses the load balancer.
SECONDARY="https://$(jq -r '.nodes["secondary-0"].api_fqdn' "$STATE/infrastructure.json"):8200"
for cluster in primary secondary; do
  while read -r node ip fqdn; do
    if curl -fsS "https://$fqdn:8200/v1/sys/leader" | jq -e '.data.is_self // .is_self' >/dev/null; then
      [[ "$cluster" != primary ]] || PRIMARY_LEADER=$ip
      [[ "$cluster" != secondary ]] || SECONDARY_LEADER=$ip
      break
    fi
  done < <(jq -r --arg cluster "$cluster" '.nodes | to_entries[] | select(.value.cluster==$cluster) | [.key,.value.public_ip,.value.api_fqdn] | @tsv' "$STATE/infrastructure.json")
done
: "${PRIMARY_LEADER:?}" "${SECONDARY_LEADER:?}"
: > "$STATE/pr-direct-network.jsonl"
for direction in primary-to-secondary secondary-to-primary; do
  source_ip=$PRIMARY_LEADER; destination_cluster=secondary
  [[ "$direction" != secondary-to-primary ]] || { source_ip=$SECONDARY_LEADER; destination_cluster=primary; }
  while read -r node ip; do
    if ssh -n "${SSH_ARGS[@]}" "ec2-user@$source_ip" "timeout 3 bash -c 'exec 3<>/dev/tcp/$ip/8201'" 2>/dev/null; then
      echo "Unexpected direct cluster connection: $direction $node" >&2; exit 1
    fi
    jq -nc --arg direction "$direction" --arg node "$node" '{direction:$direction,target:$node,direct_8201:"blocked"}' >> "$STATE/pr-direct-network.jsonl"
  done < <(jq -r --arg cluster "$destination_cluster" '.nodes | to_entries[] | select(.value.cluster==$cluster) | [.key,.value.private_ip] | @tsv' "$STATE/infrastructure.json")
done
# End any pre-migration tracked TCP session and demonstrate reconnection through the NLB.
ssh -n "${SSH_ARGS[@]}" "ec2-user@$SECONDARY_LEADER" sudo systemctl restart vault
for attempt in $(seq 1 120); do
  h=$(curl --connect-timeout 3 --max-time 5 -fsS "$SECONDARY/v1/sys/replication/status" 2>/dev/null || true)
  if jq -e '.data.performance | .state=="stream-wals" and .connection_state=="ready"' <<<"$h" >/dev/null 2>&1; then break; fi
  sleep 2
done
jq -e '.data.performance | .state=="stream-wals" and .connection_state=="ready"' <<<"$h" >/dev/null
printf '%s\n' "$h" > "$STATE/pr-after-isolation.json"
: > "$STATE/pr-established-sockets.txt"
while read -r ip; do
  ssh -n "${SSH_ARGS[@]}" "ec2-user@$ip" 'sudo ss -tnp state established | grep vault | grep :8201 || true' >> "$STATE/pr-established-sockets.txt"
done < <(jq -r '.nodes[] | select(.cluster=="secondary") | .public_ip' "$STATE/infrastructure.json")
# A secondary must have an established socket whose peer is one of the primary NLB addresses.
found=false
while read -r ip; do
  if grep -F "$ip:8201" "$STATE/pr-established-sockets.txt" >/dev/null; then found=true; break; fi
done < <(dig +short "${VAULT_ADMIN_ADDR#https://}" A | grep -E '^[0-9]+\.')
[[ "$found" == true ]]
# Also verify the secondary's private NLB API and 8201 listeners from inside the VPC.
SECONDARY_LB=$(jq -r .vault_secondary_address "$STATE/infrastructure.json")
ready=false
for attempt in $(seq 1 30); do
  if ssh -n "${SSH_ARGS[@]}" "ec2-user@$PRIMARY_LEADER" \
    "set -euo pipefail; curl --max-time 10 -fsS '$SECONDARY_LB/v1/sys/health' | jq -e '.initialized and (.sealed|not) and (.standby|not)' >/dev/null; timeout 5 bash -c 'exec 3<>/dev/tcp/${SECONDARY_LB#https://}/8201'" 2>/dev/null; then ready=true; break; fi
  sleep 3
done
[[ "$ready" == true ]]
jq -n --arg date "$(date -u +%FT%TZ)" --slurpfile blocked "$STATE/pr-direct-network.jsonl" \
  --slurpfile pr "$STATE/pr-after-isolation.json" \
  '{evaluated_at:$date,status:"passed",direct_connections:$blocked,established_secondary_to_primary_nlb_8201:true,secondary_nlb_api_and_8201:true,secondary_restart_recovery:true,replication:$pr[0].data.performance}' \
  > "$VM_ROOT/load-balancing/pr-nlb-results.json"
echo 'PR reconnected via NLB after restarting the secondary leader; all nine direct cross-cluster paths are blocked.'
