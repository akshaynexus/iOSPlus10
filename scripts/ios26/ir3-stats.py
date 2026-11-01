#!/usr/bin/env python3
"""ir3-stats.py IR3_LOG > TSV: per pipeline of ca-pipelines, the statistics ir3 printed (IR3_SHADER_DEBUG=disasm) for FD610: one row per shader variant.
Columns: pipeline stage instr nops mov cov dwords half full constlen tex(cat5) mem(cat6) sstall systall loops. `full`/`half` = highest register, in vec4 units (the A610 has reg_size_vec4 48)."""
import re
import sys

cur = "-"
row = {}
print("pipeline\tstage\tinstr\tnops\tmov\tcov\tdwords\thalf\tfull\tconstlen\tcat5\tcat6\tsstall\tsystall\tloops")
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("=== PIPELINE "):
        cur = line[13:].strip()
        continue
    m = re.search(r"; (\w+) prog \d+/\d+: (.*)", line)
    if not m:
        continue
    st, rest = m.groups()
    nums = {k: v for v, k in re.findall(r"(\d+) ([\w()-]+)", rest)}
    if "instr" in nums:
        row = {"stage": st, **nums}
    elif "constlen" in nums:
        row.update(nums)
    elif "cat0" in nums:
        row.update(nums)
    elif "sstall" in nums:
        row.update(nums)
        print("\t".join([cur, row.get("stage", "?")] + [row.get(k, "0") for k in
                        ("instr", "nops", "mov", "cov", "dwords", "half", "full", "constlen", "cat5", "cat6", "sstall", "systall", "loops")]))
