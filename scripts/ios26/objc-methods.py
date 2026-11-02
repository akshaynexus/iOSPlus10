#!/usr/bin/env python3
"""Objective-C methods of an arm64e Mach-O with chained fixups (llvm-objdump --objc-meta-data stops on them). Host, read only. Run with python3 -I.

  objc-methods.py BINARY [CLASS_SUBSTRING]    prints "IMP_VMADDR -[Class selector]"; +[..] for class methods.
"""
import struct, sys

LC_SEGMENT_64 = 0x19
d = open(sys.argv[1], 'rb').read()
want = sys.argv[2] if len(sys.argv) > 2 else ''
ncmds = struct.unpack_from('<I', d, 16)[0]
off, segs, sects = 32, [], {}
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', d, off)
    if cmd == LC_SEGMENT_64:
        vm, vs, fo = struct.unpack_from('<QQQ', d, off + 24)
        segs.append((vm, vs, fo))
        for i in struct.unpack_from('<I', d, off + 64):
            for s in range(i):
                o = off + 72 + s * 80
                name = d[o:o + 16].split(b'\0')[0].decode()
                a, sz = struct.unpack_from('<QQ', d, o + 32)
                sects[name] = (a, sz)
    off += size
BASE = 0x100000000


def fo(va):
    for vm, vs, f in segs:
        if vm <= va < vm + vs:
            return va - vm + f
    return None


def ptr(va):
    o = fo(va)
    if o is None:
        return 0
    v = struct.unpack_from('<Q', d, o)[0]
    if v >> 63:  # auth
        return BASE + (v & 0xffffffff) if not (v >> 62) & 1 else 0
    if (v >> 62) & 1:  # bind
        return 0
    t = v & 0x7ffffffffff
    return t if t >= BASE else BASE + t


def cstr(va):
    o = fo(va)
    e = d.find(b"\0", o) if o else -1
    return d[o:e].decode("utf8", "replace") if e >= 0 else "?"


def methods(lst, cls, sign):
    lst &= ~3
    if not lst or fo(lst) is None:
        return
    flags, count = struct.unpack_from('<II', d, fo(lst))
    es = flags & 0xfffc
    if es not in (12, 24) or count > 4096:
        return
    for i in range(count):
        e = lst + 8 + i * es
        if fo(e) is None:
            return
        if flags & 0x80000000:
            n, _, imp = struct.unpack_from('<iii', d, fo(e))
            sel = e + n
            s = ptr(sel) if (flags & 0x40000000) == 0 else sel
            imp = e + 8 + imp
        else:
            s = ptr(e)
            imp = ptr(e + 16)
        print(f'{imp:#x} {sign}[{cls} {cstr(s)}]')


def walk(c, sign):
    ro = ptr(c + 32) & ~7
    if not ro:
        return None
    name = cstr(ptr(ro + 24))
    if want in name:
        methods(ptr(ro + 32), name, sign)
    return name


a, sz = sects['__objc_classlist']
for i in range(sz // 8):
    c = ptr(a + i * 8)
    walk(c, '-')
    if ptr(c):
        walk(ptr(c), '+')
