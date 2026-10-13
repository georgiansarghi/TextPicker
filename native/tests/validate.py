"""Native release gate: reproducible synthetic pixels, stages, IPC and isolation."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

from worker_client import Worker

NATIVE = Path(__file__).resolve().parents[1]
ROOT = NATIVE.parent
ENV = {**os.environ, "VECLIB_MAXIMUM_THREADS": "4", "TEXTPICKER_THREADS": "4"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extra_images(directory):
    directory.mkdir()
    image = Image.open(ROOT / "benchmark/fixtures/english.png").convert("RGB")
    for angle in [8, -17, 90]:
        image.rotate(
            angle, resample=Image.Resampling.BICUBIC, expand=True, fillcolor="white"
        ).save(directory / f"rotate{angle}.png")
    image.crop((20, 8, image.width - 12, image.height - 5)).save(
        directory / "edge-clipped.png"
    )
    image.convert("L").save(directory / "grayscale.png")
    german = Image.open(ROOT / "benchmark/fixtures/german.png")
    german.resize((german.width * 2, german.height * 2), Image.Resampling.BICUBIC).save(
        directory / "german-2x.png"
    )
    for name, size in [
        ("one-pixel", (1, 1)),
        ("padded", (17, 20)),
        ("square-max", (1280, 1280)),
        ("panorama", (3000, 100)),
    ]:
        Image.new("RGB", size, "white").save(directory / f"{name}.png")


def run(command, **options):
    return subprocess.run(
        list(map(str, command)),
        env=ENV,
        capture_output=True,
        text=True,
        timeout=60,
        **options,
    )


def validate(options, directory):
    worker = (
        options.bundle / "Contents/MacOS/TextPickerNative"
        if options.bundle
        else options.build / "TextPickerNative"
    )
    models = (
        options.bundle / "Contents/Resources/models/native"
        if options.bundle
        else NATIVE / "models"
    )
    report = {
        "worker_sha256": digest(worker),
        "models": {
            p.name: digest(p)
            for p in models.iterdir()
            if p.suffix in (".weights", ".bin")
        },
        "cases": [],
    }
    build_record = json.loads((options.build / "build-manifest.json").read_text())
    assert build_record["worker_sha256"] == report["worker_sha256"], (
        "Worker was not built with this build manifest"
    )
    assert build_record["probe_sha256"] == digest(options.build / "pipeline_probe"), (
        "Probe build changed"
    )
    report["build"] = build_record
    # Generic NumPy quicksort tie ordering is part of batch-padding semantics.
    random = np.random.default_rng(1511)
    ratios = []
    for length in [0, 1, 2, 6, 15, 16, 17, 20, 47, 100, 3000]:
        ratios += [
            np.zeros(length),
            np.arange(length, dtype=float),
            np.arange(length, dtype=float)[::-1],
            random.random(length),
            random.integers(0, 8, length).astype(float),
        ]
    ratios += [
        random.integers(0, 12, int(random.integers(1, 3001))).astype(float)
        for _ in range(56)
    ]
    ordering = run(
        [options.build / "order_probe"],
        check=True,
        input="".join(
            f"{len(values)} " + " ".join(map(str, values)) + "\n" for values in ratios
        ),
    )
    rows = ordering.stdout.splitlines()
    assert len(rows) == len(ratios)
    for values, row in zip(ratios, rows):
        assert list(map(int, row.split())) == list(np.argsort(values))
    report["ratio_order_cases"] = len(ratios)
    extra_images(directory / "extra")
    cases = json.loads((NATIVE / "tests/reference.json").read_text())["cases"]
    reference = None
    if options.reference_app:
        sys.path.insert(0, str(ROOT / "app"))
        from coreml_backend import CoreMLPipeline, detector_input

        reference = CoreMLPipeline(
            options.reference_app.resolve() / "Contents/Resources"
        )
    try:
        with Worker([worker, models]) as client:
            ready = client.receive(32)
            assert ready["type"] == "ready" and ready["device_policy"] == "CPU", ready
            report["ready"] = ready
            for case in cases:
                parent = (
                    ROOT / "benchmark/fixtures"
                    if case["group"] == "base"
                    else directory / "extra"
                )
                image_path = parent / f"{case['id']}.png"
                image = np.array(Image.open(image_path).convert("RGB"))[
                    :, :, ::-1
                ].copy()
                # ImageIO must reproduce the exact original samples.
                pixels = directory / "decoded.bgra"
                result = run(
                    [options.build / "DecodeProbe", image_path, pixels], check=True
                )
                decoded = np.fromfile(pixels, np.uint8).reshape(*image.shape[:2], 4)
                assert np.array_equal(decoded[:, :, :3], image), case["id"]
                raw = directory / "input.bgr"
                image.tofile(raw)
                trace = directory / case["id"]
                result = run(
                    [
                        options.build / "pipeline_probe",
                        models,
                        raw,
                        image.shape[1],
                        image.shape[0],
                        trace,
                    ],
                    check=True,
                )
                prediction = json.loads(result.stdout)
                assert prediction["text"] == case["text"], (case["id"], prediction)
                actual = {
                    p.name: digest(p)
                    for p in trace.iterdir()
                    if p.name != "det-map.f32"
                }
                assert actual == case["stage_sha256"], (
                    case["id"],
                    "stage bytes changed",
                )
                detector = np.fromfile(trace / "det-map.f32", np.float32)
                assert (
                    detector.size == case["detector_elements"]
                    and np.isfinite(detector).all()
                )
                samples = np.linspace(
                    0, detector.size - 1, min(detector.size, 1024), dtype=int
                )
                assert np.allclose(
                    detector[samples], case["detector_samples"], atol=1e-3, rtol=1e-4
                ), case["id"]
                if reference:
                    tensor, _ = detector_input(image)
                    expected_map = reference.forward(0, tensor).ravel()
                    assert np.allclose(detector, expected_map, atol=1e-3, rtol=1e-4), (
                        case["id"]
                    )
                    assert reference.predict(image) == case["text"], case["id"]
                response = client.request(case["id"], image_path)
                assert (
                    response["type"] == "result" and response["text"] == case["text"]
                ), response
                report["cases"].append(
                    {
                        "id": case["id"],
                        "stages_exact": True,
                        "text_exact": True,
                        "ms": response["ocr_ms"],
                        "peak_probe_rss": prediction["peak_rss_bytes"],
                    }
                )
                # Bounds disk use: reports bind expected stage hashes, not large duplicate tensors.
                shutil.rmtree(trace)

            Image.new("L", (5000, 4000), 255).save(directory / "maximum-source.png")
            response = client.request(
                "maximum-source", directory / "maximum-source.png"
            )
            assert response["type"] == "result" and response["text"] == "", response
            Image.new("L", (5000, 4001), 255).save(directory / "large.png")
            Image.new("RGBA", (32, 32), (100, 20, 80, 128)).save(
                directory / "alpha.png"
            )
            (directory / "broken.png").write_bytes(b"not an image")
            os.mkfifo(directory / "fifo.png", 0o600)
            (directory / "link.png").symlink_to(ROOT / "benchmark/fixtures/english.png")
            for name in ["large", "alpha", "broken", "missing", "fifo", "link"]:
                assert (
                    client.request(name, directory / f"{name}.png")["type"] == "error"
                ), name
            for path in ["relative", "/tmp/\0x"]:
                response = client.send(json.dumps({"id": "correlated", "path": path}))
                assert response["type"] == "error" and response["id"] == "correlated", (
                    response
                )
            for value in [
                "null",
                "[]",
                "{bad json}",
                "x" * 65537,
                json.dumps({"id": "x" * 129, "path": "/tmp/x"}),
            ]:
                assert client.send(value)["type"] == "error"
            response = client.request(
                "recovery", ROOT / "benchmark/fixtures/english.png"
            )
            assert response["text"] == next(
                c["text"] for c in cases if c["id"] == "english"
            )
            client.finish()
        report["invalid_inputs_recovery_eof"] = "passed"
    finally:
        if reference:
            reference.close()
    # Asset corruption tests never alter the production assets.
    for asset in ["detector.weights", "recognizer.weights", "characters.bin"]:
        for corruption in [False, True]:
            with tempfile.TemporaryDirectory(dir=directory) as folder:
                folder = Path(folder)
                for item in models.iterdir():
                    if item.suffix in (".weights", ".bin") and item.name != asset:
                        (folder / item.name).symlink_to(item.resolve())
                if corruption:
                    shutil.copy2(models / asset, folder / asset)
                    with (folder / asset).open("r+b") as stream:
                        stream.seek(80)
                        value = stream.read(1)
                        stream.seek(80)
                        stream.write(bytes([value[0] ^ 1]))
                rejected = run([worker, folder])
                assert (
                    rejected.returncode != 0
                    and json.loads(rejected.stdout)["type"] == "error"
                )
    report["asset_rejections"] = 6
    # Independence test: no repository reads, runtime writes, or network.
    relocated = directory / "isolated"
    relocated.mkdir()
    shutil.copy2(worker, relocated / "Worker")
    (relocated / "models").mkdir()
    for name in report["models"]:
        shutil.copy2(models / name, relocated / "models" / name)
    shutil.copy2(ROOT / "benchmark/fixtures/english.png", relocated / "input.png")
    policy = f'(version 1)(allow default)(deny network*)(deny file-write*)(deny file-read* (subpath "{ROOT}"))'
    with Worker([relocated / "Worker", relocated / "models"], policy) as client:
        assert client.receive(32)["type"] == "ready"
        response = client.request("isolated", relocated / "input.png")
        assert response["text"] == next(
            c["text"] for c in cases if c["id"] == "english"
        )
        client.finish()
    report["relocated_readonly_offline"] = "passed"
    report["full_coreml_map_comparison"] = reference is not None
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=NATIVE / ".build")
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--reference-app", type=Path)
    parser.add_argument(
        "--output", type=Path, default=NATIVE / "results/validation.json"
    )
    options = parser.parse_args()
    options.build = options.build.resolve()
    if options.bundle:
        options.bundle = options.bundle.resolve()
    with tempfile.TemporaryDirectory(prefix="textpicker-native-gate-") as temporary:
        report = validate(options, Path(temporary))
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, indent=2))
    print(
        f"PASS: {len(report['cases'])} exact native image/stage/text cases, boundaries, recovery, assets and isolation"
    )


if __name__ == "__main__":
    main()
