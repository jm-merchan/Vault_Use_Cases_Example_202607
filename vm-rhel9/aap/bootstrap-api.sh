#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/aap-env.sh"
if [[ -s "$STATE/aap/api.curl" ]] && "${AAP_CURL[@]}" "$AAP_GATEWAY_API/me/" > "$STATE/aap/me.json" 2>/dev/null; then
  echo 'AAP API session already valid'
  exit 0
fi
ssh -n "${SSH_ARGS[@]}" "ec2-user@$AAP_IP" \
  'podman exec automation-gateway aap-gateway-manage create_oauth2_token --user admin --no-color' > "$STATE/aap/token-command.txt"
awk 'NF == 1 && /^[[:alnum:]_-]+$/ {print; exit} /New OAuth2 token for admin:/ {print $NF; exit}' "$STATE/aap/token-command.txt" > "$STATE/aap/api-token"
TOKEN=$(cat "$STATE/aap/api-token")
if [[ ! "$TOKEN" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
  echo 'The management command did not return a valid token' >&2
  exit 1
fi
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$STATE/aap/api.curl"
unset TOKEN
"${AAP_CURL[@]}" "$AAP_GATEWAY_API/me/" > "$STATE/aap/me.json"
echo 'AAP API session created; token saved only in .state/aap/'
