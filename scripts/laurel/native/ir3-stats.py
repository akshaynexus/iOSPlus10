#!/usr/bin/env python3
"""ir3-stats.py: the native stack's FD610 code against the default stack's table (docs/laurel_sprout/ios26-evidence/metal-pipelines.tsv), and how many real keys read the framebuffer. Input: out/ios26/native/ir3 of scripts/laurel/native/ir3-native.sh. Run with python3 -I."""
import collections
import csv
import statistics as st

R = "out/ios26/native/ir3"
base = {}
for r in csv.DictReader(open("docs/laurel_sprout/ios26-evidence/metal-pipelines.tsv"), delimiter="\t"):
    try:
        base[r["function"]] = int(r["instr"])
    except ValueError:
        pass


def load(path):
    d = collections.defaultdict(dict)
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        d[f[1]][f[2]] = [int(x) for x in f[3:]]
    return d


n = load(R + "/ca-154/stats.tsv")
rows = [(k, v["fragment"][0], base.get(k)) for k, v in n.items() if "fragment" in v]
have = [r for r in rows if r[2]]
print(f"fragment functions {len(rows)}, with a default-stack number {len(have)}")
print(f"median instructions: native {st.median(r[1] for r in have)}, default {st.median(r[2] for r in have)}")
print(f"native smaller {sum(r[1] < r[2] for r in have)}, same {sum(r[1] == r[2] for r in have)}, larger {sum(r[1] > r[2] for r in have)}")
for g in ("glass_background_lph", "glass_background_sdf_lph", "glass_foreground_sdf_lph", "glass_foreground_lph", "narrow_blur_27_frag_lph", "variable_blur_frag_lph", "simple_rim_lph", "asg_frag_lph", "ca_generic_lph_cph"):
    x = [r for r in rows if r[0] == g]
    print(f"{g}: native {x[0][1] if x else '-'}, default {x[0][2] if x and x[0][2] else '-'}")
real = load(R + "/ca-real/stats.tsv")
fr = [(k, v["fragment"]) for k, v in real.items() if "fragment" in v]
ca = [v for k, v in fr if k.startswith("fixed_frag")]
print(f"real keys: {len(fr)} distinct rows; read the framebuffer: {sum(v[13] for _, v in fr)}")
print(f"fixed_frag: {len(ca)} rows; read the framebuffer: {sum(v[13] for v in ca)}; instructions median {st.median(v[0] for v in ca)}, max {max(v[0] for v in ca)}")
for k, v in fr:
    if not k.startswith("fixed_frag"):
        print(f"  {k.split(':')[0]}: {v[0]} instructions, reads framebuffer {v[13]}")
