#!/usr/bin/env python3
"""Make a fake boot log area (the layout of kernel patch 0367, struct nbl_super / nbl_slot in
bsd/dev/negroni_ufs.c) for `op10tool bootlog --file`: tools/op10tool/tests/bootlog-test.sh.
Slots: boot 5 clean restart, boot 6 panic, boot 7 no end mark with a wrapped ring (5 MiB written),
boot 8 running; slot 4 has a bad CRC."""
import struct, sys, zlib

BLOCK, SLOTS, SLOT_BLOCKS, AREA, RING, FROM_END = 4096, 8, 1025, 9216, 4 << 20, 28673

def superblock():
    b = b"NEGRBLOG" + struct.pack("<6I", 1, SLOTS, SLOT_BLOCKS, AREA, RING, FROM_END)
    return b + struct.pack("<I", zlib.crc32(b))

def slot(boot, state, flags, total, pon, end, sb_ms=0, end_ms=0):
    def s(t, n): return t.encode().ljust(n, b"\0")[:n]
    h = b"NEGRBOOT" + struct.pack("<IIQIIIIQQQQQQQ", 1, 1932, boot, state, flags, RING, 1, total, 42,
                                  1793000000 + boot * 1000, 1793000000 + boot * 1000 + 300, 300000 + boot,
                                  sb_ms, end_ms)
    h += s("01234567-89AB-CDEF-0123-456789ABCDEF", 40) + s("Darwin Kernel Version 22.6.0 fake", 256)
    h += s("debug=0xc rd=ufsroot0 fake", 1024) + s(pon, 256) + s(end, 256)
    assert len(h) == 1928, len(h)
    return h + struct.pack("<I", zlib.crc32(h))

def ring_text(boot, n):
    lines, size = [], 0
    i = 0
    while size < n:
        l = f"boot {boot} line {i}\n"
        lines.append(l); size += len(l); i += 1
    return "".join(lines).encode()[:n]

out = sys.argv[1]
area = bytearray((1 + SLOTS * SLOT_BLOCKS) * BLOCK)
area[0:36] = superblock()
specs = {
    0: (5, 4, 1, 20000, "pon=KPDPWR_N", "restart (reboot)", 15000, 299000),
    1: (6, 2, 3, 30000, "pon=PS_HOLD reset=PS_HOLD type=HARD_RESET", "panic(cpu 2 caller 0xfffffe0007abc): requested over USB", 0, 299500),
    2: (7, 1, 1, 5 << 20, "pon=PS_HOLD reset=PS_HOLD type=HARD_RESET", "", 20000, 0),
    3: (8, 1, 0, 1234, "pon=PS_HOLD reset=PMIC_WATCHDOG_S2 type=HARD_RESET", "", 0, 0),
    4: (9, 3, 0, 100, "", "halt", 0, 0),
}
for i, (boot, state, flags, total, pon, end, sb, em) in specs.items():
    base = (1 + i * SLOT_BLOCKS) * BLOCK
    h = bytearray(slot(boot, state, flags, total, pon, end, sb, em))
    if i == 4:
        h[-1] ^= 0xff                       # bad CRC: must be ignored
    area[base:base + len(h)] = h
    text = ring_text(boot, total)
    ring = bytearray(RING)
    if total <= RING:
        ring[:total] = text
    else:
        tail = text[-RING:]                 # the last RING bytes, starting at stream offset total-RING
        start = (total - RING) % RING
        ring[start:] = tail[:RING - start]
        ring[:start] = tail[RING - start:]
    area[base + BLOCK:base + BLOCK + RING] = ring
open(out, "wb").write(area)
print(out)
