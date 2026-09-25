"""VSO JWT and public-JWKS variant, including dynamic AWS STS credentials."""
from runtime import *
from sync import aws_client

def setup():
    import kubernetes as k
    # Same Kubernetes APIs on EKS and OpenShift. Set OPENSHIFT_CONTEXT for actual OpenShift validation.
    context=os.getenv('OPENSHIFT_CONTEXT')
    if context:os.environ['KUBE_CONTEXT']=context
    aws_env();k.install();k.auth(method='jwt',mount='vm-jwt')
    iam=aws_client('iam');info=outputs();name='mapfre-vm-aws-engine'
    trust=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'AWS':info['vault_role_arn']},'Action':'sts:AssumeRole'}]})
    try:arn=iam.get_role(RoleName=name)['Role']['Arn']
    except iam.exceptions.NoSuchEntityException:arn=iam.create_role(RoleName=name,AssumeRolePolicyDocument=trust)['Role']['Arn']
    iam.put_role_policy(RoleName=info['vault_role_name'],PolicyName='vm-aws-engine',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sts:AssumeRole','Resource':arn}]}))
    # No EC2 metadata identity is installed in a pod. Vault's VM profile assumes this STS role.
    v=Vault();v.mount('aws-vm','aws');v.post('aws-vm/config/root',{'region':os.environ['AWS_REGION']})
    v.post('aws-vm/roles/demo',{'credential_type':'assumed_role','role_arns':[arn],'default_sts_ttl':'15m','max_sts_ttl':'1h'})
    ns(k.NS)
    common={'apiVersion':'secrets.hashicorp.com/v1beta1'}
    apply(common|{'kind':'VaultConnection','metadata':{'name':'vm-jwt','namespace':k.NS},'spec':{'address':v.addr,'skipTLSVerify':False}})
    apply(common|{'kind':'VaultAuth','metadata':{'name':'vm-jwt','namespace':k.NS},'spec':{'vaultConnectionRef':'vm-jwt','method':'jwt','mount':'vm-jwt','jwt':{'role':'consumer','serviceAccount':'consumer','audiences':['vault']}}})
    apply(common|{'kind':'VaultDynamicSecret','metadata':{'name':'vm-aws-jwt','namespace':k.NS},'spec':{'vaultAuthRef':'vm-jwt','mount':'aws-vm','path':'sts/demo','renewalPercent':50,'destination':{'create':True,'name':'vm-aws-jwt','overwrite':True}}})
    print('VSO JWT with all RSA signing keys and dynamic AWS STS role configured')

def verify():
    import kubernetes as k
    import boto3
    def credentials(name):
        p=kube(['-n',k.NS,'get','secret',name,'-o','json'],check=False)
        if p.returncode:return None
        d=json.loads(p.stdout)['data'];return {key:base64.b64decode(value).decode() for key,value in d.items()}
    c=wait_for(lambda:credentials('vm-aws-jwt'),timeout=300)
    sts=boto3.client('sts',aws_access_key_id=c['access_key'],aws_secret_access_key=c['secret_key'],aws_session_token=c['security_token'],region_name=os.environ['AWS_REGION'])
    assert 'assumed-role/mapfre-vm-aws-engine/' in sts.get_caller_identity()['Arn']
    # Public JWKS endpoint is EKS OIDC issuer, not the private kubernetes.default.svc DNS name.
    issuer=json.loads(kube(['get','--raw','/.well-known/openid-configuration']))['issuer']
    discovery=requests.get(issuer+'/.well-known/openid-configuration',timeout=30);discovery.raise_for_status()
    uri=discovery.json()['jwks_uri'];requests.get(uri,timeout=30).raise_for_status()
    v=Vault();v.auth('vm-jwt-public','jwt');v.post('auth/vm-jwt-public/config',{'jwks_url':uri,'bound_issuer':issuer})
    v.post('auth/vm-jwt-public/role/consumer',{'role_type':'jwt','user_claim':'sub','bound_subject':f'system:serviceaccount:{k.NS}:consumer','bound_audiences':['vault'],'token_policies':['vm-consumer']})
    apply({'apiVersion':'secrets.hashicorp.com/v1beta1','kind':'VaultAuth','metadata':{'name':'vm-jwt-public','namespace':k.NS},'spec':{'vaultConnectionRef':'vm-jwt','method':'jwt','mount':'vm-jwt-public','jwt':{'role':'consumer','serviceAccount':'consumer','audiences':['vault']}}})
    apply({'apiVersion':'secrets.hashicorp.com/v1beta1','kind':'VaultDynamicSecret','metadata':{'name':'vm-aws-jwt-public','namespace':k.NS},'spec':{'vaultAuthRef':'vm-jwt-public','mount':'aws-vm','path':'sts/demo','renewalPercent':50,'destination':{'create':True,'name':'vm-aws-jwt-public','overwrite':True}}})
    c=wait_for(lambda:credentials('vm-aws-jwt-public'),timeout=300)
    sts=boto3.client('sts',aws_access_key_id=c['access_key'],aws_secret_access_key=c['secret_key'],aws_session_token=c['security_token'],region_name=os.environ['AWS_REGION'])
    assert 'assumed-role/mapfre-vm-aws-engine/' in sts.get_caller_identity()['Arn']
    print('Both VSO JWT modes issued working AWS STS credentials. Kubernetes context:',config()['KUBE_CONTEXT'])
    print('OpenShift-specific SCC behavior requires OPENSHIFT_CONTEXT; this execution records the actual cluster.')
