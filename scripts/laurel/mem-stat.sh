#!/bin/sh
# Mi A3 iOS 26: the memory state of the phone, for the RAM/swap work (docs/laurel_sprout/memory.md). SSH only, short phone-lock holds.
#   scripts/laurel/mem-stat.sh                 one snapshot: VM counters, compressor, swap files, the 12 largest processes, kills in the last 10 min
#   scripts/laurel/mem-stat.sh watch [MIN]     a snapshot a minute for MIN minutes (default 10) -> logs/mem-watch-<time>.txt, then a summary line
#   scripts/laurel/mem-stat.sh launch BUNDLE   app launch time: `laurel-autotest open BUNDLE` to the first LAUREL frame line after it, 3 times (needs the usblog)
# Kills come from logs/usblog.log (CRASH ... reason ns 1 code 7 = jetsam per-process limit, 'low swap' / 'killing largest compressed' = compressor full).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
SSHP=scripts/laurel/phone-ssh.sh
LOG=logs/usblog.log
snap() {   # one snapshot on stdout; the lock is held only for the SSH call
  # the root has Apple's vm_stat, footprint, taskinfo, zprint (/usr/bin) and toybox ps; no sysctl, no uptime [V 2026-11-07]
  sh scripts/laurel/phone-lock.sh mem-stat sh "$SSHP" "echo '# $(date +%H:%M:%S)'; vm_stat 2>&1 | sed 's/^/  /'; echo '# swap files'; ls -la /private/var/vm 2>&1 | sed 's/^/  /'; df -k /private/var 2>&1 | sed 's/^/  /'; echo '# largest processes (RSS KiB)'; ps -A -o pid,rss,vsz,comm 2>/dev/null | sort -k2 -rn | head -12 | sed 's/^/  /'" 2>&1 | sed -n '1,80p'
}
kills() {  # kills in the last N minutes of the usblog, by kind
  n=${1:-10}
  [ -f "$LOG" ] || { echo "kills: no $LOG"; return; }
  since=$(date -d "-$n min" +%H:%M:%S 2>/dev/null || date -v-${n}M +%H:%M:%S)
  awk -v s="$since" '$1 >= s' "$LOG" > "$TMPK"
  j=$(command grep -a -c -E 'CRASH .*reason ns 1 code 0x7' "$TMPK" || true)
  c=$(command grep -a -c -E 'low swap|killing largest compressed' "$TMPK" || true)
  w=$(command grep -a -c 'crossed memory high watermark' "$TMPK" || true)
  echo "kills in the last $n min: jetsam per-process $j, compressor full $c, watermark crossings $w"
  command grep -a -o -E 'process [A-Za-z_.-]+ \[[0-9]+\] crossed memory high watermark \([0-9]+ MB\)' "$TMPK" | sed -E 's/ \[[0-9]+\]//' | sort | uniq -c | sort -rn | head -8 | sed 's/^/  /'
}
TMPK=$(mktemp); trap 'rm -f "$TMPK"' EXIT
case "${1:-}" in
watch)
  min=${2:-10}; out=logs/mem-watch-$(date +%Y%m%d-%H%M%S).txt; mkdir -p logs
  echo "mem-stat: $min snapshots, a minute apart -> $out"
  i=0
  while [ "$i" -lt "$min" ]; do snap >> "$out" 2>&1 || echo "# $(date +%H:%M:%S) no answer" >> "$out"; i=$((i + 1)); [ "$i" -lt "$min" ] && sleep 60; done
  kills "$min" | tee -a "$out"
  echo "# per snapshot (MiB, 16 KiB pages): free / wired / in compressor; compressions, swapouts:"
  awk '/Pages free:/{f=$3} /Pages wired down:/{w=$4} /Pages occupied by compressor:/{c=$5} /^  Compressions:/{k=$2} /^  Swapouts:/{sub(/\./,"",$2); printf "%d/%d/%d c%d s%d  ", f/64, w/64, c/64, k, $2}' "$out"; echo
  ;;
launch)
  b=${2:?bundle id}; [ -f "$LOG" ] || { echo "launch: no $LOG"; exit 1; }
  for i in 1 2 3; do
    n0=$(wc -l < "$LOG"); t0=$(date +%s.%N)
    sh scripts/laurel/phone-lock.sh mem-launch sh "$SSHP" "/usr/local/bin/laurel-autotest open $b" >/dev/null 2>&1 || true
    k=0; while [ "$k" -lt 100 ]; do tail -n +"$((n0 + 1))" "$LOG" | command grep -a -q -E 'LAUREL (FRAME|FB|CPU MOTION)|RedwoodGPU: buffers' && break; sleep 0.1; k=$((k + 1)); done
    t1=$(date +%s.%N); echo "launch $b try $i: $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') s to the first frame line (a 10 s limit)"
    sh scripts/laurel/phone-lock.sh mem-launch sh "$SSHP" "/usr/local/bin/laurel-autotest key home" >/dev/null 2>&1 || true; sleep 5
  done
  ;;
*)
  snap; kills 10
  ;;
esac
