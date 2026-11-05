#!/usr/bin/env python3
"""Mi A3 iOS 26: where CoreAnimation's render thread is, by wall time, while it is busy: scripts/laurel/ios26-ca-phases.py SAMPLES THREAD [MIN_BUSY_PERCENT]. SAMPLES: laurel-autotest sample PID S HZ all.
Docs: docs/laurel_sprout/ios26-default-speed.md."""
import bisect
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
g = {"__file__": os.path.join(HERE, "ios26-sample-sym.py"), "__name__": "sym"}
src = open(g["__file__"]).read().replace("\nmain()\n", "\n")
exec(compile(src, g["__file__"], "exec"), g)
path, thread = sys.argv[1], sys.argv[2]
least = int(sys.argv[3]) if len(sys.argv) > 3 else 30
images, rows, now = [], [], None
for line in open(path, errors="replace"):
    p = line.split(None, 2)
    if p and p[0] == "I" and len(p) == 3:
        images.append(g["Image"](int(p[1], 16), p[2].strip()))
    elif p and p[0] == "T":
        now = int(p[1])
    elif p and p[0] == "S":
        f = line.split()
        if f[1] == thread:
            rows.append((now, [int(x, 16) for x in f[2:]]))
images.sort(key=lambda m: m.base)
bases = [m.base for m in images]
known = g["cache_images"]()
memo = {}


def sym(pc):
    if pc not in memo:
        i = bisect.bisect_right(bases, pc) - 1
        memo[pc] = images[i].name(pc, known) if i >= 0 else hex(pc)
    return memo[pc]


ORDER = (("finish_update", "finish_update (swap)"), ("Update19build_hit", "build_hit_test_tree"), ("add_context", "add_context (layer tree)"), ("UpdateD2", "~Update"), ("stop_encoders", "stop_encoders (pass end)"),
         ("start_render_encoder", "start_render_encoder"), ("draw_elements", "draw_elements"), ("create_surface", "create_surface"), ("MetalContext5flush", "flush"), ("render_update", "render_update other"), ("render_for_time", "render_for_time other"))


def label(s):
    names = [sym(pc) for pc in s]
    j = " ".join(names)
    top = names[0]
    if "_mach_msg2_trap" in top and "io_connect" not in j:
        return "idle: mach_msg (waits for work)"
    if "cvwait" in top or "mutexwait" in top or "semwait" in top:
        for k, n in ORDER:
            if k in j:
                return "blocked in " + n
        return "blocked: " + (names[2][:50] if len(names) > 2 else top)
    for k, n in ORDER:
        if k in j:
            return n
    return "other: " + top[:48]


t0 = rows[0][0]
bins = collections.defaultdict(collections.Counter)
for t, s in rows:
    bins[(t - t0) // 500][label(s)] += 1
busy = collections.Counter()
used = 0
for k in sorted(bins):
    total = sum(bins[k].values())
    active = sum(v for a, v in bins[k].items() if not a.startswith("idle"))
    if active * 100 >= least * total:
        busy.update(bins[k])
        used += 1
n = sum(busy.values())
print(f"{used} bins of 500 ms with at least {least} % busy, of {len(bins)}; {n} samples")
for k, v in busy.most_common(26):
    print(f"{100 * v / n:5.1f}  {k}")
