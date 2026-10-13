# Building TextPicker

## Prerequisites

- Apple Silicon Mac, Xcode with its command-line tools selected.
- CMake 3.24 or newer and `uv` on `PATH`.
- Python 3.12 (the setup script can provision it through `uv`).

```sh
bash scripts/setup.sh
```

This creates/uses `.venv` and synchronizes its two pinned test dependencies:
NumPy and Pillow. Python is never included in the app. Setup does not install
the app, alter permissions or register a login item.

## Model assets

The three native assets—`detector.weights`, `recognizer.weights` and
`characters.bin`—are **not in Git**. A fresh checkout needs the exact prepared
PP-OCRv6 Small FP32 pack; generated C++ cannot reconstruct weights. There is no
automatic download or unpinned conversion step.

Import from an existing native TextPicker app or a prepared asset directory:

```sh
.venv/bin/python -B scripts/prepare_models.py --from-app ~/Applications/TextPicker.app
# Alternatively:
.venv/bin/python -B scripts/prepare_models.py --from-directory /path/to/native-models
```

The importer validates the entire input before copying and refuses mismatched
existing assets. `native/models/manifest.json` pins every file. Assets live in
`.build/models/native/`; preserve a separate pack or app before deleting
`.build/`. No alternative inference engine or reference app is needed.

## Build, run and install

```sh
bash scripts/build.sh
open .build/apps/TextPicker.app
# Quit any running TextPicker before replacing the installed copy:
bash scripts/install.sh
```

There is one native-only product. Builds verify model inventories, qualify the
actual packaged worker, embed its validation record, and ad-hoc sign the finished
bundle. The first build fetches checksum-pinned native source dependencies;
`OFFLINE=1` rejects missing caches instead of downloading.

The installer verifies its staged copy, retains a dated rollback, and launches
`~/Applications/TextPicker.app`. It does not change saved settings, TCC permissions
or login registration. Ad-hoc updates may require renewed permissions. Public
redistribution needs separate signing/notarization and licensing review.

## Repository map

- `app/`: AppKit UI, capture/input lifecycle and final artwork.
- `native/`: worker, fixed graph executor, generation and native-specific tests.
- `scripts/`: setup, packaging, verification and installation.
- `tests/`: app/capture tests and small synthetic regression fixtures.
- `licenses/`: dependency notices, also included in the app.

Generated apps, dependency sources, local models, binaries and reports belong in
ignored `.build/`. See [Testing](TESTING.md) and [native contracts](../native/README.md).
