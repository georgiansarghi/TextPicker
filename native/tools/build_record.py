"""Record source and binary identities only after a successful native build."""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    paths = [ROOT / "CMakeLists.txt", ROOT / "dependencies.json", ROOT / "build.sh"]
    for folder in ["src", "worker", "models", "tools", "tests"]:
        paths += [
            path
            for path in (ROOT / folder).rglob("*")
            if path.is_file()
            and path.suffix in (".cpp", ".hpp", ".h", ".swift", ".json", ".py")
        ]
    return {str(path.relative_to(ROOT)): sha(path) for path in sorted(paths)}


if __name__ == "__main__":
    build = Path(sys.argv[1])
    record = {
        "inputs": inputs(),
        "worker_sha256": sha(build / "TextPickerNative"),
        "probe_sha256": sha(build / "pipeline_probe"),
    }
    (build / "build-manifest.json").write_text(json.dumps(record, indent=2))
