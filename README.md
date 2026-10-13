# TextPicker

**Select a region. Copy its text.** A local OCR utility for Apple Silicon Macs.

Press **⌘⇧2**, drag over text, and paste anywhere. Recognition runs on your Mac;
no account, cloud service or capture uploads.

- Menu-preserving selection, configurable shortcut and optional capture feedback.
- Preserve line breaks or collect successive captures with Additive Clipboard.
- Native CPU inference with PP-OCRv6 Small. Opt-in launch at login.

## Build & run

Requires Xcode, CMake, `uv`, and the pinned model assets described in
[Building](docs/BUILDING.md). Deployment target: macOS 14; older OS/display
configurations still need the [live checks](docs/TESTING.md#live-checks).

```sh
bash scripts/setup.sh
bash scripts/build.sh                 # after preparing model assets
open .build/apps/TextPicker.app
```

Grant **Screen Recording** and **Accessibility** when prompted. Capture is limited
to the selected region plus its tiny alignment boundary; audio is disabled.

[Build & install](docs/BUILDING.md) · [Tests & troubleshooting](docs/TESTING.md) · [Third-party notices](licenses/THIRD_PARTY.md)
