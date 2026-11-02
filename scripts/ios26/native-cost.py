#!/usr/bin/env python3
"""native-cost.py USBLOG: the numbers of the cost model in docs/laurel_sprout/ios26-native-metal.md, read from a phone's USB log. Only RedwoodGPU's 5 s windows and LAUREL CPU TOP. Run with python3 -I."""
import re
import statistics as st
import sys

W = re.compile(r"(\d\d:\d\d:\d\d) RedwoodGPU: (\d+) submissions in (\d+) ms: (\d+) command buffers and (\d+) buffers named, (\d+) KB out of the cache in (\d+) us a submission; GPU busy ([\d.]+) %, clock (\d+) MHz")
T = re.compile(r"RedwoodGPU: the GPU worked (\d+) us on each of (\d+) \(.*?(\d+) longer; (\d+) ms in all")
P = re.compile(r"GPU pool (\d+) of (\d+) MB free")
L = re.compile(r"a submission: (\d+) us before the lock, (\d+) us with it")
S = re.compile(r"(\d+) surface pushes, (\d+) passed over")
C = re.compile(r"LAUREL CPU TOP: 60 s, busy ([\d.]+) s of 480: (.*?); ended tasks ([\d.]+)")
win, cpu = [], []
pool = gpu = held = push = None
for line in open(sys.argv[1], errors="replace"):
    m = P.search(line)
    if m:
        pool = int(m[1])
    m = W.search(line)
    if m:
        win.append(dict(t=m[1], sub=int(m[2]), ms=int(m[3]), cb=int(m[4]), named=int(m[5]), kb=int(m[6]), us=int(m[7]), busy=float(m[8]), mhz=int(m[9]), pool=pool, gpu_us=None, long=None, held=None, push=None))
    m = T.search(line)
    if m and win:
        win[-1].update(gpu_us=int(m[1]), long=int(m[3]))
    m = S.search(line)
    if m and win:
        win[-1].update(push=int(m[1]))
    m = L.search(line)
    if m and win:
        win[-1].update(held=int(m[2]))
    m = C.search(line)
    if m:
        bb = re.search(r"backboardd ([\d.]+)", m[2])
        cpu.append((float(m[1]), float(bb[1]) if bb else 0.0, float(m[3])))


def show(name, rows, key):
    v = sorted(r[key] for r in rows if r[key] is not None)
    if v:
        print(f"{name:32} min {v[0]:>10} p50 {st.median(v):>10} p90 {v[int(len(v) * 0.9)]:>10} max {v[-1]:>10}")


print(f"windows {len(win)}; GPU busy >= 30 %: {sum(w['busy'] >= 30 for w in win)}")
busy = [w for w in win if w["busy"] >= 30]
for name, rows in (("all windows", win), ("busy >= 30 %", busy)):
    print("--", name)
    show("submissions per window", rows, "sub")
    show("command buffers per window", rows, "cb")
    show("buffers named per window", rows, "named")
    show("KB pushed out of the cache", rows, "kb")
    show("surface pushes per window", rows, "push")
    show("us in the kernel per submission", rows, "us")
    show("us with the lock per submission", rows, "held")
    show("GPU us per submission", rows, "gpu_us")
    show("GPU busy %", rows, "busy")
    show("clock MHz", rows, "mhz")
    show("pool MB free", rows, "pool")
r = [(w["named"] / w["sub"], w["cb"] / w["sub"]) for w in busy if w["sub"]]
if r:
    print(f"per submission, busy windows: p50 {st.median(x[0] for x in r):.0f} buffers named, {st.median(x[1] for x in r):.1f} command buffers")
if busy:
    s = sum(w["sub"] for w in busy)
    print(f"busy windows: total {s} submissions; {sum(w['named'] for w in busy)} names; {sum(w['kb'] for w in busy) / 1024:.0f} MB pushed; kernel {sum(w['us'] * w['sub'] for w in busy) / 1e6:.1f} s of CPU in {sum(w['ms'] for w in busy) / 1e3:.0f} s")
print("-- LAUREL CPU TOP (seconds per 60 s, 480 available)")
if cpu:
    a = sorted(x[1] for x in cpu)
    print(f"minutes {len(cpu)}; backboardd: p50 {st.median(a)} max {a[-1]} ({a[-1] / 60 * 100:.0f} % of one core); busy total p50 {st.median(x[0] for x in cpu)}")
