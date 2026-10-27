#!/usr/bin/env python3
"""Frame-rate report from a USB log (logs/usblog-*.txt): what limits the UI frame rate.

  scripts/display/fbstat-report.py LOG [--from HH:MM:SS] [--to HH:MM:SS] [--active N]

Reads the once-a-second kernel lines:
  NEGRONI FB STAT:  swaps/s, presents/s, copy, late ticks, swapwait calls/timeouts, gpu-wait skips (0252/0254)
  NEGRONI FB DBUF:  flips/s, waits (0269)
  NEGRONI FB VRR:   idle / active switches (0259)
  NEGRONI GPU DCVS: governor level and MHz, busy %, late frames, ui swaps/s (0384; also 0281/0286 lines)
  NEGRONI GPU PACE: the 0389 frame-pacing floor of the GPU governor (if present)
  NEGRONI FB TE:    the TE lock (0259; 0389 locks on the 0295 rd_ptr interrupt)
and prints: the histogram of swaps/s and presents/s in active seconds (swaps/s >= --active, default 10),
the means of the counters, the frame rate by GPU clock band, and the VRR wake latency (first swap second
after an idle period -> seconds until presents/s >= 100). Lines may be cut or glued to other lines in the
USB log: each field is searched anywhere in the line.
"""
import re
import sys
from collections import defaultdict

STAT = re.compile(r"NEGRONI FB STAT: swaps/s (\d+) presents/s (\d+) \(cpu (\d+) gpu (\d+) zc (\d+)\) copy avg/max us "
                  r"(\d+)/(\d+) late ticks (\d+) swapwait calls (\d+) waited us avg/max (\d+)/(\d+) timeouts (\d+) "
                  r"gpu-wait skips (\d+) gave-up (\d+)")
DBUF = re.compile(r"NEGRONI FB DBUF: flips/s (\d+) waits (\d+) in-place (\d+) latch max us (\d+)")
DCVS = re.compile(r"NEGRONI GPU DCVS: level (\d+) -> (\d+) \((\d+) MHz.*?busy (\d+)%.*?late frames (\d+).*?ui (\d+) swaps/s")
PACE = re.compile(r"NEGRONI GPU PACE: floor (\d+) \(max (\d+) this second\), level (\d+) \((\d+) MHz\), held frames (\d+), swaps (\d+)")
TE = re.compile(r"NEGRONI FB TE: te/s (\d+) .*?locked (\d+)/(\d+) ticks \(no sample (\d+)\).*?autorefresh (0x[0-9a-f]+)")
BEHIND = re.compile(r"gave-up \d+ gpu-behind (\d+)")
VRR_IDLE = re.compile(r"NEGRONI FB VRR: idle \d+ Hz \(hold")
VRR_ACT = re.compile(r"NEGRONI FB VRR: active 120 Hz after (\d+) ms idle")
TS = re.compile(r"^(\d\d):(\d\d):(\d\d) ")


def secs(t):
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def hist(vals, step=10, top=130):
    out = []
    n = len(vals) or 1
    for lo in range(0, top, step):
        c = sum(1 for v in vals if lo <= v < lo + step)
        out.append(f"  {lo:3d}-{lo + step - 1:3d}: {c:5d} ({100.0 * c / n:5.1f} %) {'#' * int(60 * c / n)}")
    c = sum(1 for v in vals if v >= top)
    out.append(f"  >= {top}: {c:5d} ({100.0 * c / n:5.1f} %)")
    return "\n".join(out)


def mean(v):
    return sum(v) / len(v) if v else 0.0


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    t_from = t_to = None
    active = 10
    i = 1
    while i < len(args):
        if args[i] == "--from":
            t_from = secs(args[i + 1]); i += 2
        elif args[i] == "--to":
            t_to = secs(args[i + 1]); i += 2
        elif args[i] == "--active":
            active = int(args[i + 1]); i += 2
        else:
            print(f"unknown argument {args[i]}", file=sys.stderr)
            return 2
    stats, dbuf, dcvs, pace, events, te, behind = [], {}, {}, [], [], [], 0
    day = 0
    last_t = -1
    with open(path, "rb") as f:
        for raw in f:
            line = raw.decode("utf-8", "replace")
            m = TS.match(line)
            if not m:
                continue
            t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            if t + 43200 < last_t:
                day += 86400     # midnight
            last_t = t
            tt = t + day
            if t_from is not None and t < t_from:
                continue
            if t_to is not None and t > t_to:
                continue
            for s in STAT.finditer(line):
                stats.append((tt, [int(x) for x in s.groups()]))
            s = DBUF.search(line)
            if s:
                dbuf[tt] = [int(x) for x in s.groups()]
            s = DCVS.search(line)
            if s:
                dcvs[tt] = [int(x) for x in s.groups()]
            s = PACE.search(line)
            if s:
                pace.append((tt, [int(x) for x in s.groups()]))
            s = TE.search(line)
            if s:
                te.append(s.groups())
            s = BEHIND.search(line)
            if s:
                behind += int(s.group(1))
            if VRR_IDLE.search(line):
                events.append((tt, "idle", 0))
            s = VRR_ACT.search(line)
            if s:
                events.append((tt, "active", int(s.group(1))))
    act = [(t, v) for t, v in stats if v[0] >= active]
    print(f"{path}: {len(stats)} FB STAT seconds, {len(act)} active (swaps/s >= {active})")
    if not act:
        return 0
    sw = [v[0] for _, v in act]
    pr = [v[1] for _, v in act]
    print("swaps/s in active seconds:\n" + hist(sw))
    print("presents/s in active seconds:\n" + hist(pr))
    names = ["swaps", "presents", "cpu", "gpu", "zc", "copy avg us", "copy max us", "late ticks", "swapwait calls",
             "waited avg", "waited max", "timeouts", "gpu-wait skips", "gave-up"]
    print("means in active seconds:")
    for k, n in enumerate(names):
        print(f"  {n:15s} {mean([v[k] for _, v in act]):8.1f}   max {max(v[k] for _, v in act)}")
    tot_sw, tot_pr = sum(sw), sum(pr)
    tot_skip = sum(v[12] for _, v in act)
    tot_to = sum(v[11] for _, v in act)
    print(f"totals: swaps {tot_sw} presents {tot_pr} gpu-wait skips {tot_skip} ({100.0 * tot_skip / max(tot_pr, 1):.0f} % "
          f"of presents) swapwait busy {tot_to} ({tot_to / max(tot_sw, 1):.2f} per swap)")
    late = [v[7] for _, v in act if v[7] > 0]
    print(f"seconds with late ticks: {len(late)} of {len(act)}; copy max >= 4000 us in "
          f"{sum(1 for _, v in act if v[6] >= 4000)} seconds")
    if dbuf:
        dw = [dbuf[t][1] for t, _ in act if t in dbuf]
        print(f"DBUF waits (no free panel buffer) mean {mean(dw):.1f}/s in {len(dw)} active seconds")
    # frame rate by the GPU clock: the DCVS line is printed only in seconds with a change; carry the
    # last level forward (the governor may step 10 times inside one second, so this is the end level)
    if dcvs:
        mhz = None
        bands = defaultdict(list)
        busy = defaultdict(list)
        lastd = sorted(dcvs)
        j = 0
        for t, v in stats:
            while j < len(lastd) and lastd[j] <= t:
                mhz = dcvs[lastd[j]][2]
                j += 1
            if v[0] >= active and mhz is not None:
                b = "220-317" if mhz <= 317 else "350-492" if mhz <= 492 else "545-680" if mhz <= 680 else "730-818"
                bands[b].append(v)
                if t in dcvs:
                    busy[b].append(dcvs[t][3])
        print("by GPU clock at the end of the second (DCVS level carried forward):")
        for b in ("220-317", "350-492", "545-680", "730-818"):
            v = bands.get(b, [])
            if v:
                print(f"  {b:8s} MHz: {len(v):5d} s  swaps/s {mean([x[0] for x in v]):5.1f} presents/s "
                      f"{mean([x[1] for x in v]):5.1f} skips/s {mean([x[12] for x in v]):5.1f} busy/s "
                      f"{mean([x[11] for x in v]):5.1f}  GMU busy {mean(busy.get(b, [])):4.1f} %")
        ch = [dcvs[t] for t, _ in act if t in dcvs]
        if ch:
            print(f"DCVS in active seconds: {len(ch)} seconds with a change line, end level mean "
                  f"{mean([c[1] for c in ch]):.1f}, MHz mean {mean([c[2] for c in ch]):.0f}, GMU busy mean "
                  f"{mean([c[3] for c in ch]):.1f} %, at level <= 3 in {sum(1 for c in ch if c[1] <= 3)}")
    # VRR wake: from the 'active 120 Hz' line to the first second with presents/s >= 100 (if any within 5 s)
    wakes = [(t, ms) for t, k, ms in events if k == "active"]
    if wakes:
        byt = dict(stats)
        firsts = []
        for t, _ in wakes:
            p = [byt.get(t + d, [0, 0])[1] for d in range(0, 3)]
            firsts.append(p)
        print(f"VRR wakes: {len(wakes)}; presents/s in the wake second and the 2 after (mean): "
              f"{mean([p[0] for p in firsts]):.1f} {mean([p[1] for p in firsts]):.1f} {mean([p[2] for p in firsts]):.1f}")
    if pace:
        print(f"PACE (0389): {len(pace)} seconds with a floor; floor mean {mean([p[0] for _, p in pace]):.1f}, max "
              f"{max(p[1] for _, p in pace)}, level mean {mean([p[2] for _, p in pace]):.1f} "
              f"({mean([p[3] for _, p in pace]):.0f} MHz), held frames/s {mean([p[4] for _, p in pace]):.1f}")
    if behind:
        print(f"gpu-behind (0389): {behind} frames copied by the GPU behind newer work instead of the CPU")
    for name, sel in (("autorefresh 1/1 (active)", lambda g: g[4] == "0x80000001"),
                      ("VRR idle", lambda g: g[4] != "0x80000001")):
        g = [x for x in te if sel(x)]
        if g:
            samples = sum(int(x[2]) for x in g)
            print(f"TE lock, {name}: {len(g)} s, te/s mean {mean([int(x[0]) for x in g]):.0f}, samples {samples}, "
                  f"locked {sum(int(x[1]) for x in g)} ({100.0 * sum(int(x[1]) for x in g) / max(samples, 1):.0f} %), "
                  f"no sample {sum(int(x[3]) for x in g)}")
    # the 20 best and the worst-looking active seconds for the report
    best = sorted(act, key=lambda x: -x[1][1])[:5]
    print("best 5 seconds (time, swaps, presents, timeouts, skips, copy max):")
    for t, v in best:
        print(f"  {t // 3600 % 24:02d}:{t // 60 % 60:02d}:{t % 60:02d} {v[0]} {v[1]} {v[11]} {v[12]} {v[6]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
