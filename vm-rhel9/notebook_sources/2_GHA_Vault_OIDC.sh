#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
for tool in aws az vault curl jq kubectl ssh terraform; do command -v "$tool" >/dev/null; done
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  if ! doormat aws -a "$DOORMAT_AWS_ACCOUNT" export > "$STATE/aws-session.env"; then
    doormat login -f
    doormat aws -a "$DOORMAT_AWS_ACCOUNT" export > "$STATE/aws-session.env"
  fi
  source "$STATE/aws-session.env"
fi
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
# Persist only AWS session variables, never a Vault root token in notebook output.
{ declare -p AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true; } > "$STATE/aws-session.env"

# Rol OIDC, claims y política de GitHub
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault auth list -format=json | jq -e 'has("vm-github/")' >/dev/null || vault auth enable -path=vm-github jwt
vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null || vault secrets enable -path=secret kv-v2
for attempt in $(seq 1 60); do vault read secret/config >/dev/null 2>&1 && break; sleep 1; done
vault read secret/config >/dev/null
vault kv put secret/gha/demo api_key="$(openssl rand -hex 16)" >/dev/null
vault write auth/vm-github/config oidc_discovery_url=https://token.actions.githubusercontent.com bound_issuer=https://token.actions.githubusercontent.com
vault policy write vm-github-read - <<'HCL'
path "secret/data/gha/demo" { capabilities = ["read"] }
HCL
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
jq -n --arg repo "$REPO" '{role_type:"jwt",user_claim:"repository",bound_audiences:["vault-vm"],bound_claims:{repository:$repo,ref:"refs/heads/codex/vm-rhel9-poc"},token_policies:["vm-github-read"],token_ttl:"10m",token_max_ttl:"15m"}' |
  curl -fsS -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' --data @- "$VAULT_ADDR/v1/auth/vm-github/role/read" >/dev/null

# Workflow completo y ejecución real en GitHub
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
# YAML completo del workflow, incluidas sus llamadas curl y kubectl.
cat > "$VM_ROOT/workflows/vault-oidc.yml" <<'WORKFLOW'
name: Vault RHEL9 read
'on':
  workflow_dispatch: {}
permissions:
  contents: read
  id-token: write
jobs:
  verify:
    runs-on: ubuntu-latest
    env:
      VAULT_ADDR: https://vault-vm-apps.jose-merchan.sbx.hashidemos.io
      ROLE: read
    steps:
    - name: Verify Vault on RHEL9
      shell: bash
      run: 'set -euo pipefail

        jwt=$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}"
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=vault-vm" | jq -er .value)

        login=$(jq -n --arg jwt "$jwt" --arg role "$ROLE" ''{jwt:$jwt,role:$role}''
        | curl -fsS -H ''Content-Type: application/json'' -d @- "$VAULT_ADDR/v1/auth/vm-github/login")

        token=$(jq -er .auth.client_token <<<"$login")

        echo "::add-mask::$token"

        trap ''curl -fsS -H "X-Vault-Token: $token" -X POST "$VAULT_ADDR/v1/auth/token/revoke-self"
        >/dev/null'' EXIT

        curl -fsS -H "X-Vault-Token: $token" "$VAULT_ADDR/v1/secret/data/gha/demo"
        | jq -e ''.data.data.api_key | length > 0'' >/dev/null

        echo "VM workflow assertions passed"

        '
WORKFLOW

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
BRANCH=codex/vm-rhel9-poc
if ! gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  DEFAULT=$(gh api "repos/$REPO" --jq .default_branch)
  SHA=$(gh api "repos/$REPO/git/ref/heads/$DEFAULT" --jq .object.sha)
  jq -n --arg ref "refs/heads/$BRANCH" --arg sha "$SHA" '{ref:$ref,sha:$sha}' | gh api "repos/$REPO/git/refs" -X POST --input - >/dev/null
fi
FILE=vault-oidc.yml
SHA=$(gh api "repos/$REPO/contents/.github/workflows/$FILE?ref=$BRANCH" --jq .sha)
CONTENT=$(openssl base64 -A -in "$VM_ROOT/workflows/$FILE")
jq -n --arg branch "$BRANCH" --arg sha "$SHA" --arg content "$CONTENT" \
  '{message:"Make VM demo CLI workflow explicit",branch:$branch,sha:$sha,content:$content}' |
  gh api "repos/$REPO/contents/.github/workflows/$FILE" -X PUT --input - >/dev/null
gh api "repos/$REPO/actions/workflows/$FILE/runs?branch=$BRANCH" --jq '[.workflow_runs[].id]' > "$STATE/github-before.json"
gh workflow run "$FILE" --repo "$REPO" --ref "$BRANCH"
ID=''
for attempt in $(seq 1 30); do
  ID=$(gh api "repos/$REPO/actions/workflows/$FILE/runs?branch=$BRANCH" | jq -r --slurpfile before "$STATE/github-before.json" '[.workflow_runs[] | select(.id as $id | $before[0] | index($id) | not)][0].id // empty')
  [[ -z "$ID" ]] || break
  sleep 3
done
test -n "$ID"
for attempt in $(seq 1 120); do
  gh api "repos/$REPO/actions/runs/$ID" > "$STATE/github-run.json"
  [[ "$(jq -r .status "$STATE/github-run.json")" == completed ]] && break
  sleep 5
done
jq -e '.conclusion=="success"' "$STATE/github-run.json"
jq --arg repo "$REPO" '{id:.id,url:.html_url,repo:$repo}' "$STATE/github-run.json" > "$STATE/github-read.json"
jq -r .html_url "$STATE/github-run.json"
