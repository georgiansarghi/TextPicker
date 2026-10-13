"""Product identity, approved artwork and obsolete-brand regression checks.

Scans active first-party source and every file in the supplied app bundle.
Generated build outputs and Git history are excluded from the source scan.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from verify_bundle import verify_bundle

# Also catches previous identifier spellings with spaces, underscores or hyphens.
OBSOLETE = re.compile(rb'text[\s_-]*ocr', re.I)
EXTENSIONS = {'.py', '.swift', '.md', '.sh', '.plist', '.txt', '.cpp', '.hpp', '.h', '.json', '.svg', '.html'}


def active_sources():
    files = [ROOT / 'README.md', ROOT / '.gitignore']
    for directory in ('app', 'native'):
        files += [p for p in (ROOT / directory).iterdir() if p.is_file() and p.suffix in EXTENSIONS]
    for directory in ('app/Sources', 'app/Assets', 'native/src', 'native/worker',
                      'native/tools', 'native/tests', 'native/models', 'scripts', 'tests', 'docs'):
        files += [p for p in (ROOT / directory).rglob('*')
                  if p.is_file() and not p.is_symlink() and '__pycache__' not in p.parts and p.suffix in EXTENSIONS]
    return sorted(set(files))


def assert_clean(paths, root):
    hits = []
    for path in paths:
        if OBSOLETE.search(str(path.relative_to(root)).encode()) or OBSOLETE.search(path.read_bytes()):
            hits.append(str(path.relative_to(root)))
    if hits:
        raise AssertionError('Obsolete branding remains: ' + ', '.join(hits))


def main():
    source = Path(sys.argv[1]).resolve()
    files = active_sources()
    assert_clean(files, ROOT)
    contents = [p for p in source.rglob('*') if p.is_file() and not p.is_symlink()]
    assert_clean(contents, source)
    verify_bundle(source)
    assets = ROOT / 'app/Assets'
    artwork = json.loads((assets / 'icon.json').read_text())
    assert artwork['name'] == 'TextPicker' and artwork['variant'] == 'Contour hug / Medium'
    assert artwork['inner_mark_scale'] == 1.76
    assert artwork['palette'] == 'Midnight' and artwork['contour_width'] == 48
    for name, digest in artwork['files'].items():
        assert hashlib.sha256((assets / name).read_bytes()).hexdigest() == digest
    # Canonical assets are the source of truth, not a duplicate design gallery.
    # Pin the selected artwork independently of the editable asset manifest.
    assert artwork['files'] == {
        'TextPicker.svg': '9fdfa094b7eecd59afa6004d4ce70448022bc678308844abf6a9821de337bc4e',
        'TextPicker.png': 'c7e59e506ec3c627b0168b665502d16c3274d4fa7ab6e6c031f5dc8b74fd150c',
        'TextPicker.icns': '2e2a7aa52282a5d285806d227967cb6a84fab633c80b14d579f399b71819c2a0',
    }
    with tempfile.TemporaryDirectory(prefix='textpicker-branding-tests-') as temporary:
        bundle = Path(temporary) / 'TextPicker.app'
        subprocess.run(['/bin/cp', '-cR', source, bundle], check=True)
        info_path = bundle / 'Contents/Info.plist'
        original = info_path.read_bytes()
        for key in ('CFBundleIdentifier', 'CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable', 'CFBundleIconFile'):
            info = plistlib.loads(original)
            info[key] = 'UnrelatedName'
            info_path.write_bytes(plistlib.dumps(info))
            try:
                verify_bundle(bundle)
            except RuntimeError as error:
                assert 'identity' in str(error)
            else:
                raise AssertionError(f'Invalid {key} accepted')
        info_path.write_bytes(original)
        (bundle / 'Contents/Resources/TextPicker.icns').write_bytes(b'incorrect artwork')
        try:
            verify_bundle(bundle)
        except RuntimeError as error:
            assert 'Contour hug Medium' in str(error)
        else:
            raise AssertionError('Wrong artwork accepted')
    print(f'PASS: {len(files)} active sources and {len(contents)} bundled files have no obsolete branding; '
          'approved Contour hug Medium artwork, identity and six tamper rejections verified')


if __name__ == '__main__':
    main()
