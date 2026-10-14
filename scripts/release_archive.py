"""Package the qualified app unchanged; publication is a separate draft-only step."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

from verify_bundle import ROOT, verify_bundle


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def release_config(root=ROOT):
    configuration = json.loads((root / '.github/release.json').read_text())
    info = plistlib.loads((root / 'app/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or configuration['tag'] != 'v' + version:
        raise RuntimeError('Release tag and app version must match')
    if (not isinstance(configuration['title'], str) or not configuration['title'].strip()
            or any(c in configuration['title'] for c in '\r\n') or len(configuration['title']) > 120):
        raise RuntimeError('Invalid release title')
    if (configuration['prerelease'] is not False or configuration['signing'] != 'self-signed'
            or not re.fullmatch(r'[0-9a-f]{64}', str(configuration.get('certificate_sha256')))):
        raise RuntimeError('Releases must be self-signed with the pinned certificate')
    if not (root / '.github/RELEASE.md').read_text().strip():
        raise RuntimeError('Release notes must be explicitly supplied')
    return configuration, info


def signing_certificate(path):
    """SHA-256 of the leaf signing certificate, or None for an ad-hoc signature."""
    with tempfile.TemporaryDirectory(prefix='textpicker-certificate-') as folder:
        run('codesign', '-d', f'--extract-certificates={folder}/certificate', path, capture_output=True)
        leaf = Path(folder) / 'certificate0'
        return hashlib.sha256(leaf.read_bytes()).hexdigest() if leaf.exists() else None


def inventory(bundle):
    return {str(path.relative_to(bundle)): (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o777)
            for path in bundle.rglob('*') if path.is_file()}


def make_archive(bundle, destination):
    if destination.exists():
        raise RuntimeError('Refusing to overwrite a release archive')
    before = inventory(bundle)
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', bundle, destination)
    with tempfile.TemporaryDirectory(prefix='textpicker-release-check-') as folder:
        run('ditto', '-x', '-k', destination, folder)
        restored = Path(folder) / 'TextPicker.app'
        if inventory(restored) != before:
            raise RuntimeError('Archive round-trip changed app bytes or executable permissions')
        verify_bundle(restored)
        run('codesign', '--verify', '--deep', '--strict', restored)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-tag', help='Validate release metadata without producing an archive')
    options = parser.parse_args()
    config, info = release_config()
    if options.check_tag:
        if options.check_tag != config['tag']:
            parser.error('Requested tag does not match the reviewed release configuration')
        print('PASS: release tag, version, signing policy and explicit notes agree')
        return
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        raise RuntimeError('Release archives require a clean committed tree')
    bundle = ROOT / '.build/apps/TextPicker.app'
    actual_info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if actual_info != info:
        raise RuntimeError('Built app version/metadata differs from release sources')
    run(sys.executable, '-B', ROOT / 'scripts/verify_bundle.py', bundle, '--release')
    for executable in ('TextPicker', 'TextPickerNative'):
        path = bundle / 'Contents/MacOS' / executable
        architecture = subprocess.check_output(['lipo', '-archs', path], text=True).strip()
        if architecture != 'arm64':
            raise RuntimeError('Release requires Apple Silicon executables')
    # The helper keeps its tested ad-hoc identity; only the app is certificate-signed.
    if signing_certificate(bundle / 'Contents/MacOS/TextPickerNative') is not None:
        raise RuntimeError('The OCR helper must keep its validated ad-hoc signature')
    certificate = signing_certificate(bundle)
    if certificate is not None and certificate != config['certificate_sha256']:
        raise RuntimeError('App is signed with an unexpected certificate')
    destination = ROOT / '.build/dist'
    destination.mkdir(parents=True, exist_ok=True)
    if list(destination.iterdir()):
        raise RuntimeError('Release output directory must be empty')
    archive = destination / f'TextPicker-{info["CFBundleShortVersionString"]}-arm64.zip'
    make_archive(bundle, archive)
    metadata = {
        'tag': config['tag'], 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'architecture': 'arm64', 'deployment_target': info['LSMinimumSystemVersion'],
        'signing': 'self-signed' if certificate else 'ad-hoc', 'certificate_sha256': certificate,
        'notarized': False,
        'model_pack_sha256': json.loads((ROOT / 'native/models/distribution.json').read_text())['archive_sha256'],
        'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'worker_sha256': hashlib.sha256((bundle / 'Contents/MacOS/TextPickerNative').read_bytes()).hexdigest(),
        'builder_os': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
    }
    (destination / 'release-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    files = sorted(destination.iterdir())
    (destination / 'SHA256SUMS.txt').write_text(''.join(
        f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in files))
    print('PASS: qualified app archived unchanged:', archive)


if __name__ == '__main__':
    main()
