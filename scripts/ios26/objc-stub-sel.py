#!/usr/bin/env python3
"""Selector of an __objc_stubs entry in an arm64e Mach-O, for reading llvm-objdump output. Host, read only. Run with python3 -I.

  objc-stub-sel.py BINARY VADDR...    prints "VADDR selector" (the stub loads x1 with adrp + ldr from __objc_selrefs).
"""
import re, subprocess, sys

b = sys.argv[1]
for a in sys.argv[2:]:
    v = int(a, 16)
    t = subprocess.run(['llvm-objdump', '-d', '--no-show-raw-insn', f'--start-address={v:#x}', f'--stop-address={v + 8:#x}', b], capture_output=True, text=True).stdout
    p = re.search(r'adrp\s+x1, (0x[0-9a-f]+)', t)
    o = re.search(r'ldr\s+x1, \[x1, #(0x[0-9a-f]+)\]', t)
    if not p or not o:
        print(a, '?', t.splitlines()[-2:])
        continue
    ref = int(p[1], 16) + int(o[1], 16)
    d = open(b, 'rb').read()
    import struct
    # file offset through the segment list
    n = struct.unpack_from('<I', d, 16)[0]
    off, segs = 32, []
    for _ in range(n):
        c, s = struct.unpack_from('<II', d, off)
        if c == 0x19:
            segs.append(struct.unpack_from('<QQQ', d, off + 24))
        off += s
    fo = lambda va: next(va - x + z for x, y, z in segs if x <= va < x + y)
    t2 = struct.unpack_from('<Q', d, fo(ref))[0] & 0xffffffff
    t2 += 0x100000000
    e = d.index(b'\0', fo(t2))
    print(a, d[fo(t2):e].decode())
