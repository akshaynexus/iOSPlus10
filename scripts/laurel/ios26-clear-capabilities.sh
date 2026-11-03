#!/bin/sh
# Mi A3 iOS 26: remove what the phone cached under the old CPU answer (arm64), once, after the first boot of a kernel with post/9011. docs/laurel_sprout/ios26-control-center.md.
#   scripts/laurel/ios26-clear-capabilities.sh     then the phone reboots; the next boot seeds them again and takes some minutes
# It moves them to /var/tmp/laurel-capability-backup, so it can be undone. Writes on the iOS root only: the MobileGestalt cache, the LaunchServices store, the Control Center icon state. Owner's yes first.
set -eu
cd "$(dirname "$0")/../.."
SSHP="sshpass -p ${IOS_PASSWORD:-alpine} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@192.168.7.2"
[ "$($SSHP uname -s)" = Darwin ] || { echo "clear-capabilities: no iOS on SSH"; exit 1; }
$SSHP 'ksysctl kern.laurel_stats 2>/dev/null | grep -q "LAUREL ARCH.*on" || { echo "clear-capabilities: this kernel has no LAUREL ARCH: on"; exit 1; }
B=/var/tmp/laurel-capability-backup; mkdir -p $B
mv -f /var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist $B/ 2>/dev/null || true
for f in /var/mobile/Containers/Data/InternalDaemon/*/Library/Caches/*com.apple.LaunchServices-*.csstore; do [ -e "$f" ] && { echo "moved $f"; mv -f "$f" $B/; }; done
mv -f /var/mobile/Library/ControlCenter/ControlsIconState.plist /var/mobile/Library/ControlCenter/ControlsMigrationSettings.plist $B/ 2>/dev/null || true
ls -la $B | tail -n 6
sync; sync; echo cleared'
out/bin/op10tool ctl reboot | tail -n 1
