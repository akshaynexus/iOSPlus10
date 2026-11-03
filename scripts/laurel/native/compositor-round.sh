#!/bin/bash
# One test round of the native Metal stack on the running phone, for the agent that works on it. Takes the phone lock for the whole round.
#   scripts/bg.sh round scripts/laurel/native/compositor-round.sh [--reboot] [--keep] [SECONDS]
# --reboot first: `sync`, then op10tool ctl reboot, and wait for SSH (a GPU hang leaves the GPU off until a reboot). Then: install this tree's out/ios26/metal-all/stage with the setting native, wait SECONDS (default 240) or until a hang, take a screenshot, print the stack's lines, and write the setting `default` again (--keep: stay on native, for a test that follows).
# The UI test tool: AUTOTEST_DIR (default: this tree). Output: logs/round-TIME/ (screenshot, lines).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
MAIN=/home/akshay/Documents/GitHub/iOSPlus10
if [ "${ROUND_LOCKED:-0}" != 1 ]; then
  export ROUND_LOCKED=1
  exec "$MAIN/scripts/laurel/phone-lock.sh" native "$0" "$@"
fi
REBOOT=0; KEEP=0; WAIT=240
for a in "$@"; do case "$a" in --reboot) REBOOT=1 ;; --keep) KEEP=1 ;; *) WAIT=$a ;; esac; done
OP=$MAIN/out/bin/op10tool
B=/System/Library/Extensions/NegroniMetal.bundle
D=$REPO/logs/round-$(date +%H%M%S); mkdir -p "$D"
sh_phone() { sshpass -p "${IOS_PASSWORD:-alpine}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 root@192.168.7.2 "$@"; }
wait_ssh() { for _ in $(seq 1 ${1:-60}); do [ "$(sh_phone uname -s 2>/dev/null)" = Darwin ] && return 0; sleep 3; done; return 1; }
usblog() { ls -t "$MAIN"/logs/usblog-*.txt | head -1; }
say() { echo "$(date +%H:%M:%S) round: $*"; }
if [ "$REBOOT" = 1 ]; then
  sh_phone sync 2>/dev/null || true
  "$OP" ctl reboot 2>&1 | tail -1
  sleep 15
  wait_ssh 100 || { say "STOP: no SSH after the reboot"; exit 1; }
  say "SSH is back"
fi
L=$(usblog); FROM=$(wc -l < "$L")
"$REPO/scripts/laurel/ios26-metal-install-options.sh" native 2>&1 | tail -1
say "on native; waiting $WAIT s"
for _ in $(seq 1 $((WAIT / 5))); do
  sleep 5
  L=$(usblog)
  if tail -n +"$FROM" "$L" | grep -qE 'watchdog: GPU hang|LAUREL METAL NATIVE: off|LAUREL PANIC: holding'; then say "stopped early: a hang, a fallback or a panic"; sleep 5; break; fi
done
L=$(usblog)
tail -n +"$FROM" "$L" > "$D/usblog.txt"
grep -E 'LAUREL METAL:|METAL NATIVE|METAL26: |stream check|GPU hang|SMMU gfsr|LAUREL GPU: off|CRASH (backboardd|SpringBoard)\[|LAUREL PANIC|Assertion failed|LAUREL FRAME: motion|native-metal: refused' "$D/usblog.txt" | cut -c1-260 | tail -40
grep -E 'RedwoodGPU: [0-9]+ submissions' "$D/usblog.txt" | tail -3 | cut -c1-200
(cd "${AUTOTEST_DIR:-$REPO}" && timeout 50 scripts/laurel/ios26-autotest.sh shot "round-$(basename "$D")" 2>&1 | tail -1 | cut -c1-200)
cp "${AUTOTEST_DIR:-$REPO}/logs/autotest-shots/round-$(basename "$D").png" "$D/screen.png" 2>/dev/null
sh_phone 'grep -E "native-metal: (program|compute program)" /private/var/db/negronimetal/metal.log | tail -6; grep -E "this (draw|dispatch)|refused" /private/var/db/negronimetal/metal.log | tail -20; cat /private/var/db/negronimetal/stack/state' 2>/dev/null > "$D/metal-log.txt"
tail -n 30 "$D/metal-log.txt" | cut -c1-230
if [ "$KEEP" = 0 ]; then
  sh_phone "echo default > /private/var/db/negronimetal/option; echo default > $B/option.local; sync" 2>/dev/null && say "the setting is default again: acts at the next start" || say "the setting is NOT back: no SSH"
fi
say "folder $D"
