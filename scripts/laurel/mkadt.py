#!/usr/bin/env python3
"""Apple Device Tree (ADT) for the Xiaomi Mi A3 (laurel_sprout, SM6125).

Reuses topaz's builder (external/ios-topaz/tools/mkadt.py: chosen, arm-io, gic, wdt, wlan, disp0, fbcon,
UFS, buttons, D22AP /product) and changes what differs on the Mi A3:
  * CPUs: --cores 8 (default, needs the PAGES=4k kernel): Gold A73 0x100-0x103 = cluster 0 'P' (boot CPU
    0x100 first), Silver A53 0x0-0x3 = cluster 1 'E'. XNU reads cluster-type as 'E'/'P'
    (osfmk/arm64/machine_routines.c:1036). --cores 4: the 4 Gold cores only (PAGES=16k kernel).
  * Panel 720x1560 AMOLED (stride 2880) at the same splash region 0x5c000000 (0xf00000), native canvas,
    display-scale 2 (360x780 points). [I: scale 2 is our choice; iPhone X itself is 3x]
  * Identity strings: xiaomi,laurel_sprout / qcom,trinket. Kept: xiaomi,sweet and qcom,kryo470 (the
    SweetPlatformExpert and CPU IONameMatch use them), sweet,display (AppleCLCD match).
  * Kernel RAM: --dram BASE:SIZE. The Mi A3 DDR banks are not known yet (ABL writes them into the live
    FDT; docs/laurel_sprout/hardware-map.md). Default 0x80000000:0x40000000 [I]: 1 GiB below 4 GiB
    (the GPU needs RAM below 4 GiB) and above every fixed carve-out (the highest ends at 0x62100000).
    Replace it with the real bank once the live FDT is read.
Usage: mkadt.py OUT.adt [--cores 8|4] [--dram BASE:SIZE] [--dump]
The D22AP /product node needs the iPhone X device tree $APPLE/d22ap.adt (default ~/op10-apple; Apple file,
never in git; get it with scripts/ios16/fetch-d22ap-adt.sh). Without it the node is left out (warning).
"""
import argparse
import os
import struct
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
TOPAZ_TOOLS = os.path.join(REPO, 'external', 'ios-topaz', 'tools')
if not os.path.isfile(os.path.join(TOPAZ_TOOLS, 'mkadt.py')):
    sys.exit('mkadt: missing external/ios-topaz (scripts/setup/get-references.sh ios-topaz)')
sys.path.insert(0, TOPAZ_TOOLS)
import adt  # noqa: E402
import mkadt as topaz  # noqa: E402

# Mi A3 values (docs/laurel_sprout/hardware-map.md)
FB_W, FB_H = 720, 1560
LAUREL_ECID = 0x4C415552454C0001       # 'LAUREL' + 1, synthetic (not the phone's)
GOLD_HZ, SILVER_HZ = 2000000000, 1800000000   # SM6125: Gold 2.0 GHz, Silver 1.8 GHz [I: public spec; OSM LUT not read yet]

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def find(n, name):
    for c in n.children:
        if c.name == name:
            return c
    raise SystemExit(f'mkadt: topaz tree has no /{name} node')


def setprop(n, key, value):
    for i, (k, f, v) in enumerate(n.props):
        if k == key:
            n.props[i] = (k, f, value)
            return
    n.props.append((key, 0, value))


def getprop(n, key):
    for k, f, v in n.props:
        if k == key:
            return v
    return None


def cpu_nodes(cores, phandles):
    """Gold first: XNU takes DT order for logical IDs and boots on the first (shim hands off to 0x100)."""
    out = []
    plan = [(0x100 | c, 0, ord('P'), GOLD_HZ) for c in range(4)]
    if cores == 8:
        plan += [(c, 1, ord('E'), SILVER_HZ) for c in range(4)]
    for i, (mpidr, cluster, ctype, hz) in enumerate(plan):
        out.append(topaz.node(f'cpu{i}', [
            ('AAPL,phandle', u32(next(phandles))),
            ('device_type', cstr('cpu')),
            ('compatible', cstr('qcom,kryo260') + cstr('qcom,kryo470') + cstr('ARM,v8')),
            ('reg', u32(mpidr)),                 # MPIDR Aff1:Aff0, not the logical ID
            ('cpu-id', u32(i)),
            ('cluster-id', u32(cluster)),
            ('cluster-type', u32(ctype)),        # 'P' = Gold A73, 'E' = Silver A53
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(mpidr & 0xff)),
            ('l2-cache-id', u32(cluster)),       # one L2 per cluster
            ('l3-cache-id', u32(0)),
            ('state', cstr('running' if i == 0 else 'stopped')),
            ('timebase-frequency', u32(topaz.TIMEBASE)),
            ('clock-frequency', u32(hz)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(topaz.TIMEBASE)),
            ('fixed-frequency', u32(topaz.TIMEBASE)),
        ]))
    return out


D22AP_ADT = os.path.join(os.environ.get('APPLE', os.path.expanduser('~/op10-apple')), 'd22ap.adt')
_topaz_product = topaz.d22ap_product
topaz.d22ap_product = lambda: _topaz_product(D22AP_ADT)   # its default path is bound at import


def build(cores=8, dram=(0x80000000, 0x40000000), seed=None):
    topaz.FB_W, topaz.FB_H, topaz.FB_STRIDE = FB_W, FB_H, FB_W * 4
    topaz.SWEET_ECID = LAUREL_ECID
    root = topaz.build(seed=seed, native=True)

    root.props = [(k, f, v) for k, f, v in root.props]
    setprop(root, 'compatible', cstr('D22AP') + cstr('iPhone10,3') + cstr('xiaomi,laurel_sprout') +
            cstr('xiaomi,sweet') + cstr('qcom,trinket') + cstr('AppleARM'))

    chosen = find(root, 'chosen')
    setprop(chosen, 'dram-base', u64(dram[0]))
    setprop(chosen, 'dram-size', u64(dram[1]))
    setprop(chosen, 'display-scale', u32(2))
    setprop(chosen, 'firmware-version', cstr('laurel-shim'))
    setprop(chosen, 'system-firmware-version', cstr('laurel-shim'))

    arm_io = find(root, 'arm-io')
    disp0 = find(arm_io, 'disp0')
    setprop(disp0, 'canvas-width', u32(FB_W))
    setprop(disp0, 'canvas-height', u32(FB_H))
    setprop(find(arm_io, 'wlan'), 'compatible', cstr('laurel,wcn3990'))

    # new CPU phandles above every phandle topaz used
    used = [struct.unpack('<I', getprop(n, 'AAPL,phandle'))[0] for n in walk(root) if getprop(n, 'AAPL,phandle')]
    phandles = iter(range(max(used) + 1, max(used) + 100))
    cpus = find(root, 'cpus')
    cpus.children = cpu_nodes(cores, phandles)
    return root


def walk(n):
    yield n
    for c in n.children:
        yield from walk(c)


def check(root, cores):
    """Self-check of the tree we write: one boot CPU 0x100 first, P/E counts, sizes."""
    cpus = find(root, 'cpus').children
    regs = [struct.unpack('<I', getprop(c, 'reg'))[0] for c in cpus]
    types = [struct.unpack('<I', getprop(c, 'cluster-type'))[0] for c in cpus]
    assert len(cpus) == cores and regs[0] == 0x100, regs
    assert types.count(ord('P')) == 4 and types.count(ord('E')) == cores - 4, types
    fb = find(root, 'sweet-fbcon')
    assert struct.unpack('<I', getprop(fb, 'stride'))[0] == FB_W * 4
    base, size = (struct.unpack('<Q', getprop(find(root, 'chosen'), k))[0] for k in ('dram-base', 'dram-size'))
    assert base >= 0x62100000, 'kernel RAM must be above the fixed carve-outs (highest ends at 0x62100000)'
    if base + size > 1 << 32:
        print('mkadt: note: kernel RAM reaches above 4 GiB; GPU buffers need RAM below 4 GiB', file=sys.stderr)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('out')
    ap.add_argument('--cores', type=int, choices=(4, 8), default=8)
    ap.add_argument('--dram', default='0x80000000:0x40000000')
    ap.add_argument('--dump', action='store_true')
    a = ap.parse_args()
    b, s = (int(x, 0) for x in a.dram.split(':'))
    root = build(a.cores, (b, s))
    check(root, a.cores)
    blob = adt.serialize(root)
    adt.parse(blob)   # round trip
    with open(a.out, 'wb') as f:
        f.write(blob)
    if a.dump:
        adt.dump(adt.parse(blob)[0])
    print(f'{a.out}: {len(blob)} bytes, {a.cores} cores, dram {b:#x}+{s:#x}', file=sys.stderr)
