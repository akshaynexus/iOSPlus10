#!/usr/bin/env python3
"""Add properties to nodes of an ADT made by external/slop/negroni-ios/tools/mkadt.py.

    adt-extra.py ADT            (in place; properties from config/negroni-ne2211.toml [adt.extra])

[adt.extra] maps "node/path" -> {property: "hex bytes"}. Existing properties are replaced.
Why: mkadt.py writes no /chosen mac-address-wifi0 / -bluetooth0 / -ethernet0. Without them
MobileGestalt waits for an IONetworkController each time lsd/installd ask for the Wi-Fi address
(once per app bundle), so the first LaunchServices seed stalls the Apple logo for 15+ min
(bergamota NOTES.md:152-159, ios-flame tools/mkadt.py:124-132, ios-sailfish 2484c8a).
Uses the port's own ADT library (external/slop/negroni-ios/tools/adt.py).

ADT_BT=1 also adds the node /arm-io/bluetooth from [adt.bluetooth] (Bluetooth stage B, patch 0332,
docs/bluetooth-plan.md section 4): bluetoothd 20H392 needs a registry entry named "bluetooth" with
local-mac-address (main 0x1000269b4; the BT_DEVICE_ADDRESS env value is discarded at 0x1000268f4) and reads
transport-encoding / transport-speed from it (0x1000e75c8, 0x1000e74e4). NegroniPlatformExpert publishes every
/arm-io child except gic as a nub (slop patch 0046), so the node becomes that registry entry. Without ADT_BT the
ADT is unchanged.

ADT_CAM=1 adds the camera nodes (userland/camera/README.md, as HakiOS xnuloader/loader.c:3125-3145,3226-3234):
/arm-io/isp with only camera-rear = 1 (no compatible, no device_type: no driver matches it; MobileGestalt answers
still-camera and rear-facing-camera, so SpringBoard shows Camera.app), and /product/camera with no properties
(MobileGestalt video-camera; no "flash" until a torch driver exists). No camera-front: the front IMX615 has no
kernel driver. scripts/ios16/build.sh sets ADT_CAM=1 by default when out/camera/ios/NegroniCamera.driver is built
(the same rule that makes scripts/ios16/root-finish.sh install it with CAMERA=1): the Camera icon and the capture
plug-in ship together.

ADT_FLASH=1 (torch, kernel patch 0387 /dev/negroniflash, userland/flashlight/README.md) adds the property "flash"
(4 bytes, 1) to /product/camera, and makes /product/camera when ADT_CAM did not. libMobileGestalt 20H392
(0x19c563598) answers camera-flash = true when IODeviceTree:/product/camera has "flash" (presence only), and
+[AVFlashlight hasFlashlight] is MGGetBoolAnswer("camera-flash"): Control Center then shows the flashlight button.
Without ADT_FLASH the ADT is unchanged.

RAM (config [ram], kernel patch 0401, docs/notes.md section 90): always. Writes /chosen negroni-ram-bank (u64 base,
u64 size of the System RAM bank) and negroni-ram-reserved (u64 base/size pairs: the GPU region) for the kernel
self-check. When /chosen dram-size (mkadt --dram SIZE: the window DarwinBoot allocates) is above [ram] fallback, it
checks that the window fits: it starts at the Mu "Kernel RAM" base (read from the FD: MU_FD, default
out/mu/SILICIUM_UEFI-DEBUG.fd; DarwinBoot: 2 MiB aligned + 16 KiB, the kernel's link offset) and must end
uefi_headroom below the end of that region, inside the bank and outside the GPU region. On a failure (e.g. a Mu FD
built before patches/mu/0002), or with XNU_RAM=0, dram-size and darwinboot-memory-size become [ram] fallback (3 GiB,
the size before 0401) and one line "NEGRONI RAM: off: <reason>" is printed: the image still boots.
    adt-extra.py --check-ram ADT   (no change; exit 1 when the ADT's window does not fit the Mu FD: DarwinBoot
                                    would stop with "NO WINDOW". scripts/ios16/build.sh boot step)
"""
import os, sys, tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'external/slop/negroni-ios/tools'))
import adt  # noqa: E402

DARWINBOOT_BLOCK = 2 << 20       # UniXNU DarwinBoot.c BLOCK_SIZE: the window keeps the kernel's offset in 2 MiB
KERNEL_BLOCK_OFFSET = 0x4000     # VM_KERNEL_LINK_ADDRESS & (2 MiB - 1): window 0x841004000 [V notes section 2]


def mu_kernel_ram(fd_path):
    """(base, size) of the Mu memory map entry "Kernel RAM" in an FD (PrePi table: CHAR8 Name[32], UINT64 Address,
    UINT64 Length, ...; stored uncompressed), or None."""
    try:
        d = Path(fd_path).read_bytes()
    except OSError:
        return None
    name = b'Kernel RAM'.ljust(32, b'\0')
    i = d.find(name)
    if i < 0 or i + 48 > len(d):
        return None
    base, size = int.from_bytes(d[i + 32:i + 40], 'little'), int.from_bytes(d[i + 40:i + 48], 'little')
    return (base, size) if base and size else None


def ram(root, cfg, check_only=False):
    """[ram] checks and properties (module doc). Returns False when check_only finds a window that does not fit."""
    r = cfg.get('ram')
    if not r:
        return True
    hx = lambda v: int(v, 16)
    pair = lambda v: tuple(hx(x) for x in v.split(':'))
    bank, bank_size = pair(r['bank'])
    gpu, gpu_size = pair(r['gpu'])
    fallback, headroom = hx(r['fallback']), hx(r['uefi_headroom'])
    chosen = find(root, 'chosen')
    get = lambda k: next((v for n, _, v in chosen.props if n == k), None)

    def put(k, v):
        chosen.props = [p for p in chosen.props if p[0] != k] + [(k, 0, v)]
    u64 = lambda x: x.to_bytes(8, 'little')
    size = int.from_bytes(get('dram-size') or b'', 'little')
    if not check_only:
        put('negroni-ram-bank', u64(bank) + u64(bank_size))
        put('negroni-ram-reserved', u64(gpu) + u64(gpu_size))
    if size <= fallback:
        print(f'NEGRONI RAM: window {size >> 20} MiB (not above the {fallback >> 20} MiB fallback): nothing to check')
        return True
    fd = os.environ.get('MU_FD') or str(REPO / 'out/mu/SILICIUM_UEFI-DEBUG.fd')
    mu = mu_kernel_ram(fd)
    why = None
    if not check_only and os.environ.get('XNU_RAM') == '0':
        why = 'XNU_RAM=0'
    elif mu is None:
        why = f'no Mu "Kernel RAM" entry in {fd}'
    else:
        mb, ms = mu
        start = ((mb + DARWINBOOT_BLOCK - 1) & ~(DARWINBOOT_BLOCK - 1)) + KERNEL_BLOCK_OFFSET
        end = start + size
        if end + headroom > mb + ms:
            why = (f'Mu FD "Kernel RAM" 0x{mb:x}..0x{mb + ms:x} has no room for the {size >> 20} MiB window '
                   f'0x{start:x}..0x{end:x} + {headroom >> 20} MiB for UEFI (rebuild Mu with patches/mu/0002: '
                   f'scripts/uefi/prepare.sh, scripts/uefi/build.sh)')
        elif start < bank or end > bank + bank_size:
            why = f'window 0x{start:x}..0x{end:x} is outside the bank 0x{bank:x}..0x{bank + bank_size:x}'
        elif start < gpu + gpu_size and gpu < end:
            why = f'window 0x{start:x}..0x{end:x} overlaps the GPU region 0x{gpu:x}..0x{gpu + gpu_size:x}'
    if why is None:
        print(f'NEGRONI RAM: on: {size >> 20} MiB window 0x{start:x}..0x{end:x} in Mu "Kernel RAM" '
              f'0x{mb:x}..0x{mb + ms:x}; GPU region 0x{gpu:x}..0x{gpu + gpu_size:x} outside')
        return True
    if check_only:
        print(f'NEGRONI RAM: the ADT window ({size >> 20} MiB) does not fit: {why}', file=sys.stderr)
        return False
    put('dram-size', u64(fallback))
    if get('darwinboot-memory-size') is not None:
        put('darwinboot-memory-size', u64(fallback))
    print(f'NEGRONI RAM: off: {why}; ADT window {fallback >> 20} MiB')
    return True

def find(node, path):
    for part in [p for p in path.split('/') if p]:
        node = next((c for c in node.children if c.name == part), None)
        if node is None:
            raise SystemExit(f'ADT node not found: {path}')
    return node

def main():
    cfg = tomllib.loads((REPO / 'config/negroni-ne2211.toml').read_text())
    if sys.argv[1] == '--check-ram':
        root, _ = adt.parse(open(sys.argv[2], 'rb').read())
        sys.exit(0 if ram(root, cfg, check_only=True) else 1)
    path = sys.argv[1]
    extra = cfg['adt'].get('extra', {})
    root, _ = adt.parse(open(path, 'rb').read())
    ram(root, cfg)
    for npath, props in extra.items():
        n = find(root, npath)
        for name, hexval in props.items():
            val = bytes.fromhex(hexval.replace(':', ''))
            n.props = [p for p in n.props if p[0] != name] + [(name, 0, val)]
            print(f'/{npath.strip("/")} {name} = {val.hex(":")}')
    def new_phandle():
        used = []
        def walk(x):
            for k, f, v in x.props:
                if k == 'AAPL,phandle' and len(v) == 4:
                    used.append(int.from_bytes(v, 'little'))
            for c in x.children:
                walk(c)
        walk(root)
        return (max(used + [0]) + 1).to_bytes(4, 'little')
    def add_node(parent_path, name, props):
        parent = find(root, parent_path)
        # a rerun replaces the node and keeps its phandle: the same input gives the same bytes
        old = next((c for c in parent.children if c.name == name), None)
        ph = next((v for k, _, v in old.props if k == 'AAPL,phandle'), None) if old else None
        parent.children = [c for c in parent.children if c.name != name]
        n = adt.Node()
        n.props = [('name', 0, name.encode() + b'\0'), ('AAPL,phandle', 0, ph or new_phandle())] + props
        n.children = []
        parent.children.append(n)
        print(f'/{parent_path}/{name}:', ', '.join(f'{k}={v.hex(":")}' for k, _, v in n.props))
        return n
    if os.environ.get('ADT_CAM') == '1':
        add_node('arm-io', 'isp', [('camera-rear', 0, (1).to_bytes(4, 'little'))])
        add_node('product', 'camera', [])
    if os.environ.get('ADT_FLASH') == '1':
        product = find(root, 'product')
        cam = next((c for c in product.children if c.name == 'camera'), None)
        if cam is None:
            cam = add_node('product', 'camera', [])
        cam.props = [p for p in cam.props if p[0] != 'flash'] + [('flash', 0, (1).to_bytes(4, 'little'))]
        print('/product/camera flash = 01:00:00:00')
    if os.environ.get('ADT_BT') == '1':
        bt = tomllib.loads((REPO / 'config/negroni-ne2211.toml').read_text())['adt']['bluetooth']
        armio = find(root, 'arm-io')
        armio.children = [c for c in armio.children if c.name != 'bluetooth']
        n = adt.Node()
        n.props = [('name', 0, b'bluetooth\0'), ('AAPL,phandle', 0, new_phandle())]
        for name, val in bt.items():
            if isinstance(val, str) and val.startswith('str:'):
                b = val[4:].encode() + b'\0'
            elif isinstance(val, int):
                b = val.to_bytes(4, 'little')
            else:
                b = bytes.fromhex(val.replace(':', ''))
            n.props.append((name, 0, b))
        n.children = []
        armio.children.append(n)
        print('/arm-io/bluetooth:', ', '.join(f'{k}={v.hex(":")}' for k, _, v in n.props))
    open(path, 'wb').write(adt.serialize(root))

if __name__ == '__main__':
    main()
