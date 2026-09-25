#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/aap-env.sh"

# Reconcile only the dedicated demo objects. API responses stay outside Git.
upsert() {
  local resource=$1 name=$2 payload=$3 id
  "${AAP_CURL[@]}" --get --data-urlencode "name=$name" "$AAP_API/$resource/" > "$STATE/aap/search.json"
  jq -e '.count <= 1' "$STATE/aap/search.json" >/dev/null
  id=$(jq -r '.results[0].id // empty' "$STATE/aap/search.json")
  if [[ -n "$id" ]]; then
    "${AAP_CURL[@]}" -X PATCH --data @"$payload" "$AAP_API/$resource/$id/" > "$STATE/aap/object.json"
  else
    "${AAP_CURL[@]}" -X POST --data @"$payload" "$AAP_API/$resource/" > "$STATE/aap/object.json"
  fi
  jq -er .id "$STATE/aap/object.json"
}

"${AAP_CURL[@]}" --get --data-urlencode name=Default "$AAP_API/organizations/" > "$STATE/aap/organizations.json"
ORG=$(jq -er '.results[0].id' "$STATE/aap/organizations.json")
"${AAP_CURL[@]}" "$AAP_API/execution_environments/?page_size=200" > "$STATE/aap/execution-environments.json"
EE=$(jq -er '[.results[] | select(.name | test("Default execution environment|supported";"i"))][0].id' "$STATE/aap/execution-environments.json")

jq -n --argjson org "$ORG" '{name:"Vault VM demo inventory",organization:$org,variables:"ansible_connection: local"}' > "$STATE/aap/inventory-payload.json"
INVENTORY=$(upsert inventories 'Vault VM demo inventory' "$STATE/aap/inventory-payload.json")
"${AAP_CURL[@]}" "$AAP_API/inventories/$INVENTORY/hosts/?name=localhost" > "$STATE/aap/hosts.json"
if [[ $(jq -r .count "$STATE/aap/hosts.json") == 0 ]]; then
  "${AAP_CURL[@]}" -X POST -d '{"name":"localhost","variables":"ansible_connection: local"}' "$AAP_API/inventories/$INVENTORY/hosts/" > "$STATE/aap/host.json"
fi

jq -n --argjson org "$ORG" '{name:"Vault VM demo project",organization:$org,scm_type:"git",scm_url:"https://github.com/jm-merchan/Vault_Use_Cases_Example_202607.git",scm_branch:"codex/aap-vm-vault",scm_update_on_launch:false}' > "$STATE/aap/project-payload.json"
PROJECT=$(upsert projects 'Vault VM demo project' "$STATE/aap/project-payload.json")
for attempt in $(seq 1 120); do
  "${AAP_CURL[@]}" "$AAP_API/projects/$PROJECT/" > "$STATE/aap/project.json"
  status=$(jq -r .status "$STATE/aap/project.json")
  [[ "$status" != successful ]] || break
  [[ "$status" != failed && "$status" != error ]] || { echo "Project sync: $status" >&2; exit 1; }
  sleep 3
done
jq -e '.status == "successful"' "$STATE/aap/project.json" >/dev/null

cat > "$STATE/aap/credential-type-payload.json" <<'JSON'
{"name":"Vault VM demo secret","kind":"cloud","inputs":{"fields":[{"id":"vault_password","label":"Demo password from Vault","type":"string","secret":true}],"required":["vault_password"]},"injectors":{"env":{"AAP_VAULT_DEMO_SECRET":"{{ vault_password }}"}}}
JSON
TYPE=$(upsert credential_types 'Vault VM demo secret' "$STATE/aap/credential-type-payload.json")

jq -n --argjson organization "$ORG" --argjson inventory "$INVENTORY" --argjson project "$PROJECT" --argjson ee "$EE" --argjson type "$TYPE" \
  '{organization:$organization,inventory:$inventory,project:$project,execution_environment:$ee,credential_type:$type}' > "$STATE/aap/controller-resources.json"

for method in AppRole OIDC; do
  jq -n --arg name "Vault VM demo $method secret" --argjson org "$ORG" --argjson type "$TYPE" \
    '{name:$name,organization:$org,credential_type:$type,inputs:{}}' > "$STATE/aap/target-credential-payload.json"
  CREDENTIAL=$(upsert credentials "Vault VM demo $method secret" "$STATE/aap/target-credential-payload.json")
  jq -n --arg name "Vault VM - $method" --argjson inventory "$INVENTORY" --argjson project "$PROJECT" --argjson ee "$EE" \
    --arg method "$method" --rawfile digest "$STATE/aap/expected-digest" \
    '{name:$name,job_type:"run",inventory:$inventory,project:$project,execution_environment:$ee,
      playbook:"vm-rhel9/aap/playbooks/verify-secret.yml",timeout:600,
      extra_vars:({aap_auth_method:$method,aap_expected_digest:($digest|rtrimstr("\n"))}|tojson)}' > "$STATE/aap/job-template-payload.json"
  TEMPLATE=$(upsert job_templates "Vault VM - $method" "$STATE/aap/job-template-payload.json")
  "${AAP_CURL[@]}" "$AAP_API/job_templates/$TEMPLATE/credentials/" > "$STATE/aap/template-credentials.json"
  if ! jq -e --argjson id "$CREDENTIAL" 'any(.results[]; .id == $id)' "$STATE/aap/template-credentials.json" >/dev/null; then
    jq -n --argjson id "$CREDENTIAL" '{id:$id}' > "$STATE/aap/associate-payload.json"
    "${AAP_CURL[@]}" -X POST --data @"$STATE/aap/associate-payload.json" "$AAP_API/job_templates/$TEMPLATE/credentials/" > "$STATE/aap/associate.json"
  fi
  jq --arg method "$method" --argjson credential "$CREDENTIAL" --argjson template "$TEMPLATE" \
    '.[$method]={credential:$credential,job_template:$template}' "$STATE/aap/controller-resources.json" > "$STATE/aap/controller-resources.next.json"
  mv "$STATE/aap/controller-resources.next.json" "$STATE/aap/controller-resources.json"
done
jq . "$STATE/aap/controller-resources.json"
