#!/usr/bin/env python3
"""Mi A3 iOS 26: self time of the host encode bench by image, function and inlined function: scripts/laurel/ios26-encode-bench.py PCS BINARY [TOP]. Docs: docs/laurel_sprout/ios26-default-speed.md."""
import bisect
import collections
import os
import subprocess
import sys

path, binary = sys.argv[1], sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
maps, pcs = [], collections.Counter()
for line in open(path, errors="replace"):
    if line.startswith("M "):
        f = line.split()
        lo, hi = (int(x, 16) for x in f[1].split("-"))
        if "x" in f[2] and len(f) > 6:
            maps.append((lo, hi, int(f[3], 16), f[6]))
    elif line.startswith("P "):
        pcs[int(line.split()[1], 16)] += 1
maps.sort()
total = sum(pcs.values())
by_image = collections.Counter()
files = collections.defaultdict(collections.Counter)
keys = [m[0] for m in maps]
for pc, n in pcs.items():
    i = bisect.bisect_right(keys, pc) - 1
    if i >= 0 and pc < maps[i][1]:
        lo, _, off, name = maps[i]
        by_image[os.path.basename(name)] += n
        files[name][pc - lo + off] += n
    else:
        by_image["?"] += n
print(f"{total} samples at 1 kHz")
print("-- image:", [(k, round(100 * v / total, 1)) for k, v in by_image.most_common(8)])
leaf, outer, incl = collections.Counter(), collections.Counter(), collections.Counter()
for name, c in files.items():
    if not os.path.exists(name):
        continue
    ks = list(c)
    # a file offset, as the symbolizer takes for a PIE or a library with a load segment at its offset
    out = subprocess.run(["llvm-symbolizer", "--obj=" + name, "--inlining=true", "--functions=linkage", "--demangle"], input="".join(hex(k) + "\n" for k in ks), capture_output=True, text=True).stdout
    base = os.path.basename(name)
    for k, block in zip(ks, out.split("\n\n")):
        rows = block.strip().split("\n")
        names = [r.split("::h")[0] for r in rows[0::2]]
        if not names:
            continue
        leaf[names[0][-90:]] += c[k]
        outer[names[-1][-90:]] += c[k]
        for n in set(names):
            incl[n[-90:]] += c[k]
print("-- real function (the outermost of the inlined), % of samples")
for k, v in outer.most_common(top):
    print(f"{100 * v / total:5.1f}  {k}")
print("-- with what is inlined in it: inclusive inside one real function")
for k, v in incl.most_common(top):
    print(f"{100 * v / total:5.1f}  {k}")
print("-- leaf")
for k, v in leaf.most_common(top):
    print(f"{100 * v / total:5.1f}  {k}")
