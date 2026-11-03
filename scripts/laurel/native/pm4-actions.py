#!/usr/bin/env python3
"""pm4-actions.py REF_DIR NATIVE_SUMMARY: pm4-diff.py compares the state at a draw. This compares the other actions of the same scene, one by one, with Turnip's captures in REF_DIR (ref-capture.sh, TU_DEBUG=sysmem): the clear, the buffer copy, the texture copy, the mips, the readback, the dispatch. Each row names the register, both values and why a difference is expected.
Exit 1 on an unexplained difference. Run with python3 -I."""
import re
import sys

ADDRESS = re.compile(r"(_DST$|_SRC$|_BASE|ADDR|OBJ_START|FETCH|BINDLESS|BORDER_COLOR)")
# by design or by the program, with the reason
BLIT_ALLOWED = {
    "RB_2D_DST_INFO": "Turnip's texture is UBWC (bit 12); no UBWC here yet",
    "SP_PS_2D_SRC_INFO": "Turnip's texture is UBWC (bit 12); no UBWC here yet",
    "RB_2D_DST_PITCH": "only with the same width: this layout has no UBWC alignment",
}
CS_PROGRAM = {
    "HLSQ_CS_CNTL": "the program's constlen", "HLSQ_CS_NDRANGE_0": "the scene's thread count: Turnip's profile asks 8, ours 32", "HLSQ_CS_NDRANGE_1": "the same", "HLSQ_CS_NDRANGE_3": "the same",
    "HLSQ_INVALIDATE_CMD": "the last write: Turnip's sets come in a state IB; both end with the CS bindless invalidate after the program", "SP_CS_CONFIG": "the program's binding use", "SP_CS_CTRL_REG0": "the program's register use", "SP_CS_CTRL_REG1": "the program's shared size", "SP_CS_INSTRLEN": "the program's length", "SP_CS_PVT_MEM_SIZE": "the program's layout",
    "HLSQ_SHARED_CONSTS": "push constants per stage, not shared", "SP_MODE_CONTROL": "push constants per stage, not shared",
}
# (name, index in the native list with the fill left out, Turnip's capture, index among its CP_BLITs). The fill is another form on purpose: FMT6_8_UNORM; Turnip fills 32-bit words.
BLITS = [("clear", 0, 1, 5), ("buffer copy", 1, 2, 8), ("texture copy", 2, 2, 9), ("mip 1", 3, 2, 10), ("mip 2", 4, 2, 11), ("mip 3", 5, 2, 12), ("mip 4", 6, 2, 13), ("mip 5", 7, 2, 14), ("mip 6", 8, 2, 15), ("readback", 9, 2, 16)]
TWOD = ("RB_2D_UNKNOWN_8C01", "RB_2D_BLIT_CNTL", "GRAS_2D_BLIT_CNTL", "SP_2D_DST_FORMAT", "SP_PS_2D_SRC_INFO", "SP_PS_2D_SRC_SIZE", "SP_PS_2D_SRC_PITCH", "RB_2D_DST_INFO", "RB_2D_DST_PITCH", "GRAS_2D_DST_TL", "GRAS_2D_DST_BR", "GRAS_2D_SRC_TL_X", "GRAS_2D_SRC_BR_X", "GRAS_2D_SRC_TL_Y", "GRAS_2D_SRC_BR_Y", "RB_2D_SRC_SOLID_C0", "RB_2D_SRC_SOLID_C1", "RB_2D_SRC_SOLID_C2", "RB_2D_SRC_SOLID_C3")


def actions(path):
    lines = open(path, errors="replace").read().split("\n")
    out = []
    state = {}
    for i, l in enumerate(lines):
        if re.match(r"\s*draw\[\d+\] register values", l):
            before = [x for x in lines[max(0, i - 400):i] if "opcode:" in x]
            kind = before[-1].split("opcode:")[1].split()[0] if before else "?"
            for k in lines[i + 1:]:
                m = re.match(r"^[! ][+ ]\s+([0-9a-f]+)\s+([A-Za-z0-9_\[\]x.]+):\s*(.*)$", k)
                if m:
                    state[m[2]] = (m[1], m[3])
                elif re.match(r"\s*(opcode:|cmdstream|draw\[)", k):
                    break
            out.append((kind, dict(state)))
    return out


ref_dir, native = sys.argv[1:3]
ref = {f: [a for a in actions(f"{ref_dir}/plain-sysmem-{f}-summary.txt")] for f in (1, 2, 3)}
nat = actions(native)
nat_blits = [a[1] for a in nat if a[0] == "CP_BLIT"]
# the first native blit is the clear; the fill follows the draw and has no twin
order = [nat_blits[0]] + nat_blits[2:]
ref_blits = {f: [a[1] for a in ref[f] if a[0] == "CP_BLIT"] for f in (1, 2)}
bad = same = allowed = 0
for name, n, f, r in BLITS:
    a, b = ref_blits[f][r], order[n]
    for k in TWOD:
        if k not in a and k not in b:
            continue
        # a solid fill reads no source, a copy reads no solid colour: what is left there is stale state of the capture
        if name == "clear" and k.startswith("SP_PS_2D") or name == "clear" and k.startswith("GRAS_2D_SRC_T"):
            continue
        if name != "clear" and "SOLID" in k:
            continue
        x, y = a.get(k, ("0", ""))[0], b.get(k, ("0", ""))[0]
        if int(x, 16) == int(y, 16):
            same += 1
        elif k in BLIT_ALLOWED and (k != "RB_2D_DST_PITCH"):
            allowed += 1
        else:
            bad += 1
            print(f"DIFF {name:13s} {k}: ref {x} native {y}")
cs_r = [a[1] for a in ref[3] if a[0] == "CP_EXEC_CS"][-1]
cs_n = [a[1] for a in nat if a[0] == "CP_EXEC_CS"][-1]
# what a dispatch reads; the capture's other registers are leftovers of earlier work in this process
CS_READS = re.compile(r"^(SP_CS_|HLSQ_CS_|HLSQ_INVALIDATE|HLSQ_SHARED|SP_MODE|RB_CCU|SP_PERFCTR|SP_TP_MODE|SP_IBO|SP_FLOAT|SP_CHICKEN|SP_DBG|TPL1_|UCHE_|HLSQ_DBG|HLSQ_UNKNOWN)")
for k in sorted(x for x in set(cs_r) | set(cs_n) if CS_READS.match(x)):
    x, y = cs_r.get(k, ("0", ""))[0], cs_n.get(k, ("0", ""))[0]
    if int(x, 16) == int(y, 16):
        same += 1
    elif ADDRESS.search(k) or k in CS_PROGRAM:
        allowed += 1
    else:
        bad += 1
        print(f"DIFF dispatch      {k}: ref {x} {cs_r.get(k, ('', ''))[1][:50]} | native {y} {cs_n.get(k, ('', ''))[1][:50]}")
print(f"actions: same {same}; explained {allowed}; UNEXPECTED {bad}")
sys.exit(1 if bad else 0)
