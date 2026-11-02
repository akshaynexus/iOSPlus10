#!/usr/bin/env python3
"""half-deriv.py IR3_LOG: from ca-pipelines' log with IR3_SHADER_DEBUG=disasm: per pipeline, the derivative instructions (dsx, dsy, dsxpp, dsypp) with a half register (hr), and the ones with a full register.
Last line: "half-deriv: H half, F full, in P pipelines". Run with python3 -I."""
import re
import sys

cur = "-"
per = {}
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("=== PIPELINE "):
        cur = line[13:].strip()
        continue
    if re.search(r"\bdsx|\bdsy", line) and "(" in line or re.search(r"\b(dsx|dsy)(pp)?", line):
        if not re.search(r"\b(dsx|dsy)(pp)?(\.\d)?\b", line):
            continue
        half = bool(re.search(r"\bhr\d", line))
        p = per.setdefault(cur, [0, 0, ""])
        p[0 if half else 1] += 1
        if half and not p[2]:
            p[2] = line.strip()[:90]
H = sum(p[0] for p in per.values())
F = sum(p[1] for p in per.values())
for k, p in sorted(per.items(), key=lambda kv: -kv[1][0]):
    if p[0]:
        print(f"{p[0]}\t{p[1]}\t{k[:60]}\t{p[2]}")
print(f"half-deriv: {H} half, {F} full, in {len(per)} pipelines")
