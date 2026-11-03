#!/bin/sh
# Mi A3 iOS 26: measure what the CPU, the memory and the kernel give to one process (userland/laurel/speed). Nothing is flashed; nothing is restarted.
#   scripts/laurel/ios26-speed.sh [all|clock|chase|copy|sys|wake|timer|fault|time] [THREADS]     builds, copies to /usr/local/bin, runs; result in logs/speed-DATE.txt
#   scripts/laurel/ios26-speed.sh --run-only [...]                                            no build, no copy
# Takes the phone lock for the run only (about 20 s of CPU). Needs SSH to the phone. Docs: docs/laurel_sprout/ios26-default-speed.md.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
SSH="sshpass -p ${IOS_PASSWORD:-alpine} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 root@192.168.7.2"
SCP="sshpass -p ${IOS_PASSWORD:-alpine} scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
build=1
if [ "${1:-}" = --run-only ]; then build=0; shift; fi
what=${1:-all}; threads=${2:-8}
mkdir -p "$REPO/logs"
out=$REPO/logs/speed-$(date +%Y%m%d-%H%M%S).txt
if [ $build = 1 ]; then
  "$REPO/userland/laurel/speed/build.sh"
  $SCP "$OUT/laurel/speed/laurel-speed" root@192.168.7.2:/usr/local/bin/laurel-speed
  $SSH chmod 755 /usr/local/bin/laurel-speed
fi
"$REPO/scripts/laurel/phone-lock.sh" speed sh -c "echo \"laurel-speed $what $threads on \$(date +%H:%M:%S)\"; $SSH /usr/local/bin/laurel-speed $what $threads" | tee "$out"
echo "speed: $out"
