#!/bin/sh
# Mi A3: flash this tree's iOS 26 image when the phone is free, with no hand on the keyboard.
#   scripts/bg.sh NAME scripts/laurel/ios26-flash-when-free.sh [ro|rw]      (always in tmux)
#   AFTER=session   wait first until that tmux session is gone (another agent's flash job goes first; its own run is not disturbed)
#   WAIT_S=7200     how long to wait for fastboot (the owner holds Power + Vol Down on a hung phone)
#   EXTRA_ARGS=...  boot-args of the image (ios26-fast-flash.sh)
# Then: scripts/laurel/phone-lock.sh flash ios26-fast-flash.sh (builds the image, writes boot_b, reboots). The lock is held only during the flash.
set -eu
cd "$(dirname "$0")/../.."
say() { echo "$(date +%H:%M:%S) flash-when-free: $*"; }
if [ -n "${AFTER:-}" ]; then
  say "waiting for tmux session $AFTER to end"
  while tmux has-session -t "$AFTER" 2>/dev/null; do sleep 5; done
  say "$AFTER ended"
fi
n=0; W=${WAIT_S:-7200}
until timeout 3 fastboot devices 2>/dev/null | grep -q fastboot; do
  [ "$n" -lt "$W" ] || { say "STOP: no fastboot in $W s"; exit 1; }
  sleep 3; n=$((n + 3))
done
say "fastboot seen"
sleep 2
exec sh scripts/laurel/phone-lock.sh flash sh -c "EXTRA_ARGS='${EXTRA_ARGS:-ufsqueue=0}' sh scripts/laurel/ios26-fast-flash.sh ${1:-rw}"
