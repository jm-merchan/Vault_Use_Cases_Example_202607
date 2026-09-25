#!/usr/bin/env bash
# Ejecutar desde vm-rhel9/notebooks

# Entorno y sesión AWS
set -euo pipefail
source ../scripts/notebook-env.sh
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

# Política, token, configuración y deployments
set -euo pipefail
source ../scripts/notebook-env.sh
"${KUBECTL[@]}" create namespace vm-monitoring --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

vault policy write vm-metrics - <<'HCL'
path "sys/metrics" { capabilities = ["read"] }
HCL
vault token create -policy=vm-metrics -ttl=24h -orphan -format=json | jq -jr .auth.client_token > "$STATE/metrics-token"
"${KUBECTL[@]}" -n vm-monitoring create secret generic vault-metrics --from-file=token="$STATE/metrics-token" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat > "$STATE/prometheus.yml" <<'YAML'
global:
  scrape_interval: 10s
scrape_configs:
  - job_name: vault-vm
    metrics_path: /v1/sys/metrics
    params:
      format: [prometheus]
    scheme: https
    bearer_token_file: /credentials/token
    static_configs:
      - targets:
YAML
while read -r ip; do printf '          - "%s:8200"\n' "$ip" >> "$STATE/prometheus.yml"; done < <(jq -r '.nodes[] | select(.cluster=="primary") | .internal_fqdn' "$STATE/infrastructure.json")
"${KUBECTL[@]}" -n vm-monitoring create configmap prometheus --from-file=prometheus.yml="$STATE/prometheus.yml" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
[[ -s "$STATE/grafana-password" ]] || openssl rand -hex 20 | tr -d '\n' > "$STATE/grafana-password"
"${KUBECTL[@]}" -n vm-monitoring create secret generic grafana --from-file=password="$STATE/grafana-password" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat > "$STATE/datasource.yaml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
    access: proxy
YAML
cat > "$STATE/dashboard.yaml" <<'YAML'
apiVersion: 1
providers:
  - name: Vault
    type: file
    options:
      path: /dashboards
YAML
"${KUBECTL[@]}" -n vm-monitoring create configmap grafana --from-file=datasource.yaml="$STATE/datasource.yaml" \
  --from-file=dashboard.yaml="$STATE/dashboard.yaml" --from-file=vault.json="$VM_ROOT/assets/vault-dashboard.json" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: vm-monitoring
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: vm-prometheus
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: vm-prometheus
    spec:
      containers:
      - image: prom/prometheus:v3.5.0
        imagePullPolicy: IfNotPresent
        name: prometheus
        ports:
        - containerPort: 9090
          protocol: TCP
        resources:
          limits:
            cpu: '1'
            memory: 1Gi
          requests:
            cpu: 100m
            memory: 128Mi
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /etc/prometheus
          name: config
        - mountPath: /credentials
          name: credentials
          readOnly: true
        readinessProbe:
          httpGet:
            path: /-/ready
            port: 9090
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 24
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - configMap:
          defaultMode: 420
          name: prometheus
        name: config
      - name: credentials
        secret:
          defaultMode: 420
          secretName: vault-metrics
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: vm-monitoring
  annotations: {}
spec:
  internalTrafficPolicy: Cluster
  ports:
  - port: 9090
    protocol: TCP
    targetPort: 9090
  selector:
    app: vm-prometheus
  sessionAffinity: None
  type: ClusterIP
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: vm-monitoring
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: vm-grafana
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: vm-grafana
    spec:
      containers:
      - env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              key: password
              name: grafana
        image: grafana/grafana:12.1.1
        imagePullPolicy: IfNotPresent
        name: grafana
        ports:
        - containerPort: 3000
          protocol: TCP
        resources:
          limits:
            cpu: '1'
            memory: 1Gi
          requests:
            cpu: 100m
            memory: 128Mi
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /etc/grafana/provisioning/datasources/datasource.yaml
          name: config
          subPath: datasource.yaml
        - mountPath: /etc/grafana/provisioning/dashboards/dashboard.yaml
          name: config
          subPath: dashboard.yaml
        - mountPath: /dashboards/vault.json
          name: config
          subPath: vault.json
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 24
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
      volumes:
      - configMap:
          defaultMode: 420
          name: grafana
        name: config
EOF
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: vm-monitoring
  annotations: {}
spec:
  internalTrafficPolicy: Cluster
  ports:
  - port: 3000
    protocol: TCP
    targetPort: 3000
  selector:
    app: vm-grafana
  sessionAffinity: None
  type: ClusterIP
EOF

for name in prometheus grafana; do
  # Restart on configuration changes, including Grafana subPath mounts.
  hash=$("${KUBECTL[@]}" -n vm-monitoring get configmap "$name" -o json | jq -Sc .data | openssl dgst -sha256 | awk '{print $NF}')
  "${KUBECTL[@]}" -n vm-monitoring patch deployment "$name" --type=merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"vm-demo/config-sha\":\"$hash\"}}}}}"
  "${KUBECTL[@]}" -n vm-monitoring rollout status deployment/"$name" --timeout=300s
done

# Comprobar seis targets, métricas y dashboard
set -euo pipefail
source ../scripts/notebook-env.sh
"${KUBECTL[@]}" -n vm-monitoring port-forward svc/prometheus 19090:9090 > "$STATE/prometheus-forward.log" 2>&1 & PROM_PID=$!
"${KUBECTL[@]}" -n vm-monitoring port-forward svc/grafana 13000:3000 > "$STATE/grafana-forward.log" 2>&1 & GRAF_PID=$!
trap 'kill "$PROM_PID" "$GRAF_PID" 2>/dev/null || true; wait "$PROM_PID" "$GRAF_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 90); do
  curl -fsS http://127.0.0.1:19090/api/v1/targets | jq -e '.data.activeTargets | length==6 and all(.[]; .health=="up")' >/dev/null && break
  sleep 3
done
curl -fsS http://127.0.0.1:19090/api/v1/targets | jq -e '.data.activeTargets | length==6 and all(.[]; .health=="up")'
curl -fsSG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=count({job="vault-vm",__name__=~"vault_.+"})' | jq -e '.data.result[0].value[1] | tonumber > 0'
for attempt in $(seq 1 60); do
  curl -fsS -u "admin:$(cat "$STATE/grafana-password")" http://127.0.0.1:13000/api/search > "$STATE/grafana-search.json" && jq -e 'length>0' "$STATE/grafana-search.json" >/dev/null && break
  sleep 3
done
UID_GRAFANA=$(jq -r '.[0].uid' "$STATE/grafana-search.json")
curl -fsS -u "admin:$(cat "$STATE/grafana-password")" "http://127.0.0.1:13000/api/dashboards/uid/$UID_GRAFANA" > "$STATE/grafana-dashboard.json"
jq -e --slurpfile expected "$VM_ROOT/assets/vault-dashboard.json" '.dashboard.title==$expected[0].title and (.dashboard | tostring | contains("vault-vm"))' "$STATE/grafana-dashboard.json"
curl -fsS -u "admin:$(cat "$STATE/grafana-password")" http://127.0.0.1:13000/api/datasources/uid/Prometheus/health | jq -e '.status=="OK"'
