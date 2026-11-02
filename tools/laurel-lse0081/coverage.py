#!/usr/bin/env python3
"""Which words of 0081 the stream ran on the real word: coverage.py NATIVE_RECORD_FILE... One line per operation: cases per size (b h w x), and per outcome.

A record: word u32, template u16, mark u16 (0 ok, 1 SIGILL, 2 SIGSEGV, 3 SIGBUS), hash u64. Exit 1 if an operation and size has no case that finished, or none that faulted.
"""
import struct
import sys
from collections import Counter

OPS = ['ldadd', 'ldclr', 'ldeor', 'ldset', 'ldsmax', 'ldsmin', 'ldumax', 'ldumin', 'swp', 'cas', 'ldapr']


def op_of(w):
    if (w & 0x3F200C00) == 0x38200000:
        o3, opc, rs = (w >> 15) & 1, (w >> 12) & 7, (w >> 16) & 31
        if not o3:
            return opc
        if opc == 0:
            return 8
        if opc == 4 and rs == 31 and ((w >> 22) & 3) == 2:
            return 10
        return None
    return 9 if (w & 0x3FA07C00) == 0x08A07C00 else None


ok, fault, other = Counter(), Counter(), Counter()
for path in sys.argv[1:]:
    for w, _, mark, _ in struct.iter_unpack('<IHHQ', open(path, 'rb').read()):
        op = op_of(w)
        if op is None:
            other[mark] += 1
        elif mark == 0:
            ok[op, w >> 30] += 1
        else:
            fault[op, w >> 30] += 1
rc = 0
print(f'{"word":<8}{"ok b":>9}{"ok h":>9}{"ok w":>9}{"ok x":>9}{"fault b":>9}{"fault h":>9}{"fault w":>9}{"fault x":>9}')
for i, n in enumerate(OPS):
    row = [ok[i, s] for s in range(4)] + [fault[i, s] for s in range(4)]
    rc |= min(row) == 0
    print(f'{n:<8}' + ''.join(f'{v:>9}' for v in row))
print(f'not in 0081 (must stay undefined): {sum(other.values())}, of them real word undefined: {other[1]}')
rc |= sum(other.values()) != other[1]
sys.exit(1 if rc else 0)
