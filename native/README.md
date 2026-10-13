# TextPicker native CPU engine

Production implementation of **PP-OCRv6 Small — Native / CPU**. Both networks execute fixed C++20 calls backed by Accelerate. ImageIO decodes captures; a minimal static OpenCV/Clipper subset prepares images and performs detection geometry. There is no Python, Core ML, ONNX Runtime, model interpreter, download path or GPU inference in this worker.

The app retains Core ML and ONNX as alternatives. Existing selections are preserved; Core ML remains the default for a new installation. First-class integration does not imply this engine wins every latency comparison or accepts arbitrary document formats.

## Layout and ownership

| Path | Responsibility |
|---|---|
| `src/assets.cpp` | Read-only, integrity-checked model mappings; bounded dictionary parsing; regular-file checks |
| `src/buffer.*` | Owning page-aligned tensors and a synchronized 32 MiB / 64-block reuse cache |
| `src/engine.cpp`, `detector_ops.cpp` | FP32 kernels; no global mutable profiling state |
| `src/preprocess.cpp` | Exact detector/recognizer resize and normalization conventions |
| `src/geometry.cpp` | Contours, scoring, expansion, corner ordering and perspective crops |
| `src/pipeline.cpp` | Detection → bounded crop batches → streamed recognition → text |
| `src/numpy_order.hpp` | Reference-compatible tie ordering, including padding-sensitive equal ratios |
| `src/native_bridge.*` | Non-throwing C boundary with explicit input byte count and ownership rules |
| `worker/ImageDecode.swift` | Open-once bounded file input, metadata/pixel checks, original color samples |
| `worker/Protocol.swift` | Independently tested bounded line framing and typed request validation |
| `worker/NativeWorker.swift` | Serialized process protocol, autorelease scopes, errors and EOF |
| `models/*.cpp`, `models/spec/` | Checked-in generated execution plus frozen graph/layout specifications |
| `tools/` | Build-only dependency preparation, deterministic generation and release evidence |

The worker owns one engine and processes one request at a time. C ABI handles must not be concurrently used or accessed after destruction. Input pixels are borrowed only during a synchronous call. Returned text is owned and freed exactly once. Error reporting uses a fixed-size thread-local buffer and cannot allocate while reporting an allocation failure.

## Deliberate contracts

- Same resolved FP32 weights and full 18,710-entry dictionary as the checkpoint. No quantization or vocabulary changes.
- Opaque, 8-bit RGB/grayscale captures; no implicit color-space conversion. Partially transparent samples are rejected rather than lossy unpremultiplication being presented as exact. 16-bit/CMYK/indexed input is not the capture contract.
- Maximum 20 million pixels, 32,768 per side, 128 MiB encoded file. Special files and final-component symlinks are rejected. Metadata and image decoding use the same bounded bytes.
- Detector longest side ≤1280, rounded to multiples of 32. Recognition height 48, batch ≤6, width 320–4096. Excessively wide lines fail, never get squeezed or clipped.
- At most six full-resolution crops are retained; recognition logits are streamed per line. Individual tensors/scratch are capped at 64M floats. OS RSS also includes model mappings, image buffers and library storage.
- Request lines ≤64 KiB; IDs ≤128 UTF-8 bytes; paths ≤4096 bytes. Text ≤256 KiB UTF-8, leaving room for worst-case JSON escaping below the parent's 2 MB bound.
- The app enforces 30-second startup / 10-second recognition deadlines. Only the selected worker runs. Invalid requests recover; invalid assets fail startup without falling back or downloading.

### Do not “simplify” numerical conventions casually

BGR input order, separate FP32 multiply/add, ties-to-even dimension rounding, reference corner order, inclusive perspective target coordinates, cubic border replication, FP32 edge lengths, ratio sorting ties and padding widths are observable OCR behavior. `-ffp-contract=off` is deliberate. OpenCV's ARM Carotene/KleidiCV HALs are required for matching resize pixels. Model changes require requalification, not merely a successful compile.

## Prepare and build

Requires Apple Silicon macOS, Xcode, CMake ≥3.24 and Python ≥3.12 **for build tooling only**. No Homebrew runtime libraries are linked.

```bash
# Bootstrap ignored model files from a verified existing v0.6+ comparison app:
python3 native/tools/prepare.py models "$HOME/Applications/TextPicker.app"

# First build fetches checksum-pinned source dependencies; later builds are incremental.
bash native/build.sh
# After the source cache is populated, require a fully offline build:
OFFLINE=1 bash native/build.sh
```

Model bytes live in `native/models/` and are excluded from Git; their canonical hashes are in `models/manifest.json`. Missing/mismatched assets fail clearly. OpenCV 5.0.0, Clipper 6.4.2 and KleidiCV 26.03 archives/files are SHA-256 pinned in `dependencies.json`. Core/imgproc pulls geometry/flann internally; optional codecs, Unicode font downloads, video, GUI and neural-network modules are not linked. Build caches remain ignored under `.deps/` and `.build*/`.

CMake owns dependency ordering, incremental rebuilds, linking and test targets. A partially completed dependency build cannot race the worker link. Generated model code is checked on every build:

```bash
python3 native/tools/generate.py --check
# Intentional regeneration from the frozen checked-in specs:
python3 native/tools/generate.py
```

Changing graph fingerprints/weights is not an ordinary regeneration. The original conversion provenance is retained in Git checkpoint `e8e2e9e` and the historical research tree, but neither is needed to build or validate this module.

## One-command validation

Using the existing development `.venv` with NumPy/Pillow:

```bash
bash native/test.sh
# Add independent full-map and full-text comparison against Core ML CPU:
bash native/test.sh --reference-app "$HOME/Applications/TextPicker.app"

# C++ ASan/UBSan and TSan (separate build trees):
SANITIZER=address,undefined bash native/test.sh
SANITIZER=thread bash native/test.sh

# Complete application build, integration, original-backend and release gates:
bash app/test.sh --reference-app "$HOME/Applications/TextPicker.app"
```

The gate uses fresh temporary files, not old experiment result directories. It checks 25 original/transformed synthetic images, byte-exact preprocessing/boxes/crops/recognizer inputs, detector samples, exact text, pixel decoding, errors/recovery/EOF, missing/corrupt assets and a relocated network/write/repository-denied deployment. With a reference app, all detector-map elements and final texts are compared against Core ML. Temporary large tensors are removed after hashing; compact reports remain in `native/results/` or `app/build/`.

C++ primitives cover 1,241 assertions; 30 boundary checks cover byte-count/stride errors, null handles, FIFO assets, invalid crop geometry, attention scratch bounds, bad kernel parameters and tensor ownership. Model-bound tests exercise extreme detector aspect ratios/area and the maximum six-line, width-4096 streamed recognizer. Sixteen Swift framing checks cover fragmented/coalesced lines, overflow recovery, EOF and malformed requests; 111 fresh NumPy comparisons cover ratio ordering. The actual worker also accepts a 20-MP blank and rejects the immediately oversized case. Sanitizer runs include full English/rotated/maximum-detector pipelines; the static OpenCV dependency itself is not sanitizer-instrumented.

Every app build tests its **actual staged helper and models** before replacing the generated app. Build manifests bind source hashes to worker/probe hashes; the release gate rejects stale source/build/test combinations, altered assets, or non-system linkage. This is reproducibility evidence, not a substitute for external signing or a hostile-build-system audit.

## Evidence and limitations

`app/build/native-validation.json` and `native-release.json` bind the current packaged build. `inf-exp/` retains historical work but is not an active build/test dependency. `app/native-results/` records measurements and pass evidence for packaged releases.

Synthetic unsupported-script matches preserve baseline output; they do not establish language accuracy. Sleep/wake, prolonged idle, every real capture and macOS 14 runtime behavior are not proven by these gates. The app remains locally ad-hoc signed and may need permission reauthorization after an update. Distribution still needs a complete licensing/notarization review. See `licenses/` and `app/THIRD_PARTY.md`.
