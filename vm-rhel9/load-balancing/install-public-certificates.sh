#!/usr/bin/env bash
# Run from any directory. Issuance/renewal is separate; this script deploys validated files.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/notebook-env.sh"
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
