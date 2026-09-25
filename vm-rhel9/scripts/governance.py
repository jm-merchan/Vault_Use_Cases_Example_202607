from runtime import *
from services import deploy_service, password, ref

def ldap():
    aws_env();secret('ldap',{'LDAP_ADMIN_PASSWORD':password('ldap')})
    host=deploy_service('ldap','osixia/openldap:1.5.0',389,[ref('ldap','LDAP_ADMIN_PASSWORD'),{'name':'LDAP_DOMAIN','value':'vm.example'},{'name':'LDAP_ORGANISATION','value':'VM Demo'},{'name':'LDAP_TLS','value':'false'}])
    ldif='''dn: ou=users,dc=vm,dc=example
objectClass: organizationalUnit
ou: users

dn: ou=groups,dc=vm,dc=example
objectClass: organizationalUnit
ou: groups
'''
    for user in ['alice','peter']:
        ldif+=f'\ndn: cn={user},ou=users,dc=vm,dc=example\nobjectClass: inetOrgPerson\ncn: {user}\nsn: {user}\nuserPassword: {password("ldap-"+user)}\n'
    for group,user in [('dev','alice'),('ops','peter')]:
        ldif+=f'\ndn: cn={group},ou=groups,dc=vm,dc=example\nobjectClass: groupOfNames\ncn: {group}\nmember: cn={user},ou=users,dc=vm,dc=example\n'
    script='f=$(mktemp)\ntrap \'rm -f "$f"\' EXIT\nprintf %s '+shlex.quote(password('ldap'))+' > "$f"\nldapadd -c -x -H ldap://127.0.0.1 -D cn=admin,dc=vm,dc=example -y "$f" <<\'LDIF\'\n'+ldif+'\nLDIF\n'
    p=kube(['-n','vm-demo','exec','-i','deployment/ldap','--','bash','-s'],script,check=False)
    assert p.returncode in (0,68), 'LDAP add failed'
    root=Vault()
    if not root.get('sys/namespaces/vm-rbac',codes=(200,404)).get('data'):root.post('sys/namespaces/vm-rbac')
    v=Vault(namespace='vm-rbac');v.auth('ldap','ldap');v.mount('secret')
    v.post('auth/ldap/config',{'url':'ldap://'+host+':389','binddn':'cn=admin,dc=vm,dc=example','bindpass':password('ldap'),'userdn':'ou=users,dc=vm,dc=example','userattr':'cn','groupdn':'ou=groups,dc=vm,dc=example','groupfilter':'(&(objectClass=groupOfNames)(member={{.UserDN}}))','groupattr':'cn'})
    v.policy('dev','path "secret/data/allowed/*" { capabilities = ["read"] }')
    v.policy('ops','path "sys/mounts/*" { capabilities = ["create","read","update","delete","sudo"] }\npath "sys/mounts" { capabilities = ["read"] }')
    for g in ['dev','ops']:v.post('auth/ldap/groups/'+g,{'policies':[g]})
    v.post('secret/data/allowed/example',{'data':{'value':'allowed'}})
    print('LDAP namespace, users, groups and scoped policies configured')

def verify():
    root=Vault();v=Vault(namespace='vm-rbac')
    def login(user):return v.post('auth/ldap/login/'+user,{'password':password('ldap-'+user)})['auth']['client_token']
    alice=Vault(namespace='vm-rbac',token=wait_for(lambda:login('alice'),timeout=180))
    assert alice.get('secret/data/allowed/example')['data']['data']['value']=='allowed'
    alice.post('sys/mounts/forbidden',{'type':'kv'},codes=(403,))
    peter=Vault(namespace='vm-rbac',token=login('peter'))
    if not v.get('sys/mounts')['data'].get('ops-demo/'):peter.post('sys/mounts/ops-demo',{'type':'kv'})
    v.post('auth/token/revoke',{'token':alice.token});alice.get('secret/data/allowed/example',codes=(403,))
    alice.token=login('alice');assert alice.get('secret/data/allowed/example')['data']
    # Lock token remains private; use CLI for version-correct lock/unlock endpoints.
    lock=run(['vault','namespace','lock','-format=json','vm-rbac'],env=root.cli_env())
    private(STATE/'namespace-lock.json',lock)
    try:
        alice.get('secret/data/allowed/example',codes=(423,503))
        v.post('auth/ldap/login/alice',{'password':password('ldap-alice')},codes=(423,503))
    finally:
        data=json.loads(lock).get('data',{})
        args=['vault','namespace','unlock']
        if data.get('unlock_key'):args+=['-unlock-key='+data['unlock_key']]
        run(args+['vm-rbac'],env=root.cli_env())
    alice.token=login('alice');assert alice.get('secret/data/allowed/example')['data']
    print('LDAP RBAC allow/deny, token revocation, reauthentication and namespace lock/unlock passed')
