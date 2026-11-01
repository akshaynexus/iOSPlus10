#!/bin/sh
# One time, from the computer, with the owner's yes: put the Android app on the phone. Writes no partition: one app, one persist property in /data.
#   CONFIRM=switcher scripts/laurel/switcher-setup.sh
# Effect [docs/laurel_sprout/boot-menu.md section 6.2]: adbd listens on TCP at the random high port of this build (out/laurel/switcher/port). At each boot, until the app's receiver has moved it to
# loopback, it listens on all interfaces. The first tap shows Android's "Allow debugging" dialog: choose "Always allow" only for this dialog, right after a tap of your own.
# Undo: adb root; adb shell setprop persist.adb.tcp.port ''; adb shell setprop service.adb.listen_addrs ''; adb shell setprop ctl.restart adbd; adb uninstall org.iosplus10.laurelswitcher
set -eu
. "$(dirname "$0")/../lib/env.sh"
APK=$OUT/laurel/switcher/laurel-switcher.apk
PF=$OUT/laurel/switcher/port
[ "${CONFIRM:-}" = switcher ] || { echo "switcher-setup: installs an app and opens a TCP port for adbd: CONFIRM=switcher when the owner agreed" >&2; exit 1; }
[ -f "$APK" ] && [ -s "$PF" ] || { echo "switcher-setup: no $APK or $PF: scripts/laurel/switcher-build.sh" >&2; exit 1; }
P=$(cat "$PF")
dev=$(adb shell getprop ro.product.device | tr -d '\r')
[ "$dev" = laurel_sprout ] || { echo "switcher-setup: phone says '$dev', not laurel_sprout: stop" >&2; exit 1; }
adb install -r "$APK"
adb root
adb wait-for-device
[ "$(adb shell id -u | tr -d '\r')" = 0 ] || { echo "switcher-setup: no adb root: Developer options -> Rooted debugging" >&2; exit 1; }
adb shell setprop persist.adb.tcp.port "$P"
# loopback at once for this boot; the receiver does the same at each later boot
adb shell setprop service.adb.listen_addrs "tcp:localhost:$P"
adb shell setprop ctl.restart adbd
sleep 3
adb wait-for-device
echo "persist.adb.tcp.port=$(adb shell getprop persist.adb.tcp.port | tr -d '\r'), service.adb.listen_addrs=$(adb shell getprop service.adb.listen_addrs | tr -d '\r')"
adb unroot || true
echo "switcher-setup: done. On the phone: open 'Boot iOS' once, tap Check, allow the key, add the tile from the Quick Settings editor."
