#!/bin/bash
# Install an already-built, validated bundle. Never rebuild or change preferences here.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE=${1:-"$ROOT/.build/apps/TextPicker.app"}
TARGET="$HOME/Applications/TextPicker.app"
ID=local.textpicker
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" = "$ID" ]
codesign --verify --deep --strict "$SOURCE"
"$ROOT/.venv/bin/python" -B "$ROOT/scripts/verify_bundle.py" "$SOURCE" --release
if pgrep -x TextPicker >/dev/null; then echo 'Quit TextPicker before installing.' >&2; exit 1; fi
mkdir -p "$HOME/Applications"
[ ! -L "$TARGET" ] || { echo 'Refusing a symlink installation target' >&2; exit 1; }
if [ -e "$TARGET" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TARGET/Contents/Info.plist")" = "$ID" ]
fi
STAGE=$(mktemp -d "$HOME/Applications/.textpicker-install.XXXXXX")
BACKUP=
SWAPPED=0
OLD_MOVED=0
SUCCESS=0
cleanup() {
  CODE=$?
  if [ "$SUCCESS" = 0 ]; then
    if [ "$SWAPPED" = 1 ] && [ -e "$TARGET" ]; then mv "$TARGET" "$STAGE/failed.app"; fi
    if [ "$OLD_MOVED" = 1 ] && [ ! -e "$TARGET" ]; then
      mv "$BACKUP" "$TARGET"
      echo 'Installation failed; previous app restored.' >&2
    fi
  fi
  rm -rf "$STAGE"
  exit "$CODE"
}
trap cleanup EXIT
# Verify the actual copied bundle before moving the current installation.
# Clone on APFS when possible (cp falls back to copying on other filesystems).
# This avoids allocating another full runtime bundle on a nearly full disk.
cp -cR "$SOURCE" "$STAGE/TextPicker.app"
codesign --verify --deep --strict "$STAGE/TextPicker.app"
"$ROOT/.venv/bin/python" -B "$ROOT/scripts/verify_bundle.py" "$STAGE/TextPicker.app" --release
if [ -e "$TARGET" ]; then
  BACKUP="$HOME/Applications/TextPicker.previous-$(date +%Y%m%d-%H%M%S)-$$.app"
  [ ! -e "$BACKUP" ]
  mv "$TARGET" "$BACKUP"
  OLD_MOVED=1
fi
mv "$STAGE/TextPicker.app" "$TARGET"
SWAPPED=1
codesign --verify --deep --strict "$TARGET"
open "$TARGET"
SUCCESS=1
printf 'Installed: %s\nRollback: %s\n' "$TARGET" "${BACKUP:-none (first install)}"
