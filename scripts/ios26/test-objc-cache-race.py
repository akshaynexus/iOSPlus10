#!/usr/bin/env python3
"""The method cache race of libobjc on ARMv8.0, with the real lowered code of 23F84 under Unicorn (cortex-a72), no dyld. A bucket as a reader sees it in the race: the new sel, imp still 0.
  scripts/lib/native-env.sh; out/venv-user-emu/bin/python -I scripts/ios26/test-objc-cache-race.py CACHE [--expect-old]
Each entry runs twice: a bucket with sel + imp must reach the imp; sel + imp 0 must reach the uncached path, not address 0. --expect-old: the cache before the rule: imp 0 must reach 0 (proves the test sees the bug).
Exit 0: as expected. Host only. Addresses: 23F84. docs/laurel_sprout/ios26-wallpaper-widgets.md."""
import glob, struct, sys
from unicorn import *
from unicorn.arm64_const import *

TEXT, SIZE = 0x18009b000, 0x2000
ENTRIES = {'objc_msgSend': (0x18009b400, 0x18009b8a0, False, False), 'objc_msgSendSuper2': (0x18009b6c0, 0x18009b8a0, True, False),
           'objc_msgLookup': (0x18009b520, 0x18009b940, False, True), 'objc_msgLookupSuper2': (0x18009b7a0, 0x18009b940, True, True)}
OBJ, CLS, BUCKETS, IMP, RET, SEL = 0x10000, 0x20000, 0x30000, 0x50000, 0x60000, 0x1fa000000 + 0x1230
MASK = 0xff


def read(base, addr, n):
    for f in sorted(glob.glob(base + '*')):
        if f.endswith(('.symbols', '.atlas')):
            continue
        with open(f, 'rb') as h:
            head = h.read(0x400)
            if head[:4] != b'dyld':
                continue
            off, cnt = struct.unpack('<II', head[0x10:0x18])
            h.seek(off)
            maps = h.read(32 * cnt)
            for i in range(cnt):
                a, s, fo, _, _ = struct.unpack('<QQQII', maps[i * 32:i * 32 + 32])
                if a <= addr < a + s:
                    h.seek(fo + addr - a)
                    return h.read(n)
    raise SystemExit(f'{addr:#x} not in {base}')


def run(code, start, imp, sup, lookup):
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.ctl_set_cpu_model(UC_CPU_ARM64_A72)
    mu.mem_map(TEXT, SIZE, UC_PROT_ALL)
    mu.mem_write(TEXT, code)
    for a in (OBJ, CLS, BUCKETS, IMP, RET, 0x70000):
        mu.mem_map(a, 0x10000, UC_PROT_ALL)
    mu.mem_write(OBJ, struct.pack('<Q', CLS))
    mu.mem_write(OBJ + 0x100, struct.pack('<QQ', OBJ, 0x70000))      # objc_super2: receiver, current class; the code reads its superclass at +8
    mu.mem_write(0x70000 + 8, struct.pack('<Q', CLS))
    mu.mem_write(CLS, struct.pack('<Q', 0))
    mu.mem_write(CLS + 0x10, struct.pack('<Q', (MASK << 48) | BUCKETS))
    i = (SEL ^ (SEL >> 7)) & MASK
    mu.mem_write(BUCKETS + i * 16, struct.pack('<QQ', imp, SEL))
    mu.reg_write(UC_ARM64_REG_X0, OBJ + 0x100 if sup else OBJ)
    mu.reg_write(UC_ARM64_REG_X1, SEL)
    mu.reg_write(UC_ARM64_REG_LR, RET)
    mu.reg_write(UC_ARM64_REG_SP, 0x78000)
    stops = {}
    def code_hook(u, addr, size, ud):
        if addr in (RET, IMP) or (TEXT + 0x8a0 <= addr < TEXT + 0x9e0 and addr in (0x18009b8a0, 0x18009b940)):
            stops['at'] = addr
            u.emu_stop()
    mu.hook_add(UC_HOOK_CODE, code_hook)
    try:
        mu.emu_start(start, 0xffffffffff, count=200)
    except UcError:
        return ('fault', mu.reg_read(UC_ARM64_REG_PC))
    at = stops.get('at', mu.reg_read(UC_ARM64_REG_PC))
    if at == RET:     # objc_msgLookup hands the imp back in x17
        return ('imp', mu.reg_read(UC_ARM64_REG_X17))
    return ('at', at)


def main():
    base = sys.argv[1]
    old = '--expect-old' in sys.argv
    code = read(base, TEXT, SIZE)
    bad = 0
    for name, (start, miss, sup, lookup) in ENTRIES.items():
        hit = run(code, start, IMP, sup, lookup)
        hit_ok = hit == (('imp', IMP) if lookup else ('at', IMP))
        race = run(code, start, 0, sup, lookup)
        if old:
            race_ok = race in (('imp', 0), ('fault', 0), ('at', 0))
        else:
            race_ok = race == ('at', miss)
        print(f'{name}: sel+imp -> {hit[0]} {hit[1]:#x} {"ok" if hit_ok else "WRONG"}; sel+imp 0 -> {race[0]} {race[1]:#x} {"ok" if race_ok else "WRONG"}')
        bad += (not hit_ok) + (not race_ok)
    print('PASS' if not bad else f'FAIL: {bad}')
    return 1 if bad else 0


sys.exit(main())
