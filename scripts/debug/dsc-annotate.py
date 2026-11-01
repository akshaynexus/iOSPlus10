#!/usr/bin/env python3
"""Annotate an `ipsw dyld disass` listing of the iOS 16 (arm64, not arm64e) dyld shared cache.

ipsw 3.1 cannot parse the objc info of the 20H392 iPhone10,3 cache ("objc_stringhash_t: unexpected EOF"),
so its listings show `bl 0x18a4865c0` instead of `objc_msgSend$traitCollection`. This tool reads the cache
files itself (main file + numbered subcaches, mapping tables only) and adds, per line:
  - `bl/b <stub>`: the selector of an objc_msgSend stub (adrp x1 / ldr x1 / adrp x16 / ldr x16 / br x16)
  - `ldr xN, [xM, #off]` after `adrp xM`: the pointer there; a class ref gives the class name, a selector
    ref the selector, a C string its text, a CFString its text
  - `adrp + add`: a C string or CFString at that address
  - `ldr dN, [xM, #off]`: the double there
Usage: dsc-annotate.py DSC_MAIN_FILE < listing > annotated
       dsc-annotate.py DSC_MAIN_FILE --read ADDR [N]   (N 64-bit words)
"""
import os
import re
import struct
import sys


class Cache:
    def __init__(self, main):
        self.maps = []          # (addr, size, file object, file offset)
        d, base = os.path.split(main)
        files = [main] + sorted(os.path.join(d, n) for n in os.listdir(d or '.')
                                if n.startswith(base + '.') and not n.endswith(('.symbols', '.a2s', '.map')))
        for path in files:
            f = open(path, 'rb')
            hdr = f.read(0x200)
            if not hdr.startswith(b'dyld_v1'):
                continue
            moff, mcnt = struct.unpack_from('<II', hdr, 0x10)
            f.seek(moff)
            for _ in range(mcnt):
                addr, size, foff, _maxp, _initp = struct.unpack('<QQQII', f.read(32))
                self.maps.append((addr, size, f, foff))

    def read(self, addr, n):
        if addr is None:
            return None
        for a, s, f, o in self.maps:
            if a <= addr and addr + n <= a + s:
                f.seek(o + addr - a)
                return f.read(n)
        return None

    def u64(self, addr):
        b = self.read(addr, 8)
        return struct.unpack('<Q', b)[0] if b else None

    def u32(self, addr):
        b = self.read(addr, 4)
        return struct.unpack('<I', b)[0] if b else None

    @staticmethod
    def ptr(v):
        """slide info v2 (arm64): the target is in the low 36 bits (the high bits link the chain)."""
        if v is None:
            return None
        v &= 0xFFFFFFFFF
        return v if v >= 0x180000000 else (v + 0x180000000 if v else 0)

    def cstr(self, addr, maxlen=200):
        b = self.read(addr, maxlen)
        if b is None:
            return None
        end = b.find(b'\0')
        if end <= 0:
            return None
        s = b[:end]
        if all(32 <= c < 127 for c in s):
            return s.decode()
        return None

    def cfstr(self, addr):
        # CFString: isa, flags, char *, length
        flags = self.u64(addr + 8)
        if flags is None or (flags & 0xFFFFFFFF) not in (0x7c8, 0x7d0):
            return None
        return self.cstr(self.ptr(self.u64(addr + 16)))

    def classname(self, cls):
        data = self.ptr(self.u64(cls + 32))
        if not data:
            return None
        data &= ~7
        return self.cstr(self.ptr(self.u64(data + 0x18)))

    def stub_selector(self, addr):
        b = self.read(addr, 20)
        if b is None:
            return None
        w = struct.unpack('<5I', b)
        # adrp x1, P ; ldr x1, [x1, #o] ; adrp x16 ; ldr x16 ; br x16
        if (w[0] & 0x9F00001F) != 0x90000001 or (w[1] & 0xFFC003FF) != 0xF9400021 or w[4] != 0xD61F0200:
            return None
        imm = ((w[0] >> 29) & 3) | (((w[0] >> 5) & 0x7FFFF) << 2)
        if imm & (1 << 20):
            imm -= 1 << 21
        page = (addr & ~0xFFF) + (imm << 12)
        off = ((w[1] >> 10) & 0xFFF) * 8
        return self.cstr(self.ptr(self.u64(page + off)))

    def describe(self, addr):
        v = self.u64(addr)
        if v is None:
            return None
        p = self.ptr(v)
        for what in (lambda: ('class ' + self.classname(p)) if self.classname(p) else None,
                     lambda: ('"%s"' % self.cstr(p)) if self.cstr(p) else None,
                     lambda: ('@"%s"' % self.cfstr(p)) if self.cfstr(p) else None):
            try:
                r = what()
            except Exception:
                r = None
            if r:
                return r
        return None


def main():
    c = Cache(sys.argv[1])
    if len(sys.argv) > 2 and sys.argv[2] == '--read':
        a = int(sys.argv[3], 0)
        for i in range(int(sys.argv[4]) if len(sys.argv) > 4 else 4):
            v = c.u64(a + 8 * i)
            if v is None:
                print('%#x: not mapped' % (a + 8 * i))
                continue
            print('%#x: %#018x  ptr %#x  %s' % (a + 8 * i, v, c.ptr(v), c.describe(a + 8 * i) or ''))
        return
    adrp = {}
    for line in sys.stdin:
        line = line.rstrip('\n')
        note = None
        m = re.search(r'\s(adrp)\s+(x\d+), (0x[0-9a-f]+)', line)
        if m:
            adrp[m.group(2)] = int(m.group(3), 16)
        m = re.search(r'\s(bl|b)\s+(0x[0-9a-f]+)$', line)
        if m:
            sel = c.stub_selector(int(m.group(2), 16))
            if sel:
                note = 'objc_msgSend$' + sel
        m = re.search(r'\sldr\s+([xd]\d+), \[(x\d+), #(0x[0-9a-f]+)\]', line)
        if m and m.group(2) in adrp:
            a = adrp[m.group(2)] + int(m.group(3), 16)
            if m.group(1).startswith('d'):
                b = c.read(a, 8)
                note = 'double %r' % struct.unpack('<d', b)[0] if b else None
            else:
                d = c.describe(a)
                note = ('[%#x] ' % a) + d if d else None
        m = re.search(r'\sadd\s+(x\d+), (x\d+), #(0x[0-9a-f]+)$', line)
        if m and m.group(2) in adrp:
            a = adrp[m.group(2)] + int(m.group(3), 16)
            s = c.cstr(a) or (('@"%s"' % c.cfstr(a)) if c.cfstr(a) else None)
            if s:
                note = s if s.startswith('@') else '"%s"' % s
        print(line + ('    ; ' + note if note else ''))


if __name__ == '__main__':
    main()
