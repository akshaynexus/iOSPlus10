#!/bin/bash
# AWDL for AirDrop on a mounted Mi A3 root (docs/laurel_sprout/airdrop-awdl.md). root-features.sh calls it.
#   scripts/laurel/root-awdl.sh MOUNTED_ROOT
# AWDL=0: nothing is installed. Else /usr/libexec/laurel-awdld + its launchd job com.laurel.awdl. The kernel side is patch 2932 (kill switch awdl=0).
# wifip2pd stays out: it speaks Apple80211 AWDL ioctls to Apple's driver, and the daemon here does its work. Runs as the user too (a test on a copy): no owners then.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/laurel/awdl/root/usr/libexec/laurel-awdld
T=$R/usr/libexec/laurel-awdld
if [ "${AWDL:-1}" = 0 ]; then
  rm -f "$T"
  python3 -I "$REPO/scripts/laurel/root-awdl-job.py" "$R" off
  echo "laurel-root: awdl: skipped (AWDL=0)"
  exit 0
fi
[ -x "$SRC" ] || { echo "laurel-root: awdl: missing $SRC: run scripts/laurel/awdl-build.sh" >&2; exit 1; }
install -m 755 "$SRC" "$T"
[ "$(id -u)" != 0 ] || chown 0:0 "$T"
python3 -I "$REPO/scripts/laurel/root-awdl-job.py" "$R" on
echo "laurel-root: awdl: /usr/libexec/laurel-awdld installed ($(sha256sum "$T" | cut -c1-16)...), job com.laurel.awdl"
