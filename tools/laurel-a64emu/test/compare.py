#!/usr/bin/env python3
"""Compare the two record files of the emulator test: compare.py CLASS NATIVE EMU. Prints counts per template and the first mismatches.

A record: word u32, template u16, mark u16 (0 ok, 1 SIGILL, 2 SIGSEGV, 3 SIGBUS), hash u64. Exit 1 on a mismatch.
"""
import struct
import sys
from collections import Counter

cls, a, b = sys.argv[1:4]
da = open(a, 'rb').read()
db = open(b, 'rb').read()
if len(da) != len(db) or len(da) % 16:
    sys.exit(f'{cls}: record files differ in size: {len(da)} {len(db)}')
n = len(da) // 16
bad = 0
marks = Counter()
perword = Counter()
first = []
it = struct.iter_unpack('<IHHQ', da)
jt = struct.iter_unpack('<IHHQ', db)
per_t = Counter()
bad_t = Counter()
for k, (x, y) in enumerate(zip(it, jt)):
    marks[x[2]] += 1
    per_t[x[1]] += 1
    if x != y:
        bad += 1
        bad_t[x[1]] += 1
        if len(first) < 12:
            first.append((k, x, y))
print(f'{cls}: cases {n}, mismatches {bad}; real word: ok {marks[0]}, undefined {marks[1]}, segv {marks[2]}, bus {marks[3]}')
for k, x, y in first:
    print(f'  case {k}: word {x[0]:08x} tmpl {x[1]}: native mark {x[2]} hash {x[3]:016x}, emu word {y[0]:08x} mark {y[2]} hash {y[3]:016x}')
if bad:
    print('  mismatches by template:', dict(bad_t), 'of', dict(per_t))
sys.exit(1 if bad else 0)
