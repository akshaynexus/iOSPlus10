#!/bin/sh
# The fingerprint lock-screen glyph daemon on a mounted, writable iOS 16 root (patch 0354,
# patches/xnu/README-fingerprint.md "0354"). Off unless FPD=1. Run as root (macOS or Linux);
# scripts/ios16/root-finish.sh calls it after the Bluetooth hook:
#   FPD=1 scripts/fp/root-add-fpd.sh MOUNTED_ROOT
# Needs out/fp/userland/negroni-fpd from userland/fp/build.sh (macOS). Steps (idempotent):
#  1. /usr/libexec/negroni-fpd (root, ad hoc signed)
#  2. launchd job com.iosplus10.negroni-fpd: plist file + entry in /System/Library/xpc/launchd.plist
#     (the only path launchd reads on these ports; scripts/net/root-add-ssh.py does the same)
# Kernel side: negronifp_hl=1|2 allows the overlay; without 0354 the daemon logs a failed sysctl and
# keeps running (KeepAlive). Log on the phone: /private/var/log/iosplus10-negroni-fpd.log.
set -eu
R=${1:?usage: FPD=1 $0 MOUNTED_ROOT}
if [ "${FPD:-0}" != 1 ]; then echo "fpd: skipped (FPD=1 adds the fingerprint glyph daemon negroni-fpd)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
B=$REPO/out/fp/userland/negroni-fpd
[ -f "$R/System/Library/xpc/launchd.plist" ] || { echo "$R is not an iOS root" >&2; exit 1; }
[ -f "$B" ] || { echo "missing $B: run userland/fp/build.sh (macOS)" >&2; exit 1; }
mkdir -p "$R/usr/libexec" "$R/private/var/log"
install -m 755 "$B" "$R/usr/libexec/negroni-fpd"
chown 0:0 "$R/usr/libexec/negroni-fpd"
python3 -I - "$R" <<'PY'
import os, plistlib, sys
root = sys.argv[1]
label = 'com.iosplus10.negroni-fpd'
job = {'Label': label, 'ProgramArguments': ['/usr/libexec/negroni-fpd'], 'RunAtLoad': True, 'KeepAlive': True,
       'ThrottleInterval': 10, 'UserName': 'root',
       'StandardOutPath': '/private/var/log/iosplus10-negroni-fpd.log',
       'StandardErrorPath': '/private/var/log/iosplus10-negroni-fpd.log'}
rel = f'System/Library/LaunchDaemons/{label}.plist'
os.makedirs(os.path.join(root, 'System/Library/LaunchDaemons'), exist_ok=True)
with open(os.path.join(root, rel), 'wb') as f:
    plistlib.dump(job, f, fmt=plistlib.FMT_XML)
lp = os.path.join(root, 'System/Library/xpc/launchd.plist')
st = os.stat(lp)
with open(lp, 'rb') as f:
    data = plistlib.load(f)
data.setdefault('LaunchDaemons', {})['/' + rel] = job
with open(lp + '.new', 'wb') as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
try:
    os.chown(lp + '.new', st.st_uid, st.st_gid)
except PermissionError:
    pass
os.chmod(lp + '.new', st.st_mode & 0o7777)
os.replace(lp + '.new', lp)
print(f'fpd: launchd job {label} (/usr/libexec/negroni-fpd)')
PY
echo "fpd: done; kernel: negronifp_hl=1|2 (patch 0354), log /private/var/log/iosplus10-negroni-fpd.log"
