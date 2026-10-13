#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-python3}
SANITIZER=${SANITIZER:-}
BUILD="${HERE}/../.build/native${SANITIZER:+-${SANITIZER//,/-}}"
# Offline builds reject missing cache entries rather than silently fetching.
OPTIONS=()
if [ "${OFFLINE:-0}" = 1 ]; then OPTIONS+=(--offline); fi
"$PYTHON" -B "$HERE/tools/prepare.py" dependencies ${OPTIONS[@]+"${OPTIONS[@]}"}
"$PYTHON" -B "$HERE/tools/prepare.py" verify
"$PYTHON" -B "$HERE/tools/generate.py" --check
cmake -S "$HERE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DTEXT_PICKER_SANITIZER="$SANITIZER"
cmake --build "$BUILD" --parallel "${BUILD_JOBS:-4}"
if [ -z "$SANITIZER" ]; then
  codesign --verify --strict "$BUILD/TextPickerNative"
  "$PYTHON" -B "$HERE/tools/build_record.py" "$BUILD"
fi
printf 'Native build: %s\n' "$BUILD"
