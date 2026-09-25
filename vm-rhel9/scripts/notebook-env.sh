# Environment only: no provisioning or scenario operations are hidden here.
VM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VM_ROOT STATE="$VM_ROOT/.state"
# macOS ships LibreSSL; use OpenSSL 3 for SAN inspection and the portable CLI examples.
if [[ -x /opt/homebrew/opt/openssl@3/bin/openssl ]]; then
  export PATH="/opt/homebrew/opt/openssl@3/bin:$PATH"
fi
umask 077
mkdir -p "$STATE"
chmod 700 "$STATE"
[[ ! -f "$VM_ROOT/.env" ]] || { set -a; source "$VM_ROOT/.env"; set +a; }
[[ ! -f "$STATE/aws-session.env" ]] || source "$STATE/aws-session.env"
export AWS_REGION="${AWS_REGION:-eu-central-1}" AWS_DEFAULT_REGION="${AWS_REGION:-eu-central-1}"
export DOORMAT_AWS_ACCOUNT="${DOORMAT_AWS_ACCOUNT:-aws_jose.merchan_test}"
export KUBE_CONTEXT="${KUBE_CONTEXT:-arn:aws:eks:eu-central-1:492487827579:cluster/eks-infra-dev}"
export VAULT_NAMESPACE='' VAULT_CACERT='' VAULT_TLS_SERVER_NAME='' VAULT_SKIP_VERIFY=false
if [[ -f "$STATE/infrastructure.json" ]]; then
  export VAULT_ADDR="$(jq -er .vault_address "$STATE/infrastructure.json")"
  export VAULT_ADMIN_ADDR="$VAULT_ADDR"
  export VAULT_APPLICATION_ADDR="$(jq -r '.vault_application_address // empty' "$STATE/infrastructure.json")"
  export APP_IP="$(jq -er .nodes.app.public_ip "$STATE/infrastructure.json")"
fi
if [[ -f "$STATE/primary-init.json" ]]; then
  export VAULT_TOKEN="$(jq -er .root_token "$STATE/primary-init.json")"
fi
# Read only Azure IDs from the original dotenv; never import its Vault token/address.
for field in AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID; do
  if [[ -z "${!field:-}" && -f "$VM_ROOT/../.env" ]]; then
    value=$(sed -n "s/^${field}=//p" "$VM_ROOT/../.env" | head -1 | tr -d '\r' | sed "s/^[\"']//;s/[\"']$//")
    export "$field=$value"
  fi
done
export ARM_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}" ARM_TENANT_ID="${AZURE_TENANT_ID:-}"
export NO_COLOR=1 CLICOLOR=0 CLICOLOR_FORCE=0 FORCE_COLOR=0 GH_FORCE_TTY=''
SSH_ARGS=(-i "$STATE/id_ed25519" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=\"$STATE/known_hosts\"" -o ConnectTimeout=10)
KUBECTL=(kubectl --context "$KUBE_CONTEXT")
