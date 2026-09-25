#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/notebook-env.sh"
REPO=jm-merchan/Vault_Use_Cases_Example_202607
BRANCH=codex/aap-vm-vault
FILE=vm-rhel9/aap/playbooks/verify-secret.yml
mkdir -p "$STATE/aap"
if ! gh api "repos/$REPO/git/ref/heads/$BRANCH" > "$STATE/aap/github-branch.json" 2>/dev/null; then
  base=$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)
  jq -n --arg ref "refs/heads/$BRANCH" --arg sha "$base" '{ref:$ref,sha:$sha}' > "$STATE/aap/github-create-branch.json"
  gh api -X POST "repos/$REPO/git/refs" --input "$STATE/aap/github-create-branch.json" > "$STATE/aap/github-branch.json"
fi
old_sha=''
if gh api "repos/$REPO/contents/$FILE?ref=$BRANCH" > "$STATE/aap/github-current-file.json" 2>/dev/null; then
  old_sha=$(jq -r .sha "$STATE/aap/github-current-file.json")
fi
base64 < "$VM_ROOT/aap/playbooks/verify-secret.yml" | tr -d '\n' > "$STATE/aap/playbook.b64"
jq -n --arg branch "$BRANCH" --arg sha "$old_sha" --rawfile content "$STATE/aap/playbook.b64" \
  '{message:"Add Vault VM secret verification playbook for AAP",branch:$branch,content:$content} + (if $sha=="" then {} else {sha:$sha} end)' \
  > "$STATE/aap/github-publish.json"
gh api -X PUT "repos/$REPO/contents/$FILE" --input "$STATE/aap/github-publish.json" > "$STATE/aap/github-publish-result.json"
jq '{url:.content.html_url,commit:.commit.sha}' "$STATE/aap/github-publish-result.json"
