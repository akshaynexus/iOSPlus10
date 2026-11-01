#!/usr/bin/env python3
"""Evidence for docs/laurel_sprout/cellular.md section 9: which methods of a 20H392 class are real ObjC methods (in its method list) and not objc_direct.
  cell-method-list.py DSC SYMS_FILE CLASS...      (SYMS_FILE from scripts/debug/cell-statusbar-re.sh or cell-dis.sh; only the file's own symbols are named)
Reads __OBJC_$_INSTANCE_METHODS_<CLASS> (small method list: 3 relative int32s per entry; IMP = address of the third + its value) and prints each IMP's symbol."""
import os, struct, sys

dsc, syms, classes = sys.argv[1], sys.argv[2], sys.argv[3:]
by_addr, lists = {}, {}
for l in open(syms, errors='replace'):
    f = l.rstrip('\n').split('\t')
    if len(f) >= 3 and f[0].startswith('0x'):
        by_addr[int(f[0].rstrip(':'), 16)] = f[2]
        if f[2].startswith('__OBJC_$_INSTANCE_METHODS_'):
            lists[f[2][len('__OBJC_$_INSTANCE_METHODS_'):]] = int(f[0].rstrip(':'), 16)
    elif l.startswith('0x') and '__OBJC_$_INSTANCE_METHODS_' in l:
        p = l.split()
        lists[p[-1].split('__OBJC_$_INSTANCE_METHODS_')[-1]] = int(p[0].rstrip(':'), 16)
# the cache's mappings, from its files: header + subcaches
def maps(path):
    with open(path, 'rb') as fh:
        h = fh.read(0x200)
    off, n = struct.unpack_from('<II', h, 0x10)
    with open(path, 'rb') as fh:
        fh.seek(off)
        m = fh.read(n * 32)
    return [struct.unpack_from('<QQQ', m, i * 32) + (path,) for i in range(n)]
paths = [dsc] + ['%s.%02d' % (dsc, i) for i in range(1, 60) if os.path.exists('%s.%02d' % (dsc, i))]
mp = [x for p in paths for x in maps(p)]
def read(a, n):
    for addr, size, foff, path in mp:
        if addr <= a < addr + size:
            with open(path, 'rb') as fh:
                fh.seek(foff + a - addr)
                return fh.read(n)
    raise ValueError(hex(a))
for c in classes:
    a = lists.get(c)
    if a is None:
        print('%s: no method list symbol' % c)
        continue
    ent, cnt = struct.unpack('<II', read(a, 8))
    names = []
    for i in range(cnt):
        p = a + 8 + i * 12
        imp = struct.unpack('<i', read(p + 8, 4))[0]
        names.append(by_addr.get(p + 8 + imp, hex(p + 8 + imp)))
    print('%s: %d methods, entsize %x' % (c, cnt, ent & 0xffff))
    for n in names:
        print('  ' + n)
