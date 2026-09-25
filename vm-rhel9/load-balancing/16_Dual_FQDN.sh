#!/usr/bin/env bash
# Run from vm-rhel9/load-balancing. Same commands as the notebook.

set -euo pipefail
source ../scripts/notebook-env.sh
aws sts get-caller-identity --query '{Account:Account}' --output json
terraform -chdir="$VM_ROOT/terraform/infrastructure" fmt -check
terraform -chdir="$VM_ROOT/terraform/infrastructure" validate
terraform -chdir="$VM_ROOT/terraform/infrastructure" plan -input=false -out="$STATE/dual-endpoint.tfplan" > "$STATE/dual-endpoint-plan.log" 2>&1
terraform -chdir="$VM_ROOT/terraform/infrastructure" show -json "$STATE/dual-endpoint.tfplan" > "$STATE/dual-endpoint-plan.json"
jq '[.resource_changes[]? | select(.change.actions != ["no-op"]) | {address,actions:.change.actions}]' "$STATE/dual-endpoint-plan.json"
# Stop on any deletion, replacement, or change to an existing VM.
jq -e 'all(.resource_changes[]?; (.change.actions | index("delete") | not) and (if .type == "aws_instance" then .change.actions == ["no-op"] else true end))' "$STATE/dual-endpoint-plan.json" >/dev/null
terraform -chdir="$VM_ROOT/terraform/infrastructure" apply -input=false "$STATE/dual-endpoint.tfplan" > "$STATE/dual-endpoint-apply.log" 2>&1
terraform -chdir="$VM_ROOT/terraform/infrastructure" output -json | jq 'with_entries(.value=.value.value)' > "$STATE/infrastructure.json"
jq '{vault_address,vault_application_address}' "$STATE/infrastructure.json"

set -euo pipefail
source ../scripts/notebook-env.sh
ADMIN_TG=$(jq -er .vault_admin_target_group_arn "$STATE/infrastructure.json")
APP_TG=$(jq -er .vault_application_target_group_arn "$STATE/infrastructure.json")
for attempt in $(seq 1 60); do
  aws elbv2 describe-target-health --target-group-arn "$ADMIN_TG" > "$STATE/lb-admin-health.json"
  aws elbv2 describe-target-health --target-group-arn "$APP_TG" > "$STATE/lb-app-health.json"
  if jq -e '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length==1' "$STATE/lb-admin-health.json" >/dev/null &&
     jq -e '(.TargetHealthDescriptions | length==6) and all(.TargetHealthDescriptions[]; .TargetHealth.State=="healthy")' "$STATE/lb-app-health.json" >/dev/null; then
    break
  fi
  sleep 5
done
jq -e '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length==1' "$STATE/lb-admin-health.json" >/dev/null
jq -e '(.TargetHealthDescriptions | length==6) and all(.TargetHealthDescriptions[]; .TargetHealth.State=="healthy")' "$STATE/lb-app-health.json" >/dev/null
aws elbv2 describe-target-group-attributes --target-group-arn "$APP_TG" > "$STATE/lb-app-attributes.json"
jq -e '(.Attributes | map({key:.Key,value:.Value}) | from_entries) | .["stickiness.enabled"]=="false"' "$STATE/lb-app-attributes.json" >/dev/null
aws elbv2 describe-target-groups --target-group-arns "$ADMIN_TG" "$APP_TG" --query 'TargetGroups[].{Name:TargetGroupName,Protocol:Protocol,Port:Port,HealthPath:HealthCheckPath,Accept:Matcher.HttpCode}' --output table
echo 'Healthy targets: administrative=1; applications=6. NLB TCP flow hashing; no stickiness.'

set -euo pipefail
source ../scripts/notebook-env.sh
for endpoint in "$VAULT_ADMIN_ADDR" "$VAULT_APPLICATION_ADDR"; do
  for attempt in $(seq 1 30); do
    if curl --connect-timeout 5 --max-time 10 -fsS "$endpoint/v1/sys/health?perfstandbyok=true" > "$STATE/lb-public-health.json" 2>/dev/null; then break; fi
    sleep 5
  done
  curl --connect-timeout 5 --max-time 10 -fsS "$endpoint/v1/sys/health?perfstandbyok=true" | jq -e '.initialized and (.sealed|not)' >/dev/null
  curl --connect-timeout 5 --max-time 10 -fsS "$endpoint/ui/" > "$STATE/lb-ui.html"
  grep -q '<html' "$STATE/lb-ui.html"
  echo "$endpoint: DNS, trusted TLS, health and UI OK"
done
: > "$STATE/lb-admin-leaders.jsonl"
for request in $(seq 1 12); do
  curl --max-time 10 -fsS "$VAULT_ADMIN_ADDR/v1/sys/leader" | jq -c '{is_self,leader_address,performance_standby}' >> "$STATE/lb-admin-leaders.jsonl"
done
jq -se 'length==12 and all(.[]; .is_self==true and .performance_standby==false)' "$STATE/lb-admin-leaders.jsonl" >/dev/null
echo '12/12 administrative requests reached the active node.'

set -euo pipefail
source ../scripts/notebook-env.sh
vault secrets list -format=json | jq -e 'has("lb-verification/")' >/dev/null || vault secrets enable -path=lb-verification kv-v2
for attempt in $(seq 1 30); do
  vault read lb-verification/config >/dev/null 2>&1 && break
  sleep 1
done
vault policy write lb-verification-reader - <<'HCL'
path "lb-verification/data/*" {
  capabilities = ["read"]
}
HCL
MARKER="routing-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
printf '%s\n' "$MARKER" > "$STATE/lb-verification-marker"
# A newly mounted KV v2 backend initializes asynchronously on performance standbys.
# Wait for the first application write to succeed before measuring normal reads.
WRITE_READY=false
for attempt in $(seq 1 30); do
  if VAULT_ADDR="$VAULT_APPLICATION_ADDR" vault kv put "lb-verification/$MARKER" marker="$MARKER" > "$STATE/lb-write-result.log" 2>&1; then
    WRITE_READY=true
    break
  fi
  sleep 2
done
"$WRITE_READY"
# A batch token permits local performance-standby reads and expires after 10 min.
vault token create -type=batch -policy=lb-verification-reader -no-default-policy -ttl=10m -format=json > "$STATE/lb-read-token.json"
jq -r '.auth.client_token | "header = \"X-Vault-Token: \(.)\""' "$STATE/lb-read-token.json" > "$STATE/lb-curl.conf"
trap 'rm -f "$STATE/lb-read-token.json" "$STATE/lb-curl.conf"' EXIT
: > "$STATE/lb-read-request-ids.txt"
: > "$STATE/lb-response-headers.jsonl"
for request in $(seq 1 60); do
  curl -D "$STATE/lb-read.headers" --config "$STATE/lb-curl.conf" --connect-timeout 5 --max-time 15 -fsS \
    "$VAULT_APPLICATION_ADDR/v1/lb-verification/data/$MARKER" > "$STATE/lb-read-result.json"
  jq -e --arg marker "$MARKER" '.data.data.marker==$marker' "$STATE/lb-read-result.json" >/dev/null
  jq -er .request_id "$STATE/lb-read-result.json" >> "$STATE/lb-read-request-ids.txt"
  node=$(tr -d '\r' < "$STATE/lb-read.headers" | awk 'tolower($1)=="x-vault-raft-node-id:" {print $2}')
  hostname=$(tr -d '\r' < "$STATE/lb-read.headers" | awk 'tolower($1)=="x-vault-hostname:" {print $2}')
  [[ "$node" == primary-* && -n "$hostname" ]]
  jq -nc --arg node "$node" --arg hostname "$hostname" '{node:$node,hostname:$hostname}' >> "$STATE/lb-response-headers.jsonl"
done
test "$(wc -l < "$STATE/lb-read-request-ids.txt" | tr -d ' ')" = 60
jq -se 'length==60 and ([.[].node]|unique|length)==6' "$STATE/lb-response-headers.jsonl" >/dev/null
echo 'Application endpoint: KV write OK; 60/60 authenticated reads returned the expected value.'

set -euo pipefail
source ../scripts/notebook-env.sh
MARKER=$(cat "$STATE/lb-verification-marker")
AUDIT_PATH="lb-verification/data/$MARKER"
: > "$STATE/lb-audit-distribution.jsonl"
while read -r name public private; do
  count=$(ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" \
    "sudo grep -F '$AUDIT_PATH' /var/log/vault/audit.json | jq -s --arg path '$AUDIT_PATH' '[.[] | select(.type==\"response\" and .request.path==\$path and .request.operation==\"read\" and (.error==null or .error==\"\"))] | length'")
  test "$count" -gt 0
  jq -nc --arg node "$name" --arg ip "$private" --argjson reads "$count" '{node:$node,private_ip:$ip,successful_read_responses:$reads}' >> "$STATE/lb-audit-distribution.jsonl"
done < <(jq -r '.nodes | to_entries[] | select(.value.cluster=="primary") | [.key,.value.public_ip,.value.private_ip] | @tsv' "$STATE/infrastructure.json")
jq -se 'length==6 and all(.[]; .successful_read_responses>0)' "$STATE/lb-audit-distribution.jsonl" >/dev/null
jq -s '.' "$STATE/lb-audit-distribution.jsonl"
jq -n --arg date "$(date -u +%FT%TZ)" \
  --arg admin "$VAULT_ADMIN_ADDR" --arg apps "$VAULT_APPLICATION_ADDR" \
  --slurpfile distribution "$STATE/lb-audit-distribution.jsonl" \
  --slurpfile headers "$STATE/lb-response-headers.jsonl" \
  '{status:"passed",evaluated_at:$date,admin_endpoint:$admin,application_endpoint:$apps,healthy_admin_targets:1,healthy_application_targets:6,admin_leader_requests:12,successful_application_reads:60,application_write:"passed",tls_and_ui:"passed",audit_distribution:$distribution,response_header_distribution:($headers|group_by(.node)|map({node:.[0].node,hostname:.[0].hostname,responses:length})),scope:"Normal operation; no induced leader failover"}' > "$VM_ROOT/load-balancing/results.json"
echo 'Both FQDNs verified; successful reads observed on every primary-cluster node.'
