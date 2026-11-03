#!/usr/bin/env python3
"""Mi A3 iOS 26: symbols for `laurel-autotest kstack PID`: scripts/laurel/ios26-kstack-sym.py [FILE] [KERNEL_UNSTRIPPED]. Docs: docs/laurel_sprout/ios26-default-speed.md.
A return address is taken as unslid when it falls in the kernel's symbols; else the "L slide" line of the tool is taken off."""
import bisect
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
lines = open(sys.argv[1], errors="replace").read().splitlines() if len(sys.argv) > 1 and sys.argv[1] != "-" else sys.stdin.read().splitlines()
kernel = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, "out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k.unstripped")
if not os.path.exists(kernel):
    main = subprocess.run(["git", "-C", REPO, "worktree", "list", "--porcelain"], capture_output=True, text=True).stdout.splitlines()[0].split(" ", 1)[1]
    kernel = os.path.join(main, "out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k.unstripped")
syms = []
for row in subprocess.run(["llvm-nm", "--defined-only", "-n", kernel], capture_output=True, text=True).stdout.splitlines():
    f = row.split()
    if len(f) == 3 and f[1] in "tT":
        syms.append((int(f[0], 16), f[2]))
keys = [a for a, _ in syms]
slide = next((int(x.split()[1], 16) for x in lines if x.startswith("L ")), 0)


def name(pc):
    for at in (pc, pc - slide, pc | 0xffff000000000000, (pc | 0xffff000000000000) - slide):
        i = bisect.bisect_right(keys, at) - 1
        if i >= 0 and at - keys[i] < 0x100000:
            return f"{syms[i][1]}+{at - keys[i]:#x}"
    return hex(pc)


for line in lines:
    if line.startswith("K "):
        f = line.split()
        print(f"thread {f[1]}: sys {f[2]} ms, user {f[3]} ms")
        for pc in f[4:]:
            print("   ", name(int(pc, 16)))
