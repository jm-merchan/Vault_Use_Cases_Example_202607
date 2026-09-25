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

# Controladores VSO/CSI
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-consumers --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
if ! "${KUBECTL[@]}" get deployments -A -o json | jq -e 'any(.items[]; .metadata.name | contains("vault-secrets-operator"))' >/dev/null; then
  helm --kube-context "$KUBE_CONTEXT" upgrade --install vm-vso hashicorp/vault-secrets-operator -n vm-vso-system --create-namespace --version 0.10.0 --wait
fi
if ! "${KUBECTL[@]}" get crd secretproviderclasses.secrets-store.csi.x-k8s.io >/dev/null 2>&1; then
  helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts --force-update
  helm --kube-context "$KUBE_CONTEXT" upgrade --install vm-csi secrets-store-csi-driver/secrets-store-csi-driver -n vm-csi-system --create-namespace --set enableSecretRotation=true --set rotationPollInterval=30s --wait
fi
if ! "${KUBECTL[@]}" get daemonset -A -o json | jq -e 'any(.items[]; .metadata.name | contains("vault-csi-provider"))' >/dev/null; then
  helm --kube-context "$KUBE_CONTEXT" upgrade --install vm-vault-csi hashicorp/vault -n vm-csi-system --create-namespace --version 0.34.0 --set server.enabled=false --set injector.enabled=false --set csi.enabled=true --wait
fi

# Autenticación Kubernetes
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-consumers --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

for sa in consumer reviewer; do
  "${KUBECTL[@]}" -n vm-consumers create serviceaccount "$sa" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
done
"${KUBECTL[@]}" create clusterrolebinding vm-consumers-reviewer --clusterrole=system:auth-delegator --serviceaccount=vm-consumers:reviewer --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" config view --minify --raw --flatten -o json > "$STATE/kube-connection.json"
K8S_SERVER=$(jq -r '.clusters[0].cluster.server' "$STATE/kube-connection.json")
jq -r '.clusters[0].cluster."certificate-authority-data"' "$STATE/kube-connection.json" | openssl base64 -d -A > "$STATE/kubernetes-ca.pem"
"${KUBECTL[@]}" -n vm-consumers create token reviewer --duration=24h > "$STATE/reviewer.jwt"
vault auth list -format=json | jq -e 'has("vm-kubernetes/")' >/dev/null || vault auth enable -path=vm-kubernetes kubernetes

vault write auth/vm-kubernetes/config kubernetes_host="$K8S_SERVER" \
  kubernetes_ca_cert=@"$STATE/kubernetes-ca.pem" token_reviewer_jwt=@"$STATE/reviewer.jwt" disable_local_ca_jwt=true
vault policy write vm-consumer - <<'HCL'
path "secret/data/vm/*" { capabilities = ["read"] }
path "vm-gha/secret/data/*" { capabilities = ["read"] }
path "database/creds/readonly" { capabilities = ["read"] }
path "aws-vm/sts/demo" { capabilities = ["read"] }
HCL
vault write auth/vm-kubernetes/role/consumer bound_service_account_names=consumer \
  bound_service_account_namespaces=vm-consumers audience=vault token_policies=vm-consumer token_ttl=10m
"${KUBECTL[@]}" -n vm-consumers create token consumer --audience=vault --duration=10m > "$STATE/consumer.jwt"
vault write -format=json auth/vm-kubernetes/login role=consumer jwt=@"$STATE/consumer.jwt" > "$STATE/consumer-login.json"
jq -e '.auth.client_token | length>0' "$STATE/consumer-login.json" >/dev/null
"${KUBECTL[@]}" -n vm-consumers create token reviewer --audience=vault --duration=10m > "$STATE/wrong-sa.jwt"
if vault write auth/vm-kubernetes/login role=consumer jwt=@"$STATE/wrong-sa.jwt" >/dev/null 2>&1; then exit 1; fi

# PostgreSQL auxiliar
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
"${KUBECTL[@]}" create namespace vm-demo --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
[[ -s "$STATE/postgres-password" ]] || openssl rand -hex 20 | tr -d '
' > "$STATE/postgres-password"
"${KUBECTL[@]}" -n vm-demo create secret generic postgres --from-file=POSTGRES_PASSWORD="$STATE/postgres-password" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: vm-demo
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3
  volumeMode: Filesystem
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: vm-demo
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: vm-postgres
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: vm-postgres
    spec:
      containers:
      - env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              key: POSTGRES_PASSWORD
              name: postgres
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        image: postgres:17.6
        imagePullPolicy: IfNotPresent
        name: postgres
        ports:
        - containerPort: 5432
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          periodSeconds: 5
          successThreshold: 1
          tcpSocket:
            port: 5432
          timeoutSeconds: 1
        resources:
          limits:
            cpu: '2'
            memory: 1Gi
          requests:
            cpu: 100m
            memory: 256Mi
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: data
      dnsPolicy: ClusterFirst
      enableServiceLinks: false
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: postgres-data
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: vm-demo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: 'true'
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  allocateLoadBalancerNodePorts: true
  externalTrafficPolicy: Cluster
  internalTrafficPolicy: Cluster
  ports:
  - port: 5432
    protocol: TCP
    targetPort: 5432
  selector:
    app: vm-postgres
  sessionAffinity: None
  type: LoadBalancer
EOF
"${KUBECTL[@]}" -n vm-demo rollout status deployment/postgres --timeout=1800s
for attempt in $(seq 1 120); do
  endpoint=$("${KUBECTL[@]}" -n vm-demo get service postgres -o json | jq -r '.status.loadBalancer.ingress[0].hostname // empty')
  [[ -z "$endpoint" ]] || break
  sleep 5
done
test -n "$endpoint"
printf '%s' "$endpoint" > "$STATE/postgres-endpoint"

# Database Engine
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault secrets list -format=json | jq -e 'has("database/")' >/dev/null || vault secrets enable -path=database database

if ! vault read database/config/postgresql >/dev/null 2>&1; then
  # Reconcile the isolated demo DB if Vault was freshly initialized after an earlier root rotation.
  printf "ALTER USER postgres WITH PASSWORD '%s';\n" "$(cat "$STATE/postgres-password")" |
    "${KUBECTL[@]}" -n vm-demo exec -i deployment/postgres -- psql -U postgres -v ON_ERROR_STOP=1 >/dev/null
  vault write database/config/postgresql plugin_name=postgresql-database-plugin \
    allowed_roles=readonly,agent-db username=postgres password=@"$STATE/postgres-password" \
    connection_url="postgresql://{{username}}:{{password}}@$(cat "$STATE/postgres-endpoint"):5432/postgres?sslmode=disable"
fi
cat > "$STATE/postgres-create.sql" <<'SQL'
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT CONNECT ON DATABASE postgres TO "{{name}}";
GRANT USAGE ON SCHEMA public TO "{{name}}";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";
SQL
for role in readonly agent-db; do
  vault write "database/roles/$role" db_name=postgresql creation_statements=@"$STATE/postgres-create.sql" default_ttl=3m max_ttl=1h
done

# Consumidores VSO/CSI
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null || vault secrets enable -path=secret kv-v2
for attempt in $(seq 1 60); do vault read secret/config >/dev/null 2>&1 && break; sleep 1; done
vault read secret/config >/dev/null
vault kv put secret/vm/static value=vm-version-1 >/dev/null
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vm-vault
  namespace: vm-consumers
spec:
  address: ${VAULT_APPLICATION_ADDR}
  skipTLSVerify: false
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vm-vault
  namespace: vm-consumers
spec:
  kubernetes:
    audiences:
    - vault
    role: consumer
    serviceAccount: consumer
    tokenExpirationSeconds: 600
  method: kubernetes
  mount: vm-kubernetes
  vaultConnectionRef: vm-vault
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vm-static
  namespace: vm-consumers
spec:
  destination:
    create: true
    name: vm-static
    overwrite: true
    transformation: {}
  hmacSecretData: true
  mount: secret
  path: vm/static
  refreshAfter: 10s
  type: kv-v2
  vaultAuthRef: vm-vault
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: vm-dynamic
  namespace: vm-consumers
spec:
  destination:
    create: true
    name: vm-dynamic
    overwrite: true
    transformation: {}
  mount: database
  path: creds/readonly
  renewalPercent: 50
  vaultAuthRef: vm-vault
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vm-vault
  namespace: vm-consumers
spec:
  parameters:
    audience: vault
    objects: |
      - objectName: static
        secretKey: value
        secretPath: secret/data/vm/static
      - objectName: db-user
        secretKey: username
        secretPath: database/creds/readonly
      - objectName: db-password
        secretKey: password
        secretPath: database/creds/readonly
    roleName: consumer
    vaultAddress: ${VAULT_APPLICATION_ADDR}
    vaultAuthMountPath: vm-kubernetes
  provider: vault
EOF
"${KUBECTL[@]}" -n vm-consumers delete pod vm-secret-reader --ignore-not-found --wait=true
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vm-secret-reader
  namespace: vm-consumers
spec:
  containers:
  - command:
    - sh
    - -c
    - sleep 86400
    image: busybox:1.37.0
    imagePullPolicy: IfNotPresent
    name: reader
    resources: {}
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    volumeMounts:
    - mountPath: /csi
      name: csi
      readOnly: true
    - mountPath: /static
      name: static
      readOnly: true
    - mountPath: /dynamic
      name: dynamic
      readOnly: true
  dnsPolicy: ClusterFirst
  enableServiceLinks: true
  preemptionPolicy: PreemptLowerPriority
  priority: 0
  restartPolicy: Always
  schedulerName: default-scheduler
  securityContext: {}
  serviceAccount: consumer
  serviceAccountName: consumer
  terminationGracePeriodSeconds: 30
  tolerations:
  - effect: NoExecute
    key: node.kubernetes.io/not-ready
    operator: Exists
    tolerationSeconds: 300
  - effect: NoExecute
    key: node.kubernetes.io/unreachable
    operator: Exists
    tolerationSeconds: 300
  volumes:
  - csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: vm-vault
    name: csi
  - name: static
    secret:
      defaultMode: 420
      secretName: vm-static
  - name: dynamic
    secret:
      defaultMode: 420
      secretName: vm-dynamic
EOF
"${KUBECTL[@]}" -n vm-consumers wait --for=condition=Ready pod/vm-secret-reader --timeout=300s

# Motor Kubernetes y RBAC
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
vault secrets list -format=json | jq -e 'has("kubernetes/")' >/dev/null || vault secrets enable -path=kubernetes kubernetes
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: engine
  namespace: vm-consumers
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: engine
  namespace: vm-consumers
rules:
- apiGroups:
  - ''
  resources:
  - serviceaccounts
  verbs:
  - get
  - create
  - update
  - delete
- apiGroups:
  - ''
  resources:
  - serviceaccounts/token
  verbs:
  - create
- apiGroups:
  - rbac.authorization.k8s.io
  resourceNames:
  - consumer
  resources:
  - roles
  verbs:
  - get
  - bind
- apiGroups:
  - rbac.authorization.k8s.io
  resources:
  - rolebindings
  verbs:
  - get
  - create
  - update
  - delete
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: engine
  namespace: vm-consumers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: engine
subjects:
- kind: ServiceAccount
  name: engine
  namespace: vm-consumers
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: consumer
  namespace: vm-consumers
rules:
- apiGroups:
  - ''
  resources:
  - configmaps
  verbs:
  - get
  - list
  - create
  - update
  - patch
  - delete
- apiGroups:
  - secrets.hashicorp.com
  resources:
  - vaultconnections
  - vaultauths
  - vaultstaticsecrets
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - apps
  resources:
  - deployments
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: consumer
  namespace: vm-consumers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: consumer
subjects:
- kind: ServiceAccount
  name: consumer
  namespace: vm-consumers
EOF

K8S_SERVER=$("${KUBECTL[@]}" config view --minify --raw --flatten -o json | jq -r '.clusters[0].cluster.server')
"${KUBECTL[@]}" -n vm-consumers create token engine --duration=24h > "$STATE/engine.jwt"
vault write kubernetes/config kubernetes_host="$K8S_SERVER" kubernetes_ca_cert=@"$STATE/kubernetes-ca.pem" \
  service_account_jwt=@"$STATE/engine.jwt" disable_local_ca_jwt=true
vault write kubernetes/roles/github allowed_kubernetes_namespaces=vm-consumers service_account_name='' \
  kubernetes_role_name=consumer kubernetes_role_type=Role token_default_ttl=10m token_max_ttl=1h
vault write -format=json kubernetes/creds/github kubernetes_namespace=vm-consumers > "$STATE/k8s-credentials.json"
TOKEN=$(jq -r .data.service_account_token "$STATE/k8s-credentials.json")
K8S_DYNAMIC=(kubectl --server "$K8S_SERVER" --certificate-authority "$STATE/kubernetes-ca.pem" --token "$TOKEN")
"${K8S_DYNAMIC[@]}" auth can-i create configmaps -n vm-consumers | grep -qx yes
if "${K8S_DYNAMIC[@]}" auth can-i get secrets -n kube-system >/dev/null; then exit 1; fi
vault lease revoke "$(jq -r .lease_id "$STATE/k8s-credentials.json")" >/dev/null
for attempt in $(seq 1 30); do
  if ! "${K8S_DYNAMIC[@]}" auth can-i create configmaps -n vm-consumers >/dev/null 2>&1; then break; fi
  sleep 3
done
if "${K8S_DYNAMIC[@]}" auth can-i create configmaps -n vm-consumers >/dev/null 2>&1; then exit 1; fi
echo 'Permisos acotados y revocación del token Kubernetes verificados'

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
vault policy write vm-github-engine - <<'HCL'
path "secret/data/gha/demo" { capabilities = ["read"] }
path "kubernetes/creds/github" { capabilities = ["update"] }
path "secret/data/vm/static" { capabilities = ["create","update"] }
path "sys/leases/revoke" { capabilities = ["update"] }
path "sys/namespaces/vm-gha" { capabilities = ["create","update","read"] }
path "vm-gha/sys/mounts/secret" { capabilities = ["create","update","read","sudo"] }
path "vm-gha/secret/data/application/ui" { capabilities = ["create","update"] }
HCL
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
jq -n --arg repo "$REPO" '{role_type:"jwt",user_claim:"repository",bound_audiences:["vault-vm"],bound_claims:{repository:$repo,ref:"refs/heads/codex/vm-rhel9-poc"},token_policies:["vm-github-engine"],token_ttl:"10m",token_max_ttl:"15m"}' |
  curl -fsS -H "X-Vault-Token: $VAULT_TOKEN" -H 'Content-Type: application/json' --data @- "$VAULT_ADDR/v1/auth/vm-github/role/engine" >/dev/null

# Workflow completo y ejecución real en GitHub
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
# YAML completo del workflow, incluidas sus llamadas curl y kubectl.
cat > "$VM_ROOT/workflows/vault-k8s-engine-vso.yml" <<'WORKFLOW'
name: Vault RHEL9 engine
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
      ROLE: engine
      K8S_SERVER: https://6644A6BC129B47B8D55B137B76768774.gr7.eu-central-1.eks.amazonaws.com
      K8S_CA: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURNVENDQWhtZ0F3SUJBZ0lRUzFMWmdvbVZmV3REZmRBSHhhamNlekFOQmdrcWhraUc5dzBCQVFzRkFEQW4KTVJBd0RnWURWUVFLRXdkQlYxTWdSVXRUTVJNd0VRWURWUVFERXdwcmRXSmxjbTVsZEdWek1CNFhEVEkyTURreQpNekE1TWprd01Wb1hEVE14TURreU1qQTVNamt3TVZvd0p6RVFNQTRHQTFVRUNoTUhRVmRUSUVWTFV6RVRNQkVHCkExVUVBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUIKQUxXMXcrNTRvcmRMSEZMV1diOWFveUpXcC85alBwNWZua3gxK0kxa1g3Y1lkVXpyczFaQzdYdTdWaFdPYnlQYQowaDJNcUtaRWdTWmFseHlNNHdMcVlLcUxiSmN4d3AyQ080a2E2MDJ5ZzJac2ptR1NDUmJMWDVkb3dmTGxmQ3c1CnhrbkpNT3N5MnplOElKbWpBL3JQcmZMYi9IdFhqWEttalI4WjgzMDRtWlFWN0g4Nm1rOWdyVjBMTXNFV0ttQVoKZDFkWGZqbDNHQUp4TXJ5Mys4Um1DMUR4Rno1WHZFOWhkSzdSdkxUcEdTQlNqQ0lnRHlrZCsxSDFrRHF0WlphRgpQa1pQY0k2d28rK05wcVZkZDQ5NjBmNXdpWks5aXlXdElCc3I1Y1RIVnRBbUdGM0V6RjF0TzMvU3RRak83SVhGCnEzVWNkdXd2ck40MTg4aElrSWIwdXowQ0F3RUFBYU5aTUZjd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWQKRXdFQi93UUZNQU1CQWY4d0hRWURWUjBPQkJZRUZHaHNMR0ptT3c2Wi84ckZCd1dxc0VZUnJzQlNNQlVHQTFVZApFUVFPTUF5Q0NtdDFZbVZ5Ym1WMFpYTXdEUVlKS29aSWh2Y05BUUVMQlFBRGdnRUJBRXBEWU9NV05xSk9hQ25KCnhQOGdWQmtodmgxRlhsU3I3MUdBd1FPVW81bzhjSE83cENrMHpyb05KeHpGNTdIVVdHY3IrTE96UW1LL2RoNEoKZVZGVVVXZlZFb1ZNY1VYSTk5NTVFZUxlaE5HNk9Cd2w3RFFodWVFV0wyNm54VWFhaUNFV2F3YWFNM1gzZ0xxUQpMRG8wb29zd0hkM2o1UTlJNW9BcVhWc0xPQmgyNDFKQUR6Rk9FcXhUQTM5djRZYzBEb3dKWUdGN2hFaG9ZdytWCml5TDJtWGV4MDlYdkI2ZUJYdzRaZFJROXBqbFhBeU1USHhwL2h1NWRDZmdSaVVmRm9xWjhuNTRvdkhLWjZPbFYKMHBrVFlIcU9QMlViRTYxZTVjWmd6S1BYVjIvSkVySHg1OG1IQUV3OHQ1Vy81cXlCNThlQmdtZkJ3MG83TmU2VApadk43cThjPQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
      APP_NS: vm-consumers
    steps:
    - name: Verify Vault on RHEL9
      shell: bash
      run: "set -euo pipefail\njwt=$(curl -fsS -H \"Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}\"\
        \ \"${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=vault-vm\" | jq -er .value)\n\
        login=$(jq -n --arg jwt \"$jwt\" --arg role \"$ROLE\" '{jwt:$jwt,role:$role}'\
        \ | curl -fsS -H 'Content-Type: application/json' -d @- \"$VAULT_ADDR/v1/auth/vm-github/login\"\
        )\ntoken=$(jq -er .auth.client_token <<<\"$login\")\necho \"::add-mask::$token\"\
        \ntrap 'curl -fsS -H \"X-Vault-Token: $token\" -X POST \"$VAULT_ADDR/v1/auth/token/revoke-self\"\
        \ >/dev/null' EXIT\ncurl -fsS -H \"X-Vault-Token: $token\" \"$VAULT_ADDR/v1/secret/data/gha/demo\"\
        \ | jq -e '.data.data.api_key | length > 0' >/dev/null\n\nstatus=$(curl -sS\
        \ -o /dev/null -w '%{http_code}' -H \"X-Vault-Token: $token\" \"$VAULT_ADDR/v1/sys/namespaces/vm-gha\"\
        )\nif [[ \"$status\" == 404 ]]; then curl -fsS -H \"X-Vault-Token: $token\"\
        \ -X POST \"$VAULT_ADDR/v1/sys/namespaces/vm-gha\" >/dev/null; elif [[ \"\
        $status\" != 200 ]]; then exit 1; fi\nstatus=$(curl -sS -o /dev/null -w '%{http_code}'\
        \ -H \"X-Vault-Token: $token\" -H 'X-Vault-Namespace: vm-gha' \"$VAULT_ADDR/v1/sys/mounts/secret\"\
        )\nif [[ \"$status\" == 400 || \"$status\" == 404 ]]; then\n printf '%s' '{\"\
        type\":\"kv\",\"options\":{\"version\":\"2\"}}' | curl -fsS -H \"X-Vault-Token:\
        \ $token\" -H 'X-Vault-Namespace: vm-gha' -H 'Content-Type: application/json'\
        \ -d @- \"$VAULT_ADDR/v1/sys/mounts/secret\" >/dev/null\nelif [[ \"$status\"\
        \ != 200 ]]; then exit 1; fi\njq -n --arg marker \"github-${GITHUB_RUN_ID}\"\
        \ '{data:{value:$marker}}' | curl -fsS -H \"X-Vault-Token: $token\" -H 'X-Vault-Namespace:\
        \ vm-gha' -H 'Content-Type: application/json' -d @- \"$VAULT_ADDR/v1/secret/data/application/ui\"\
        \ >/dev/null\ncreds=$(curl -fsS -H \"X-Vault-Token: $token\" -H 'Content-Type:\
        \ application/json' -d \"{\\\"kubernetes_namespace\\\":\\\"${APP_NS}\\\"}\"\
        \ \"$VAULT_ADDR/v1/kubernetes/creds/github\")\nk8s_token=$(jq -er .data.service_account_token\
        \ <<<\"$creds\")\necho \"::add-mask::$k8s_token\"\nprintf '%s' \"$K8S_CA\"\
        \ | base64 -d > \"$RUNNER_TEMP/ca.pem\"\nexport KUBECONFIG=\"$RUNNER_TEMP/kubeconfig\"\
        \nkubectl config set-cluster vm-demo --server=\"$K8S_SERVER\" --certificate-authority=\"\
        $RUNNER_TEMP/ca.pem\" --embed-certs=true >/dev/null\nkubectl config set-credentials\
        \ dynamic --token=\"$k8s_token\" >/dev/null\nkubectl config set-context vm-demo\
        \ --cluster=vm-demo --user=dynamic --namespace=\"$APP_NS\" >/dev/null\nkubectl\
        \ config use-context vm-demo >/dev/null\nkubectl auth can-i create configmaps\
        \ | grep -qx yes\nkubectl create configmap vm-gha-evidence --from-literal=run_id=\"\
        $GITHUB_RUN_ID\" --dry-run=client -o yaml | kubectl apply -f - >/dev/null\n\
        jq -n --arg marker \"github-${GITHUB_RUN_ID}\" '{data:{value:$marker}}' |\
        \ curl -fsS -H \"X-Vault-Token: $token\" -H 'Content-Type: application/json'\
        \ -d @- \"$VAULT_ADDR/v1/secret/data/vm/static\" >/dev/null\ncat <<EOF | kubectl\
        \ apply -f - >/dev/null\napiVersion: secrets.hashicorp.com/v1beta1\nkind:\
        \ VaultStaticSecret\nmetadata:\n  name: vm-gha-delivery\n  namespace: ${APP_NS}\n\
        spec:\n  vaultAuthRef: vm-vault\n  namespace: vm-gha\n  type: kv-v2\n  mount:\
        \ secret\n  path: application/ui\n  refreshAfter: 10s\n  destination:\n  \
        \  create: true\n    name: vm-gha-delivery\n  rolloutRestartTargets:\n   \
        \ - kind: Deployment\n      name: vm-gha-app\n---\napiVersion: apps/v1\nkind:\
        \ Deployment\nmetadata:\n  name: vm-gha-app\n  namespace: ${APP_NS}\nspec:\n\
        \  replicas: 1\n  selector:\n    matchLabels: {app: vm-gha-app}\n  template:\n\
        \    metadata:\n      labels: {app: vm-gha-app}\n    spec:\n      containers:\n\
        \        - name: app\n          image: busybox:1.37.0\n          command:\
        \ [sh, -c, 'sleep 86400']\n          readinessProbe:\n            exec:\n\
        \              command: [sh, -c, 'test -s /vault/value']\n          volumeMounts:\n\
        \            - {name: secret, mountPath: /vault, readOnly: true}\n      volumes:\n\
        \        - name: secret\n          secret: {secretName: vm-gha-delivery}\n\
        EOF\nkubectl rollout status deployment/vm-gha-app --timeout=300s\njq '{lease_id:.lease_id}'\
        \ <<<\"$creds\" | curl -fsS -H \"X-Vault-Token: $token\" -H 'Content-Type:\
        \ application/json' -d @- \"$VAULT_ADDR/v1/sys/leases/revoke\" >/dev/null\n\
        echo \"VM workflow assertions passed\"\n"
WORKFLOW

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
BRANCH=codex/vm-rhel9-poc
if ! gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  DEFAULT=$(gh api "repos/$REPO" --jq .default_branch)
  SHA=$(gh api "repos/$REPO/git/ref/heads/$DEFAULT" --jq .object.sha)
  jq -n --arg ref "refs/heads/$BRANCH" --arg sha "$SHA" '{ref:$ref,sha:$sha}' | gh api "repos/$REPO/git/refs" -X POST --input - >/dev/null
fi
FILE=vault-k8s-engine-vso.yml
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
jq --arg repo "$REPO" '{id:.id,url:.html_url,repo:$repo}' "$STATE/github-run.json" > "$STATE/github-engine.json"
jq -r .html_url "$STATE/github-run.json"

for name in vm-static vm-gha-delivery; do
  for attempt in $(seq 1 60); do
    actual=$("${KUBECTL[@]}" -n vm-consumers get secret "$name" -o json | jq -r '.data.value | @base64d')
    [[ "$actual" == "github-$ID" ]] && break
    sleep 3
  done
  [[ "$actual" == "github-$ID" ]]
done
