#!/bin/bash
# The native stack over a long run: the fixed scenario N times, each round under the phone lock, with the lock free between them. One line a round: hangs, the table's results, the frames per second. Output: logs/stability-TIME.txt.
#   scripts/bg.sh stability env AUTOTEST_DIR=... scripts/laurel/native/stability.sh [N]
# The last round puts the setting back on default. Stops at a hang: the round's folder has the recorder's files when it was on (FLIGHT=1).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
N=${1:-5}
O=$REPO/logs/stability-$(date +%H%M%S).txt
A=${AUTOTEST_DIR:-$REPO}
[ -x "$A/scripts/laurel/ios26-autotest.sh" ] || { echo "stability: no UI test tool in $A"; exit 2; }
for i in $(seq 1 "$N"); do
  keep=--keep; [ "$i" = "$N" ] && keep=
  flight=--no-flight; [ "${FLIGHT:-0}" = 1 ] && flight=; [ "${FLIGHT:-0}" = lite ] && flight=--flight-lite
  touch "$O.start"
  # A hang leaves the GPU off until a reboot: only then (each boot of slot b counts), with the lock only for the command.
  OP=/home/akshay/Documents/GitHub/iOSPlus10/out/bin/op10tool
  U=$(ls -t /home/akshay/Documents/GitHub/iOSPlus10/logs/usblog-*.txt | head -1); boot=$(grep -an 'exec hangtelemetryd' "$U" | tail -1 | cut -d: -f1); hang=$(grep -an 'watchdog: GPU hang' "$U" | tail -1 | cut -d: -f1)
  if [ "${hang:-0}" -gt "${boot:-0}" ]; then /home/akshay/Documents/GitHub/iOSPlus10/scripts/laurel/phone-lock.sh native "$OP" ctl reboot 2>&1 | tail -1; sleep 30; fi
  # No lock in this wait: at most 15 min for SSH, then 120 s of uptime (a stuck CPU comes at 70-80 s after a boot). No attempt to bring iOS back: another job may be flashing.
  for _ in $(seq 1 90); do
    up=$("$OP" ctl state 2>/dev/null | sed -n '1s/.*up=\([0-9]*\).*/\1/p')
    [ "${up:-0}" -ge "${MIN_UP:-120}" ] && [ "$(sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 root@192.168.7.2 uname -s 2>/dev/null)" = Darwin ] && break
    sleep 10
  done
  [ "${up:-0}" -ge "${MIN_UP:-120}" ] || { echo "$(date +%H:%M:%S) no iOS in 15 min: stopped; the lock is free" | tee -a "$O"; exit 3; }
  "$REPO/scripts/laurel/native/compositor-round.sh" $keep $flight --test unlock,home-swipe,control-center,settings-scroll 40 > "$O.round" 2>&1
  D=$(ls -dt "$REPO"/logs/round-* | head -1)
  T=$(ls -t "$A"/logs/autotest-*.txt | head -1)
  H=$(grep -ac 'TopazGPU: watchdog: GPU hang' "$D/usblog.txt")
  B=$(grep -ac 'LAUREL WDOG: bark: no pet' "$D/usblog.txt")
  echo "$(date +%H:%M:%S) round $i of $N: $(basename "$D"), GPU hangs $H, CPU watchdog barks $B, table $(basename "$T")" | tee -a "$O"
  [ -n "$T" ] || { echo "$(date +%H:%M:%S) round $i: the UI test wrote no table: stopped" | tee -a "$O"; exit 4; }
  [ "$(stat -c %Y "$T")" -ge "$(stat -c %Y "$O.start" 2>/dev/null || echo 0)" ] && grep -E '^\| (unlock|home-swipe|control-center|settings-scroll)' "$T" | cut -c1-135 | tee -a "$O"
  if [ "$B" != 0 ]; then grep -a -m1 'LAUREL WDOG: bark: no pet' "$D/usblog.txt" | cut -c1-170 | tee -a "$O"; echo "a CPU watchdog bark: not this stack's GPU hang" | tee -a "$O"; fi
  if [ "${H:-0}" != 0 ]; then grep -a -m2 -E 'watchdog: GPU hang|SMMU gfsr' "$D/usblog.txt" | cut -c1-170 | tee -a "$O"; echo "stopped at a hang" | tee -a "$O"; exit 1; fi
done
echo "no hang in $N rounds" | tee -a "$O"
