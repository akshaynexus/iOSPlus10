#!/bin/bash
# Mi A3 iOS 26: one bench of the default stack as a good neighbour on the shared phone. Docs: docs/laurel_sprout/ios26-default-speed.md.
#   scripts/bg.sh bench-NAME scripts/laurel/ios26-bench-round.sh NAME [KEY=VALUE ...] [-- autotest args]
# Waits for SSH and SETTLE_UP_S (default 120) of uptime with NO lock (up to WAIT_S, default 3600), then takes the lock for one try of ios26-default-bench.sh.
# Exit 7 or 8 of the bench (the phone went away, was too young, or the bench rebooted it): the lock is free, a new round starts. At most ROUNDS (default 3). Env for the bench passes through.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
OP=$REPO/out/bin/op10tool; [ -x "$OP" ] || OP=$MAIN/out/bin/op10tool
LOCK=$MAIN/scripts/laurel/phone-lock.sh
name=${1:?usage: $0 NAME [KEY=VALUE ...] [-- autotest args]}
ready() {
  local waited=0 up
  while :; do
    up=$(timeout 6 "$OP" ctl state 2>/dev/null | sed -n '1s/.*up=\([0-9]*\).*/\1/p')
    if [ "${up:-0}" -ge "${SETTLE_UP_S:-120}" ] && "$REPO/scripts/net/ssh-phone.sh" true >/dev/null 2>&1; then return 0; fi
    [ "$waited" -lt "${WAIT_S:-3600}" ] || { echo "$(date +%H:%M:%S) round $name: no ready phone in ${WAIT_S:-3600} s: last uptime ${up:-none}"; return 1; }
    sleep 15; waited=$((waited + 15))
  done
}
round=0
while [ "$round" -lt "${ROUNDS:-3}" ]; do
  round=$((round + 1))
  ready || exit 9
  echo "$(date +%H:%M:%S) round $name: try $round of ${ROUNDS:-3}"
  "$LOCK" m2v "$REPO/scripts/laurel/ios26-default-bench.sh" "$@" </dev/null
  rc=$?
  case "$rc" in
  7|8) sleep 30 ;;
  *) exit "$rc" ;;
  esac
done
echo "$(date +%H:%M:%S) round $name: no result in ${ROUNDS:-3} rounds"
exit 7
