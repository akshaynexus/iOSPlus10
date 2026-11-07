#!/bin/sh
# Mi A3: make sure iOS 26 runs, for agents in a test loop (standing order in CLAUDE.md). Slot b has 7 boots and refills only after a key press (docs/laurel_sprout/boot-menu.md),
# so a loop of unattended reboots ends in Android, on purpose. This brings the phone back, under the phone lock, through the guarded path of ios26-retry.sh (Android must open its data).
#   scripts/laurel/phone-ensure-ios.sh       exit 0: iOS answers on SSH
# It only acts when iOS does not answer. It writes boot_b, dtbo_b and the active slot, nothing else. It never touches an adb device other than the Mi A3.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
cd "$MAIN"
up() { [ "$(timeout 10 sshpass -p "${IOS_PASSWORD:-alpine}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 root@192.168.7.2 uname -s 2>/dev/null)" = Darwin ]; }
if up; then echo "ensure-ios: iOS is up"; exit 0; fi
# A boot that is still going: USB control answers. Wait for it first.
c=0
while timeout 4 out/bin/op10tool ctl ping 2>/dev/null | grep -q pong && [ "$c" -lt 24 ]; do
  sleep 5; up && { echo "ensure-ios: iOS is up"; exit 0; }; c=$((c + 1))
done
echo "ensure-ios: no iOS: back through ios26-retry.sh"
sh scripts/laurel/phone-lock.sh ensure-ios sh -c 'EXTRA_ARGS=${EXTRA_ARGS:-ufsqueue=0} sh scripts/laurel/ios26-retry.sh rw'
c=0
until up; do [ "$c" -lt 40 ] || { echo "ensure-ios: no SSH 200 s after the switch"; exit 1; }; sleep 5; c=$((c + 1)); done
echo "ensure-ios: iOS is up"
