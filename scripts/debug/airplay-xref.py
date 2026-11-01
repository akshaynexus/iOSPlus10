#!/usr/bin/env python3
"""airplay-xref.py IMAGE.s STRINGS.txt... > IMAGE.ann.s: writes each string after the adrp + add that loads it. Read-only reverse-engineering aid for
docs/laurel_sprout/airplay-airdrop.md. IMAGE.s: scripts/debug/airplay-disasm.sh. STRINGS.txt: scripts/debug/air-re.sh (0xADDR: "text"); more than one file is allowed."""
import re
import sys

strings = {}
for name in sys.argv[2:]:
    for line in open(name, errors='replace'):
        m = re.match(r'(0x[0-9a-f]+): "(.*)"$', line.rstrip('\n'))
        if m:
            strings[int(m.group(1), 16)] = m.group(2)
pages = {}
ins = re.compile(r'^(0x[0-9a-f]+):\s+(?:[0-9a-f]{2} ){4}\s*(\S+)\s*(.*)$')
for line in open(sys.argv[1], errors='replace'):
    line = line.rstrip('\n')
    m = ins.match(line)
    if not m:
        print(line)
        continue
    op, args = m.group(2), m.group(3)
    a = [x.strip() for x in args.split(',')]
    note = ''
    if op == 'adrp' and len(a) == 2:
        pages[a[0]] = int(a[1], 16)
    elif op == 'add' and len(a) == 3 and a[1] in pages and a[2].startswith('#0x'):
        t = pages[a[1]] + int(a[2][1:], 16)
        pages[a[0]] = t
        if t in strings:
            note = f'  ; "{strings[t][:140]}"'
    print(line + note)
