#!/bin/bash
# Build and validate without capturing the screen or changing user state.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[ "$#" = 0 ] || { echo "Usage: bash scripts/test.sh" >&2; exit 2; }
.venv/bin/python -B tests/app/model_pack_tests.py
.venv/bin/python -B tests/app/release_tests.py
bash scripts/build.sh
APP="$ROOT/.build/apps/TextPicker.app"
mkdir -p .build/tests
swift_test() {
  local name=$1
  shift
  swiftc -O -warnings-as-errors -swift-version 5 -target arm64-apple-macos14.0 \
    "$@" -o ".build/tests/$name"
  ".build/tests/$name"
}
swift_test TextPickerTests app/Sources/Support.swift app/Sources/Worker.swift tests/app/Tests.swift -framework AppKit
swift_test InputTests app/Sources/Support.swift app/Sources/Shortcut.swift app/Sources/InputCapture.swift tests/app/InputTests.swift \
  -framework AppKit -framework ApplicationServices
swift_test SelectionTests app/Sources/Support.swift app/Sources/Shortcut.swift app/Sources/InputCapture.swift \
  app/Sources/RegionCapture.swift app/Sources/Capture.swift tests/app/SelectionTests.swift \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit
swift_test RegionCaptureTests app/Sources/Support.swift app/Sources/RegionCapture.swift tests/capture/RegionCaptureTests.swift \
  -framework AppKit -framework ScreenCaptureKit
swift_test PermissionTests app/Sources/Permissions.swift tests/app/PermissionTests.swift -framework AppKit -framework ApplicationServices
swift_test MenuTests app/Sources/Support.swift app/Sources/Shortcut.swift app/Sources/InputCapture.swift \
  app/Sources/Permissions.swift app/Sources/Menu.swift tests/app/MenuTests.swift \
  -framework AppKit -framework ApplicationServices -framework Carbon
swift_test PermissionMenuTests app/Sources/Support.swift app/Sources/Shortcut.swift app/Sources/Permissions.swift \
  app/Sources/Menu.swift tests/app/PermissionMenuTests.swift -framework AppKit -framework ApplicationServices -framework Carbon
swift_test SettingsTests app/Sources/Support.swift app/Sources/LoginItem.swift tests/app/SettingsTests.swift -framework AppKit -framework ServiceManagement
swift_test FeedbackTests app/Sources/Feedback.swift tests/app/FeedbackTests.swift -framework AppKit
.venv/bin/python -B tests/app/bundle_tests.py "$APP"
.venv/bin/python -B tests/app/branding_tests.py "$APP"
.venv/bin/python -B scripts/verify_bundle.py "$APP" --release
codesign --verify --deep --strict "$APP"
.venv/bin/python -B tests/app/install_tests.py "$APP"
git diff --check
echo 'PASS: full app validation; no screen, clipboard, preferences or installation changes'
