"""Pinned build inputs. Stdlib only; never runs in the app worker."""

import argparse
import hashlib
import json
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_models(directory):
    manifest = json.loads((ROOT / "models/manifest.json").read_text())
    for name, expected in manifest["files"].items():
        path = directory / name
        if not path.is_file() or digest(path) != expected:
            raise RuntimeError(
                f"Missing or changed native model asset: {name}; run native/tools/prepare.py models SOURCE_DIRECTORY"
            )


def import_models(source):
    if source.suffix == ".app":
        source = source / "Contents/Resources/models/native"
    verify_models(source)
    with tempfile.TemporaryDirectory(
        dir=ROOT / "models", prefix=".import-"
    ) as temporary:
        temporary = Path(temporary)
        for name in json.loads((ROOT / "models/manifest.json").read_text())["files"]:
            shutil.copyfile(source / name, temporary / name)
        verify_models(temporary)
        # Only validated bytes become visible to a build; never modify source assets.
        for path in temporary.iterdir():
            path.replace(ROOT / "models" / path.name)


def dependencies(offline):
    cache = ROOT / ".deps"
    for item in json.loads((ROOT / "dependencies.json").read_text()):
        path = cache / item["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            if offline:
                raise RuntimeError(f"Offline build is missing {item['path']}")
            temporary = path.with_suffix(path.suffix + ".partial")
            try:
                with (
                    urllib.request.urlopen(item["url"], timeout=90) as response,
                    temporary.open("wb") as output,
                ):
                    shutil.copyfileobj(response, output)
                if digest(temporary) != item["sha256"]:
                    raise RuntimeError(
                        f"Downloaded dependency hash mismatch: {item['path']}"
                    )
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        if digest(path) != item["sha256"]:
            raise RuntimeError(f"Cached dependency hash mismatch: {item['path']}")
    directory = cache / "opencv-5.0.0"
    if not directory.exists():
        with tempfile.TemporaryDirectory(dir=cache, prefix=".extract-") as temporary:
            with tarfile.open(cache / "opencv-5.0.0.tar.gz") as archive:
                archive.extractall(temporary, filter="data")
            (Path(temporary) / directory.name).replace(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["dependencies", "models", "verify"])
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--offline", action="store_true")
    options = parser.parse_args()
    if options.action == "dependencies":
        dependencies(options.offline)
    elif options.action == "models":
        if options.source is None:
            parser.error("models requires a source directory or app bundle")
        import_models(options.source)
    else:
        verify_models(options.source or ROOT / "models")
    print(f"Native {options.action}: verified")


if __name__ == "__main__":
    main()
