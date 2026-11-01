#!/usr/bin/env python3
"""Disassemble bytes of a dyld shared cache by VM address, with no Apple tool: cache-dis.py CACHE_BASE ADDR [BEFORE_WORDS AFTER_WORDS] [--from-pacibsp].
CACHE_BASE: the path of the main cache file; subcaches are found next to it. Uses llvm-mc. Output: address, word, text. Host only."""
import glob, re, struct, subprocess, sys

def maps(base):
    out = []
    for f in sorted(glob.glob(base + '*')):
        if f.endswith(('.symbols', '.atlas')):
            continue
        with open(f, 'rb') as fh:
            h = fh.read(0x400)
        if h[:4] != b'dyld':
            continue
        off, cnt = struct.unpack('<II', h[0x10:0x18])
        with open(f, 'rb') as fh:
            fh.seek(off)
            d = fh.read(32 * cnt)
        for i in range(cnt):
            a, s, fo, _, _ = struct.unpack('<QQQII', d[i * 32:i * 32 + 32])
            out.append((a, s, fo, f))
    return out

def read(ms, addr, n):
    for a, s, fo, f in ms:
        if a <= addr < a + s:
            with open(f, 'rb') as fh:
                fh.seek(fo + addr - a)
                return fh.read(n)
    raise SystemExit(f'{addr:#x} not in the cache')

def cstr(ms, a):
    try:
        b = read(ms, a, 96)
    except SystemExit:
        return None
    e = b.find(b'\0')
    if e > 0 and all(32 <= c < 127 for c in b[:e]):
        return b[:e].decode()
    return None

def string_at(ms, a):
    """A CFString constant (isa, flags, chars, length; the chars pointer is a slide-info entry: low 34 bits from the cache base), or a C string."""
    try:
        b = read(ms, a, 32)
    except SystemExit:
        return f'{a:#x}'
    v = struct.unpack('<Q', b[16:24])[0]
    t = cstr(ms, 0x180000000 + (v & 0x3FFFFFFFF))
    if t and struct.unpack('<Q', b[24:32])[0] == len(t):
        return f'@"{t}"'
    t = cstr(ms, a)
    return f'"{t}"' if t else f'{a:#x}'

def dis(words):
    src = '\n'.join(' '.join(f'0x{(w >> (8 * k)) & 255:02x},' for k in range(4)).rstrip(',') for w in words)
    r = subprocess.run(['llvm-mc', '--disassemble', '--triple=aarch64', '--mattr=+all', '--show-encoding'], input=src, capture_output=True, text=True).stdout
    return [l.split('//')[0].strip() or '?' for l in r.splitlines() if '// encoding' in l or 'warning' in l]

def main():
    base = sys.argv[1]
    addr = int(sys.argv[2], 0)
    before = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    after = int(sys.argv[4]) if len(sys.argv) > 4 else 60
    ms = maps(base)
    start = addr - 4 * before
    if '--from-pacibsp' in sys.argv:
        a = addr
        while struct.unpack('<I', read(ms, a, 4))[0] != 0xD503237F:
            a -= 4
        start = a
    b = read(ms, start, addr + 4 * after - start)
    ws = list(struct.unpack('<%dI' % (len(b) // 4), b))
    src = [dis([w]) for w in ws] if len(ws) < 0 else None
    # one call per word would be slow: llvm-mc stops on no word, and marks bad ones with a warning line
    text = []
    r = subprocess.run(['llvm-mc', '--disassemble', '--triple=aarch64', '--mattr=+all'], input='\n'.join(' '.join(f'0x{(w >> (8 * k)) & 255:02x},' for k in range(4)).rstrip(',') for w in ws), capture_output=True, text=True)
    lines = [l.strip() for l in r.stdout.splitlines() if l.startswith('\t')]
    bad = r.stderr.count('invalid instruction encoding')
    if bad == 0 and len(lines) == len(ws):
        text = lines
    else:
        text = [(dis_one(w)) for w in ws]
    page = {}
    for i, w in enumerate(ws):
        pc = start + 4 * i
        t = ' '.join(text[i].split())
        note = ''
        m = re.match(r'adrp (x\d+), #(-?\d+)', t)
        if m:
            page[m[1]] = (pc & ~0xfff) + int(m[2])
        m = re.match(r'add (x\d+), (x\d+), #(\d+)$', t)
        if m and m[2] in page:
            a = page[m[2]] + int(m[3])
            note = ' ; ' + string_at(ms, a)
        print(f'{pc:#x} {w:08x} {t}{note}')

def dis_one(w):
    r = subprocess.run(['llvm-mc', '--disassemble', '--triple=aarch64', '--mattr=+all'], input=' '.join(f'0x{(w >> (8 * k)) & 255:02x},' for k in range(4)).rstrip(','), capture_output=True, text=True)
    ls = [l.strip() for l in r.stdout.splitlines() if l.startswith('\t')]
    return ls[0] if ls else '.word'

if __name__ == '__main__':
    main()
