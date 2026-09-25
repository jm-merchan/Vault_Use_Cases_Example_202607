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

# AppRole y política del Agent
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault auth list -format=json | jq -e 'has("approle/")' >/dev/null || vault auth enable -path=approle approle
vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null || vault secrets enable -path=secret kv-v2
for attempt in $(seq 1 60); do vault read secret/config >/dev/null 2>&1 && break; sleep 1; done
vault read secret/config >/dev/null
vault policy write agent-static - <<'HCL'
path "secret/data/jboss/demo" { capabilities = ["read"] }
HCL
vault write auth/approle/role/agent-static token_policies=agent-static token_ttl=10m token_max_ttl=1h secret_id_ttl=24h
vault read -field=role_id auth/approle/role/agent-static/role-id > "$STATE/agent-static-role-id"
vault write -f -field=secret_id auth/approle/role/agent-static/secret-id > "$STATE/agent-static-secret-id"
vault kv put secret/jboss/demo username=appuser password=version-1 >/dev/null

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
mkdir -p /opt/vm-agent-static/secrets
if [[ ! -d /opt/vm-agent-static/wildfly ]]; then
  curl -fsSL https://github.com/wildfly/wildfly/releases/download/36.0.1.Final/wildfly-36.0.1.Final.zip -o /var/tmp/wildfly.zip
  unzip -oq /var/tmp/wildfly.zip -d /opt/vm-agent-static
  mv /opt/vm-agent-static/wildfly-36.0.1.Final /opt/vm-agent-static/wildfly
fi
mkdir -p /opt/vm-agent-static/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib
chown -R vaultapp:vaultapp /opt/vm-agent-static
REMOTE
for item in role-id secret-id; do
  target=${item//-/_}
  ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" "sudo sh -c 'umask 077; cat > /opt/vm-agent-static/$target; chown vaultapp:vaultapp /opt/vm-agent-static/$target'" < "$STATE/agent-static-$item"
done

# Plantilla HCL, systemd y sudoers
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
# La configuración HCL completa se entrega a la VM por stdin.
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'sudo tee /opt/vm-agent-static/agent.hcl >/dev/null' <<EOF
vault { address = "$VAULT_ADDR" }
auto_auth {
  method "approle" {
    config = { role_id_file_path = "/opt/vm-agent-static/role_id", secret_id_file_path = "/opt/vm-agent-static/secret_id", remove_secret_id_file_after_reading = false }
  }
  sink "file" { config = { path = "/opt/vm-agent-static/token" } }
}
template_config { static_secret_render_interval = "5s" }
template {
  destination = "/opt/vm-agent-static/secrets/application.properties"
  perms = "0600"
  contents = <<EOH
{{ with secret "secret/data/jboss/demo" }}
demo.username={{ .Data.data.username }}
demo.password={{ .Data.data.password }}
{{ end }}
EOH
  exec {
    command = ["/usr/bin/sudo", "/usr/bin/systemctl", "restart", "vm-wildfly-static.service"]
    timeout = "90s"
  }
}
EOF
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
cat > /etc/systemd/system/vm-wildfly-static.service <<'UNIT'
[Unit]
Description=VM WildFly static
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
Environment=JAVA_HOME=/usr/lib/jvm/jre-21-openjdk
ExecStart=/opt/vm-agent-static/wildfly/bin/standalone.sh -b 127.0.0.1 -Djboss.socket.binding.port-offset=10000 -P /opt/vm-agent-static/secrets/application.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/vm-agent-static.service <<'UNIT'
[Unit]
Description=Vault Agent static
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
ExecStart=/usr/local/bin/vault agent -config=/opt/vm-agent-static/agent.hcl
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
printf '%s\n' 'vaultapp ALL=(root) NOPASSWD: /usr/bin/systemctl restart vm-wildfly-static.service' > /etc/sudoers.d/vm-agent-static
chmod 440 /etc/sudoers.d/vm-agent-static
chown vaultapp:vaultapp /opt/vm-agent-static/agent.hcl
chmod 600 /opt/vm-agent-static/agent.hcl
REMOTE

# Aplicación y comprobación HTTP
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'sudo tee /opt/vm-agent-static/wildfly/standalone/deployments/vault-demo.war/index.jsp >/dev/null' <<EOF
<%@ page import="java.security.*" %><% byte[] digest=MessageDigest.getInstance("SHA-256").digest(System.getProperty("demo.password").getBytes("UTF-8"));for(byte b:digest)out.print(String.format("%02x",b)); %>
EOF
ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" sudo bash -se <<'REMOTE'
chown -R vaultapp:vaultapp /opt/vm-agent-static/wildfly/standalone/deployments
chmod -R u+rwX,g+rX /opt/vm-agent-static/wildfly/standalone/deployments
touch /opt/vm-agent-static/wildfly/standalone/deployments/vault-demo.war.dodeploy
systemctl daemon-reload
systemctl enable vm-wildfly-static vm-agent-static
systemctl restart vm-agent-static
REMOTE
expected="$(printf version-1 | openssl dgst -sha256 | awk '{print $NF}')"
for attempt in $(seq 1 90); do
  response=$(ssh "${SSH_ARGS[@]}" "ec2-user@$APP_IP" 'curl -fsS --max-time 10 http://127.0.0.1:18080/vault-demo/index.jsp' 2>/dev/null || true)
  [[ "$response" == *"$expected"* ]] && break
  sleep 3
done
[[ "$response" == *"$expected"* ]]
echo 'Respuesta de WildFly verificada'

# Rotación y verificación funcional
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
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
