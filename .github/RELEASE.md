Select any part of your screen and copy the text in it. Recognition runs entirely on your Mac.

**Download `TextPicker-arm64.zip` below** (macOS 14+, Apple Silicon). The other two files are checksums for verification.

### Install

1. Unzip and drag **TextPicker** into **Applications**, then open it.
2. macOS will say it could not verify the app. Click **Done**, open **System Settings → Privacy & Security**, and click **Open Anyway** next to the TextPicker message.
3. Grant **Screen Recording** and **Accessibility** when asked.

TextPicker isn't notarized by Apple yet, which is why macOS asks. See the [README](https://github.com/georgiansarghi/TextPicker#install) for details.

### What's new in 0.12.0

- **Permissions now survive updates.** Releases are signed with a stable certificate, so future updates no longer ask for Screen Recording and Accessibility again.
- **About TextPicker** and **Check for Updates…** in the menu. Checking opens this page in your browser; TextPicker still makes no network connections.
- New app identifier: `io.github.georgiansarghi.TextPicker`.
- TextPicker is now MIT-licensed.

### Upgrading from 0.11

Because the app's identity changed, macOS asks for permissions one more time. Remove the old **TextPicker** entries under Screen Recording and Accessibility in System Settings, then grant access again. Your settings carry over. If you use **Launch at Login**, check that it is still on.
