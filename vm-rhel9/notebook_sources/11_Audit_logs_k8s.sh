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

# Archivo de auditoría, logrotate y reapertura
set -euo pipefail
source ../scripts/notebook-env.sh
vault secrets list -format=json | jq -e 'has("audit-check/")' >/dev/null || vault secrets enable -path=audit-check kv-v2
for attempt in $(seq 1 60); do vault read audit-check/config >/dev/null 2>&1 && break; sleep 1; done
vault read audit-check/config >/dev/null

marker=$(openssl rand -hex 8)
vault kv put "audit-check/$marker" test=true >/dev/null
leader=$(vault read -format=json sys/leader | jq -r .data.leader_address)
ACTIVE=$(jq -r --arg leader "$leader" '.nodes[] | select(.cluster=="primary") | select(("https://" + .internal_fqdn + ":8200") == $leader) | .public_ip' "$STATE/infrastructure.json")
test -n "$ACTIVE"
ssh "${SSH_ARGS[@]}" "ec2-user@$ACTIVE" sudo bash -se <<EOF
test -s /var/log/vault/audit.json
grep -q 'audit-check/data/$marker' /var/log/vault/audit.json
# Configuración de rotación visible:
cat /etc/logrotate.d/vault
logrotate -f /etc/logrotate.d/vault
test -s /var/log/vault/audit.json.1
EOF
marker=$(openssl rand -hex 8)
vault kv put "audit-check/$marker" test=true >/dev/null
ssh "${SSH_ARGS[@]}" "ec2-user@$ACTIVE" sudo bash -se <<EOF
grep -q 'audit-check/data/$marker' /var/log/vault/audit.json
test "\$(stat -c '%U:%G %a' /var/log/vault/audit.json)" = 'vault:vault 640'
systemctl is-active --quiet vault
EOF
echo 'Auditoría escrita antes y después de logrotate/SIGHUP'
