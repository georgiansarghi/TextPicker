"""Release metadata must explicitly agree with the app and signing policy."""
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from release_archive import release_config


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='textpicker-release-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'app').mkdir()
        (self.root / '.github').mkdir()
        (self.root / 'app/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.11.0'}))
        (self.root / '.github/RELEASE.md').write_text('Explicitly reviewed release notes')
        self.config = {'tag': 'v0.11.0', 'title': 'TextPicker 0.11.0',
                       'prerelease': False, 'signing': 'self-signed', 'certificate_sha256': 'ab' * 32}
        self.save()

    def save(self):
        (self.root / '.github/release.json').write_text(json.dumps(self.config))

    def test_valid(self):
        config, info = release_config(self.root)
        self.assertEqual(config, self.config)
        self.assertEqual(config['tag'], 'v' + info['CFBundleShortVersionString'])

    def test_version_mismatch(self):
        self.config['tag'] = 'v1.0.0'
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'version must match'):
            release_config(self.root)

    def test_signing_policy(self):
        for key, value in [('prerelease', True), ('prerelease', 0), ('signing', 'ad-hoc'),
                           ('signing', 'Developer ID'), ('certificate_sha256', None),
                           ('certificate_sha256', 'AB' * 32), ('certificate_sha256', 'ab' * 31)]:
            with self.subTest(key=key, value=value):
                original = self.config[key]
                self.config[key] = value
                self.save()
                with self.assertRaisesRegex(RuntimeError, 'pinned certificate'):
                    release_config(self.root)
                self.config[key] = original

    def test_title(self):
        for value in ['', ' ', 'a\nb', 'a\rb', 'a' * 121, None]:
            with self.subTest(title=value):
                self.config['title'] = value
                self.save()
                with self.assertRaisesRegex(RuntimeError, 'Invalid release title'):
                    release_config(self.root)

    def test_no_implicit_notes(self):
        (self.root / '.github/RELEASE.md').write_text('  \n')
        with self.assertRaisesRegex(RuntimeError, 'explicitly supplied'):
            release_config(self.root)


if __name__ == '__main__':
    unittest.main()
