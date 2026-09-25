from runtime import *
import yaml
BRANCH='codex/vm-rhel9-poc'

def api(path,method='GET',payload=None):
    args=['gh','api','--hostname','github.com',path,'--method',method]
    if payload is not None:args+=['--input','-']
    raw=run(args,json.dumps(payload) if payload is not None else None,env={'NO_COLOR':'1','CLICOLOR':'0','CLICOLOR_FORCE':'0','FORCE_COLOR':'0','GH_FORCE_TTY':''})
    import re
    raw=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '',raw)
    raw=re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)', '',raw)
    if not raw.strip():
        raise RuntimeError('GitHub API returned an empty response for '+path)
    return json.loads(raw)

def repository():
    url=run(['git','remote','get-url','origin']).strip()
    if 'github.com' not in url:raise Blocked('GitHub remote required')
    return url.split('github.com')[-1].lstrip('/:').removesuffix('.git')

def configure(engine=False):
    repo=repository();v=Vault();v.auth('vm-github','jwt')
    v.post('auth/vm-github/config',{'oidc_discovery_url':'https://token.actions.githubusercontent.com','bound_issuer':'https://token.actions.githubusercontent.com'})
    v.mount('secret');v.post('secret/data/gha/demo',{'data':{'api_key':secrets.token_hex(16)}})
    policy='path "secret/data/gha/demo" { capabilities = ["read"] }'
    if engine:policy+='\npath "kubernetes/creds/github" { capabilities = ["update"] }\npath "secret/data/vm/static" { capabilities = ["create","update"] }\npath "sys/leases/revoke" { capabilities = ["update"] }'
    if engine:policy+='\npath "sys/namespaces/vm-gha" { capabilities = ["create","update","read"] }\npath "vm-gha/sys/mounts/secret" { capabilities = ["create","update","read","sudo"] }\npath "vm-gha/secret/data/application/ui" { capabilities = ["create","update"] }'
    role='engine' if engine else 'read'
    v.policy('vm-github-'+role,policy)
    v.post('auth/vm-github/role/'+role,{'role_type':'jwt','user_claim':'repository','bound_audiences':['vault-vm'],'bound_claims':{'repository':repo,'ref':'refs/heads/'+BRANCH},'token_policies':['vm-github-'+role],'token_ttl':'10m','token_max_ttl':'15m'})
    print('GitHub OIDC role constrained to repository and dedicated branch:',role)

def workflow(engine=False):
    repo=repository();role='engine' if engine else 'read';v=Vault()
    script='''set -euo pipefail
jwt=$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=vault-vm" | jq -er .value)
login=$(jq -n --arg jwt "$jwt" --arg role "$ROLE" '{jwt:$jwt,role:$role}' | curl -fsS -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/auth/vm-github/login")
token=$(jq -er .auth.client_token <<<"$login")
echo "::add-mask::$token"
trap 'curl -fsS -H "X-Vault-Token: $token" -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null' EXIT
curl -fsS -H "X-Vault-Token: $token" "$VAULT_ADDR/v1/secret/data/gha/demo" | jq -e '.data.data.api_key | length > 0' >/dev/null
'''
    env={'VAULT_ADDR':v.addr,'ROLE':role}
    if engine:
        from kubernetes import cluster_info,NS
        server,ca=cluster_info();env.update({'K8S_SERVER':server,'K8S_CA':base64.b64encode(ca.encode()).decode(),'APP_NS':NS})
        script+='''
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $token" "$VAULT_ADDR/v1/sys/namespaces/vm-gha")
if [[ "$status" == 404 ]]; then curl -fsS -H "X-Vault-Token: $token" -X POST "$VAULT_ADDR/v1/sys/namespaces/vm-gha" >/dev/null; elif [[ "$status" != 200 ]]; then exit 1; fi
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $token" -H 'X-Vault-Namespace: vm-gha' "$VAULT_ADDR/v1/sys/mounts/secret")
if [[ "$status" == 400 || "$status" == 404 ]]; then
 printf '%s' '{"type":"kv","options":{"version":"2"}}' | curl -fsS -H "X-Vault-Token: $token" -H 'X-Vault-Namespace: vm-gha' -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/sys/mounts/secret" >/dev/null
elif [[ "$status" != 200 ]]; then exit 1; fi
jq -n --arg marker "github-${GITHUB_RUN_ID}" '{data:{value:$marker}}' | curl -fsS -H "X-Vault-Token: $token" -H 'X-Vault-Namespace: vm-gha' -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/secret/data/application/ui" >/dev/null
'''
        script+='''creds=$(curl -fsS -H "X-Vault-Token: $token" -H 'Content-Type: application/json' -d "{\\"kubernetes_namespace\\":\\"${APP_NS}\\"}" "$VAULT_ADDR/v1/kubernetes/creds/github")
k8s_token=$(jq -er .data.service_account_token <<<"$creds")
echo "::add-mask::$k8s_token"
printf '%s' "$K8S_CA" | base64 -d > "$RUNNER_TEMP/ca.pem"
export KUBECONFIG="$RUNNER_TEMP/kubeconfig"
kubectl config set-cluster vm-demo --server="$K8S_SERVER" --certificate-authority="$RUNNER_TEMP/ca.pem" --embed-certs=true >/dev/null
kubectl config set-credentials dynamic --token="$k8s_token" >/dev/null
kubectl config set-context vm-demo --cluster=vm-demo --user=dynamic --namespace="$APP_NS" >/dev/null
kubectl config use-context vm-demo >/dev/null
kubectl auth can-i create configmaps | grep -qx yes
kubectl create configmap vm-gha-evidence --from-literal=run_id="$GITHUB_RUN_ID" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
jq -n --arg marker "github-${GITHUB_RUN_ID}" '{data:{value:$marker}}' | curl -fsS -H "X-Vault-Token: $token" -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/secret/data/vm/static" >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vm-gha-delivery
  namespace: ${APP_NS}
spec:
  vaultAuthRef: vm-vault
  namespace: vm-gha
  type: kv-v2
  mount: secret
  path: application/ui
  refreshAfter: 10s
  destination:
    create: true
    name: vm-gha-delivery
  rolloutRestartTargets:
    - kind: Deployment
      name: vm-gha-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vm-gha-app
  namespace: ${APP_NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: vm-gha-app}
  template:
    metadata:
      labels: {app: vm-gha-app}
    spec:
      containers:
        - name: app
          image: busybox:1.37.0
          command: [sh, -c, 'sleep 86400']
          readinessProbe:
            exec:
              command: [sh, -c, 'test -s /vault/value']
          volumeMounts:
            - {name: secret, mountPath: /vault, readOnly: true}
      volumes:
        - name: secret
          secret: {secretName: vm-gha-delivery}
EOF
kubectl rollout status deployment/vm-gha-app --timeout=300s
jq '{lease_id:.lease_id}' <<<"$creds" | curl -fsS -H "X-Vault-Token: $token" -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/sys/leases/revoke" >/dev/null
'''
    script+='echo "VM workflow assertions passed"\n'
    doc={'name':'Vault RHEL9 '+role,'on':{'workflow_dispatch':{}},'permissions':{'contents':'read','id-token':'write'},'jobs':{'verify':{'runs-on':'ubuntu-latest','env':env,'steps':[{'name':'Verify Vault on RHEL9','shell':'bash','run':script}]}}}
    name='vault-k8s-engine-vso.yml' if engine else 'vault-oidc.yml'
    (ROOT/'workflows').mkdir(exist_ok=True);(ROOT/'workflows'/name).write_text(yaml.safe_dump(doc,sort_keys=False))
    # Dedicated branch only. Existing default-branch workflow filename enables dispatch with --ref.
    details=api('repos/'+repo);sha=api('repos/'+repo+'/git/ref/heads/'+details['default_branch'])['object']['sha']
    try:api('repos/'+repo+'/git/ref/heads/'+BRANCH)
    except RuntimeError:api('repos/'+repo+'/git/refs','POST',{'ref':'refs/heads/'+BRANCH,'sha':sha})
    path='.github/workflows/'+name
    current=api('repos/'+repo+'/contents/'+path+'?ref='+BRANCH)
    content=(ROOT/'workflows'/name).read_bytes()
    if base64.b64decode(current['content'])!=content:
        api('repos/'+repo+'/contents/'+path,'PUT',{'message':'Add isolated RHEL9 VM '+role+' validation','branch':BRANCH,'sha':current['sha'],'content':base64.b64encode(content).decode()})
    before={x['id'] for x in api('repos/'+repo+'/actions/workflows/'+name+'/runs?branch='+BRANCH)['workflow_runs']}
    run(['gh','workflow','run',name,'--repo',repo,'--ref',BRANCH])
    def find():
        return next((x for x in api('repos/'+repo+'/actions/workflows/'+name+'/runs?branch='+BRANCH)['workflow_runs'] if x['id'] not in before),None)
    execution=wait_for(find,timeout=120)
    private(STATE/('github-'+role+'.json'),{'id':execution['id'],'url':execution['html_url'],'repo':repo})
    def done():
        r=api('repos/'+repo+'/actions/runs/'+str(execution['id']))
        return r if r['status']=='completed' else None
    result=wait_for(done,timeout=600)
    assert result['conclusion']=='success','GitHub workflow failed: '+result['html_url']
    if engine:
        expected='github-'+str(execution['id'])
        def synced():
            s=json.loads(kube(['-n','vm-consumers','get','secret','vm-static','-o','json']))
            other=json.loads(kube(['-n','vm-consumers','get','secret','vm-gha-delivery','-o','json']))
            return base64.b64decode(s['data']['value']).decode()==expected and base64.b64decode(other['data']['value']).decode()==expected
        wait_for(synced,timeout=180)
    print('GitHub workflow passed:',result['html_url'])
