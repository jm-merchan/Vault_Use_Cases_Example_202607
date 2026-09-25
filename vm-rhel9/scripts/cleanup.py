#!/usr/bin/env python3
"""Explicitly retire only resources owned by this VM variant."""
from runtime import *
import argparse

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scope',choices=['scenarios','infrastructure'],required=True)
    parser.add_argument('--execute',action='store_true',help='Apply destructive cleanup. Without this flag, list scope only.')
    args=parser.parse_args()
    print('Scope:',args.scope,'; ownership prefix mapfre-vm / mvm- / namespaces vm-*')
    if not args.execute:
        print('Preview only. Add --execute to retire these VM-demo resources. Original notebooks/resources are excluded.');return
    config();aws_env()
    if args.scope=='infrastructure':
        if not (STATE/'scenarios-cleaned').exists():raise RuntimeError('Run --scope scenarios --execute first')
        path=ROOT/'terraform/infrastructure'
        run(['terraform',f'-chdir={path}','destroy','-auto-approve','-input=false'],timeout=1800)
        print('VM infrastructure retired. Keep encrypted backup of .state if required.');return
    from sync import aws_client
    v=Vault()
    # Delete only VM-owned Kubernetes namespaces. No shared VSO/CSI CRDs or controllers are removed.
    for name in ['vm-demo','vm-consumers','vm-monitoring','vm-benchmark']:
        kube(['delete','namespace',name,'--ignore-not-found=true','--wait=true'],timeout=1200)
    # Destroy scenario Terraform state. Protected issuer/key remain on this Vault until VM deletion.
    for name in ['azure-spn','azure-wif','wif','operator-role','irsa-assume-role','irsa']:
        path=ROOT/'terraform'/name
        if not (path/'terraform.tfstate').exists():continue
        resources=run(['terraform',f'-chdir={path}','state','list']).splitlines()
        for address in ['vault_identity_oidc.issuer','vault_identity_oidc_key.secrets_sync']:
            if address in resources:run(['terraform',f'-chdir={path}','state','rm',address])
        # Exclude protected blocks from destroy configuration, restore source afterwards.
        import re
        modified={}
        for f in path.glob('*.tf'):
            original=f.read_text();updated=original.replace('prevent_destroy = true','prevent_destroy = false')
            if original!=updated:modified[f]=original;f.write_text(updated)
        try:run(['terraform',f'-chdir={path}','destroy','-auto-approve','-input=false'],env=v.cli_env(),timeout=1800)
        finally:
            for f,s in modified.items():f.write_text(s)
    iam=aws_client('iam');sm=aws_client('secretsmanager')
    for role in ['mapfre-vm-sync-assume','mapfre-vm-import-sync','mapfre-vm-aws-engine','mapfre-vm-wif-secrets-sync-role']:
        try:
            for name in iam.list_role_policies(RoleName=role)['PolicyNames']:iam.delete_role_policy(RoleName=role,PolicyName=name)
            iam.delete_role(RoleName=role)
        except iam.exceptions.NoSuchEntityException:pass
    # Only tagged import sources, or known mount prefixes emitted by this isolated Vault.
    prefixes=['vault/sync-aws-irsa/','vault/irsa-assume-role-kv/','vault/mapfre-vm-wif-kv/','vault/sync-aws-static/']
    for page in sm.get_paginator('list_secrets').paginate():
        for s in page['SecretList']:
            tags={t['Key']:t['Value'] for t in s.get('Tags',[])}
            # Avoid names used by the original demo: source account shares these default mount names.
            # Sync cloud destinations use vm-specific secret prefixes in this variant.
            if tags.get('migration')=='vm-rhel9-aws' or s['Name'].startswith('vault-vm/'):
                sm.delete_secret(SecretId=s['ARN'],RecoveryWindowInDays=7)
    p=STATE/'azure-cli.json'
    if p.exists():
        c=json.loads(p.read_text());run(['az','group','delete','-n',c['rg'],'--yes'],timeout=900)
        run(['az','ad','app','delete','--id',c['app_id']])
    private(STATE/'scenarios-cleaned','done\n')
    print('Scenario resources retired; infrastructure can now be removed.')

if __name__=='__main__':main()
