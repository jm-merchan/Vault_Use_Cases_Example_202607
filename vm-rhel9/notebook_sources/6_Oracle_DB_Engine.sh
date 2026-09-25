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

# Instalar plugin e Instant Client en las nueve VMs
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
while read -r public; do
  ssh "${SSH_ARGS[@]}" "ec2-user@$public" sudo bash -se <<'REMOTE'

cd /var/tmp
test -s vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip || curl -fsSLO 'https://releases.hashicorp.com/vault-plugin-database-oracle/0.14.1+ent/vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip'
echo 'e14fc3474c6074b458d967098d448f357577fe77cc3c4b64401a4216b46ba372  vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip' | sha256sum -c -
install -d -o vault -g vault /opt/vault/plugins/vault-plugin-database-oracle_0.14.1+ent_linux_amd64
unzip -oq vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip -d /opt/vault/plugins/vault-plugin-database-oracle_0.14.1+ent_linux_amd64
test -s instantclient.zip || curl -fsSLo instantclient.zip 'https://download.oracle.com/otn_software/linux/instantclient/2326300/instantclient-basic-linux.x64-23.26.3.0.0.zip'
echo 'fce485361332927f8328ea4b68d98968c6b0ea124e62470de8c9d0cef880130e  instantclient.zip' | sha256sum -c -
mkdir -p /opt/oracle
unzip -oq instantclient.zip -d /opt/oracle
printf '%s\n' /opt/oracle/instantclient_23_26 > /etc/ld.so.conf.d/oracle-instantclient.conf
ldconfig
chown -R root:vault /opt/vault/plugins /opt/oracle
chmod -R g+rX /opt/vault/plugins /opt/oracle
restorecon -RF /opt/vault/plugins /opt/oracle
REMOTE
done < <(jq -r '.nodes[] | select(.cluster!="app") | .public_ip' "$STATE/infrastructure.json")
vault plugin register -version=v0.14.1+ent \
  -env=LD_LIBRARY_PATH=/opt/oracle/instantclient_23_26 -env=ORACLE_HOME=/opt/oracle/instantclient_23_26 \
  database vault-plugin-database-oracle

# Oracle en Kubernetes
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-demo --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
[[ -s "$STATE/oracle-password" ]] || openssl rand -hex 20 | tr -d '
' > "$STATE/oracle-password"
"${KUBECTL[@]}" -n vm-demo create secret generic oracle --from-file=ORACLE_PWD="$STATE/oracle-password" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: oracle-data
  namespace: vm-demo
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: gp3
  volumeMode: Filesystem
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oracle
  namespace: vm-demo
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: vm-oracle
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: vm-oracle
    spec:
      containers:
      - env:
        - name: ORACLE_PWD
          valueFrom:
            secretKeyRef:
              key: ORACLE_PWD
              name: oracle
        - name: ORACLE_PDB
          value: FREEPDB1
        - name: INIT_SGA_SIZE
          value: '1024'
        - name: INIT_PGA_SIZE
          value: '256'
        image: container-registry.oracle.com/database/free:latest-lite
        imagePullPolicy: IfNotPresent
        name: oracle
        ports:
        - containerPort: 1521
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          periodSeconds: 10
          successThreshold: 1
          tcpSocket:
            port: 1521
          timeoutSeconds: 1
        resources:
          limits:
            cpu: '2'
            memory: 3Gi
          requests:
            cpu: 100m
            memory: 2Gi
        startupProbe:
          exec:
            command:
            - /bin/bash
            - -c
            - /opt/oracle/checkDBStatus.sh
          failureThreshold: 120
          periodSeconds: 15
          successThreshold: 1
          timeoutSeconds: 10
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /opt/oracle/oradata
          name: data
        - mountPath: /dev/shm
          name: dshm
      dnsPolicy: ClusterFirst
      enableServiceLinks: false
      nodeSelector:
        kubernetes.io/arch: amd64
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext:
        fsGroup: 54321
      terminationGracePeriodSeconds: 30
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: oracle-data
      - emptyDir:
          medium: Memory
          sizeLimit: 1Gi
        name: dshm
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: oracle
  namespace: vm-demo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: 'true'
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  allocateLoadBalancerNodePorts: true
  externalTrafficPolicy: Cluster
  internalTrafficPolicy: Cluster
  ports:
  - port: 1521
    protocol: TCP
    targetPort: 1521
  selector:
    app: vm-oracle
  sessionAffinity: None
  type: LoadBalancer
EOF
"${KUBECTL[@]}" -n vm-demo rollout status deployment/oracle --timeout=1800s
for attempt in $(seq 1 120); do
  endpoint=$("${KUBECTL[@]}" -n vm-demo get service oracle -o json | jq -r '.status.loadBalancer.ingress[0].hostname // empty')
  [[ -z "$endpoint" ]] || break
  sleep 5
done
test -n "$endpoint"
printf '%s' "$endpoint" > "$STATE/oracle-endpoint"

# Configurar usuario técnico, conexión y roles
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault secrets list -format=json | jq -e 'has("database/")' >/dev/null || vault secrets enable -path=database database

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

# Validar SQL, revocación y rotación
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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
