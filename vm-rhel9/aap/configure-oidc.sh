#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/aap-env.sh"
curl -fsS "$AAP_ADDR/o/.well-known/openid-configuration/" > "$STATE/aap/oidc-discovery.json"
ISSUER=$(jq -er .issuer "$STATE/aap/oidc-discovery.json")
[[ "$ISSUER" == "$AAP_ADDR/o" ]]
curl -fsS "$(jq -er .jwks_uri "$STATE/aap/oidc-discovery.json")" > "$STATE/aap/jwks.json"
jq -e '.keys | length > 0' "$STATE/aap/jwks.json" >/dev/null

vault auth list -format=json | jq -e 'has("aap-jwt/")' >/dev/null || vault auth enable -path=aap-jwt jwt
# The bundled gateway emits workload JWTs with /o/ while discovery advertises /o.
# Match the actual signed iss claim exactly; the discovery URL stays unchanged.
vault write auth/aap-jwt/config oidc_discovery_url="$ISSUER" bound_issuer="${ISSUER%/}/" >/dev/null
jq -n --arg audience "$VAULT_APPLICATION_ADDR" \
  --argjson template "$(jq -er .OIDC.job_template "$STATE/aap/controller-resources.json")" \
  --argjson organization "$(jq -er .organization "$STATE/aap/controller-resources.json")" \
  --argjson project "$(jq -er .project "$STATE/aap/controller-resources.json")" \
  '{role_type:"jwt",user_claim:"sub",bound_audiences:[$audience],bound_claims_type:"string",
    bound_claims:{aap_controller_job_template_id:$template,aap_controller_organization_id:$organization,aap_controller_project_id:$project},
    token_policies:["aap-demo-read"],token_ttl:300,token_max_ttl:600}' > "$STATE/aap/jwt-role-payload.json"
vault write auth/aap-jwt/role/aap-demo @"$STATE/aap/jwt-role-payload.json" >/dev/null
vault read -format=json auth/aap-jwt/role/aap-demo | jq '.data | {role_type,bound_audiences,bound_claims,token_policies,token_ttl}'
