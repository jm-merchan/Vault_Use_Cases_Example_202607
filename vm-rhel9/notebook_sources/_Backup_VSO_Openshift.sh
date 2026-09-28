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

# Controladores y service accounts
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-consumers --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

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
"${KUBECTL[@]}" create namespace vm-consumers --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

for sa in consumer reviewer; do
  "${KUBECTL[@]}" -n vm-consumers create serviceaccount "$sa" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
done
"${KUBECTL[@]}" create clusterrolebinding vm-consumers-reviewer --clusterrole=system:auth-delegator --serviceaccount=vm-consumers:reviewer --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" config view --minify --raw --flatten -o json > "$STATE/kube-connection.json"
K8S_SERVER=$(jq -r '.clusters[0].cluster.server' "$STATE/kube-connection.json")
jq -r '.clusters[0].cluster."certificate-authority-data"' "$STATE/kube-connection.json" | openssl base64 -d -A > "$STATE/kubernetes-ca.pem"
"${KUBECTL[@]}" -n vm-consumers create token reviewer --duration=24h > "$STATE/reviewer.jwt"
vault auth list -format=json | jq -e 'has("vm-kubernetes/")' >/dev/null || vault auth enable -path=vm-kubernetes kubernetes

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

# JWT con todas las claves públicas RSA
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault auth list -format=json | jq -e 'has("vm-jwt/")' >/dev/null || vault auth enable -path=vm-jwt jwt

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

# AWS Engine AssumeRole y VSO
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault secrets list -format=json | jq -e 'has("aws-vm/")' >/dev/null || vault secrets enable -path=aws-vm aws

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
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vm-jwt
  namespace: vm-consumers
spec:
  address: ${VAULT_APPLICATION_ADDR}
  skipTLSVerify: false
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vm-jwt
  namespace: vm-consumers
spec:
  jwt:
    audiences:
    - vault
    role: consumer
    serviceAccount: consumer
    tokenExpirationSeconds: 600
  method: jwt
  mount: vm-jwt
  vaultConnectionRef: vm-jwt
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: vm-aws-jwt
  namespace: vm-consumers
spec:
  destination:
    create: true
    name: vm-aws-jwt
    overwrite: true
    transformation: {}
  mount: aws-vm
  path: sts/demo
  renewalPercent: 50
  vaultAuthRef: vm-jwt
EOF

# JWT con JWKS público
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault auth list -format=json | jq -e 'has("vm-jwt-public/")' >/dev/null || vault auth enable -path=vm-jwt-public jwt

ISSUER=$(jq -r .issuer "$STATE/issuer.json")
curl -fsS "$ISSUER/.well-known/openid-configuration" > "$STATE/public-discovery.json"
JWKS=$(jq -r .jwks_uri "$STATE/public-discovery.json")
curl -fsS "$JWKS" | jq -e '.keys | length>0'
vault write auth/vm-jwt-public/config jwks_url="$JWKS" bound_issuer="$ISSUER"
vault write auth/vm-jwt-public/role/consumer role_type=jwt user_claim=sub bound_subject=system:serviceaccount:vm-consumers:consumer bound_audiences=vault token_policies=vm-consumer token_ttl=10m
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vm-jwt-public
  namespace: vm-consumers
spec:
  jwt:
    audiences:
    - vault
    role: consumer
    serviceAccount: consumer
    tokenExpirationSeconds: 600
  method: jwt
  mount: vm-jwt-public
  vaultConnectionRef: vm-jwt
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: vm-aws-jwt-public
  namespace: vm-consumers
spec:
  destination:
    create: true
    name: vm-aws-jwt-public
    overwrite: true
    transformation: {}
  mount: aws-vm
  path: sts/demo
  renewalPercent: 50
  vaultAuthRef: vm-jwt-public
EOF

# Verificación efectiva de las credenciales STS
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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
