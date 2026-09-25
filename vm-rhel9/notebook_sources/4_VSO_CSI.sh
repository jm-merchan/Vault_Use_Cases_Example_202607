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

# Instalar o reutilizar controladores
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

# Configurar Kubernetes auth con Vault CLI
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

# PostgreSQL auxiliar en Kubernetes
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

# Configurar Database Secrets Engine
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

# VaultConnection, VaultAuth, VSO y CSI
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

# Comprobar rotación y conexión SQL
set -euo pipefail
source ../scripts/notebook-env.sh
export VAULT_ADDR="${VAULT_APPLICATION_ADDR:?Deploy the application FQDN first}"
# VSO y CSI deben obtener la misma actualización KV.
marker="vm-$(openssl rand -hex 8)"
vault kv put secret/vm/static value="$marker" >/dev/null
for attempt in $(seq 1 90); do
  vso=$("${KUBECTL[@]}" -n vm-consumers get secret vm-static -o json | jq -r '.data.value | @base64d')
  csi=$("${KUBECTL[@]}" -n vm-consumers exec vm-secret-reader -- cat /csi/static)
  [[ "$vso" == "$marker" && "$csi" == "$marker" ]] && break
  sleep 5
done
[[ "$vso" == "$marker" && "$csi" == "$marker" ]]
for source in vso csi; do
  if [[ "$source" == vso ]]; then
    "${KUBECTL[@]}" -n vm-consumers get secret vm-dynamic -o json > "$STATE/vso-db.json"
    user=$(jq -r '.data.username | @base64d' "$STATE/vso-db.json")
    pass=$(jq -r '.data.password | @base64d' "$STATE/vso-db.json")
  else
    user=$("${KUBECTL[@]}" -n vm-consumers exec vm-secret-reader -- cat /csi/db-user)
    pass=$("${KUBECTL[@]}" -n vm-consumers exec vm-secret-reader -- cat /csi/db-password)
  fi
  printf 'export PGPASSWORD=%q\npsql -h postgres.vm-demo.svc.cluster.local -U %q -d postgres -Atc "select 1"\n' "$pass" "$user" |
    "${KUBECTL[@]}" -n vm-demo exec -i deployment/postgres -- sh -se | grep -qx 1
done
echo 'VSO/CSI: actualización KV y ambos logins SQL correctos'
