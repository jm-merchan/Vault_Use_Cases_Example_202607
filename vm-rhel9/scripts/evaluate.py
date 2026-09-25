#!/usr/bin/env python3
"""Run every requested notebook; retain executed copies and truthful statuses."""
import argparse,datetime,json,os,sys,time,traceback
from pathlib import Path
import nbformat
from nbclient import NotebookClient
ROOT=Path(__file__).resolve().parents[1]
os.umask(0o077)
os.environ['JUPYTER_PATH']=str(ROOT/'.venv/share/jupyter')
p=argparse.ArgumentParser();p.add_argument('names',nargs='*');p.add_argument('--retry-failed',action='store_true');a=p.parse_args()
manifest=json.loads((ROOT/'scenario-map.json').read_text())
report_path=ROOT/'reports/results.json'
reports=json.loads(report_path.read_text()) if report_path.exists() else {}
for entry in manifest:
    name=entry['source']
    if a.names and name not in a.names and Path(name).stem not in a.names:continue
    nb=nbformat.read(ROOT/entry['vm_notebook'],as_version=4)
    if a.retry_failed and reports.get(name,{}).get('status')=='passed':
        executed_path=ROOT/reports[name]['executed_copy']
        if executed_path.exists():
            old=nbformat.read(executed_path,as_version=4)
            code=lambda doc:[c.source for c in doc.cells if c.cell_type=='code']
            if code(old)==code(nb):continue
        print('SOURCE CHANGED',name,flush=True)
    start=time.time();status='passed';error=''
    print('RUN',name,flush=True)
    try:
        NotebookClient(nb,timeout=2400,kernel_name='vm-rhel9-poc',resources={'metadata':{'path':str(ROOT/'notebooks')}},allow_errors=False,on_cell_start=lambda cell,cell_index: print('  CELL',cell_index,flush=True) if cell.cell_type=='code' else None).execute()
    except Exception as exc:
        status='blocked' if 'Blocked:' in str(exc) else 'failed'
        # Full notebook stays private. Share only concise error type and message.
        errors=[o for c in nb.cells if c.cell_type=='code' for o in c.get('outputs',[]) if o.get('output_type')=='error']
        error=(errors[-1]['ename']+': '+errors[-1]['evalue']) if errors else type(exc).__name__
        if errors and errors[-1]['ename']=='CalledProcessError':
            index=next(i for i,c in enumerate(nb.cells) if any(o.get('output_type')=='error' for o in c.get('outputs',[])))
            error=f'Bash cell {index} failed; details in private executed notebook'
        print(status.upper(),name,error[:500],flush=True)
    target=ROOT/'reports'/(Path(name).stem+'.executed.ipynb');nbformat.write(nb,target);os.chmod(target,0o600)
    reports[name]={'status':status,'implementation':'bash-cli','error':error,'seconds':round(time.time()-start,1),'evaluated_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'executed_copy':str(target.relative_to(ROOT))}
    import fcntl
    with (ROOT/'reports/.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        latest=json.loads(report_path.read_text()) if report_path.exists() else {}
        latest[name]=reports[name]
        report_path.write_text(json.dumps(latest,indent=2,ensure_ascii=False)+'\n')
        reports=latest
    print(status.upper(),name,flush=True)
    if name=='1_Deploy_Vault_AWS.ipynb' and status!='passed':
        print('Stopping dependent scenarios because deployment failed',flush=True)
        break
print(json.dumps({s:sum(x['status']==s for x in reports.values()) for s in ['passed','failed','blocked']},indent=2))
import subprocess
subprocess.run([sys.executable,str(ROOT/'scripts/report.py')],check=True)
sys.exit(1 if any(x['status']!='passed' for x in reports.values()) else 0)
