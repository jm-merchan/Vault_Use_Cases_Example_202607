from runtime import *
from contextlib import contextmanager
import socket,yaml,re,hashlib

@contextmanager
def forward(namespace,service,port):
    with socket.socket() as s:s.bind(('127.0.0.1',0));local=s.getsockname()[1]
    p=subprocess.Popen(['kubectl','--context',config()['KUBE_CONTEXT'],'-n',namespace,'port-forward','svc/'+service,f'{local}:{port}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        def ready():
            with socket.create_connection(('127.0.0.1',local),timeout=1):return True
        wait_for(ready,timeout=30,interval=1)
        yield f'http://127.0.0.1:{local}'
    finally:p.terminate();p.wait(timeout=10)

def monitor():
    aws_env();ns('vm-monitoring');v=Vault()
    v.policy('vm-metrics','path "sys/metrics" { capabilities = ["read"] }')
    token=v.post('auth/token/create',{'policies':['vm-metrics'],'ttl':'24h','no_parent':True})['auth']['client_token']
    secret('vault-metrics',{'token':token},'vm-monitoring')
    conf={'global':{'scrape_interval':'10s'},'scrape_configs':[{'job_name':'vault-vm','metrics_path':'/v1/sys/metrics','params':{'format':['prometheus']},'scheme':'https','bearer_token_file':'/credentials/token','static_configs':[{'targets':[n['internal_fqdn']+':8200' for n in outputs()['nodes'].values() if n['cluster']=='primary']}]}]}
    apply({'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'prometheus','namespace':'vm-monitoring'},'data':{'prometheus.yml':yaml.safe_dump(conf)}})
    def deployment(name,image,port,mounts,volumes,args=None,env=None):
        container={'name':name,'image':image,'ports':[{'containerPort':port}],'volumeMounts':mounts,'resources':{'requests':{'cpu':'100m','memory':'128Mi'},'limits':{'cpu':'1','memory':'1Gi'}}}
        if args:container['args']=args
        if env:container['env']=env
        config_data=kube(['-n','vm-monitoring','get','configmap',name,'-o','json'])
        revision=hashlib.sha256(json.dumps(json.loads(config_data)['data'],sort_keys=True).encode()).hexdigest()
        apply({'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':name,'namespace':'vm-monitoring'},'spec':{'replicas':1,'selector':{'matchLabels':{'app':'vm-'+name}},'template':{'metadata':{'labels':{'app':'vm-'+name},'annotations':{'vm-demo/config-sha':revision}},'spec':{'containers':[container],'volumes':volumes}}}})
        apply({'apiVersion':'v1','kind':'Service','metadata':{'name':name,'namespace':'vm-monitoring'},'spec':{'selector':{'app':'vm-'+name},'ports':[{'port':port}]}})
        kube(['-n','vm-monitoring','rollout','status','deployment/'+name,'--timeout=300s'])
    deployment('prometheus','prom/prometheus:v3.5.0',9090,[{'name':'config','mountPath':'/etc/prometheus'},{'name':'credentials','mountPath':'/credentials','readOnly':True}],[{'name':'config','configMap':{'name':'prometheus'}},{'name':'credentials','secret':{'secretName':'vault-metrics'}}])
    from services import password
    secret('grafana',{'password':password('grafana')},'vm-monitoring')
    dashboard=json.loads((ROOT/'assets/vault-dashboard.json').read_text())
    datasource={'apiVersion':1,'datasources':[{'name':'Prometheus','uid':'Prometheus','type':'prometheus','url':'http://prometheus:9090','isDefault':True,'access':'proxy'}]}
    provider={'apiVersion':1,'providers':[{'name':'Vault','type':'file','options':{'path':'/dashboards'}}]}
    apply({'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'grafana','namespace':'vm-monitoring'},'data':{'datasource.yaml':yaml.safe_dump(datasource),'dashboard.yaml':yaml.safe_dump(provider),'vault.json':json.dumps(dashboard)}})
    deployment('grafana','grafana/grafana:12.1.1',3000,[{'name':'config','mountPath':'/etc/grafana/provisioning/datasources/datasource.yaml','subPath':'datasource.yaml'},{'name':'config','mountPath':'/etc/grafana/provisioning/dashboards/dashboard.yaml','subPath':'dashboard.yaml'},{'name':'config','mountPath':'/dashboards/vault.json','subPath':'vault.json'}],[{'name':'config','configMap':{'name':'grafana'}}],env=[{'name':'GF_SECURITY_ADMIN_PASSWORD','valueFrom':{'secretKeyRef':{'name':'grafana','key':'password'}}}])
    print('Prometheus and Grafana deployed; six VM targets configured with verified TLS')

def verify_monitor():
    with forward('vm-monitoring','prometheus',9090) as addr:
        def healthy():
            d=requests.get(addr+'/api/v1/targets',timeout=10).json()['data']['activeTargets']
            return len(d)==6 and all(t['health']=='up' for t in d)
        wait_for(healthy,timeout=180)
        result=requests.get(addr+'/api/v1/query',params={'query':'up{job="vault-vm"}'},timeout=10).json()['data']['result']
        assert len(result)==6 and all(x['value'][1]=='1' for x in result)
        samples=requests.get(addr+'/api/v1/query',params={'query':'count({job="vault-vm",__name__=~"vault_.+"})'},timeout=15).json()['data']['result']
        assert samples and float(samples[0]['value'][1])>0
    from services import password
    with forward('vm-monitoring','grafana',3000) as addr:
        def dashboards_ready():
            r=requests.get(addr+'/api/search',auth=('admin',password('grafana')),timeout=15)
            r.raise_for_status()
            return bool(r.json())
        wait_for(dashboards_ready,timeout=180)
        entries=requests.get(addr+'/api/search',auth=('admin',password('grafana')),timeout=15).json()
        dashboard=requests.get(addr+'/api/dashboards/uid/'+entries[0]['uid'],auth=('admin',password('grafana')),timeout=15).json()['dashboard']
        assert dashboard['title']==json.loads((ROOT/'assets/vault-dashboard.json').read_text())['title']
        assert 'vault-vm' in json.dumps(dashboard)
        r=requests.get(addr+'/api/datasources/uid/Prometheus/health',auth=('admin',password('grafana')),timeout=20)
        r.raise_for_status(); assert r.json().get('status','').lower()=='ok'
    print('Prometheus: all six VM targets up; Grafana dashboard provisioned and API accessible')

def benchmark():
    aws_env();ns('vm-benchmark');v=Vault()
    # Reuse source policy and HCL schema; cluster target is now the VM application NLB.
    policy=(ROOT/'assets/benchmark-policy.hcl').read_text()
    v.policy('vm-benchmark',policy)
    token=v.post('auth/token/create',{'policies':['vm-benchmark'],'ttl':'1h','no_parent':True})['auth']['client_token']
    secret('benchmark-token',{'token':token},'vm-benchmark')
    hcl='''vault_addr = ""
vault_token = ""
duration = "30s"
report_mode = "terse"
random_mounts = true
cleanup = true
test "approle_auth" "approle_logins" {
 weight = 50
 config {
  role { role_name = "benchmark-role" token_ttl = "2m" }
 }
}
test "kvv2_write" "static_secret_writes" {
 weight = 50
 config { numkvs = 100 kvsize = 256 }
}
'''.replace('role { role_name = "benchmark-role" token_ttl = "2m" }','role {\n role_name = "benchmark-role"\n token_ttl = "2m"\n }').replace('config { numkvs = 100 kvsize = 256 }','config {\n numkvs = 100\n kvsize = 256\n }')
    apply({'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'benchmark','namespace':'vm-benchmark'},'data':{'benchmark.hcl':hcl}})
    kube(['-n','vm-benchmark','delete','job','benchmark','--ignore-not-found=true'])
    apply({'apiVersion':'batch/v1','kind':'Job','metadata':{'name':'benchmark','namespace':'vm-benchmark'},'spec':{'backoffLimit':0,'template':{'spec':{'restartPolicy':'Never','automountServiceAccountToken':False,'containers':[{'name':'benchmark','image':'hashicorp/vault-benchmark:0.3.0','command':['vault-benchmark'],'args':['run','-config=/config/benchmark.hcl','-rps=50','-workers=5'],'env':[{'name':'VAULT_ADDR','value':v.addr},{'name':'VAULT_TOKEN','valueFrom':{'secretKeyRef':{'name':'benchmark-token','key':'token'}}}],'volumeMounts':[{'name':'config','mountPath':'/config'}],'resources':{'requests':{'cpu':'100m','memory':'128Mi'},'limits':{'cpu':'1','memory':'512Mi'}}}],'volumes':[{'name':'config','configMap':{'name':'benchmark'}}]}}}})
    try:
        kube(['-n','vm-benchmark','wait','--for=condition=complete','job/benchmark','--timeout=300s'])
        logs=kube(['-n','vm-benchmark','logs','job/benchmark'])
        private(STATE/'benchmark.log',logs)
        assert 'approle_logins' in logs and 'static_secret_writes' in logs
        rows=[line.split() for line in logs.splitlines() if line.strip().startswith(('approle_logins','static_secret_writes'))]
        assert len(rows)==2 and {r[0] for r in rows}=={'approle_logins','static_secret_writes'}
        assert all(int(r[1])>0 and r[-1].endswith('%') and float(r[-1][:-1])==100 for r in rows),'Missing or unsuccessful benchmark ratios; inspect private log'
        (ROOT/'reports/benchmark.json').write_text(json.dumps([{'operation':r[0],'count':int(r[1]),'rate':float(r[2]),'throughput':float(r[3]),'mean':r[4],'p95':r[5],'p99':r[6],'success_ratio':r[-1]} for r in rows],indent=2)+'\n')
        print('AppRole and KV benchmark passed at 50 RPS / 5 workers for 30 s; both success ratios 100%')
    finally:v.post('auth/token/revoke',{'token':token})
