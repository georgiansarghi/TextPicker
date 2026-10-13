"""Import checksum-pinned native assets; no conversion or implicit downloads."""
import argparse
from pathlib import Path
import shutil
import tempfile

from verify_models import ROOT, verify_directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--from-app', type=Path, help='TextPicker app containing native models')
    source.add_argument('--from-directory', type=Path, help='Directory containing the three native asset files')
    options = parser.parse_args()
    origin = (options.from_app / 'Contents/Resources/models/native'
              if options.from_app else options.from_directory).resolve()
    destination = ROOT / '.build/models/native'
    # Validate the input and existing destination before copying anything.
    verify_directory(origin)
    if destination.exists():
        verify_directory(destination)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.import-') as temporary:
            prepared = Path(temporary) / 'native'
            shutil.copytree(origin, prepared)
            verify_directory(prepared)
            prepared.rename(destination)
    print('Verified native assets:', destination)


if __name__ == '__main__':
    main()
