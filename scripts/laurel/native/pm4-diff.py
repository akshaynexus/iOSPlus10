#!/usr/bin/env python3
"""pm4-diff.py REF_SUMMARY NATIVE_SUMMARY: the register state at the last draw of two `cffdump --summary` outputs. Rows: same value; differs (the value of each); only in one.
Addresses and shader code move between drivers, so a register whose name holds BASE, ADDR, OBJ_START, or a shader's own footprint is not compared by value. DESIGN lists registers that differ on purpose, each with its reason: docs/laurel_sprout/ios26-native-metal.md section 6.2.
Exit 1 when any other register differs. Run with python3 -I."""
import re
import sys

ADDR = re.compile(r"(BASE|ADDR|OBJ_START|_DST\b|_SRC\b|FETCH\[.*\]\.BASE|BINDLESS|PVT_MEM_ADDR|BORDER_COLOR)")
PROGRAM = re.compile(r"(SP_[VF]S_CTRL_REG0|SP_[VF]S_INSTRLEN|HLSQ_[VF]S_CNTL|SP_[VF]S_CONFIG|SP_VS_OUT|SP_VS_VPC|VPC_VS_PACK|PC_VS_OUT_CNTL|SP_VS_PRIMITIVE|VFD_DEST|VFD_CONTROL_[01]|VPC_VAR|VPC_CNTL_0|SP_FS_OUTPUT\[|VPC_VARYING|HLSQ_CONTROL|GRAS_CNTL|RB_RENDER_CONTROL0|SP_FS_PREFETCH|VFD_FETCH.*SIZE)")


# the native stack's decisions, not accidents
DESIGN = {
    "HLSQ_SHARED_CONSTS": "push constants per stage, not shared",
    "SP_MODE_CONTROL": "push constants per stage, not shared",
    "GRAS_SC_CNTL": "flush mode only when the program reads the framebuffer",
    "RB_RENDER_CNTL": "no UBWC in the first version: no flag bits",
    "SP_FS_TEX_CONST": "a framebuffer read is bindless, not an input attachment slot",
    "SP_FS_TEX_COUNT": "a framebuffer read is bindless, not an input attachment slot",
    "RB_MRT[0x1].BUF_INFO": "an attachment no program writes is not bound",
    "RB_MRT[0x1].PITCH": "an attachment no program writes is not bound",
    "RB_MRT[0x1].ARRAY_PITCH": "an attachment no program writes is not bound",
    "SP_FS_MRT[0x1].REG": "an attachment no program writes is not bound",
    "RB_MRT_FLAG_BUFFER[0x1].ADDR": "no UBWC",
    "RB_MRT_FLAG_BUFFER[0x1].PITCH": "no UBWC",
}


def last_draw(path):
    lines = open(path, errors="replace").read().split("\n")
    at = []
    for i, l in enumerate(lines):
        if re.match(r"\s*draw\[\d+\] register values", l):
            # the packet this state belongs to: the last opcode before it. A blit has a draw number too.
            before = [x for x in lines[max(0, i - 400):i] if "opcode:" in x]
            if before and "CP_DRAW_INDX" in before[-1]:
                at.append(i)
    if not at:
        return {}
    regs = {}
    for l in lines[at[-1] + 1:]:
        m = re.match(r"^[! ][+ ]\s+([0-9a-f]+)\s+([A-Za-z0-9_\[\]x.]+):\s*(.*)$", l)
        if m:
            regs[m[2]] = (m[1], m[3])
        elif re.match(r"\s*(opcode:|cmdstream|draw\[)", l):
            break
    return regs


ref, nat = last_draw(sys.argv[1]), last_draw(sys.argv[2])
same = addr = prog = diff = design = only = 0
print(f"registers at the last draw: reference {len(ref)}, native {len(nat)}")
rows = []
for k in sorted(set(ref) | set(nat)):
    if k not in ref:
        if int(nat[k][0], 16) != 0:
            rows.append(f"only native  {k} = {nat[k][1][:70]}")
            only += 1
        continue
    if k not in nat:
        if k in DESIGN:
            design += 1
        elif int(ref[k][0], 16) != 0 and not PROGRAM.search(k):
            rows.append(f"only ref     {k} = {ref[k][1][:70]}")
            only += 1
        continue
    if ref[k][0] == nat[k][0]:
        same += 1
    elif k in DESIGN:
        design += 1
    elif ADDR.search(k):
        addr += 1
    elif PROGRAM.search(k):
        prog += 1
        rows.append(f"program      {k}: ref {ref[k][0]} native {nat[k][0]}")
    else:
        diff += 1
        rows.append(f"DIFF         {k}: ref {ref[k][0]} {ref[k][1][:48]} | native {nat[k][0]} {nat[k][1][:48]}")
print(f"same {same}; addresses {addr}; depend on the program's code {prog}; by design {design}; UNEXPECTED {diff + only}")
print("\n".join(rows))
sys.exit(1 if diff + only else 0)
