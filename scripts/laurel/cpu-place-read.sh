#!/bin/sh
# Mi A3 iOS 26: one CPU reading under the phone lock (short hold, SSH only; nothing written on the phone): the governor's state,
# the busy share of each CPU per second (0-3 gold, 4-7 silver), the CPU and P-core time and the runnable (run-queue wait) time of the
# UI processes over SECONDS, then the last minute lines of the USB log (CPUFREQ, CPU TOP, EMU counts and sites, SCHED PLACE, CPU MOTION).
#   scripts/laurel/cpu-place-read.sh [SECONDS] [NAME]      -> logs/cpu-place-NAME-DATE.txt (default SECONDS 10)
# Run the same scenario on the phone meanwhile (scripts/laurel/ios26-autotest.sh run, or swipes) for a before/after of one change.
# Docs: docs/laurel_sprout/cpu-efficiency.md.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/laurel/phone-ssh.sh
secs=${1:-10}; name=${2:-read}
mkdir -p "$REPO/logs"
out=$REPO/logs/cpu-place-$name-$(date +%Y%m%d-%H%M%S).txt
{
  echo "cpu-place-read $name: $secs s on $(date +%H:%M:%S)"
  "$REPO/scripts/laurel/phone-lock.sh" cpu-place "$SSHP" "ksysctl kern.laurel_stats 2>&1 | grep -i 'cpu\\.'; \
    pids=\$(toybox ps -A -o pid,comm 2>/dev/null | awk '\$2==\"SpringBoard\"||\$2==\"backboardd\"{printf \"%s \", \$1}'); echo \"ui pids: \$pids\"; \
    echo 'cpus: busy % per CPU, one row a second (0-3 gold, 4-7 silver)'; \
    [ -n \"\$pids\" ] && (/usr/local/bin/laurel-autotest cores $secs \$pids > /tmp/cores.txt 2>&1 &); \
    /usr/local/bin/laurel-autotest cpus $secs 2>&1; sleep 1; echo 'cores: SpringBoard, backboardd (ms CPU, ms on P cores, runnable ms)'; cat /tmp/cores.txt 2>/dev/null; rm -f /tmp/cores.txt"
  echo "--- the last minute lines of logs/usblog.log"
  for k in "LAUREL CPUFREQ: on: silver" "LAUREL CPUFREQ: on: gold" "LAUREL CPU TOP" "LAUREL EMU: counts" "LAUREL EMU: sites" "LAUREL SCHED PLACE" "LAUREL CPU MOTION" "LAUREL THERMAL: on: cpu"; do
    grep "$k" "$REPO/logs/usblog.log" 2>/dev/null | tail -1 | cut -c1-400 || true
  done
} | tee "$out"
echo "cpu-place-read: $out"
