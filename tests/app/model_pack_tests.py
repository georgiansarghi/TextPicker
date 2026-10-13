"""Model bootstrap tests: synthetic assets and injected HTTP, never real downloads."""
import contextlib
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import model_pack
import verify_models


class ModelPackTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix='textpicker-model-test-')))
        self.source = self.root / 'source'
        self.source.mkdir()
        files = {}
        for name in ('detector.weights', 'recognizer.weights', 'characters.bin'):
            data = ('synthetic ' + name).encode()
            (self.source / name).write_bytes(data)
            files[name] = hashlib.sha256(data).hexdigest()
        manifest = self.root / 'native/models/manifest.json'
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'files': files}))
        license = self.root / 'licenses/PaddleOCR-Apache-2.0.txt'
        license.parent.mkdir()
        license.write_text('Synthetic license fixture')
        self.stack.enter_context(patch.object(model_pack, 'ROOT', self.root))
        self.stack.enter_context(patch.object(model_pack, 'MANIFEST', manifest))
        self.stack.enter_context(patch.object(verify_models, 'MANIFEST', manifest))
        self.stack.enter_context(patch.dict(os.environ, {'OFFLINE': '0'}))
        self.pack = self.root / 'source.tar.gz'
        record = model_pack.write_pack(self.source, self.pack)
        self.specification = {'schema': 1, 'asset': 'models.tar.gz',
                              'url': 'https://github.com/georgiansarghi/TextPicker/releases/download/models-v1/models.tar.gz', **record}
        self.save_specification()
        self.destination = self.root / '.build/models/native'
        self.cache = self.root / '.build/downloads/models.tar.gz'

    def save_specification(self):
        (self.root / 'native/models/distribution.json').write_text(json.dumps(self.specification))

    def seed_cache(self):
        self.cache.parent.mkdir(parents=True)
        shutil.copyfile(self.pack, self.cache)

    def test_deterministic_pack(self):
        other = self.root / 'different-filename.tar.gz'
        os.utime(self.source / 'detector.weights', (123456789, 123456789))
        model_pack.write_pack(self.source, other)
        self.assertEqual(self.pack.read_bytes(), other.read_bytes())
        with self.assertRaisesRegex(RuntimeError, 'overwrite'):
            model_pack.write_pack(self.source, other)

    def test_download_then_warm_and_offline_cache(self):
        with patch.object(model_pack.urllib.request, 'urlopen', return_value=io.BytesIO(self.pack.read_bytes())) as fetch:
            model_pack.ensure_models()
            fetch.assert_called_once()
        verify_models.verify_directory(self.destination)
        with patch.object(model_pack.urllib.request, 'urlopen', side_effect=AssertionError('unexpected network')):
            model_pack.ensure_models()
            shutil.rmtree(self.destination)
            model_pack.ensure_models(offline=True)
        verify_models.verify_directory(self.destination)

    def test_offline_missing_assets(self):
        with patch.object(model_pack.urllib.request, 'urlopen') as fetch:
            with self.assertRaisesRegex(RuntimeError, 'Offline build'):
                model_pack.ensure_models(offline=True)
            with patch.dict(os.environ, {'OFFLINE': '1'}):
                with self.assertRaisesRegex(RuntimeError, 'Offline build'):
                    model_pack.ensure_models()
            fetch.assert_not_called()
        self.assertFalse(self.destination.exists())

    def test_corrupt_cache_never_redownloaded_or_extracted(self):
        self.seed_cache()
        data = bytearray(self.cache.read_bytes())
        data[-1] ^= 1
        self.cache.write_bytes(data)
        with patch.object(model_pack.urllib.request, 'urlopen') as fetch:
            with self.assertRaisesRegex(RuntimeError, 'checksum/size'):
                model_pack.ensure_models()
            fetch.assert_not_called()
        self.assertFalse(self.destination.exists())

    def test_corrupt_existing_assets_never_replaced(self):
        self.destination.parent.mkdir(parents=True)
        shutil.copytree(self.source, self.destination)
        (self.destination / 'characters.bin').write_bytes(b'changed')
        with patch.object(model_pack.urllib.request, 'urlopen') as fetch:
            with self.assertRaisesRegex(RuntimeError, 'fingerprints'):
                model_pack.ensure_models()
            fetch.assert_not_called()
        self.assertEqual((self.destination / 'characters.bin').read_bytes(), b'changed')

    def test_bad_url_and_oversized_download(self):
        self.specification['url'] = 'http://example.invalid/models.tar.gz'
        self.save_specification()
        with self.assertRaisesRegex(RuntimeError, 'pinned HTTPS'):
            model_pack.ensure_models()
        self.specification['url'] = 'https://github.com/georgiansarghi/TextPicker/releases/download/models-v1/models.tar.gz'
        self.specification['archive_bytes'] = 1
        self.save_specification()
        with patch.object(model_pack.urllib.request, 'urlopen', return_value=io.BytesIO(b'too large')):
            with self.assertRaisesRegex(RuntimeError, 'pinned size'):
                model_pack.ensure_models()
        self.assertFalse(self.cache.exists())
        self.assertFalse(self.destination.exists())

    def test_symlink_cache(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.symlink_to(self.pack)
        with self.assertRaisesRegex(RuntimeError, 'regular file'):
            model_pack.ensure_models(offline=True)

    def test_malicious_entries_and_missing_inventory(self):
        with tarfile.open(self.pack) as original:
            entries = [(member, original.extractfile(member).read()) for member in original]
        invalid_sets = [entries + [entries[0]], entries[:-1]]
        for name, kind in [('../escape', tarfile.REGTYPE),
                           ('native/characters.bin', tarfile.SYMTYPE)]:
            item = tarfile.TarInfo(name)
            item.type = kind
            item.linkname = '/tmp/escape' if kind == tarfile.SYMTYPE else ''
            invalid_sets.append([(item, b'')] + entries)
        bad = self.root / 'bad.tar.gz'
        for items in invalid_sets:
            with self.subTest(names=[entry.name for entry, _ in items]):
                with tarfile.open(bad, 'w:gz') as output:
                    for member, data in items:
                        output.addfile(member, io.BytesIO(data))
                with self.assertRaises(RuntimeError):
                    model_pack.unpack_models(bad, self.destination)
                self.assertFalse(self.destination.exists())
        oversized = tarfile.TarInfo('native/characters.bin')
        oversized.size = model_pack.MAX_UNPACKED_BYTES + 1
        bad.write_bytes(gzip.compress(oversized.tobuf() + bytes(1024)))
        with self.assertRaisesRegex(RuntimeError, 'extraction limit'):
            model_pack.unpack_models(bad, self.destination)
        self.assertFalse(self.destination.exists())
        self.assertFalse((self.root / 'escape').exists())

    def test_entry_checksum(self):
        bad = self.root / 'bad-hash.tar.gz'
        item = tarfile.TarInfo('native/characters.bin')
        item.size = 4
        with tarfile.open(bad, 'w:gz') as output:
            output.addfile(item, io.BytesIO(b'FAIL'))
        with self.assertRaisesRegex(RuntimeError, 'entry checksum'):
            model_pack.unpack_models(bad, self.destination)
        self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()
