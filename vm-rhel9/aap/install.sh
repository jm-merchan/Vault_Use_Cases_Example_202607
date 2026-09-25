#!/usr/bin/env bash
# Usage: bash aap/install.sh /absolute/path/to/official-bundle.tar.gz
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/notebook-env.sh"
: "${1:?Pass the official AAP 2.7 RHEL 9 x86_64 containerized setup bundle}"
BUNDLE=$1
test -s "$BUNDLE"
mkdir -p "$STATE/aap"
IP=$(jq -er .public_ip "$STATE/aap/infrastructure.json")
AAP_ADDR=$(jq -er .aap_address "$STATE/aap/infrastructure.json")
DOMAIN=${AAP_ADDR#https://}
BUNDLE_SHA=$(shasum -a 256 "$BUNDLE" | awk '{print $1}')

# Published checksum for the bundle available from Red Hat Developer.
if [[ "$(basename "$BUNDLE")" == ansible-automation-platform-containerized-setup-bundle-2.7-1.1-x86_64.tar.gz ]]; then
  expected=12343d643503d61fb0353f9af167a8f6cf0e6e53a5f7b206c1900fb4f9610863
  [[ "$BUNDLE_SHA" == "$expected" ]]
fi

for attempt in $(seq 1 120); do
  ssh -n "${SSH_ARGS[@]}" "ec2-user@$IP" 'sudo test -f /var/lib/aap-bootstrap-ready' >/dev/null 2>&1 && break
  sleep 5
done
ssh -n "${SSH_ARGS[@]}" "ec2-user@$IP" 'set -e; sudo test -f /var/lib/aap-bootstrap-ready; . /etc/os-release; test "$ID" = rhel; [[ "$VERSION_ID" == 9.* ]]; test "$(getenforce)" = Enforcing; podman --version; ansible --version | head -1'

[[ -s "$STATE/aap/admin-password" ]] || openssl rand -hex 24 | tr -d '\n' > "$STATE/aap/admin-password"
[[ -s "$STATE/aap/postgres-password" ]] || openssl rand -hex 24 | tr -d '\n' > "$STATE/aap/postgres-password"
for component in gateway controller hub eda automationmetrics; do
  file="$STATE/aap/$component-pg-password"
  [[ -s "$file" ]] || openssl rand -hex 24 | tr -d '\n' > "$file"
done
[[ -s "$STATE/aap/metrics-read-password" ]] || openssl rand -hex 24 | tr -d '\n' > "$STATE/aap/metrics-read-password"

REMOTE_SHA=$(ssh -n "${SSH_ARGS[@]}" "ec2-user@$IP" 'test ! -f /home/ec2-user/aap/bundle.tar.gz || sha256sum /home/ec2-user/aap/bundle.tar.gz' | awk '{print $1}')
if [[ "$REMOTE_SHA" != "$BUNDLE_SHA" ]]; then
  ssh "${SSH_ARGS[@]}" "ec2-user@$IP" 'umask 077; cat > /home/ec2-user/aap/bundle.tar.gz' < "$BUNDLE"
  REMOTE_SHA=$(ssh -n "${SSH_ARGS[@]}" "ec2-user@$IP" 'sha256sum /home/ec2-user/aap/bundle.tar.gz' | awk '{print $1}')
  [[ "$REMOTE_SHA" == "$BUNDLE_SHA" ]]
fi
ssh -n "${SSH_ARGS[@]}" "ec2-user@$IP" 'set -e; mkdir -p /home/ec2-user/aap/installer; tar -xzf /home/ec2-user/aap/bundle.tar.gz -C /home/ec2-user/aap/installer --strip-components=1; mkdir -p /home/ec2-user/aap/installer/group_vars'

for group in automationgateway automationcontroller automationhub automationeda automationmetrics database; do
  printf '[%s]\n%s ansible_connection=local\n\n' "$group" "$DOMAIN"
done > "$STATE/aap/inventory"

# JSON is valid YAML. Credentials remain in this private group_vars file.
jq -n --arg domain "$DOMAIN" --rawfile admin "$STATE/aap/admin-password" \
  --rawfile pg "$STATE/aap/postgres-password" --rawfile gateway "$STATE/aap/gateway-pg-password" \
  --rawfile controller "$STATE/aap/controller-pg-password" --rawfile hub "$STATE/aap/hub-pg-password" \
  --rawfile eda "$STATE/aap/eda-pg-password" --rawfile metrics "$STATE/aap/automationmetrics-pg-password" \
  --rawfile metrics_read "$STATE/aap/metrics-read-password" \
  '{bundle_install:true,bundle_dir:"/home/ec2-user/aap/installer/bundle",redis_mode:"standalone",hub_seed_collections:false,
    postgresql_admin_username:"postgres",postgresql_admin_password:$pg,
    gateway_admin_password:$admin,gateway_pg_host:$domain,gateway_pg_password:$gateway,
    controller_admin_password:$admin,controller_pg_host:$domain,controller_pg_password:$controller,
    hub_admin_password:$admin,hub_pg_host:$domain,hub_pg_password:$hub,
    eda_admin_password:$admin,eda_pg_host:$domain,eda_pg_password:$eda,
    automationmetrics_pg_host:$domain,automationmetrics_pg_password:$metrics,
    automationmetrics_controller_read_pg_host:$domain,automationmetrics_controller_read_pg_password:$metrics_read,
    gateway_main_url:("https://"+$domain),
    controller_percent_memory_capacity:0.5,
    feature_flags:{FEATURE_OIDC_WORKLOAD_IDENTITY_ENABLED:true}}' > "$STATE/aap/all.yml"

for file in inventory group_vars/all.yml; do
  local_file=${file##*/}
  ssh "${SSH_ARGS[@]}" "ec2-user@$IP" "umask 077; cat > /home/ec2-user/aap/installer/$file" < "$STATE/aap/$local_file"
done

ssh "${SSH_ARGS[@]}" "ec2-user@$IP" 'umask 077; cat > /home/ec2-user/aap/run-install.sh; chmod 700 /home/ec2-user/aap/run-install.sh' <<'REMOTE'
#!/usr/bin/env bash
set -uo pipefail
umask 077
cd /home/ec2-user/aap/installer
rm -f /home/ec2-user/aap/install.exit
ansible-playbook -i inventory ansible.containerized_installer.install > /home/ec2-user/aap/install.log 2>&1
result=$?
printf '%s\n' "$result" > /home/ec2-user/aap/install.exit
exit "$result"
REMOTE
ssh -n "${SSH_ARGS[@]}" "ec2-user@$IP" 'systemd-run --user --unit=aap-install --collect /home/ec2-user/aap/run-install.sh'
echo 'Installer started. Progress: ~/aap/install.log; final exit status: ~/aap/install.exit'
