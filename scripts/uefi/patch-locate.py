#!/usr/bin/env python3
"""Find a code window of OUR binary inside a PATCHED reference binary (another firmware build) and
list the words that differ. Used to recover r0q (Galaxy S22) UEFI patches for the negroni build.

    uefi-patch-locate.py OURS.efi OFFSET PATCHED_REF.efi [--before N] [--after N]

Words are compared with PC-relative immediates (b/bl/b.cond/cbz/tbz/adr/adrp/ldr literal) and
struct/page offsets masked, like external/slop/uefi/negroni/portpatch2.py. Prints the best match
offset in the reference, the mismatch count and both words per line; '*' marks a difference.
"""
import argparse, struct

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

def words(b):
    return [struct.unpack_from('<I', b, i)[0] for i in range(0, len(b) - 3, 4)]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ours'); ap.add_argument('offset', type=lambda s: int(s, 0)); ap.add_argument('ref')
    ap.add_argument('--before', type=int, default=24); ap.add_argument('--after', type=int, default=24)
    a = ap.parse_args()
    o, r = words(open(a.ours, 'rb').read()), words(open(a.ref, 'rb').read())
    oi = a.offset // 4
    lo, hi = max(0, oi - a.before), min(len(o), oi + a.after + 1)
    win = [mask(w) for w in o[lo:hi]]
    rm = [mask(w) for w in r]
    best = None
    for s in range(0, len(rm) - len(win) + 1):
        miss = sum(1 for k, w in enumerate(win) if rm[s + k] != w)
        if best is None or miss < best[0]:
            best = (miss, s)
    miss, s = best
    shift = (s - lo) * 4
    print(f'best match: ours {lo*4:#x}..{hi*4:#x} -> ref {s*4:#x} (delta {shift:+#x}), {miss}/{len(win)} masked mismatches')
    for k in range(hi - lo):
        ow, rw = o[lo + k], r[s + k]
        flag = '*' if mask(ow) != mask(rw) else ' '
        mark = '<' if lo + k == oi else ' '
        print(f'{flag}{mark} ours {(lo+k)*4:#07x}: {ow:08x}   ref {(s+k)*4:#07x}: {rw:08x}')

if __name__ == '__main__':
    main()
