#!/bin/sh
# One time, from the computer, with the owner's yes: put the Android app on the phone. Writes no partition: one app, one persist property in /data.
#   CONFIRM=switcher scripts/laurel/switcher-setup.sh
# Effect [docs/laurel_sprout/boot-menu.md]: adbd also listens on TCP 5555 of all interfaces (persist.adb.tcp.port) with its normal key check, so the app can reach it on 127.0.0.1.
# The first tap shows Android's "Allow debugging" dialog: choose "Always allow".
# Undo: adb root; adb shell setprop persist.adb.tcp.port ''; adb shell setprop ctl.restart adbd; adb uninstall org.iosplus10.laurelswitcher
set -eu
. "$(dirname "$0")/../lib/env.sh"
APK=$OUT/laurel/switcher/laurel-switcher.apk
[ "${CONFIRM:-}" = switcher ] || { echo "switcher-setup: installs an app and opens TCP 5555 for adbd: CONFIRM=switcher when the owner agreed" >&2; exit 1; }
[ -f "$APK" ] || { echo "switcher-setup: no $APK: scripts/laurel/switcher-build.sh" >&2; exit 1; }
dev=$(adb shell getprop ro.product.device | tr -d '\r')
[ "$dev" = laurel_sprout ] || { echo "switcher-setup: phone says '$dev', not laurel_sprout: stop" >&2; exit 1; }
adb install -r "$APK"
adb root
adb wait-for-device
[ "$(adb shell id -u | tr -d '\r')" = 0 ] || { echo "switcher-setup: no adb root: Developer options -> Rooted debugging" >&2; exit 1; }
adb shell setprop persist.adb.tcp.port 5555
adb shell setprop ctl.restart adbd
sleep 3
adb wait-for-device
echo "persist.adb.tcp.port=$(adb shell getprop persist.adb.tcp.port | tr -d '\r')"
echo "switcher-setup: done. On the phone: open 'Boot iOS' once, allow the key (Always allow), add the tile from the Quick Settings editor."
