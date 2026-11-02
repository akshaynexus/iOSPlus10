#!/usr/bin/env python3
"""scripts/laurel/test-ios26-hid.sh: compare what the 23F84 parser read with what the driver sent."""
import sys
W = sys.argv[1]


def read(name):
    r = {}
    for line in open(f'{W}/{name}.txt'):
        p = line.split()
        if p[0] == 'HID':
            r[(p[1], p[2])] = (int(p[4], 16), float(p[6]))
    return r


bad = 0


def want(r, ev, key, val, float_=True):
    global bad
    got = r.get((ev, key))
    if got is None:
        print(f'  {ev} {key}: no answer')
        bad += 1
        return
    v = got[1] if float_ else got[0]
    ok = abs(v - val) < 1e-3 if float_ else v == val
    print(f"  {'ok ' if ok else 'BAD'} {ev} {key} = {v} (driver: {val})")
    bad += 0 if ok else 1


b = read('before')
print('before (IOHIDFamily-1915 on 23F84): down event: children %s, child X %s, parent X %s' % (b.get(('event0', 'child-count'), ('?',))[0], b.get(('event0.child0', 'x'), ('?', '?'))[1], b.get(('event0', 'x'), ('?', '?'))[1]))
broken = b.get(('event0', 'child-count'), (0,))[0] != 1 or abs(b.get(('event0.child0', 'x'), (0, 0))[1] - 0.5) > 1e-3
print('before: the parser reads no finger: %s (the bug)' % broken)
a = read('after')
print('after (IOHIDFamily-2238):')
# The digitizer mask bits: Range 1, Touch 2, Position 4, Identity 0x20. The first down has Position too: the driver's own logic (a new position)
for ev, x, y, cmask in (('event0', 0.5, 0.25, 0x27), ('event1', 0.5, 0.5, 0x4), ('event2', 0.5, 0.5, 0x3)):
    want(a, ev, 'child-count', 1, False)
    want(a, ev, 'event-type', 11, False)
    want(a, ev, 'x', x)
    want(a, ev, 'y', y)
    want(a, ev, 'int-collection', 1, False)
    want(a, ev + '.child0', 'event-type', 11, False)
    want(a, ev + '.child0', 'x', x)
    want(a, ev + '.child0', 'y', y)
    want(a, ev + '.child0', 'int-type', 2, False)
    want(a, ev + '.child0', 'int-identity', 2, False)
    want(a, ev + '.child0', 'int-index', 0, False)
    want(a, ev + '.child0', 'int-mask', cmask, False)
    want(a, ev + '.child0', 'int-touch', 1 if ev != 'event2' else 0, False)
if not broken:
    print('FAIL: the old format reads right: this test does not see the bug')
    bad += 1
print('PASS' if not bad else f'FAIL: {bad}')
sys.exit(1 if bad else 0)
