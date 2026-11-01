#!/bin/bash
# AirPlay and AirDrop on a mounted Mi A3 root (docs/laurel_sprout/airplay-airdrop.md). root-features.sh calls it.
#   scripts/laurel/root-airplay.sh MOUNTED_ROOT
# AIRPLAY=0: nothing is installed. Installs /usr/libexec/laurel-airplay + its launchd job (the LAUREL AIRPLAY line) and the managed
# preferences that let sharingd do AirDrop on en0 (scripts/laurel/root-airdrop-lan.py; AIRDROP_LAN=0 skips those alone).
# Runs as the user too (a test on a copy): no owners then.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/laurel/airplay/root/usr/libexec/laurel-airplay
T=$R/usr/libexec/laurel-airplay
if [ "${AIRPLAY:-1}" = 0 ]; then
  rm -f "$T"
  python3 -I "$REPO/scripts/laurel/root-airplay-job.py" "$R" off
  python3 -I "$REPO/scripts/laurel/root-airdrop-lan.py" "$R" off
  echo "laurel-root: airplay: skipped (AIRPLAY=0)"
  exit 0
fi
[ -x "$SRC" ] || { echo "laurel-root: airplay: missing $SRC: run scripts/laurel/airplay-build.sh" >&2; exit 1; }
install -m 755 "$SRC" "$T"
[ "$(id -u)" != 0 ] || chown 0:0 "$T"
python3 -I "$REPO/scripts/laurel/root-airplay-job.py" "$R" on
python3 -I "$REPO/scripts/laurel/root-airdrop-lan.py" "$R" "$([ "${AIRDROP_LAN:-1}" = 0 ] && echo off || echo on)"
echo "laurel-root: airplay: /usr/libexec/laurel-airplay installed ($(sha256sum "$T" | cut -c1-16)...), job com.laurel.airplay"
