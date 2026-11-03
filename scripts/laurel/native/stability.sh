#!/bin/bash
# The native stack over a long run: the fixed scenario N times, each round under the phone lock, with the lock free between them. One line a round: hangs, the table's results, the frames per second. Output: logs/stability-TIME.txt.
#   scripts/bg.sh stability env AUTOTEST_DIR=... scripts/laurel/native/stability.sh [N]
# The last round puts the setting back on default. Stops at a hang: the round's folder has the recorder's files when it was on (FLIGHT=1).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
N=${1:-5}
O=$REPO/logs/stability-$(date +%H%M%S).txt
A=${AUTOTEST_DIR:-$REPO}
for i in $(seq 1 "$N"); do
  keep=--keep; [ "$i" = "$N" ] && keep=
  flight=--no-flight; [ "${FLIGHT:-0}" = 1 ] && flight=; [ "${FLIGHT:-0}" = lite ] && flight=--flight-lite
  touch "$O.start"
  # a stuck CPU 5 comes at 70-80 s after a boot (the kernel watchdog, also on the default stack): no round in that time
  OP=/home/akshay/Documents/GitHub/iOSPlus10/out/bin/op10tool
  for _ in $(seq 1 90); do up=$("$OP" ctl state 2>/dev/null | sed -n '1s/.*up=\([0-9]*\).*/\1/p'); [ "${up:-0}" -ge "${MIN_UP:-120}" ] && break; sleep 5; done
  # a hang leaves the GPU off until a reboot: only then, each boot of slot b counts
  U=$(ls -t /home/akshay/Documents/GitHub/iOSPlus10/logs/usblog-*.txt | head -1); boot=$(grep -an 'exec hangtelemetryd' "$U" | tail -1 | cut -d: -f1); hang=$(grep -an 'watchdog: GPU hang' "$U" | tail -1 | cut -d: -f1); R=; [ "${hang:-0}" -gt "${boot:-0}" ] && R=--reboot
  "$REPO/scripts/laurel/native/compositor-round.sh" $R $keep $flight --test unlock,home-swipe,control-center,settings-scroll 40 > "$O.round" 2>&1
  D=$(ls -dt "$REPO"/logs/round-* | head -1)
  T=$(ls -t "$A"/logs/autotest-*.txt | head -1)
  H=$(grep -ac 'TopazGPU: watchdog: GPU hang' "$D/usblog.txt")
  B=$(grep -ac 'LAUREL WDOG: bark: no pet' "$D/usblog.txt")
  echo "$(date +%H:%M:%S) round $i of $N: $(basename "$D"), GPU hangs $H, CPU watchdog barks $B, table $(basename "$T")" | tee -a "$O"
  [ "$(stat -c %Y "$T")" -ge "$(stat -c %Y "$O.start" 2>/dev/null || echo 0)" ] && grep -E '^\| (unlock|home-swipe|control-center|settings-scroll)' "$T" | cut -c1-135 | tee -a "$O"
  if [ "$B" != 0 ]; then grep -a -m1 'LAUREL WDOG: bark: no pet' "$D/usblog.txt" | cut -c1-170 | tee -a "$O"; echo "a CPU watchdog bark: not this stack's GPU hang" | tee -a "$O"; fi
  if [ "${H:-0}" != 0 ]; then grep -a -m2 -E 'watchdog: GPU hang|SMMU gfsr' "$D/usblog.txt" | cut -c1-170 | tee -a "$O"; echo "stopped at a hang" | tee -a "$O"; exit 1; fi
done
echo "no hang in $N rounds" | tee -a "$O"
