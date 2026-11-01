#!/usr/bin/env python3
"""Where wifid uses a C string or CFString (out/wifi-re, made by scripts/debug/wifi-re.sh). Run with python3 -I.

  scripts/debug/wifi-xref.py out/wifi-re/wifid out/wifi-re/wifid.s TEXT...   code addresses that load TEXT
"""
import re
import struct
import sys


def sections(d):
    out = {}
    ncmds = struct.unpack_from('<I', d, 16)[0]
    o = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, o)
        if cmd == 0x19:
            nsects = struct.unpack_from('<I', d, o + 64)[0]
            for i in range(nsects):
                s = o + 72 + i * 80
                name = d[s:s + 16].rstrip(b'\0').decode()
                addr, sz, off = struct.unpack_from('<QQI', d, s + 32)
                out.setdefault(name, []).append((addr, sz, off))
        o += size
    return out


def main():
    d = open(sys.argv[1], 'rb').read()
    secs = sections(d)
    base = secs['__text'][0][0] - secs['__text'][0][2]
    wanted = {}
    for text in sys.argv[3:]:
        for m in re.finditer(re.escape(text.encode()) + b'\0', d):
            if m.start() == 0 or d[m.start() - 1] == 0:
                wanted[base + m.start()] = text
    addrs = dict(wanted)
    for addr, size, off in secs.get('__cfstring', []):
        for i in range(0, size, 32):
            p = struct.unpack_from('<Q', d, off + i + 16)[0]
            target = base + (p & 0xFFFFFFFFF)
            if p >> 36 == 0 or (p & 0xFFFFFFFFF) < 0x10000000:
                target = base + (p & 0xFFFFFFFFF) if (p & 0xFFFFFFFFF) < 0x100000000 else (p & 0xFFFFFFFFF)
            if target in wanted:
                addrs[addr + i] = wanted[target] + ' (CFString)'
    last = {}
    func = '?'
    for line in open(sys.argv[2], errors='replace'):
        m = re.match(r'^([0-9a-f]+) <(.*)>:', line)
        if m:
            func = m.group(2)
            continue
        m = re.match(r'\s*([0-9a-f]+):\s+(\S+)\s+(.*)', line)
        if not m:
            continue
        pc, op, args = m.groups()
        a = [x.strip() for x in args.split(',')]
        if op == 'adrp':
            last[a[0]] = int(a[1].split()[0], 16)
        elif op in ('add', 'ldr') and len(a) >= 3:
            src = a[1].lstrip('[')
            n = re.match(r'#(0x[0-9a-f]+|\d+)', a[2])
            if src in last and n:
                t = last[src] + int(n.group(1), 0)
                if t in addrs:
                    print(f'0x{pc} {op} -> {addrs[t]} in {func}')


main()
