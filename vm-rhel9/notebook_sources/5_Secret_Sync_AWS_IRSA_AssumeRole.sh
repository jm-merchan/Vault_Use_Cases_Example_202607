#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=irsa-assume-role-kv
DEST=aws-sm-irsa-assume-role
KIND=aws-sm
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

# Crear permisos y destino con Terraform
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=irsa-assume-role-kv
DEST=aws-sm-irsa-assume-role
KIND=aws-sm
vault write -f sys/activation-flags/secrets-sync/activate >/dev/null
cat > "$VM_ROOT/terraform/irsa-assume-role/runtime.auto.tfvars.json" <<EOF
{"vault_irsa_role_name":"$(jq -r .vault_role_name "$STATE/infrastructure.json")","sync_role_name":"mapfre-vm-sync-assume","aws_region":"$AWS_REGION"}
EOF
# El provider no puede refrescar una asociación antigua si su mount ya no existe.
# Solo se retiran del estado local esas referencias obsoletas; no se borran recursos cloud.
vault secrets list -format=json > "$STATE/irsa-assume-role-mounts.json"
if [[ -s "$VM_ROOT/terraform/irsa-assume-role/terraform.tfstate" ]] && ! jq -e --arg key "$MOUNT/" 'has($key)' "$STATE/irsa-assume-role-mounts.json" >/dev/null; then
  cp "$VM_ROOT/terraform/irsa-assume-role/terraform.tfstate" "$STATE/irsa-assume-role-before-recovery.tfstate"
  terraform -chdir="$VM_ROOT/terraform/irsa-assume-role" state list | grep -E '^vault_secrets_sync_association\.|^vault_generic_endpoint\.aws_destination$' > "$STATE/irsa-assume-role-stale-resources" || true
  while read -r resource; do
    [[ -z "$resource" ]] || terraform -chdir="$VM_ROOT/terraform/irsa-assume-role" state rm "$resource"
  done < "$STATE/irsa-assume-role-stale-resources"
fi
terraform -chdir="$VM_ROOT/terraform/irsa-assume-role" init -input=false
terraform -chdir="$VM_ROOT/terraform/irsa-assume-role" validate
terraform -chdir="$VM_ROOT/terraform/irsa-assume-role" apply -input=false -auto-approve
terraform -chdir="$VM_ROOT/terraform/irsa-assume-role" output -json > "$STATE/irsa-assume-role-outputs.json"

# Destino Secrets Sync y configuración CLI
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=irsa-assume-role-kv
DEST=aws-sm-irsa-assume-role
KIND=aws-sm
vault write -f sys/activation-flags/secrets-sync/activate
vault read -format=json "sys/sync/destinations/aws-sm/$DEST" | jq '.data | del(.credentials,.access_key_id,.secret_access_key,.session_token)'
# Equivalente CLI explícito del destino creado por Terraform.
vault write "sys/sync/destinations/aws-sm/$DEST" region="$AWS_REGION" role_arn="$(terraform -chdir="$VM_ROOT/terraform/irsa-assume-role" output -raw sync_role_arn)" \
  secret_name_template='vault-vm/{{ .MountPath }}/{{ .SecretPath }}' >/dev/null

# Sincronizar y comparar dos versiones con AWS CLI
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=irsa-assume-role-kv
DEST=aws-sm-irsa-assume-role
KIND=aws-sm
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
