"""Full C++ pipeline sanitizer probes; synthetic inputs, no research-tree dependency."""

import argparse
import json
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image
from validate import NATIVE, ROOT, digest, run

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build", required=True, type=Path)
options = parser.parse_args()
probe = options.build.resolve() / "pipeline_probe"
english = Image.open(ROOT / "benchmark/fixtures/english.png").convert("RGB")
cases = {
    "english": english,
    "rotated": english.rotate(
        -17, resample=Image.Resampling.BICUBIC, expand=True, fillcolor="white"
    ),
    "maximum": Image.new("RGB", (1280, 1280), "white"),
}
report = {"probe_sha256": digest(probe), "cases": {}}
with tempfile.TemporaryDirectory(prefix="textpicker-sanitizers-") as temporary:
    path = Path(temporary) / "input.bgr"
    for name, image in cases.items():
        np.array(image)[:, :, ::-1].copy().tofile(path)
        result = run(
            [probe, NATIVE / "models", path, image.width, image.height], check=True
        )
        if result.stderr:
            raise RuntimeError(result.stderr)
        report["cases"][name] = json.loads(result.stdout)
output = NATIVE / "results" / (options.build.name + ".json")
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps(report, indent=2))
print(
    "PASS: full C++ pipeline sanitizer cases (third-party OpenCV is not instrumented)"
)
