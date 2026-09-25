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

# Política, HCL, Job y verificación de resultados
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-benchmark --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
vault policy write vm-benchmark - <<'HCL'
path "sys/mounts" { capabilities = ["read", "list"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth" { capabilities = ["read", "list"] }
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "auth/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "+/data/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "+/metadata/*" { capabilities = ["create", "read", "update", "delete", "list"] }

HCL

vault token create -policy=vm-benchmark -ttl=1h -orphan -format=json | jq -jr .auth.client_token > "$STATE/benchmark-token"
trap 'vault token revoke "$(cat "$STATE/benchmark-token")" >/dev/null' EXIT
"${KUBECTL[@]}" -n vm-benchmark create secret generic benchmark-token --from-file=token="$STATE/benchmark-token" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat > "$STATE/benchmark.hcl" <<'HCL'
vault_addr = ""
vault_token = ""
duration = "30s"
report_mode = "terse"
random_mounts = true
cleanup = true
test "approle_auth" "approle_logins" {
  weight = 50
  config {
    role {
      role_name = "benchmark-role"
      token_ttl = "2m"
    }
  }
}
test "kvv2_write" "static_secret_writes" {
  weight = 50
  config {
    numkvs = 100
    kvsize = 256
  }
}
HCL
"${KUBECTL[@]}" -n vm-benchmark create configmap benchmark --from-file=benchmark.hcl="$STATE/benchmark.hcl" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" -n vm-benchmark delete job benchmark --ignore-not-found
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: benchmark
  namespace: vm-benchmark
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: benchmark
          image: hashicorp/vault-benchmark:0.3.0
          command: [vault-benchmark]
          args: [run, -config=/config/benchmark.hcl, -rps=50, -workers=5]
          env:
            - name: VAULT_ADDR
              value: "$VAULT_ADDR"
            - name: VAULT_TOKEN
              valueFrom:
                secretKeyRef: {name: benchmark-token, key: token}
          volumeMounts:
            - {name: config, mountPath: /config}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: '1', memory: 512Mi}
      volumes:
        - name: config
          configMap: {name: benchmark}
EOF
"${KUBECTL[@]}" -n vm-benchmark wait --for=condition=complete job/benchmark --timeout=300s
"${KUBECTL[@]}" -n vm-benchmark logs job/benchmark > "$STATE/benchmark.log"
awk '/^approle_logins|^static_secret_writes/ {print; n++; if ($2<=0 || $NF+0 != 100) bad=1} END {exit(n!=2 || bad)}' "$STATE/benchmark.log"
awk '/^approle_logins|^static_secret_writes/ {printf "{\"operation\":\"%s\",\"count\":%s,\"rate\":%s,\"throughput\":%s,\"mean\":\"%s\",\"p95\":\"%s\",\"p99\":\"%s\",\"success_ratio\":\"%s\"}\n",$1,$2,$3,$4,$5,$6,$7,$NF}' "$STATE/benchmark.log" | jq -s . > "$VM_ROOT/reports/benchmark.json"
