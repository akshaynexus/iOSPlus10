#!/usr/bin/env python3
"""Port byte patches from one UEFI driver build to another (r0q S22 -> negroni NE2211).

    uefi-portpatch.py ORIG PATCHED TARGET OUT [--skip OFF ...] [--byte OFF=OLD:NEW ...]

Based on external/slop/uefi/negroni/portpatch2.py (same masked aarch64 context match), with:
- Branch targets: a patched b/bl is re-aimed at the function that matches the r0q destination's
  code in TARGET (masked context search), not at "same distance as the site". Falls back to the
  old rule only when that search is not unique, and says so.
- --skip OFF: a patch run (r0q offset) that is known to have no match in TARGET is skipped
  instead of failing the whole file.
- --byte OFF=OLD:NEW: a checked data patch at a TARGET offset (hex); fails if the byte is not OLD.
Exit 1 if any non-skipped run has no match or a --byte check fails.
"""
import argparse, struct, sys

def W(b, i): return struct.unpack_from('<I', b, i)[0]

def mask(w):
    if (w & 0x7c000000) == 0x14000000: return w & 0xfc000000          # b / bl
    if (w & 0xff000010) == 0x54000000: return w & 0xff00001f          # b.cond
    if (w & 0x7e000000) == 0x34000000: return w & 0xff00001f          # cbz/cbnz
    if (w & 0x7e000000) == 0x36000000: return w & 0xfff8001f          # tbz/tbnz
    if (w & 0x1f000000) == 0x10000000: return w & 0x9f00001f          # adr/adrp
    if (w & 0x3b000000) == 0x18000000: return w & 0xff00001f          # ldr literal
    if (w & 0xffc00000) == 0x91000000: return w & 0xffc003ff          # add imm
    if (w & 0x3b400000) == 0x39400000: return w & 0xffc003ff          # ldr/str unsigned imm
    return w

def mwords(b, a, n): return [mask(W(b, a + 4 * k)) for k in range(n)]

def unique_match(src, at, before, after, tw):
    """Offset in target of src[at] using a masked window; None unless exactly one hit."""
    if at - 4 * before < 0 or at + 4 * after > len(src): return None
    pat = mwords(src, at - 4 * before, before + after)
    L = len(pat)
    hits = [k for k in range(len(tw) - L) if tw[k] == pat[0] and tw[k:k + L] == pat]
    return (hits[0] + before) * 4 if len(hits) == 1 else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('orig'); ap.add_argument('patched'); ap.add_argument('target'); ap.add_argument('out')
    ap.add_argument('--skip', action='append', default=[], type=lambda s: int(s, 0))
    ap.add_argument('--byte', action='append', default=[])
    a = ap.parse_args()
    o, p = open(a.orig, 'rb').read(), open(a.patched, 'rb').read()
    t = bytearray(open(a.target, 'rb').read())
    tw = [mask(W(t, k)) for k in range(0, len(t) - 3, 4)]
    diff = [i for i in range(0, len(o) - 3, 4) if o[i:i + 4] != p[i:i + 4]]
    runs = []
    for i in diff:
        if runs and i == runs[-1][1]: runs[-1][1] = i + 4
        else: runs.append([i, i + 4])
    ok = True
    for ra, rb in runs:
        if ra in a.skip:
            print(f'  run {ra:#x}+{rb - ra}: skipped (--skip)'); continue
        found = None
        for ctx in (12, 10, 8, 6, 5, 4):
            pat = mwords(o, ra - 4 * ctx, ctx + (rb - ra) // 4 + ctx)
            L = len(pat)
            hits = [k for k in range(len(tw) - L) if tw[k] == pat[0] and tw[k:k + L] == pat]
            if len(hits) == 1:
                found = (hits[0] + ctx) * 4; break
        if found is None:
            print(f'  run {ra:#x}+{rb - ra}: NO MATCH'); ok = False; continue
        for k in range(0, rb - ra, 4):
            nw, ow = W(p, ra + k), W(o, ra + k)
            if (nw & 0x7c000000) == 0x14000000 and nw != ow:      # patched b/bl: re-aim
                off = ((nw & 0x3ffffff) ^ 0x2000000) - 0x2000000
                dest = ra + k + off * 4                            # destination in r0q
                nd = None
                for c in (8, 6, 4):
                    nd = unique_match(o, dest, 0, c, tw) or unique_match(o, dest, c, c, tw)
                    if nd is not None: break
                how = 'by code match'
                if nd is None:
                    nd = found + k + off * 4; how = 'SAME-DISTANCE FALLBACK (check by hand)'
                nw = (nw & 0xfc000000) | (((nd - (found + k)) // 4) & 0x3ffffff)
                print(f'    branch at {found + k:#x} -> {nd:#x} ({how}; r0q dest {dest:#x})')
            struct.pack_into('<I', t, found + k, nw)
        print(f'  run {ra:#x}+{rb - ra} -> {found:#x} ctx {ctx}: ' +
              ' '.join(f'{W(t, found + k):08x}' for k in range(0, rb - ra, 4)))
    for spec in a.byte:
        off, vals = spec.split('=')
        off = int(off, 16); old, new = (int(v, 16) for v in vals.split(':'))
        if t[off] != old:
            print(f'  byte {off:#x}: is {t[off]:#04x}, expected {old:#04x}: NOT PATCHED'); ok = False; continue
        t[off] = new
        print(f'  byte {off:#x}: {old:#04x} -> {new:#04x}')
    open(a.out, 'wb').write(t)
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
