#!/bin/bash
# One native gate, with fresh temporary data and no historical experiment outputs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-"$HERE/../.venv/bin/python"}
if [ "${1:-}" = --skip-build ]; then shift; else PYTHON="$PYTHON" bash "$HERE/build.sh"; fi
BUILD="$HERE/.build${SANITIZER:+-${SANITIZER//,/-}}"
ctest --test-dir "$BUILD" --output-on-failure
if [ -z "${SANITIZER:-}" ]; then
  "$PYTHON" -B "$HERE/tests/validate.py" --build "$BUILD" "$@"
else
  "$PYTHON" -B "$HERE/tests/sanitizers.py" --build "$BUILD"
fi
