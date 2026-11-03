#!/usr/bin/env python3
"""Mi A3 iOS 26: `laurel-autotest sample` output by time bin: how busy one thread is in each bin, and what it waits in.
  scripts/laurel/ios26-sample-bins.py SAMPLES [--thread N] [--bin MS] [--dis DIR] [--busy PCT] [--callers] [--from MS --to MS] [--abs] [--stacks N]
`--abs`: bins and --from/--to on the T clock of the file (two files of one run compare), else from the first sample. `--stacks N`: the N most common whole stacks.
`--callers`: for the samples in a wait trap, the first frame above the system libraries: who waits, and for what.
Each bin: samples, share not in a wait trap, the top non-wait leaf symbol, the top wait trap. `--busy PCT` prints only bins at or over PCT.
Symbols: the `.syms` files of `ios26-sample-sym.py` (`--dis` names its out/ios26/dis; default this repo's). Only the dyld cache images need them;
a pc with no symbol is counted by its image. Docs: docs/laurel_sprout/ios26-default-speed.md."""
import bisect
import collections
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WAITS = ("_mach_msg2_trap", "___psynch_cvwait", "___psynch_mutexwait", "__semwait_signal", "_kevent", "___ulock_wait", "___workq_kernreturn",
         "_semaphore_wait_trap", "_semaphore_timedwait_trap", "_mach_msg_trap", "___select", "___read", "_read", "___sleep", "_nanosleep", "___wait4",
         "_thread_switch", "_mach_wait_until", "_mach_timebase_info_trap", "_poll", "___psynch_rw_rdlock", "___psynch_rw_wrlock")


def syms_of(dis, leaf):
    f = os.path.join(dis, re.sub(r"\W", "_", leaf) + ".syms")
    table = []
    if os.path.exists(f):
        for line in open(f, errors="replace"):
            p = line.split(None, 2)
            if len(p) == 3 and p[0].startswith("0x"):
                table.append((int(p[0], 16), p[2].strip()))
    table.sort()
    return table


def nm_syms(path):
    out = subprocess.run(["llvm-nm", "-n", "--defined-only", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
    table = []
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3 and p[1] in "tT":
            table.append((int(p[0], 16), p[2]))
    return table


def own_syms(dis, leaf):
    """NegroniMetal and Turnip are not in the dyld cache: their symbols come from the build of the repo that owns `dis`."""
    repo = os.path.dirname(os.path.dirname(os.path.dirname(dis)))
    if leaf == "NegroniMetal":
        d = [os.environ["NEGRONI_SYMBOLS"]] if os.environ.get("NEGRONI_SYMBOLS") else glob.glob(os.path.join(repo, "out/ios26/metal-impl/NegroniMetal.dSYM/Contents/Resources/DWARF/*"))
        return nm_syms(d[0]) if d else []
    if "libvulkan_freedreno" in leaf:
        f = os.path.join(repo, "out/ios26/gpu/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib")
        return nm_syms(f) if os.path.exists(f) else []
    return []


def images_of(dis):
    out = {}
    f = os.path.join(dis, "images.txt")
    if os.path.exists(f):
        for line in open(f, errors="replace"):
            p = line.split(None, 1)
            if len(p) == 2 and p[0].startswith("0x"):
                out[p[1].strip()] = int(p[0], 16)
    return out


def main():
    args = sys.argv[1:]
    want, bin_ms, dis, busy_min, callers, t_from, t_to = None, 250, os.path.join(REPO, "out/ios26/dis"), -1.0, False, 0, 1 << 60
    use_abs, stacks = False, 0
    if "--abs" in args:
        args.remove("--abs"); use_abs = True
    if "--stacks" in args:
        i = args.index("--stacks"); stacks = int(args[i + 1]); del args[i:i + 2]
    if "--callers" in args:
        args.remove("--callers"); callers = True
    if "--from" in args:
        i = args.index("--from"); t_from = int(args[i + 1]); del args[i:i + 2]
    if "--to" in args:
        i = args.index("--to"); t_to = int(args[i + 1]); del args[i:i + 2]
    if "--thread" in args:
        i = args.index("--thread"); want = args[i + 1]; del args[i:i + 2]
    if "--bin" in args:
        i = args.index("--bin"); bin_ms = int(args[i + 1]); del args[i:i + 2]
    if "--dis" in args:
        i = args.index("--dis"); dis = args[i + 1]; del args[i:i + 2]
    if "--busy" in args:
        i = args.index("--busy"); busy_min = float(args[i + 1]); del args[i:i + 2]
    images, samples, t = [], [], 0
    for line in open(args[0], errors="replace"):
        p = line.split(None, 2)
        if p and p[0] == "I" and len(p) == 3:
            images.append((int(p[1], 16), p[2].strip()))
        elif p and p[0] == "T":
            t = int(p[1])
        elif p and p[0] == "S":
            f = line.split()
            samples.append((t, f[1], [int(x, 16) for x in f[2:]]))
    images.sort()
    bases = [b for b, _ in images]
    known = images_of(dis)
    tables = {}
    memo = {}

    def sym(pc):
        if pc in memo:
            return memo[pc]
        i = bisect.bisect_right(bases, pc) - 1
        name = hex(pc)
        if i >= 0:
            base, path = images[i]
            leaf = os.path.basename(path)
            name = leaf
            if path in known or leaf == "NegroniMetal" or "libvulkan_freedreno" in leaf:
                if leaf not in tables:
                    tables[leaf] = syms_of(dis, path.lstrip("/")) if path in known else own_syms(dis, leaf)
                tab = tables[leaf]
                if tab:
                    at = pc - base + known.get(path, 0)
                    j = bisect.bisect_right([a for a, _ in tab], at) - 1
                    if j >= 0:
                        name = tab[j][1] + " [" + leaf + "]"
        memo[pc] = name
        return name

    threads = collections.Counter(th for _, th, _ in samples)
    if want is None:
        want = threads.most_common(1)[0][0]
    use = [(tt, pcs[0] if pcs else 0, pcs) for tt, th, pcs in samples if th == want]
    if not use:
        print("no samples of thread", want, "threads:", threads.most_common(8))
        return
    t0 = 0 if use_abs else use[0][0]
    use = [u for u in use if t_from <= u[0] - t0 < t_to]
    if stacks:
        c = collections.Counter(" < ".join(sym(x).split(" [")[0][:48] for x in pcs[:14]) for _, _, pcs in use)
        print(f"thread {want}: {len(use)} samples, the {stacks} most common stacks (leaf first)")
        for k, v in c.most_common(stacks):
            print(f"{100.0 * v / len(use):5.1f}  {k}")
        return
    if callers:
        SYSTEM = ("libsystem_kernel.dylib", "libsystem_pthread.dylib", "libdispatch.dylib", "CoreFoundation", "libsystem_platform.dylib", "libobjc.A.dylib", "Foundation", "IOKit", "IOSurface")
        who = collections.Counter()
        n = 0
        for _, pc, pcs in use:
            leaf = sym(pc)
            if not any(leaf.startswith(w) for w in WAITS):
                continue
            n += 1
            above = next((sym(x) for x in pcs[1:] if sym(x).split("[")[-1].rstrip("]") not in SYSTEM), "(system only)")
            who[leaf.split(" [")[0] + " <- " + above[:100]] += 1
        print(f"thread {want}: {n} samples in a wait trap of {len(use)}")
        for k, v in who.most_common(25):
            print(f"{100.0 * v / max(n, 1):5.1f}  {k}")
        return
    bins = collections.defaultdict(list)
    for tt, pc, _ in use:
        bins[(tt - t0) // bin_ms].append(pc)
    print(f"thread {want}: {len(use)} samples over {use[-1][0] - t0} ms, bins of {bin_ms} ms; busy = leaf not a wait trap")
    print(f"{'ms':>7} {'n':>4} {'busy%':>6}  top busy leaf | top wait")
    tot_busy = tot = 0
    for b in sorted(bins):
        pcs = bins[b]
        names = [sym(pc) for pc in pcs]
        busy = [n for n in names if not any(n.startswith(w) for w in WAITS)]
        waits = [n for n in names if any(n.startswith(w) for w in WAITS)]
        share = 100.0 * len(busy) / len(pcs)
        tot_busy += len(busy)
        tot += len(pcs)
        if share < busy_min:
            continue
        tb = collections.Counter(busy).most_common(1)
        tw = collections.Counter(waits).most_common(1)
        print(f"{b * bin_ms:7d} {len(pcs):4d} {share:6.1f}  {tb[0][0][:60] if tb else '-'} ({tb[0][1] if tb else 0}) | {tw[0][0][:40] if tw else '-'} ({tw[0][1] if tw else 0})")
    print(f"all: {100.0 * tot_busy / tot:.1f} % busy of {tot} samples")


main()
