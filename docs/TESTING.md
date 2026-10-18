# Testing and troubleshooting

## Automated checks

After [preparing build inputs](BUILDING.md):

```sh
bash scripts/test.sh
```

Tests use synthetic inputs and injected actions. They do not acquire real screen
pixels, access your clipboard, request permissions, modify standard preferences,
register login items or replace the installed app. Installer tests use a temporary
HOME and stubbed launch commands. Reports and test executables go under `.build/`.

The gates cover capture geometry/cancellation, input ownership, nested menu
tracking, worker framing/recovery, settings, permission UI, feedback, native
payload inventories, artwork, model importing/download/cache safety, release
metadata policy and installation rollback.
Native builds compare 25 full image/stage/text cases, every detector-map value
against frozen references, 111 ratio-order cases, invalid assets, bounds and isolation.

```sh
bash native/test.sh
SANITIZER=address,undefined bash native/test.sh
SANITIZER=thread bash native/test.sh
```

Sanitizers instrument the native implementation, not third-party OpenCV.
`tests/fixtures/` contains the committed synthetic regression corpus. Its generator
writes to `.build/generated-fixtures/` by default; font/OS changes must not silently
replace the golden PNGs or expected outputs.

## Performance

`scripts/bench.py` times the bundled OCR worker on the fixture corpus plus two
deterministic screen-sized composites (1600×1000 and 2560×1440). With
`--baseline`, it alternates requests between two builds on the same machine, so
background load affects both equally, and reports per-workload ratios, the
geometric-mean ratio and any change in recognized text.

```sh
.venv/bin/python -B scripts/bench.py .build/apps/TextPicker.app --baseline release:latest
.venv/bin/python -B scripts/bench.py .build/apps/TextPicker.app --baseline ~/Applications/TextPicker.app \
  --require-identical
```

A baseline is an `.app`, a release ZIP or `release:<tag|latest>` (downloaded and
checked against its `SHA256SUMS.txt`). `--max-regression PERCENT` fails a slower
candidate; CI uses 15% on release tags. Identical builds measure within a few
percent of each other on a busy M1, so treat smaller differences as noise and use
more `--rounds` to settle them.

## Reference data

`native/tests/reference.json` preserves exact text, preprocessing/crop/batch
fingerprints and FP32 detector samples. `detector-maps.npz` contains all 3,935,232
detector probabilities from an independently qualified FP32 Core ML CPU reference,
frozen before that implementation was removed. Builds no longer run Core ML.

Only these **test expectations** use compact uint16 encoding:
`round(probability × 65535)`, with maximum error `0.5/65535` (about 0.00000763).
The full-map comparison uses the established `atol=1e-3, rtol=1e-4`, adding that
bounded encoding allowance to the absolute tolerance. Comparator tests reject
out-of-tolerance changes, nonfinite values and wrong types/shapes. Inference,
model weights and the existing exact stage/text checks are unchanged.

The archive is hash-pinned and source-bound to qualification evidence. Do not
regenerate expectations simply to make changed inference pass. These are
regression checks, not a live second-engine comparison or a language-accuracy
claim (some cases deliberately preserve unsupported-script behavior).

## Live checks

Use harmless test text, not private content:

- Press **⌘⇧2**, select text and verify the clipboard; try Escape/right-click.
- Capture an open menu, including TextPicker's own, without activating a menu item.
- Try thin horizontal/vertical selections, odd pixel sizes and all display corners.
- Repeat on 1×/2×, mixed-scale, rotated and external displays; change scaling and
  test reconnect/sleep/wake. The live rendering gate has been exercised on one 2×
  display on macOS 27.0.1, not a complete hardware/OS matrix.
- Verify shortcut recording/reset, line breaks, optional feedback/sound and fresh
  additive collections. Enabling Additive Clipboard must not import existing text.
- Verify Screen Recording/Accessibility actions and capture readiness after restart.
  Check real login behavior separately; Launch at Login remains opt-in.

### Synthetic-window capture probe (explicit opt-in)

The probe briefly shows a colored window and allowlists **only that window** for
capture. It requires an already-authorized host and does not request access. It
saves synthetic PNG/JSON output to a fresh directory, never regular user captures.

```sh
mkdir -p .build/tests
swiftc -O -warnings-as-errors -swift-version 5 -target arm64-apple-macos14.0 \
  app/Sources/Support.swift app/Sources/RegionCapture.swift \
  tests/capture/RegionCaptureProbe.swift -o .build/tests/RegionCaptureProbe \
  -framework AppKit -framework ScreenCaptureKit
.build/tests/RegionCaptureProbe "$PWD/.build/capture-probe-1"
.venv/bin/python -B tests/capture/check_region_probe.py .build/capture-probe-1
```

All 13 cases must be present. Dimensions and opacity are exact requirements;
small RGB differences between separate system captures are tolerated, not called
bitwise parity. Interactive checks are not part of the ordinary test command.

## Diagnostics and limits

Routine logs contain launch/readiness/errors only, in
`~/Library/Logs/TextPicker/TextPicker.log` (owner-only, bounded). To enable input,
capture-size/alpha and timing traces, quit the app and launch its executable with
`TEXTPICKER_DEBUG=1`. This is a developer environment flag, not a saved setting.
No mode logs recognized text or saves regular capture images. Temporary OCR PNGs
are removed on completion, cancellation, failure, exit and startup.

If the shortcut is unavailable, check both permissions and reopen after granting
access. If recognition fails, use **Retry OCR Engine** and try a smaller selection.
Native accepts opaque 8-bit RGB/grayscale images up to **20 million pixels**;
a full 6K/8K screenshot can exceed that limit. Detector resizing can also lose
very small text in large selections. A deployment target of macOS 14 is not proof
of live compatibility with every macOS release or display configuration.

Capture requests use a tight whole-point envelope, then trim its tiny alignment
boundary back to the selected pixels. Unexpected geometry/dimensions fail rather
than falling back to a full-display shot. Audio is disabled, but macOS's broad
recording permission wording is outside the app's control.
