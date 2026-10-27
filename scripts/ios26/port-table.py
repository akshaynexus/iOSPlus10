#!/usr/bin/env python3
"""Markdown per-patch table of the negroni series on xnu-12377 for docs/ios26-port-status.md.

    scripts/ios26/port-table.py SERIES_REPORT > table.md

SERIES_REPORT is the output of scripts/ios26/apply-series.py: out/kernel/local-ios26-<UTC>/series-report.txt
(build-kernel.sh) or the output of scripts/ios26/series-tree.sh. Columns: patch, result on 12377 (applied /
applied+rules / replaced / skipped / base / ran / ERROR), and the rule kinds or the skip reason.
"""
import re
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rows, summary = [], ""
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("== series:"):
            summary = line[3:]
        m = re.match(r"^(\d{4}-\S+\.(?:patch|sh))\s+(.*)$", line)
        if not m:
            continue
        name, what = m.groups()
        if what.startswith("applied+rules"):
            n, _, kinds = what.partition(": ")
            rows.append((name, n, kinds))
        elif what.startswith("skipped: "):
            rows.append((name, "skipped", what[len("skipped: "):]))
        else:
            rows.append((name, what, ""))
    print(f"Result: {summary}\n")
    print("| Patch | 12377 result | Rules / reason |")
    print("|---|---|---|")
    for name, res, why in rows:
        print(f"| `{name}` | {res} | {why.replace('|', '/')} |")


if __name__ == "__main__":
    main()
