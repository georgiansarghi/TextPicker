#!/usr/bin/env python3
"""Check an opt-in RegionCaptureProbe directory (generated synthetic pixels only)."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    directory = args.directory
    reference = Image.open(directory / "reference.png").convert("RGBA")
    rows = json.loads((directory / "results.json").read_text())
    names = set()
    failures = []
    for row in rows:
        x, y, width, height = map(round, row["reference_rect"])
        expected = np.array(reference.crop((x, y, x + width, y + height)))
        actual = np.array(Image.open(directory / f"{row['case']}-{row['variant']}.png").convert("RGBA"))
        row["dimensions_exact"] = actual.shape == expected.shape
        if not row["dimensions_exact"]:
            failures.append(f"{row['case']}/{row['variant']}: wrong dimensions")
            continue
        delta = np.abs(actual[:, :, :3].astype(int) - expected[:, :, :3].astype(int))
        row["rgb_max_error"] = int(delta.max())
        row["pixels_over_three_levels"] = int(np.any(delta > 3, axis=2).sum())
        row["png_nonopaque"] = int(np.sum(actual[:, :, 3] != 255))
        print(row["case"], row["variant"], "RGB max", row["rgb_max_error"],
              "pixels over 3", row["pixels_over_three_levels"], "nonopaque", row["png_nonopaque"])
        if row["variant"] == "fixed":
            names.add(row["case"])
            # Separate ScreenCaptureKit shots vary by up to two 8-bit RGB levels
            # even in unchanged integer-rectangle controls. This is NOT a
            # bitwise screenshot parity claim. No geometry/alpha tolerance.
            if row["png_nonopaque"] or row["nonopaque_pixels"] != 0 or row["pixels_over_three_levels"]:
                failures.append(f"{row['case']}: alpha or geometry/color mismatch")
    required = {"square", "wide", "tall", "odd-wide", "odd-tall", "normal", "odd-height", "odd-width",
                "odd-both-integer-origin", "odd-square", "fractional-origin-even-size", "minimum-wide", "minimum-tall"}
    if names != required:
        failures.append(f"Missing/unexpected cases: {names ^ required}")
    (directory / "comparison.json").write_text(json.dumps(rows, indent=2) + "\n")
    if failures:
        raise SystemExit("FAIL: " + "; ".join(failures))
    print(f"PASS: {len(names)} fixed live regions; exact dimensions, opaque, RGB differences <=3/255")


if __name__ == "__main__":
    main()
