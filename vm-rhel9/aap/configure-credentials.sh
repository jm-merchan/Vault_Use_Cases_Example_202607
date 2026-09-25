#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/aap-env.sh"

"${AAP_CURL[@]}" "$AAP_API/credential_types/?page_size=200" > "$STATE/aap/credential-types.json"
APPROLE_TYPE=$(jq -er '.results[] | select(.namespace == "hashivault_kv") | .id' "$STATE/aap/credential-types.json")
OIDC_TYPE=$(jq -er '.results[] | select(.namespace == "hashivault-kv-oidc") | .id' "$STATE/aap/credential-types.json")
ORG=$(jq -er .organization "$STATE/aap/controller-resources.json")

for method in AppRole OIDC; do
  if [[ "$method" == AppRole ]]; then
    jq -n --arg url "$VAULT_APPLICATION_ADDR" --argjson org "$ORG" --argjson type "$APPROLE_TYPE" \
      --slurpfile role "$STATE/aap/role-id.json" --slurpfile secret "$STATE/aap/secret-id.json" \
      '{name:"Vault VM - AppRole backend",organization:$org,credential_type:$type,
        inputs:{url:$url,api_version:"v2",default_auth_path:"aap-approle",role_id:$role[0].data.role_id,secret_id:$secret[0].data.secret_id}}' > "$STATE/aap/backend-payload.json"
  else
    jq -n --arg url "$VAULT_APPLICATION_ADDR" --argjson org "$ORG" --argjson type "$OIDC_TYPE" \
      '{name:"Vault VM - OIDC backend",organization:$org,credential_type:$type,
        inputs:{url:$url,api_version:"v2",default_auth_path:"aap-jwt",jwt_role:"aap-demo"}}' > "$STATE/aap/backend-payload.json"
  fi
  "${AAP_CURL[@]}" --get --data-urlencode "name=Vault VM - $method backend" "$AAP_API/credentials/" > "$STATE/aap/backend-search.json"
  BACKEND=$(jq -r '.results[0].id // empty' "$STATE/aap/backend-search.json")
  if [[ -n "$BACKEND" ]]; then
    "${AAP_CURL[@]}" -X PATCH --data @"$STATE/aap/backend-payload.json" "$AAP_API/credentials/$BACKEND/" > "$STATE/aap/backend.json"
  else
    "${AAP_CURL[@]}" -X POST --data @"$STATE/aap/backend-payload.json" "$AAP_API/credentials/" > "$STATE/aap/backend.json"
    BACKEND=$(jq -er .id "$STATE/aap/backend.json")
  fi
  TARGET=$(jq -er --arg method "$method" '.[$method].credential' "$STATE/aap/controller-resources.json")
  jq -n --argjson source "$BACKEND" --arg method "$method" \
    '{source_credential:$source,input_field_name:"vault_password",metadata:({secret_backend:"aap-demo",secret_path:"credentials/test",secret_key:"password"} +
      (if $method == "OIDC" then {default_auth_path:"aap-jwt"} else {auth_path:"aap-approle"} end))}' > "$STATE/aap/input-source-payload.json"
  "${AAP_CURL[@]}" "$AAP_API/credentials/$TARGET/input_sources/" > "$STATE/aap/input-sources.json"
  INPUT=$(jq -r '.results[] | select(.input_field_name == "vault_password") | .id' "$STATE/aap/input-sources.json")
  if [[ -n "$INPUT" ]]; then
    "${AAP_CURL[@]}" -X PATCH --data @"$STATE/aap/input-source-payload.json" "$AAP_API/credential_input_sources/$INPUT/" > "$STATE/aap/input-source.json"
  else
    "${AAP_CURL[@]}" -X POST --data @"$STATE/aap/input-source-payload.json" "$AAP_API/credentials/$TARGET/input_sources/" > "$STATE/aap/input-source.json"
  fi
  jq --arg method "$method" --argjson backend "$BACKEND" '.[$method].backend=$backend' "$STATE/aap/controller-resources.json" > "$STATE/aap/controller-resources.next.json"
  mv "$STATE/aap/controller-resources.next.json" "$STATE/aap/controller-resources.json"
  printf '%s external lookup configured: backend %s -> target credential %s\n' "$method" "$BACKEND" "$TARGET"
done
