#!/bin/bash
# Development tools only; never registers login items or requests permissions.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon macOS is required.' >&2; exit 1; }
for tool in uv cmake; do command -v "$tool" >/dev/null || { echo "Install $tool first." >&2; exit 1; }; done
xcrun --find swiftc >/dev/null
if [ "${OFFLINE:-0}" = 1 ]; then export UV_OFFLINE=1; fi
if [ ! -x .venv/bin/python ]; then uv venv --python 3.12 .venv; fi
.venv/bin/python -c 'import sys; assert sys.version_info[:2] == (3, 12), "Use a Python 3.12 development environment"'
uv pip sync --python .venv/bin/python scripts/requirements-dev.txt
uv pip check --python .venv/bin/python
printf 'Development environment ready. Prepare pinned models as described in docs/BUILDING.md.\n'
