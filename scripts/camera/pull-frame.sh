#!/bin/sh
# Copy the camera frames of patch 0315 (negronicam=5) from iOS on the phone and convert them to PNG.
#   scripts/camera/pull-frame.sh [tpg|sensor|both]     (default both)
# Reads /dev/negronicam-tpg and /dev/negronicam-sensor over SSH (scripts/net/ssh-phone.sh, USB network),
# writes out/camera/frames/<name>-<UTC time>.raw (64-byte NCAMRAW1 header + MIPI RAW10) and the PNG from
# scripts/camera/raw-to-png.py. The device node exists only when the kernel captured that frame.
# Read only on the phone (dd from a character device into /var/tmp, then deleted). macOS and Linux.
set -eu
. "$(dirname "$0")/../lib/env.sh"
WHICH=${1:-both}
D=$OUT/camera/frames
mkdir -p "$D"
T=$(date -u +%Y%m%d-%H%M%S)
case $WHICH in both) set -- tpg sensor ;; tpg|sensor) set -- "$WHICH" ;; *) sed -n 2,7p "$0"; exit 1 ;; esac
for n in "$@"; do
  r=/var/tmp/negronicam-$n.raw
  if ! "$REPO/scripts/net/ssh-phone.sh" "test -c /dev/negronicam-$n && dd if=/dev/negronicam-$n of=$r bs=1048576 2>/dev/null && ls -l $r"; then
    echo "no /dev/negronicam-$n on the phone (no $n frame in this boot: see the NEGRONI CAM lines)" >&2
    continue
  fi
  "$REPO/scripts/net/ssh-phone.sh" pull "$r" "$D/$n-$T.raw"
  "$REPO/scripts/net/ssh-phone.sh" "rm -f $r" || true
  python3 -I "$REPO/scripts/camera/raw-to-png.py" "$D/$n-$T.raw" "$D/$n-$T.png"
  shasum -a 256 "$D/$n-$T.raw"
done
