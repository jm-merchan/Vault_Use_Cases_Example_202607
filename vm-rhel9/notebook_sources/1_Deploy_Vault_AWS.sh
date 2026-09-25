#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
CLUSTER=primary
NODE_COUNT=6
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

# Descubrir AWS, red y desplegar Terraform
set -euo pipefail
source ../scripts/notebook-env.sh
CLUSTER=primary
NODE_COUNT=6
aws eks describe-cluster --name "${EKS_CLUSTER_NAME:-eks-infra-dev}" > "$STATE/eks.json"
VPC=$(jq -r .cluster.resourcesVpcConfig.vpcId "$STATE/eks.json")
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" > "$STATE/subnets.json"
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" > "$STATE/routes.json"
PUBLIC=$(jq '[.RouteTables[] | select(any(.Routes[]; (.GatewayId // "") | startswith("igw-"))) | .Associations[] | .SubnetId // empty]' "$STATE/routes.json")
SUBNETS=$(jq --argjson public "$PUBLIC" '[.Subnets[] | select(.SubnetId as $id | $public | index($id))] | unique_by(.AvailabilityZone) | .[:3] | map(.SubnetId)' "$STATE/subnets.json")
[[ "$(jq length <<<"$SUBNETS")" == 3 ]]
[[ -f "$STATE/id_ed25519" ]] || ssh-keygen -t ed25519 -N '' -f "$STATE/id_ed25519"
# Preserve the already selected DNS zone when resuming the demo.
if [[ -f "$STATE/deployment-input.json" ]]; then
  SUBNETS=$(jq -c .subnet_ids "$STATE/deployment-input.json")
  ZONE_ID=$(jq -r .zone_id "$STATE/deployment-input.json")
  DOMAIN=$(jq -r .domain "$STATE/deployment-input.json")
else
  : "${DNS_ZONE_NAME:?Set DNS_ZONE_NAME to your public Route 53 hosted zone}"
  aws route53 list-hosted-zones > "$STATE/zones.json"
  ZONE_ID=$(jq -er --arg zone "${DNS_ZONE_NAME%.}." '.HostedZones[] | select(.Name==$zone and .Config.PrivateZone==false) | .Id | split("/")[-1]' "$STATE/zones.json")
  DOMAIN="vault-vm.${DNS_ZONE_NAME%.}"
fi
jq -n --arg vpc "$VPC" --arg region "$AWS_REGION" --argjson subnets "$SUBNETS" \
  --arg sg "$(jq -r .cluster.resourcesVpcConfig.clusterSecurityGroupId "$STATE/eks.json")" \
  --arg cidr "$(curl -fsS https://checkip.amazonaws.com)/32" --rawfile key "$STATE/id_ed25519.pub" \
  --arg zone "$ZONE_ID" --arg domain "$DOMAIN" \
  '{vpc_id:$vpc,region:$region,subnet_ids:$subnets,eks_security_group_id:$sg,admin_cidr:$cidr,public_key:$key,zone_id:$zone,domain:$domain}' > "$STATE/deployment-input.json"
cp "$STATE/deployment-input.json" "$VM_ROOT/terraform/infrastructure/runtime.auto.tfvars.json"
terraform -chdir="$VM_ROOT/terraform/infrastructure" init -input=false
terraform -chdir="$VM_ROOT/terraform/infrastructure" validate
terraform -chdir="$VM_ROOT/terraform/infrastructure" plan -input=false -out="$STATE/infrastructure.tfplan"
# Fail closed: this notebook never replaces or destroys an existing resource.
terraform -chdir="$VM_ROOT/terraform/infrastructure" show -json "$STATE/infrastructure.tfplan" |
  jq -e 'all(.resource_changes[]?; .change.actions | index("delete") | not)' >/dev/null
terraform -chdir="$VM_ROOT/terraform/infrastructure" apply -input=false "$STATE/infrastructure.tfplan"
terraform -chdir="$VM_ROOT/terraform/infrastructure" output -json | jq 'with_entries(.value=.value.value)' > "$STATE/infrastructure.json"
jq '{vault_address,nodes:(.nodes | map_values({public_ip,private_ip,cluster,zone}))}' "$STATE/infrastructure.json"

# TLS interno con OpenSSL
set -euo pipefail
source ../scripts/notebook-env.sh
CLUSTER=primary
NODE_COUNT=6
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

# Configurar Vault y systemd por SSH
set -euo pipefail
source ../scripts/notebook-env.sh
CLUSTER=primary
NODE_COUNT=6
LICENSE_FILE="${VAULT_LICENSE_FILE:-$VM_ROOT/../vault.hclic}"
test -s "$LICENSE_FILE"
while IFS=$'\t' read -r node public private zone internal; do
  for attempt in $(seq 1 120); do
    ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo test -f /var/lib/vault/rhel9-ready' && break
    sleep 5
  done
  # License and private key travel through stdin, never cloud-init or Terraform state.
  for file in ca.pem "$node.pem" "$node.key"; do
    target=$file
    [[ "$file" != "$node.pem" ]] || target=server.pem
    [[ "$file" != "$node.key" ]] || target=server.key
    ssh "${SSH_ARGS[@]}" "ec2-user@$public" "sudo sh -c 'umask 077; cat > /etc/vault.d/tls/$target; chown vault:vault /etc/vault.d/tls/$target'" < "$STATE/$file"
  done
  ssh "${SSH_ARGS[@]}" "ec2-user@$public" "sudo sh -c 'umask 077; cat > /etc/vault.d/vault.hclic; chown vault:vault /etc/vault.d/vault.hclic'" < "$LICENSE_FILE"
  cat > "$STATE/$node.hcl" <<EOF
ui = true
api_addr = "https://$internal:8200"
cluster_addr = "https://$private:8201"
disable_mlock = true
enable_response_header_hostname     = true
enable_response_header_raft_node_id = true
plugin_directory = "/opt/vault/plugins"
listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file = "/etc/vault.d/tls/server.pem"
  tls_key_file = "/etc/vault.d/tls/server.key"
}
seal "awskms" {
  region = "$AWS_REGION"
  kms_key_id = "$(jq -r .kms_key_id "$STATE/infrastructure.json")"
}
storage "raft" {
  path = "/var/lib/vault"
  node_id = "$node"
  autopilot_redundancy_zone = "$zone"
EOF
  while read -r peer; do
    cat >> "$STATE/$node.hcl" <<EOF
  retry_join {
    leader_api_addr = "https://$peer:8200"
    leader_ca_cert_file = "/etc/vault.d/tls/ca.pem"
  }
EOF
  done < <(jq -r --arg cluster "$CLUSTER" --arg node "$node" '.nodes | to_entries[] | select(.value.cluster==$cluster and .key!=$node) | .value.internal_fqdn' "$STATE/infrastructure.json")
  cat >> "$STATE/$node.hcl" <<'EOF'
}
telemetry {
  prometheus_retention_time = "12h"
  disable_hostname = true
}
EOF
  ssh "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo tee /etc/vault.d/vault.hcl >/dev/null' < "$STATE/$node.hcl"
  ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo chown vault:vault /etc/vault.d/vault.hcl; sudo chmod 600 /etc/vault.d/vault.hcl; sudo systemctl enable vault; if sudo systemctl is-active --quiet vault; then sudo systemctl reload vault; else sudo systemctl start vault; fi'
done < <(jq -r --arg cluster "$CLUSTER" '.nodes | to_entries[] | select(.value.cluster==$cluster) | [.key,.value.public_ip,.value.private_ip,.value.zone,.value.internal_fqdn] | @tsv' "$STATE/infrastructure.json")

# Inicializar, unir Raft y verificar RHEL 9
set -euo pipefail
source ../scripts/notebook-env.sh
CLUSTER=primary
NODE_COUNT=6
FIRST=$(jq -r --arg node "$CLUSTER-0" '.nodes[$node].api_fqdn' "$STATE/infrastructure.json")
for attempt in $(seq 1 60); do
  health=$(curl -sS --cacert "$STATE/ca.pem" "https://$FIRST:8200/v1/sys/health" 2>/dev/null || true)
  jq -e 'has("initialized")' <<<"$health" >/dev/null 2>&1 && break
  sleep 3
done
jq -e 'has("initialized")' <<<"$health" >/dev/null
if [[ "$(jq -r .initialized <<<"$health")" == false ]]; then
  curl -fsS --cacert "$STATE/ca.pem" -X POST -H 'Content-Type: application/json' \
    --data '{"recovery_shares":1,"recovery_threshold":1}' "https://$FIRST:8200/v1/sys/init" > "$STATE/$CLUSTER-init.json"
fi
if [[ "$(jq -r .replication_performance_mode <<<"$health")" != secondary ]]; then
  export VAULT_ADDR="https://$FIRST:8200" VAULT_CACERT="$STATE/ca.pem"
  export VAULT_TOKEN="$(jq -r .root_token "$STATE/$CLUSTER-init.json")"
  for attempt in $(seq 1 90); do
    if vault operator raft list-peers -format=json | jq -e --argjson n "$NODE_COUNT" '.data.config.servers | length==$n' >/dev/null; then break; fi
    sleep 5
  done
  vault operator raft list-peers -format=json | jq -e --argjson n "$NODE_COUNT" '.data.config.servers | length==$n'
  vault audit list -format=json | jq -e 'has("file/")' >/dev/null || vault audit enable file file_path=/var/log/vault/audit.json mode=0640
fi
while IFS=$'\t' read -r node public fqdn; do
  h=$(curl -sS --cacert "$STATE/ca.pem" "https://$fqdn:8200/v1/sys/health")
  if [[ "$(jq -r .sealed <<<"$h")" == true ]]; then
    ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" sudo systemctl restart vault
  fi
  for attempt in $(seq 1 60); do
    curl -sS --cacert "$STATE/ca.pem" "https://$fqdn:8200/v1/sys/health" | jq -e '.initialized and (.sealed|not)' >/dev/null && break
    sleep 3
  done
  curl -sS --cacert "$STATE/ca.pem" "https://$fqdn:8200/v1/sys/health" | jq -e '.initialized and (.sealed|not)'
  ssh "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo bash -se' <<'REMOTE'
. /etc/os-release
test "$ID" = rhel
[[ "$VERSION_ID" == 9.* ]]
test "$(getenforce)" = Enforcing
systemctl is-active --quiet vault
echo "$PRETTY_NAME"
REMOTE
done < <(jq -r --arg c "$CLUSTER" '.nodes | to_entries[] | select(.value.cluster==$c) | [.key,.value.public_ip,.value.api_fqdn] | @tsv' "$STATE/infrastructure.json")

if [[ "$CLUSTER" == primary ]]; then
  PUBLIC_ADDR=$(jq -r .vault_address "$STATE/infrastructure.json")
  for attempt in $(seq 1 60); do
    curl -fsS "$PUBLIC_ADDR/v1/sys/health" | jq -e '.initialized and (.sealed|not)' >/dev/null && break
    sleep 3
  done
  curl -fsS "$PUBLIC_ADDR/v1/sys/health" | jq -e '.initialized and (.sealed|not)' >/dev/null
fi

# Fallo del líder y recuperación
set -euo pipefail
source ../scripts/notebook-env.sh
CLUSTER=primary
NODE_COUNT=6
vault secrets list -format=json | jq -e 'has("ha-check/")' >/dev/null || vault secrets enable -path=ha-check kv-v2
for attempt in $(seq 1 60); do vault read ha-check/config >/dev/null 2>&1 && break; sleep 1; done
vault read ha-check/config >/dev/null

marker=$(openssl rand -hex 12)
vault kv put ha-check/probe value="$marker" >/dev/null
ACTIVE=''
while IFS=$'\t' read -r node public fqdn; do
  if curl -sS --cacert "$STATE/ca.pem" "https://$fqdn:8200/v1/sys/health" | jq -e '.standby==false' >/dev/null; then ACTIVE=$public; break; fi
done < <(jq -r '.nodes | to_entries[] | select(.value.cluster=="primary") | [.key,.value.public_ip,.value.api_fqdn] | @tsv' "$STATE/infrastructure.json")
test -n "$ACTIVE"
trap 'ssh "${SSH_ARGS[@]}" "ec2-user@$ACTIVE" sudo systemctl start vault' EXIT
ssh "${SSH_ARGS[@]}" "ec2-user@$ACTIVE" sudo systemctl stop vault
for attempt in $(seq 1 60); do
  [[ "$(vault kv get -field=value ha-check/probe 2>/dev/null || true)" == "$marker" ]] && break
  sleep 3
done
[[ "$(vault kv get -field=value ha-check/probe)" == "$marker" ]]
vault kv put ha-check/after-failover value=write-after-election >/dev/null
ssh "${SSH_ARGS[@]}" "ec2-user@$ACTIVE" sudo systemctl start vault
trap - EXIT
for attempt in $(seq 1 90); do
  vault operator raft autopilot state -format=json | jq -e .Healthy >/dev/null && break
  sleep 3
done
vault operator raft autopilot state -format=json | jq -e .Healthy
