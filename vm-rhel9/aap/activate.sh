#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/aap-env.sh"
test -s "$STATE/aap/manifest.zip"
test -s "$STATE/aap/api.curl"
base64 < "$STATE/aap/manifest.zip" | tr -d '\n' > "$STATE/aap/manifest.base64"
jq -n --rawfile manifest "$STATE/aap/manifest.base64" '{manifest:$manifest}' > "$STATE/aap/activation-payload.json"
"${AAP_CURL[@]}" -X POST --data @"$STATE/aap/activation-payload.json" "$AAP_API/config/" > "$STATE/aap/activation.json"
"${AAP_CURL[@]}" "$AAP_API/config/" > "$STATE/aap/config.json"
jq -e '.license_info.valid_key == true' "$STATE/aap/config.json" >/dev/null
jq '.license_info | {license_type,instance_count,valid_key,trial,subscription_name,time_remaining}' "$STATE/aap/config.json"
