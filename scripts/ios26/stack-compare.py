#!/usr/bin/env python3
"""stack-compare.py IR3_A IR3_B NAME_A NAME_B OUT.tsv: two Metal stacks' FD610 compile results for QuartzCore's pipelines (scripts/ios26/ir3-check.sh with IR3_OUT). Prints the summary; writes one row per pipeline fragment stage."""
import csv, statistics, sys
LIB = "Frameworks_QuartzCore.framework_default.metallib"
a_dir, b_dir, a_name, b_name, out = sys.argv[1:6]

def load(d):
    rows = {}
    for r in csv.DictReader(open(f"{d}/{LIB}/stats.tsv"), delimiter="\t"):
        if r["pipeline"] != "-":
            rows.setdefault((r["pipeline"], r["stage"]), r)
    return rows

def made(d):
    return {r[1]: r[0] for r in csv.reader(open(f"{d}/{LIB}/result.tsv"), delimiter="\t") if len(r) > 1}

A, B = load(a_dir), load(b_dir)
ma, mb = made(a_dir), made(b_dir)
for n, m in ((a_name, ma), (b_name, mb)):
    print(f"{n}: {sum(v == 'ok' for v in m.values())} made, {sum(v != 'ok' for v in m.values())} refused")
for n, m, o in ((a_name, ma, mb), (b_name, mb, ma)):
    only = sorted(k for k, v in m.items() if v != "ok" and o.get(k) == "ok")
    print(f"refused only by {n}: {' '.join(only) or 'none'}")
common = sorted(A.keys() & B.keys())
for stage in ("FRAG", "VERT"):
    keys = [k for k in common if k[1] == stage]
    x = [int(A[k]["instr"]) for k in keys]
    y = [int(B[k]["instr"]) for k in keys]
    print(f"{stage}: {len(keys)} pipelines; instructions median {a_name} {statistics.median(x):g}, {b_name} {statistics.median(y):g}; "
          f"smaller in {a_name} {sum(p < q for p, q in zip(x, y))}, in {b_name} {sum(q < p for p, q in zip(x, y))}, same {sum(p == q for p, q in zip(x, y))}")
with open(out, "w") as f:
    f.write(f"pipeline\t{a_name}_instr\t{b_name}_instr\t{a_name}_full\t{b_name}_full\n")
    for k in common:
        if k[1] == "FRAG":
            f.write(f"{k[0]}\t{A[k]['instr']}\t{B[k]['instr']}\t{A[k]['full']}\t{B[k]['full']}\n")
for name in ("ca_generic_lph_cph", "ca_generic_lph_cpf", "ca_generic_fetch_lph_cph", "glass_background_lph", "glass_background_sdf_lph", "glass_foreground_lph", "asg_frag_lph"):
    k = (name, "FRAG")
    if k in A and k in B:
        print(f"{name}: {a_name} {A[k]['instr']}, {b_name} {B[k]['instr']}")
