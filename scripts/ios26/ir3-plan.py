#!/usr/bin/env python3
"""ir3-plan.py CORPUS_LIB_DIR > PLAN: the pipelines scripts/ios26/ir3-check.sh makes, from a host-translate result directory (results.tsv + stand-ins *.fc *.ca *.vd.json)
+ CoreAnimation's own specializations of fixed_frag (names and Metal types read from CA::OGL::MetalContext::create_fragment_shader, 23F84).
Plan format: userland/laurel/metal/tests/ca-pipelines.c. Run with python3 -I."""
import json
import os
import sys

TYPES = {"bool": 53, "uint": 33, "int": 29, "float": 3, "half": 16, "ushort": 41, "short": 37, "uchar": 49, "char": 45}
FORMATS = {"BGRA8Unorm": 80, "RGBA8Unorm": 70, "R8Unorm": 10, "RG8Unorm": 30, "RGBA16Float": 115, "R16Float": 25, "RG16Float": 65, "R32Float": 55,
           "RG32Float": 105, "RGBA32Float": 125, "R8Uint": 13, "R16Uint": 23, "R32Uint": 53, "RGBA8Uint": 73, "RGBA16Uint": 113, "RGBA32Uint": 123, "R32Sint": 54}
# CA::OGL::MetalContext::vertex_layout_info (QuartzCore 0x184246d10, 23F84) [V]: buffer 1; layout 0 = stride 48: float4@0, float2@16, float2@24, half4@32
CA_LAYOUT0 = "b1s48;0:31:0,1:29:16,2:29:24,3:27:32"
VFORMATS = {"Float4": 31, "UInt4": 39, "Int4": 35, "Half4": 27, "UChar4Normalized": 9}


def mtype(t):
    n = int(t[-1]) if t[-1].isdigit() else 1
    base = t[:-1] if t[-1].isdigit() else t
    return TYPES[base] + (n - 1)


def constants(d, *names):
    have = {}
    for name in names:
        p = os.path.join(d, name + ".fc")
        if os.path.exists(p):
            for line in open(p):
                line = line.strip()
                if line:
                    i, t, v = line.split(":")
                    have.setdefault(i, f"i{i}:{mtype(t)}:{v.replace(',', '.').replace('false', '0').replace('true', '1')}")
    return ",".join(have.values()) or "-"


def colors(d, frag):
    p = os.path.join(d, frag + ".ca")
    if not os.path.exists(p):
        return "80"
    fm = [FORMATS[x.strip().split(":")[1]] for x in open(p) if x.strip()]
    return ",".join(map(str, fm)) or "80"


def vdesc(d, vert):
    p = os.path.join(d, vert + ".vd.json")
    if not os.path.exists(p):
        return "-"
    v = json.load(open(p))
    return ",".join(f"{a}:{VFORMATS[x['format']]}:{x['offset']}" for a, x in v["attributes"].items()) or "-"


def main():
    d = sys.argv[1]
    verts = {}
    frags = []
    for line in open(os.path.join(d, "results.tsv")):
        f = line.rstrip("\n").split("\t")
        if len(f) < 3 or not f[1] or f[1] == "bash":
            continue
        kind, name, res = f[0], f[1], f[2]
        if kind == "kernel" and res.startswith("PASS"):
            print(f"K\t{name}\t{constants(d, name)}")
        elif kind == "fragment" and res.startswith("PASS ("):
            frags.append((name, res[6:].rstrip(")")))
    for name, vert in frags:
        print(f"R\t{name}\t{vert}\t{name}\t{colors(d, name)}\t{vdesc(d, vert)}\t{constants(d, name, vert)}")
    # CoreAnimation's generic fixed function shader (fc_generic=1), as create_fragment_shader asks for it. Types [V]: bool 53, uchar 49, uchar2 50, uchar4 52. A specialized fixed_frag
    # needs CA's real Spec values: a test grid here gave 1 instruction (no outputs), which proves nothing, so it is not in the plan. Real keys come from the phone's pipelines.log.
    if os.path.exists(os.path.join(d, "fixed_frag_lph_cph.fc")):
        base = {"fc_generic": "53:0", "fc_vertex_layout": "49:0", "fc_framebuffer_fetch": "53:0", "fc_attachment_count": "49:1"}
        for prec in ("lph_cph", "lph_cpf"):
            vert = "fixed_vert_lph_spc"
            ref = {x.split(":")[0]: x for x in constants(d, f"fixed_frag_{prec}", vert).split(",")}
            def row(label, over, v=vert, desc=None):
                vals = dict(base, **over)
                # every other constant keeps the plan's stand-in value (by index); the named ones are CoreAnimation's
                s = ",".join([f"n{k}:{x}" for k, x in vals.items()] + list(ref.values()))
                print(f"R\t{label}\t{v}\tfixed_frag_{prec}\t80\t{desc or CA_LAYOUT0}\t{s}")
            gen = {x.split(":")[0]: x for x in constants(d, f"fixed_frag_{prec}", "fixed_vert_lph_gen").split(",")}
            ref_saved = dict(ref)
            ref.clear()
            ref.update(gen)
            row(f"ca_generic_{prec}", {"fc_generic": "53:1", "fc_vertex_layout": "49:0", "fc_has_attachment_0": "53:1"}, "fixed_vert_lph_gen", "-")
            ref.clear()
            ref.update(ref_saved)
    print()


if __name__ == "__main__":
    main()
