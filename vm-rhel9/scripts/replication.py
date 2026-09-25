from runtime import *

def ensure_secondary():
    # PR changes the barrier keys. Auto-unseal standbys must restart afterwards:
    # https://developer.hashicorp.com/vault/docs/concepts/seal
    states=[]
    for name,node in outputs()['nodes'].items():
        if node['cluster']!='secondary':continue
        client=Vault('secondary',address='https://'+node['public_ip']+':8200')
        health=client.get('sys/health',codes=(200,429,472,473,503))
        if health['sealed']:ssh(name,'systemctl restart vault\n')
        def ready():
            h=client.get('sys/health',codes=(200,429,472,473,503))
            return h if not h['sealed'] and h.get('replication_performance_mode')=='secondary' else None
        states.append(wait_for(ready,timeout=180))
    assert len(states)==3 and len({h['cluster_id'] for h in states})==1
    print('All three secondary nodes are unsealed in the same replication cluster')

def enable():
    primary=Vault();secondary=Vault('secondary')
    if primary.get('sys/replication/status')['data'].get('performance',{}).get('mode')!='primary':
        primary.post('sys/replication/performance/primary/enable',{'primary_cluster_addr':outputs()['vault_address']+':8201'})
    status=secondary.get('sys/replication/status')['data'].get('performance',{})
    if status.get('mode')!='secondary':
        token=primary.post('sys/replication/performance/primary/secondary-token',{'id':'rhel9-secondary'})['wrap_info']['token']
        # Both bootstrap API and the advertised PR address use the primary NLB.
        private_addr=outputs()['vault_address']
        secondary.post('sys/replication/performance/secondary/enable',{'token':token,'primary_api_addr':private_addr,'ca_file':'/etc/vault.d/tls/ca.pem'})
    wait_for(lambda:secondary.get('sys/replication/status')['data']['performance'].get('state')=='stream-wals',timeout=300)
    ensure_secondary()
    print('Performance Replication enabled; secondary is streaming WALs')

def verify():
    v=Vault();v.mount('pr-check')
    policy='path "pr-check/data/*" { capabilities = ["read"] }'
    v.policy('pr-reader',policy);v.auth('pr-userpass','userpass')
    password=secrets.token_hex(16)
    v.post('auth/pr-userpass/users/reader',{'password':password,'token_policies':['pr-reader']})
    s=Vault('secondary',token='')
    def login():return s.post('auth/pr-userpass/login/reader',{'password':password})['auth']['client_token']
    token=wait_for(login,timeout=180);s.token=token
    timings=[]
    for i in range(5):
        marker=secrets.token_hex(12);start=time.monotonic()
        v.post('pr-check/data/probe',{'data':{'value':marker}})
        wait_for(lambda:s.get('pr-check/data/probe')['data']['data']['value']==marker,timeout=120,interval=0.2)
        timings.append(round((time.monotonic()-start)*1000,1))
    private(STATE/'replication-latency.json',{'milliseconds':timings})
    s.post('auth/token/revoke-self')
    print('Secondary authenticated with replicated user; five values matched. Latency ms:',timings)

def audit():
    v=Vault();v.mount('audit-check');marker=secrets.token_hex(8)
    v.post('audit-check/data/'+marker,{'data':{'test':True}})
    # Find active node without making assumptions about elections.
    leader=None
    for name,n in outputs()['nodes'].items():
        if n['cluster']=='primary':
            health=Vault(address='https://'+n['public_ip']+':8200').get('sys/health',codes=(200,429,473))
            if not health['standby']:leader=name;break
    assert leader
    ssh(leader,f"test -s /var/log/vault/audit.json\ngrep -q 'audit-check/data/{marker}' /var/log/vault/audit.json\nlogrotate -f /etc/logrotate.d/vault\ntest -s /var/log/vault/audit.json.1\n")
    marker2=secrets.token_hex(8);v.post('audit-check/data/'+marker2,{'data':{'test':True}})
    ssh(leader,f"grep -q 'audit-check/data/{marker2}' /var/log/vault/audit.json\ntest \"$(stat -c '%U:%G %a' /var/log/vault/audit.json)\" = 'vault:vault 640'\nsystemctl is-active --quiet vault\n")
    print('Audit request found, logrotate completed, Vault reopened file after SIGHUP; owner/mode verified')
