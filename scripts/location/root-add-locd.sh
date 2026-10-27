#!/bin/sh
# negroni-locd on a mounted, writable iOS 16 root (docs/location-plan.md, paths L1 and L3). On by default.
# Run as root (macOS or Linux); scripts/ios16/root-finish.sh calls it (LOCD default 1 when
# out/location/userland/negroni-locd is built), and scripts/ios16/root-update.sh has the hook "location":
#   [LOCD=0] [LOCD_JOB=0] scripts/location/root-add-locd.sh MOUNTED_ROOT
# Needs out/location/userland/ from userland/location/build.sh (macOS). Steps (idempotent):
#  1. /usr/local/bin/negroni-locd (root, ad hoc signed with com.apple.locationd.simulation)
#  2. /usr/local/share/negroni-locd/com.iosplus10.negroni-locd.plist (a copy only; launchd does not read it)
#  3. launchd job com.iosplus10.negroni-locd (`negroni-locd gnss`, as root: fixes from the kernel GNSS,
#     /dev/negroni_gnss of patch 0397) in /System/Library/xpc/launchd.plist (the only path launchd reads on these
#     ports; scripts/fp/root-add-fpd.sh does the same). Without 0397 (or with negronignss=0) the daemon logs one
#     line "negroni-locd: gnss: off: <reason>" and checks again every 60 s; nothing else runs.
# Kill switches: LOCD=0 (nothing installed), LOCD_JOB=0 (binary only, no job at boot). The UDP listener for the
# Mac (`listen`) stays a manual mode: scripts/location/phone-location.sh listen (it ends the gnss job first).
# The Location Services switch itself is a separate root tweak: scripts/ios16/root-tweaks-extra.py item 7
# (default on; LOCATION_SWITCH=0 leaves it off).
set -eu
R=${1:?usage: [LOCD=0] [LOCD_JOB=0] $0 MOUNTED_ROOT}
if [ "${LOCD:-1}" = 0 ]; then echo "locd: off: LOCD=0 (negroni-locd not installed)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$REPO/out/location/userland
[ -f "$R/System/Library/xpc/launchd.plist" ] || { echo "$R is not an iOS root" >&2; exit 1; }
[ -f "$W/negroni-locd" ] || { echo "missing $W/negroni-locd: run userland/location/build.sh (macOS)" >&2; exit 1; }
mkdir -p "$R/usr/local/bin" "$R/usr/local/share/negroni-locd" "$R/private/var/log"
install -m 755 "$W/negroni-locd" "$R/usr/local/bin/negroni-locd"
install -m 644 "$W/com.iosplus10.negroni-locd.plist" "$R/usr/local/share/negroni-locd/com.iosplus10.negroni-locd.plist"
chown 0:0 "$R/usr/local/bin/negroni-locd" "$R/usr/local/share/negroni-locd/com.iosplus10.negroni-locd.plist"
echo "locd: /usr/local/bin/negroni-locd installed"
if [ "${LOCD_JOB:-1}" = 0 ]; then echo "locd: off: LOCD_JOB=0 (no launchd job; the binary is installed)"; exit 0; fi
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
