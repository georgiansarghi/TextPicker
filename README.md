# TextPicker

**Select any part of your screen and copy the text in it.** A free, open-source
menu bar app for Apple Silicon Macs. Recognition runs entirely on your Mac.

<img src="docs/media/capture-demo.gif" alt="Capturing a database name with TextPicker, then pasting it into a confirmation field" width="768">

### [⬇ Download TextPicker for Apple Silicon](https://github.com/georgiansarghi/TextPicker/releases/latest/download/TextPicker-arm64.zip)

macOS 14 Sonoma or later · Apple Silicon (M1 or newer) · 28 MB download ·
[All releases](https://github.com/georgiansarghi/TextPicker/releases)

## What it does

Press **⌘⇧2**, drag over text, and it's on your clipboard. It works on text you
normally can't select: images, videos, screen shares, error dialogs, tooltips,
and even **open menus**, which stay open while you capture them.

- **Private:** no account and no network connections. Captures never leave your Mac.
- **Fast:** a few lines of text typically take about 0.1 s on an M1.
- **Additive Clipboard:** collect several captures into one paste.
- **Your shortcut:** change it from the menu. You can also keep or join line
  breaks, and turn the sound and on-screen feedback on or off.
- **Opt-in launch at login.**

<img src="docs/media/menu.webp" alt="TextPicker's dark-mode menu with capture settings and permission status" width="362">

## Install

1. [Download `TextPicker-arm64.zip`](https://github.com/georgiansarghi/TextPicker/releases/latest/download/TextPicker-arm64.zip),
   unzip it, and drag **TextPicker** into **Applications**.
2. Open TextPicker. macOS will say it **could not verify** the app. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to the
   "TextPicker was blocked" message, click **Open Anyway**, and confirm.
4. Grant **Screen Recording** and **Accessibility** when TextPicker asks.

You only need to do this once.

<details>
<summary>Why does macOS warn about TextPicker?</summary>

Apple only stops warning about apps whose developer has a paid Apple Developer
account and has sent the app to Apple for scanning ("notarization"). TextPicker
doesn't have that yet, so macOS warns about it the same way it would about any
small free app distributed outside the App Store. Every release is built from
this repository by
[GitHub Actions](https://github.com/georgiansarghi/TextPicker/actions) and
published with SHA-256 checksums.

Prefer Terminal? This removes the download warning flag instead of steps 2–3:

```sh
xattr -dr com.apple.quarantine /Applications/TextPicker.app
```
</details>

## Why it needs these permissions

| Permission | What TextPicker uses it for |
| --- | --- |
| **Screen Recording** | Capturing the rectangle you select, and nothing else. The image is recognized, then deleted. macOS uses the same broad wording for every screenshot app. |
| **Accessibility** | Listening for the capture shortcut, and holding your mouse click while you drag so it doesn't reach the app underneath. That is what keeps menus open. Keystrokes are not recorded or sent anywhere. |

Missing a permission? Open the TextPicker menu; the **Permissions** section shows
what's missing and takes you to the right settings page.

## Languages

TextPicker uses PaddleOCR's PP-OCRv6 Small model.

- **Works well:** English and other Latin-script languages (German, French,
  Spanish, …), Chinese, Japanese, code, and terminal output.
- **Not supported yet:** Korean, Cyrillic (Russian, …), Arabic, and Devanagari
  (Hindi, …).

## Updating

Choose **Check for Updates…** in the TextPicker menu to open the latest release,
then replace the app in Applications. Releases are signed with the same
certificate, so macOS keeps your permissions when you update.

> **Upgrading from 0.11?** That version had a different identity. Remove the old
> **TextPicker** entries under Screen Recording and Accessibility in System
> Settings, then grant access again. Your settings carry over.

## Troubleshooting

- **The shortcut does nothing.** Check that both permissions are on in the
  TextPicker menu. If macOS shows them as on but they don't work, select
  TextPicker in each list, remove it with **–**, then open TextPicker again.
- **"OCR unavailable".** Choose **Retry OCR Engine** in the menu.
- **Very large selections miss small text.** Select a smaller area. Captures are
  limited to 20 megapixels, so a full 6K/8K screen won't fit in one capture.
- **Logs** for bug reports are in `~/Library/Logs/TextPicker/`. They contain
  status and errors only, never recognized text.

Please include your macOS version and Mac model when you
[open an issue](https://github.com/georgiansarghi/TextPicker/issues).

## Uninstall

Quit TextPicker from its menu and delete it from Applications. Then remove it
from **Screen Recording** and **Accessibility** in System Settings, and optionally
remove its settings and logs:

```sh
defaults delete io.github.georgiansarghi.TextPicker
rm -rf ~/Library/Logs/TextPicker
```

## Build from source

Requires Xcode, CMake and [`uv`](https://docs.astral.sh/uv/). The first build
downloads and verifies the pinned model pack and dependencies.

```sh
bash scripts/setup.sh
bash scripts/build.sh
open .build/apps/TextPicker.app
```

[Building](docs/BUILDING.md) · [Testing](docs/TESTING.md) · [Releasing](docs/RELEASING.md)

## License

TextPicker is [MIT-licensed](LICENSE). The OCR model and bundled libraries have
their own licenses; see [third-party notices](licenses/THIRD_PARTY.md).
