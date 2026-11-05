#!/usr/bin/env python3
"""Mi A3 iOS 26: self time of a thread in NegroniMetal by source line and by inlined function (one fat LTO function hides many). Docs: docs/laurel_sprout/ios26-default-speed.md.
  scripts/laurel/ios26-sample-lines.py SAMPLES THREAD [TOP]   needs llvm-symbolizer and out/ios26/metal-impl/NegroniMetal.dSYM of the same build"""
import bisect
import collections
import glob
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
path, thread = sys.argv[1], sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 30
base = None
pcs = collections.Counter()
total = 0
images = []
for line in open(path, errors="replace"):
    p = line.split(None, 2)
    if p and p[0] == "I" and len(p) == 3:
        images.append((int(p[1], 16), p[2].strip()))
    elif p and p[0] == "S":
        f = line.split()
        if f[1] == thread:
            total += 1
            pcs[int(f[2], 16)] += 1
images.sort()
bases = [b for b, _ in images]
own = collections.Counter()
for pc, n in pcs.items():
    i = bisect.bisect_right(bases, pc) - 1
    if i >= 0 and os.path.basename(images[i][1]) == "NegroniMetal":
        own[pc - images[i][0]] += n
dsym = glob.glob(os.path.join(REPO, "out/ios26/metal-impl/NegroniMetal.dSYM/Contents/Resources/DWARF/*"))[0]
keys = list(own)
out = subprocess.run(["llvm-symbolizer", "--obj=" + dsym, "--inlining=true", "--functions=linkage", "--demangle"], input="".join(hex(k) + "\n" for k in keys), capture_output=True, text=True).stdout
fn, ln = collections.Counter(), collections.Counter()
for k, block in zip(keys, out.split("\n\n")):
    rows = block.strip().split("\n")
    name = rows[0] if rows else "?"
    where = rows[1] if len(rows) > 1 else "?"
    fn[name.split("::h")[0][-70:]] += own[k]
    ln[os.path.basename(where.rsplit(":", 1)[0]) + " " + name.split("::h")[0][-40:]] += own[k]
s = sum(own.values())
print(f"thread {thread}: {total} samples, {s} in NegroniMetal ({100 * s / max(total, 1):.1f} %)")
print("-- leaf function, % of thread")
for k, v in fn.most_common(top):
    print(f"{100 * v / total:5.1f}  {k}")
print("-- source line")
for k, v in ln.most_common(top):
    print(f"{100 * v / total:5.1f}  {k}")
