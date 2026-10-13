#!/bin/bash
# Build the native app; optional --install installs only after qualification.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "$ROOT/.venv/bin/python" -B "$ROOT/scripts/package_app.py" "$@"
