#!/usr/bin/env python3
"""Mi A3 iOS 26: CPU per thread between two samples of `ps -M`, as scripts/laurel/ios26-default-bench.sh takes them. Threads have no names here: the line number, the priority and the times tell them."""
import re
import sys

ROW = re.compile(r"\s+([\d.]+)\s+\S+\s+(\d+\S*)\s+(\d+):(\d+\.\d+)\s+(\d+):(\d+\.\d+)")


def read(path):
    out, cur = {}, None
    for line in open(path):
        if line.startswith("== "):
            cur = line.split()[1]
            out[cur] = []
            continue
        m = ROW.search(line)
        if m and cur:
            out[cur].append((m[2], 60 * int(m[3]) + float(m[4]), 60 * int(m[5]) + float(m[6])))
    return out


a, b = read(sys.argv[1]), read(sys.argv[2])
for name in b:
    rows = []
    for i, (pri, st, ut) in enumerate(b[name]):
        s0, u0 = (a.get(name, []) + [(0, 0, 0)] * 500)[i][1:] if i < len(a.get(name, [])) else (0, 0)
        rows.append((st - s0 + ut - u0, st - s0, i, pri))
    rows.sort(reverse=True)
    print(f"cpu {name}: {sum(r[0] for r in rows):.2f} s in all: " + ", ".join(f"#{r[2]} pri {r[3]} {r[0]:.2f} s (sys {r[1]:.2f})" for r in rows[:5]))
