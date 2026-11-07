#!/usr/bin/env python3
"""Mi A3 iOS 26: reads the `LAUREL EMU: sites:` lines of laurel 3070 (LAUREL EMU SITES) from a USB log and names the images.
  scripts/laurel/ios26-emu-sites.py LOG... [--top N] [--images FILE]
Each minute: one `LAUREL EMU: site N:` line per hot site (class, count, process, user pc, the pc with the dyld cache slide off, the word) and a
`LAUREL EMU: sites:` line with the words that found no slot, per class. The first form (all sites in one line) is read too.
This sums them per site over all lines, sorts, and maps the unslid pc to a cache image through out/ios26/dsc-images.txt
("VADDR PATH" per image, from scripts/laurel/dsc-image.py images). A pc with no slide (a root binary, not the cache) shows the process only.
Docs: docs/laurel_sprout/cpu-efficiency.md. Run with python3 -I."""
import bisect
import collections
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LINE = re.compile(r"LAUREL EMU: sites?(?: \d+)?: (.*)")   # `site N: ...` (one site a line) or the first form `sites: a; b; ...`
TAIL = re.compile(r"; other (\d+); (\d+) of (\d+) slots")
SITE = re.compile(r"(\w+) (\d+) (\S+) pc 0x([0-9a-f]+) unslid 0x([0-9a-f]+) word 0x([0-9a-f]+)")


def images(path):
    addrs, names = [], []
    try:
        with open(path) as f:
            for ln in f:
                p = ln.split()
                if len(p) >= 2 and p[0].startswith("0x"):
                    addrs.append(int(p[0], 16))
                    names.append(p[1])
    except OSError:
        return [], []
    order = sorted(range(len(addrs)), key=lambda i: addrs[i])
    return [addrs[i] for i in order], [names[i] for i in order]


CACHE_BASE = 0x180000000    # a user pc below this is a root binary, not the cache: its "unslid" value means nothing


def image_of(addrs, names, va):
    if not addrs or va == 0 or va < addrs[0]:
        return "-"
    i = bisect.bisect_right(addrs, va) - 1
    return "%s+0x%x" % (os.path.basename(names[i]), va - addrs[i])


def main():
    args = sys.argv[1:]
    top, imgfile, logs = 12, os.path.join(REPO, "out/ios26/dsc-images.txt"), []
    while args:
        a = args.pop(0)
        if a == "--top":
            top = int(args.pop(0))
        elif a == "--images":
            imgfile = args.pop(0)
        else:
            logs.append(a)
    if not logs:
        print(__doc__)
        return 2
    addrs, names = images(imgfile)
    total = collections.Counter()
    info = {}
    minutes, other = 0, 0
    noslot = collections.Counter()
    for path in logs:
        with open(path, errors="replace") as f:
            for ln in f:
                m = LINE.search(ln)
                if not m:
                    continue
                t = TAIL.search(m.group(1))
                if t:
                    other += int(t.group(1))
                if "no slot this minute:" in m.group(1):
                    minutes += 1
                    for cls, n in re.findall(r" (\w+)=(\d+)", m.group(1)):
                        noslot[cls] += int(n)
                elif " site " not in ln.split("LAUREL EMU:")[1][:8]:
                    minutes += 1
                for cls, n, comm, pc, unslid, word in SITE.findall(m.group(1)):
                    key = (comm, int(unslid, 16) if int(pc, 16) >= CACHE_BASE else int(pc, 16), cls)
                    total[key] += int(n)
                    info[key] = (int(pc, 16), int(unslid, 16), word)
    if minutes == 0:
        print("no `LAUREL EMU: sites:` line in", ", ".join(logs))
        return 1
    print("%d minutes, words with no slot: %s; the %d hottest sites over all lines:" % (
        minutes, ", ".join("%s %d" % kv for kv in noslot.most_common()) or str(other), top))
    print("%-9s %-8s %-16s %-14s %-14s %-10s %s" % ("count", "class", "process", "pc", "unslid", "word", "image+offset"))
    for (comm, _, cls), n in total.most_common(top):
        pc, unslid, word = info[(comm, _, cls)]
        print("%-9d %-8s %-16s 0x%-12x 0x%-12x 0x%-8s %s" % (n, cls, comm, pc, unslid, word,
                                                           image_of(addrs, names, unslid) if pc >= CACHE_BASE else "root binary"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
