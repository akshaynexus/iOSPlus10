#!/bin/sh
# negroni-locd on a mounted, writable iOS 16 root (docs/location-plan.md, path L1). Off unless LOCD=1.
# Run as root (macOS or Linux); scripts/ios16/root-finish.sh calls it (LOCD default 0), and
# scripts/ios16/root-update.sh has the hook "location":
#   LOCD=1 [LOCD_JOB=1] scripts/location/root-add-locd.sh MOUNTED_ROOT
# Needs out/location/userland/ from userland/location/build.sh (macOS). Steps (idempotent):
#  1. /usr/local/bin/negroni-locd (root, ad hoc signed with com.apple.locationd.simulation)
#  2. /usr/local/share/negroni-locd/com.iosplus10.negroni-locd.plist (a copy only; launchd does not read it)
#  3. only with LOCD_JOB=1: launchd job com.iosplus10.negroni-locd (listen on UDP 192.168.7.2:5155 for the
#     Mac's "LAT LON ACC" lines) in /System/Library/xpc/launchd.plist (the only path launchd reads on these
#     ports; scripts/fp/root-add-fpd.sh does the same). Default: no job, so nothing runs at boot.
# The Location Services switch itself is a separate, optional root tweak: LOCATION_SWITCH=1 for
# scripts/ios16/root-tweaks-extra.py.
set -eu
R=${1:?usage: LOCD=1 [LOCD_JOB=1] $0 MOUNTED_ROOT}
if [ "${LOCD:-0}" != 1 ]; then echo "locd: skipped (LOCD=1 adds negroni-locd, docs/location-plan.md)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$REPO/out/location/userland
[ -f "$R/System/Library/xpc/launchd.plist" ] || { echo "$R is not an iOS root" >&2; exit 1; }
[ -f "$W/negroni-locd" ] || { echo "missing $W/negroni-locd: run userland/location/build.sh (macOS)" >&2; exit 1; }
mkdir -p "$R/usr/local/bin" "$R/usr/local/share/negroni-locd" "$R/private/var/log"
install -m 755 "$W/negroni-locd" "$R/usr/local/bin/negroni-locd"
install -m 644 "$W/com.iosplus10.negroni-locd.plist" "$R/usr/local/share/negroni-locd/com.iosplus10.negroni-locd.plist"
chown 0:0 "$R/usr/local/bin/negroni-locd" "$R/usr/local/share/negroni-locd/com.iosplus10.negroni-locd.plist"
echo "locd: /usr/local/bin/negroni-locd installed"
if [ "${LOCD_JOB:-0}" != 1 ]; then echo "locd: no launchd job (LOCD_JOB=1 adds com.iosplus10.negroni-locd)"; exit 0; fi
python3 -I - "$R" "$W/com.iosplus10.negroni-locd.plist" <<'PY'
import os, plistlib, sys
root, src = sys.argv[1], sys.argv[2]
job = plistlib.load(open(src, 'rb'))
label = job['Label']
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
print(f'locd: launchd job {label} ({" ".join(job["ProgramArguments"])})')
PY
