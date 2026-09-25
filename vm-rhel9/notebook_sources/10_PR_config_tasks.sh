#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
for tool in aws az vault curl jq kubectl ssh terraform; do command -v "$tool" >/dev/null; done
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  if ! doormat aws -a "$DOORMAT_AWS_ACCOUNT" export > "$STATE/aws-session.env"; then
    doormat login -f
    doormat aws -a "$DOORMAT_AWS_ACCOUNT" export > "$STATE/aws-session.env"
  fi
  source "$STATE/aws-session.env"
fi
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
# Persist only AWS session variables, never a Vault root token in notebook output.
{ declare -p AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true; } > "$STATE/aws-session.env"

# Activar primario, secundario y auto-unseal de standbys
set -euo pipefail
source ../scripts/notebook-env.sh
SECONDARY="https://$(jq -r '.nodes["secondary-0"].api_fqdn' "$STATE/infrastructure.json"):8200"
if [[ "$(vault read -format=json sys/replication/status | jq -r .data.performance.mode)" != primary ]]; then
  vault write sys/replication/performance/primary/enable primary_cluster_addr="${VAULT_ADMIN_ADDR}:8201" >/dev/null
fi
if [[ "$(curl -fsS --cacert "$STATE/ca.pem" "$SECONDARY/v1/sys/replication/status" | jq -r .data.performance.mode)" != secondary ]]; then
  vault write -format=json sys/replication/performance/primary/secondary-token id=rhel9-secondary > "$STATE/pr-activation.json"
  jq -n --arg token "$(jq -r .wrap_info.token "$STATE/pr-activation.json")" \
    --arg primary "$VAULT_ADMIN_ADDR" \
    '{token:$token,primary_api_addr:$primary,ca_file:"/etc/vault.d/tls/ca.pem"}' |
    curl -fsS --cacert "$STATE/ca.pem" -H "X-Vault-Token: $(jq -r .root_token "$STATE/secondary-init.json")" \
      -H 'Content-Type: application/json' --data @- "$SECONDARY/v1/sys/replication/performance/secondary/enable" >/dev/null
fi
for attempt in $(seq 1 90); do
  curl -fsS --cacert "$STATE/ca.pem" "$SECONDARY/v1/sys/replication/status" | jq -e '.data.performance | .state=="stream-wals" and .connection_state=="ready"' >/dev/null && break
  sleep 3
done
curl -fsS --cacert "$STATE/ca.pem" "$SECONDARY/v1/sys/replication/status" | jq -e '.data.performance | .state=="stream-wals" and .connection_state=="ready"' >/dev/null
# PR cambia las claves de barrera. Reiniciar standbys sellados ejecuta KMS auto-unseal.
while read -r ip fqdn; do
  restarted=false
  for attempt in $(seq 1 60); do
    h=$(curl -sS --cacert "$STATE/ca.pem" "https://$fqdn:8200/v1/sys/health" 2>/dev/null || true)
    if [[ "$(jq -r .sealed <<<"$h" 2>/dev/null || true)" == true && "$restarted" == false ]]; then
      ssh -n "${SSH_ARGS[@]}" "ec2-user@$ip" sudo systemctl restart vault
      restarted=true
    fi
    jq -e '.sealed==false and .replication_performance_mode=="secondary"' <<<"$h" >/dev/null 2>&1 && break
    sleep 3
  done
  curl -sS --cacert "$STATE/ca.pem" "https://$fqdn:8200/v1/sys/health" | jq -e '.sealed==false and .replication_performance_mode=="secondary"'
done < <(jq -r '.nodes[] | select(.cluster=="secondary") | [.public_ip,.api_fqdn] | @tsv' "$STATE/infrastructure.json")

# Autenticación local y cinco lecturas replicadas
set -euo pipefail
source ../scripts/notebook-env.sh
vault secrets list -format=json | jq -e 'has("pr-check/")' >/dev/null || vault secrets enable -path=pr-check kv-v2
for attempt in $(seq 1 60); do vault read pr-check/config >/dev/null 2>&1 && break; sleep 1; done
vault read pr-check/config >/dev/null
vault auth list -format=json | jq -e 'has("pr-userpass/")' >/dev/null || vault auth enable -path=pr-userpass userpass

vault policy write pr-reader - <<'HCL'
path "pr-check/data/*" { capabilities = ["read"] }
HCL
[[ -s "$STATE/pr-password" ]] || openssl rand -hex 16 | tr -d '\n' > "$STATE/pr-password"
vault write auth/pr-userpass/users/reader password=@"$STATE/pr-password" token_policies=pr-reader >/dev/null
SECONDARY="https://$(jq -r '.nodes["secondary-0"].api_fqdn' "$STATE/infrastructure.json"):8200"
# Wait for the user/policy WAL to replicate before attempting authentication.
# Repeated logins during replication lag can trigger user lockout.
EXPECTED_WAL=$(vault read -format=json sys/replication/status | jq -er .data.performance.last_wal)
ready=false
for attempt in $(seq 1 120); do
  if curl -fsS "$SECONDARY/v1/sys/replication/status" | jq -e --argjson wal "$EXPECTED_WAL" \
    '.data.performance | .state=="stream-wals" and .connection_state=="ready" and .last_remote_wal >= $wal' >/dev/null; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]]
sleep 3
VAULT_ADDR="$SECONDARY" VAULT_CACERT="$STATE/ca.pem" VAULT_TOKEN='' vault write -format=json \
  auth/pr-userpass/login/reader password=@"$STATE/pr-password" > "$STATE/pr-login.json"
TOKEN=$(jq -er .auth.client_token "$STATE/pr-login.json")
trap 'VAULT_ADDR="$SECONDARY" VAULT_CACERT="$STATE/ca.pem" VAULT_TOKEN="$TOKEN" vault token revoke -self >/dev/null' EXIT
printf '[]' > "$STATE/replication-cli-seconds.json"
for iteration in 1 2 3 4 5; do
  marker=$(openssl rand -hex 12); start=$SECONDS
  vault kv put pr-check/probe value="$marker" >/dev/null
  for attempt in $(seq 1 60); do
    actual=$(VAULT_ADDR="$SECONDARY" VAULT_CACERT="$STATE/ca.pem" VAULT_TOKEN="$TOKEN" vault kv get -field=value pr-check/probe 2>/dev/null || true)
    [[ "$actual" == "$marker" ]] && break
    sleep 0.2
  done
  [[ "$actual" == "$marker" ]]
  elapsed=$((SECONDS-start))
  jq --argjson elapsed "$elapsed" '. + [$elapsed]' "$STATE/replication-cli-seconds.json" > "$STATE/pr-time.tmp"
  mv "$STATE/pr-time.tmp" "$STATE/replication-cli-seconds.json"
  echo "Lectura replicada $iteration verificada; resolución de la medida: segundos ($elapsed s)"
done
