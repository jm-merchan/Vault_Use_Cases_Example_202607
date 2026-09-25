# Shared environment only. Operations use curl and Vault CLI in the calling script.
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/notebook-env.sh"
export AAP_ADDR="$(jq -er .aap_address "$STATE/aap/infrastructure.json")"
export AAP_IP="$(jq -er .public_ip "$STATE/aap/infrastructure.json")"
export AAP_API="$AAP_ADDR/api/controller/v2"
export AAP_GATEWAY_API="$AAP_ADDR/api/gateway/v1"
# Authorization stays in a private curl config, outside process arguments and Git.
AAP_CURL=(curl --silent --show-error --fail-with-body --config "$STATE/aap/api.curl" -H 'Content-Type: application/json')
