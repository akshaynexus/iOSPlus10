#!/usr/bin/env python3
"""Add properties to nodes of an ADT made by external/slop/negroni-ios/tools/mkadt.py.

    adt-extra.py ADT            (in place; properties from config/negroni-ne2211.toml [adt.extra])

[adt.extra] maps "node/path" -> {property: "hex bytes"}. Existing properties are replaced.
Why: mkadt.py writes no /chosen mac-address-wifi0 / -bluetooth0 / -ethernet0. Without them
MobileGestalt waits for an IONetworkController each time lsd/installd ask for the Wi-Fi address
(once per app bundle), so the first LaunchServices seed stalls the Apple logo for 15+ min
(bergamota NOTES.md:152-159, ios-flame tools/mkadt.py:124-132, ios-sailfish 2484c8a).
Uses the port's own ADT library (external/slop/negroni-ios/tools/adt.py).
"""
import sys, tomllib
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
    open(path, 'wb').write(adt.serialize(root))

if __name__ == '__main__':
    main()
