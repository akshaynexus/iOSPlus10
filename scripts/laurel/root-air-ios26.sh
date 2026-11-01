#!/bin/bash
# AirDrop (AWDL) and AirPlay on a mounted Mi A3 iOS 26.5.2 23F84 root (docs/laurel_sprout/ios26-airdrop.md). Entry point for the iOS 26 root build. Idempotent: a second run gives the same root.
#   scripts/laurel/root-air-ios26.sh MOUNTED_ROOT
# Installs /usr/libexec/laurel-awdld + job com.laurel.awdl, /usr/libexec/laurel-airplay + job com.laurel.airplay, the managed preferences (the same keys and domains on 23F84 [V disassembly]:
# BrowseAllInterfaces + RegisterAllInterfaces, sessionProtocolOverride=legacy), and takes the job com.apple.wifip2pd out of launchd's cache (it speaks Apple80211 to Apple's driver; laurel-awdld does its work).
# Switches: AWDL=0, AIRPLAY=0, AIRDROP_LAN=0, AIRPLAY_LEGACY=0 as on iOS 16.
# AWDL_FIRST_TRY=alone|shared: the owner's choice at build time: the file /private/var/db/laurel-awdl.allow. No such value: the radio sends nothing to the firmware until the owner writes that file (policy.rs).
# Output: one line per run in ROOT/usr/share/laurel/ios26-air-manifest (and in $MANIFEST when set), the cdhashes in ROOT/usr/share/laurel/ios26-air-cdhashes.
# The two binaries are ours, so they are in no Apple trust cache. Kernel of today: trust caches off, sweet_amfi takes every root binary (ios26-kernel.md section 3). A root build with a trust list
# must add those two hashes; a rebuilt binary has new ones. launchd.plist is edited: launchd 23F84 reads /System/Library/xpc/launchd.plist and has no string of its .sig file [V strings].
# Runs as the user too (a test on a copy): no owners then. Refuses a root that is not iOS 26 and a binary that is not plain arm64.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
L=$REPO/scripts/laurel
CACHE=$R/System/Library/xpc/launchd.plist
[ -f "$CACHE" ] || { echo "laurel-root: air-ios26: no $CACHE" >&2; exit 1; }
python3 -I - "$CACHE" <<'PY' || { echo "laurel-root: air-ios26: this root has no audiomxd job: not iOS 26; nothing changed (iOS 16: root-awdl.sh, root-airplay.sh)" >&2; exit 1; }
import plistlib, sys
sys.exit(0 if '/System/Library/LaunchDaemons/com.apple.audiomxd.plist' in plistlib.load(open(sys.argv[1], 'rb'))['LaunchDaemons'] else 1)
PY
AWDL_BIN=$REPO/out/laurel/awdl/root/usr/libexec/laurel-awdld
AIR_BIN=$REPO/out/laurel/airplay/root/usr/libexec/laurel-airplay
plain() { python3 -I - "$1" <<'PY'
import struct, sys
m, c, s = struct.unpack('<III', open(sys.argv[1], 'rb').read(12))
sys.exit(0 if (m, c, s & 0xff) == (0xfeedfacf, 0x0100000c, 0) else 1)
PY
}
install_bin() {  # SRC NAME
  [ -x "$1" ] || { echo "laurel-root: air-ios26: missing $1: run its build script" >&2; exit 1; }
  plain "$1" || { echo "laurel-root: air-ios26: $1 is not plain arm64: refused" >&2; exit 1; }
  install -m 755 "$1" "$R/usr/libexec/$2"
  [ "$(id -u)" != 0 ] || chown 0:0 "$R/usr/libexec/$2"
}
mkdir -p "$R/usr/libexec" "$R/usr/share/laurel" "$R/System/Library/LaunchDaemons" "$R/private/var/db"
state=
if [ "${AWDL:-1}" = 0 ]; then
  rm -f "$R/usr/libexec/laurel-awdld" "$R/private/var/db/laurel-awdl.allow"
  python3 -I "$L/root-awdl-job.py" "$R" off
  state="awdl off"
else
  install_bin "$AWDL_BIN" laurel-awdld
  python3 -I "$L/root-awdl-job.py" "$R" on
  case "${AWDL_FIRST_TRY:-}" in
  alone|shared) printf '%s\n' "$AWDL_FIRST_TRY" > "$R/private/var/db/laurel-awdl.allow"; state="awdl on, first try allowed: $AWDL_FIRST_TRY" ;;
  "") rm -f "$R/private/var/db/laurel-awdl.allow"; state="awdl on, first try waits for the owner" ;;
  *) echo "laurel-root: air-ios26: AWDL_FIRST_TRY must be alone or shared" >&2; exit 1 ;;
  esac
fi
if [ "${AIRPLAY:-1}" = 0 ]; then
  rm -f "$R/usr/libexec/laurel-airplay"
  python3 -I "$L/root-airplay-job.py" "$R" off
  python3 -I "$L/root-airdrop-lan.py" "$R" off
  python3 -I "$L/root-airplay-legacy.py" "$R" off
  state="$state; airplay off"
else
  install_bin "$AIR_BIN" laurel-airplay
  python3 -I "$L/root-airplay-job.py" "$R" on
  python3 -I "$L/root-airdrop-lan.py" "$R" "$([ "${AIRDROP_LAN:-1}" = 0 ] && echo off || echo on)"
  python3 -I "$L/root-airplay-legacy.py" "$R" "$([ "${AIRPLAY_LEGACY:-1}" = 0 ] && echo off || echo on)"
  state="$state; airplay on"
fi
python3 -I - "$CACHE" <<'PY'
import os, plistlib, sys
p = sys.argv[1]
st = os.stat(p)
d = plistlib.load(open(p, 'rb'))
gone = d['LaunchDaemons'].pop('/System/Library/LaunchDaemons/com.apple.wifip2pd.plist', None)
if gone is not None:
    with open(p, 'wb') as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
    os.chmod(p, st.st_mode & 0o7777)
    if os.geteuid() == 0:
        os.chown(p, st.st_uid, st.st_gid)
PY
rm -f "$R/System/Library/LaunchDaemons/com.apple.wifip2pd.plist"
python3 -I "$L/ios26-air-cdhash.py" "$R" > "$R/usr/share/laurel/ios26-air-cdhashes"
LINE="air-ios26: $state; wifip2pd out; $(wc -l < "$R/usr/share/laurel/ios26-air-cdhashes") cdhashes"
printf '%s\n' "$LINE" > "$R/usr/share/laurel/ios26-air-manifest"
if [ -n "${MANIFEST:-}" ]; then
  touch "$MANIFEST"
  { grep -v '^air-ios26: ' "$MANIFEST" || true; printf '%s\n' "$LINE"; } > "$MANIFEST.new"
  mv -f "$MANIFEST.new" "$MANIFEST"
fi
echo "laurel-root: $LINE"
