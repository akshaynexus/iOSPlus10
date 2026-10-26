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
    if os.environ.get('ADT_BT') == '1':
        bt = tomllib.loads((REPO / 'config/negroni-ne2211.toml').read_text())['adt']['bluetooth']
        armio = find(root, 'arm-io')
        armio.children = [c for c in armio.children if c.name != 'bluetooth']
        n = adt.Node()
        used = []
        def walk(x):
            for k, f, v in x.props:
                if k == 'AAPL,phandle' and len(v) == 4:
                    used.append(int.from_bytes(v, 'little'))
            for c in x.children:
                walk(c)
        walk(root)
        n.props = [('name', 0, b'bluetooth\0'), ('AAPL,phandle', 0, (max(used + [0]) + 1).to_bytes(4, 'little'))]
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
