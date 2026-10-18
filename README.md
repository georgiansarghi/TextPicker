# TextPicker

Select any part of your screen and copy the text in it. A free, open-source
menu bar app for Apple Silicon Macs. OCR runs entirely on your Mac.

<img src="docs/media/capture-demo.gif" alt="Capturing a database name with TextPicker, then pasting it into a confirmation field" width="768">

**[Download](https://github.com/georgiansarghi/TextPicker/releases/latest/download/TextPicker-arm64.zip)**
· macOS 14+ · Apple Silicon

## Install

1. Unzip and drag **TextPicker** into **Applications**.
2. Open it, then allow it in **System Settings → Privacy & Security → Open Anyway**
   (the app isn't notarized).
3. Grant **Screen Recording** and **Accessibility** when asked.

Press **⌘⇧2** and drag over text to copy it.

<img src="docs/media/menu.webp" alt="TextPicker's dark-mode menu with capture settings and permission status" width="362">

## Build from source

Requires Xcode, CMake and [`uv`](https://docs.astral.sh/uv/).

```sh
bash scripts/setup.sh
bash scripts/build.sh
open .build/apps/TextPicker.app
```

## License

[MIT](LICENSE). The OCR model and bundled libraries have their own licenses; see
[third-party notices](licenses/THIRD_PARTY.md).
