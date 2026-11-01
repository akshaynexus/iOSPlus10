#!/usr/bin/env python3
"""root-airplay-legacy.py ROOT on|off: AirPlay audio through the sender's legacy session on the Mi A3.
   root-airplay-legacy.py --self-test     host check on a made-up root.

AirPlaySender 20H392 [V disassembly, scripts/debug/airplay-disasm.sh, docs/laurel_sprout/airdrop-awdl.md]: endpoint_shouldUseLegacySenderSession reads the setting
sessionProtocolOverride (domain com.apple.airplay): "legacy" gives APSenderSessionLegacyAudio ("because of defaults write"), "airplay" APSenderSessionAirPlay.
The legacy session (sdpsession) uses the NTP clock (APSNetworkClockNTP) and asks the receiver for one of RSA (1), FairPlay (4), MFi (8).
The AirPlay session asks for PTP (IOTimeSyncDomain: not on this port) when the receiver can do it, and for FairPlay on /fp-setup (no fairplayd here).
So "legacy" removes the two known blockers for every receiver that accepts RAOP with RSA or no key, as third-party receivers do [I].
Cost: no multi-room; screen mirroring goes through the same choice and fails [I]: AIRPLAY_LEGACY=0 at the root build goes back.
mediaserverd runs as mobile, and managed preferences win over the user's: /private/var/Managed Preferences/mobile.
"""
import os
import plistlib
import sys
import tempfile

DIR = 'private/var/Managed Preferences/mobile'
FILE = DIR + '/com.apple.airplay.plist'
PREFS = {'sessionProtocolOverride': 'legacy'}


def apply(root, op):
    path = os.path.join(root, FILE)
    if op == 'off':
        if os.path.exists(path):
            os.remove(path)
        print('laurel airplay: legacy session off')
        return
    os.makedirs(os.path.join(root, DIR), mode=0o755, exist_ok=True)
    with open(path, 'wb') as f:
        plistlib.dump(PREFS, f, fmt=plistlib.FMT_BINARY)
    os.chmod(path, 0o644)
    if os.geteuid() == 0:
        os.chown(path, 0, 0)
    print('laurel airplay: legacy session on: /' + FILE)


def self_test():
    with tempfile.TemporaryDirectory() as root:
        apply(root, 'on')
        apply(root, 'on')
        with open(os.path.join(root, FILE), 'rb') as f:
            assert plistlib.load(f) == PREFS
        apply(root, 'off')
        assert not os.path.exists(os.path.join(root, FILE))
        apply(root, 'off')
    print('root-airplay-legacy: self-test passed (host only)')


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) == 3 and sys.argv[2] in ('on', 'off'):
        apply(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
