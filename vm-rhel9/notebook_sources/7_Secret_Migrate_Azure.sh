#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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

# Crear las fuentes cloud aisladas
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
if ! az account get-access-token --query expiresOn -o tsv >/dev/null 2>&1; then
  az login --tenant "$AZURE_TENANT_ID" --subscription "$AZURE_SUBSCRIPTION_ID" --output none
fi
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
[[ "$(az account show --query tenantId -o tsv)" == "$AZURE_TENANT_ID" ]]
az account show --query '{subscription:name,id:id,tenant:tenantId}' -o table

if [[ ! -f "$STATE/import-azure-values.json" ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$STATE/import-azure-key.pem" 2>/dev/null
  jq -n --arg password "$(openssl rand -hex 24)" --rawfile pem "$STATE/import-azure-key.pem" \
    '{"vm-demo-db-password":$password,"vm-demo-json":({user:"demo",password:$password}|tojson),"vm-demo-unicode":"España – contraseña de prueba","vm-demo-multiline":"line one\nline two\n","vm-demo-pem":$pem}' > "$STATE/import-azure-values.json"
  for i in $(seq 0 4); do
    jq --arg name "vm-demo-secret-$i" --arg value "$(openssl rand -hex 24)" '. + {($name):$value}' "$STATE/import-azure-values.json" > "$STATE/import-values.tmp"
    mv "$STATE/import-values.tmp" "$STATE/import-azure-values.json"
  done
fi
while read -r name; do
  jq -jr --arg name "$name" '.[$name]' "$STATE/import-azure-values.json" > "$STATE/import-value.txt"

  az keyvault secret set --vault-name "$(jq -r .kv "$STATE/azure-cli.json")" --name "$name" \
    --file "$STATE/import-value.txt" --tags importable=true migration=vm-rhel9-azure -o none
done < <(jq -r 'keys[]' "$STATE/import-azure-values.json")
echo '10 secretos fuente preparados; sus valores no se imprimen'

# Plan, importación plana/anidada y metadata
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
PREFIX="$(jq -r .kv "$STATE/azure-cli.json")"
vault write -f sys/activation-flags/secrets-import/activate >/dev/null
jq -jr .client_secret "$STATE/azure-cli.json" > "$STATE/azure-import-client-secret"
for mode in flat nested; do
  cat > "$STATE/azure-import.hcl" <<EOF
source_azure {
  name = "source"
  key_vault_uri = "https://$(jq -r .kv "$STATE/azure-cli.json").vault.azure.net/"
  tenant_id = "$(jq -r .tenant "$STATE/azure-cli.json")"
  client_id = "$(jq -r .app_id "$STATE/azure-cli.json")"
  credentials_file = "$STATE/azure-import-client-secret"
}
destination_vault {
  name = "vault"
  address = "$VAULT_ADDR"
  mount = "vm-azure-import"
}
mapping {
  name = "isolated-vm-import"
  source = "source"
  destination = "vault"
  filter = "Secret.Tags.importable == \"true\" and Secret.Tags.migration == \"vm-rhel9-azure\""
EOF
  if [[ "$mode" == nested ]]; then
    cat >> "$STATE/azure-import.hcl" <<EOF
  transform "regexp" {
    from = "(.+)"
    to = "$PREFIX/\$1"
  }
EOF
  fi
  printf '}\n' >> "$STATE/azure-import.hcl"
  vault operator import -config="$STATE/azure-import.hcl" plan
  vault operator import -config="$STATE/azure-import.hcl" -auto-create -auto-approve apply
done
while read -r name; do
  for path in "$name" "$PREFIX/$name"; do
    vault kv get -format=json "vm-azure-import/$path" > "$STATE/import-check.json"
    jq -e --arg name "$name" --slurpfile expected "$STATE/import-azure-values.json" '.data.data.value==$expected[0][$name]' "$STATE/import-check.json" >/dev/null
    vault kv metadata get -format=json "vm-azure-import/$path" | jq -e '.data.custom_metadata.importable=="true" and .data.custom_metadata.migration=="vm-rhel9-azure"' >/dev/null
  done
done < <(jq -r 'keys[]' "$STATE/import-azure-values.json")

# Secrets Sync al nombre original y comparación
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
PREFIX="$(jq -r .kv "$STATE/azure-cli.json")"

jq '{key_vault_uri:("https://"+.kv+".vault.azure.net/"),tenant_id:.tenant,client_id:.app_id,client_secret:.client_secret,granularity:"secret-key",secret_name_template:"{{ $unused := .SecretKey }}{{ .SecretBaseName }}",custom_tags:{importable:"true",migration:"vm-rhel9-azure"}}' "$STATE/azure-cli.json" |
  curl -fsS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' \
    --data @- "$VAULT_ADDR/v1/sys/sync/destinations/azure-kv/vm-import-roundtrip-azure" >/dev/null
while read -r name; do
  vault write sys/sync/destinations/azure-kv/vm-import-roundtrip-azure/associations/set mount=vm-azure-import secret_name="$PREFIX/$name" >/dev/null
done < <(jq -r 'keys[]' "$STATE/import-azure-values.json")
for attempt in $(seq 1 90); do
  vault read -format=json sys/sync/destinations/azure-kv/vm-import-roundtrip-azure/associations | jq -e '.data.associated_secrets | length==10 and all(.[]; .sync_status=="SYNCED")' >/dev/null && break
  sleep 5
done
vault read -format=json sys/sync/destinations/azure-kv/vm-import-roundtrip-azure/associations | jq -e '.data.associated_secrets | length==10 and all(.[]; .sync_status=="SYNCED")'
while read -r name; do
  az keyvault secret show --vault-name "$(jq -r .kv "$STATE/azure-cli.json")" --name "$name" -o json | jq -jr .value > "$STATE/roundtrip.txt"
  jq -jr --arg name "$name" '.[$name]' "$STATE/import-azure-values.json" > "$STATE/expected.txt"
  cmp "$STATE/expected.txt" "$STATE/roundtrip.txt"
done < <(jq -r 'keys[]' "$STATE/import-azure-values.json")
echo '10 valores idénticos después del round-trip'
