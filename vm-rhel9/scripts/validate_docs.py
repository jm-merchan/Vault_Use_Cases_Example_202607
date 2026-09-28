#!/usr/bin/env python3
"""Offline documentation audit. Never execute snippets or contact cloud services."""
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

import nbformat
import yaml

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
errors = []
counts = dict(markdown_files=0, notebooks=0, notebook_bash_cells=0,
              documented_bash_blocks=0, structured_blocks=0, shell_files=0,
              local_links=0, historical_code_matches=0)
external = set()
documents = {}


def issue(path, detail):
    errors.append(f'{path.relative_to(REPO)}: {detail}')


def bash_check(path, body, label):
    checked = subprocess.run(['bash', '-n'], input=body, text=True, capture_output=True)
    if checked.returncode:
        issue(path, f'{label}: {checked.stderr.strip()}')


def code(nb):
    return [c.source for c in nb.cells if c.cell_type == 'code']


markdown = [REPO/'README.md', REPO/'vault-logrotate-master/README.md']
markdown += list(ROOT.glob('*.md')) + list(ROOT.glob('aap/*.md'))
markdown += list(ROOT.glob('load-balancing/*.md')) + list(ROOT.glob('reports/*.md'))
for path in sorted(set(markdown)):
    documents[path] = path.read_text()
    counts['markdown_files'] += 1

notebooks = sorted(list(ROOT.glob('notebooks/*.ipynb')) +
                   list(ROOT.glob('aap/*.ipynb')) + list(ROOT.glob('load-balancing/*.ipynb')))
for path in notebooks:
    nb = nbformat.read(path, as_version=4)
    nbformat.validate(nb)
    documents[path] = '\n\n'.join(c.source for c in nb.cells if c.cell_type == 'markdown')
    counts['notebooks'] += 1
    for index, cell in enumerate(nb.cells):
        if cell.cell_type != 'code':
            continue
        if not cell.source.startswith('%%bash\n'):
            issue(path, f'cell {index} must use %%bash')
            continue
        counts['notebook_bash_cells'] += 1
        bash_check(path, cell.source.split('\n', 1)[1], f'cell {index}')
    if path.parent.name == 'notebooks':
        executed = ROOT/'reports'/f'{path.stem}.executed.ipynb'
        if executed.exists():
            if code(nb) != code(nbformat.read(executed, as_version=4)):
                issue(path, 'operational code differs from historical executed copy')
            else:
                counts['historical_code_matches'] += 1
        script = ROOT/'notebook_sources'/f'{path.stem}.sh'
        if not script.exists():
            issue(path, 'equivalent Bash source missing')
        elif any(c.split('\n', 1)[1].strip() not in script.read_text() for c in code(nb)):
            issue(path, 'Bash source does not contain the notebook commands')

fences = re.compile(r'^\s*```([^\n]*)\n(.*?)^\s*```\s*$', re.M | re.S)
links = re.compile(r'\[[^\]\n]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)')


def heading_ids(text):
    ids = set()
    used = {}
    for title in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', text, re.M):
        slug = re.sub(r'[^\w\- ]', '', title.lower()).replace(' ', '-')
        suffix = used.get(slug, 0)
        used[slug] = suffix + 1
        ids.add(slug if not suffix else f'{slug}-{suffix}')
    return ids


for path, document in documents.items():
    for lang, body in fences.findall(document):
        lang = lang.strip().lower()
        if lang in {'bash', 'sh', 'shell'}:
            counts['documented_bash_blocks'] += 1
            bash_check(path, body, 'documented Bash block')
        elif lang in {'json', 'yaml', 'yml'}:
            counts['structured_blocks'] += 1
            try:
                json.loads(body) if lang == 'json' else list(yaml.safe_load_all(body))
            except (ValueError, yaml.YAMLError) as exc:
                issue(path, f'invalid {lang} block: {exc}')
    for target in links.findall(fences.sub('', document)):
        url = urlsplit(target.strip('<>'))
        if url.scheme in {'http', 'https'}:
            external.add(target)
            continue
        if url.scheme:
            continue
        counts['local_links'] += 1
        destination = (path.parent/unquote(url.path)).resolve() if url.path else path.resolve()
        if not destination.exists():
            issue(path, f'broken local link: {target}')
            continue
        if destination.is_file():
            ignored = subprocess.run(['git', 'check-ignore', '-q', str(destination)], cwd=REPO)
            if ignored.returncode == 0:
                issue(path, f'link points to ignored file, unavailable in a clone: {target}')
        if url.fragment and destination.suffix == '.md':
            if unquote(url.fragment) not in heading_ids(destination.read_text()):
                issue(path, f'unknown Markdown heading: {target}')

for folder in ['scripts', 'notebook_sources', 'aap', 'load-balancing']:
    for path in sorted((ROOT/folder).glob('*.sh')):
        counts['shell_files'] += 1
        bash_check(path, path.read_text(), 'shell file')

manifest = json.loads((ROOT/'scenario-map.json').read_text())
if {Path(x['vm_notebook']).name for x in manifest} != {p.name for p in ROOT.glob('notebooks/*.ipynb')}:
    errors.append('Manifest and main notebook coverage differ')
if len(notebooks) != len(manifest) + 3:
    errors.append('Expected three additional notebooks (AAP and load balancing)')

report = {
    'validated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'status': 'failed' if errors else 'passed',
    'scope': 'Offline documentation, local links, syntax and historical code comparison only; no deployment or live evaluation',
    'counts': counts,
    'external_links': sorted(external),
    'external_links_scope': 'Collected only; network verification is separate from this offline validator',
    'errors': errors,
}
(ROOT/'reports/documentation-validation.json').write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')
print(json.dumps({k: v for k, v in report.items() if k != 'external_links'}, indent=2, ensure_ascii=False))
sys.exit(bool(errors))
