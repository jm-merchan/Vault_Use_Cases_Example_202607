#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=vm-azure-cli
DEST=vm-azure-cli
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

# Login y suscripción Azure
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=vm-azure-cli
DEST=vm-azure-cli
KIND=azure-kv
if ! az account get-access-token --query expiresOn -o tsv >/dev/null 2>&1; then
  az login --tenant "$AZURE_TENANT_ID" --subscription "$AZURE_SUBSCRIPTION_ID" --output none
fi
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
[[ "$(az account show --query tenantId -o tsv)" == "$AZURE_TENANT_ID" ]]
az account show --query '{subscription:name,id:id,tenant:tenantId}' -o table

# Resource group, Key Vault, aplicación y RBAC
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=vm-azure-cli
DEST=vm-azure-cli
KIND=azure-kv
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

# Configurar el destino con curl
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=vm-azure-cli
DEST=vm-azure-cli
KIND=azure-kv
vault secrets list -format=json | jq -e 'has("vm-azure-cli/")' >/dev/null || vault secrets enable -path=vm-azure-cli kv-v2
for attempt in $(seq 1 60); do vault read vm-azure-cli/config >/dev/null 2>&1 && break; sleep 1; done
vault read vm-azure-cli/config >/dev/null

vault write -f sys/activation-flags/secrets-sync/activate
# jq construye el payload; curl muestra el endpoint y los headers utilizados.
jq '{key_vault_uri:("https://"+.kv+".vault.azure.net/"),client_id:.app_id,client_secret:.client_secret,tenant_id:.tenant,secret_name_template:"vault-{{ .MountPath }}-{{ .SecretPath }}"}' "$STATE/azure-cli.json" |
  curl -fsS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' \
    --data @- "$VAULT_ADDR/v1/sys/sync/destinations/azure-kv/vm-azure-cli" >/dev/null

# Sincronizar y comprobar con az
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
MOUNT=vm-azure-cli
DEST=vm-azure-cli
KIND=azure-kv
KEY_VAULT=$(jq -r .kv "$STATE/azure-cli.json")

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
