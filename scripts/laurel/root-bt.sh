#!/bin/bash
# Bluetooth userland in the Mi A3 iOS 16 root (kernel side: patches/laurel/xnu/2600, docs/laurel_sprout/bluetooth.md).
#   sudo scripts/laurel/root-bt.sh MOUNTED_ROOT          (root.sh step 2 calls this; BT=0 skips)
# macOS and Linux. Needs out/laurel/bt/negroni-bluetool (userland/laurel/bt/build.sh; built here if missing). A stand-in
# that cannot be built (no theos toolchain / SDK): exit 1; root.sh's table says `bluetooth missing`.
# Steps (idempotent):
#  1. /usr/libexec/negroni-bluetool (root:wheel 755): the com.apple.BlueTool stand-in (the kernel boots the chip)
#  2. launchd cache (scripts/bt/bt-launchd.py on): the bluetoothd job back (root-tweaks-extra.py drops it) from
#     LaunchDaemons/com.apple.bluetoothd.plist with BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000;
#     the BlueTool job runs the stand-in.
# With Bluetooth off in the kernel (laurelbt=0, or its self-check failed), the kernel hides the ADT "bluetooth" nub
# and removes /dev/uart.bluetooth: bluetoothd logs "No bluetooth on this device" and exits 0 once (no restart).
# Undo: scripts/bt/bt-launchd.py ROOT/System/Library/xpc/launchd.plist off; delete the stand-in.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
B=$REPO/out/laurel/bt/negroni-bluetool
ts() { date +%H:%M:%S; }
if [ "${BT:-1}" = 0 ]; then echo "$(ts) root-bt: skipped (BT=0)"; exit 0; fi
[ -d "$R/System/Library/xpc" ] || { echo "root-bt: $R is not an iOS root" >&2; exit 1; }
if [ ! -s "$B" ]; then
  if [ -n "${SUDO_USER:-}" ]; then b() { sudo -u "$SUDO_USER" "$REPO/userland/laurel/bt/build.sh"; }; else b() { "$REPO/userland/laurel/bt/build.sh"; }; fi
  if ! b; then
    echo "$(ts) root-bt: FAILED: BlueTool stand-in not built; no Bluetooth userland" >&2
    exit 1
  fi
fi
mkdir -p "$R/usr/libexec"
install -m 755 "$B" "$R/usr/libexec/negroni-bluetool"
[ "$(id -u)" != 0 ] || chown 0:0 "$R/usr/libexec/negroni-bluetool"
python3 -I "$REPO/scripts/bt/bt-launchd.py" "$R/System/Library/xpc/launchd.plist" on \
  "$R/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
echo "$(ts) root-bt: done (bluetoothd job + BlueTool stand-in; kernel 2600 + ADT /arm-io/bluetooth from mkadt.py)"
