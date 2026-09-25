from runtime import *
import boto3

def aws_client(service):
    aws_env();return boto3.Session().client(service,region_name=os.environ['AWS_REGION'])

def synced(v,kind,name):
    def check():
        d=v.get(f'sys/sync/destinations/{kind}/{name}/associations')['data']
        records=d.get('associated_secrets',{})
        records=list(records.values()) if isinstance(records,dict) else records
        return bool(records) and all(x.get('sync_status')=='SYNCED' for x in records)
    wait_for(check,timeout=360)

def aws_permissions(role_name=None,user_name=None):
    iam=aws_client('iam'); account=aws_env()['Account']
    policy=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':['secretsmanager:CreateSecret','secretsmanager:DeleteSecret','secretsmanager:DescribeSecret','secretsmanager:GetSecretValue','secretsmanager:PutSecretValue','secretsmanager:TagResource','secretsmanager:UntagResource','secretsmanager:UpdateSecret'],'Resource':f'arn:aws:secretsmanager:{os.environ["AWS_REGION"]}:{account}:secret:vault-vm/*'}]})
    if role_name:iam.put_role_policy(RoleName=role_name,PolicyName='mapfre-vm-secrets-sync',PolicyDocument=policy)
    if user_name:iam.put_user_policy(UserName=user_name,PolicyName='mapfre-vm-secrets-sync',PolicyDocument=policy)

def aws_sync(mode):
    v=Vault(); v.post('sys/activation-flags/secrets-sync/activate')
    info=outputs(); region=os.environ.get('AWS_REGION','eu-central-1')
    if mode=='instance-profile':
        terraform('irsa',{'vault_irsa_role_name':info['vault_role_name']});mount='sync-aws-irsa';name='aws-sm-irsa-local'
    elif mode=='assume-role':
        terraform('irsa-assume-role',{'vault_irsa_role_name':info['vault_role_name'],'sync_role_name':'mapfre-vm-sync-assume','aws_region':region});mount='irsa-assume-role-kv';name='aws-sm-irsa-assume-role'
    elif mode=='wif':
        terraform('wif',{'vault_pod_role_name':info['vault_role_name'],'public_oidc_issuer_url':info['vault_address'],'tenant_id':'mapfre-vm-wif','aws_region':region});mount='mapfre-vm-wif-kv';name='mapfre-vm-wif-aws-sm'
    elif mode in ('static','operator-role'):
        # User-authorized replacement for the static-key example: Doormat drives
        # Terraform; the Vault VM assumes a dedicated destination role. No IAM user.
        terraform('operator-role',{'vault_irsa_role_name':info['vault_role_name'],'sync_role_name':'mapfre-vm-operator-role','destination_name':'aws-sm-operator-role','aws_region':region})
        mount='operator-role-kv';name='aws-sm-operator-role'
    else:raise ValueError(mode)
    private(STATE/('sync-aws-'+mode+'.json'),{'name':name,'mount':mount})
    marker=secrets.token_hex(12)
    v.post(mount+'/data/verification',{'data':{'marker':marker}})
    v.post('sys/sync/destinations/aws-sm/'+name+'/associations/set',{'mount':mount,'secret_name':'verification'})
    synced(v,'aws-sm',name)
    sm=aws_client('secretsmanager')
    def same():return json.loads(sm.get_secret_value(SecretId='vault-vm/'+mount+'/verification')['SecretString'])['marker']==marker
    wait_for(same,timeout=180)
    marker=secrets.token_hex(12);v.post(mount+'/data/verification',{'data':{'marker':marker}})
    wait_for(same,timeout=180)
    print('AWS',mode,': SYNCED and two value versions verified in Secrets Manager')

def azure_account():
    settings=dotenv_values(ROOT.parent/'.env')
    subscription=os.getenv('AZURE_SUBSCRIPTION_ID') or settings.get('AZURE_SUBSCRIPTION_ID')
    tenant=os.getenv('AZURE_TENANT_ID') or settings.get('AZURE_TENANT_ID')
    if subscription:run(['az','account','set','--subscription',subscription],timeout=45)
    if tenant:os.environ['ARM_TENANT_ID']=tenant
    account=json.loads(run(['az','account','show','-o','json'],timeout=45))
    if tenant and account['tenantId']!=tenant:raise Blocked('Azure CLI tenant differs from .env; run az login --tenant for the configured tenant')
    run(['az','account','get-access-token','--query','expiresOn','-o','tsv'],timeout=45)
    return account

def azure_sync(mode):
    v=Vault(); account=azure_account(); prefix='mvm-'+mode
    if mode in ['spn','wif']:
        variables={'azure_subscription_id':account['id'],'name_prefix':prefix}
        if mode=='wif':variables['public_oidc_issuer_url']=outputs()['vault_address']
        result=terraform('azure-'+mode,variables)
        private(STATE/('azure-'+mode+'.json'),result)
        # Read canonical destination config rather than depend on output naming.
        name=prefix+'-azure-kv';mount=prefix+'-kv'
        cfg=v.get('sys/sync/destinations/azure-kv/'+name)['data']
        if 'connection_details' in cfg:cfg=cfg['connection_details']
        uri=cfg.get('key_vault_uri')
        if not uri:
            # Terraform outputs are non-secret metadata.
            for k,value in result.items():
                if 'uri' in k and isinstance(value,str):uri=value;break
        if not uri:
            vaults=json.loads(run(['az','keyvault','list','--resource-group',prefix+'-secrets-sync-rg','-o','json']))
            kv=vaults[0]['name']
        else:kv=uri.split('//')[1].split('.')[0]
    elif mode=='cli':
        name='vm-azure-cli';mount='vm-azure-cli';path=STATE/'azure-cli.json'
        if path.exists():result=json.loads(path.read_text())
        else:
            kv='mvmcli'+secrets.token_hex(4);rg='mapfre-vm-cli'
            run(['az','group','create','-n',rg,'-l','westeurope'])
            vault=json.loads(run(['az','keyvault','create','-n',kv,'-g',rg,'-l','westeurope','--enable-rbac-authorization','true','-o','json']))
            app=json.loads(run(['az','ad','app','create','--display-name','mapfre-vm-cli','-o','json']))
            sp=json.loads(run(['az','ad','sp','create','--id',app['appId'],'-o','json']))
            cred=json.loads(run(['az','ad','app','credential','reset','--id',app['appId'],'--append','--display-name','vm-poc','--years','1','-o','json']))
            run(['az','role','assignment','create','--assignee-object-id',sp['id'],'--assignee-principal-type','ServicePrincipal','--role','Key Vault Secrets Officer','--scope',vault['id']])
            oid=run(['az','ad','signed-in-user','show','--query','id','-o','tsv']).strip()
            run(['az','role','assignment','create','--assignee-object-id',oid,'--assignee-principal-type','User','--role','Key Vault Secrets Officer','--scope',vault['id']])
            result={'kv':kv,'app_id':app['appId'],'client_secret':cred['password'],'tenant':account['tenantId'],'rg':rg};private(path,result)
        kv=result['kv'];v.mount(mount);v.post('sys/activation-flags/secrets-sync/activate')
        v.post('sys/sync/destinations/azure-kv/'+name,{'key_vault_uri':'https://'+kv+'.vault.azure.net/','client_id':result['app_id'],'client_secret':result['client_secret'],'tenant_id':result['tenant'],'secret_name_template':'vault-{{ .MountPath }}-{{ .SecretPath }}'})
    else:raise ValueError(mode)
    marker=secrets.token_hex(12);v.post(mount+'/data/verification',{'data':{'marker':marker}})
    v.post('sys/sync/destinations/azure-kv/'+name+'/associations/set',{'mount':mount,'secret_name':'verification'})
    synced(v,'azure-kv',name)
    def same():
        val=run(['az','keyvault','secret','show','--vault-name',kv,'--name','vault-'+mount+'-verification','--query','value','-o','tsv'],timeout=60)
        return json.loads(val)['marker']==marker
    wait_for(same,timeout=360)
    marker=secrets.token_hex(12);v.post(mount+'/data/verification',{'data':{'marker':marker}});wait_for(same,timeout=180)
    private(STATE/('azure-'+mode+'-verification.json'),{'kv':kv,'name':name,'mount':mount})
    print('Azure',mode,': SYNCED and two value versions verified in Key Vault')
