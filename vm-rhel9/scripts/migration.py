from runtime import *
from sync import aws_client, synced

def values(count):
    # Include simple, structured, Unicode, multiline and PEM source shapes.
    result={'vm-demo-db-password':secrets.token_hex(24),'vm-demo-json':json.dumps({'user':'demo','password':secrets.token_hex(16)}),'vm-demo-unicode':'España – contraseña de prueba','vm-demo-multiline':'line one\nline two\n'}
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives import serialization
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    result['vm-demo-pem']=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
    for i in range(count-len(result)):result['vm-demo-secret-'+str(i)]=secrets.token_hex(24)
    return result

def sources(provider):
    path=STATE/('import-'+provider+'-values.json')
    if not path.exists():private(path,values(11 if provider=='aws' else 10))
    vals=json.loads(path.read_text())
    if provider=='aws':
        sm=aws_client('secretsmanager')
        for name,value in vals.items():
            try:sm.create_secret(Name=name,SecretString=value,Tags=[{'Key':'importable','Value':'true'},{'Key':'migration','Value':'vm-rhel9-aws'}])
            except sm.exceptions.ResourceExistsException:sm.put_secret_value(SecretId=name,SecretString=value)
    else:
        p=STATE/'azure-cli.json'
        if not p.exists():
            from sync import azure_sync
            azure_sync('cli')
        cfg=json.loads(p.read_text())
        for name,value in vals.items():
            f=private(STATE/'azure-value.txt',value)
            run(['az','keyvault','secret','set','--vault-name',cfg['kv'],'--name',name,'--file',f,'--tags','importable=true','migration=vm-rhel9-azure','-o','none'])
    print(len(vals),provider,'source secrets created with an isolated migration tag')

def import_secrets(provider):
    v=Vault();v.post('sys/activation-flags/secrets-import/activate')
    if provider=='aws':
        account=aws_env()['Account'];prefix=account+'/'+os.environ['AWS_REGION'];source='source_aws {\n name = "source"\n}'
    else:
        cfg=json.loads((STATE/'azure-cli.json').read_text());prefix=cfg['kv']
        f=private(STATE/'azure-import-client-secret',cfg['client_secret'])
        source=f'source_azure {{\n name = "source"\n key_vault_uri = "https://{cfg["kv"]}.vault.azure.net/"\n tenant_id = "{cfg["tenant"]}"\n client_id = "{cfg["app_id"]}"\n credentials_file = "{f}"\n}}'
    mount='vm-'+provider+'-import'
    for nested in [False,True]:
        transform='\n transform "regexp" {\n from = "(.+)"\n to = "'+prefix+'/$1"\n }' if nested else ''
        plan=source+f'''\ndestination_vault {{
 name = "vault"
 address = "{v.addr}"
 mount = "{mount}"
}}
mapping {{
 name = "isolated-vm-import"
 source = "source"
 destination = "vault"
 filter = "Secret.Tags.importable == \\"true\\" and Secret.Tags.migration == \\"vm-rhel9-{provider}\\""
 {transform}
}}
'''
        path=private(STATE/(provider+'-import.hcl'),plan)
        # Every application is preceded by an actual import plan.
        run(['vault','operator','import','-config='+str(path),'plan'],env=v.cli_env())
        run(['vault','operator','import','-config='+str(path),'-auto-create','-auto-approve','apply'],env=v.cli_env())
    vals=json.loads((STATE/('import-'+provider+'-values.json')).read_text())
    for name,value in vals.items():
        for path in [name,prefix+'/'+name]:
            assert v.get(mount+'/data/'+path)['data']['data']['value']==value
            metadata=v.get(mount+'/metadata/'+path)['data']['custom_metadata']
            assert metadata['importable']=='true' and metadata['migration']=='vm-rhel9-'+provider
    private(STATE/('import-'+provider+'-location.json'),{'mount':mount,'prefix':prefix})
    print('Flat and nested import completed; all values and source tags matched')

def roundtrip(provider):
    v=Vault();v.post('sys/activation-flags/secrets-sync/activate');name='vm-import-roundtrip-'+provider
    kind='aws-sm' if provider=='aws' else 'azure-kv'
    if provider=='aws':
        iam=aws_client('iam');info=outputs();role='mapfre-vm-import-sync'
        trust=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'AWS':info['vault_role_arn']},'Action':'sts:AssumeRole'}]})
        try:arn=iam.get_role(RoleName=role)['Role']['Arn']
        except iam.exceptions.NoSuchEntityException:arn=iam.create_role(RoleName=role,AssumeRolePolicyDocument=trust)['Role']['Arn']
        account=aws_env()['Account']
        iam.put_role_policy(RoleName=role,PolicyName='vm-import',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':['secretsmanager:CreateSecret','secretsmanager:DescribeSecret','secretsmanager:PutSecretValue','secretsmanager:UpdateSecret','secretsmanager:TagResource','secretsmanager:UntagResource','secretsmanager:DeleteSecret'],'Resource':f'arn:aws:secretsmanager:{os.environ["AWS_REGION"]}:{account}:secret:vm-demo-*'}]}))
        iam.put_role_policy(RoleName=info['vault_role_name'],PolicyName='vm-import-assume',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sts:AssumeRole','Resource':arn}]}))
        dest={'region':os.environ['AWS_REGION'],'role_arn':arn}
    else:
        cfg=json.loads((STATE/'azure-cli.json').read_text())
        dest={'key_vault_uri':'https://'+cfg['kv']+'.vault.azure.net/','tenant_id':cfg['tenant'],'client_id':cfg['app_id'],'client_secret':cfg['client_secret']}
    dest.update({'granularity':'secret-key','secret_name_template':'{{ $unused := .SecretKey }}{{ .SecretBaseName }}'})
    v.post('sys/sync/destinations/'+kind+'/'+name,dest)
    loc=json.loads((STATE/('import-'+provider+'-location.json')).read_text());vals=json.loads((STATE/('import-'+provider+'-values.json')).read_text())
    for base in vals:
        v.post('sys/sync/destinations/'+kind+'/'+name+'/associations/set',{'mount':loc['mount'],'secret_name':loc['prefix']+'/'+base})
    synced(v,kind,name)
    for base,value in vals.items():
        if provider=='aws':got=aws_client('secretsmanager').get_secret_value(SecretId=base)['SecretString']
        else:got=run(['az','keyvault','secret','show','--vault-name',cfg['kv'],'--name',base,'-o','json']);got=json.loads(got)['value']
        assert got==value,'Round-trip value mismatch: '+base
    print(len(vals),provider,'secrets synced back to original names; values and SYNCED status verified')
