#!/usr/bin/env python3
"""real-plan.py {ca|rb} PIPELINES_LOG... > PLAN: the render pipelines a phone really asked for (NMTL_DIR/cache/<process>/pipelines.log), as a plan of userland/laurel/metal/tests/ca-pipelines.c.
ca: CoreAnimation's named shaders of QuartzCore's default.metallib (glass, blur, ...), and each fixed_frag specialization with its real fc_* key. rb: RenderBox's stages with their real state constant (#0),
each custom effect as a linked custom_fn of IconRendering's library. One row per distinct key. Run with python3 -I. Only for the host: scripts/ios26/test-real-pipelines.sh."""
import re
import sys


def num(v):
    return "%de0" % v   # (e0: ca-pipelines reads values with strtod, "0.0" would be one number)


def values(typ, hexa):
    b = bytes.fromhex(hexa)
    t = int(typ)
    size = 4 if 29 <= t <= 36 or 3 <= t <= 6 else 2 if 16 <= t <= 19 or 37 <= t <= 44 else 1
    return ".".join(num(int.from_bytes(b[i:i + size], "little")) for i in range(0, len(b), size))


def constants(text):
    out = []
    for m in re.finditer(r"(#\d+|fc_\w+):(\d+):([0-9a-f]+)", text):
        n, t, h = m.groups()
        out.append(("i" + n[1:] if n[0] == "#" else "n" + n) + ":" + t + ":" + values(t, h))
    return ",".join(out) or "-"


def layout(line):
    a = re.findall(r" a(\d+)=(\d+):(\d+):(\d+):(\d+):", line)
    if not a:
        return "-"
    return "b%ss%s;" % (a[0][3], a[0][4]) + ",".join("%s:%s:%s" % x[:3] for x in a)


def main():
    kind, logs = sys.argv[1], sys.argv[2:]
    seen = set()
    fixed = {}
    for path in logs:
        for line in open(path, errors="replace"):
            m = re.match(r"S .*ok=1 name=(fixed_frag\w+|\w*vert\w*) k=(.*?) \| ", line)
            if m and m[1].startswith("fixed_frag"):
                fixed[constants(m[2])] = m[1]
    for path in logs:
        for line in open(path, errors="replace"):
            if not line.startswith("R ") or " | f " not in line:
                continue
            label = re.search(r" label=(\S*)", line)[1]
            colors = ",".join(c for c in re.findall(r" c\d+=(\d+):", line))
            vs = re.search(r"\| v (\S+)([^|]*)", line)
            fs = re.search(r"\| f (\S+)([^|]*)", line)
            if not vs or not fs:
                continue
            k = constants(fs[2])
            if kind == "ca":
                if not label.startswith("com.apple.coreanimation"):
                    continue
                fragment = fixed.get(k, "") if fs[1][0] == "T" or " fc_" in fs[2] else fs[1]
                vertex = vs[1]
                if vertex == "VfxXgh":      # CA's generic vertex stage: no vertex descriptor, its constants join the row
                    vertex = "fixed_vert_lph_gen"
                    k = ",".join(x for x in (constants(vs[2]), k) if x and x != "-")
                elif not fragment or re.match(r"V[a-z]", vertex):   # CA's name of a specialized vertex: the fragment's own compile says what matters
                    vertex = "std_vert_lph" if not re.match(r"V[a-z]", vertex) else "fixed_vert_lph_spc"
                row = ("R", (fragment or "?") + ":" + fs[1], vertex, fragment, colors, layout(line), k)
                if not fragment:
                    continue
            else:
                if label.startswith("com.apple.coreanimation") or "#0:" not in fs[2]:
                    continue
                if label.startswith(("primitive_custom:", "custom_effect:")):
                    stage, effect = label.split(":", 1)
                    row = ("L", label, stage + "_vertex", stage + "_fragment", colors, "-", effect, "custom_fn", sys.argv[0] and "@IC@", k)
                else:
                    if not vs[1].endswith("vertex") or not fs[1].endswith("fragment"):
                        continue
                    row = ("R", label + ":" + fs[2].strip()[-16:], vs[1], fs[1], colors, "-", k)
            key = row[1:]
            if key not in seen:
                seen.add(key)
                print("\t".join(row))


main()
