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
"""
import os, sys, tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'external/slop/negroni-ios/tools'))
import adt  # noqa: E402

def find(node, path):
    for part in [p for p in path.split('/') if p]:
        node = next((c for c in node.children if c.name == part), None)
        if node is None:
            raise SystemExit(f'ADT node not found: {path}')
    return node

def main():
    path = sys.argv[1]
    extra = tomllib.loads((REPO / 'config/negroni-ne2211.toml').read_text())['adt'].get('extra', {})
    root, _ = adt.parse(open(path, 'rb').read())
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
