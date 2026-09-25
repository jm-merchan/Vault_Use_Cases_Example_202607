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
if [[ ! -f "$STATE/import-aws-values.json" ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$STATE/import-aws-key.pem" 2>/dev/null
  jq -n --arg password "$(openssl rand -hex 24)" --rawfile pem "$STATE/import-aws-key.pem" \
    '{"vm-demo-db-password":$password,"vm-demo-json":({user:"demo",password:$password}|tojson),"vm-demo-unicode":"España – contraseña de prueba","vm-demo-multiline":"line one\nline two\n","vm-demo-pem":$pem}' > "$STATE/import-aws-values.json"
  for i in $(seq 0 5); do
    jq --arg name "vm-demo-secret-$i" --arg value "$(openssl rand -hex 24)" '. + {($name):$value}' "$STATE/import-aws-values.json" > "$STATE/import-values.tmp"
    mv "$STATE/import-values.tmp" "$STATE/import-aws-values.json"
  done
fi
while read -r name; do
  jq -jr --arg name "$name" '.[$name]' "$STATE/import-aws-values.json" > "$STATE/import-value.txt"

  if aws secretsmanager describe-secret --secret-id "$name" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$name" --secret-string "file://$STATE/import-value.txt" >/dev/null
  else
    aws secretsmanager create-secret --name "$name" --secret-string "file://$STATE/import-value.txt" \
      --tags Key=importable,Value=true Key=migration,Value=vm-rhel9-aws >/dev/null
  fi
  aws secretsmanager tag-resource --secret-id "$name" --tags Key=importable,Value=true Key=migration,Value=vm-rhel9-aws
done < <(jq -r 'keys[]' "$STATE/import-aws-values.json")
echo '11 secretos fuente preparados; sus valores no se imprimen'

# Plan, importación plana/anidada y metadata
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
PREFIX="$(aws sts get-caller-identity --query Account --output text)/$AWS_REGION"
vault write -f sys/activation-flags/secrets-import/activate >/dev/null
for mode in flat nested; do
  cat > "$STATE/aws-import.hcl" <<EOF
source_aws {
  name = "source"
}
destination_vault {
  name = "vault"
  address = "$VAULT_ADDR"
  mount = "vm-aws-import"
}
mapping {
  name = "isolated-vm-import"
  source = "source"
  destination = "vault"
  filter = "Secret.Tags.importable == \"true\" and Secret.Tags.migration == \"vm-rhel9-aws\""
EOF
  if [[ "$mode" == nested ]]; then
    cat >> "$STATE/aws-import.hcl" <<EOF
  transform "regexp" {
    from = "(.+)"
    to = "$PREFIX/\$1"
  }
EOF
  fi
  printf '}\n' >> "$STATE/aws-import.hcl"
  vault operator import -config="$STATE/aws-import.hcl" plan
  vault operator import -config="$STATE/aws-import.hcl" -auto-create -auto-approve apply
done
while read -r name; do
  for path in "$name" "$PREFIX/$name"; do
    vault kv get -format=json "vm-aws-import/$path" > "$STATE/import-check.json"
    jq -e --arg name "$name" --slurpfile expected "$STATE/import-aws-values.json" '.data.data.value==$expected[0][$name]' "$STATE/import-check.json" >/dev/null
    vault kv metadata get -format=json "vm-aws-import/$path" | jq -e '.data.custom_metadata.importable=="true" and .data.custom_metadata.migration=="vm-rhel9-aws"' >/dev/null
  done
done < <(jq -r 'keys[]' "$STATE/import-aws-values.json")

# Secrets Sync al nombre original y comparación
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
PREFIX="$(aws sts get-caller-identity --query Account --output text)/$AWS_REGION"

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
while read -r name; do
  vault write sys/sync/destinations/aws-sm/vm-import-roundtrip-aws/associations/set mount=vm-aws-import secret_name="$PREFIX/$name" >/dev/null
done < <(jq -r 'keys[]' "$STATE/import-aws-values.json")
for attempt in $(seq 1 90); do
  vault read -format=json sys/sync/destinations/aws-sm/vm-import-roundtrip-aws/associations | jq -e '.data.associated_secrets | length==11 and all(.[]; .sync_status=="SYNCED")' >/dev/null && break
  sleep 5
done
vault read -format=json sys/sync/destinations/aws-sm/vm-import-roundtrip-aws/associations | jq -e '.data.associated_secrets | length==11 and all(.[]; .sync_status=="SYNCED")'
while read -r name; do
  aws secretsmanager get-secret-value --secret-id "$name" | jq -jr .SecretString > "$STATE/roundtrip.txt"
  jq -jr --arg name "$name" '.[$name]' "$STATE/import-aws-values.json" > "$STATE/expected.txt"
  cmp "$STATE/expected.txt" "$STATE/roundtrip.txt"
done < <(jq -r 'keys[]' "$STATE/import-aws-values.json")
echo '11 valores idénticos después del round-trip'
