#!/usr/bin/env python3
"""rpm-fw-dis.py [MBN] [OUT]: the stock RPM firmware of the Mi A3 as ELF + Thumb disassembly + strings with their references, in OUT (default out/rpm-re, git-ignored): nothing of it goes into git.
Code segment at file 0x3000, its own address 0; data at file 0x2ae10, its own address 0x90000 (program headers: 0x4600000, 0x4690000 from the AP). Needs llvm-objdump. Run with python3 -I. Host only."""
import os, re, struct, subprocess, sys
mbn = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/laurel-backup/stock/images/rpm.mbn')
out = sys.argv[2] if len(sys.argv) > 2 else 'out/rpm-re'
os.makedirs(out, exist_ok=True)
d = open(mbn, 'rb').read()
c, dd = d[0x3000:0x3000 + 0x27e04], d[0x2ae10:0x2ae10 + 0xafb4]
names = b'\0.text\0.data\0.shstrtab\0'
ot, od, os_, osh = 52, 52 + len(c), 52 + len(c) + len(dd), 52 + len(c) + len(dd) + len(names)
e = b'\x7fELF' + bytes([1, 1, 1, 0]) + b'\0' * 8 + struct.pack('<HHIIIIIHHHHHH', 1, 40, 1, 0, 0, osh, 0x05000000, 52, 0, 0, 40, 4, 3)
sec = b'\0' * 40 + struct.pack('<10I', 1, 1, 6, 0, ot, len(c), 0, 0, 4, 0) + struct.pack('<10I', 7, 1, 3, 0x90000, od, len(dd), 0, 0, 4, 0) + struct.pack('<10I', 13, 3, 0, 0, os_, len(names), 0, 0, 1, 0)
open(f'{out}/rpm.o', 'wb').write(e + c + dd + names + sec)
strs = [(base + m.start(), m.group().decode()) for b, base in ((c, 0), (dd, 0x90000)) for m in re.finditer(rb'[\x20-\x7e]{4,}', b)]
idx = dict(strs); refs = {}
for b, base in ((c, 0), (dd, 0x90000)):
    for i in range(0, len(b) - 3, 4):
        w = struct.unpack_from('<I', b, i)[0]
        if w in idx: refs.setdefault(w, []).append(base + i)
with open(f'{out}/strings.txt', 'w') as f:
    for a, s in strs: f.write('%08x %s  xref %s\n' % (a, s, ','.join('%x' % x for x in refs.get(a, []))))
with open(f'{out}/rpm.dis', 'w') as f:
    subprocess.run(['llvm-objdump', '--triple=thumbv7m-none-eabi', '-d', f'{out}/rpm.o'], stdout=f, check=True)
print(f'rpm-fw-dis: {out}/rpm.dis, {out}/strings.txt')
