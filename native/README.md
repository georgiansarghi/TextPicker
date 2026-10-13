# Native CPU engine

PP-OCRv6 Small detector and recognizer, implemented as fixed C++20 calls backed
by Accelerate. ImageIO decodes input; a minimal static OpenCV/Clipper subset
handles image preparation and geometry. No general inference runtime, GPU,
Python, network access or model downloads run in the native worker.

## Structure

- `src/`: kernels, memory pool, image geometry, pipeline and non-throwing C ABI.
- `worker/`: Swift image decoding and bounded request/response protocol.
- `models/`: generated execution code, frozen graph/layout specifications and hashes.
- `tools/`: dependency preparation, deterministic code generation and release gates.
- `tests/`: primitives, boundaries, model limits, protocol and full-pipeline validation.

Model bytes live in `../.build/models/native/`, not the source directory.
Dependency sources and build products live in `../.build/deps/` and
`../.build/native/`. See [build setup](../docs/BUILDING.md) and
[test commands](../docs/TESTING.md).

## Contracts

- Preserve the resolved FP32 weights and full 18,710-entry dictionary. No
  quantization, vocabulary trimming, automatic fallback or silent input squeezing.
- Opaque 8-bit RGB/grayscale, up to 20 million pixels, 32,768 pixels per side and
  128 MiB encoded input. Decode the same bounded bytes inspected for metadata;
  reject special files, final-component symlinks and unsupported image formats.
- Detector: longest side at most 1280, dimensions rounded to multiples of 32.
  Recognizer: height 48, batches up to six lines, widths 320–4096.
- At most six full-resolution crops retained; classifier logits streamed per line.
  Tensor/scratch allocations capped at 64M floats; reusable pool capped at 32 MiB.
- One serial worker/engine. C handles are not concurrently shareable. Borrow input
  only during the call; free returned text using the paired C ABI function.
- Request lines at most 64 KiB, IDs 128 UTF-8 bytes, paths 4096 bytes, returned text
  256 KiB. Invalid requests recover; invalid assets fail startup.

BGR order, separate FP32 multiply/add, ties-to-even resizing, corner ordering,
cubic border replication, ratio-sort ties and batch padding affect OCR results.
`-ffp-contract=off` and the pinned Carotene/KleidiCV resize implementations are
intentional. Do not change these conventions without requalification.

## Generation and verification

```sh
.venv/bin/python -B native/tools/generate.py --check
# Only when intentionally regenerating from the frozen graph/layout specs:
.venv/bin/python -B native/tools/generate.py
OFFLINE=1 bash native/build.sh
```

Build manifests bind source to worker/probe hashes. Packaging validates the actual
staged worker and assets before signing the enclosing app; release verification
rejects stale source/build/test combinations, changed models and non-system
linkage. Qualification uses frozen independent detector references and exact
stage/text expectations, without a second inference engine. The compact test
reference encoding and numerical tolerance are documented in [Testing](../docs/TESTING.md#reference-data).

Tests preserve reference behavior, including unsupported-script output; they do
not establish language accuracy, universal display compatibility or latency/energy
claims. Third-party notices are under [licenses](../licenses/THIRD_PARTY.md).
