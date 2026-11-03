#!/bin/bash
# Mi A3 iOS 26: the shape of one Home animation on backboardd's render thread: a 500 Hz sample of that thread alone through a page swipe, then
# scripts/laurel/ios26-sample-bins.py at 10 ms. Nothing is flashed or restarted; the phone lock is held for about 10 s.
#   scripts/laurel/ios26-frame-sample.sh [HZ] [SECONDS] [PRI]     default 500 Hz, 6 s, the thread at priority 54 (CoreAnimation's render thread)
# Needs laurel-autotest on the phone (scripts/laurel/ios26-autotest.sh install). Waits up to WAIT_S (3600) for SSH before it takes the lock.
# Result: logs/frame-sample-DATE.samples and .txt. Docs: docs/laurel_sprout/ios26-default-speed.md section 7.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
hz=${1:-500}; secs=${2:-6}; pri=${3:-54}
SSH="sshpass -p ${IOS_PASSWORD:-alpine} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@192.168.7.2"
up() { [ "$(timeout 10 $SSH uname -s 2>/dev/null)" = Darwin ]; }
c=0; until up; do [ "$c" -lt "$((${WAIT_S:-3600} / 10))" ] || { echo "frame-sample: no SSH in ${WAIT_S:-3600} s"; exit 1; }; sleep 10; c=$((c + 1)); done
mkdir -p "$REPO/logs"
stamp=$(date +%Y%m%d-%H%M%S)
out=$REPO/logs/frame-sample-$stamp
one() {
  pid=$($SSH 'ps -ax -o pid=,comm= | grep "/backboardd$"' | awk '{print $1; exit}')
  [ -n "$pid" ] || { echo "frame-sample: no backboardd"; return 1; }
  # the thread index in task order = the row order of ps -M; the render thread runs at priority $pri
  idx=$($SSH "ps -M -p $pid" | awk -v p="$pri" 'NR==1{for(i=1;i<=NF;i++) if($i=="PRI") c=i; next} {n++; if($c==p && !f){print n-1; f=1}}')
  [ -n "$idx" ] || { echo "frame-sample: no thread at priority $pri in backboardd $pid"; $SSH "ps -M -p $pid" | head -12; return 1; }
  echo "frame-sample: backboardd $pid thread $idx at $hz Hz for $secs s, a Home page swipe after 1 s"
  $SSH "/usr/local/bin/laurel-autotest sample $pid $secs $hz only=$idx" > "$out.samples" 2>"$out.err" &
  sp=$!
  sleep 1
  "$REPO/scripts/laurel/ios26-autotest.sh" swipe 620 800 100 800 300 || true
  wait $sp || true
  echo "frame-sample: $(grep -c '^S ' "$out.samples") samples in $out.samples"
}
"$REPO/scripts/laurel/phone-lock.sh" frame-sample bash -c "$(declare -f one up); SSH='$SSH'; REPO='$REPO'; hz=$hz; secs=$secs; pri=$pri; out='$out'; one"
python3 -I "$REPO/scripts/laurel/ios26-sample-bins.py" "$out.samples" --bin 10 > "$out.txt" 2>&1 || true
python3 -I "$REPO/scripts/laurel/ios26-sample-bins.py" "$out.samples" --callers >> "$out.txt" 2>&1 || true
echo "frame-sample: $out.txt"; head -5 "$out.txt"
