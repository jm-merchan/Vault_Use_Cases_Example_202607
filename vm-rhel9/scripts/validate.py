"""Offline checks complement (never replace) live notebook execution."""
import ast,json,subprocess,sys
from pathlib import Path
import nbformat
ROOT=Path(__file__).resolve().parents[1]
errors=[]
source={p.name for p in ROOT.parent.glob('*.ipynb')}
ports={p.name for p in (ROOT/'notebooks').glob('*.ipynb')}
if source!=ports:errors.append('Notebook coverage mismatch: '+str(source^ports))
for path in (ROOT/'scripts').glob('*.py'):
    try:ast.parse(path.read_text(),filename=str(path))
    except SyntaxError as e:errors.append(str(e))
for path in (ROOT/'notebooks').glob('*.ipynb'):
    nb=nbformat.read(path,as_version=4);nbformat.validate(nb)
    for i,c in enumerate(nb.cells):
        if c.cell_type=='code':
            try:
                if not c.source.startswith('%%bash\n'):raise SyntaxError('Scenario cell must use %%bash')
                shell=c.source.split('\n',1)[1]
                result=subprocess.run(['bash','-n'],input=shell,text=True,capture_output=True)
                if result.returncode:raise SyntaxError(result.stderr)
                if 'import ' in shell and 'python' in shell:raise SyntaxError('Python scenario logic is not allowed')
            except SyntaxError as e:errors.append(f'{path.name}:{i}: {e}')
            if c.get('outputs'):errors.append(f'{path.name}: source notebook contains output')
for path in (ROOT/'terraform').iterdir():
    if path.is_dir():
        p=subprocess.run(['terraform',f'-chdir={path}','fmt','-check'],capture_output=True,text=True)
        if p.returncode:errors.append('Terraform formatting: '+path.name)
for path in list((ROOT/'scripts').glob('*')) + list((ROOT/'terraform').glob('*/.terraform.lock.hcl')):
    if not path.is_file(): continue
    ignored=subprocess.run(['git','check-ignore','-q',str(path)])
    if ignored.returncode==0:errors.append('Required implementation file is gitignored: '+str(path.relative_to(ROOT)))
result={'source_notebooks':len(source),'vm_notebooks':len(ports),'status':'failed' if errors else 'passed','errors':errors,'scope':'Offline notebook schema, syntax, coverage and Terraform formatting only'}
(ROOT/'reports/static-validation.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2));sys.exit(bool(errors))
