#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=mvm-wif-kv
DEST=mvm-wif-azure-kv
KIND=azure-kv
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

# Autenticación Azure CLI
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=mvm-wif-kv
DEST=mvm-wif-azure-kv
KIND=azure-kv
if ! az account get-access-token --query expiresOn -o tsv >/dev/null 2>&1; then
  az login --tenant "$AZURE_TENANT_ID" --subscription "$AZURE_SUBSCRIPTION_ID" --output none
fi
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
[[ "$(az account show --query tenantId -o tsv)" == "$AZURE_TENANT_ID" ]]
az account show --query '{subscription:name,id:id,tenant:tenantId}' -o table

# Configurar Azure y Vault con Terraform
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=mvm-wif-kv
DEST=mvm-wif-azure-kv
KIND=azure-kv
vault write -f sys/activation-flags/secrets-sync/activate >/dev/null
cat > "$VM_ROOT/terraform/azure-wif/runtime.auto.tfvars.json" <<EOF
{"azure_subscription_id":"$AZURE_SUBSCRIPTION_ID","name_prefix":"mvm-wif","public_oidc_issuer_url":"$VAULT_ADMIN_ADDR"}
EOF
# El provider no puede refrescar una asociación antigua si su mount ya no existe.
# Solo se retiran del estado local esas referencias obsoletas; no se borran recursos cloud.
vault secrets list -format=json > "$STATE/azure-wif-mounts.json"
if [[ -s "$VM_ROOT/terraform/azure-wif/terraform.tfstate" ]] && ! jq -e --arg key "$MOUNT/" 'has($key)' "$STATE/azure-wif-mounts.json" >/dev/null; then
  cp "$VM_ROOT/terraform/azure-wif/terraform.tfstate" "$STATE/azure-wif-before-recovery.tfstate"
  terraform -chdir="$VM_ROOT/terraform/azure-wif" state list | grep -E '^vault_secrets_sync_association\.|^vault_generic_endpoint\.aws_destination$' > "$STATE/azure-wif-stale-resources" || true
  while read -r resource; do
    [[ -z "$resource" ]] || terraform -chdir="$VM_ROOT/terraform/azure-wif" state rm "$resource"
  done < "$STATE/azure-wif-stale-resources"
fi
terraform -chdir="$VM_ROOT/terraform/azure-wif" init -input=false
terraform -chdir="$VM_ROOT/terraform/azure-wif" validate
terraform -chdir="$VM_ROOT/terraform/azure-wif" apply -input=false -auto-approve
terraform -chdir="$VM_ROOT/terraform/azure-wif" output -json > "$STATE/azure-wif-outputs.json"

# Configuración visible y comprobación en Azure
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=mvm-wif-kv
DEST=mvm-wif-azure-kv
KIND=azure-kv
cat "$VM_ROOT/terraform/azure-wif/main.tf"
KEY_VAULT=$(az keyvault list -g "mvm-wif-secrets-sync-rg" --query '[0].name' -o tsv)

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
