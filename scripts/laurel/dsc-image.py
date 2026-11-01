#!/usr/bin/env python3
"""One image of the iOS dyld shared cache, without ipsw (macOS + Linux; needs llvm-objdump + llvm-objcopy). Run with python3 -I.

  dsc-image.py DIR images                 "VADDR PATH" of every image
  dsc-image.py DIR syms IMAGE             "VADDR kind NAME": exports (trie), symtab, and local names from the .symbols file
  dsc-image.py DIR strings IMAGE          "VADDR text" of the C strings in __cstring
  dsc-image.py DIR dis IMAGE              __text listing, with symbol names as labels
  dsc-image.py DIR fn IMAGE NAME|VADDR [N]  N instructions (default: to the next symbol): strings, symbols, stubs resolved

DIR = .../System/Library/Caches/com.apple.dyld. IMAGE = a unique part of the path. Sits next to scripts/debug/dsc-dis.py.
"""
import bisect, glob, os, re, shutil, struct, subprocess, sys, tempfile

LC_SEGMENT_64, LC_SYMTAB, LC_TRIE, LC_INFO = 0x19, 0x2, 0x80000033, 0x80000022


class Cache:
    def __init__(self, d):
        self.d, self.maps = d, []
        for f in sorted(glob.glob(os.path.join(d, 'dyld_shared_cache_arm64*'))):
            h = open(f, 'rb')
            hdr = h.read(0x400)
            if not hdr.startswith(b'dyld_v1'):
                h.close()
                continue
            mo, mc = struct.unpack_from('<II', hdr, 0x10)
            h.seek(mo)
            for _ in range(mc):
                a, s, o = struct.unpack('<QQQII', h.read(32))[:3]
                self.maps.append((a, s, o, h))
            if f.endswith('.symbols'):
                self.symfile = h
        self.maps.sort(key=lambda m: m[0])
        self.starts = [m[0] for m in self.maps]
        self.main = open(os.path.join(d, 'dyld_shared_cache_arm64'), 'rb')
        hdr = self.main.read(0x400)
        self.base = self.maps[0][0]
        io, ic = struct.unpack_from('<II', hdr, 0x1c0)
        if ic == 0:
            io, ic = struct.unpack_from('<II', hdr, 0x18)
        self.main.seek(io)
        raw = self.main.read(32 * ic)
        self.imgs = []
        for i in range(ic):
            a, _, _, po, _ = struct.unpack_from('<QQQII', raw, 32 * i)
            self.main.seek(po)
            self.imgs.append((a, self.main.read(300).split(b'\0')[0].decode()))
        self.imgs.sort()

    def read(self, va, n):
        i = bisect.bisect_right(self.starts, va) - 1
        a, s, o, h = self.maps[i]
        if not a <= va < a + s:
            raise ValueError('vaddr %#x is in no mapping' % va)
        h.seek(o + va - a)
        return h.read(n)

    def find(self, part):
        hits = [x for x in self.imgs if part in x[1]]
        exact = [x for x in hits if x[1].rsplit('/', 1)[-1].split('.')[0] == part]
        hits = exact or hits
        if not hits:
            sys.exit('no image with %r' % part)
        if len(hits) > 1:
            sys.exit('%d images with %r: %s' % (len(hits), part, [x[1] for x in hits[:8]]))
        return hits[0]


class Image:
    def __init__(self, c, va):
        self.c, self.va, self.segs, self.sects = c, va, {}, {}
        self.symtab = self.trie = None
        ncmd = struct.unpack_from('<I', c.read(va, 32), 16)[0]
        size = struct.unpack_from('<I', c.read(va, 32), 20)[0]
        lc = c.read(va + 32, size)
        off = 0
        for _ in range(ncmd):
            cmd, sz = struct.unpack_from('<II', lc, off)
            if cmd == LC_SEGMENT_64:
                name = lc[off + 8:off + 24].split(b'\0')[0].decode()
                sva, svs, sfo = struct.unpack_from('<QQQ', lc, off + 24)
                self.segs[name] = (sva, svs, sfo)
                nsect = struct.unpack_from('<I', lc, off + 64)[0]
                for i in range(nsect):
                    so = off + 72 + 80 * i
                    sn = lc[so:so + 16].split(b'\0')[0].decode()
                    a, s = struct.unpack_from('<QQ', lc, so + 32)
                    self.sects[(name, sn)] = (a, s)
            elif cmd == LC_SYMTAB:
                self.symtab = struct.unpack_from('<IIII', lc, off + 8)
            elif cmd == LC_TRIE:
                self.trie = struct.unpack_from('<II', lc, off + 8)
            elif cmd == LC_INFO:
                x = struct.unpack_from('<IIIIIIIIII', lc, off + 8)
                self.trie = self.trie or (x[8], x[9])
            off += sz

    def link(self, fo, n):
        a, _, f = self.segs['__LINKEDIT']
        return self.c.read(a + fo - f, n)


def walk_trie(buf):
    out, stack = [], [(0, '')]
    def uleb(p):
        v = s = 0
        while True:
            b = buf[p]; p += 1
            v |= (b & 0x7f) << s; s += 7
            if not b & 0x80:
                return v, p
    while stack:
        p, name = stack.pop()
        ts, q = uleb(p)
        if ts:
            flags, r = uleb(q)
            # a re-export (flag 8) has no address here, but the name is exported all the same (memcpy in libSystem)
            out.append((name, None if flags & 8 else uleb(r)[0], flags))
        _, q = uleb(p)
        q += ts
        n = buf[q]; q += 1
        for _ in range(n):
            e = buf.index(0, q)
            sub = buf[q:e].decode('latin1'); q = e + 1
            o, q = uleb(q)
            stack.append((o, name + sub))
    return out


def symbols(c, va):
    im = Image(c, va)
    seen = {}
    if im.trie and im.trie[1]:
        for n, a, _ in walk_trie(im.link(*im.trie)):
            if a is not None:
                seen[va + a] = ('export', n)
    if getattr(c, 'symfile', None) is not None:
        h = c.symfile
        h.seek(0)
        hdr = h.read(0x60)
        lo = struct.unpack_from('<Q', hdr, 0x48)[0]
        h.seek(lo)
        no, nc, so, ss, eo, ec = struct.unpack('<6I', h.read(24))
        h.seek(lo + eo)
        raw = h.read(16 * ec)
        for i in range(ec):
            dyo, ns, nn = struct.unpack_from('<QII', raw, 16 * i)
            if c.base + dyo == va or dyo == va:
                h.seek(lo + no + 16 * ns)
                nl = h.read(16 * nn)
                h.seek(lo + so)
                st = h.read(ss)
                for k in range(nn):
                    sx, ty, _, _, val = struct.unpack_from('<IBBHQ', nl, 16 * k)
                    if ty & 0xe0 or not val:
                        continue
                    nm = st[sx:st.index(0, sx)].decode('latin1')
                    if nm and val not in seen:
                        seen[val] = ('local', nm)
                break
    return sorted((a, k, n) for a, (k, n) in seen.items())


def cmd_dis(c, va):
    im = Image(c, va)
    a, s = im.sects[('__TEXT', '__text')]
    syms = {x[0]: x[2] for x in symbols(c, va)}
    base = a & ~0xfff
    tmp = tempfile.mkdtemp(prefix='dsc-image-')
    try:
        b, o = os.path.join(tmp, 'c.bin'), os.path.join(tmp, 'c.o')
        with open(b, 'wb') as h:
            h.write(c.read(base, s + a - base))
        subprocess.run(['llvm-objcopy', '-I', 'binary', '-O', 'elf64-littleaarch64',
                        '--rename-section=.data=.text,alloc,load,code', b, o], check=True)
        p = subprocess.Popen(['llvm-objdump', '-d', '--no-show-raw-insn', '--triple=aarch64', '--adjust-vma=%#x' % base, o],
                             stdout=subprocess.PIPE, text=True)
        for line in p.stdout:
            m = re.match(r'\s*([0-9a-f]+):', line)
            if not m:
                continue
            v = int(m.group(1), 16)
            if v < a:
                continue
            if v in syms:
                print('\n%s:' % syms[v])
            print(re.sub(r' *<_binary[^>]*>', '', line.rstrip()))
        p.wait()
    finally:
        shutil.rmtree(tmp)


class Names:
    """vaddr -> name over all images; one image is loaded when first asked for."""

    def __init__(self, c):
        self.c, self.addrs, self.loaded = c, [a for a, _ in c.imgs], {}

    def of(self, va):
        i = bisect.bisect_right(self.addrs, va) - 1
        if i < 0:
            return None
        base = self.addrs[i]
        if base not in self.loaded:
            try:
                self.loaded[base] = {a: n for a, _, n in symbols(self.c, base)}
            except Exception:
                self.loaded[base] = {}
        return self.loaded[base].get(va)

    def stub(self, va):
        """the target of a __stubs entry (adrp x16 / ldr x16 / br x16), else None"""
        try:
            w = struct.unpack('<3I', self.c.read(va, 12))
        except Exception:
            return None
        if w[0] & 0x9f00001f != 0x90000010 or w[2] != 0xd61f0200:
            return None
        hi = ((w[0] >> 29) & 3) | (((w[0] >> 5) & 0x7ffff) << 2)
        if hi & 0x100000:
            hi -= 0x200000
        page = (va & ~0xfff) + (hi << 12)
        if w[1] & 0xffc003ff == 0x91000210:    # add x16, x16, #imm: a direct island
            return page + ((w[1] >> 10) & 0xfff)
        if w[1] & 0xffc003ff != 0xf9400210:    # ldr x16, [x16, #imm]
            return None
        return struct.unpack('<Q', self.c.read(page + (((w[1] >> 10) & 0xfff) << 3), 8))[0] & 0xfffffffff

    def text(self, va):
        n = self.of(va)
        if n:
            return n
        t = self.stub(va)
        if t:
            return self.of(t) or '%#x' % t
        try:
            b = self.c.read(va, 96)
        except Exception:
            return None
        e = b.find(0)
        if e >= 3 and all(32 <= x < 127 for x in b[:e]):
            return '"%s"' % b[:e].decode()
        q = struct.unpack('<Q', b[:8])[0] & 0xfffffffff
        if q < self.c.base:
            return None
        try:   # a CFString constant: isa, flags, data, length
            d = struct.unpack('<Q', self.c.read(va + 16, 8))[0] & 0xfffffffff
            bb = self.c.read(d, 96)
            e = bb.find(0)
            if e >= 2 and all(32 <= x < 127 for x in bb[:e]):
                return '@"%s"' % bb[:e].decode()
        except Exception:
            pass
        n = self.of(q)
        return '-> ' + n if n else None


def cmd_fn(c, part, what, count):
    va, _ = c.find(part)
    syms = symbols(c, va)
    if what.startswith('0x'):
        addr = int(what, 16)
    else:
        hits = [x for x in syms if x[2] in (what, '_' + what)] or [x for x in syms if what in x[2]]
        if not hits:
            sys.exit('no symbol %r' % what)
        for h in hits[:12]:
            print('# %#x %s' % (h[0], h[2]))
        addr = hits[0][0]
    starts = [x[0] for x in syms]
    i = bisect.bisect_right(starts, addr)
    n = count * 4 if count else ((starts[i] if i < len(starts) else addr + 0x400) - addr)
    n = min(n, 0x8000)
    base = addr & ~0xfff
    names = Names(c)
    tmp = tempfile.mkdtemp(prefix='dsc-image-')
    try:
        b, o = os.path.join(tmp, 'c.bin'), os.path.join(tmp, 'c.o')
        with open(b, 'wb') as h:
            h.write(c.read(base, n + addr - base))
        subprocess.run(['llvm-objcopy', '-I', 'binary', '-O', 'elf64-littleaarch64',
                        '--rename-section=.data=.text,alloc,load,code', b, o], check=True)
        r = subprocess.run(['llvm-objdump', '-d', '--no-show-raw-insn', '--triple=aarch64', '--adjust-vma=%#x' % base, o],
                           check=True, capture_output=True, text=True).stdout
    finally:
        shutil.rmtree(tmp)
    regs = {}
    for line in r.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+(\S+)\s*(.*)', line)
        if not m:
            continue
        v, op, args = int(m.group(1), 16), m.group(2), re.sub(r' *<_binary[^>]*>', '', m.group(3))
        if v < addr:
            continue
        note = ''
        a = re.match(r'(x\d+), (0x[0-9a-f]+)', args)
        if op == 'adrp' and a:
            regs[a.group(1)] = int(a.group(2), 16)
        elif op == 'add' and re.match(r'x\d+, x\d+, #', args):
            d, s_, imm = re.match(r'(x\d+), (x\d+), #(\S+)', args).groups()
            if s_ in regs:
                t = regs[s_] + int(imm, 0)
                regs[d] = t
                note = names.text(t) or '%#x' % t
        elif re.match(r'(ldr|ldrsw|ldrb|str|strb)$', op) and re.match(r'[xwqdsb]\d+, \[x\d+(, #\S+)?\]', args):
            s_, imm = re.match(r'[xwqdsb]\d+, \[(x\d+)(?:, #(\S+))?\]', args).groups()
            if s_ in regs:
                t = regs[s_] + int(imm or '0', 0)
                note = names.text(t) or '%#x' % t
        elif op in ('bl', 'b', 'cbz', 'cbnz', 'tbz', 'tbnz') or op.startswith('b.'):
            t = re.search(r'0x[0-9a-f]+', args)
            if t:
                note = names.text(int(t.group(), 16)) or ''
        print('%x: %-8s %-40s %s' % (v, op, args.split('//')[0].strip(), '; ' + note if note else ''))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    c, cmd = Cache(sys.argv[1]), sys.argv[2]
    if cmd == 'images':
        for a, p in c.imgs:
            print('%#x %s' % (a, p))
        return
    if cmd == 'fn':
        cmd_fn(c, sys.argv[3], sys.argv[4], int(sys.argv[5]) if len(sys.argv) > 5 else 0)
        return
    va, path = c.find(sys.argv[3])
    if cmd == 'syms':
        print('# %s %#x' % (path, va))
        for a, k, n in symbols(c, va):
            print('%#x %s %s' % (a, k, n))
    elif cmd == 'strings':
        im = Image(c, va)
        for sec in (('__TEXT', '__cstring'), ('__TEXT', '__oslogstring')):
            if sec in im.sects:
                a, s = im.sects[sec]
                buf = c.read(a, s)
                for m in re.finditer(rb'[\x20-\x7e\t\n]{3,}', buf):
                    print('%#x %s' % (a + m.start(), m.group().decode().replace('\n', '\\n')))
    elif cmd == 'dis':
        cmd_dis(c, va)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
