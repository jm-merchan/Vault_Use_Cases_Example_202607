"""Shared VM notebook operations. Secrets never go into notebook output."""
from __future__ import annotations
import base64, datetime, ipaddress, json, os, pathlib, secrets, shlex, subprocess, time
import requests
from dotenv import dotenv_values
ROOT = pathlib.Path(__file__).resolve().parents[1]
STATE = ROOT / '.state'
STATE.mkdir(mode=0o700, exist_ok=True)
os.chmod(STATE, 0o700)

class Blocked(RuntimeError):
    """A missing external prerequisite, never a successful test."""

def private(path, data):
    path = pathlib.Path(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(data if isinstance(data, str) else json.dumps(data, indent=2))
    return path

def run(args, data=None, env=None, timeout=600, check=True):
    p = subprocess.run(list(map(str,args)), input=data, text=True, capture_output=True,
                       env=os.environ | (env or {}), timeout=timeout)
    if check and p.returncode:
        # Do not echo command arguments or stdout: they can contain credentials.
        detail = p.stderr[-1800:]
        for key, value in os.environ.items():
            if any(w in key for w in ('TOKEN','PASSWORD','SECRET','KEY')) and len(value)>8:
                detail = detail.replace(value, '[redacted]')
        raise RuntimeError(f'{pathlib.Path(str(args[0])).name} exited {p.returncode}: {detail}')
    return p.stdout if check else p

def aws_env():
    os.environ.setdefault('AWS_REGION', 'eu-central-1')
    os.environ['AWS_DEFAULT_REGION'] = os.environ['AWS_REGION']
    for attempt in range(3):
        identity=run(['aws','sts','get-caller-identity','--output','json'],check=False,timeout=30)
        if identity.returncode==0 and identity.stdout.strip():
            return json.loads(identity.stdout)
        account=os.getenv('DOORMAT_AWS_ACCOUNT','aws_jose.merchan_test')
        if attempt:
            run(['doormat','login','-f'],timeout=120)
        response=run(['doormat','aws','-a',account,'export'],timeout=90,check=False)
        if response.returncode:
            time.sleep(2)
            continue
        exported=response.stdout
        if not exported.strip(): continue
        # Parse exports without placing credentials in a subprocess command line.
        for line in exported.splitlines():
            for assignment in shlex.split(line):
                if assignment.startswith('AWS_') and '=' in assignment:
                    key,value=assignment.split('=',1)
                    os.environ[key]=value.rstrip(';')
    raise Blocked('AWS STS rejected credentials after refreshing Doormat')

def config():
    for k,v in dotenv_values(ROOT/'.env').items():
        if v is not None: os.environ[k]=v
    os.environ.setdefault('KUBE_CONTEXT','arn:aws:eks:eu-central-1:492487827579:cluster/eks-infra-dev')
    return os.environ

def outputs():
    p=STATE/'infrastructure.json'
    if not p.exists(): raise Blocked('Run deployment notebook first: missing VM inventory')
    return json.loads(p.read_text())

def ssh(node, script, timeout=600):
    n=outputs()['nodes'][node]
    return run(['ssh','-i',STATE/'id_ed25519','-o','StrictHostKeyChecking=accept-new',
                '-o',f'UserKnownHostsFile="{STATE}/known_hosts"','-o','ConnectTimeout=10',
                f'ec2-user@{n["public_ip"]}', 'sudo bash -se'], data='set -euo pipefail\numask 077\n'+script, timeout=timeout)

def put(node, path, data, owner='vault:vault', mode='600'):
    encoded=base64.b64encode(data.encode() if isinstance(data,str) else data).decode()
    return ssh(node, f"printf '%s' '{encoded}' | base64 -d > {shlex.quote(path)}\nchown {owner} {shlex.quote(path)}\nchmod {mode} {shlex.quote(path)}\n")

def kube(args, data=None, check=True, timeout=600):
    return run(['kubectl','--context',config()['KUBE_CONTEXT'], *args],data=data,check=check,timeout=timeout)

def apply(doc):
    kube(['apply','-f','-'],json.dumps(doc))

def ns(name='vm-demo'):
    apply({'apiVersion':'v1','kind':'Namespace','metadata':{'name':name,'labels':{'app.kubernetes.io/part-of':'vault-rhel9-poc'}}})

def secret(name, values, namespace='vm-demo'):
    ns(namespace)
    apply({'apiVersion':'v1','kind':'Secret','metadata':{'name':name,'namespace':namespace},'type':'Opaque',
           'stringData':values})

class Vault:
    def __init__(self, cluster='primary', token=None, namespace='', address=None):
        self.cluster=cluster;self.namespace=namespace
        info=outputs(); self.addr=address or (info.get('vault_application_address',info['vault_address']) if cluster=='primary' else 'https://'+info['nodes']['secondary-0']['public_ip']+':8200')
        # Direct diagnostic endpoints use certificate-covered node DNS names.
        for node in info['nodes'].values():
            for field, dns in [('public_ip','api_fqdn'),('private_ip','internal_fqdn')]:
                if node.get(dns): self.addr=self.addr.replace('https://'+node[field]+':8200','https://'+node[dns]+':8200')
        p=STATE/f'{cluster}-init.json'
        self.token=token if token is not None else (json.loads(p.read_text())['root_token'] if p.exists() else '')
        self.verify=True if self.addr in (info['vault_address'],info.get('vault_application_address')) else str(STATE/'ca.pem')
    def call(self, method, path, data=None, codes=(200,204), token=None):
        headers={'X-Vault-Token': self.token if token is None else token}
        if self.namespace: headers['X-Vault-Namespace']=self.namespace
        r=requests.request(method,self.addr+'/v1/'+path,headers=headers,json=data,verify=self.verify,timeout=45)
        if r.status_code not in codes:
            # Errors contain no request body. Avoid including generated credential values.
            try: err=r.json().get('errors',[])
            except ValueError: err=['non-JSON response']
            raise RuntimeError(f'Vault {method} {path}: HTTP {r.status_code}: {err}')
        return r.json() if r.content else {}
    def get(self,path,**kw): return self.call('GET',path,**kw)
    def post(self,path,data=None,**kw): return self.call('POST',path,data,**kw)
    def delete(self,path,**kw): return self.call('DELETE',path,**kw)
    def mount(self,path,kind='kv',options=None):
        if path+'/' not in self.get('sys/mounts')['data']:
            self.post('sys/mounts/'+path,{'type':kind,'options':options or ({'version':'2'} if kind=='kv' else {})})
    def auth(self,path,kind):
        if path+'/' not in self.get('sys/auth')['data']: self.post('sys/auth/'+path,{'type':kind})
    def policy(self,name,policy): self.post('sys/policies/acl/'+name,{'policy':policy})
    def cli_env(self):
        e={'VAULT_ADDR':self.addr,'VAULT_TOKEN':self.token,'VAULT_NAMESPACE':self.namespace,'VAULT_SKIP_VERIFY':'false'}
        # Public Let's Encrypt certificate uses system trust; explicit empty value clears inherited CA.
        e['VAULT_CACERT']='' if self.verify is True else self.verify
        e['VAULT_TLS_SERVER_NAME']=''
        return e

def wait_for(fn, timeout=300, interval=5):
    end=time.monotonic()+timeout; last=None
    while time.monotonic()<end:
        try:
            result=fn()
            if result: return result
        except Exception as e: last=e
        time.sleep(interval)
    raise RuntimeError(f'Timed out waiting for readiness; last error: {last}')

def terraform(directory, variables=None):
    aws_env()
    path=ROOT/'terraform'/directory
    if variables: private(path/'runtime.auto.tfvars.json',variables)
    run(['terraform',f'-chdir={path}','init','-input=false'],timeout=600)
    run(['terraform',f'-chdir={path}','validate'])
    if directory=='infrastructure':
        plan=STATE/'legacy-infrastructure.tfplan'
        run(['terraform',f'-chdir={path}','plan','-input=false','-out='+str(plan)],timeout=600)
        changes=json.loads(run(['terraform',f'-chdir={path}','show','-json',plan]))
        if any('delete' in change['change']['actions'] for change in changes.get('resource_changes',[])):
            raise RuntimeError('Infrastructure plan contains a deletion or replacement; no changes applied')
        run(['terraform',f'-chdir={path}','apply','-input=false',plan],timeout=1800)
    else:
        run(['terraform',f'-chdir={path}','apply','-input=false','-auto-approve'],env=Vault().cli_env(),timeout=1800)
    return {k:v['value'] for k,v in json.loads(run(['terraform',f'-chdir={path}','output','-json'])).items()}
