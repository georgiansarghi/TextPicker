"""Verify the exact native model inventory, without downloads or conversion."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'native/models/manifest.json'


def verify_directory(directory):
    expected = json.loads(MANIFEST.read_text())['files']
    if directory.is_symlink() or any(p.is_symlink() for p in directory.rglob('*')):
        raise RuntimeError('Symlink model assets are not permitted')
    actual = {
        str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in directory.rglob('*') if path.is_file()
    }
    if actual != expected or {p.name for p in directory.iterdir()} != set(expected):
        raise RuntimeError('Model fingerprints differ; restore the validated native assets')


def verify(resources):
    models = resources / 'models'
    if {p.name for p in models.iterdir()} != {'native'}:
        raise RuntimeError('Unexpected model directory')
    verify_directory(models / 'native')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
    print('Verified native model inventory')
