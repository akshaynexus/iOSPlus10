#!/usr/bin/env python3
"""Mi A3 iOS 26: is the picture of a run the same as the picture of a reference run. Docs: docs/laurel_sprout/ios26-default-speed.md.
  scripts/laurel/ios26-png-compare.py REF_DIR RUN_DIR [SHOT...]     dirs: logs/autotest-DATE. No SHOT: all PNG files both have.
One row per shot: share of pixels off by more than 8 of 255 in a channel, mean difference, largest difference, the box of the changed pixels. The status bar (the top 90 rows: clock) does not count.
Exit 0 always: a difference in a shot of an animation is not a fault of the build; read the row, then the PNG."""
import glob
import os
import sys

import numpy as np
from PIL import Image

STATUS_ROWS = 90


def row(a, b):
    a = np.asarray(Image.open(a).convert("RGB"), dtype=np.int16)[STATUS_ROWS:]
    b = np.asarray(Image.open(b).convert("RGB"), dtype=np.int16)[STATUS_ROWS:]
    if a.shape != b.shape:
        return "other size"
    d = np.abs(a - b).max(axis=2)
    off = d > 8
    box = "-"
    if off.any():
        ys, xs = np.nonzero(off)
        box = f"x {xs.min()}-{xs.max()} y {ys.min() + STATUS_ROWS}-{ys.max() + STATUS_ROWS}"
    return f"{100.0 * off.mean():6.2f} % off, mean {d.mean():5.2f}, max {d.max():3d}, {box}"


def main():
    ref, run = sys.argv[1], sys.argv[2]
    names = sys.argv[3:] or sorted(os.path.basename(p) for p in glob.glob(os.path.join(ref, "*.png")))
    for n in names:
        n = n if n.endswith(".png") else n + ".png"
        x, y = os.path.join(ref, n), os.path.join(run, n)
        print(f"{n:32s} {row(x, y) if os.path.exists(x) and os.path.exists(y) else 'not in both'}")


main()
