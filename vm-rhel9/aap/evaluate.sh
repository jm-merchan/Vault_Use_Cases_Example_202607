#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/aap-env.sh"
printf '[]\n' > "$STATE/aap/test-results.json"

run_job() {
  local template=$1 method=$2 phase=$3 expected=$4 job status
  "${AAP_CURL[@]}" -X POST -d '{}' "$AAP_API/job_templates/$template/launch/" > "$STATE/aap/launch.json"
  job=$(jq -er .job "$STATE/aap/launch.json")
  for attempt in $(seq 1 180); do
    "${AAP_CURL[@]}" "$AAP_API/jobs/$job/" > "$STATE/aap/job-$job.json"
    status=$(jq -r .status "$STATE/aap/job-$job.json")
    case "$status" in
      successful) jq -e '.event_processing_finished' "$STATE/aap/job-$job.json" >/dev/null && break;;
      failed|error|canceled) break;;
    esac
    sleep 3
  done
  "${AAP_CURL[@]}" "$AAP_API/jobs/$job/stdout/?format=txt" > "$STATE/aap/job-$job.txt"
  if [[ "$expected" == successful ]]; then
    [[ "$status" == successful ]]
    grep -q 'Vault VM secret retrieved and verified' "$STATE/aap/job-$job.txt"
  else
    [[ "$status" == failed || "$status" == error ]]
    # A generic job failure is not proof that the JWT restriction worked.
    jq -n --arg template "$template" \
      '{metadata:{secret_backend:"aap-demo",secret_path:"credentials/test",secret_key:"password",default_auth_path:"aap-jwt",job_template_id:$template}}' > "$STATE/aap/negative-test-payload.json"
    backend=$(jq -er .OIDC.backend "$STATE/aap/controller-resources.json")
    http_code=$(curl -sS --config "$STATE/aap/api.curl" -H 'Content-Type: application/json' -X POST \
      --data @"$STATE/aap/negative-test-payload.json" --output "$STATE/aap/negative-test.json" --write-out '%{http_code}' \
      "$AAP_API/credentials/$backend/test/")
    [[ "$http_code" == 400 ]]
    jq -r '.details.error_message' "$STATE/aap/negative-test.json" > "$STATE/aap/negative-explanation.txt"
    grep -q 'aap_controller_job_template_id' "$STATE/aap/negative-explanation.txt"
    grep -Eiq 'bound claim|bound_claim|claim.*match|claim.*valid' "$STATE/aap/negative-explanation.txt"
  fi
  jq --arg method "$method" --arg phase "$phase" --arg status "$status" --arg expected "$expected" \
    --argjson job "$job" --arg url "$AAP_ADDR/execution/jobs/playbook/$job/details" \
    '. + [{method:$method,phase:$phase,job:$job,status:$status,expected:$expected,passed:true,url:$url}]' \
    "$STATE/aap/test-results.json" > "$STATE/aap/test-results.next.json"
  mv "$STATE/aap/test-results.next.json" "$STATE/aap/test-results.json"
  printf '%s / %s: job %s, %s (expected %s)\n' "$method" "$phase" "$job" "$status" "$expected"
}

for method in AppRole OIDC; do
  template=$(jq -er --arg method "$method" '.[$method].job_template' "$STATE/aap/controller-resources.json")
  run_job "$template" "$method" initial successful
done

# Prove that AAP resolves the current KV value at launch; no cached static secret.
openssl rand -hex 32 | tr -d '\n' > "$STATE/aap/demo-password"
vault kv put aap-demo/credentials/test password=@"$STATE/aap/demo-password" purpose=aap-vm-demo >/dev/null
shasum -a 256 "$STATE/aap/demo-password" | awk '{print $1}' > "$STATE/aap/expected-digest"
for method in AppRole OIDC; do
  template=$(jq -er --arg method "$method" '.[$method].job_template' "$STATE/aap/controller-resources.json")
  jq -n --arg method "$method" --rawfile digest "$STATE/aap/expected-digest" \
    '{extra_vars:({aap_auth_method:$method,aap_expected_digest:($digest|rtrimstr("\n"))}|tojson)}' > "$STATE/aap/rotation-payload.json"
  "${AAP_CURL[@]}" -X PATCH --data @"$STATE/aap/rotation-payload.json" "$AAP_API/job_templates/$template/" > "$STATE/aap/template-updated.json"
  run_job "$template" "$method" rotated successful
done

# Copy the authorized template, keeping its OIDC credential but changing its ID.
"${AAP_CURL[@]}" --get --data-urlencode 'name=Vault VM - OIDC rejected template' "$AAP_API/job_templates/" > "$STATE/aap/negative-template-search.json"
NEGATIVE=$(jq -r '.results[0].id // empty' "$STATE/aap/negative-template-search.json")
if [[ -z "$NEGATIVE" ]]; then
  TEMPLATE=$(jq -er .OIDC.job_template "$STATE/aap/controller-resources.json")
  "${AAP_CURL[@]}" -X POST -d '{"name":"Vault VM - OIDC rejected template"}' "$AAP_API/job_templates/$TEMPLATE/copy/" > "$STATE/aap/negative-template.json"
  NEGATIVE=$(jq -er .id "$STATE/aap/negative-template.json")
fi
run_job "$NEGATIVE" OIDC unauthorized_template rejected

jq -n --arg date "$(date -u +%FT%TZ)" --arg aap "$AAP_ADDR" --arg vault "$VAULT_APPLICATION_ADDR" \
  --slurpfile tests "$STATE/aap/test-results.json" \
  '{evaluated_at:$date,aap_url:$aap,vault_url:$vault,tests:$tests[0],passed:($tests[0]|length==5 and all(.passed))}' > "$VM_ROOT/aap/evaluation.json"
jq -e .passed "$VM_ROOT/aap/evaluation.json" >/dev/null
