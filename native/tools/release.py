"""Bind packaged native code/assets to passing tests and record build provenance."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from prepare import ROOT, verify_models
from build_record import inputs


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    bundle = options.bundle.resolve()
    worker = bundle / "Contents/MacOS/TextPickerNative"
    assets = bundle / "Contents/Resources/models/native"
    report = json.loads(options.report.read_text())
    verify_models(assets)
    baseline = json.loads((ROOT / "tests/reference.json").read_text())
    if (not report["full_detector_reference_comparison"]
        or report["detector_reference_sha256"] != baseline["detector_maps"]["sha256"]
        or report["ratio_order_cases"] != 111):
        raise RuntimeError("Full detector-reference / ratio-ordering gate is incomplete")
    if report["build"]["inputs"] != inputs():
        raise RuntimeError(
            "Native sources changed after build/test; rebuild and rerun validation"
        )
    if report["build"]["worker_sha256"] != report["worker_sha256"]:
        raise RuntimeError("Worker build/test evidence mismatch")
    if report["worker_sha256"] != sha(worker):
        raise RuntimeError("Packaged native worker differs from the tested worker")
    if (
        report["models"]
        != json.loads((ROOT / "models/manifest.json").read_text())["files"]
    ):
        raise RuntimeError("Tested model assets differ from the release assets")
    if len(report["cases"]) != 25 or not all(
        row["text_exact"] and row["stages_exact"] for row in report["cases"]
    ):
        raise RuntimeError("Native image/stage/text gate is incomplete")
    if (
        report["invalid_inputs_recovery_eof"] != "passed"
        or report["asset_rejections"] != 6
        or report["relocated_readonly_offline"] != "passed"
    ):
        raise RuntimeError("Native safety/isolation gate is incomplete")
    links = subprocess.check_output(["otool", "-L", worker], text=True)
    for line in links.splitlines()[1:]:
        if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
            raise RuntimeError(f"Non-system native dependency: {line}")
        if any(
            name in line
            for name in [
                "CoreML.framework",
                "onnxruntime",
                "Python",
                "opencv",
                "libmlx",
            ]
        ):
            raise RuntimeError(f"Unexpected native inference dependency: {line}")
    subprocess.run(["codesign", "--verify", "--strict", worker], check=True)
    source_hashes = {}
    for directory in ["src", "worker", "tools", "models", "tests"]:
        for path in (ROOT / directory).rglob("*"):
            if path.is_file() and path.suffix in [
                ".cpp",
                ".hpp",
                ".h",
                ".swift",
                ".py",
                ".json",
                ".npz",
            ]:
                source_hashes[str(path.relative_to(ROOT))] = sha(path)
    provenance = {
        "worker_sha256": sha(worker),
        "assets": report["models"],
        "validation_sha256": sha(options.report),
        "source_sha256": source_hashes,
        "dependencies_sha256": sha(ROOT / "dependencies.json"),
        "cmake_sha256": sha(ROOT / "CMakeLists.txt"),
        "system_linkage": links,
        "clang": subprocess.check_output(["xcrun", "clang++", "--version"], text=True),
        "swift": subprocess.check_output(["swiftc", "--version"], text=True),
        "native_payload_bytes": worker.stat().st_size
        + sum(path.stat().st_size for path in assets.iterdir()),
        "gate": "passed",
    }
    destination = options.output or options.report.with_name("native-release.json")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(provenance, indent=2))
    print("PASS: native release is bound to tested code/assets and system-only linkage")


if __name__ == "__main__":
    main()
