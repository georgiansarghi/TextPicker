"""Deterministic native model packs and checksum-pinned build-time caching."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import urllib.parse
import urllib.request

from verify_models import ROOT, MANIFEST, verify_directory

MAX_UNPACKED_BYTES = 40 * 1024 * 1024
MAX_ARCHIVE_BYTES = 40 * 1024 * 1024


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def metadata_files():
    return {'manifest.json': MANIFEST,
            'Licenses/PaddleOCR-Apache-2.0.txt': ROOT / 'licenses/PaddleOCR-Apache-2.0.txt'}


def expected_contents():
    files = {'native/' + name: value for name, value in json.loads(MANIFEST.read_text())['files'].items()}
    files.update({name: digest(path) for name, path in metadata_files().items()})
    return files


def write_pack(source, destination):
    verify_directory(source)
    files = {'native/' + name: source / name for name in json.loads(MANIFEST.read_text())['files']}
    files.update(metadata_files())
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise RuntimeError('Refusing to overwrite an existing model pack')
    with destination.open('xb') as output:
        with gzip.GzipFile(filename='', fileobj=output, mode='wb', mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name, path in sorted(files.items()):
                    data = path.read_bytes()
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    member.mode = 0o644
                    member.mtime = member.uid = member.gid = 0
                    archive.addfile(member, io.BytesIO(data))
    return {'archive_bytes': destination.stat().st_size, 'archive_sha256': digest(destination)}


def verify_pack(path, specification):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError('Model cache entry must be a regular file')
    if path.stat().st_size != specification['archive_bytes'] or digest(path) != specification['archive_sha256']:
        raise RuntimeError('Model pack checksum/size mismatch; refusing to use or silently replace it')


def download_pack(destination, specification):
    url = specification['url']
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' or parsed.netloc != 'github.com' or not parsed.path.startswith('/georgiansarghi/TextPicker/releases/download/'):
        raise RuntimeError('Model pack must use the pinned HTTPS GitHub release URL')
    size = specification['archive_bytes']
    if type(size) is not int or not 0 < size <= MAX_ARCHIVE_BYTES:
        raise RuntimeError('Invalid model pack size limit')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.download-') as temporary:
        prepared = Path(temporary) / 'models.tar.gz'
        request = urllib.request.Request(url, headers={'User-Agent': 'TextPicker-model-setup'})
        with urllib.request.urlopen(request, timeout=90) as response, prepared.open('xb') as output:
            total = 0
            while data := response.read(1024 * 1024):
                total += len(data)
                if total > size:
                    raise RuntimeError('Model download exceeds its pinned size')
                output.write(data)
        verify_pack(prepared, specification)
        prepared.replace(destination)


def unpack_models(pack, destination):
    expected = expected_contents()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.unpack-') as temporary:
        temporary = Path(temporary)
        seen = set()
        total = 0
        # Never extract archive paths, links, permissions or ownership directly.
        with tarfile.open(pack, mode='r|gz') as archive:
            for member in archive:
                if not member.isfile() or member.name not in expected or member.name in seen:
                    raise RuntimeError('Unexpected, duplicate or non-regular model pack entry')
                total += member.size
                if member.size < 0 or total > MAX_UNPACKED_BYTES:
                    raise RuntimeError('Model pack exceeds its extraction limit')
                stream = archive.extractfile(member)
                if stream is None:
                    raise RuntimeError('Missing model pack entry data')
                data = stream.read(member.size + 1)
                if len(data) != member.size or hashlib.sha256(data).hexdigest() != expected[member.name]:
                    raise RuntimeError('Model pack entry checksum mismatch')
                if member.name.startswith('native/'):
                    target = temporary / member.name
                    target.parent.mkdir(exist_ok=True)
                    target.write_bytes(data)
                seen.add(member.name)
        if seen != set(expected):
            raise RuntimeError('Model pack inventory is incomplete')
        prepared = temporary / 'native'
        verify_directory(prepared)
        if destination.exists() or destination.is_symlink():
            raise RuntimeError('Model destination appeared during preparation; refusing to overwrite it')
        prepared.rename(destination)


def ensure_models(*, offline=False):
    destination = ROOT / '.build/models/native'
    if destination.exists() or destination.is_symlink():
        verify_directory(destination)
        return destination
    specification = json.loads((ROOT / 'native/models/distribution.json').read_text())
    if specification.get('schema') != 1:
        raise RuntimeError('Unsupported model distribution specification')
    name = specification['asset']
    if Path(name).name != name or not name.endswith('.tar.gz'):
        raise RuntimeError('Invalid model cache filename')
    cache = ROOT / '.build/downloads' / name
    if not cache.exists() and not cache.is_symlink():
        if offline or os.environ.get('OFFLINE') == '1':
            raise RuntimeError('Offline build needs cached models; import a native app/model pack or run once online')
        download_pack(cache, specification)
    verify_pack(cache, specification)
    unpack_models(cache, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / '.build/models/native')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(write_pack(args.source.resolve(), args.output.resolve()), indent=2))


if __name__ == '__main__':
    main()
