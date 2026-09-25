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

# PostgreSQL en Kubernetes
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-demo --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
[[ -s "$STATE/postgres-password" ]] || openssl rand -hex 20 | tr -d '
' > "$STATE/postgres-password"
"${KUBECTL[@]}" -n vm-demo create secret generic postgres --from-file=POSTGRES_PASSWORD="$STATE/postgres-password" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: vm-demo
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3
  volumeMode: Filesystem
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: vm-demo
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: vm-postgres
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: vm-postgres
    spec:
      containers:
      - env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              key: POSTGRES_PASSWORD
              name: postgres
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        image: postgres:17.6
        imagePullPolicy: IfNotPresent
        name: postgres
        ports:
        - containerPort: 5432
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          periodSeconds: 5
          successThreshold: 1
          tcpSocket:
            port: 5432
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
        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: data
      dnsPolicy: ClusterFirst
      enableServiceLinks: false
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: postgres-data
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: vm-demo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: 'true'
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  allocateLoadBalancerNodePorts: true
  externalTrafficPolicy: Cluster
  internalTrafficPolicy: Cluster
  ports:
  - port: 5432
    protocol: TCP
    targetPort: 5432
  selector:
    app: vm-postgres
  sessionAffinity: None
  type: LoadBalancer
EOF
"${KUBECTL[@]}" -n vm-demo rollout status deployment/postgres --timeout=1800s
for attempt in $(seq 1 120); do
  endpoint=$("${KUBECTL[@]}" -n vm-demo get service postgres -o json | jq -r '.status.loadBalancer.ingress[0].hostname // empty')
  [[ -z "$endpoint" ]] || break
  sleep 5
done
test -n "$endpoint"
printf '%s' "$endpoint" > "$STATE/postgres-endpoint"

# Motor Database y roles SQL
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault secrets list -format=json | jq -e 'has("database/")' >/dev/null || vault secrets enable -path=database database

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

# Validar revocación y rotación de root
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

# AppRole y política del Agent
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault auth list -format=json | jq -e 'has("approle/")' >/dev/null || vault auth enable -path=approle approle
vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null || vault secrets enable -path=secret kv-v2
for attempt in $(seq 1 60); do vault read secret/config >/dev/null 2>&1 && break; sleep 1; done
vault read secret/config >/dev/null
vault policy write agent-db - <<'HCL'
path "database/creds/agent-db" { capabilities = ["read"] }
HCL
vault write auth/approle/role/agent-db token_policies=agent-db token_ttl=10m token_max_ttl=1h secret_id_ttl=24h
vault read -field=role_id auth/approle/role/agent-db/role-id > "$STATE/agent-db-role-id"
vault write -f -field=secret_id auth/approle/role/agent-db/secret-id > "$STATE/agent-db-secret-id"

# Preparar RHEL y WildFly por SSH
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
. /etc/os-release
test "$ID" = rhel
[[ "$VERSION_ID" == 9.* ]]
test "$(getenforce)" = Enforcing
id vaultapp >/dev/null 2>&1 || useradd --system --home-dir /opt/vm-agent --shell /sbin/nologin vaultapp
mkdir -p /opt/vm-agent-db/secrets
if [[ ! -d /opt/vm-agent-db/wildfly ]]; then
  curl -fsSL https://github.com/wildfly/wildfly/releases/download/36.0.1.Final/wildfly-36.0.1.Final.zip -o /var/tmp/wildfly.zip
  unzip -oq /var/tmp/wildfly.zip -d /opt/vm-agent-db
  mv /opt/vm-agent-db/wildfly-36.0.1.Final /opt/vm-agent-db/wildfly
fi
mkdir -p /opt/vm-agent-db/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib
chown -R vaultapp:vaultapp /opt/vm-agent-db
REMOTE
for item in role-id secret-id; do
  target=${item//-/_}
  ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" "sudo sh -c 'umask 077; cat > /opt/vm-agent-db/$target; chown vaultapp:vaultapp /opt/vm-agent-db/$target'" < "$STATE/agent-db-$item"
done

# Plantilla HCL, systemd y sudoers
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
# La configuración HCL completa se entrega a la VM por stdin.
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'sudo tee /opt/vm-agent-db/agent.hcl >/dev/null' <<EOF
vault { address = "$VAULT_ADDR" }
auto_auth {
  method "approle" {
    config = { role_id_file_path = "/opt/vm-agent-db/role_id", secret_id_file_path = "/opt/vm-agent-db/secret_id", remove_secret_id_file_after_reading = false }
  }
  sink "file" { config = { path = "/opt/vm-agent-db/token" } }
}
template_config { static_secret_render_interval = "5s" }
template {
  destination = "/opt/vm-agent-db/secrets/application.properties"
  perms = "0600"
  contents = <<EOH
{{ with secret "database/creds/agent-db" }}
demo.username={{ .Data.username }}
demo.password={{ .Data.password }}
{{ end }}
EOH
  exec {
    command = ["/usr/bin/sudo", "/usr/bin/systemctl", "restart", "vm-wildfly-db.service"]
    timeout = "90s"
  }
}
EOF
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
cat > /etc/systemd/system/vm-wildfly-db.service <<'UNIT'
[Unit]
Description=VM WildFly db
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
Environment=JAVA_HOME=/usr/lib/jvm/jre-21-openjdk
ExecStart=/opt/vm-agent-db/wildfly/bin/standalone.sh -b 127.0.0.1 -Djboss.socket.binding.port-offset=10001 -P /opt/vm-agent-db/secrets/application.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/vm-agent-db.service <<'UNIT'
[Unit]
Description=Vault Agent db
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
ExecStart=/usr/local/bin/vault agent -config=/opt/vm-agent-db/agent.hcl
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
printf '%s\n' 'vaultapp ALL=(root) NOPASSWD: /usr/bin/systemctl restart vm-wildfly-db.service' > /etc/sudoers.d/vm-agent-db
chmod 440 /etc/sudoers.d/vm-agent-db
chown vaultapp:vaultapp /opt/vm-agent-db/agent.hcl
chmod 600 /opt/vm-agent-db/agent.hcl
REMOTE

# Aplicación y comprobación HTTP
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'sudo tee /opt/vm-agent-db/wildfly/standalone/deployments/vault-demo.war/index.jsp >/dev/null' <<EOF
<%@ page import="java.sql.*" %><% Class.forName("org.postgresql.Driver"); try(Connection c=DriverManager.getConnection("jdbc:postgresql://$(cat "$STATE/postgres-endpoint"):5432/postgres",System.getProperty("demo.username"),System.getProperty("demo.password"))){try(Statement s=c.createStatement();ResultSet r=s.executeQuery("select 1")){if(r.next() && r.getInt(1)==1)out.print("DB_CONNECTION_OK");else response.setStatus(500);}} %>
EOF
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
systemctl stop vm-agent-db-once.timer vm-agent-db-once.service 2>/dev/null || true
curl -fsSL https://jdbc.postgresql.org/download/postgresql-42.7.7.jar -o /opt/vm-agent-db/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib/postgresql.jar
chown -R vaultapp:vaultapp /opt/vm-agent-db/wildfly/standalone/deployments
chmod -R u+rwX,g+rX /opt/vm-agent-db/wildfly/standalone/deployments
touch /opt/vm-agent-db/wildfly/standalone/deployments/vault-demo.war.dodeploy
systemctl daemon-reload
systemctl enable vm-wildfly-db vm-agent-db
systemctl restart vm-agent-db
REMOTE
expected="DB_CONNECTION_OK"
for attempt in $(seq 1 90); do
  response=$(ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'curl -fsS --max-time 10 http://127.0.0.1:18081/vault-demo/index.jsp' 2>/dev/null || true)
  [[ "$response" == *"$expected"* ]] && break
  sleep 3
done
[[ "$response" == *"$expected"* ]]
echo 'Respuesta de WildFly verificada'

# Rotación y verificación funcional
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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
