#!/bin/bash
# One test round of the native Metal stack on the running phone, for the agent that works on it. Takes the phone lock for the whole round.
#   scripts/bg.sh round scripts/laurel/native/compositor-round.sh [--reboot] [--keep] [SECONDS]
# Hold the lock for one install and one run: a few minutes (default 150 s of run): other agents wait for it.
# --reboot first: `sync`, then op10tool ctl reboot, and wait for SSH (a GPU hang leaves the GPU off until a reboot). Then: install this tree's out/ios26/metal-all/stage with the setting native, wait SECONDS (default 150) or until a hang, take a screenshot, print the stack's lines, and write the setting `default` again (--keep: stay on native, for a test that follows).
# The UI test tool: AUTOTEST_DIR (default: this tree). Output: logs/round-TIME/ (screenshot, lines).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
MAIN=/home/akshay/Documents/GitHub/iOSPlus10
if [ "${ROUND_LOCKED:-0}" != 1 ]; then
  export ROUND_LOCKED=1
  exec "$MAIN/scripts/laurel/phone-lock.sh" native "$0" "$@"
fi
REBOOT=0; KEEP=0; WAIT=150
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
  # at most 3 min: the lock is shared; a phone that does not come back is not a reason to hold it
  wait_ssh 20 || { "$MAIN/scripts/laurel/phone-ensure-ios.sh" 2>&1 | tail -2; wait_ssh 20 || { say "STOP: no SSH after the reboot"; exit 1; }; }
  say "SSH is back"
fi
# (the phone can be still coming up: the recorder's file must be there before the stack starts; the slot's boots are few, so no reboot here: phone-ensure-ios.sh when SSH stays down)
wait_ssh 20 || { "$MAIN/scripts/laurel/phone-ensure-ios.sh" 2>&1 | tail -2; wait_ssh 20 || { say "STOP: no SSH"; exit 1; }; }
L=$(usblog); FROM=$(wc -l < "$L")
sh_phone 'touch /private/var/db/negronimetal/stack/flight-on; chmod 644 /private/var/db/negronimetal/stack/flight-on; chown 501 /private/var/db/negronimetal/stack/flight-on' 2>/dev/null
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
# the hang: the words of the failed submissions, and who wrote the address it read
H=$(grep -m1 'watchdog: GPU hang' "$D/usblog.txt" || true)
if [ -n "$H" ]; then
  for p in backboardd SpringBoard; do sh_phone "cat /private/var/db/negronimetal/stack/flight-$p" > "$D/flight-$p" 2>/dev/null || true; done
  FAR=$(grep -m1 'SMMU gfsr' "$D/usblog.txt" | sed -n 's/.*FAR \([0-9a-f]*\).*/\1/p')
  say "hang: FAR $FAR; words: ${FAR:8}, ${FAR:0:8}"
  for p in backboardd SpringBoard; do
    [ -s "$D/flight-$p" ] || continue
    echo "--- $p"; python3 -I "$REPO/scripts/laurel/native/flight-read.py" "$D/flight-$p" --find "${FAR:8:5}" --find "${FAR:4:4}${FAR:8:4}" | tail -8 | cut -c1-400
    python3 -I "$REPO/scripts/laurel/native/flight-read.py" "$D/flight-$p" > "$D/flight-$p.txt" 2>/dev/null; tail -n 12 "$D/flight-$p.txt" | cut -c1-260
  done
fi
if [ "$KEEP" = 0 ]; then
  sh_phone "rm -f /private/var/db/negronimetal/stack/flight-on; echo default > /private/var/db/negronimetal/option; echo default > $B/option.local; sync" 2>/dev/null && say "the setting is default again: acts at the next start" || say "the setting is NOT back: no SSH"
fi
say "folder $D"
