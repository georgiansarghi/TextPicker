"""Measure app-bundle bytes; exclude development inputs and rollback copies."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--previous', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()

def logical(path):
    return sum(p.lstat().st_size for p in path.rglob('*') if p.is_file() or p.is_symlink())

def measure(path):
    path = path.resolve()
    allocated = int(subprocess.check_output(['/usr/bin/du','-sk',str(path)],text=True).split()[0])*1024
    return {'path':str(path), 'allocated_bytes':allocated, 'allocated_mib':allocated/1024**2,
            'logical_bytes_including_symlinks':logical(path)}

app = args.app.resolve()
res = app/'Contents/Resources'
components = {'native_models': logical(res/'models/native'),
              'native_worker': (app/'Contents/MacOS/TextPickerNative').stat().st_size}
components['app_icon_notices_and_evidence'] = logical(app)-sum(components.values())
report = {'current':measure(app), 'components_logical_bytes':components,
          'scope':'App bundle only; no system frameworks, runtime caches, research files or rollback copies. No compressed download-size claim.'}
if args.previous:
    report['previous'] = measure(args.previous)
    report['allocated_reduction_percent'] = 100*(1-report['current']['allocated_bytes']/report['previous']['allocated_bytes'])
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
