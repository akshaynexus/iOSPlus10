#!/bin/sh
# Bluetooth userland on a mounted, writable iOS 16 root (docs/bluetooth-plan.md section 4). Off unless BT=1.
# Run as root (macOS or Linux); scripts/ios16/root-finish.sh calls it after root-tweaks-extra.py:
#   BT=1 scripts/bt/root-add-bt.sh MOUNTED_ROOT
# Needs out/bt/userland from userland/bluetooth/build.sh (macOS). Steps (idempotent):
#  1. /usr/libexec/negroni-bluetool (BlueTool stand-in) and /usr/local/bin/hcitest (H4 test client)
#  2. launchd cache: bluetoothd job added (the cache has none) from LaunchDaemons/com.apple.bluetoothd.plist with BT_HCI_TRANSPORT, BlueTool job -> the stand-in (scripts/bt/bt-launchd.py)
# The stock /usr/sbin/BlueTool stays (manual tests: BT_UART=com.apple.uart.bluetooth BlueTool -c ...).
# The kernel side is negronibt=4 + the ADT node /arm-io/bluetooth (ADT_BT=1 scripts/ios16/adt-extra.py); without
# them bluetoothd exits 0 once at boot. BTAudioHALPlugin: with bluetoothd present it may stay enabled
# (BTAUDIO=1 for scripts/audio/root-add-audio.sh); default audio roots move it to HAL.disabled.
set -eu
R=${1:?usage: BT=1 $0 MOUNTED_ROOT}
if [ "${BT:-0}" != 1 ]; then echo "bluetooth: skipped (BT=1 adds bluetoothd + the BlueTool stand-in)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
U=$REPO/out/bt/userland
[ -d "$R/System/Library/xpc" ] || { echo "$R is not an iOS root" >&2; exit 1; }
for b in negroni-bluetool hcitest; do
  [ -f "$U/$b" ] || { echo "missing $U/$b: run userland/bluetooth/build.sh (macOS)" >&2; exit 1; }
done
mkdir -p "$R/usr/libexec" "$R/usr/local/bin"
install -m 755 "$U/negroni-bluetool" "$R/usr/libexec/negroni-bluetool"
install -m 755 "$U/hcitest" "$R/usr/local/bin/hcitest"
chown 0:0 "$R/usr/libexec/negroni-bluetool" "$R/usr/local/bin/hcitest"
python3 "$REPO/scripts/bt/bt-launchd.py" "$R/System/Library/xpc/launchd.plist" on \
  "$R/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
echo "bluetooth: done; kernel: negronibt=4 + ADT_BT=1 (README-bluetooth.md section 0332)"
