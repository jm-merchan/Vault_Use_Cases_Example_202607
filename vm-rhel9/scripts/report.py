"""Render a concise report from actual evaluation results, including failures."""
import datetime,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
manifest=json.loads((ROOT/'scenario-map.json').read_text())
results=json.loads((ROOT/'reports/results.json').read_text())
counts={s:sum(r['status']==s for r in results.values()) for s in ['passed','failed','blocked']}
lines=['# Evaluación de la variante RHEL 9','',f'Informe generado: {datetime.datetime.now(datetime.timezone.utc).isoformat()}','',
       f"{counts['passed']} correctos, {counts['failed']} fallidos, {counts['blocked']} bloqueados; {len(manifest)-len(results)} pendientes.",'',
       'Cada estado procede de ejecutar el notebook completo con nbclient: celdas %%bash, comandos CLI y comprobaciones activas. La implementación evaluada se registra como bash-cli en results.json. La validación estática se registra por separado.','',
       '| Notebook | Resultado | Duración (s) |','|---|---|---|']
for item in manifest:
    r=results.get(item['source'],{})
    lines.append(f"| [{item['source']}](../{item['vm_notebook']}) | {r.get('status','pending')} | {r.get('seconds','—')} |")
    if r.get('error'):lines.append(f"\nError de `{item['source']}`: {r['error']}\n")
lines+=['','## Alcance de la adaptación','',
        '- Diez VMs RHEL 9: seis primarias, tres secundarias y una de aplicación. Servicios auxiliares en el EKS existente.',
        '- NLB TCP y certificados Let’s Encrypt instalados directamente en Vault; API 443/8200 y PR 8201. Pruebas adicionales: [NLB/PR y cert auth](../load-balancing/17_NLB_LetsEncrypt_PR.ipynb), [doble FQDN](../load-balancing/16_Dual_FQDN.ipynb) y [AAP](../aap/15_AAP_Vault_AppRole_OIDC.ipynb).',
        '- El caso originalmente estático de AWS usa ahora un rol dedicado, según la instrucción del usuario. No se crean usuarios IAM.',
        '- El complemento llamado OpenShift verifica las dos modalidades JWT/VSO en el EKS disponible. No acredita una ejecución de SCC en OpenShift.',
        '- Estado, tokens, certificados privados y copias ejecutadas se guardan localmente y se excluyen de Git.',
        '- Los recursos permanecen desplegados para continuar la demo.']
for name in ['read','engine']:
    p=ROOT/'.state'/('github-'+name+'.json')
    if p.exists():
        r=json.loads(p.read_text());lines.append(f"- GitHub {name}: [ejecución real]({r['url']}).")
(ROOT/'reports/EVALUATION.md').write_text('\n'.join(lines)+'\n')
sources=list((ROOT/'notebooks').glob('*.ipynb'))+list((ROOT/'notebook_sources').glob('*.sh'))+list((ROOT/'scripts').glob('*.py'))+list((ROOT/'scripts').glob('*.sh'))+list((ROOT/'scripts').glob('*.tftpl'))+list((ROOT/'terraform').glob('*/*.tf'))+list((ROOT/'assets').rglob('*.yaml'))+list((ROOT/'assets').glob('*.json'))+list((ROOT/'assets').glob('*.hcl'))+list((ROOT/'workflows').glob('*.yml'))+list((ROOT/'load-balancing').glob('*.sh'))+list((ROOT/'load-balancing').glob('*.ipynb'))+list((ROOT/'aap').glob('*.sh'))+list((ROOT/'aap').glob('*.ipynb'))
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)}
(ROOT/'reports/source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
print(json.dumps(counts))
# Access instructions always follow the current Terraform inventory, never stale IPs.
inventory_path=ROOT/'.state/infrastructure.json'
if inventory_path.exists():
    inventory=json.loads(inventory_path.read_text())
    access=['# Acceso a la variante VM','',
            'Vault: '+inventory['vault_address']+'/ui/','',
            'Aplicaciones: '+inventory.get('vault_application_address','pendiente de desplegar')+' (activo y performance standbys).','',
            'Login: método Token, namespace vacío (root). El token vigente está en `.state/primary-init.json`.','',
            'Desde `vm-rhel9`, copiarlo al portapapeles de macOS sin imprimirlo:','',
            '```bash',"jq -r '.root_token' .state/primary-init.json | pbcopy",'```','',
            'SSH: usuario `ec2-user`, clave `.state/id_ed25519`; usar `sudo -i` dentro de la VM.','',
            '| Nodo | IP pública | Comando desde vm-rhel9 |','|---|---|---|']
    for name,node in inventory['nodes'].items():
        access.append(f"| {name} | {node['public_ip']} | `ssh -i .state/id_ed25519 ec2-user@{node['public_ip']}` |")
    access+=['','SSH está limitado a la IP pública del operador registrada en el despliegue.',
             '', 'Durante la conversión a Bash se sustituyeron accidentalmente las diez VMs al cambiar el orden de subredes. Estas son las IP posteriores a esa sustitución; el token de bootstrap también se regeneró. El notebook de despliegue conserva ahora el orden registrado y bloquea planes con destrucciones o sustituciones.']
    (ROOT/'reports/ACCESS.md').write_text('\n'.join(access)+'\n')
