# TextOCR: Apple Silicon OCR prototype and benchmarks

**TextOCR v0.6.0 adds an opt-in native CPU backend.** Installed target: `~/Applications/TextOCR.app`. Capture with **⌘⇧2**. **PP-OCRv6 Small — Core ML / CPU** remains the default; **ONNX Runtime / CPU** remains available. **Native / CPU (experimental)** runs both detector and recognizer in the specialized C++/Accelerate executor, with native image preparation and perspective crops. Enable Screen Recording and Accessibility on first use. The default input-interception path is designed to preserve open menus without activating TextOCR; no separate menu mode is needed. See **[app/TESTING.md](app/TESTING.md)** for the testing checklist and **[app/README.md](app/README.md)** for implementation/build details.

The app is rebuilt from a clean runtime allowlist: no MLX, Tiny models, Apple Vision worker, Core ML GPU mode, pretrained patch checkpoint, Hugging Face tooling or PyMuPDF. Core ML uses NumPy/OpenCV helpers with parity checks against the previous pipeline. See [the app guide](app/README.md) and [measured cleanup results](app/cleanup-results/size.json).

The complete native pipeline and its 25 synthetic stage/text parity cases are documented in **[inf-exp/PIPELINE.md](inf-exp/PIPELINE.md)**. Its measured runtime payload is 33.26 MiB, but adding it to the comparison app increases bundle size because the existing backends remain. Core ML CPU still has the lower matched median latency; native is experimental, not the new default.

Previous builds and all research evidence remain separate from the app. Vision's investigation is preserved [here](experiments/vision_api/README.md); its real-capture timeouts motivated removing it from the supported app.

The rest of this document covers historical research and reproducible benchmarks, including engines no longer shipped. These benchmark environments are not app dependencies.

**Research report: [research/REPORT.md](research/REPORT.md).** It contains the recommendation, online sources, language/license comparison, M1 timings, MLX compilation findings, and evidence about a reproduced Apple Vision initialization stall.

## Main findings on this M1 / 16 GB Mac

- **PP-OCRv6 Small / native MLX:** ~54 ms warm median, zero non-whitespace character errors on nine synthetic Latin fixtures. Promising independent engine, but the `mlx4ocr` port is pre-alpha.
- **PP-OCRv6 Tiny / native MLX:** ~20 ms, with a small accuracy trade-off.
- **Vision accurate, explicit GPU:** ~41 ms and zero errors on the same fixtures; explicit CPU was essentially tied.
- **Disable MLX model graph compilation for arbitrary screenshot shapes initially.** Default compilation introduced substantial new-shape latency; eager mode was nearly as fast warm.
- Simply enabling ONNX Runtime's **Core ML provider was slower**, not faster, in the tested configuration.

These are OCR-only timings, not selection-to-clipboard timings, and this is a small synthetic corpus rather than a general accuracy benchmark. See the report for cold-start costs, script coverage and caveats.

## Layout

- `benchmark/vision.swift`: native Vision runner, explicit GPU/CPU support.
- `benchmark/render.swift`, `generate_fixtures.py`: deterministic native CoreText fixture rendering.
- `benchmark/run_python.py`: RapidOCR CPU/Core ML and persistent Tesseract C API runners.
- `benchmark/run_mlx.py`: native MLX/Metal PP-OCRv6 runner.
- `benchmark/run_suite.py`: serialized, bounded benchmark orchestration.
- `benchmark/probe_vision.py`: bounded fresh-process Vision probes.
- `benchmark/summarize.py`: CER and latency calculations.
- `benchmark/fixtures/`: 15 images and ground-truth manifest.
- `benchmark/results/`: raw outputs, summaries, model hashes, metadata and diagnostic evidence.
- `research/sources/`: primary-source snapshots.
- `vendor/mlx4ocr/`: cloned MLX port; no upstream files were edited.
- `vendor/mlx-vlm/`: reference checkout; its PP-OCRv6 support was not merged at investigation time.

## Re-run using the prepared environment

From `~/src/textocr`:

```bash
# CPU/native baselines; overwrites corresponding result files
.venv/bin/python benchmark/run_suite.py

# Vision GPU/modern CPU, compiled MLX, ONNX/Core ML; sequential, not parallel
.venv/bin/python benchmark/run_suite.py --gpu

# Recommended MLX settings
.venv/bin/python benchmark/run_suite.py --mlx-eager

# Regenerate score tables after all runs finish
.venv/bin/python benchmark/summarize.py

# Scoring sanity checks
.venv/bin/python -m unittest discover -s benchmark -p 'test_*.py' -v
```

Do **not** run suites concurrently. Close other heavy workloads for more consistent results. A suite allows 240 seconds per engine and kills its process group on timeout. Model downloads must be completed separately before timing.

## Fresh setup

Requires Apple Silicon macOS, Xcode command-line tools (`swiftc`), `uv`, and Homebrew Tesseract. The benchmark's Tesseract library path is `/opt/homebrew/lib/libtesseract.dylib`.

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r benchmark/requirements.lock.txt
.venv/bin/python benchmark/prepare_models.py
.venv/bin/python benchmark/generate_fixtures.py
swiftc -O benchmark/vision.swift -o benchmark/vision

# MLX environment (run clone only if vendor/mlx4ocr is absent)
git clone https://github.com/shuuul/mlx4ocr.git vendor/mlx4ocr
git -C vendor/mlx4ocr checkout 2d5bb458607d97112555fed27901bdde603c934d
uv venv --python 3.12 .venv-mlx
uv pip install --python .venv-mlx/bin/python -r benchmark/requirements-mlx.lock.txt
HF_HUB_DISABLE_XET=1 .venv-mlx/bin/python benchmark/prepare_models.py --mlx
```

The MLX lock also contains `mlx-vlm` dependencies installed for investigation; lightweight PP-OCRv6 itself does not need the optional VLM stack. The benchmark runs `mlx4ocr`, not a generative model.

Small's upstream MLX weight loader additionally downloads a ~125 MB official Paddle checkpoint to patch recognition head tensors. Allow several minutes. That loader writes directly to its final filename; an interrupted download can leave a partial `.cache/paddle_pretrained/PP-OCRv6_small_rec_pretrained.pdparams`. Verify its size/hash against `benchmark/results/environment.json` before reusing it, and resume or replace the partial file if necessary.

Pip versions, cloned commits, HF snapshot revisions and model hashes are recorded. The MLX upstream download path resolves HF `main`; retain the prepared cache or verify hashes against `environment.json` if upstream models change.

## One-off backend runs

```bash
# Native GPU, accurate recognition, language correction disabled
benchmark/vision accurate benchmark/fixtures/manifest.json 5 gpu-only no-correction

# Modern explicit CPU selection (not the deprecated usesCPUOnly setting)
benchmark/vision accurate benchmark/fixtures/manifest.json 5 cpu-modern no-correction

# MLX Small; already-downloaded models, no graph compilation
HF_HUB_OFFLINE=1 .venv-mlx/bin/python benchmark/run_mlx.py small 5 --no-compile

# Diagnostic probes; do not run alongside timing suites
.venv/bin/python benchmark/probe_vision.py
```

The legacy CPU baseline intentionally retains `usesCPUOnly` to document the original diagnostic; compiling therefore emits a deprecation warning. New production code should use explicit `MLComputeDevice` assignments, as the modern modes demonstrate.

## Metrics

Each image: one initial call plus five timed repeat calls. GPU operations are synchronized. CER is NFC-normalized, case-sensitive, and removes **all whitespace**. Both character-weighted and equal-image-weighted CER are retained. This does not score indentation, spacing, or complex reading order. Unsupported-script examples are separated from the Latin comparison; a fast wrong/empty result is not a useful success.

Initial-call timing is retained separately because warm timing alone hides language initialization, model loading and shape compilation. No caches or system services were reset during the investigation.

## Scope and privacy

All recognition was local on generated fixtures. Only public source/model downloads used the network. No private screen contents were captured or uploaded. TextSniper's version and linked framework list were read without modifying or instrumenting the app. No launch agents, services, global Python packages or macOS settings were installed/changed.
