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

# LDAP auxiliar en Kubernetes
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-demo --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
[[ -s "$STATE/ldap-password" ]] || openssl rand -hex 20 | tr -d '
' > "$STATE/ldap-password"
"${KUBECTL[@]}" -n vm-demo create secret generic ldap --from-file=LDAP_ADMIN_PASSWORD="$STATE/ldap-password" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ldap
  namespace: vm-demo
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: vm-ldap
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: vm-ldap
    spec:
      containers:
      - env:
        - name: LDAP_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              key: LDAP_ADMIN_PASSWORD
              name: ldap
        - name: LDAP_DOMAIN
          value: vm.example
        - name: LDAP_ORGANISATION
          value: VM Demo
        - name: LDAP_TLS
          value: 'false'
        image: osixia/openldap:1.5.0
        imagePullPolicy: IfNotPresent
        name: ldap
        ports:
        - containerPort: 389
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          periodSeconds: 5
          successThreshold: 1
          tcpSocket:
            port: 389
          timeoutSeconds: 1
        resources:
          limits:
            cpu: '2'
            memory: 1Gi
          requests:
            cpu: 100m
            memory: 256Mi
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
      dnsPolicy: ClusterFirst
      enableServiceLinks: false
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ldap
  namespace: vm-demo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: 'true'
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  allocateLoadBalancerNodePorts: true
  externalTrafficPolicy: Cluster
  internalTrafficPolicy: Cluster
  ports:
  - port: 389
    protocol: TCP
    targetPort: 389
  selector:
    app: vm-ldap
  sessionAffinity: None
  type: LoadBalancer
EOF
"${KUBECTL[@]}" -n vm-demo rollout status deployment/ldap --timeout=1800s
for attempt in $(seq 1 120); do
  endpoint=$("${KUBECTL[@]}" -n vm-demo get service ldap -o json | jq -r '.status.loadBalancer.ingress[0].hostname // empty')
  [[ -z "$endpoint" ]] || break
  sleep 5
done
test -n "$endpoint"
printf '%s' "$endpoint" > "$STATE/ldap-endpoint"

# Usuarios LDAP, grupos y políticas de Vault
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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
vault auth list -format=json | jq -e 'has("ldap/")' >/dev/null || vault auth enable -path=ldap ldap
vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null || vault secrets enable -path=secret kv-v2
for attempt in $(seq 1 60); do vault read secret/config >/dev/null 2>&1 && break; sleep 1; done
vault read secret/config >/dev/null

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

# Login, permisos, revocación y bloqueo de namespace
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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

# Revocar leases SQL y rotar credenciales
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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
