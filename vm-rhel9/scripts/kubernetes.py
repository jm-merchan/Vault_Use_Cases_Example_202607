from runtime import *
import yaml
NS='vm-consumers'

def cluster_info():
    c=json.loads(kube(['config','view','--minify','--raw','--flatten','-o','json']))['clusters'][0]['cluster']
    return c['server'],base64.b64decode(c['certificate-authority-data']).decode()

def auth(namespace=NS,method='kubernetes',mount='vm-kubernetes',context=None):
    ns(namespace)
    for name in ['consumer','reviewer']:
        apply({'apiVersion':'v1','kind':'ServiceAccount','metadata':{'name':name,'namespace':namespace}})
    server,ca=cluster_info();v=Vault();v.auth(mount,method)
    if method=='kubernetes':
        apply({'apiVersion':'rbac.authorization.k8s.io/v1','kind':'ClusterRoleBinding','metadata':{'name':namespace+'-reviewer'},'roleRef':{'apiGroup':'rbac.authorization.k8s.io','kind':'ClusterRole','name':'system:auth-delegator'},'subjects':[{'kind':'ServiceAccount','name':'reviewer','namespace':namespace}]})
        jwt=kube(['-n',namespace,'create','token','reviewer','--duration=24h']).strip()
        v.post('auth/'+mount+'/config',{'kubernetes_host':server,'kubernetes_ca_cert':ca,'token_reviewer_jwt':jwt,'disable_local_ca_jwt':True})
        role={'bound_service_account_names':['consumer'],'bound_service_account_namespaces':[namespace],'audience':'vault','token_policies':['vm-consumer'],'token_ttl':'10m'}
    else:
        discovery=json.loads(kube(['get','--raw','/.well-known/openid-configuration']))
        jwks=json.loads(kube(['get','--raw','/openid/v1/jwks']))
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives import serialization
        def integer(s):return int.from_bytes(base64.urlsafe_b64decode(s+'='*(-len(s)%4)),'big')
        keys=[rsa.RSAPublicNumbers(integer(k['e']),integer(k['n'])).public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode() for k in jwks['keys'] if k['kty']=='RSA']
        v.post('auth/'+mount+'/config',{'jwt_validation_pubkeys':keys,'bound_issuer':discovery['issuer']})
        role={'role_type':'jwt','user_claim':'sub','bound_subject':f'system:serviceaccount:{namespace}:consumer','bound_audiences':['vault'],'token_policies':['vm-consumer'],'token_ttl':'10m'}
    v.policy('vm-consumer','path "vm-gha/secret/data/*" { capabilities = ["read"] }\npath "secret/data/vm/*" { capabilities = ["read"] }\npath "database/creds/readonly" { capabilities = ["read"] }\npath "aws-vm/sts/demo" { capabilities = ["read"] }')
    v.post('auth/'+mount+'/role/consumer',role)
    # Prove authentication and negative audience/SA rejection.
    jwt=kube(['-n',namespace,'create','token','consumer','--audience=vault','--duration=10m']).strip()
    response=v.post('auth/'+mount+'/login',{'role':'consumer','jwt':jwt});assert response['auth']['client_token']
    wrong=kube(['-n',namespace,'create','token','reviewer','--audience=vault','--duration=10m']).strip()
    v.post('auth/'+mount+'/login',{'role':'consumer','jwt':wrong},codes=(400,403))
    print('External Vault',method,'authentication and forbidden service-account test passed')

def helm(args):return run(['helm','--kube-context',config()['KUBE_CONTEXT'],*args],timeout=900)

def install():
    aws_env();ns(NS)
    helm(['repo','add','hashicorp','https://helm.releases.hashicorp.com','--force-update'])
    # Reuse existing controllers; never remove their cluster-wide resources.
    deployments=json.loads(kube(['get','deploy','-A','-o','json']))['items']
    if not any('vault-secrets-operator' in x['metadata']['name'] for x in deployments):
        helm(['upgrade','--install','vm-vso','hashicorp/vault-secrets-operator','-n','vm-vso-system','--create-namespace','--version','0.10.0','--wait'])
    if kube(['get','crd','secretproviderclasses.secrets-store.csi.x-k8s.io'],check=False).returncode:
        helm(['repo','add','secrets-store-csi-driver','https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts','--force-update'])
        helm(['upgrade','--install','vm-csi','secrets-store-csi-driver/secrets-store-csi-driver','-n','vm-csi-system','--create-namespace','--set','enableSecretRotation=true','--set','rotationPollInterval=30s','--wait'])
    ds=json.loads(kube(['get','ds','-A','-o','json']))['items']
    if not any('vault-csi-provider' in x['metadata']['name'] for x in ds):
        helm(['upgrade','--install','vm-vault-csi','hashicorp/vault','-n','vm-csi-system','--create-namespace','--version','0.34.0','--set','server.enabled=false','--set','injector.enabled=false','--set','csi.enabled=true','--wait'])
    auth()

def resources(method='kubernetes',mount='vm-kubernetes',namespace=NS):
    v=Vault();v.mount('secret');v.post('secret/data/vm/static',{'data':{'value':'vm-version-1'}})
    common={'apiVersion':'secrets.hashicorp.com/v1beta1'}
    apply(common|{'kind':'VaultConnection','metadata':{'name':'vm-vault','namespace':namespace},'spec':{'address':v.addr,'skipTLSVerify':False}})
    apply(common|{'kind':'VaultAuth','metadata':{'name':'vm-vault','namespace':namespace},'spec':{'vaultConnectionRef':'vm-vault','method':method,'mount':mount,method:{'role':'consumer','serviceAccount':'consumer','audiences':['vault']}}})
    apply(common|{'kind':'VaultStaticSecret','metadata':{'name':'vm-static','namespace':namespace},'spec':{'vaultAuthRef':'vm-vault','type':'kv-v2','mount':'secret','path':'vm/static','refreshAfter':'10s','destination':{'create':True,'name':'vm-static','overwrite':True}}})
    from services import postgres
    postgres()
    apply(common|{'kind':'VaultDynamicSecret','metadata':{'name':'vm-dynamic','namespace':namespace},'spec':{'vaultAuthRef':'vm-vault','mount':'database','path':'creds/readonly','renewalPercent':50,'destination':{'create':True,'name':'vm-dynamic','overwrite':True}}})
    # The CSI Vault provider uses Kubernetes auth; keep JWT VSO as a separate flow.
    objects=[{'objectName':'static','secretPath':'secret/data/vm/static','secretKey':'value'},
             {'objectName':'db-user','secretPath':'database/creds/readonly','secretKey':'username'},
             {'objectName':'db-password','secretPath':'database/creds/readonly','secretKey':'password'}]
    apply({'apiVersion':'secrets-store.csi.x-k8s.io/v1','kind':'SecretProviderClass','metadata':{'name':'vm-vault','namespace':namespace},'spec':{'provider':'vault','parameters':{'vaultAddress':v.addr,'roleName':'consumer','vaultAuthMountPath':'vm-kubernetes','audience':'vault','objects':yaml.safe_dump(objects)}}})
    pod={'apiVersion':'v1','kind':'Pod','metadata':{'name':'vm-secret-reader','namespace':namespace},'spec':{'serviceAccountName':'consumer','containers':[{'name':'reader','image':'busybox:1.37.0','command':['sh','-c','sleep 86400'],'volumeMounts':[{'name':'csi','mountPath':'/csi','readOnly':True},{'name':'static','mountPath':'/static','readOnly':True},{'name':'dynamic','mountPath':'/dynamic','readOnly':True}]}],'volumes':[{'name':'csi','csi':{'driver':'secrets-store.csi.k8s.io','readOnly':True,'volumeAttributes':{'secretProviderClass':'vm-vault'}}},{'name':'static','secret':{'secretName':'vm-static'}},{'name':'dynamic','secret':{'secretName':'vm-dynamic'}}]}}
    apply(pod)
    kube(['-n',namespace,'wait','--for=condition=Ready','pod/vm-secret-reader','--timeout=300s'])
    print('VSO static/dynamic resources and CSI mounted consumer are ready')

def verify():
    from services import pg_login
    def get_secret(name):
        d=json.loads(kube(['-n',NS,'get','secret',name,'-o','json']))['data'];return {k:base64.b64decode(v).decode() for k,v in d.items()}
    wait_for(lambda:get_secret('vm-static')['value']=='vm-version-1',timeout=180)
    assert pg_login(get_secret('vm-dynamic')).returncode==0
    wait_for(lambda:kube(['-n',NS,'exec','vm-secret-reader','--','cat','/csi/static']).strip()=='vm-version-1',timeout=180)
    # Both fields from the same dynamic path must come from the same CSI lease.
    creds={k:kube(['-n',NS,'exec','vm-secret-reader','--','cat','/csi/'+f]).strip() for k,f in [('username','db-user'),('password','db-password')]}
    assert pg_login(creds).returncode==0
    marker='vm-'+secrets.token_hex(8);Vault().post('secret/data/vm/static',{'data':{'value':marker}})
    wait_for(lambda:get_secret('vm-static')['value']==marker,timeout=180)
    wait_for(lambda:kube(['-n',NS,'exec','vm-secret-reader','--','cat','/csi/static']).strip()==marker,timeout=300)
    print('VSO and CSI: static rotation matched; both dynamic SQL credentials authenticated')

def secrets_engine():
    aws_env();ns(NS);server,ca=cluster_info();v=Vault();v.mount('kubernetes','kubernetes')
    apply({'apiVersion':'v1','kind':'ServiceAccount','metadata':{'name':'engine','namespace':NS}})
    # Scope token creation to this namespace and a pre-existing consumer SA.
    apply({'apiVersion':'rbac.authorization.k8s.io/v1','kind':'Role','metadata':{'name':'engine','namespace':NS},'rules':[{'apiGroups':[''],'resources':['serviceaccounts'],'verbs':['get','create','update','delete']},{'apiGroups':[''],'resources':['serviceaccounts/token'],'verbs':['create']},{'apiGroups':['rbac.authorization.k8s.io'],'resources':['roles'],'resourceNames':['consumer'],'verbs':['get','bind']},{'apiGroups':['rbac.authorization.k8s.io'],'resources':['rolebindings'],'verbs':['get','create','update','delete']}]})
    apply({'apiVersion':'rbac.authorization.k8s.io/v1','kind':'RoleBinding','metadata':{'name':'engine','namespace':NS},'roleRef':{'apiGroup':'rbac.authorization.k8s.io','kind':'Role','name':'engine'},'subjects':[{'kind':'ServiceAccount','name':'engine','namespace':NS}]})
    apply({'apiVersion':'rbac.authorization.k8s.io/v1','kind':'Role','metadata':{'name':'consumer','namespace':NS},'rules':[{'apiGroups':[''],'resources':['configmaps'],'verbs':['get','list','create','update','patch','delete']},{'apiGroups':['secrets.hashicorp.com'],'resources':['vaultconnections','vaultauths','vaultstaticsecrets'],'verbs':['get','list','watch','create','update','patch','delete']},{'apiGroups':['apps'],'resources':['deployments'],'verbs':['get','list','watch','create','update','patch','delete']}]})
    apply({'apiVersion':'rbac.authorization.k8s.io/v1','kind':'RoleBinding','metadata':{'name':'consumer','namespace':NS},'roleRef':{'apiGroup':'rbac.authorization.k8s.io','kind':'Role','name':'consumer'},'subjects':[{'kind':'ServiceAccount','name':'consumer','namespace':NS}]})
    reviewer=kube(['-n',NS,'create','token','engine','--duration=24h']).strip()
    v.post('kubernetes/config',{'kubernetes_host':server,'kubernetes_ca_cert':ca,'service_account_jwt':reviewer,'disable_local_ca_jwt':True})
    v.post('kubernetes/roles/github',{'allowed_kubernetes_namespaces':[NS],'service_account_name':'','kubernetes_role_name':'consumer','kubernetes_role_type':'Role','token_default_ttl':'10m','token_max_ttl':'1h'})
    creds=v.post('kubernetes/creds/github',{'kubernetes_namespace':NS})
    ca_path=private(STATE/'kubernetes-ca.pem',ca)
    p=run(['kubectl','--server',server,'--certificate-authority',ca_path,'--token',creds['data']['service_account_token'],'auth','can-i','create','configmaps','-n',NS]).strip();assert p=='yes'
    p=run(['kubectl','--server',server,'--certificate-authority',ca_path,'--token',creds['data']['service_account_token'],'auth','can-i','get','secrets','-n','kube-system'],check=False);assert p.returncode!=0
    v.post('sys/leases/revoke',{'lease_id':creds['lease_id']})
    def revoked():
        return run(['kubectl','--server',server,'--certificate-authority',ca_path,'--token',creds['data']['service_account_token'],'auth','can-i','create','configmaps','-n',NS],check=False).returncode!=0
    wait_for(revoked,timeout=90)
    print('Kubernetes engine: generated SA, namespace-scoped permissions and denial after lease revocation verified')
