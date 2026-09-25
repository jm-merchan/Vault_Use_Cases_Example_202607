"""Author transparent Bash notebooks and equivalent copyable .sh files.
Python only assembles documents; all scenario operations are literal Bash cells.
"""
from pathlib import Path
import json,nbformat,textwrap
ROOT=Path(__file__).resolve().parents[1]
CASES=[]
ENV='set -euo pipefail\nsource ../scripts/notebook-env.sh\n'
BOOT=r'''
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
'''
AZURE=r'''
if ! az account get-access-token --query expiresOn -o tsv >/dev/null 2>&1; then
  az login --tenant "$AZURE_TENANT_ID" --subscription "$AZURE_SUBSCRIPTION_ID" --output none
fi
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
[[ "$(az account show --query tenantId -o tsv)" == "$AZURE_TENANT_ID" ]]
az account show --query '{subscription:name,id:id,tenant:tenantId}' -o table
'''
def add(name,title,steps,desc='',preamble=''):
    CASES.append((name,title,[('Entorno y sesión AWS',BOOT)]+steps,desc,preamble))
def mount(path,kind='kv-v2'):
    return f'vault secrets list -format=json | jq -e \'has("{path}/")\' >/dev/null || vault secrets enable -path={path} {kind}\n' + (f'for attempt in $(seq 1 60); do vault read {path}/config >/dev/null 2>&1 && break; sleep 1; done\nvault read {path}/config >/dev/null\n' if kind=='kv-v2' else '')
def auth(path,kind):
    return f'vault auth list -format=json | jq -e \'has("{path}/")\' >/dev/null || vault auth enable -path={path} {kind}\n'
def tf(directory,variables):
    return f'''vault write -f sys/activation-flags/secrets-sync/activate >/dev/null
cat > "$VM_ROOT/terraform/{directory}/runtime.auto.tfvars.json" <<EOF
{variables}
EOF
# El provider no puede refrescar una asociación antigua si su mount ya no existe.
# Solo se retiran del estado local esas referencias obsoletas; no se borran recursos cloud.
vault secrets list -format=json > "$STATE/{directory}-mounts.json"
if [[ -s "$VM_ROOT/terraform/{directory}/terraform.tfstate" ]] && ! jq -e --arg key "$MOUNT/" 'has($key)' "$STATE/{directory}-mounts.json" >/dev/null; then
  cp "$VM_ROOT/terraform/{directory}/terraform.tfstate" "$STATE/{directory}-before-recovery.tfstate"
  terraform -chdir="$VM_ROOT/terraform/{directory}" state list | grep -E '^vault_secrets_sync_association\.|^vault_generic_endpoint\.aws_destination$' > "$STATE/{directory}-stale-resources" || true
  while read -r resource; do
    [[ -z "$resource" ]] || terraform -chdir="$VM_ROOT/terraform/{directory}" state rm "$resource"
  done < "$STATE/{directory}-stale-resources"
fi
terraform -chdir="$VM_ROOT/terraform/{directory}" init -input=false
terraform -chdir="$VM_ROOT/terraform/{directory}" validate
terraform -chdir="$VM_ROOT/terraform/{directory}" apply -input=false -auto-approve
terraform -chdir="$VM_ROOT/terraform/{directory}" output -json > "$STATE/{directory}-outputs.json"
'''
SYNC_CHECK=r'''
marker=$(openssl rand -hex 12)
vault kv put "$MOUNT/verification" marker="$marker" >/dev/null
vault write "sys/sync/destinations/$KIND/$DEST/associations/set" mount="$MOUNT" secret_name=verification >/dev/null
for attempt in $(seq 1 90); do
  if vault read -format=json "sys/sync/destinations/$KIND/$DEST/associations" | jq -e '.data.associated_secrets | length > 0 and all(.[]; .sync_status == "SYNCED")' >/dev/null; then break; fi
  sleep 5
done
for version in 1 2; do
  if [[ "$version" == 2 ]]; then marker=$(openssl rand -hex 12); vault kv put "$MOUNT/verification" marker="$marker" >/dev/null; fi
  match=false
  for attempt in $(seq 1 60); do
    if [[ "$KIND" == aws-sm ]]; then
      actual=$(aws secretsmanager get-secret-value --secret-id "vault-vm/$MOUNT/verification" --query SecretString --output text | jq -r .marker)
    else
      actual=$(az keyvault secret show --vault-name "$KEY_VAULT" --name "vault-$MOUNT-verification" --query value -o tsv | jq -r .marker)
    fi
    if [[ "$actual" == "$marker" ]]; then match=true; break; fi
    sleep 5
  done
  "$match"
  echo "Versión $version verificada en el destino cloud"
done
vault read -format=json "sys/sync/destinations/$KIND/$DEST/associations" | jq -e '.data.associated_secrets | all(.[]; .sync_status == "SYNCED")'
'''
for name,title,directory,mp,dest,variables in [
 ('5_Secret_Sync_AWS_IRSA','Secrets Sync: perfil IAM de EC2','irsa','sync-aws-irsa','aws-sm-irsa-local','{"vault_irsa_role_name":"$(jq -r .vault_role_name "$STATE/infrastructure.json")"}'),
 ('5_Secret_Sync_AWS_IRSA_AssumeRole','Secrets Sync: EC2 y AssumeRole','irsa-assume-role','irsa-assume-role-kv','aws-sm-irsa-assume-role','{"vault_irsa_role_name":"$(jq -r .vault_role_name "$STATE/infrastructure.json")","sync_role_name":"mapfre-vm-sync-assume","aws_region":"$AWS_REGION"}'),
 ('5_Secret_Sync_AWS_WIF_Doormat','Secrets Sync: AWS WIF y Doormat','wif','mapfre-vm-wif-kv','mapfre-vm-wif-aws-sm','{"vault_pod_role_name":"$(jq -r .vault_role_name "$STATE/infrastructure.json")","public_oidc_issuer_url":"$VAULT_ADMIN_ADDR","tenant_id":"mapfre-vm-wif","aws_region":"$AWS_REGION"}'),
 ('5_Secret_Sync_AWS_static_account','Secrets Sync: rol dedicado en lugar de claves estáticas','operator-role','operator-role-kv','aws-sm-operator-role','{"vault_irsa_role_name":"$(jq -r .vault_role_name "$STATE/infrastructure.json")","sync_role_name":"mapfre-vm-operator-role","destination_name":"aws-sm-operator-role","aws_region":"$AWS_REGION"}')]:
    roleconfig='role_arn="$(terraform -chdir="$VM_ROOT/terraform/'+directory+'" output -raw sync_role_arn)"' if directory in ['operator-role','irsa-assume-role'] else ''
    config=f'''vault write -f sys/activation-flags/secrets-sync/activate
vault read -format=json "sys/sync/destinations/aws-sm/$DEST" | jq '.data | del(.credentials,.access_key_id,.secret_access_key,.session_token)'
'''
    if directory!='wif':config+=f'''# Equivalente CLI explícito del destino creado por Terraform.
vault write "sys/sync/destinations/aws-sm/$DEST" region="$AWS_REGION" {roleconfig} \\
  secret_name_template='vault-vm/{{{{ .MountPath }}}}/{{{{ .SecretPath }}}}' >/dev/null
'''
    else: config+='''# En cada actualización WIF se envían explícitamente audiencia y clave.
ROLE_ARN=$(terraform -chdir="$VM_ROOT/terraform/wif" output -raw wif_role_arn)
AUDIENCE=$(terraform -chdir="$VM_ROOT/terraform/wif" output -raw wif_audience)
vault write identity/oidc/config issuer="$VAULT_ADMIN_ADDR"
vault write "sys/sync/destinations/aws-sm/$DEST" role_arn="$ROLE_ARN" region="$AWS_REGION" \
  identity_token_audience="$AUDIENCE" identity_token_key=mapfre-vm-wif-secrets-sync-key identity_token_ttl=3600 \
  granularity=secret-path secret_name_template='vault-vm/{{ .MountPath }}/{{ .SecretPath }}' >/dev/null
# Inspección de la confianza IAM y del issuer público:
aws iam get-role --role-name "${ROLE_ARN##*/}" --query Role.AssumeRolePolicyDocument
curl -fsS "$(terraform -chdir="$VM_ROOT/terraform/wif" output -raw secrets_sync_oidc_discovery_url)" | jq '{issuer,jwks_uri}'
'''
    add(name,title,[('Crear permisos y destino con Terraform',tf(directory,variables)),('Destino Secrets Sync y configuración CLI',config),('Sincronizar y comparar dos versiones con AWS CLI',SYNC_CHECK)],'IRSA se sustituye por el instance profile de las VMs. El caso estático usa AssumeRole por indicación del usuario; no se crean usuarios IAM.',f'MOUNT={mp}\nDEST={dest}\nKIND=aws-sm\n')
for mode in ['spn','wif']:
    prefix='mvm-'+mode
    add('5_Secret_Sync_Azure_Terraform_'+mode.upper(),'Azure Secrets Sync: Terraform '+mode.upper(),[('Autenticación Azure CLI',AZURE),('Configurar Azure y Vault con Terraform',tf('azure-'+mode,'{"azure_subscription_id":"$AZURE_SUBSCRIPTION_ID","name_prefix":"'+prefix+'"'+(',"public_oidc_issuer_url":"$VAULT_ADMIN_ADDR"' if mode=='wif' else '')+'}')),('Configuración visible y comprobación en Azure',r'''
cat "$VM_ROOT/terraform/azure-'''+mode+r'''/main.tf"
KEY_VAULT=$(az keyvault list -g "mvm-'''+mode+r'''-secrets-sync-rg" --query '[0].name' -o tsv)
'''+SYNC_CHECK)],preamble=f'MOUNT={prefix}-kv\nDEST={prefix}-azure-kv\nKIND=azure-kv\n')
AZ_CLI=r'''
if [[ ! -f "$STATE/azure-cli.json" ]]; then
  RESOURCE_GROUP=mapfre-vm-cli
  KEY_VAULT="mvmcli$(openssl rand -hex 4)"
  az group create -n "$RESOURCE_GROUP" -l westeurope -o none
  az keyvault create -n "$KEY_VAULT" -g "$RESOURCE_GROUP" -l westeurope --enable-rbac-authorization true -o json > "$STATE/azure-cli-vault.json"
  az ad app create --display-name mapfre-vm-cli -o json > "$STATE/azure-cli-app.json"
  APP_ID=$(jq -r .appId "$STATE/azure-cli-app.json")
  az ad sp create --id "$APP_ID" -o json > "$STATE/azure-cli-sp.json"
  az ad app credential reset --id "$APP_ID" --append --display-name vm-poc --years 1 -o json > "$STATE/azure-cli-credential.json"
  SCOPE=$(jq -r .id "$STATE/azure-cli-vault.json")
  az role assignment create --assignee-object-id "$(jq -r .id "$STATE/azure-cli-sp.json")" --assignee-principal-type ServicePrincipal --role 'Key Vault Secrets Officer' --scope "$SCOPE" -o none
  az role assignment create --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" --assignee-principal-type User --role 'Key Vault Secrets Officer' --scope "$SCOPE" -o none
  jq --arg kv "$KEY_VAULT" --arg app "$APP_ID" --arg rg "$RESOURCE_GROUP" --arg tenant "$AZURE_TENANT_ID" '{kv:$kv,app_id:$app,client_secret:.password,tenant:$tenant,rg:$rg}' "$STATE/azure-cli-credential.json" > "$STATE/azure-cli.json"
fi
jq '{kv,app_id,tenant,rg}' "$STATE/azure-cli.json"
'''
AZ_DEST=mount('vm-azure-cli')+r'''
vault write -f sys/activation-flags/secrets-sync/activate
# jq construye el payload; curl muestra el endpoint y los headers utilizados.
jq '{key_vault_uri:("https://"+.kv+".vault.azure.net/"),client_id:.app_id,client_secret:.client_secret,tenant_id:.tenant,secret_name_template:"vault-{{ .MountPath }}-{{ .SecretPath }}"}' "$STATE/azure-cli.json" |
  curl -fsS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' \
    --data @- "$VAULT_ADDR/v1/sys/sync/destinations/azure-kv/vm-azure-cli" >/dev/null
'''
add('5_Secret_Sync_Azure_CLI_SPN','Azure Secrets Sync: Azure CLI y SPN',[('Login y suscripción Azure',AZURE),('Resource group, Key Vault, aplicación y RBAC',AZ_CLI),('Configurar el destino con curl',AZ_DEST),('Sincronizar y comprobar con az', 'KEY_VAULT=$(jq -r .kv "$STATE/azure-cli.json")\n'+SYNC_CHECK)],preamble='MOUNT=vm-azure-cli\nDEST=vm-azure-cli\nKIND=azure-kv\n')
DISCOVER=r'''
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
'''
CERTS=r'''
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
'''
CONFIGURE=r'''
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
'''
INIT=r'''
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
'''
FAILOVER=mount('ha-check')+r'''
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
'''
INIT += r'''
if [[ "$CLUSTER" == primary ]]; then
  PUBLIC_ADDR=$(jq -r .vault_address "$STATE/infrastructure.json")
  for attempt in $(seq 1 60); do
    curl -fsS "$PUBLIC_ADDR/v1/sys/health" | jq -e '.initialized and (.sealed|not)' >/dev/null && break
    sleep 3
  done
  curl -fsS "$PUBLIC_ADDR/v1/sys/health" | jq -e '.initialized and (.sealed|not)' >/dev/null
fi
'''
add('1_Deploy_Vault_AWS','Vault Enterprise en VMs RHEL 9',[('Descubrir AWS, red y desplegar Terraform',DISCOVER),('TLS interno con OpenSSL',CERTS),('Configurar Vault y systemd por SSH',CONFIGURE),('Inicializar, unir Raft y verificar RHEL 9',INIT),('Fallo del líder y recuperación',FAILOVER)],'Seis nodos primarios, tres secundarios y una VM de aplicación. El código cloud-init completo está en scripts/cloud-init.sh.tftpl; la infraestructura se declara en terraform/infrastructure.',preamble='CLUSTER=primary\nNODE_COUNT=6\n')
add('9_VAULT_PR','Clúster secundario RHEL 9',[('Configurar los tres nodos por SSH',CONFIGURE),('Inicialización y estado de todos los nodos',INIT)],'Después de activar PR, el token inicial del secundario deja de ser válido. Los standbys sellados se reinician para ejecutar auto-unseal.',preamble='CLUSTER=secondary\nNODE_COUNT=3\n')
def manifest(ns,kind,name):
    text=(ROOT/f'assets/manifests/{ns}-{kind}-{name}.yaml').read_text()
    text=text.replace('https://vault-vm-apps.jose-merchan.sbx.hashidemos.io','${VAULT_APPLICATION_ADDR}')
    return 'cat <<EOF | "${KUBECTL[@]}" apply -f -\n'+text+'EOF\n'
def namespace(name):return f'"${{KUBECTL[@]}}" create namespace {name} --dry-run=client -o yaml | "${{KUBECTL[@]}}" apply -f -\n'
def service(name,key):
    return namespace('vm-demo')+f'''[[ -s "$STATE/{name}-password" ]] || openssl rand -hex 20 | tr -d '\n' > "$STATE/{name}-password"
"${{KUBECTL[@]}}" -n vm-demo create secret generic {name} --from-file={key}="$STATE/{name}-password" --dry-run=client -o yaml | "${{KUBECTL[@]}}" apply -f -
'''+('' if name=='ldap' else manifest('vm-demo','persistentvolumeclaim',name+'-data'))+manifest('vm-demo','deployment',name)+manifest('vm-demo','service',name)+f'''"${{KUBECTL[@]}}" -n vm-demo rollout status deployment/{name} --timeout=1800s
for attempt in $(seq 1 120); do
  endpoint=$("${{KUBECTL[@]}}" -n vm-demo get service {name} -o json | jq -r '.status.loadBalancer.ingress[0].hostname // empty')
  [[ -z "$endpoint" ]] || break
  sleep 5
done
test -n "$endpoint"
printf '%s' "$endpoint" > "$STATE/{name}-endpoint"
'''
PG_CONFIG=mount('database','database')+r'''
if ! vault read database/config/postgresql >/dev/null 2>&1; then
  # Reconcile the isolated demo DB if Vault was freshly initialized after an earlier root rotation.
  printf "ALTER USER postgres WITH PASSWORD '%s';\n" "$(cat "$STATE/postgres-password")" |
    "${KUBECTL[@]}" -n vm-demo exec -i deployment/postgres -- psql -U postgres -v ON_ERROR_STOP=1 >/dev/null
  vault write database/config/postgresql plugin_name=postgresql-database-plugin \
    allowed_roles=readonly,agent-db username=postgres password=@"$STATE/postgres-password" \
    connection_url="postgresql://{{username}}:{{password}}@$(cat "$STATE/postgres-endpoint"):5432/postgres?sslmode=disable"
fi
cat > "$STATE/postgres-create.sql" <<'SQL'
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT CONNECT ON DATABASE postgres TO "{{name}}";
GRANT USAGE ON SCHEMA public TO "{{name}}";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";
SQL
for role in readonly agent-db; do
  vault write "database/roles/$role" db_name=postgresql creation_statements=@"$STATE/postgres-create.sql" default_ttl=3m max_ttl=1h
done
'''
PG_VERIFY=r'''
for phase in initial after-root-rotation; do
  [[ "$phase" != after-root-rotation ]] || vault write -f database/rotate-root/postgresql >/dev/null
  vault read -format=json database/creds/readonly > "$STATE/pg-check.json"
  user=$(jq -r .data.username "$STATE/pg-check.json")
  pass=$(jq -r .data.password "$STATE/pg-check.json")
  printf 'export PGPASSWORD=%q\npsql -h postgres.vm-demo.svc.cluster.local -U %q -d postgres -Atc "select 1"\n' "$pass" "$user" |
    "${KUBECTL[@]}" -n vm-demo exec -i deployment/postgres -- sh -se | grep -qx 1
  vault lease revoke "$(jq -r .lease_id "$STATE/pg-check.json")" >/dev/null
  if printf 'export PGPASSWORD=%q\npsql -h postgres.vm-demo.svc.cluster.local -U %q -d postgres -Atc "select 1"\n' "$pass" "$user" |
      "${KUBECTL[@]}" -n vm-demo exec -i deployment/postgres -- sh -se >/dev/null 2>&1; then
    echo 'ERROR: la credencial revocada sigue funcionando' >&2; exit 1
  fi
done
echo 'SQL: emisión, login, revocación y rotación de root verificadas'
'''
K_INSTALL=namespace('vm-consumers')+r'''
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
if ! "${KUBECTL[@]}" get deployments -A -o json | jq -e 'any(.items[]; .metadata.name | contains("vault-secrets-operator"))' >/dev/null; then
  helm --kube-context "$KUBE_CONTEXT" upgrade --install vm-vso hashicorp/vault-secrets-operator -n vm-vso-system --create-namespace --version 0.10.0 --wait
fi
if ! "${KUBECTL[@]}" get crd secretproviderclasses.secrets-store.csi.x-k8s.io >/dev/null 2>&1; then
  helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts --force-update
  helm --kube-context "$KUBE_CONTEXT" upgrade --install vm-csi secrets-store-csi-driver/secrets-store-csi-driver -n vm-csi-system --create-namespace --set enableSecretRotation=true --set rotationPollInterval=30s --wait
fi
if ! "${KUBECTL[@]}" get daemonset -A -o json | jq -e 'any(.items[]; .metadata.name | contains("vault-csi-provider"))' >/dev/null; then
  helm --kube-context "$KUBE_CONTEXT" upgrade --install vm-vault-csi hashicorp/vault -n vm-csi-system --create-namespace --version 0.34.0 --set server.enabled=false --set injector.enabled=false --set csi.enabled=true --wait
fi
'''
K_AUTH=namespace('vm-consumers')+r'''
for sa in consumer reviewer; do
  "${KUBECTL[@]}" -n vm-consumers create serviceaccount "$sa" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
done
"${KUBECTL[@]}" create clusterrolebinding vm-consumers-reviewer --clusterrole=system:auth-delegator --serviceaccount=vm-consumers:reviewer --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" config view --minify --raw --flatten -o json > "$STATE/kube-connection.json"
K8S_SERVER=$(jq -r '.clusters[0].cluster.server' "$STATE/kube-connection.json")
jq -r '.clusters[0].cluster."certificate-authority-data"' "$STATE/kube-connection.json" | openssl base64 -d -A > "$STATE/kubernetes-ca.pem"
"${KUBECTL[@]}" -n vm-consumers create token reviewer --duration=24h > "$STATE/reviewer.jwt"
'''+auth('vm-kubernetes','kubernetes')+r'''
vault write auth/vm-kubernetes/config kubernetes_host="$K8S_SERVER" \
  kubernetes_ca_cert=@"$STATE/kubernetes-ca.pem" token_reviewer_jwt=@"$STATE/reviewer.jwt" disable_local_ca_jwt=true
vault policy write vm-consumer - <<'HCL'
path "secret/data/vm/*" { capabilities = ["read"] }
path "vm-gha/secret/data/*" { capabilities = ["read"] }
path "database/creds/readonly" { capabilities = ["read"] }
path "aws-vm/sts/demo" { capabilities = ["read"] }
HCL
vault write auth/vm-kubernetes/role/consumer bound_service_account_names=consumer \
  bound_service_account_namespaces=vm-consumers audience=vault token_policies=vm-consumer token_ttl=10m
"${KUBECTL[@]}" -n vm-consumers create token consumer --audience=vault --duration=10m > "$STATE/consumer.jwt"
vault write -format=json auth/vm-kubernetes/login role=consumer jwt=@"$STATE/consumer.jwt" > "$STATE/consumer-login.json"
jq -e '.auth.client_token | length>0' "$STATE/consumer-login.json" >/dev/null
"${KUBECTL[@]}" -n vm-consumers create token reviewer --audience=vault --duration=10m > "$STATE/wrong-sa.jwt"
if vault write auth/vm-kubernetes/login role=consumer jwt=@"$STATE/wrong-sa.jwt" >/dev/null 2>&1; then exit 1; fi
'''
K_RES=mount('secret')+'vault kv put secret/vm/static value=vm-version-1 >/dev/null\n'
for kind,name in [('vaultconnection','vm-vault'),('vaultauth','vm-vault'),('vaultstaticsecret','vm-static'),('vaultdynamicsecret','vm-dynamic'),('secretproviderclass','vm-vault'),('pod','vm-secret-reader')]:
    if kind=='pod':K_RES+='"${KUBECTL[@]}" -n vm-consumers delete pod vm-secret-reader --ignore-not-found --wait=true\n'
    K_RES+=manifest('vm-consumers',kind,name)
K_RES+='"${KUBECTL[@]}" -n vm-consumers wait --for=condition=Ready pod/vm-secret-reader --timeout=300s\n'
K_VERIFY=r'''
# VSO y CSI deben obtener la misma actualización KV.
marker="vm-$(openssl rand -hex 8)"
vault kv put secret/vm/static value="$marker" >/dev/null
for attempt in $(seq 1 90); do
  vso=$("${KUBECTL[@]}" -n vm-consumers get secret vm-static -o json | jq -r '.data.value | @base64d')
  csi=$("${KUBECTL[@]}" -n vm-consumers exec vm-secret-reader -- cat /csi/static)
  [[ "$vso" == "$marker" && "$csi" == "$marker" ]] && break
  sleep 5
done
[[ "$vso" == "$marker" && "$csi" == "$marker" ]]
for source in vso csi; do
  if [[ "$source" == vso ]]; then
    "${KUBECTL[@]}" -n vm-consumers get secret vm-dynamic -o json > "$STATE/vso-db.json"
    user=$(jq -r '.data.username | @base64d' "$STATE/vso-db.json")
    pass=$(jq -r '.data.password | @base64d' "$STATE/vso-db.json")
  else
    user=$("${KUBECTL[@]}" -n vm-consumers exec vm-secret-reader -- cat /csi/db-user)
    pass=$("${KUBECTL[@]}" -n vm-consumers exec vm-secret-reader -- cat /csi/db-password)
  fi
  printf 'export PGPASSWORD=%q\npsql -h postgres.vm-demo.svc.cluster.local -U %q -d postgres -Atc "select 1"\n' "$pass" "$user" |
    "${KUBECTL[@]}" -n vm-demo exec -i deployment/postgres -- sh -se | grep -qx 1
done
echo 'VSO/CSI: actualización KV y ambos logins SQL correctos'
'''
add('4_VSO_CSI','VSO y CSI con Vault externo',[('Instalar o reutilizar controladores',K_INSTALL),('Configurar Kubernetes auth con Vault CLI',K_AUTH),('PostgreSQL auxiliar en Kubernetes',service('postgres','POSTGRES_PASSWORD')),('Configurar Database Secrets Engine',PG_CONFIG),('VaultConnection, VaultAuth, VSO y CSI',K_RES),('Comprobar rotación y conexión SQL',K_VERIFY)])
for dynamic in [False,True]:
    name='db' if dynamic else 'static';port=18081 if dynamic else 18080;base='/opt/vm-agent-'+name
    policy_path='database/creds/agent-db' if dynamic else 'secret/data/jboss/demo'
    role=auth('approle','approle')+mount('secret')+f'''vault policy write agent-{name} - <<'HCL'
path "{policy_path}" {{ capabilities = ["read"] }}
HCL
vault write auth/approle/role/agent-{name} token_policies=agent-{name} token_ttl=10m token_max_ttl=1h secret_id_ttl=24h
vault read -field=role_id auth/approle/role/agent-{name}/role-id > "$STATE/agent-{name}-role-id"
vault write -f -field=secret_id auth/approle/role/agent-{name}/secret-id > "$STATE/agent-{name}-secret-id"
'''
    if not dynamic:role+='vault kv put secret/jboss/demo username=appuser password=version-1 >/dev/null\n'
    remote=r'''
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
. /etc/os-release
test "$ID" = rhel
[[ "$VERSION_ID" == 9.* ]]
test "$(getenforce)" = Enforcing
id vaultapp >/dev/null 2>&1 || useradd --system --home-dir /opt/vm-agent --shell /sbin/nologin vaultapp
mkdir -p BASE/secrets
if [[ ! -d BASE/wildfly ]]; then
  curl -fsSL https://github.com/wildfly/wildfly/releases/download/36.0.1.Final/wildfly-36.0.1.Final.zip -o /var/tmp/wildfly.zip
  unzip -oq /var/tmp/wildfly.zip -d BASE
  mv BASE/wildfly-36.0.1.Final BASE/wildfly
fi
mkdir -p BASE/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib
chown -R vaultapp:vaultapp BASE
REMOTE
for item in role-id secret-id; do
  target=${item//-/_}
  ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" "sudo sh -c 'umask 077; cat > BASE/$target; chown vaultapp:vaultapp BASE/$target'" < "$STATE/agent-NAME-$item"
done
'''.replace('BASE',base).replace('NAME',name)
    content='{{ with secret "database/creds/agent-db" }}\ndemo.username={{ .Data.username }}\ndemo.password={{ .Data.password }}\n{{ end }}' if dynamic else '{{ with secret "secret/data/jboss/demo" }}\ndemo.username={{ .Data.data.username }}\ndemo.password={{ .Data.data.password }}\n{{ end }}'
    config=f'''# La configuración HCL completa se entrega a la VM por stdin.
ssh "${{SSH_ARGS[@]}}" "ec2-user@$APP_IP" 'sudo tee {base}/agent.hcl >/dev/null' <<EOF
vault {{ address = "$VAULT_ADDR" }}
auto_auth {{
  method "approle" {{
    config = {{ role_id_file_path = "{base}/role_id", secret_id_file_path = "{base}/secret_id", remove_secret_id_file_after_reading = false }}
  }}
  sink "file" {{ config = {{ path = "{base}/token" }} }}
}}
template_config {{ static_secret_render_interval = "5s" }}
template {{
  destination = "{base}/secrets/application.properties"
  perms = "0600"
  contents = <<EOH
{content}
EOH
  exec {{
    command = ["/usr/bin/sudo", "/usr/bin/systemctl", "restart", "vm-wildfly-{name}.service"]
    timeout = "90s"
  }}
}}
EOF
ssh "${{SSH_ARGS[@]}}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
cat > /etc/systemd/system/vm-wildfly-{name}.service <<'UNIT'
[Unit]
Description=VM WildFly {name}
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
Environment=JAVA_HOME=/usr/lib/jvm/jre-21-openjdk
ExecStart={base}/wildfly/bin/standalone.sh -b 127.0.0.1 -Djboss.socket.binding.port-offset={10001 if dynamic else 10000} -P {base}/secrets/application.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/vm-agent-{name}.service <<'UNIT'
[Unit]
Description=Vault Agent {name}
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
ExecStart=/usr/local/bin/vault agent -config={base}/agent.hcl
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
printf '%s\\n' 'vaultapp ALL=(root) NOPASSWD: /usr/bin/systemctl restart vm-wildfly-{name}.service' > /etc/sudoers.d/vm-agent-{name}
chmod 440 /etc/sudoers.d/vm-agent-{name}
chown vaultapp:vaultapp {base}/agent.hcl
chmod 600 {base}/agent.hcl
REMOTE
'''
    jsp='<%@ page import="java.security.*" %><% byte[] digest=MessageDigest.getInstance("SHA-256").digest(System.getProperty("demo.password").getBytes("UTF-8"));for(byte b:digest)out.print(String.format("%02x",b)); %>'
    if dynamic:jsp='<%@ page import="java.sql.*" %><% Class.forName("org.postgresql.Driver"); try(Connection c=DriverManager.getConnection("jdbc:postgresql://$(cat "$STATE/postgres-endpoint"):5432/postgres",System.getProperty("demo.username"),System.getProperty("demo.password"))){try(Statement s=c.createStatement();ResultSet r=s.executeQuery("select 1")){if(r.next() && r.getInt(1)==1)out.print("DB_CONNECTION_OK");else response.setStatus(500);}} %>'
    app=f'''ssh "${{SSH_ARGS[@]}}" "ec2-user@$APP_IP" 'sudo tee {base}/wildfly/standalone/deployments/vault-demo.war/index.jsp >/dev/null' <<EOF
{jsp}
EOF
ssh "${{SSH_ARGS[@]}}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
'''
    if dynamic:app+=f'''systemctl stop vm-agent-db-once.timer vm-agent-db-once.service 2>/dev/null || true
curl -fsSL https://jdbc.postgresql.org/download/postgresql-42.7.7.jar -o {base}/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib/postgresql.jar
'''
    app+=f'''chown -R vaultapp:vaultapp {base}/wildfly/standalone/deployments
chmod -R u+rwX,g+rX {base}/wildfly/standalone/deployments
touch {base}/wildfly/standalone/deployments/vault-demo.war.dodeploy
systemctl daemon-reload
systemctl enable vm-wildfly-{name} vm-agent-{name}
systemctl restart vm-agent-{name}
REMOTE
'''
    expected='DB_CONNECTION_OK' if dynamic else '$(printf version-1 | openssl dgst -sha256 | awk \'{print $NF}\')'
    app+=f'''expected="{expected}"
for attempt in $(seq 1 90); do
  response=$(ssh "${{SSH_ARGS[@]}}" "ec2-user@$APP_IP" 'curl -fsS --max-time 10 http://127.0.0.1:{port}/vault-demo/index.jsp' 2>/dev/null || true)
  [[ "$response" == *"$expected"* ]] && break
  sleep 3
done
[[ "$response" == *"$expected"* ]]
echo 'Respuesta de WildFly verificada'
'''
    rotate=r'''
marker=$(openssl rand -hex 16)
vault kv put secret/jboss/demo username=appuser password="$marker" >/dev/null
expected=$(printf '%s' "$marker" | openssl dgst -sha256 | awk '{print $NF}')
for attempt in $(seq 1 60); do
  response=$(ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'curl -fsS --max-time 10 http://127.0.0.1:18080/vault-demo/index.jsp' 2>/dev/null || true)
  [[ "$response" == *"$expected"* ]] && break
  sleep 3
done
[[ "$response" == *"$expected"* ]]
echo 'Cambio KV, renderizado, reinicio y valor servido verificados'
'''
    if dynamic:rotate=r'''
vault lease revoke -prefix database/creds/agent-db >/dev/null
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
systemctl restart vm-agent-db
sleep 5
systemctl stop vm-agent-db
sed 's/template_config {/exit_after_auth = true\ntemplate_config {/' /opt/vm-agent-db/agent.hcl > /opt/vm-agent-db/oneshot.hcl
chown vaultapp:vaultapp /opt/vm-agent-db/oneshot.hcl
chmod 600 /opt/vm-agent-db/oneshot.hcl
cat > /etc/systemd/system/vm-agent-db-once.service <<'UNIT'
[Unit]
Description=One-shot SQL credential refresh
[Service]
Type=oneshot
User=vaultapp
Group=vaultapp
ExecStart=/usr/local/bin/vault agent -config=/opt/vm-agent-db/oneshot.hcl
UNIT
cat > /etc/systemd/system/vm-agent-db-once.timer <<'UNIT'
[Unit]
Description=Refresh SQL credentials every two minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl start vm-agent-db-once
systemctl enable --now vm-agent-db-once.timer
systemctl is-active --quiet vm-agent-db-once.timer
REMOTE
for attempt in $(seq 1 60); do
  response=$(ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'curl -fsS --max-time 10 http://127.0.0.1:18081/vault-demo/index.jsp' 2>/dev/null || true)
  [[ "$response" == *DB_CONNECTION_OK* ]] && break
  sleep 3
done
[[ "$response" == *DB_CONNECTION_OK* ]]
echo 'Nuevas credenciales JDBC y timer verificados'
'''
    steps=([('PostgreSQL en Kubernetes',service('postgres','POSTGRES_PASSWORD')),('Motor Database y roles SQL',PG_CONFIG),('Validar revocación y rotación de root',PG_VERIFY)] if dynamic else [])
    steps += [('AppRole y política del Agent',role),('Preparar RHEL y WildFly por SSH',remote),('Plantilla HCL, systemd y sudoers',config),('Aplicación y comprobación HTTP',app),('Rotación y verificación funcional',rotate)]
    add('3B_JBOSS_DB_Engine_Agent' if dynamic else '3A_JBOSS_WASS_Agent','WildFly y Vault Agent: '+('credenciales dinámicas' if dynamic else 'KV estático'),steps)
# Oracle: the installer body is Bash already; embed it instead of invoking Python.
import ast
services_tree=ast.parse((ROOT/'scripts/services.py').read_text())
oracle_function=next(n for n in services_tree.body if isinstance(n,ast.FunctionDef) and n.name=='oracle_install')
oracle_install_body=ast.literal_eval(oracle_function.body[0].value)
ORACLE_INSTALL='''while read -r public; do
  ssh "${SSH_ARGS[@]}" "ec2-user@$public" sudo bash -se <<'REMOTE'
'''+oracle_install_body+'''REMOTE
done < <(jq -r '.nodes[] | select(.cluster!="app") | .public_ip' "$STATE/infrastructure.json")
vault plugin register -version=v0.14.1+ent \\
  -env=LD_LIBRARY_PATH=/opt/oracle/instantclient_23_26 -env=ORACLE_HOME=/opt/oracle/instantclient_23_26 \\
  database vault-plugin-database-oracle
'''
ORACLE_CONFIG=mount('database','database')+r'''
[[ -s "$STATE/oracle-vault-password" ]] || openssl rand -hex 20 | tr -d '\n' > "$STATE/oracle-vault-password"
PASSWORD=$(cat "$STATE/oracle-vault-password")
"${KUBECTL[@]}" -n vm-demo exec -i deployment/oracle -- bash -se <<EOF
sqlplus -L -s /nolog <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER=FREEPDB1;
DECLARE n NUMBER; BEGIN SELECT COUNT(*) INTO n FROM dba_users WHERE username='VAULT'; IF n=0 THEN EXECUTE IMMEDIATE 'CREATE USER VAULT IDENTIFIED BY "$PASSWORD"'; END IF; END;
/
GRANT CREATE USER, ALTER USER, DROP USER, CREATE SESSION TO VAULT WITH ADMIN OPTION;
GRANT CONNECT TO VAULT WITH ADMIN OPTION;
GRANT SELECT ON SYS.GV_\$SESSION TO VAULT;
GRANT SELECT ON SYS.V_\$SQL TO VAULT;
GRANT ALTER SYSTEM TO VAULT;
EXIT
SQL
EOF
vault write database/config/oracle plugin_name=vault-plugin-database-oracle plugin_version=v0.14.1+ent \
  allowed_roles=oracle-dynamic,oracle-static username=VAULT password=@"$STATE/oracle-vault-password" \
  connection_url="{{username}}/{{password}}@//$(cat "$STATE/oracle-endpoint"):1521/FREEPDB1"
vault write database/roles/oracle-dynamic db_name=oracle default_ttl=5m max_ttl=1h \
  creation_statements='CREATE USER {{username}} IDENTIFIED BY "{{password}}"; GRANT CONNECT TO {{username}}; GRANT CREATE SESSION TO {{username}};'
if ! vault read database/static-roles/oracle-static >/dev/null 2>&1; then
  [[ -s "$STATE/oracle-static-password" ]] || openssl rand -hex 20 | tr -d '\n' > "$STATE/oracle-static-password"
  "${KUBECTL[@]}" -n vm-demo exec -i deployment/oracle -- bash -se <<EOF
sqlplus -L -s /nolog <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER=FREEPDB1;
DECLARE n NUMBER; BEGIN SELECT COUNT(*) INTO n FROM dba_users WHERE username='VAULT_STATIC'; IF n=0 THEN EXECUTE IMMEDIATE 'CREATE USER VAULT_STATIC IDENTIFIED BY "$(cat "$STATE/oracle-static-password")"'; END IF; END;
/
GRANT CREATE SESSION TO VAULT_STATIC;
EXIT
SQL
EOF
  vault write database/static-roles/oracle-static db_name=oracle username=VAULT_STATIC rotation_period=24h
fi
'''
# SQL test function is defined visibly in the cell, so it is also copyable.
ORACLE_VERIFY=r'''
oracle_login() {
  local user pass
  user=$(jq -r .data.username "$1"); pass=$(jq -r .data.password "$1")
  "${KUBECTL[@]}" -n vm-demo exec -i deployment/oracle -- bash -se <<EOF
sqlplus -L -s /nolog <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
CONNECT $user/"$pass"@//127.0.0.1:1521/FREEPDB1
SELECT 'LOGIN_OK' FROM dual;
EXIT
SQL
EOF
}
echo "Oracle: emitir y probar credencial dinámica"
vault read -format=json database/creds/oracle-dynamic > "$STATE/oracle-dynamic.json"
oracle_login "$STATE/oracle-dynamic.json" | grep LOGIN_OK
vault lease revoke "$(jq -r .lease_id "$STATE/oracle-dynamic.json")" >/dev/null
if oracle_login "$STATE/oracle-dynamic.json" >/dev/null 2>&1; then exit 1; fi
echo "Oracle: probar credencial estática y rotarla"
vault read -format=json database/static-creds/oracle-static > "$STATE/oracle-old.json"
oracle_login "$STATE/oracle-old.json" | grep LOGIN_OK
vault write -f database/rotate-role/oracle-static >/dev/null
vault read -format=json database/static-creds/oracle-static > "$STATE/oracle-new.json"
[[ "$(jq -r .data.password "$STATE/oracle-old.json")" != "$(jq -r .data.password "$STATE/oracle-new.json")" ]]
oracle_login "$STATE/oracle-new.json" | grep LOGIN_OK
echo "Oracle: rechazar la contraseña estática anterior"
if oracle_login "$STATE/oracle-old.json" >/dev/null 2>&1; then echo "ERROR: contraseña anterior aceptada" >&2; exit 1; fi
for n in 1 2; do vault read -format=json database/creds/oracle-dynamic > "$STATE/oracle-lease-$n.json"; oracle_login "$STATE/oracle-lease-$n.json" | grep LOGIN_OK; done
vault lease revoke -prefix database/creds/oracle-dynamic >/dev/null
for n in 1 2; do if oracle_login "$STATE/oracle-lease-$n.json" >/dev/null 2>&1; then exit 1; fi; done
echo 'Oracle: login, revocación individual y por prefijo, y rotación estática verificados'
'''
add('6_Oracle_DB_Engine','Oracle Database Secrets Engine en RHEL 9',[('Instalar plugin e Instant Client en las nueve VMs',ORACLE_INSTALL),('Oracle en Kubernetes',service('oracle','ORACLE_PWD')),('Configurar usuario técnico, conexión y roles',ORACLE_CONFIG),('Validar SQL, revocación y rotación',ORACLE_VERIFY)])
for provider,count in [('aws',11),('azure',10)]:
    prep=(AZURE if provider=='azure' else '')+r'''
if [[ ! -f "$STATE/import-PROVIDER-values.json" ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$STATE/import-PROVIDER-key.pem" 2>/dev/null
  jq -n --arg password "$(openssl rand -hex 24)" --rawfile pem "$STATE/import-PROVIDER-key.pem" \
    '{"vm-demo-db-password":$password,"vm-demo-json":({user:"demo",password:$password}|tojson),"vm-demo-unicode":"España – contraseña de prueba","vm-demo-multiline":"line one\nline two\n","vm-demo-pem":$pem}' > "$STATE/import-PROVIDER-values.json"
  for i in $(seq 0 EXTRA); do
    jq --arg name "vm-demo-secret-$i" --arg value "$(openssl rand -hex 24)" '. + {($name):$value}' "$STATE/import-PROVIDER-values.json" > "$STATE/import-values.tmp"
    mv "$STATE/import-values.tmp" "$STATE/import-PROVIDER-values.json"
  done
fi
while read -r name; do
  jq -jr --arg name "$name" '.[$name]' "$STATE/import-PROVIDER-values.json" > "$STATE/import-value.txt"
'''.replace('PROVIDER',provider).replace('EXTRA',str(count-6))
    prep+=(r'''
  if aws secretsmanager describe-secret --secret-id "$name" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$name" --secret-string "file://$STATE/import-value.txt" >/dev/null
  else
    aws secretsmanager create-secret --name "$name" --secret-string "file://$STATE/import-value.txt" \
      --tags Key=importable,Value=true Key=migration,Value=vm-rhel9-aws >/dev/null
  fi
  aws secretsmanager tag-resource --secret-id "$name" --tags Key=importable,Value=true Key=migration,Value=vm-rhel9-aws
''' if provider=='aws' else r'''
  az keyvault secret set --vault-name "$(jq -r .kv "$STATE/azure-cli.json")" --name "$name" \
    --file "$STATE/import-value.txt" --tags importable=true migration=vm-rhel9-azure -o none
''')+f'''done < <(jq -r 'keys[]' "$STATE/import-{provider}-values.json")
echo '{count} secretos fuente preparados; sus valores no se imprimen'
'''
    prefix='$(aws sts get-caller-identity --query Account --output text)/$AWS_REGION' if provider=='aws' else '$(jq -r .kv "$STATE/azure-cli.json")'
    imp=f'''PREFIX="{prefix}"
vault write -f sys/activation-flags/secrets-import/activate >/dev/null
'''
    source='source_aws {\n  name = "source"\n}'
    if provider=='azure':
        imp+='jq -jr .client_secret "$STATE/azure-cli.json" > "$STATE/azure-import-client-secret"\n'
        source='''source_azure {
  name = "source"
  key_vault_uri = "https://$(jq -r .kv "$STATE/azure-cli.json").vault.azure.net/"
  tenant_id = "$(jq -r .tenant "$STATE/azure-cli.json")"
  client_id = "$(jq -r .app_id "$STATE/azure-cli.json")"
  credentials_file = "$STATE/azure-import-client-secret"
}'''
    imp+=f'''for mode in flat nested; do
  cat > "$STATE/{provider}-import.hcl" <<EOF
{source}
destination_vault {{
  name = "vault"
  address = "$VAULT_ADDR"
  mount = "vm-{provider}-import"
}}
mapping {{
  name = "isolated-vm-import"
  source = "source"
  destination = "vault"
  filter = "Secret.Tags.importable == \\"true\\" and Secret.Tags.migration == \\"vm-rhel9-{provider}\\""
EOF
  if [[ "$mode" == nested ]]; then
    cat >> "$STATE/{provider}-import.hcl" <<EOF
  transform "regexp" {{
    from = "(.+)"
    to = "$PREFIX/\$1"
  }}
EOF
  fi
  printf '}}\\n' >> "$STATE/{provider}-import.hcl"
  vault operator import -config="$STATE/{provider}-import.hcl" plan
  vault operator import -config="$STATE/{provider}-import.hcl" -auto-create -auto-approve apply
done
while read -r name; do
  for path in "$name" "$PREFIX/$name"; do
    vault kv get -format=json "vm-{provider}-import/$path" > "$STATE/import-check.json"
    jq -e --arg name "$name" --slurpfile expected "$STATE/import-{provider}-values.json" '.data.data.value==$expected[0][$name]' "$STATE/import-check.json" >/dev/null
    vault kv metadata get -format=json "vm-{provider}-import/$path" | jq -e '.data.custom_metadata.importable=="true" and .data.custom_metadata.migration=="vm-rhel9-{provider}"' >/dev/null
  done
done < <(jq -r 'keys[]' "$STATE/import-{provider}-values.json")
'''
    roundtrip=f'PREFIX="{prefix}"\n'
    if provider=='aws':roundtrip+=r'''
ROLE=mapfre-vm-import-sync
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
jq -n --arg role "$(jq -r .vault_role_arn "$STATE/infrastructure.json")" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{AWS:$role},Action:"sts:AssumeRole"}]}' > "$STATE/import-trust.json"
if ! aws iam get-role --role-name "$ROLE" > "$STATE/import-role.json" 2>/dev/null; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$STATE/import-trust.json" > "$STATE/import-role.json"
fi
ROLE_ARN=$(jq -r .Role.Arn "$STATE/import-role.json")
jq -n --arg resource "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT:secret:vm-demo-*" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["secretsmanager:CreateSecret","secretsmanager:DescribeSecret","secretsmanager:PutSecretValue","secretsmanager:UpdateSecret","secretsmanager:TagResource","secretsmanager:UntagResource","secretsmanager:DeleteSecret"],Resource:$resource}]}' > "$STATE/import-policy.json"
aws iam put-role-policy --role-name "$ROLE" --policy-name vm-import --policy-document "file://$STATE/import-policy.json"
jq -n --arg arn "$ROLE_ARN" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"sts:AssumeRole",Resource:$arn}]}' > "$STATE/import-assume.json"
aws iam put-role-policy --role-name "$(jq -r .vault_role_name "$STATE/infrastructure.json")" --policy-name vm-import-assume --policy-document "file://$STATE/import-assume.json"
jq -n --arg region "$AWS_REGION" --arg arn "$ROLE_ARN" \
  '{region:$region,role_arn:$arn,granularity:"secret-key",secret_name_template:"{{ $unused := .SecretKey }}{{ .SecretBaseName }}",custom_tags:{importable:"true",migration:"vm-rhel9-aws"}}' |
  vault write sys/sync/destinations/aws-sm/vm-import-roundtrip-aws - >/dev/null
'''
    else:roundtrip+=r'''
jq '{key_vault_uri:("https://"+.kv+".vault.azure.net/"),tenant_id:.tenant,client_id:.app_id,client_secret:.client_secret,granularity:"secret-key",secret_name_template:"{{ $unused := .SecretKey }}{{ .SecretBaseName }}",custom_tags:{importable:"true",migration:"vm-rhel9-azure"}}' "$STATE/azure-cli.json" |
  curl -fsS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' \
    --data @- "$VAULT_ADDR/v1/sys/sync/destinations/azure-kv/vm-import-roundtrip-azure" >/dev/null
'''
    kind='aws-sm' if provider=='aws' else 'azure-kv'
    roundtrip+=f'''while read -r name; do
  vault write sys/sync/destinations/{kind}/vm-import-roundtrip-{provider}/associations/set mount=vm-{provider}-import secret_name="$PREFIX/$name" >/dev/null
done < <(jq -r 'keys[]' "$STATE/import-{provider}-values.json")
for attempt in $(seq 1 90); do
  vault read -format=json sys/sync/destinations/{kind}/vm-import-roundtrip-{provider}/associations | jq -e '.data.associated_secrets | length=={count} and all(.[]; .sync_status=="SYNCED")' >/dev/null && break
  sleep 5
done
vault read -format=json sys/sync/destinations/{kind}/vm-import-roundtrip-{provider}/associations | jq -e '.data.associated_secrets | length=={count} and all(.[]; .sync_status=="SYNCED")'
while read -r name; do
'''
    roundtrip+=('  aws secretsmanager get-secret-value --secret-id "$name" | jq -jr .SecretString > "$STATE/roundtrip.txt"\n' if provider=='aws' else '  az keyvault secret show --vault-name "$(jq -r .kv "$STATE/azure-cli.json")" --name "$name" -o json | jq -jr .value > "$STATE/roundtrip.txt"\n')
    roundtrip+=f'''  jq -jr --arg name "$name" '.[$name]' "$STATE/import-{provider}-values.json" > "$STATE/expected.txt"
  cmp "$STATE/expected.txt" "$STATE/roundtrip.txt"
done < <(jq -r 'keys[]' "$STATE/import-{provider}-values.json")
echo '{count} valores idénticos después del round-trip'
'''
    add('7_Secret_Migrate_'+('AWS' if provider=='aws' else 'Azure'),'Importar secretos de '+provider.upper(),[('Crear las fuentes cloud aisladas',prep),('Plan, importación plana/anidada y metadata',imp),('Secrets Sync al nombre original y comparación',roundtrip)],'Azure reutiliza el Key Vault del notebook Azure CLI SPN. Los valores privados se comparan sin imprimirlos.')
LDAP_CONFIG=r'''
for user in alice peter; do
  [[ -s "$STATE/ldap-$user-password" ]] || openssl rand -hex 20 | tr -d '\n' > "$STATE/ldap-$user-password"
done
cat > "$STATE/users.ldif" <<EOF
dn: ou=users,dc=vm,dc=example
objectClass: organizationalUnit
ou: users

dn: ou=groups,dc=vm,dc=example
objectClass: organizationalUnit
ou: groups

dn: cn=alice,ou=users,dc=vm,dc=example
objectClass: inetOrgPerson
cn: alice
sn: alice
userPassword: $(cat "$STATE/ldap-alice-password")

dn: cn=peter,ou=users,dc=vm,dc=example
objectClass: inetOrgPerson
cn: peter
sn: peter
userPassword: $(cat "$STATE/ldap-peter-password")

dn: cn=dev,ou=groups,dc=vm,dc=example
objectClass: groupOfNames
cn: dev
member: cn=alice,ou=users,dc=vm,dc=example

dn: cn=ops,ou=groups,dc=vm,dc=example
objectClass: groupOfNames
cn: ops
member: cn=peter,ou=users,dc=vm,dc=example
EOF
"${KUBECTL[@]}" -n vm-demo exec -i deployment/ldap -- sh -c 'umask 077; cat > /tmp/vm-ldap-password' < "$STATE/ldap-password"
rc=0
"${KUBECTL[@]}" -n vm-demo exec -i deployment/ldap -- ldapadd -c -x -H ldap://127.0.0.1 \
  -D cn=admin,dc=vm,dc=example -y /tmp/vm-ldap-password < "$STATE/users.ldif" || rc=$?
[[ "$rc" == 0 || "$rc" == 68 ]]
"${KUBECTL[@]}" -n vm-demo exec deployment/ldap -- rm /tmp/vm-ldap-password
vault namespace lookup vm-rbac >/dev/null 2>&1 || vault namespace create vm-rbac >/dev/null
export VAULT_NAMESPACE=vm-rbac
'''+auth('ldap','ldap')+mount('secret')+r'''
vault write auth/ldap/config url="ldap://$(cat "$STATE/ldap-endpoint"):389" \
  binddn=cn=admin,dc=vm,dc=example bindpass=@"$STATE/ldap-password" userdn=ou=users,dc=vm,dc=example userattr=cn \
  groupdn=ou=groups,dc=vm,dc=example groupattr=cn groupfilter='(&(objectClass=groupOfNames)(member={{.UserDN}}))'
vault policy write dev - <<'HCL'
path "secret/data/allowed/*" { capabilities = ["read"] }
HCL
vault policy write ops - <<'HCL'
path "sys/mounts/*" { capabilities = ["create","read","update","delete","sudo"] }
path "sys/mounts" { capabilities = ["read"] }
HCL
vault write auth/ldap/groups/dev policies=dev
vault write auth/ldap/groups/ops policies=ops
vault kv put secret/allowed/example value=allowed >/dev/null
'''
LDAP_VERIFY=r'''
export VAULT_NAMESPACE=vm-rbac
ROOT_TOKEN=$VAULT_TOKEN
vault write -format=json auth/ldap/login/alice password=@"$STATE/ldap-alice-password" > "$STATE/alice-login.json"
ALICE=$(jq -r .auth.client_token "$STATE/alice-login.json")
[[ "$(VAULT_TOKEN="$ALICE" vault kv get -field=value secret/allowed/example)" == allowed ]]
if VAULT_TOKEN="$ALICE" vault secrets enable -path=forbidden kv >/dev/null 2>&1; then exit 1; fi
vault write -format=json auth/ldap/login/peter password=@"$STATE/ldap-peter-password" > "$STATE/peter-login.json"
PETER=$(jq -r .auth.client_token "$STATE/peter-login.json")
if ! vault secrets list -format=json | jq -e 'has("ops-demo/")' >/dev/null; then
  VAULT_TOKEN="$PETER" vault secrets enable -path=ops-demo kv >/dev/null
fi
vault token revoke "$ALICE" >/dev/null
if VAULT_TOKEN="$ALICE" vault kv get secret/allowed/example >/dev/null 2>&1; then exit 1; fi
vault write -format=json auth/ldap/login/alice password=@"$STATE/ldap-alice-password" > "$STATE/alice-login.json"
ALICE=$(jq -r .auth.client_token "$STATE/alice-login.json")
export VAULT_NAMESPACE=''
vault namespace lock -format=json vm-rbac > "$STATE/namespace-lock.json"
UNLOCK=$(jq -r '.data.unlock_key // empty' "$STATE/namespace-lock.json")
trap 'VAULT_TOKEN="$ROOT_TOKEN" VAULT_NAMESPACE="" vault namespace unlock -unlock-key="$UNLOCK" vm-rbac >/dev/null' EXIT
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $ALICE" -H 'X-Vault-Namespace: vm-rbac' "$VAULT_ADDR/v1/secret/data/allowed/example")
[[ "$code" == 423 || "$code" == 503 ]]
jq -n --rawfile password "$STATE/ldap-alice-password" '{password:$password}' > "$STATE/ldap-login-payload.json"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-Vault-Namespace: vm-rbac' -H 'Content-Type: application/json' --data @"$STATE/ldap-login-payload.json" "$VAULT_ADDR/v1/auth/ldap/login/alice")
[[ "$code" == 423 || "$code" == 503 ]]
vault namespace unlock -unlock-key="$UNLOCK" vm-rbac >/dev/null
trap - EXIT
VAULT_NAMESPACE=vm-rbac vault write -format=json auth/ldap/login/alice password=@"$STATE/ldap-alice-password" > "$STATE/alice-login.json"
VAULT_NAMESPACE=vm-rbac VAULT_TOKEN="$(jq -r .auth.client_token "$STATE/alice-login.json")" vault kv get -field=value secret/allowed/example | grep -qx allowed
echo 'LDAP: acceso permitido/denegado, revocación y lock/unlock verificados'
'''
add('8_RBAC_Revoke_Namespace','LDAP, RBAC, revocación y namespaces',[('LDAP auxiliar en Kubernetes',service('ldap','LDAP_ADMIN_PASSWORD')),('Usuarios LDAP, grupos y políticas de Vault',LDAP_CONFIG),('Login, permisos, revocación y bloqueo de namespace',LDAP_VERIFY),('Revocar leases SQL y rotar credenciales',PG_VERIFY+ORACLE_VERIFY)])
PR_ENABLE=r'''
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
'''
PR_VERIFY=mount('pr-check')+auth('pr-userpass','userpass')+r'''
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
'''
add('10_PR_config_tasks','Performance Replication entre VMs',[('Activar primario, secundario y auto-unseal de standbys',PR_ENABLE),('Autenticación local y cinco lecturas replicadas',PR_VERIFY)])
AUDIT=mount('audit-check')+r'''
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
'''
add('11_Audit_logs_k8s','Auditoría de Vault en RHEL 9',[('Archivo de auditoría, logrotate y reapertura',AUDIT)])
K_ENGINE=mount('kubernetes','kubernetes')
for kind,name in [('serviceaccount','engine'),('role','engine'),('rolebinding','engine'),('role','consumer'),('rolebinding','consumer')]:K_ENGINE+=manifest('vm-consumers',kind,name)
K_ENGINE+=r'''
K8S_SERVER=$("${KUBECTL[@]}" config view --minify --raw --flatten -o json | jq -r '.clusters[0].cluster.server')
"${KUBECTL[@]}" -n vm-consumers create token engine --duration=24h > "$STATE/engine.jwt"
vault write kubernetes/config kubernetes_host="$K8S_SERVER" kubernetes_ca_cert=@"$STATE/kubernetes-ca.pem" \
  service_account_jwt=@"$STATE/engine.jwt" disable_local_ca_jwt=true
vault write kubernetes/roles/github allowed_kubernetes_namespaces=vm-consumers service_account_name='' \
  kubernetes_role_name=consumer kubernetes_role_type=Role token_default_ttl=10m token_max_ttl=1h
vault write -format=json kubernetes/creds/github kubernetes_namespace=vm-consumers > "$STATE/k8s-credentials.json"
TOKEN=$(jq -r .data.service_account_token "$STATE/k8s-credentials.json")
K8S_DYNAMIC=(kubectl --server "$K8S_SERVER" --certificate-authority "$STATE/kubernetes-ca.pem" --token "$TOKEN")
"${K8S_DYNAMIC[@]}" auth can-i create configmaps -n vm-consumers | grep -qx yes
if "${K8S_DYNAMIC[@]}" auth can-i get secrets -n kube-system >/dev/null; then exit 1; fi
vault lease revoke "$(jq -r .lease_id "$STATE/k8s-credentials.json")" >/dev/null
for attempt in $(seq 1 30); do
  if ! "${K8S_DYNAMIC[@]}" auth can-i create configmaps -n vm-consumers >/dev/null 2>&1; then break; fi
  sleep 3
done
if "${K8S_DYNAMIC[@]}" auth can-i create configmaps -n vm-consumers >/dev/null 2>&1; then exit 1; fi
echo 'Permisos acotados y revocación del token Kubernetes verificados'
'''
for engine in [False,True]:
    role='engine' if engine else 'read';filename='vault-k8s-engine-vso.yml' if engine else 'vault-oidc.yml'
    policy='path "secret/data/gha/demo" { capabilities = ["read"] }\n'
    if engine:policy+='''path "kubernetes/creds/github" { capabilities = ["update"] }
path "secret/data/vm/static" { capabilities = ["create","update"] }
path "sys/leases/revoke" { capabilities = ["update"] }
path "sys/namespaces/vm-gha" { capabilities = ["create","update","read"] }
path "vm-gha/sys/mounts/secret" { capabilities = ["create","update","read","sudo"] }
path "vm-gha/secret/data/application/ui" { capabilities = ["create","update"] }
'''
    configure=auth('vm-github','jwt')+mount('secret')+f'''vault kv put secret/gha/demo api_key="$(openssl rand -hex 16)" >/dev/null
vault write auth/vm-github/config oidc_discovery_url=https://token.actions.githubusercontent.com bound_issuer=https://token.actions.githubusercontent.com
vault policy write vm-github-{role} - <<'HCL'
{policy}HCL
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
jq -n --arg repo "$REPO" '{{role_type:"jwt",user_claim:"repository",bound_audiences:["vault-vm"],bound_claims:{{repository:$repo,ref:"refs/heads/codex/vm-rhel9-poc"}},token_policies:["vm-github-{role}"],token_ttl:"10m",token_max_ttl:"15m"}}' |
  curl -fsS -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' --data @- "$VAULT_ADDR/v1/auth/vm-github/role/{role}" >/dev/null
'''
    workflow=(ROOT/'workflows'/filename).read_text()
    publish=f'''# YAML completo del workflow, incluidas sus llamadas curl y kubectl.
cat > "$VM_ROOT/workflows/{filename}" <<'WORKFLOW'
{workflow}WORKFLOW
'''+r'''
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
BRANCH=codex/vm-rhel9-poc
if ! gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  DEFAULT=$(gh api "repos/$REPO" --jq .default_branch)
  SHA=$(gh api "repos/$REPO/git/ref/heads/$DEFAULT" --jq .object.sha)
  jq -n --arg ref "refs/heads/$BRANCH" --arg sha "$SHA" '{ref:$ref,sha:$sha}' | gh api "repos/$REPO/git/refs" -X POST --input - >/dev/null
fi
'''+f'''FILE={filename}
SHA=$(gh api "repos/$REPO/contents/.github/workflows/$FILE?ref=$BRANCH" --jq .sha)
CONTENT=$(openssl base64 -A -in "$VM_ROOT/workflows/$FILE")
jq -n --arg branch "$BRANCH" --arg sha "$SHA" --arg content "$CONTENT" \\
  '{{message:"Make VM demo CLI workflow explicit",branch:$branch,sha:$sha,content:$content}}' |
  gh api "repos/$REPO/contents/.github/workflows/$FILE" -X PUT --input - >/dev/null
gh api "repos/$REPO/actions/workflows/$FILE/runs?branch=$BRANCH" --jq '[.workflow_runs[].id]' > "$STATE/github-before.json"
gh workflow run "$FILE" --repo "$REPO" --ref "$BRANCH"
ID=''
for attempt in $(seq 1 30); do
  ID=$(gh api "repos/$REPO/actions/workflows/$FILE/runs?branch=$BRANCH" | jq -r --slurpfile before "$STATE/github-before.json" '[.workflow_runs[] | select(.id as $id | $before[0] | index($id) | not)][0].id // empty')
  [[ -z "$ID" ]] || break
  sleep 3
done
test -n "$ID"
for attempt in $(seq 1 120); do
  gh api "repos/$REPO/actions/runs/$ID" > "$STATE/github-run.json"
  [[ "$(jq -r .status "$STATE/github-run.json")" == completed ]] && break
  sleep 5
done
jq -e '.conclusion=="success"' "$STATE/github-run.json"
jq --arg repo "$REPO" '{{id:.id,url:.html_url,repo:$repo}}' "$STATE/github-run.json" > "$STATE/github-{role}.json"
jq -r .html_url "$STATE/github-run.json"
'''
    if engine:publish+=r'''
for name in vm-static vm-gha-delivery; do
  for attempt in $(seq 1 60); do
    actual=$("${KUBECTL[@]}" -n vm-consumers get secret "$name" -o json | jq -r '.data.value | @base64d')
    [[ "$actual" == "github-$ID" ]] && break
    sleep 3
  done
  [[ "$actual" == "github-$ID" ]]
done
'''
    steps=([('Controladores VSO/CSI',K_INSTALL),('Autenticación Kubernetes',K_AUTH),('PostgreSQL auxiliar',service('postgres','POSTGRES_PASSWORD')),('Database Engine',PG_CONFIG),('Consumidores VSO/CSI',K_RES),('Motor Kubernetes y RBAC',K_ENGINE)] if engine else [])
    steps += [('Rol OIDC, claims y política de GitHub',configure),('Workflow completo y ejecución real en GitHub',publish)]
    add('12_K8S_Engine_Github' if engine else '2_GHA_Vault_OIDC','GitHub OIDC'+(' y Kubernetes Secrets Engine' if engine else ''),steps)
MONITOR=namespace('vm-monitoring')+r'''
vault policy write vm-metrics - <<'HCL'
path "sys/metrics" { capabilities = ["read"] }
HCL
vault token create -policy=vm-metrics -ttl=24h -orphan -format=json | jq -jr .auth.client_token > "$STATE/metrics-token"
"${KUBECTL[@]}" -n vm-monitoring create secret generic vault-metrics --from-file=token="$STATE/metrics-token" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat > "$STATE/prometheus.yml" <<'YAML'
global:
  scrape_interval: 10s
scrape_configs:
  - job_name: vault-vm
    metrics_path: /v1/sys/metrics
    params:
      format: [prometheus]
    scheme: https
    bearer_token_file: /credentials/token
    static_configs:
      - targets:
YAML
while read -r ip; do printf '          - "%s:8200"\n' "$ip" >> "$STATE/prometheus.yml"; done < <(jq -r '.nodes[] | select(.cluster=="primary") | .internal_fqdn' "$STATE/infrastructure.json")
"${KUBECTL[@]}" -n vm-monitoring create configmap prometheus --from-file=prometheus.yml="$STATE/prometheus.yml" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
[[ -s "$STATE/grafana-password" ]] || openssl rand -hex 20 | tr -d '\n' > "$STATE/grafana-password"
"${KUBECTL[@]}" -n vm-monitoring create secret generic grafana --from-file=password="$STATE/grafana-password" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat > "$STATE/datasource.yaml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
    access: proxy
YAML
cat > "$STATE/dashboard.yaml" <<'YAML'
apiVersion: 1
providers:
  - name: Vault
    type: file
    options:
      path: /dashboards
YAML
"${KUBECTL[@]}" -n vm-monitoring create configmap grafana --from-file=datasource.yaml="$STATE/datasource.yaml" \
  --from-file=dashboard.yaml="$STATE/dashboard.yaml" --from-file=vault.json="$VM_ROOT/assets/vault-dashboard.json" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
'''
for name in ['prometheus','grafana']:
    MONITOR+=manifest('vm-monitoring','deployment',name)+manifest('vm-monitoring','service',name)
MONITOR+=r'''
for name in prometheus grafana; do
  # Restart on configuration changes, including Grafana subPath mounts.
  hash=$("${KUBECTL[@]}" -n vm-monitoring get configmap "$name" -o json | jq -Sc .data | openssl dgst -sha256 | awk '{print $NF}')
  "${KUBECTL[@]}" -n vm-monitoring patch deployment "$name" --type=merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"vm-demo/config-sha\":\"$hash\"}}}}}"
  "${KUBECTL[@]}" -n vm-monitoring rollout status deployment/"$name" --timeout=300s
done
'''
MONITOR_VERIFY=r'''
"${KUBECTL[@]}" -n vm-monitoring port-forward svc/prometheus 19090:9090 > "$STATE/prometheus-forward.log" 2>&1 & PROM_PID=$!
"${KUBECTL[@]}" -n vm-monitoring port-forward svc/grafana 13000:3000 > "$STATE/grafana-forward.log" 2>&1 & GRAF_PID=$!
trap 'kill "$PROM_PID" "$GRAF_PID" 2>/dev/null || true; wait "$PROM_PID" "$GRAF_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 90); do
  curl -fsS http://127.0.0.1:19090/api/v1/targets | jq -e '.data.activeTargets | length==6 and all(.[]; .health=="up")' >/dev/null && break
  sleep 3
done
curl -fsS http://127.0.0.1:19090/api/v1/targets | jq -e '.data.activeTargets | length==6 and all(.[]; .health=="up")'
curl -fsSG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=count({job="vault-vm",__name__=~"vault_.+"})' | jq -e '.data.result[0].value[1] | tonumber > 0'
for attempt in $(seq 1 60); do
  curl -fsS -u "admin:$(cat "$STATE/grafana-password")" http://127.0.0.1:13000/api/search > "$STATE/grafana-search.json" && jq -e 'length>0' "$STATE/grafana-search.json" >/dev/null && break
  sleep 3
done
UID_GRAFANA=$(jq -r '.[0].uid' "$STATE/grafana-search.json")
curl -fsS -u "admin:$(cat "$STATE/grafana-password")" "http://127.0.0.1:13000/api/dashboards/uid/$UID_GRAFANA" > "$STATE/grafana-dashboard.json"
jq -e --slurpfile expected "$VM_ROOT/assets/vault-dashboard.json" '.dashboard.title==$expected[0].title and (.dashboard | tostring | contains("vault-vm"))' "$STATE/grafana-dashboard.json"
curl -fsS -u "admin:$(cat "$STATE/grafana-password")" http://127.0.0.1:13000/api/datasources/uid/Prometheus/health | jq -e '.status=="OK"'
'''
add('13_Grafana_Prometheus_Vault_Telemetry','Prometheus y Grafana: Vault en VMs',[('Política, token, configuración y deployments',MONITOR),('Comprobar seis targets, métricas y dashboard',MONITOR_VERIFY)])
BENCH=namespace('vm-benchmark')+'''vault policy write vm-benchmark - <<'HCL'
'''+(ROOT/'assets/benchmark-policy.hcl').read_text()+'''\nHCL
'''+r'''
vault token create -policy=vm-benchmark -ttl=1h -orphan -format=json | jq -jr .auth.client_token > "$STATE/benchmark-token"
trap 'vault token revoke "$(cat "$STATE/benchmark-token")" >/dev/null' EXIT
"${KUBECTL[@]}" -n vm-benchmark create secret generic benchmark-token --from-file=token="$STATE/benchmark-token" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat > "$STATE/benchmark.hcl" <<'HCL'
vault_addr = ""
vault_token = ""
duration = "30s"
report_mode = "terse"
random_mounts = true
cleanup = true
test "approle_auth" "approle_logins" {
  weight = 50
  config {
    role {
      role_name = "benchmark-role"
      token_ttl = "2m"
    }
  }
}
test "kvv2_write" "static_secret_writes" {
  weight = 50
  config {
    numkvs = 100
    kvsize = 256
  }
}
HCL
"${KUBECTL[@]}" -n vm-benchmark create configmap benchmark --from-file=benchmark.hcl="$STATE/benchmark.hcl" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" -n vm-benchmark delete job benchmark --ignore-not-found
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: benchmark
  namespace: vm-benchmark
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: benchmark
          image: hashicorp/vault-benchmark:0.3.0
          command: [vault-benchmark]
          args: [run, -config=/config/benchmark.hcl, -rps=50, -workers=5]
          env:
            - name: VAULT_ADDR
              value: "$VAULT_ADDR"
            - name: VAULT_TOKEN
              valueFrom:
                secretKeyRef: {name: benchmark-token, key: token}
          volumeMounts:
            - {name: config, mountPath: /config}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: '1', memory: 512Mi}
      volumes:
        - name: config
          configMap: {name: benchmark}
EOF
"${KUBECTL[@]}" -n vm-benchmark wait --for=condition=complete job/benchmark --timeout=300s
"${KUBECTL[@]}" -n vm-benchmark logs job/benchmark > "$STATE/benchmark.log"
awk '/^approle_logins|^static_secret_writes/ {print; n++; if ($2<=0 || $NF+0 != 100) bad=1} END {exit(n!=2 || bad)}' "$STATE/benchmark.log"
awk '/^approle_logins|^static_secret_writes/ {printf "{\"operation\":\"%s\",\"count\":%s,\"rate\":%s,\"throughput\":%s,\"mean\":\"%s\",\"p95\":\"%s\",\"p99\":\"%s\",\"success_ratio\":\"%s\"}\n",$1,$2,$3,$4,$5,$6,$7,$NF}' "$STATE/benchmark.log" | jq -s . > "$VM_ROOT/reports/benchmark.json"
'''
add('14_Vault_Benchmark_Kubernetes_AppRole_KV','Benchmark AppRole y KV contra las VMs',[('Política, HCL, Job y verificación de resultados',BENCH)])
JWT_STATIC=auth('vm-jwt','jwt')+r'''
"${KUBECTL[@]}" get --raw /.well-known/openid-configuration > "$STATE/issuer.json"
"${KUBECTL[@]}" get --raw /openid/v1/jwks > "$STATE/jwks.json"
# Conversión JWK RSA a PEM con Bash y OpenSSL (sin Python).
: > "$STATE/jwt-pem-keys.jsonl"
jwk_hex() {
  local value=$1
  value=${value//-/+}; value=${value//_/\/}
  while (( ${#value} % 4 )); do value="${value}="; done
  printf '%s' "$value" | openssl base64 -d -A | od -An -v -tx1 | tr -d ' \n'
}
while read -r key; do
  n=$(jwk_hex "$(jq -r .n <<<"$key")"); e=$(jwk_hex "$(jq -r .e <<<"$key")")
  cat > "$STATE/rsa-asn1.cnf" <<EOF
asn1=SEQUENCE:rsa
[rsa]
n=INTEGER:0x$n
e=INTEGER:0x$e
EOF
  openssl asn1parse -genconf "$STATE/rsa-asn1.cnf" -out "$STATE/rsa.der" -noout
  openssl rsa -RSAPublicKey_in -inform DER -in "$STATE/rsa.der" -pubout -out "$STATE/jwt-public.pem" 2>/dev/null
  jq -Rs . "$STATE/jwt-public.pem" >> "$STATE/jwt-pem-keys.jsonl"
done < <(jq -c '.keys[] | select(.kty=="RSA")' "$STATE/jwks.json")
jq -n --arg issuer "$(jq -r .issuer "$STATE/issuer.json")" --slurpfile keys "$STATE/jwt-pem-keys.jsonl" '{bound_issuer:$issuer,jwt_validation_pubkeys:$keys}' |
  curl -fsS -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' --data @- "$VAULT_ADDR/v1/auth/vm-jwt/config" >/dev/null
vault write auth/vm-jwt/role/consumer role_type=jwt user_claim=sub bound_subject=system:serviceaccount:vm-consumers:consumer bound_audiences=vault token_policies=vm-consumer token_ttl=10m
'''
AWS_ENGINE=mount('aws-vm','aws')+r'''
ROLE=mapfre-vm-aws-engine
jq -n --arg principal "$(jq -r .vault_role_arn "$STATE/infrastructure.json")" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{AWS:$principal},Action:"sts:AssumeRole"}]}' > "$STATE/aws-engine-trust.json"
if ! aws iam get-role --role-name "$ROLE" > "$STATE/aws-engine-role.json" 2>/dev/null; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$STATE/aws-engine-trust.json" > "$STATE/aws-engine-role.json"
fi
ARN=$(jq -r .Role.Arn "$STATE/aws-engine-role.json")
jq -n --arg arn "$ARN" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"sts:AssumeRole",Resource:$arn}]}' > "$STATE/aws-engine-permissions.json"
aws iam put-role-policy --role-name "$(jq -r .vault_role_name "$STATE/infrastructure.json")" --policy-name vm-aws-engine --policy-document "file://$STATE/aws-engine-permissions.json"
vault write aws-vm/config/root region="$AWS_REGION"
vault write aws-vm/roles/demo credential_type=assumed_role role_arns="$ARN" default_sts_ttl=15m max_sts_ttl=1h
'''
JWT_PUBLIC=auth('vm-jwt-public','jwt')+r'''
ISSUER=$(jq -r .issuer "$STATE/issuer.json")
curl -fsS "$ISSUER/.well-known/openid-configuration" > "$STATE/public-discovery.json"
JWKS=$(jq -r .jwks_uri "$STATE/public-discovery.json")
curl -fsS "$JWKS" | jq -e '.keys | length>0'
vault write auth/vm-jwt-public/config jwks_url="$JWKS" bound_issuer="$ISSUER"
vault write auth/vm-jwt-public/role/consumer role_type=jwt user_claim=sub bound_subject=system:serviceaccount:vm-consumers:consumer bound_audiences=vault token_policies=vm-consumer token_ttl=10m
'''
for name in ['vm-jwt','vm-jwt-public']:
    if name=='vm-jwt':AWS_ENGINE+=manifest('vm-consumers','vaultconnection','vm-jwt')
    target='vm-aws-jwt'+('-public' if name.endswith('public') else '')
    text=manifest('vm-consumers','vaultauth',name)+manifest('vm-consumers','vaultdynamicsecret',target)
    if name=='vm-jwt':AWS_ENGINE+=text
    else:JWT_PUBLIC+=text
JWT_VERIFY=r'''
for name in vm-aws-jwt vm-aws-jwt-public; do
  verified=false
  for attempt in $(seq 1 60); do
    if "${KUBECTL[@]}" -n vm-consumers get secret "$name" -o json > "$STATE/sts-secret.json" 2>/dev/null && jq -e '.data.access_key and .data.secret_key and .data.security_token' "$STATE/sts-secret.json" >/dev/null; then
      if AWS_ACCESS_KEY_ID="$(jq -r '.data.access_key|@base64d' "$STATE/sts-secret.json")" \
         AWS_SECRET_ACCESS_KEY="$(jq -r '.data.secret_key|@base64d' "$STATE/sts-secret.json")" \
         AWS_SESSION_TOKEN="$(jq -r '.data.security_token|@base64d' "$STATE/sts-secret.json")" \
           aws sts get-caller-identity > "$STATE/sts-identity.json" 2>/dev/null; then
        if jq -e '.Arn | contains("assumed-role/mapfre-vm-aws-engine/")' "$STATE/sts-identity.json" >/dev/null; then verified=true; break; fi
      fi
    fi
    sleep 5
  done
  "$verified"
  echo "$name: identidad STS del rol esperado verificada"
done
echo "Ambos modos JWT/VSO verificados en $KUBE_CONTEXT"

'''
add('_Backup_VSO_Openshift','VSO con JWT, JWKS público y AWS STS',[('Controladores y service accounts',K_INSTALL+K_AUTH),('JWT con todas las claves públicas RSA',JWT_STATIC),('AWS Engine AssumeRole y VSO',AWS_ENGINE),('JWT con JWKS público',JWT_PUBLIC),('Verificación efectiva de las credenciales STS',JWT_VERIFY)],'El complemento original de OpenShift se adapta al EKS de la demo. Se verifican ambos modos JWT; esta ejecución no acredita SCC nativo de OpenShift.')
# Keep the original notebook order and names from the previous mapping.
order={x['source'].removesuffix('.ipynb'):i for i,x in enumerate(json.loads((ROOT/'scenario-map.json').read_text()))}
CASES.sort(key=lambda x:order[x[0]])
for name,title,steps,desc,preamble in CASES:
    nb=nbformat.v4.new_notebook()
    nb.metadata['kernelspec']={'display_name':'Vault RHEL9 PoC','language':'python','name':'vm-rhel9-poc'}
    nb.metadata['source_notebook']=name+'.ipynb'
    nb.metadata['implementation']='bash-cli'
    nb.cells=[nbformat.v4.new_markdown_cell('# '+title+'\n\n'+desc+'\n\nEjecutar en orden. Todas las operaciones están en celdas `%%bash`, copiables a una terminal Bash quitando únicamente esa primera línea. El directorio de trabajo es `vm-rhel9/notebooks`. `notebook-env.sh` carga rutas y variables; no despliega ni configura servicios. Los archivos sensibles van a `.state/` con permisos privados.')]
    chunks=['#!/usr/bin/env bash\n# Ejecutar desde vm-rhel9/notebooks\n']
    for heading,body in steps:
        # Provisioning, replication, audit maintenance and per-node metrics keep
        # the administrative endpoint. All integration clients use the apps VIP.
        endpoint = '' if name in {'1_Deploy_Vault_AWS','9_VAULT_PR','10_PR_config_tasks','11_Audit_logs_k8s','13_Grafana_Prometheus_Vault_Telemetry'} else 'export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"\n'
        code=ENV+endpoint+preamble+textwrap.dedent(body).strip()+'\n'
        nb.cells.extend([nbformat.v4.new_markdown_cell('## '+heading),nbformat.v4.new_code_cell('%%bash\n'+code)])
        chunks.append('\n# '+heading+'\n'+code)
    nb.cells.append(nbformat.v4.new_markdown_cell('## Limpieza opcional\n\nLa evaluación conserva el entorno. La limpieza independiente se documenta en `../README.md`; no ejecutar los scripts de limpieza del repositorio padre.'))
    nbformat.write(nb,ROOT/'notebooks'/(name+'.ipynb'))
    (ROOT/'notebook_sources'/(name+'.sh')).write_text(''.join(chunks))
print('Generated',len(CASES),'notebooks with explicit Bash CLI cells')
