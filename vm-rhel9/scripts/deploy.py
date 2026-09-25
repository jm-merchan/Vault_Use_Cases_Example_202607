from runtime import *

def discover():
    config(); identity=aws_env()
    region=os.environ['AWS_REGION']
    eks=json.loads(run(['aws','eks','describe-cluster','--name',os.getenv('EKS_CLUSTER_NAME','eks-infra-dev'),'--region',region]))['cluster']
    vpc=eks['resourcesVpcConfig']['vpcId']
    subnets=json.loads(run(['aws','ec2','describe-subnets','--filters',f'Name=vpc-id,Values={vpc}']))['Subnets']
    routes=json.loads(run(['aws','ec2','describe-route-tables','--filters',f'Name=vpc-id,Values={vpc}']))['RouteTables']
    public={a['SubnetId'] for rt in routes if any(r.get('GatewayId','').startswith('igw-') for r in rt['Routes']) for a in rt['Associations'] if 'SubnetId' in a}
    chosen={s['AvailabilityZone']:s['SubnetId'] for s in subnets if s['SubnetId'] in public}
    if len(chosen)<3: raise Blocked('Need three public subnets with IGW routing, or adapt transport to SSM/bastion')
    if not (STATE/'id_ed25519').exists(): run(['ssh-keygen','-t','ed25519','-N','','-f',STATE/'id_ed25519'])
    ip=requests.get('https://checkip.amazonaws.com',timeout=20).text.strip(); ipaddress.ip_address(ip)
    parent=dotenv_values(ROOT.parent/'.env')
    from urllib.parse import urlparse
    oldhost=urlparse(parent.get('VAULT_ADDR','')).hostname or ''
    zones=json.loads(run(['aws','route53','list-hosted-zones']))['HostedZones']
    zone=next(z for z in zones if oldhost.endswith(z['Name'].rstrip('.')) and not z['Config']['PrivateZone'])
    variables={'eks_security_group_id':eks['resourcesVpcConfig']['clusterSecurityGroupId'],'vpc_id':vpc,'region':region,'subnet_ids':list(chosen.values())[:3],
        'admin_cidr':ip+'/32','public_key':(STATE/'id_ed25519.pub').read_text(),
        'zone_id':zone['Id'].split('/')[-1],'domain':'vault-vm.'+zone['Name'].rstrip('.')}
    existing=STATE/'deployment-input.json'
    if existing.exists():
        # Preserve node placement on repeat runs; subnet ordering is not discovery metadata.
        previous=json.loads(existing.read_text())
        variables['subnet_ids']=previous['subnet_ids']
        variables['zone_id']=previous['zone_id']
        variables['domain']=previous['domain']
    private(STATE/'deployment-input.json',variables)
    print('AWS identity, EKS VPC, three public subnets and DNS zone verified.')

def provision():
    result=terraform('infrastructure',json.loads((STATE/'deployment-input.json').read_text()))
    private(STATE/'infrastructure.json',result)
    print('Provisioned',len(result['nodes']),'RHEL 9 VMs. Public endpoint:',result['vault_address'])

def certificates():
    # Legacy entrypoint; operational commands remain visible in the Bash script and notebook.
    print(run(["bash", ROOT/"load-balancing/issue-public-certificate.sh"]))

def configure(cluster='primary'):
    info=outputs(); license_file=pathlib.Path(os.getenv('VAULT_LICENSE_FILE',str(ROOT.parent/'vault.hclic')))
    if not license_file.is_file(): raise Blocked('Missing Enterprise license file')
    for name,n in info['nodes'].items():
        if n['cluster']!=cluster:continue
        wait_for(lambda: ssh(name,'test -f /var/lib/vault/rhel9-ready && echo ready',30).strip()=='ready',timeout=900)
        for src,dest in [('ca.pem','ca.pem'),(name+'.pem','server.pem'),(name+'.key','server.key')]: put(name,'/etc/vault.d/tls/'+dest,(STATE/src).read_text())
        put(name,'/etc/vault.d/vault.hclic',license_file.read_text())
        joins='\n'.join('retry_join {\n leader_api_addr = "https://'+p['internal_fqdn']+':8200"\n leader_ca_cert_file = "/etc/vault.d/tls/ca.pem"\n}' for k,p in info['nodes'].items() if p['cluster']==cluster and k!=name)
        hcl=f'''ui = true
api_addr = "https://{n['internal_fqdn']}:8200"
cluster_addr = "https://{n['private_ip']}:8201"
disable_mlock = true
enable_response_header_hostname     = true
enable_response_header_raft_node_id = true
plugin_directory = "/opt/vault/plugins"
listener "tcp" {{
 address = "0.0.0.0:8200"
 cluster_address = "0.0.0.0:8201"
 tls_cert_file = "/etc/vault.d/tls/server.pem"
 tls_key_file = "/etc/vault.d/tls/server.key"
}}
seal "awskms" {{
 region = "{os.environ.get('AWS_REGION','eu-central-1')}"
 kms_key_id = "{info['kms_key_id']}"
}}
storage "raft" {{
 path = "/var/lib/vault"
 node_id = "{name}"
 autopilot_redundancy_zone = "{n['zone']}"
 {joins}
}}
telemetry {{
 prometheus_retention_time = "12h"
 disable_hostname = true
}}
'''
        put(name,'/etc/vault.d/vault.hcl',hcl)
        ssh(name,'systemctl enable --now vault\nsystemctl reload vault\n')
        print(name,'configured; systemd enabled')

def initialize(cluster='primary'):
    info=outputs(); addr='https://'+info['nodes'][cluster+'-0']['public_ip']+':8200'
    v=Vault(cluster,address=addr)
    health=wait_for(lambda:v.get('sys/health',codes=(200,429,472,473,501,503)),timeout=180)
    if not health['initialized']:
        result=v.post('sys/init',{'recovery_shares':1,'recovery_threshold':1})
        private(STATE/f'{cluster}-init.json',result)
    elif not (STATE/f'{cluster}-init.json').exists(): raise Blocked('Already initialized but bootstrap token unavailable; do not reinitialize')
    if cluster=='secondary' and health.get('replication_performance_mode')=='secondary':
        from replication import ensure_secondary
        ensure_secondary()
        print('Secondary already replicating; bootstrap root token is intentionally obsolete')
        return
    v=Vault(cluster,address=addr)
    wait_for(lambda:not v.get('sys/health',codes=(200,429,472,473,503))['sealed'])
    wait_for(lambda:len(v.get('sys/storage/raft/configuration')['data']['config']['servers'])==(6 if cluster=='primary' else 3),timeout=300)
    if 'file/' not in v.get('sys/audit')['data']:
        v.post('sys/audit/file',{'type':'file','options':{'file_path':'/var/log/vault/audit.json','mode':'0640'}})
    if cluster=='primary': wait_for(lambda:Vault().get('sys/health')['initialized'],timeout=300)
    print(cluster,'initialized, unsealed, Raft membership and audit verified')

def verify(cluster='primary'):
    info=outputs(); report=[]
    for name,n in info['nodes'].items():
        if n['cluster']!=cluster:continue
        result=ssh(name,'. /etc/os-release\ntest "$ID" = rhel\n[[ "$VERSION_ID" == 9.* ]]\ntest "$(getenforce)" = Enforcing\nsystemctl is-active --quiet vault\necho "$PRETTY_NAME"\n')
        health=Vault(cluster,address='https://'+n['public_ip']+':8200').get('sys/health',codes=(200,429,472,473))
        assert not health['sealed'] and health['initialized']
        report.append({'node':name,'os':result.strip(),'version':health['version'],'sealed':False})
    private(STATE/f'{cluster}-verification.json',report)
    print(json.dumps(report,indent=2))

def failover():
    info=outputs();v=Vault();v.mount('ha-check')
    value=secrets.token_hex(12);v.post('ha-check/data/probe',{'data':{'value':value}})
    active=next(name for name,n in info['nodes'].items() if n['cluster']=='primary' and not Vault(address='https://'+n['public_ip']+':8200').get('sys/health',codes=(200,429,473))['standby'])
    try:
        ssh(active,'systemctl stop vault\n')
        wait_for(lambda:v.get('ha-check/data/probe')['data']['data']['value']==value,timeout=180)
        v.post('ha-check/data/after-failover',{'data':{'value':'write-after-election'}})
    finally:ssh(active,'systemctl start vault\n')
    wait_for(lambda:v.get('sys/storage/raft/autopilot/state')['data']['healthy'],timeout=300)
    assert len(v.get('sys/storage/raft/configuration')['data']['config']['servers'])==6
    print('Leader service stopped: new leader served the persisted secret and accepted a write; node rejoined unsealed and Autopilot is healthy')
