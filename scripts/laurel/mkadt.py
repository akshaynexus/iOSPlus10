#!/usr/bin/env python3
"""Apple Device Tree (ADT) for the Xiaomi Mi A3 (laurel_sprout, SM6125).

Reuses topaz's builder (external/ios-topaz/tools/mkadt.py: chosen, arm-io, gic, wdt, wlan, disp0, fbcon,
UFS, buttons, D22AP /product) and changes what differs on the Mi A3:
  * CPUs: --cores 8 (default, needs the PAGES=4k kernel): Gold A73 0x100-0x103 = 'P' cluster, Silver A53
    0x0-0x3 = 'E' cluster. XNU reads cluster-type as 'E'/'P' (osfmk/arm64/machine_routines.c:1036) and takes
    the boot CPU from state = "running" (ml_is_boot_cpu); it must be first (logical CPU 0, topaz 0082 / laurel 2012).
    --boot gold (default; topaz shim path: the shim hands off to Gold 0x100): Gold cluster first.
    --boot silver (UEFI/DarwinBoot path, docs/laurel_sprout/uefi-boot.md): Silver 0x0 first, the core ABL and
    UEFI run on; Silver = cluster 0 'E', Gold = cluster 1 'P' (Apple SoCs boot on an E core too).
    --cores 4: the 4 Gold cores only (PAGES=16k kernel; --boot gold only).
  * Panel 720x1560 AMOLED (stride 2880) at the same splash region 0x5c000000 (0xf00000), native canvas,
    display-scale 2 (360x780 points). [I: scale 2 is our choice; iPhone X itself is 3x]
  * Identity strings: xiaomi,laurel_sprout / qcom,trinket. Kept: xiaomi,sweet and qcom,kryo470 (the
    SweetPlatformExpert and CPU IONameMatch use them), sweet,display (AppleCLCD match).
  * Kernel RAM: --dram BASE:SIZE. The Mi A3 DDR banks are not known yet (ABL writes them into the live
    FDT; docs/laurel_sprout/hardware-map.md). Default 0x80000000:0x40000000 [I]: 1 GiB below 4 GiB
    (the GPU needs RAM below 4 GiB) and above every fixed carve-out (the highest ends at 0x62100000).
    Replace it with the real bank once the live FDT is read.
  * --darwinboot: /chosen darwinboot-memory-size = dram SIZE (UniXNU DarwinBoot allocates a window of that size
    in the first UEFI conventional-memory run that fits: Mu "Kernel RAM", patches/laurel/mu/0001 + 0101);
    firmware-version "laurel-uefi".
  * --dram auto --mu-fd FD (UEFI path, kernel patch 2100): the window size from the Mu FD's "Kernel RAM" entry
    (PrePi memory map table, uncompressed in the FD). Mu 0101 ("Kernel RAM" 0xE1000000 + 0xDF000000, to 0x1C0000000):
    3264 MiB (window 0xE1004000..0x1AD004000; the largest 64 MiB multiple that leaves 256 MiB for UEFI, at most 4608 MiB,
    the TOPAZ_4K bootstrap page-table limit). An older FD (Kernel RAM to 0xC0000000): 768 MiB, as before, with a
    "LAUREL RAM: off:" line.
  * /arm-io/bluetooth (kernel patch 2600): local-mac-address (fallback 02:4c:41:33:42:54, synthetic),
    transport-encoding 3 (H4BC), transport-speed 3000000, as the negroni [adt.bluetooth] node.
  * /chosen laurel-ram-banks (u64 base/size pairs): the DDR banks XNU may manage, B 0x80000000 + 1 GiB and
    C 0xC0000000 + 4 GiB (they touch; bank A 0x40000000-0x7CC00000 holds every fixed carve-out). /chosen
    laurel-ram-reserved: device pools that must stay out of kernel RAM: 0xC0000000 + 512 MiB (Adreno GPU pool) and
    0xE0000000 + 16 MiB (TopazModem pool). Kernel patch 2100 checks the boot window against both.
Usage: mkadt.py OUT.adt [--cores 8|4] [--boot gold|silver] [--dram BASE:SIZE|auto] [--mu-fd FD] [--darwinboot] [--dump]
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
# DDR banks XNU may manage (docs/laurel_sprout/uefi-boot.md "RAM layout"; kernel patch 2100)
RAM_BANKS = ((0x80000000, 0x40000000), (0xC0000000, 0x100000000))
# device pools outside kernel RAM (Mu 0101 "Pool RAM" 0x80000000-0xE1000000 holds them): GPU, modem
RAM_RESERVED = ((0xC0000000, 0x20000000), (0xE0000000, 0x01000000))
RAM_STEP = 64 << 20              # --dram auto window granularity
RAM_MAX = 4608 << 20             # laurel 2100 LAUREL_RAM_MAX (TOPAZ_4K BOOTSTRAP_TABLE_SIZE)
RAM_FALLBACK = 768 << 20         # the window before 2100 (Mu "Kernel RAM" to 0xC0000000)
UEFI_HEADROOM = 256 << 20        # room left in "Kernel RAM" above the window for UEFI's own allocations
DARWINBOOT_BLOCK, KERNEL_BLOCK_OFFSET = 2 << 20, 0x4000   # DarwinBoot.c BLOCK_SIZE; VM_KERNEL_LINK_ADDRESS & 0x1FFFFF
FB_W, FB_H = 720, 1560
LAUREL_ECID = 0x4C415552454C0001       # 'LAUREL' + 1, synthetic (not the phone's)
# Bluetooth (patch 2600): fallback address, locally administered, synthetic (not the phone's), used only when the
# WCN3990 has no unique address of its own; the speed the kernel leaves the chip at
BT_ADDR = bytes.fromhex('024c41334254')   # 02:4c:41:33:42:54 ("LA3BT")
BT_SPEED = 3000000
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


def cpu_nodes(cores, phandles, boot='gold'):
    """XNU takes DT order for logical IDs; the first node is state=running = the boot CPU
    (gold: the shim hands off to 0x100; silver: UEFI/DarwinBoot stay on the ABL's core 0x0)."""
    out = []
    gold = [(0x100 | c, 0 if boot == 'gold' else 1, ord('P'), GOLD_HZ) for c in range(4)]
    silver = [(c, 1 if boot == 'gold' else 0, ord('E'), SILVER_HZ) for c in range(4)]
    if boot == 'silver':
        if cores != 8:
            raise SystemExit('mkadt: --boot silver needs --cores 8 (the 16K kernel cannot run on Silver)')
        plan = silver + gold
    else:
        plan = gold + (silver if cores == 8 else [])
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


def build(cores=8, dram=(0x80000000, 0x40000000), seed=None, boot='gold', darwinboot=False):
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
    setprop(chosen, 'laurel-ram-banks', b''.join(u64(b, sz) for b, sz in RAM_BANKS))   # laurel 2100 self-check
    setprop(chosen, 'laurel-ram-reserved', b''.join(u64(b, sz) for b, sz in RAM_RESERVED))
    fw = 'laurel-uefi' if darwinboot else 'laurel-shim'
    setprop(chosen, 'firmware-version', cstr(fw))
    setprop(chosen, 'system-firmware-version', cstr(fw))
    if darwinboot:
        # UniXNU DarwinBoot: size of the RAM window it allocates (>= 256 MiB, 2 MiB multiple); XNU gets exactly it
        setprop(chosen, 'darwinboot-memory-size', u64(dram[1]))

    arm_io = find(root, 'arm-io')
    disp0 = find(arm_io, 'disp0')
    setprop(disp0, 'canvas-width', u32(FB_W))
    setprop(disp0, 'canvas-height', u32(FB_H))
    setprop(find(arm_io, 'wlan'), 'compatible', cstr('laurel,wcn3990'))

    # new CPU phandles above every phandle topaz used
    used = [struct.unpack('<I', getprop(n, 'AAPL,phandle'))[0] for n in walk(root) if getprop(n, 'AAPL,phandle')]
    phandles = iter(range(max(used) + 1, max(used) + 100))
    cpus = find(root, 'cpus')
    cpus.children = cpu_nodes(cores, phandles, boot)
    arm_io.children = [c for c in arm_io.children if c.name != 'bluetooth']
    arm_io.children.append(bluetooth_node(next(phandles)))
    return root


def bluetooth_node(phandle):
    """/arm-io/bluetooth for iOS bluetoothd (kernel patch 2600, docs/laurel_sprout/bluetooth.md). SweetPlatformExpert
    makes it the registry entry "bluetooth" that bluetoothd 20H392 looks for; it reads local-mac-address,
    transport-encoding (3 = H4BC) and transport-speed. The kernel puts the address in use into local-mac-address
    (the chip's own one when unique) and hides the node when Bluetooth is off."""
    n = adt.Node()
    n.props = [('name', 0, cstr('bluetooth')), ('AAPL,phandle', 0, u32(phandle)),
               ('device_type', 0, cstr('bluetooth')), ('compatible', 0, cstr('bluetooth,wcn3990')),
               ('local-mac-address', 0, BT_ADDR), ('transport-encoding', 0, u32(3)),
               ('transport-speed', 0, u32(BT_SPEED)), ('vendor-id', 0, u32(0x05ac)), ('product-id', 0, u32(0x12a0))]
    return n


def mu_kernel_ram(fd_path):
    """(base, size) of the Mu memory map entry "Kernel RAM" in an FD (PrePi table: CHAR8 Name[32], UINT64 Address,
    UINT64 Length, ...; stored uncompressed), or None. Same reader as scripts/ios16/adt-extra.py."""
    try:
        with open(fd_path, 'rb') as f:
            d = f.read()
    except OSError:
        return None
    i = d.find(b'Kernel RAM'.ljust(32, b'\0'))
    if i < 0 or i + 48 > len(d):
        return None
    base, size = struct.unpack_from('<QQ', d, i + 32)
    return (base, size) if base and size else None


def auto_dram(fd_path):
    """(dram base, window size) for --dram auto, and the LAUREL RAM line for the build log."""
    mu = mu_kernel_ram(fd_path)
    if mu is None:
        return (0x81000000, RAM_FALLBACK), f'LAUREL RAM: off: no Mu "Kernel RAM" entry in {fd_path}; ADT window 768 MiB'
    base, size = mu
    start = ((base + DARWINBOOT_BLOCK - 1) & ~(DARWINBOOT_BLOCK - 1)) + KERNEL_BLOCK_OFFSET
    room = base + size - start - UEFI_HEADROOM
    run = next(((b, b + s) for b, s in RAM_BANKS if b <= start < b + s), None)
    if run is not None:   # extend over touching banks
        for b, s in RAM_BANKS:
            if b == run[1]:
                run = (run[0], b + s)
    win = min(RAM_MAX, max(room, 0) // RAM_STEP * RAM_STEP)
    clash = next(((b, b + s) for b, s in RAM_RESERVED if b < start + win and start < b + s), None)
    if win > RAM_FALLBACK and run is not None and start + win <= run[1] and clash is None:
        return (base, win), (f'LAUREL RAM: on: {win >> 20} MiB window 0x{start:x}..0x{start + win:x} in Mu '
                             f'"Kernel RAM" 0x{base:x}..0x{base + size:x} ({(base + size - start - win) >> 20} MiB '
                             f'left for UEFI)')
    why = (f'window 0x{start:x}..0x{start + win:x} overlaps the pool 0x{clash[0]:x}..0x{clash[1]:x}' if clash else
           f'Mu FD "Kernel RAM" 0x{base:x}..0x{base + size:x} has no room for more than {RAM_FALLBACK >> 20} MiB + '
           f'{UEFI_HEADROOM >> 20} MiB for UEFI (FD from before patches/laurel/mu/0101: make laurel-mu)')
    return (base, RAM_FALLBACK), f'LAUREL RAM: off: {why}; ADT window {RAM_FALLBACK >> 20} MiB'


def walk(n):
    yield n
    for c in n.children:
        yield from walk(c)


def check(root, cores, boot='gold', darwinboot=False):
    """Self-check of the tree we write: one boot CPU (0x100 or 0x0) first and running, P/E counts, sizes."""
    cpus = find(root, 'cpus').children
    regs = [struct.unpack('<I', getprop(c, 'reg'))[0] for c in cpus]
    types = [struct.unpack('<I', getprop(c, 'cluster-type'))[0] for c in cpus]
    states = [getprop(c, 'state') for c in cpus]
    assert len(cpus) == cores and regs[0] == (0x100 if boot == 'gold' else 0x0), regs
    assert states[0] == cstr('running') and states.count(cstr('running')) == 1, states
    if darwinboot:
        ws = struct.unpack('<Q', getprop(find(root, 'chosen'), 'darwinboot-memory-size'))[0]
        assert ws >= 0x10000000 and ws % 0x200000 == 0, 'darwinboot-memory-size: >= 256 MiB, 2 MiB multiple'
    else:
        assert getprop(find(root, 'chosen'), 'darwinboot-memory-size') is None
    assert types.count(ord('P')) == 4 and types.count(ord('E')) == cores - 4, types
    fb = find(root, 'sweet-fbcon')
    assert struct.unpack('<I', getprop(fb, 'stride'))[0] == FB_W * 4
    base, size = (struct.unpack('<Q', getprop(find(root, 'chosen'), k))[0] for k in ('dram-base', 'dram-size'))
    assert base >= 0x62100000, 'kernel RAM must be above the fixed carve-outs (highest ends at 0x62100000)'
    if base + size > 1 << 32:
        print(f'mkadt: note: kernel RAM reaches above 4 GiB ({((1 << 32) - base) >> 20} MiB below): display/GPU/DMA '
              f'buffers ask for RAM below 4 GiB (laurel 2100/2101)', file=sys.stderr)
    banks = getprop(find(root, 'chosen'), 'laurel-ram-banks')
    assert banks and len(banks) % 16 == 0, 'laurel-ram-banks: u64 base/size pairs'


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('out')
    ap.add_argument('--cores', type=int, choices=(4, 8), default=8)
    ap.add_argument('--boot', choices=('gold', 'silver'), default='gold')
    ap.add_argument('--dram', default='0x80000000:0x40000000', help='BASE:SIZE, or auto (needs --mu-fd)')
    ap.add_argument('--mu-fd', help='Mu FD for --dram auto (its "Kernel RAM" entry decides the window size)')
    ap.add_argument('--darwinboot', action='store_true')
    ap.add_argument('--dump', action='store_true')
    a = ap.parse_args()
    if a.dram == 'auto':
        if not a.mu_fd:
            sys.exit('mkadt: --dram auto needs --mu-fd FD')
        (b, s), line = auto_dram(a.mu_fd)
        print(line, file=sys.stderr)
    else:
        b, s = (int(x, 0) for x in a.dram.split(':'))
    root = build(a.cores, (b, s), boot=a.boot, darwinboot=a.darwinboot)
    check(root, a.cores, a.boot, a.darwinboot)
    blob = adt.serialize(root)
    adt.parse(blob)   # round trip
    with open(a.out, 'wb') as f:
        f.write(blob)
    if a.dump:
        adt.dump(adt.parse(blob)[0])
    print(f'{a.out}: {len(blob)} bytes, {a.cores} cores, boot {a.boot}, dram {b:#x}+{s:#x}'
          f'{", darwinboot window" if a.darwinboot else ""}', file=sys.stderr)
