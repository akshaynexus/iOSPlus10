#!/usr/bin/env python3
"""Mi A3 iOS 26: the sum of the LAUREL GPU PASS lines of a part of a USB log. Docs: docs/laurel_sprout/ios26-default-speed.md.
  scripts/laurel/ios26-gpu-pass-sum.py FILE     FILE: a part of the log (scripts/laurel/ios26-default-bench.sh writes logs/bench-NAME.kernel.txt)
Per process: GPU ms in all, in render passes, in compute, in blits, and the kinds of work that take the most. Then the frames of the run (LAUREL FRAME: motion)."""
import collections
import re
import sys

HEAD = re.compile(r"LAUREL GPU PASS: on: (\S+): (\d+) ms: GPU (\d+) ms: (\d+) passes, (\d+) blits (\d+) ms, (\d+) compute (\d+) ms, (\d+) clears (\d+) ms")
PASS = re.compile(r"LAUREL GPU PASS:   (gmem|sysmem) (\d+x\d+) (\d+) att (\d+) tiles x(\d+): (\d+) ms, (\d+) us each, (\d+) draws each;(.*)")
COMP = re.compile(r"LAUREL GPU PASS:   compute (\d+x\d+), (\d+x\d+) groups( indirect)? x(\d+): (\d+) ms, (\d+) us each")
MOTION = re.compile(r"LAUREL FRAME: motion ended: (\d+) frames in (\d+) ms")
RED = re.compile(r"RedwoodGPU: (\d+) submissions in (\d+) ms: .*GPU busy ([\d.]+) %, clock (\d+) MHz")

procs = collections.defaultdict(lambda: dict(win=0, gpu=0, passes=0, pass_n=0, blit=0, comp=0, comp_n=0, kinds=collections.Counter(), n=collections.Counter(), shapes=collections.Counter(), sn=collections.Counter()))
cur = None
frames = ms = 0
busy = 0.0
span = 0
for line in open(sys.argv[1], errors="replace"):
    m = HEAD.search(line)
    if m:
        cur = procs[m[1]]
        cur["win"] += int(m[2]); cur["gpu"] += int(m[3]); cur["pass_n"] += int(m[4]); cur["blit"] += int(m[6]); cur["comp_n"] += int(m[7]); cur["comp"] += int(m[8])
        continue
    m = PASS.search(line)
    if m and cur:
        k = f"{m[1]} {m[2]} {m[4]}t"
        cur["kinds"][k] += int(m[6]); cur["n"][k] += int(m[5])
        continue
    m = COMP.search(line)
    if m and cur:
        k = f"{m[1]} x {m[2]}"
        cur["shapes"][k] += int(m[5]); cur["sn"][k] += int(m[4])
        continue
    m = MOTION.search(line)
    if m:
        frames += int(m[1]); ms += int(m[2])
    m = RED.search(line)
    if m:
        span += int(m[2]); busy += float(m[3]) / 100 * int(m[2])
if ms:
    print(f"motion: {frames} frames in {ms} ms = {1000.0 * frames / ms:.1f} fps")
if span:
    print(f"GPU busy (kernel): {busy / span * 100:.1f} % of {span} ms")
for name, p in sorted(procs.items(), key=lambda kv: -kv[1]["gpu"]):
    print(f"{name}: GPU {p['gpu']} ms of {p['win']} ms: passes {p['gpu'] - p['comp'] - p['blit']} ms ({p['pass_n']}), compute {p['comp']} ms ({p['comp_n']}), blit {p['blit']} ms")
    for k, v in p["shapes"].most_common(5):
        print(f"    compute {k}: {v} ms, x{p['sn'][k]}, {1000 * v // max(p['sn'][k], 1)} us each")
    for k, v in p["kinds"].most_common(5):
        print(f"    {k}: {v} ms, x{p['n'][k]}, {1000 * v // max(p['n'][k], 1)} us each")
