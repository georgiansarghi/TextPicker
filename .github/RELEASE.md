Select any part of your screen and copy the text in it. Recognition runs entirely on your Mac.

**Download `TextPicker-arm64.zip` below** (macOS 14+, Apple Silicon). The other two files are checksums for verification.

### Install

1. Unzip and drag **TextPicker** into **Applications**, then open it.
2. macOS will say it could not verify the app. Click **Done**, open **System Settings → Privacy & Security**, and click **Open Anyway** next to the TextPicker message.
3. Grant **Screen Recording** and **Accessibility** when asked.

TextPicker isn't notarized by Apple yet, which is why macOS asks. See the [README](https://github.com/georgiansarghi/TextPicker#install) for details.

### What's new in 0.12.1

- **Simpler permissions window.** Shorter text, one button per permission, and a clear checkmark once access is granted.
- **Selections that are too large no longer break recognition.** You'll see "Try selecting a smaller area", and the next capture works right away instead of needing **Retry OCR Engine**.
- **Captures can start at the very top of the screen**, including on menu bar text. Previously, the selection was cancelled, or jumped to a display above.
