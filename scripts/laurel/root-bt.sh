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
#  3. /usr/local/libexec/laurel-bluetoothd + /usr/local/lib/liblaurel-btpty.dylib (scripts/laurel/btpty-build.sh): the job's start program
#     execs /usr/sbin/bluetoothd with openpty's central end non-blocking (an accessory's iAP PTY cannot stop the stack; Scion 2e0c90a).
#     Not built = bluetoothd as Apple's (the job keeps /usr/sbin/bluetoothd), one line. Boot-arg laurel_btpty=0 is the kill switch.
PT=$REPO/out/laurel/bt/root
if [ ! -s "$PT/usr/local/libexec/laurel-bluetoothd" ] || [ ! -s "$PT/usr/local/lib/liblaurel-btpty.dylib" ]; then
  if [ -n "${SUDO_USER:-}" ]; then pb() { sudo -u "$SUDO_USER" "$REPO/scripts/laurel/btpty-build.sh"; }; else pb() { "$REPO/scripts/laurel/btpty-build.sh"; }; fi
  pb >/dev/null 2>&1 || echo "$(ts) root-bt: WARNING: laurel-bluetoothd not built (scripts/laurel/btpty-build.sh): bluetoothd runs as Apple's, iAP PTY can block it" >&2
fi
if [ -s "$PT/usr/local/libexec/laurel-bluetoothd" ] && [ -s "$PT/usr/local/lib/liblaurel-btpty.dylib" ]; then
  mkdir -p "$R/usr/local/libexec" "$R/usr/local/lib"
  install -m 755 "$PT/usr/local/libexec/laurel-bluetoothd" "$R/usr/local/libexec/laurel-bluetoothd"
  install -m 644 "$PT/usr/local/lib/liblaurel-btpty.dylib" "$R/usr/local/lib/liblaurel-btpty.dylib"
  [ "$(id -u)" != 0 ] || chown 0:0 "$R/usr/local/libexec/laurel-bluetoothd" "$R/usr/local/lib/liblaurel-btpty.dylib"
  WRAP=/usr/local/libexec/laurel-bluetoothd
else
  WRAP=
fi
BTD_WRAP=$WRAP python3 -I "$REPO/scripts/bt/bt-launchd.py" "$R/System/Library/xpc/launchd.plist" on \
  "$R/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
echo "$(ts) root-bt: done (bluetoothd job${WRAP:+ through $WRAP + liblaurel-btpty.dylib} + BlueTool stand-in; kernel 2600 + ADT /arm-io/bluetooth from mkadt.py)"
