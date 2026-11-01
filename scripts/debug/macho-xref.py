#!/usr/bin/env python3
"""macho-xref.py MACHO TEXT...: who loads a C string or a CFString in a stripped arm64 or arm64e Mach-O. Read-only aid for docs/laurel_sprout/ios26-airdrop.md.
   macho-xref.py MACHO --dis ADDR [COUNT]       disassemble from ADDR with llvm-objdump, with strings on adrp + add
   macho-xref.py MACHO --method TEXT            the ObjC methods whose name holds TEXT, with their addresses
Each hit: address of the adrp, enclosing function start (LC_FUNCTION_STARTS), ObjC method name when the metadata gives one.
Python here because this is a small reading aid, not a product. Works on macOS and Linux."""
import bisect
import hashlib
import os
import pickle
import re
import struct
import subprocess
import sys

LC_SEGMENT_64 = 0x19
LC_FUNCTION_STARTS = 0x26


def work_file(m):
    """The disassembly and its index: Apple text, out/ only. XREF_DIS, else out/macho-xref/. Never beside the input: a file there goes into the next root build (lowered tree, 2026-11-02)."""
    if os.environ.get('XREF_DIS'):
        return os.environ['XREF_DIS']
    d = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'out', 'macho-xref')
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, '%s-%s.s' % (os.path.basename(m.path), hashlib.sha1(os.path.abspath(m.path).encode()).hexdigest()[:8]))


class Macho:
    def __init__(self, path):
        with open(path, 'rb') as f:
            data = f.read()
        self.path = path
        if struct.unpack('>I', data[:4])[0] == 0xcafebabe:
            n = struct.unpack('>I', data[4:8])[0]
            for i in range(n):
                cpu, _, off, size, _ = struct.unpack('>5I', data[8 + i * 20:28 + i * 20])
                if cpu == 0x0100000c:
                    data = data[off:off + size]
                    break
        self.d = data
        self.sections = []
        self.segments = []
        ncmds = struct.unpack('<I', data[16:20])[0]
        off = 32
        fs = None
        for _ in range(ncmds):
            cmd, size = struct.unpack('<II', data[off:off + 8])
            if cmd == LC_SEGMENT_64:
                seg = data[off + 8:off + 24].split(b'\0')[0].decode()
                vm, vms, fo, fs_, _, _, nsect, _ = struct.unpack('<QQQQIIII', data[off + 24:off + 72])
                self.segments.append((seg, vm, vms, fo, fs_))
                for i in range(nsect):
                    s = off + 72 + i * 80
                    name = data[s:s + 16].split(b'\0')[0].decode()
                    a, sz, fo2 = struct.unpack('<QQI', data[s + 32:s + 52])
                    self.sections.append((seg, name, a, sz, fo2))
            elif cmd == LC_FUNCTION_STARTS:
                fs = struct.unpack('<II', data[off + 8:off + 16])
            off += size
        self.base = next(v for s, v, *_ in self.segments if s == '__TEXT')
        self.funcs = []
        if fs is not None:
            a = self.base
            shift = v = 0
            for b in data[fs[0]:fs[0] + fs[1]]:
                v |= (b & 0x7f) << shift
                if b & 0x80:
                    shift += 7
                    continue
                if v == 0:
                    break
                a += v
                self.funcs.append(a)
                v = shift = 0

    def sect(self, seg, name):
        for s in self.sections:
            if s[0] == seg and s[1] == name:
                return s
        return None

    def off(self, a):
        for _, v, vs, fo, _ in self.segments:
            if v <= a < v + vs:
                return fo + a - v
        return None

    def ptr(self, a):
        """A pointer in a chained-fixup page: the low 36 bits (rebase target as an offset, or a plain value)."""
        o = self.off(a)
        if o is None:
            return None
        r = struct.unpack('<Q', self.d[o:o + 8])[0]
        if r >> 62 == 1 or (r >> 63 == 1 and (r >> 62) & 1):
            return None     # a bind
        t = r & 0xffffffff if r >> 63 else r & 0xfffffffff
        return t + self.base if t < self.base else t

    def cstr(self, a):
        o = self.off(a)
        if o is None:
            return None
        e = self.d.find(b'\0', o, o + 4096)
        return self.d[o:e].decode(errors='replace') if e > 0 else None

    def strings(self):
        """address -> text, for __cstring and __cfstring (a CFString's address maps to its text)."""
        out = {}
        for name in ('__cstring', '__oslogstring'):
            s = self.sect('__TEXT', name)
            if not s:
                continue
            o = s[4]
            end = o + s[3]
            while o < end:
                e = self.d.find(b'\0', o, end)
                if e < 0:
                    break
                if e > o:
                    out[s[2] + o - s[4]] = self.d[o:e].decode(errors='replace')
                o = e + 1
        for seg in ('__DATA_CONST', '__DATA', '__AUTH_CONST'):
            s = self.sect(seg, '__cfstring')
            if s:
                for a in range(s[2], s[2] + s[3], 32):
                    t = self.ptr(a + 16)
                    if t is not None and t in out:
                        out[a] = '@' + out[t]
        return out

    def methods(self):
        """IMP address -> -[Class sel]."""
        out = {}
        for seg in ('__DATA_CONST', '__DATA', '__AUTH_CONST'):
            s = self.sect(seg, '__objc_classlist')
            if not s:
                continue
            for a in range(s[2], s[2] + s[3], 8):
                cls = self.ptr(a)
                if cls is None:
                    continue
                for c, sign in ((cls, '-'), (self.ptr(cls), '+')):
                    if c is None:
                        continue
                    ro = self.ptr(c + 32)
                    if ro is None:
                        continue
                    ro &= ~7
                    name = self.ptr(ro + 24)
                    ml = self.ptr(ro + 32)
                    n = self.cstr(name) if name else '?'
                    if ml:
                        self._list(ml & ~1 if ml & 1 == 0 else ml & ~1, sign, n, out)
        return out

    def objc_stubs(self):
        """address of a stub in __objc_stubs -> selector."""
        s = self.sect('__TEXT', '__objc_stubs')
        out = {}
        if not s:
            return out
        for a in range(s[2], s[2] + s[3], 4):
            o = s[4] + a - s[2]
            w, n = struct.unpack('<II', self.d[o:o + 8])
            if w & 0x9f00001f == 0x90000001 and n & 0xffc003ff == 0xf9400021:
                imm = ((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2)
                if imm & (1 << 20):
                    imm -= 1 << 21
                t = (a & ~0xfff) + (imm << 12) + (((n >> 10) & 0xfff) << 3)
                p = self.ptr(t)
                out[a] = self.cstr(p) if p else '?'
        return out

    def _list(self, ml, sign, cname, out):
        o = self.off(ml)
        if o is None:
            return
        flags, count = struct.unpack('<II', self.d[o:o + 8])
        if count > 8000:
            return                   # not a method list: a pointer that this reader took wrongly
        if flags & 0x80000000:       # relative
            for i in range(count):
                e = ml + 8 + i * 12
                eo = self.off(e)
                if eo is None:
                    return
                nm, _, imp = struct.unpack('<iii', self.d[eo:eo + 12])
                sel = e + nm
                if flags & 0x40000000:
                    text = self.cstr(sel)
                else:
                    p = self.ptr(sel)
                    text = self.cstr(p) if p else '?'
                out[e + 8 + imp] = f'{sign}[{cname} {text}]'
        else:
            for i in range(count):
                e = ml + 8 + i * 24
                p = self.ptr(e)
                imp = self.ptr(e + 16)
                if imp:
                    out[imp & ~3] = f'{sign}[{cname} {self.cstr(p) if p else "?"}]'


def refs(m, targets):
    """adrp + add (or + ldr for a pointer) to a target."""
    s = m.sect('__TEXT', '__text')
    words = struct.unpack(f'<{s[3] // 4}I', m.d[s[4]:s[4] + (s[3] & ~3)])
    for i, w in enumerate(words):
        if w & 0x9f000000 != 0x90000000:
            continue
        rd = w & 31
        pc = s[2] + i * 4
        imm = ((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2)
        if imm & (1 << 20):
            imm -= 1 << 21
        page = (pc & ~0xfff) + (imm << 12)
        for j in range(i + 1, min(i + 8, len(words))):
            n = words[j]
            if n & 0xff800000 == 0x91000000 and (n >> 5) & 31 == rd:
                t = page + ((n >> 10) & 0xfff)
                if t in targets:
                    yield pc, t
                if n & 31 == rd:
                    break


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    m = Macho(sys.argv[1])
    # the slow part once per file: strings, methods, stubs (a work file beside the disassembly, Apple text: out/ only)
    pkl = work_file(m) + '.pkl'
    if os.path.exists(pkl):
        with open(pkl, 'rb') as f:
            st, meth, stubs = pickle.load(f)
    else:
        st, meth, stubs = m.strings(), m.methods(), m.objc_stubs()
        with open(pkl, 'wb') as f:
            pickle.dump((st, meth, stubs), f)
    funcs = sorted(set(m.funcs) | set(meth))

    def where(pc):
        k = bisect.bisect_right(funcs, pc) - 1
        f = funcs[k] if k >= 0 else 0
        return f'{f:#x} {meth.get(f, "")}'.rstrip()

    if sys.argv[2] == '--method':
        for imp, name in sorted(meth.items()):
            if any(t in name for t in sys.argv[3:]):
                print(f'{imp:#x} {name}')
        return
    if sys.argv[2] in ('--sel', '--calls'):      # who sends this selector, or who calls this address
        want = {t for t, n in stubs.items() if n in sys.argv[3:]} if sys.argv[2] == '--sel' else {int(a, 16) for a in sys.argv[3:]}
        for line in open(work_file(m), errors='replace'):
            mm = re.match(r'([0-9a-f]{9,}):\tb(l?)\t0x([0-9a-f]+)', line)
            if mm and int(mm.group(3), 16) in want:
                pc = int(mm.group(1), 16)
                print(f'{pc:#x} -> {mm.group(3)} {stubs.get(int(mm.group(3), 16), "")} in {where(pc)}')
        return
    if sys.argv[2] == '--dis':
        a = int(sys.argv[3], 16)
        n = int(sys.argv[4]) if len(sys.argv) > 4 else 80
        cache = work_file(m)
        if not os.path.exists(cache):
            with open(cache, 'w') as f:
                subprocess.run(['llvm-objdump', '--macho', '-d', '--no-show-raw-insn', m.path], stdout=f, check=True)
        pages = {}
        print(f'; in {where(a)}')
        left = n
        f = open(cache, errors='replace', newline='')
        lo, hi = 0, os.path.getsize(cache)
        while hi - lo > 4096:       # the file is in address order
            mid = (lo + hi) // 2
            f.seek(mid)
            f.readline()
            line = f.readline()
            mm = re.match(r'([0-9a-f]{9,}):', line)
            if mm and int(mm.group(1), 16) >= a:
                hi = mid
            else:
                lo = mid
        f.seek(lo)
        f.readline()
        for line in f:
            mm = re.match(r'([0-9a-f]{9,}):\t(\S+)\s*(.*)$', line.rstrip())
            if not mm:
                continue
            pc = int(mm.group(1), 16)
            if pc < a:
                continue
            if left == 0:
                break
            left -= 1
            op, args = mm.group(2), mm.group(3)
            note = ''
            r = args.split(',')
            if op == 'adrp':
                pages[r[0].strip()] = int(args.split('; 0x')[1].split()[0], 16) if '; 0x' in args else None
            elif op == 'add' and len(r) >= 3 and r[1].strip() in pages and pages[r[1].strip()] is not None and r[2].strip().startswith('#0x'):
                t = pages[r[1].strip()] + int(r[2].strip()[1:].split()[0], 16)
                pages[r[0].strip()] = t
                if t in st and st[t].startswith('@'):
                    note = f'  ; {st[t][:90]!r}'
            elif op in ('bl', 'b'):
                t = int(r[0].split()[0], 16) if r[0].startswith('0x') else None
                if t in stubs:
                    note = f'  ; msg {stubs[t]}'
                elif t in meth:
                    note = f'  ; {meth[t]}'
            print(f'{pc:#x} {op} {args}{note}'[:170])
            if op == 'retab' and n < 0:
                break
        return
    for q in sys.argv[2:]:
        hits = {a: t for a, t in st.items() if q in t}
        print(f'== {q}: {len(hits)} strings')
        for pc, t in refs(m, hits):
            print(f'{pc:#x} {st[t][:70]!r} in {where(pc)}')


if __name__ == '__main__':
    main()
