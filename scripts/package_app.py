"""Build and qualify a fresh native TextPicker app."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from verify_bundle import verify_bundle
from verify_models import ROOT, MANIFEST, verify_directory

BUILD = ROOT / '.build/apps'
PYTHON = ROOT / '.venv/bin/python'


def run(*args):
    subprocess.run([str(v) for v in args], cwd=ROOT, check=True)


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    destination = BUILD / 'TextPicker.app'
    if destination.is_symlink():
        parser.error('Refusing a symlink build destination')
    models = ROOT / '.build/models/native'
    if not models.is_dir():
        parser.error('Missing native model assets; see docs/BUILDING.md')
    verify_directory(models)
    BUILD.mkdir(parents=True, exist_ok=True)
    evidence = ROOT / '.build/reports'
    evidence.mkdir(parents=True, exist_ok=True)
    run('env', f'PYTHON={PYTHON}', 'bash', ROOT / 'native/build.sh')
    with tempfile.TemporaryDirectory(prefix='stage.', dir=BUILD) as temporary:
        bundle = Path(temporary) / 'TextPicker.app'
        resources = bundle / 'Contents/Resources'
        macos = bundle / 'Contents/MacOS'
        macos.mkdir(parents=True)
        (resources / 'Licenses').mkdir(parents=True)
        info = plistlib.loads((ROOT / 'app/Info.plist').read_bytes())
        copy(ROOT / 'app/Info.plist', bundle / 'Contents/Info.plist')
        run('swiftc', '-O', '-warnings-as-errors', '-swift-version', '5', '-target', 'arm64-apple-macos14.0',
            '-file-prefix-map', f'{ROOT}=/TextPicker',
            *sorted((ROOT / 'app/Sources').glob('*.swift')), '-o', macos / 'TextPicker',
            '-framework', 'AppKit', '-framework', 'ApplicationServices', '-framework', 'ScreenCaptureKit',
            '-framework', 'Carbon', '-framework', 'ServiceManagement')
        copy(ROOT / '.build/native/TextPickerNative', macos / 'TextPickerNative')
        for name in json.loads(MANIFEST.read_text())['files']:
            copy(models / name, resources / 'models/native' / name)
        copy(ROOT / 'app/Assets/TextPicker.icns', resources / 'TextPicker.icns')
        for notice in (ROOT / 'licenses').iterdir():
            if notice.suffix in ('.txt', '.md'):
                copy(notice, resources / 'Licenses' / notice.name)
        verify_bundle(bundle, evidence=False)
        # Never deep-sign: preserve the helper's tested artifact identity.
        run('codesign', '--verify', '--strict', macos / 'TextPickerNative')
        run('codesign', '--force', '--sign', '-', '--identifier', info['CFBundleIdentifier'], bundle)
        report = evidence / 'native-validation.json'
        run('bash', ROOT / 'native/test.sh', '--skip-build', '--bundle', bundle, '--output', report)
        run(PYTHON, '-B', ROOT / 'native/tools/release.py', '--bundle', bundle, '--report', report)
        copy(report, resources / 'native-validation.json')
        # Seal evidence into the enclosing app without re-signing the helper.
        run('codesign', '--force', '--sign', '-', '--identifier', info['CFBundleIdentifier'], bundle)
        run('codesign', '--verify', '--deep', '--strict', bundle)
        verify_bundle(bundle)
        if destination.exists():
            shutil.rmtree(destination)  # Only the canonical generated bundle.
        bundle.rename(destination)
    print('Built:', destination, flush=True)
    run('du', '-sh', destination)
    if args.install:
        run('bash', ROOT / 'scripts/install.sh', destination)


if __name__ == '__main__':
    main()
