"""Check the exact native payload and artifact-bound validation evidence."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import sys

from verify_models import ROOT, MANIFEST, verify


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_bundle(bundle, evidence=True):
    bundle = Path(bundle).resolve()
    resources = bundle / 'Contents/Resources'
    for path in bundle.rglob('*'):
        if path.is_symlink():
            raise RuntimeError(f'Symlink in native bundle: {path}')
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    identity = {'CFBundleIdentifier': 'local.textpicker', 'CFBundleName': 'TextPicker',
                'CFBundleDisplayName': 'TextPicker', 'CFBundleExecutable': 'TextPicker',
                'CFBundleIconFile': 'TextPicker'}
    if any(info.get(key) != value for key, value in identity.items()):
        raise RuntimeError('App identity does not match TextPicker')
    if 'TextPickerEngines' in info:
        raise RuntimeError('Obsolete engine profile in native app')
    artwork = json.loads((ROOT / 'app/Assets/icon.json').read_text())['files']
    if sha(resources / 'TextPicker.icns') != artwork['TextPicker.icns']:
        raise RuntimeError('App icon differs from the approved Contour hug Medium artwork')
    verify(resources)
    expected = {'models', 'Licenses', 'TextPicker.icns'}
    if evidence:
        expected.add('native-validation.json')
    actual = {p.name for p in resources.iterdir()}
    if actual != expected:
        raise RuntimeError(f'Unexpected app resources: extra={actual-expected}, missing={expected-actual}')
    if {p.name for p in (bundle / 'Contents/MacOS').iterdir()} != {'TextPicker', 'TextPickerNative'}:
        raise RuntimeError('Unexpected executable inventory')
    notices = {p.name: sha(p) for p in (ROOT / 'licenses').iterdir() if p.suffix in ('.txt', '.md')}
    bundled_notices = {p.name: sha(p) for p in (resources / 'Licenses').iterdir() if p.is_file()}
    if bundled_notices != notices or {p.name for p in (resources / 'Licenses').iterdir()} != set(notices):
        raise RuntimeError('Third-party notices differ')
    if evidence:
        report = json.loads((resources / 'native-validation.json').read_text())
        worker_hash = sha(bundle / 'Contents/MacOS/TextPickerNative')
        if report['worker_sha256'] != worker_hash or report['build']['worker_sha256'] != worker_hash:
            raise RuntimeError('Native worker evidence does not match bundled code')
        if report['models'] != json.loads(MANIFEST.read_text())['files']:
            raise RuntimeError('Native model evidence differs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--without-evidence', action='store_true')
    parser.add_argument('--release', action='store_true')
    args = parser.parse_args()
    if args.release and args.without_evidence:
        parser.error('Release checks require evidence')
    verify_bundle(args.bundle, evidence=not args.without_evidence)
    if args.release:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', args.bundle], check=True)
        subprocess.run([sys.executable, '-B', ROOT / 'native/tools/release.py',
                        '--bundle', args.bundle, '--report', args.bundle / 'Contents/Resources/native-validation.json',
                        '--output', ROOT / '.build/reports/installed-native-release.json'], check=True)
    print('PASS: exact native payload and artifact-bound evidence')


if __name__ == '__main__':
    main()
