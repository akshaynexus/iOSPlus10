#!/usr/bin/env python3
"""root-airdrop-lan.py ROOT on|off: AirDrop over infrastructure Wi-Fi (en0), the alternative to AWDL on the Mi A3.
   root-airdrop-lan.py --self-test     host check on a made-up root.

There is no awdl0 here (docs/laurel_sprout/airplay-airdrop.md). sharingd 20H392 has two preferences in domain com.apple.Sharing [V disasm, docs/airdrop-plan.md 1.1]:
  BrowseAllInterfaces    0x1000ca734: the AirDrop browser skips the awdl0 lookup and browses on all interfaces (default: EnableDemoMode, false).
  RegisterAllInterfaces  0x1001b2a00: read with default false; our server then listens on all interfaces, not on awdl0 alone [I: the name; docs/airdrop-plan.md 0x1000b4c4c].
Managed preferences win over the user's: /private/var/Managed Preferences/mobile/com.apple.Sharing.plist [V docs/airdrop-plan.md]. Not EnableDemoMode: its other effects are unknown.

What it gives: AirDrop with peers on the same LAN that use _airdrop._tcp there: opendrop on a PC, another phone of this port. Not iPhones and Macs in their normal state: they use AWDL only [I].
Cost: when AirDrop is not "Receiving Off", sharingd's HTTPS server is on the LAN too; it still asks before it takes a file.
"""
import os
import plistlib
import sys
import tempfile

DIR = 'private/var/Managed Preferences/mobile'
FILE = DIR + '/com.apple.Sharing.plist'
PREFS = {'BrowseAllInterfaces': True, 'RegisterAllInterfaces': True}


def apply(root, op):
    path = os.path.join(root, FILE)
    if op == 'off':
        if os.path.exists(path):
            os.remove(path)
        print('laurel airdrop: LAN preferences off')
        return
    os.makedirs(os.path.join(root, DIR), mode=0o755, exist_ok=True)
    with open(path, 'wb') as f:
        plistlib.dump(PREFS, f, fmt=plistlib.FMT_BINARY)
    os.chmod(path, 0o644)
    if os.geteuid() == 0:           # managed preferences are root's
        os.chown(path, 0, 0)
    print('laurel airdrop: LAN preferences on: /' + FILE)


def self_test():
    with tempfile.TemporaryDirectory() as root:
        apply(root, 'on')
        apply(root, 'on')           # idempotent
        with open(os.path.join(root, FILE), 'rb') as f:
            assert plistlib.load(f) == PREFS
        apply(root, 'off')
        assert not os.path.exists(os.path.join(root, FILE))
        apply(root, 'off')          # nothing to remove: no error
    print('root-airdrop-lan: self-test passed (host only)')


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) == 3 and sys.argv[2] in ('on', 'off'):
        apply(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
