"""Benchmark the OCR worker of a built app, optionally against a baseline build.

Requests alternate between the two workers round by round, so background load
affects both sides equally. Inputs are the committed fixtures plus deterministic
screen-sized composites; nothing reads the real screen or clipboard.

  bench.py APP                                   # timings for one build
  bench.py APP --baseline ~/Applications/TextPicker.app
  bench.py APP --baseline release:latest --max-regression 15
"""
import argparse
import hashlib
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
RELEASES = "https://github.com/georgiansarghi/TextPicker/releases"
ARCHIVE = "TextPicker-arm64.zip"


def composite(name, size, fixtures, directory):
    """Tile fixtures row by row onto an opaque canvas, like a busy screen region."""
    canvas = Image.new("RGB", size, "white")
    x = y = row = 0
    for path in fixtures * 8:
        tile = Image.open(path).convert("RGB")
        if x + tile.width > size[0]:
            x, y, row = 0, y + row, 0
        if y + tile.height > size[1]:
            break
        canvas.paste(tile, (x, y))
        x, row = x + tile.width, max(row, tile.height)
    path = directory / f"{name}.png"
    canvas.save(path)
    return path


def workloads(directory):
    manifest = json.loads((ROOT / "tests/fixtures/manifest.json").read_text())
    fixtures = [ROOT / entry["path"] for entry in manifest]
    items = {path.stem: path for path in fixtures}
    items["window-1600x1000"] = composite("window-1600x1000", (1600, 1000), fixtures, directory)
    items["screen-2560x1440"] = composite("screen-2560x1440", (2560, 1440), fixtures, directory)
    return items


def download(url, target):
    with urllib.request.urlopen(url, timeout=120) as response, open(target, "wb") as output:
        while chunk := response.read(1 << 20):
            output.write(chunk)


def resolve_app(spec, directory):
    """Accept an .app, a release ZIP or release:<tag|latest>; return the .app path."""
    if spec.startswith("release:"):
        tag = spec.split(":", 1)[1]
        base = f"{RELEASES}/latest/download" if tag == "latest" else f"{RELEASES}/download/{tag}"
        archive, sums = directory / ARCHIVE, directory / "SHA256SUMS.txt"
        download(f"{base}/{ARCHIVE}", archive)
        download(f"{base}/SHA256SUMS.txt", sums)
        expected = next(line.split()[0] for line in sums.read_text().splitlines() if line.endswith(ARCHIVE))
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != expected:
            sys.exit(f"Checksum mismatch for {spec}: {actual} != {expected}")
        spec = str(archive)
    path = Path(spec).expanduser().resolve()
    if path.suffix == ".zip":
        extracted = directory / ("extracted-" + path.stem)
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(path), str(extracted)], check=True)
        path = next(extracted.glob("*.app"))
    if not (path / "Contents/MacOS/TextPickerNative").is_file():
        sys.exit(f"Not a TextPicker app bundle: {path}")
    return path


def app_version(app):
    plist = app / "Contents/Info.plist"
    read = lambda key: subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Print {key}", str(plist)],
                                      capture_output=True, text=True).stdout.strip()
    return f"{read('CFBundleShortVersionString')} ({read('CFBundleVersion')})"


class Worker:
    """The same launch contract as the app: 4 threads, Resources as cwd, no network."""

    def __init__(self, app):
        resources = app / "Contents/Resources"
        self.process = subprocess.Popen(
            ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
             str(app / "Contents/MacOS/TextPickerNative"), str(resources / "models/native")],
            cwd=resources, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, env={**os.environ, "VECLIB_MAXIMUM_THREADS": "4", "TEXTPICKER_THREADS": "4",
                            "OPENCV_LOG_LEVEL": "ERROR"})
        ready = json.loads(self.process.stdout.readline() or "{}")
        if ready.get("type") != "ready":
            sys.exit(f"Worker in {app} did not start: {ready}")
        self.load_ms = ready["load_ms"]

    def recognize(self, path):
        start = time.perf_counter()
        self.process.stdin.write(json.dumps({"id": "bench", "path": str(path)}) + "\n")
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        wall = (time.perf_counter() - start) * 1000
        if reply.get("type") != "result":
            sys.exit(f"Recognition failed for {path.name}: {reply}")
        return reply["ocr_ms"], wall, reply["text"]

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)


def geomean(values):
    return math.exp(statistics.fmean(math.log(v) for v in values))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", help="candidate .app, release ZIP or release:<tag|latest>")
    parser.add_argument("--baseline", help="build to compare against (same forms as APP)")
    parser.add_argument("--rounds", type=int, default=10, help="measured rounds after one warm-up round")
    parser.add_argument("--only", nargs="+", help="limit to these workload names")
    parser.add_argument("--max-regression", type=float,
                        help="fail if the candidate is this many percent slower overall")
    parser.add_argument("--require-identical", action="store_true",
                        help="fail if any recognized text differs from the baseline")
    parser.add_argument("--output", type=Path, help="write the full JSON report here")
    parser.add_argument("--summary", type=Path, help="append a Markdown table (e.g. $GITHUB_STEP_SUMMARY)")
    args = parser.parse_args()
    if (args.max_regression is not None or args.require_identical) and not args.baseline:
        parser.error("--max-regression and --require-identical need --baseline")

    with tempfile.TemporaryDirectory(prefix="textpicker-bench-") as temp:
        temp = Path(temp)
        items = workloads(temp)
        if args.only:
            items = {name: items[name] for name in args.only}
        builds = {"candidate": resolve_app(args.app, temp)}
        if args.baseline:
            builds["baseline"] = resolve_app(args.baseline, temp)
        workers = {name: Worker(app) for name, app in builds.items()}
        samples = {name: {item: [] for item in items} for name in builds}
        texts = {name: {} for name in builds}
        order = list(builds)
        for round_index in range(args.rounds + 1):
            for item, path in items.items():
                # Alternate who goes first so neither side always runs on a warmer cache.
                for name in (order if round_index % 2 else order[::-1]):
                    ocr_ms, wall_ms, text = workers[name].recognize(path)
                    texts[name][item] = text
                    if round_index:
                        samples[name][item].append(ocr_ms)
        load = {name: worker.load_ms for name, worker in workers.items()}
        versions = {name: app_version(app) for name, app in builds.items()}
        for worker in workers.values():
            worker.close()

    rows = []
    for item in items:
        row = {"workload": item, **{f"{name}_ms": statistics.median(samples[name][item]) for name in builds}}
        if args.baseline:
            # Median of paired per-round ratios resists bursts of background load.
            row["ratio"] = statistics.median(c / b for c, b in zip(samples["candidate"][item],
                                                                    samples["baseline"][item]))
            row["text_identical"] = texts["candidate"][item] == texts["baseline"][item]
        rows.append(row)

    report = {
        "machine": {"cpu": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True,
                                          text=True).stdout.strip(),
                    "macos": platform.mac_ver()[0], "load_average": os.getloadavg()},
        "rounds": args.rounds,
        "builds": {name: {"path": str(app), "version": versions[name], "load_ms": load[name]}
                   for name, app in builds.items()},
        "workloads": rows,
    }
    if args.baseline:
        report["overall_ratio"] = geomean([row["ratio"] for row in rows])
        report["changed_text"] = [row["workload"] for row in rows if not row["text_identical"]]

    columns = ["candidate_ms"] + (["baseline_ms", "ratio"] if args.baseline else [])
    lines = ["| workload | " + " | ".join(columns) + " |", "|---" * (len(columns) + 1) + "|"]
    for row in rows:
        cells = [f"{row[c]:.0f}" if c.endswith("_ms") else f"{row[c]:.3f}" for c in columns]
        mark = "" if row.get("text_identical", True) else " (text differs)"
        lines.append(f"| {row['workload']}{mark} | " + " | ".join(cells) + " |")
    print(f"Candidate: {report['builds']['candidate']['version']}"
          + (f"   Baseline: {report['builds']['baseline']['version']}" if args.baseline else ""))
    print(f"{report['machine']['cpu']}, load average {report['machine']['load_average'][0]:.1f}; "
          f"median OCR ms over {args.rounds} rounds")
    if report["machine"]["load_average"][0] > (os.cpu_count() or 8) / 2:
        print("Warning: the machine is busy; absolute times are inflated (ratios stay comparable).")
    print("\n".join(lines))
    verdict = []
    if args.baseline:
        change = (report["overall_ratio"] - 1) * 100
        verdict.append(f"Overall: candidate is {abs(change):.1f}% {'slower' if change > 0 else 'faster'} "
                       f"(geometric mean ratio {report['overall_ratio']:.3f}).")
        if report["changed_text"]:
            verdict.append("Recognized text differs for: " + ", ".join(report["changed_text"]))
    print("\n".join(verdict))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2))
    if args.summary:
        with open(args.summary, "a") as summary:
            summary.write("### OCR benchmark\n\n" + "\n".join(lines) + "\n\n" + "\n".join(verdict) + "\n")

    failed = False
    if args.max_regression is not None and report["overall_ratio"] > 1 + args.max_regression / 100:
        print(f"FAIL: slower than the {args.max_regression:g}% regression budget", file=sys.stderr)
        failed = True
    if args.require_identical and report["changed_text"]:
        print("FAIL: recognized text changed", file=sys.stderr)
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
