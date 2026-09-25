#!/usr/bin/env bash
# Run from vm-rhel9/load-balancing. Same commands as the notebook.

# %% Emitir o reutilizar el certificado de Let’s Encrypt con DNS-01
set -euo pipefail
source ../scripts/notebook-env.sh
DOMAIN=${VAULT_ADMIN_ADDR#https://}
SUFFIX=${DOMAIN#*.}
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-$HOME/.vault-demo/letsencrypt-vm}"
mkdir -p "$LETSENCRYPT_DIR"
podman run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  -e AWS_REGION -e AWS_DEFAULT_REGION -v "$LETSENCRYPT_DIR:/etc/letsencrypt" \
  certbot/dns-route53:latest certonly --dns-route53 --non-interactive --agree-tos \
  --register-unsafely-without-email --keep-until-expiring --cert-name vault-vm \
  -d "$DOMAIN" -d "${VAULT_APPLICATION_ADDR#https://}" \
  -d "vault-vm-secondary.$SUFFIX" -d "*.vm-vault.$SUFFIX"
CERT_DIR="$LETSENCRYPT_DIR/live/vault-vm"
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -issuer -dates -ext subjectAltName
if [[ $(uname) == Darwin ]]; then
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain > "$STATE/ca.pem"
else
  cp /etc/pki/tls/certs/ca-bundle.crt "$STATE/ca.pem"
fi
while read -r node; do
  cp "$CERT_DIR/fullchain.pem" "$STATE/$node.pem"
  cp "$CERT_DIR/privkey.pem" "$STATE/$node.key"
done < <(jq -r '.nodes | to_entries[] | select(.value.cluster!="app") | .key' "$STATE/infrastructure.json")

# %% Instalar la cadena y clave en Vault; recarga o reinicio gradual
# Run from any directory. Issuance/renewal is separate; this script deploys validated files.
set -euo pipefail
source ../scripts/notebook-env.sh
CERT_DIR="${LETSENCRYPT_DIR:-$HOME/.vault-demo/letsencrypt-vm}/live/vault-vm"
test -s "$CERT_DIR/fullchain.pem"
test -s "$CERT_DIR/privkey.pem"
openssl x509 -in "$CERT_DIR/fullchain.pem" -checkend 86400 -noout
# Retain the bootstrap CA while migrating; append the system trust store for public certificates.
[[ -f "$STATE/bootstrap-ca.pem" ]] || cp "$STATE/ca.pem" "$STATE/bootstrap-ca.pem"
if [[ $(uname) == Darwin ]]; then
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain > "$STATE/public-ca.pem"
else
  cp /etc/pki/tls/certs/ca-bundle.crt "$STATE/public-ca.pem"
fi
cat "$STATE/bootstrap-ca.pem" "$STATE/public-ca.pem" > "$STATE/ca.pem"
# One member at a time; active nodes last. Cluster addresses remain node-specific.
: > "$STATE/tls-roll-order.tsv"
while read -r node public fqdn internal cluster; do
  health=$(ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" \
    "sudo curl -sS --cacert /etc/vault.d/tls/ca.pem https://127.0.0.1:8200/v1/sys/health" 2>/dev/null || true)
  if ! jq -e '.initialized' <<<"$health" >/dev/null 2>&1; then
    health=$(curl -sS "https://$fqdn:8200/v1/sys/health")
  fi
  jq -e '.initialized and (.sealed|not)' <<<"$health" >/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(jq -r 'if .standby then 0 else 1 end' <<<"$health")" "$node" "$public" "$fqdn" "$internal" "$cluster" >> "$STATE/tls-roll-order.tsv"
done < <(jq -r '.nodes | to_entries[] | select(.value.cluster!="app") | [.key,.value.public_ip,.value.api_fqdn,.value.internal_fqdn,.value.cluster] | @tsv' "$STATE/infrastructure.json")
while read -r active node public fqdn internal cluster; do
  ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" \
    'sudo test -d /etc/vault.d/pre-nlb-backup || sudo cp -a /etc/vault.d /etc/vault.d-pre-nlb-backup; sudo mkdir -p /etc/vault.d/pre-nlb-backup'
  ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo cat /etc/vault.d/vault.hcl' > "$STATE/$node.nlb.hcl"
  cp "$STATE/$node.nlb.hcl" "$STATE/$node.before.hcl"
  sed -E "s|^api_addr = \"https://[^\"]+\"|api_addr = \"https://$internal:8200\"|" "$STATE/$node.nlb.hcl" > "$STATE/$node.nlb.tmp"
  mv "$STATE/$node.nlb.tmp" "$STATE/$node.nlb.hcl"
  # Rebuild only the peer addresses; matching api_addr as a substring would also alter leader_api_addr.
  jq -r --arg cluster "$cluster" --arg node "$node" \
    '.nodes | to_entries[] | select(.value.cluster==$cluster and .key!=$node) | .value.internal_fqdn' \
    "$STATE/infrastructure.json" > "$STATE/$node.peers.txt"
  awk 'NR==FNR { peers[++n]=$0; next }
       /^[[:space:]]*leader_api_addr[[:space:]]*=/ {
         i++; sub(/https:\/\/[^"]+/, "https://" peers[i] ":8200")
       }
       { print }
       END { if (i!=n) exit 1 }' "$STATE/$node.peers.txt" "$STATE/$node.nlb.hcl" > "$STATE/$node.nlb.tmp"
  mv "$STATE/$node.nlb.tmp" "$STATE/$node.nlb.hcl"
  # Remove the previous resolver override: Vault's default is true.
  # Preserve any other settings in the replication stanza; drop it only if empty.
  awk '
    /^# (Remote replication resolves|The leader-only NLB resolves)/ { next }
    /^[[:space:]]*enable_response_header_(hostname|raft_node_id)[[:space:]]*=/ { next }
    /^[[:space:]]*resolver_discover_servers[[:space:]]*=/ { next }
    /^[[:space:]]*replication[[:space:]]*\{/ { stanza=$0; in_replication=1; content=0; next }
    in_replication && /^[[:space:]]*\}/ {
      if (content) print stanza "\n" $0
      in_replication=0; next
    }
    in_replication { stanza=stanza "\n" $0; if ($0 !~ /^[[:space:]]*$/) content=1; next }
    { print }
    END {
      print "enable_response_header_hostname     = true"
      print "enable_response_header_raft_node_id = true"
    }
  ' "$STATE/$node.nlb.hcl" > "$STATE/$node.nlb.tmp"
  mv "$STATE/$node.nlb.tmp" "$STATE/$node.nlb.hcl"
  for pair in "$CERT_DIR/fullchain.pem:server.pem" "$CERT_DIR/privkey.pem:server.key" "$STATE/ca.pem:ca.pem"; do
    src=${pair%:*}; dst=${pair##*:}
    ssh "${SSH_ARGS[@]}" "ec2-user@$public" "sudo sh -c 'umask 077; cat > /etc/vault.d/tls/$dst.new; chown vault:vault /etc/vault.d/tls/$dst.new; mv /etc/vault.d/tls/$dst.new /etc/vault.d/tls/$dst'" < "$src"
  done
  ssh "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo tee /etc/vault.d/vault.hcl >/dev/null' < "$STATE/$node.nlb.hcl"
  if cmp -s "$STATE/$node.before.hcl" "$STATE/$node.nlb.hcl"; then
    ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo systemctl reload vault'
  else
    ssh -n "${SSH_ARGS[@]}" "ec2-user@$public" 'sudo systemctl restart vault'
  fi
  ready=false
  for attempt in $(seq 1 90); do
    h=$(curl --connect-timeout 3 --max-time 5 -sS "https://$fqdn:8200/v1/sys/health" 2>/dev/null || true)
    if jq -e '.initialized and (.sealed|not)' <<<"$h" >/dev/null 2>&1; then ready=true; break; fi
    sleep 2
  done
  [[ "$ready" == true ]]
  printf '%s: public TLS verified; initialized and unsealed\n' "$node"
  sleep 5
 done < <(sort -n "$STATE/tls-roll-order.tsv")
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -issuer -dates -ext subjectAltName

# %% Reconciliar NLB TCP, DNS y grupos de seguridad con Terraform
set -euo pipefail
source ../scripts/notebook-env.sh
terraform -chdir="$VM_ROOT/terraform/infrastructure" validate
terraform -chdir="$VM_ROOT/terraform/infrastructure" plan -input=false -out="$STATE/nlb-verify.tfplan" > "$STATE/nlb-verify.log" 2>&1
terraform -chdir="$VM_ROOT/terraform/infrastructure" show -json "$STATE/nlb-verify.tfplan" > "$STATE/nlb-verify.json"
# Re-evaluation never replaces or destroys an existing resource.
jq -e 'all(.resource_changes[]?; .change.actions | index("delete") | not)' "$STATE/nlb-verify.json" >/dev/null
terraform -chdir="$VM_ROOT/terraform/infrastructure" apply -input=false "$STATE/nlb-verify.tfplan" > "$STATE/nlb-verify-apply.log" 2>&1
terraform -chdir="$VM_ROOT/terraform/infrastructure" output -json | jq 'with_entries(.value=.value.value)' > "$STATE/infrastructure.json"
while read -r name arn; do
  aws elbv2 describe-listeners --load-balancer-arn "$arn" > "$STATE/nlb-$name-listeners.json"
  jq -e 'all(.Listeners[]; .Protocol=="TCP" and (.Certificates==null))' "$STATE/nlb-$name-listeners.json" >/dev/null
  jq --arg name "$name" '{nlb:$name,listeners:[.Listeners[] | {Port,Protocol}]}' "$STATE/nlb-$name-listeners.json"
done < <(jq -r '.nlb | to_entries[] | [.key,.value.arn] | @tsv' "$STATE/infrastructure.json")
for endpoint in "$VAULT_ADMIN_ADDR" "$VAULT_APPLICATION_ADDR"; do
  for port in 443 8200; do
    curl -fsS "$endpoint:$port/v1/sys/health?perfstandbyok=true" | jq -e '.initialized and (.sealed|not)' >/dev/null
  done
done

# %% Anunciar el NLB y actualizar la conexión PR sin reinicializar Raft
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="$VAULT_ADMIN_ADDR"
# Repeating enable on this primary updates its advertised address without disabling PR.
vault write sys/replication/performance/primary/enable primary_cluster_addr="${VAULT_ADMIN_ADDR}:8201" >/dev/null
SECONDARY="https://$(jq -r '.nodes["secondary-0"].api_fqdn' "$STATE/infrastructure.json"):8200"
CURRENT_PR_ADDR=$(curl -fsS "$SECONDARY/v1/sys/replication/status" | jq -r .data.performance.primary_cluster_addr)
if [[ "$CURRENT_PR_ADDR" != "${VAULT_ADMIN_ADDR}:8201" ]]; then
vault policy write pr-nlb-operator - <<'HCL'
path "sys/replication/performance/secondary/update-primary" { capabilities = ["update", "sudo"] }
path "sys/replication/status" { capabilities = ["read"] }
HCL
vault auth list -format=json | jq -e 'has("pr-userpass/")' >/dev/null || vault auth enable -path=pr-userpass userpass
openssl rand -hex 24 | tr -d '\n' > "$STATE/pr-nlb-password"
vault write auth/pr-userpass/users/nlb-operator password=@"$STATE/pr-nlb-password" \
  token_policies=pr-nlb-operator token_ttl=15m token_max_ttl=30m >/dev/null
for attempt in $(seq 1 30); do
  if VAULT_ADDR="$SECONDARY" VAULT_TOKEN='' vault write -format=json auth/pr-userpass/login/nlb-operator \
    password=@"$STATE/pr-nlb-password" > "$STATE/pr-nlb-login.json" 2>/dev/null; then break; fi
  sleep 2
done
SECONDARY_TOKEN=$(jq -er .auth.client_token "$STATE/pr-nlb-login.json")
# Refresh only the connection parameters. update-primary does not reinitialize Raft storage.
vault write -format=json sys/replication/performance/primary/secondary-token id="rhel9-secondary-nlb-$(date -u +%Y%m%d%H%M%S)" \
  > "$STATE/pr-nlb-activation.json"
VAULT_ADDR="$SECONDARY" VAULT_TOKEN="$SECONDARY_TOKEN" vault write sys/replication/performance/secondary/update-primary \
  token="$(jq -er .wrap_info.token "$STATE/pr-nlb-activation.json")" primary_api_addr="$VAULT_ADMIN_ADDR" \
  ca_file=/etc/pki/tls/certs/ca-bundle.crt >/dev/null
else
  echo "The secondary already advertises the NLB; keeping its existing replication identity."
fi
for attempt in $(seq 1 90); do
  curl -fsS "$SECONDARY/v1/sys/replication/status" > "$STATE/pr-nlb-status.json"
  jq -e --arg expected "${VAULT_ADMIN_ADDR}:8201" \
    '.data.performance | .primary_cluster_addr==$expected and .state=="stream-wals" and .connection_state=="ready"' \
    "$STATE/pr-nlb-status.json" >/dev/null && break
  sleep 2
done
jq -e --arg expected "${VAULT_ADMIN_ADDR}:8201" \
  '.data.performance | .primary_cluster_addr==$expected and .state=="stream-wals" and .connection_state=="ready"' \
  "$STATE/pr-nlb-status.json" >/dev/null
if [[ -n "${SECONDARY_TOKEN:-}" ]]; then
  VAULT_ADDR="$SECONDARY" VAULT_TOKEN="$SECONDARY_TOKEN" vault token revoke -self >/dev/null
fi
vault delete auth/pr-userpass/users/nlb-operator >/dev/null
vault policy delete pr-nlb-operator >/dev/null
jq '.data.performance | {mode,state,connection_state,primary_cluster_addr,known_primary_cluster_addrs}' "$STATE/pr-nlb-status.json"

# %% Probar el aislamiento entre clústeres y la reconexión PR por NLB
set -euo pipefail
source ../scripts/notebook-env.sh
# Only node-level diagnostics use operator-restricted public node DNS. PR uses the load balancer.
SECONDARY="https://$(jq -r '.nodes["secondary-0"].api_fqdn' "$STATE/infrastructure.json"):8200"
for cluster in primary secondary; do
  while read -r node ip fqdn; do
    if curl -fsS "https://$fqdn:8200/v1/sys/leader" | jq -e '.data.is_self // .is_self' >/dev/null; then
      [[ "$cluster" != primary ]] || PRIMARY_LEADER=$ip
      [[ "$cluster" != secondary ]] || SECONDARY_LEADER=$ip
      break
    fi
  done < <(jq -r --arg cluster "$cluster" '.nodes | to_entries[] | select(.value.cluster==$cluster) | [.key,.value.public_ip,.value.api_fqdn] | @tsv' "$STATE/infrastructure.json")
done
: "${PRIMARY_LEADER:?}" "${SECONDARY_LEADER:?}"
: > "$STATE/pr-direct-network.jsonl"
for direction in primary-to-secondary secondary-to-primary; do
  source_ip=$PRIMARY_LEADER; destination_cluster=secondary
  [[ "$direction" != secondary-to-primary ]] || { source_ip=$SECONDARY_LEADER; destination_cluster=primary; }
  while read -r node ip; do
    if ssh -n "${SSH_ARGS[@]}" "ec2-user@$source_ip" "timeout 3 bash -c 'exec 3<>/dev/tcp/$ip/8201'" 2>/dev/null; then
      echo "Unexpected direct cluster connection: $direction $node" >&2; exit 1
    fi
    jq -nc --arg direction "$direction" --arg node "$node" '{direction:$direction,target:$node,direct_8201:"blocked"}' >> "$STATE/pr-direct-network.jsonl"
  done < <(jq -r --arg cluster "$destination_cluster" '.nodes | to_entries[] | select(.value.cluster==$cluster) | [.key,.value.private_ip] | @tsv' "$STATE/infrastructure.json")
done
# End any pre-migration tracked TCP session and demonstrate reconnection through the NLB.
ssh -n "${SSH_ARGS[@]}" "ec2-user@$SECONDARY_LEADER" sudo systemctl restart vault
for attempt in $(seq 1 120); do
  h=$(curl --connect-timeout 3 --max-time 5 -fsS "$SECONDARY/v1/sys/replication/status" 2>/dev/null || true)
  if jq -e '.data.performance | .state=="stream-wals" and .connection_state=="ready"' <<<"$h" >/dev/null 2>&1; then break; fi
  sleep 2
done
jq -e '.data.performance | .state=="stream-wals" and .connection_state=="ready"' <<<"$h" >/dev/null
printf '%s\n' "$h" > "$STATE/pr-after-isolation.json"
: > "$STATE/pr-established-sockets.txt"
while read -r ip; do
  ssh -n "${SSH_ARGS[@]}" "ec2-user@$ip" 'sudo ss -tnp state established | grep vault | grep :8201 || true' >> "$STATE/pr-established-sockets.txt"
done < <(jq -r '.nodes[] | select(.cluster=="secondary") | .public_ip' "$STATE/infrastructure.json")
# A secondary must have an established socket whose peer is one of the primary NLB addresses.
found=false
while read -r ip; do
  if grep -F "$ip:8201" "$STATE/pr-established-sockets.txt" >/dev/null; then found=true; break; fi
done < <(dig +short "${VAULT_ADMIN_ADDR#https://}" A | grep -E '^[0-9]+\.')
[[ "$found" == true ]]
# Also verify the secondary's private NLB API and 8201 listeners from inside the VPC.
SECONDARY_LB=$(jq -r .vault_secondary_address "$STATE/infrastructure.json")
ready=false
for attempt in $(seq 1 30); do
  if ssh -n "${SSH_ARGS[@]}" "ec2-user@$PRIMARY_LEADER" \
    "set -euo pipefail; curl --max-time 10 -fsS '$SECONDARY_LB/v1/sys/health' | jq -e '.initialized and (.sealed|not) and (.standby|not)' >/dev/null; timeout 5 bash -c 'exec 3<>/dev/tcp/${SECONDARY_LB#https://}/8201'" 2>/dev/null; then ready=true; break; fi
  sleep 3
done
[[ "$ready" == true ]]
jq -n --arg date "$(date -u +%FT%TZ)" --slurpfile blocked "$STATE/pr-direct-network.jsonl" \
  --slurpfile pr "$STATE/pr-after-isolation.json" \
  '{evaluated_at:$date,status:"passed",direct_connections:$blocked,established_secondary_to_primary_nlb_8201:true,secondary_nlb_api_and_8201:true,secondary_restart_recovery:true,replication:$pr[0].data.performance}' \
  > "$VM_ROOT/load-balancing/pr-nlb-results.json"
echo 'PR reconnected via NLB after restarting the secondary leader; all nine direct cross-cluster paths are blocked.'

# %% Autenticación con certificado de cliente por los dos FQDN y puertos
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="$VAULT_APPLICATION_ADDR"
mkdir -p "$STATE/client-cert"
CERT_TEST="$STATE/client-cert"
if [[ ! -f "$CERT_TEST/ca.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=VM demo client CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -keyout "$CERT_TEST/ca.key" -out "$CERT_TEST/ca.pem" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -subj '/CN=vm-demo-client' \
    -keyout "$CERT_TEST/client.key" -out "$CERT_TEST/client.csr" 2>/dev/null
  printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n' > "$CERT_TEST/client.ext"
  openssl x509 -req -days 14 -in "$CERT_TEST/client.csr" -CA "$CERT_TEST/ca.pem" \
    -CAkey "$CERT_TEST/ca.key" -CAcreateserial -extfile "$CERT_TEST/client.ext" -out "$CERT_TEST/client.pem" 2>/dev/null
fi
vault auth list -format=json | jq -e 'has("vm-cert/")' >/dev/null || vault auth enable -path=vm-cert cert
vault secrets list -format=json | jq -e 'has("tls-check/")' >/dev/null || vault secrets enable -path=tls-check kv-v2
vault policy write vm-cert-read - <<'HCL'
path "tls-check/data/probe" { capabilities = ["read"] }
HCL
for attempt in $(seq 1 30); do
  vault kv put tls-check/probe value=certificate-login-verified >/dev/null 2>&1 && break
  sleep 1
done
[[ "$(vault kv get -field=value tls-check/probe)" == certificate-login-verified ]]
vault write auth/vm-cert/certs/demo certificate=@"$CERT_TEST/ca.pem" \
  allowed_common_names=vm-demo-client token_policies=vm-cert-read token_ttl=5m token_max_ttl=10m >/dev/null
printf '[]' > "$STATE/client-cert-results.json"
for base in "$VAULT_ADMIN_ADDR" "$VAULT_APPLICATION_ADDR"; do
  for port in 443 8200; do
    url="$base:$port"
    curl --connect-timeout 5 --max-time 20 -fsS --cert "$CERT_TEST/client.pem" --key "$CERT_TEST/client.key" \
      -H 'Content-Type: application/json' --data '{"name":"demo"}' "$url/v1/auth/vm-cert/login" > "$CERT_TEST/login.json"
    token=$(jq -er .auth.client_token "$CERT_TEST/login.json")
    value=$(VAULT_ADDR="$url" VAULT_TOKEN="$token" vault kv get -field=value tls-check/probe)
    [[ "$value" == certificate-login-verified ]]
    denied=$(curl -sS -o "$CERT_TEST/denied.json" -w '%{http_code}' -H "X-Vault-Token: $token" "$url/v1/secret/data/forbidden")
    [[ "$denied" == 403 ]]
    VAULT_ADDR="$url" VAULT_TOKEN="$token" vault token revoke -self >/dev/null
    unauthenticated=$(curl -sS -o "$CERT_TEST/no-cert.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data '{"name":"demo"}' "$url/v1/auth/vm-cert/login")
    [[ "$unauthenticated" == 400 || "$unauthenticated" == 403 ]]
    jq --arg url "$url" '. + [{endpoint:$url,client_certificate_login:"passed",authorized_read:"passed",unauthorized_read:"denied",login_without_certificate:"denied"}]' \
      "$STATE/client-cert-results.json" > "$STATE/client-cert-results.tmp"
    mv "$STATE/client-cert-results.tmp" "$STATE/client-cert-results.json"
    echo "$url: client certificate login, policy and negative tests passed"
  done
done
cp "$STATE/client-cert-results.json" "$VM_ROOT/load-balancing/client-cert-results.json"
