#!/bin/sh
# Mi A3 iOS 26, bring-up, on a phone that runs the writable (rw) image and answers SSH: takes the key RecoverOnCrash out of the jetsam file of the root that is on the phone, with no new root.
# Same edit as no_recover_on_crash() of ios26-root-spec.py, which every new root has already. launchd reads the file at its start: it takes effect at the next boot.
#   scripts/laurel/ios26-recover-off.sh         the original goes to logs/, and stays there. To undo: scripts/laurel/phone-ssh.sh push logs/FILE /System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist
# SSH is up about 8 s after launchd, and launchd reboots after 3 fast crashes: run it at once, or use: scripts/laurel/phone-ssh.sh wait 300 && scripts/laurel/ios26-recover-off.sh
# What it does: backboardd, SpringBoard, configd, runningboardd in a crash loop restart and do not reboot the phone. Then use Power + Vol Down, or out/bin/op10tool ctl bootloader. docs/laurel_sprout/ios26-backboardd.md section 4.
set -eu
cd "$(dirname "$0")/../.."
SSHP=scripts/laurel/phone-ssh.sh
P=/System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist
O=logs/jetsam-N104-$(date +%Y%m%d-%H%M%S).plist
N=$O.new
mkdir -p logs
"$SSHP" pull "$P" "$O"
python3 -I - "$O" "$N" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
over = d['Version4']['Daemon']['Override']
gone = [n for n, e in over.items() if isinstance(e, dict) and e.pop('RecoverOnCrash', None) is not None]
if not gone:
    sys.exit('ios26-recover-off: no daemon has RecoverOnCrash: nothing to do')
plistlib.dump(d, open(sys.argv[2], 'wb'), fmt=plistlib.FMT_BINARY)
print('ios26-recover-off: removed from', sorted(gone))
PY
"$SSHP" push "$N" "$P"
rm -f "$N"
echo "ios26-recover-off: on the phone; the next boot has no reboot on these crash loops. Original: $O"
