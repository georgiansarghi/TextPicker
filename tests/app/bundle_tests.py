"""Reject unexpected native payloads, stale evidence and invalid model imports."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import prepare_models
from verify_bundle import verify_bundle
from verify_models import verify_directory

checks = 0


def rejects(action, message):
    global checks
    try:
        action()
    except RuntimeError as error:
        assert message in str(error), error
        checks += 1
    else:
        raise AssertionError('Invalid payload was accepted')


source = Path(sys.argv[1]).resolve()
verify_bundle(source)
with tempfile.TemporaryDirectory(prefix='textpicker-bundle-tests-') as folder:
    folder = Path(folder)
    bundle = folder / 'TextPicker.app'
    subprocess.run(['/bin/cp', '-cR', source, bundle], check=True)
    resources = bundle / 'Contents/Resources'
    for name in ['unexpected-runtime', 'python', 'libTextPickerCoreML.dylib', 'coreml_backend.py', 'worker.py']:
        extra = resources / name
        extra.write_text('synthetic extra payload')
        rejects(lambda: verify_bundle(bundle), 'Unexpected app resources')
        extra.unlink()
    extra = resources / 'models/unused'
    extra.mkdir()
    rejects(lambda: verify_bundle(bundle), 'Unexpected model directory')
    extra.rmdir()
    extra = bundle / 'Contents/MacOS/UnusedWorker'
    extra.touch()
    rejects(lambda: verify_bundle(bundle), 'Unexpected executable inventory')
    extra.unlink()
    extra = resources / 'Licenses/extra.txt'
    extra.touch()
    rejects(lambda: verify_bundle(bundle), 'Third-party notices differ')
    extra.unlink()
    extra = resources / 'external-link'
    extra.symlink_to('/etc/hosts')
    rejects(lambda: verify_bundle(bundle), 'Symlink in native bundle')
    extra.unlink()
    info_path = bundle / 'Contents/Info.plist'
    original = info_path.read_bytes()
    info = plistlib.loads(original)
    info['TextPickerEngines'] = ['native-cpu']
    info_path.write_bytes(plistlib.dumps(info))
    rejects(lambda: verify_bundle(bundle), 'Obsolete engine profile')
    info_path.write_bytes(original)
    report_path = resources / 'native-validation.json'
    original = report_path.read_bytes()
    report = json.loads(original)
    report['worker_sha256'] = '0' * 64
    report_path.write_text(json.dumps(report))
    rejects(lambda: verify_bundle(bundle), 'Native worker evidence')
    report_path.write_bytes(original)
    asset = resources / 'models/native/detector.weights'
    with asset.open('r+b') as stream:
        original_byte = stream.read(1)
        stream.seek(0)
        stream.write(bytes([original_byte[0] ^ 1]))
    rejects(lambda: verify_bundle(bundle), 'Model fingerprints differ')
    with asset.open('r+b') as stream:
        stream.write(original_byte)
    verify_bundle(bundle)

    # Import into an isolated build root, never the checkout's existing assets.
    def import_models(*arguments):
        with patch.object(prepare_models, 'ROOT', folder / 'checkout'), \
             patch.object(sys, 'argv', ['prepare_models.py', *map(str, arguments)]), \
             contextlib.redirect_stdout(io.StringIO()):
            prepare_models.main()

    import_models('--from-app', source)
    imported = folder / 'checkout/.build/models/native'
    verify_directory(imported)
    checks += 1
    import_models('--from-directory', resources / 'models/native')
    checks += 1  # Valid existing inputs are idempotent.
    (imported / 'extra').touch()
    rejects(lambda: import_models('--from-app', source), 'Model fingerprints differ')
    (imported / 'extra').unlink()
    shutil.rmtree(imported)
    (resources / 'models/native/extra').touch()
    rejects(lambda: import_models('--from-directory', resources / 'models/native'), 'Model fingerprints differ')
    assert not imported.exists(), 'Bad source must not create destination assets'
print(f'PASS: {checks} native payload, evidence and model-import checks')
