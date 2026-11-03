#!/usr/bin/env python3
"""Mi A3 iOS 26: reads `laurel-autotest sample` output: where the running threads of a process spend their time. Docs: docs/laurel_sprout/ios26-default-speed.md.
  scripts/laurel/ios26-sample-sym.py SAMPLES [--thread N] [--top N] [--under TEXT]   --under: only the callees of the first frame whose symbol holds TEXT, one level
Symbols: NegroniMetal (dSYM of out/ios26/metal-impl), Turnip (out/ios26/gpu/turnip/build-ios), the dyld cache (scripts/laurel/dsc-image.py, kept in out/ios26/dis). Self = the pc; inclusive = anywhere on the walked stack."""
import bisect
import collections
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DSC = os.path.expanduser("~/op10-apple/ios26/23F84-n104ap/tree/cache")
DIS = os.path.join(REPO, "out/ios26/dis")
TEXT_BASE_DYLIB = 0


def nm(path):
    out = subprocess.run(["llvm-nm", "-n", "--defined-only", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
    table = []
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3 and p[1] in "tT":
            table.append((int(p[0], 16), p[2]))
    return table


def cache_syms(leaf):
    os.makedirs(DIS, exist_ok=True)
    f = os.path.join(DIS, re.sub(r"\W", "_", leaf) + ".syms")
    if not os.path.exists(f):
        with open(f, "w") as o:
            subprocess.run([sys.executable, "-I", os.path.join(REPO, "scripts/laurel/dsc-image.py"), DSC, "syms", leaf], stdout=o, stderr=subprocess.DEVNULL)
    table = []
    for line in open(f, errors="replace"):
        p = line.split(None, 2)
        if len(p) == 3 and p[0].startswith("0x"):
            table.append((int(p[0], 16), p[2].strip()))
    table.sort()
    return table


class Image:
    def __init__(self, base, path):
        self.base, self.path, self.leaf = base, path, os.path.basename(path)
        self.table = None
        self.unslid = None

    def load(self, images):
        if self.table is not None:
            return
        self.table = []
        if self.leaf == "NegroniMetal":
            # NEGRONI_SYMBOLS: the native stack's out/ios26/metal-native/NegroniMetal.unstripped
            d = [os.environ["NEGRONI_SYMBOLS"]] if os.environ.get("NEGRONI_SYMBOLS") else glob.glob(os.path.join(REPO, "out/ios26/metal-impl/NegroniMetal.dSYM/Contents/Resources/DWARF/*"))
            self.table = nm(d[0]) if d else []
            self.unslid = 0
        elif "libvulkan_freedreno" in self.leaf:
            self.table = nm(os.path.join(REPO, "out/ios26/gpu/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib"))
            self.unslid = 0
        elif self.leaf in KEEP:
            self.unslid = images.get(self.path)
            if self.unslid is not None:
                self.table = cache_syms(self.path.lstrip("/"))
        self.keys = [a for a, _ in self.table]

    def name(self, pc, images):
        self.load(images)
        if not self.table:
            return self.leaf
        at = pc - self.base + (self.unslid or 0)
        i = bisect.bisect_right(self.keys, at) - 1
        return (self.table[i][1] if i >= 0 else "?") + " [" + self.leaf + "]"


KEEP = {"QuartzCore", "libsystem_kernel.dylib", "libsystem_platform.dylib", "libsystem_malloc.dylib", "libsystem_pthread.dylib", "Metal", "IOKit", "IOSurface", "libobjc.A.dylib", "libdispatch.dylib", "CoreFoundation"}


def cache_images():
    f = os.path.join(DIS, "images.txt")
    if not os.path.exists(f):
        os.makedirs(DIS, exist_ok=True)
        with open(f, "w") as o:
            subprocess.run([sys.executable, "-I", os.path.join(REPO, "scripts/laurel/dsc-image.py"), DSC, "images"], stdout=o, stderr=subprocess.DEVNULL)
    out = {}
    for line in open(f, errors="replace"):
        p = line.split(None, 1)
        if len(p) == 2 and p[0].startswith("0x"):
            out[p[1].strip()] = int(p[0], 16)
    return out


def main():
    args = sys.argv[1:]
    want = None
    top = 45
    under = None
    if "--under" in args:
        i = args.index("--under"); under = args[i + 1]; del args[i:i + 2]
    if "--thread" in args:
        i = args.index("--thread"); want = args[i + 1]; del args[i:i + 2]
    if "--top" in args:
        i = args.index("--top"); top = int(args[i + 1]); del args[i:i + 2]
    images = []
    samples = []
    for line in open(args[0], errors="replace"):
        p = line.split(None, 2)
        if p and p[0] == "I" and len(p) == 3:
            images.append(Image(int(p[1], 16), p[2].strip()))
        elif p and p[0] == "S":
            f = line.split()
            samples.append((f[1], [int(x, 16) for x in f[2:]]))
    images.sort(key=lambda m: m.base)
    bases = [m.base for m in images]
    known = cache_images()
    memo = {}

    def sym(pc):
        if pc not in memo:
            i = bisect.bisect_right(bases, pc) - 1
            memo[pc] = images[i].name(pc, known) if i >= 0 else hex(pc)
        return memo[pc]

    by_thread = collections.Counter(t for t, _ in samples)
    print("samples per thread:", by_thread.most_common(8))
    if want is None:
        want = by_thread.most_common(1)[0][0]
    use = [s for t, s in samples if t == want]
    print(f"thread {want}: {len(use)} samples")
    if under:
        kids = collections.Counter()
        hits = 0
        for s in use:
            names = [sym(pc) for pc in s]
            at = next((i for i in range(len(names) - 1, -1, -1) if under in names[i]), None)
            if at is None:
                continue
            hits += 1
            kids[names[at - 1] if at > 0 else "(self)"] += 1
        print(f"under {under}: {hits} samples, {100 * hits / len(use):.1f} % of the thread")
        for k, v in kids.most_common(top):
            print(f"{100 * v / hits:5.1f}  {k[:120]}")
        return
    selfs = collections.Counter(sym(s[0]) for s in use)
    incl = collections.Counter()
    img = collections.Counter(sym(s[0]).split("[")[-1].rstrip("]") for s in use)
    for s in use:
        for n in {sym(pc) for pc in s}:
            incl[n] += 1
    print("-- image (self):", [(k, round(100 * v / len(use), 1)) for k, v in img.most_common(10)])
    print("-- self:")
    for k, v in selfs.most_common(top):
        print(f"{100 * v / len(use):5.1f}  {k[:110]}")
    print("-- inclusive:")
    for k, v in incl.most_common(top):
        print(f"{100 * v / len(use):5.1f}  {k[:110]}")


main()
