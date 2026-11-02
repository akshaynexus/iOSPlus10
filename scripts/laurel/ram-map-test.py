#!/usr/bin/env python3
"""mkadt.py --dram auto on fake Mu FDs (static, late, the FD of before 2974, the oldest), the pools against the window and the DT carve-outs, and the
start.s bootstrap table budget. usage: ram-map-test.py WORKDIR (scripts/laurel/ram-map-test.sh)."""
import importlib.util, os, struct, sys
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
spec = importlib.util.spec_from_file_location('laurel_mkadt', os.path.join(REPO, 'scripts', 'laurel', 'mkadt.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
W = sys.argv[1]
fails = 0
MIB = 1 << 20
# Lineage boot.img DTB /reserved-memory: the highest fixed region ends at wt_share_mem; bank A only (docs/laurel_sprout/gpu.md "Pool size")
HIGHEST_CARVEOUT_END = 0x62100000
GPU_MIN, CHUNK, BUDGET = 128 * MIB, 64 * MIB, 16     # TopazAdreno GPU_POOL_MIN, GPU_POOL_CHUNK; TOPAZ_4K BOOTSTRAP_TABLE_SIZE pages
KVA = 0xFFFFFFF007004000                             # __TEXT, as in laurel_ram.c


def fd(name, *entries):
    p = os.path.join(W, name)
    with open(p, 'wb') as f:
        for n, b, s in entries:
            f.write(n.encode().ljust(32, b'\0') + struct.pack('<QQ', b, s) + bytes(24))
    return p


def tables(base, size):
    """start.s: 2 L1 + one L2 per GiB touched of V=P and of KVA + 1 L2 for the splash framebuffer."""
    gib = lambda a, n: ((a + n - 1) >> 30) - (a >> 30) + 1
    return 2 + gib(base, size) + gib(KVA, size) + 1


def case(what, path, want_base, want_win, want_gpu):
    global fails
    (b, s), line = m.auto_dram(path)
    start = ((b + m.DARWINBOOT_BLOCK - 1) & ~(m.DARWINBOOT_BLOCK - 1)) + m.KERNEL_BLOCK_OFFSET
    res = m.ram_reserved(path)
    gpu, modem = res[0], res[1]
    checks = {
        'window': (start, s) == (want_base, want_win),
        'gpu pool': gpu == want_gpu,
        'pools outside the window or old map': want_win == m.RAM_FALLBACK or all(not (rb < start + s and start < rb + rs) for rb, rs in res),
        'pools apart': gpu[0] + gpu[1] <= modem[0],
        'pool chunk aligned, >= minimum, below 4 GiB, in one bank': gpu[0] % CHUNK == 0 and gpu[1] % CHUNK == 0 and gpu[1] >= GPU_MIN and
            gpu[0] + gpu[1] <= 1 << 32 and any(bb <= gpu[0] and gpu[0] + gpu[1] <= bb + bs for bb, bs in m.RAM_BANKS),
        'modem pool below 0xF0000000 (2401)': modem[0] + modem[1] <= 0xF0000000,
        'above every fixed carve-out': min(gpu[0], modem[0], start) >= HIGHEST_CARVEOUT_END,
        'bootstrap tables fit': tables(start, s) <= BUDGET,
        'window at most 4608 MiB, valid for DarwinBoot': s <= m.RAM_MAX and s % (2 * MIB) == 0,
    }
    bad = [k for k, v in checks.items() if not v]
    fails += bool(bad)
    print(f'{what:<30} window {start:#x}+{s >> 20} MiB, GPU {gpu[0]:#x}+{gpu[1] >> 20} MiB, modem {modem[0]:#x}, {tables(start, s)} table pages: {"ok" if not bad else "BAD " + str(bad)}')
    print(f'  {line}')


case('static (mu 0101)', fd('static', ('Pool RAM', 0x80000000, 0x41000000), ('Kernel RAM', 0xC1000000, 0xFF000000)), 0xC1004000, 3904 * MIB, (0x80000000, 0x40000000))
case('late (mu late/0101)', fd('late', ('Pool RAM Guard', 0x80000000, 0x1000000), ('UEFI RAM', 0x81000000, 0xF000000), ('Pool RAM', 0x90000000, 0x31000000)),
     0xC1004000, 3904 * MIB, (0x90000000, 0x30000000))
case('FD of before 2974', fd('before', ('Pool RAM', 0x80000000, 0x61000000), ('Kernel RAM', 0xE1000000, 0xDF000000)), 0xE1004000, 3392 * MIB, (0x80000000, 0x40000000))
case('oldest FD (768 MiB)', fd('oldest', ('Kernel RAM', 0x81000000, 0x3F000000)), 0x81004000, m.RAM_FALLBACK, (0x80000000, 0x40000000))
print('ram-map-test: FAILED' if fails else 'ram-map-test: ok')
sys.exit(fails != 0)
