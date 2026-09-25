from runtime import *
NAMESPACE='vm-demo'

def deploy_service(name,image,port,env=None,storage=None,memory='256Mi',args=None):
    ns(); labels={'app':'vm-'+name}
    container={'name':name,'image':image,'ports':[{'containerPort':port}],
               'resources':{'requests':{'cpu':'100m','memory':memory},'limits':{'cpu':'2','memory': '3Gi' if name=='oracle' else '1Gi'}}}
    if env: container['env']=env
    if args: container['args']=args
    spec={'containers':[container],'enableServiceLinks':False}
    if storage:
        claim={'apiVersion':'v1','kind':'PersistentVolumeClaim','metadata':{'name':name+'-data','namespace':NAMESPACE},'spec':{'accessModes':['ReadWriteOnce'],'resources':{'requests':{'storage':storage[1]}}}}
        apply(claim)
        container['volumeMounts']=[{'name':'data','mountPath':storage[0]}]
        spec['volumes']=[{'name':'data','persistentVolumeClaim':{'claimName':name+'-data'}}]
    if name=='oracle':
        spec['nodeSelector']={'kubernetes.io/arch':'amd64'}
        spec['securityContext']={'fsGroup':54321}
        spec.setdefault('volumes',[]).append({'name':'dshm','emptyDir':{'medium':'Memory','sizeLimit':'1Gi'}})
        container.setdefault('volumeMounts',[]).append({'name':'dshm','mountPath':'/dev/shm'})
        probe={'exec':{'command':['/bin/bash','-c','/opt/oracle/checkDBStatus.sh']},'periodSeconds':15,'timeoutSeconds':10,'failureThreshold':120}
        container['startupProbe']=probe
        container['readinessProbe']={'tcpSocket':{'port':port},'periodSeconds':10}
    else: container['readinessProbe']={'tcpSocket':{'port':port},'periodSeconds':5}
    apply({'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':name,'namespace':NAMESPACE},'spec':{'replicas':1,'strategy':{'type':'Recreate'},'selector':{'matchLabels':labels},'template':{'metadata':{'labels':labels},'spec':spec}}})
    apply({'apiVersion':'v1','kind':'Service','metadata':{'name':name,'namespace':NAMESPACE,'annotations':{'service.beta.kubernetes.io/aws-load-balancer-type':'nlb','service.beta.kubernetes.io/aws-load-balancer-internal':'true'}},'spec':{'type':'LoadBalancer','selector':labels,'ports':[{'port':port,'targetPort':port}]}})
    kube(['-n',NAMESPACE,'rollout','status','deployment/'+name,'--timeout=1800s'],timeout=1850)
    def endpoint():
        d=json.loads(kube(['-n',NAMESPACE,'get','svc',name,'-o','json']))
        return (d.get('status',{}).get('loadBalancer',{}).get('ingress') or [{}])[0].get('hostname')
    host=wait_for(endpoint,timeout=600)
    private(STATE/(name+'-endpoint'),host)
    print(name,'ready in Kubernetes; internal endpoint recorded')
    return host

def password(name):
    p=STATE/(name+'-password')
    if not p.exists():private(p,'Vm9'+secrets.token_hex(16))
    return p.read_text()

def ref(name,key):return {'name':key,'valueFrom':{'secretKeyRef':{'name':name,'key':key}}}

def postgres():
    secret('postgres',{'POSTGRES_PASSWORD':password('postgres')})
    host=deploy_service('postgres','postgres:17.6',5432,[ref('postgres','POSTGRES_PASSWORD'),{'name':'PGDATA','value':'/var/lib/postgresql/data/pgdata'}],('/var/lib/postgresql/data','10Gi'))
    v=Vault(); v.mount('database','database')
    # Do not reset a root password already rotated and managed by Vault.
    if v.get('database/config/postgresql',codes=(200,404)).get('data') is None:
        wait_for(lambda:v.post('database/config/postgresql',{'plugin_name':'postgresql-database-plugin','allowed_roles':['readonly','agent-db'],
              'connection_url':f'postgresql://{{{{username}}}}:{{{{password}}}}@{host}:5432/postgres?sslmode=disable',
              'username':'postgres','password':password('postgres')}) or True,timeout=300)
    sql='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD \'{{password}}\' VALID UNTIL \'{{expiration}}\'; GRANT CONNECT ON DATABASE postgres TO "{{name}}"; GRANT USAGE ON SCHEMA public TO "{{name}}"; GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";'
    for role in ['readonly','agent-db']:v.post('database/roles/'+role,{'db_name':'postgresql','creation_statements':[sql],'default_ttl':'3m','max_ttl':'1h'})
    print('PostgreSQL dynamic roles configured')

def pg_login(creds):
    command='export PGPASSWORD='+shlex.quote(creds['password'])+'\npsql -h postgres.vm-demo.svc.cluster.local -U '+shlex.quote(creds['username'])+' -d postgres -Atc "select 1"\n'
    return kube(['-n',NAMESPACE,'exec','-i','deployment/postgres','--','sh','-se'],command,check=False)

def verify_postgres():
    v=Vault(); result=v.get('database/creds/readonly'); assert pg_login(result['data']).returncode==0
    v.post('sys/leases/revoke',{'lease_id':result['lease_id']})
    assert pg_login(result['data']).returncode!=0, 'Revoked SQL credential still works'
    v.post('database/rotate-root/postgresql')
    result=v.get('database/creds/readonly');assert pg_login(result['data']).returncode==0
    v.post('sys/leases/revoke',{'lease_id':result['lease_id']})
    print('PostgreSQL issuance, SQL login, revocation and root rotation passed')

def oracle_install():
    script='''
cd /var/tmp
test -s vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip || curl -fsSLO 'https://releases.hashicorp.com/vault-plugin-database-oracle/0.14.1+ent/vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip'
echo 'e14fc3474c6074b458d967098d448f357577fe77cc3c4b64401a4216b46ba372  vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip' | sha256sum -c -
install -d -o vault -g vault /opt/vault/plugins/vault-plugin-database-oracle_0.14.1+ent_linux_amd64
unzip -oq vault-plugin-database-oracle_0.14.1+ent_linux_amd64.zip -d /opt/vault/plugins/vault-plugin-database-oracle_0.14.1+ent_linux_amd64
test -s instantclient.zip || curl -fsSLo instantclient.zip 'https://download.oracle.com/otn_software/linux/instantclient/2326300/instantclient-basic-linux.x64-23.26.3.0.0.zip'
echo 'fce485361332927f8328ea4b68d98968c6b0ea124e62470de8c9d0cef880130e  instantclient.zip' | sha256sum -c -
mkdir -p /opt/oracle
unzip -oq instantclient.zip -d /opt/oracle
printf '%s\\n' /opt/oracle/instantclient_23_26 > /etc/ld.so.conf.d/oracle-instantclient.conf
ldconfig
chown -R root:vault /opt/vault/plugins /opt/oracle
chmod -R g+rX /opt/vault/plugins /opt/oracle
restorecon -RF /opt/vault/plugins /opt/oracle
'''
    # All primary and PR nodes need the same signed plugin and native libraries.
    from concurrent.futures import ThreadPoolExecutor
    names=[name for name,n in outputs()['nodes'].items() if n['cluster']!='app']
    with ThreadPoolExecutor(max_workers=3) as pool:
        for result in pool.map(lambda name: ssh(name,script,timeout=600),names): pass
    v=Vault();run(['vault','plugin','register','-version=v0.14.1+ent','-env=LD_LIBRARY_PATH=/opt/oracle/instantclient_23_26','-env=ORACLE_HOME=/opt/oracle/instantclient_23_26','database','vault-plugin-database-oracle'],env=v.cli_env())
    print('Signed Oracle plugin and Instant Client installed on all nine Vault VMs')

def oracle_sql(sql,login=None):
    connect='CONNECT '+login['username']+'/"'+login['password']+'"@//127.0.0.1:1521/FREEPDB1\n' if login else 'CONNECT / AS SYSDBA\nALTER SESSION SET CONTAINER=FREEPDB1;\n'
    script='sqlplus -L -s /nolog <<\'SQL\'\nWHENEVER SQLERROR EXIT FAILURE\n'+connect+sql+'\nEXIT\nSQL\n'
    return kube(['-n',NAMESPACE,'exec','-i','deployment/oracle','--','bash','-se'],script,check=False)

def oracle():
    secret('oracle',{'ORACLE_PWD':password('oracle')})
    host=deploy_service('oracle','container-registry.oracle.com/database/free:latest-lite',1521,[ref('oracle','ORACLE_PWD'),{'name':'ORACLE_PDB','value':'FREEPDB1'},{'name':'INIT_SGA_SIZE','value':'1024'},{'name':'INIT_PGA_SIZE','value':'256'}],('/opt/oracle/oradata','50Gi'),'2Gi')
    p=password('oracle-vault')
    sql=f'''DECLARE n NUMBER; BEGIN SELECT COUNT(*) INTO n FROM dba_users WHERE username='VAULT'; IF n=0 THEN EXECUTE IMMEDIATE 'CREATE USER VAULT IDENTIFIED BY "{p}"'; END IF; END;
/
GRANT CREATE USER, ALTER USER, DROP USER, CREATE SESSION TO VAULT WITH ADMIN OPTION;
GRANT CONNECT TO VAULT WITH ADMIN OPTION;
GRANT SELECT ON SYS.GV_$SESSION TO VAULT;
GRANT SELECT ON SYS.V_$SQL TO VAULT;
GRANT ALTER SYSTEM TO VAULT;
'''
    result=oracle_sql(sql);assert result.returncode==0,result.stdout[-500:]
    v=Vault();v.mount('database','database')
    wait_for(lambda:v.post('database/config/oracle',{'plugin_name':'vault-plugin-database-oracle','plugin_version':'v0.14.1+ent','allowed_roles':['oracle-dynamic','oracle-static'],'connection_url':'{{username}}/{{password}}@//'+host+':1521/FREEPDB1','username':'VAULT','password':p}) or True,timeout=300)
    v.post('database/roles/oracle-dynamic',{'db_name':'oracle','creation_statements':['CREATE USER {{username}} IDENTIFIED BY "{{password}}"; GRANT CONNECT TO {{username}}; GRANT CREATE SESSION TO {{username}};'],'default_ttl':'5m','max_ttl':'1h'})
    if not v.get('database/static-roles/oracle-static',codes=(200,404)).get('data'):
        r=oracle_sql(f'CREATE USER VAULT_STATIC IDENTIFIED BY "{password("oracle-static")}";\nGRANT CREATE SESSION TO VAULT_STATIC;');assert r.returncode==0
        v.post('database/static-roles/oracle-static',{'db_name':'oracle','username':'VAULT_STATIC','rotation_period':'24h'})
    print('Oracle dynamic and static roles configured')

def verify_oracle():
    v=Vault(); dynamic=v.get('database/creds/oracle-dynamic')
    assert oracle_sql("SELECT 'LOGIN_OK' FROM dual;",dynamic['data']).returncode==0
    v.post('sys/leases/revoke',{'lease_id':dynamic['lease_id']})
    assert oracle_sql('SELECT 1 FROM dual;',dynamic['data']).returncode!=0
    old=v.get('database/static-creds/oracle-static')['data']
    assert oracle_sql('SELECT 1 FROM dual;',old).returncode==0
    v.post('database/rotate-role/oracle-static')
    new=v.get('database/static-creds/oracle-static')['data'];assert old['password']!=new['password']
    assert oracle_sql('SELECT 1 FROM dual;',new).returncode==0
    assert oracle_sql('SELECT 1 FROM dual;',old).returncode!=0
    issued=[v.get('database/creds/oracle-dynamic') for _ in range(2)]
    for credential in issued: assert oracle_sql('SELECT 1 FROM dual;',credential['data']).returncode==0
    v.post('sys/leases/revoke-prefix/database/creds/oracle-dynamic')
    for credential in issued: assert oracle_sql('SELECT 1 FROM dual;',credential['data']).returncode!=0
    print('Oracle login, individual and prefix lease revocation, and static password rotation passed')
