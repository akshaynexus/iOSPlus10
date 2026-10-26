#!/bin/sh
# Bluetooth userland on the running phone, no new root (reversible). docs/bluetooth-plan.md section 4.
#   scripts/bt/phone-bt.sh on       push negroni-bluetool + hcitest, launchd cache: bluetoothd job on with
#                                   BT_HCI_TRANSPORT, BlueTool job -> /usr/libexec/negroni-bluetool
#   scripts/bt/phone-bt.sh off      the launchd cache from before the first "on" back
#   scripts/bt/phone-bt.sh status   jobs, binaries, /dev nodes, processes
#   scripts/bt/phone-bt.sh test     run hcitest (stops bluetoothd first: one transport client at a time)
#   scripts/bt/phone-bt.sh log      bluetoothd / BlueTool lines of the unified log (scripts/net/phone-log.sh)
# Needs out/bt/userland (userland/bluetooth/build.sh) and a kernel booted with negronibt=4 + the ADT node.
# launchd reads the cache at boot only: reboot after on/off (printed, not run). The first "on" keeps the
# phone's cache as /var/db/negronibt/launchd.plist.orig. One plain file per copy, never a "var" directory entry.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
CACHE=/System/Library/xpc/launchd.plist
BTD=/System/Library/LaunchDaemons/com.apple.bluetoothd.plist
ORIG=/var/db/negronibt/launchd.plist.orig
U=$REPO/out/bt/userland
W=$REPO/out/bt/phone
cmd=${1:?usage: $0 on | off | status | test | log}
mkdir -p "$W" "$REPO/logs"
LOG=$REPO/logs/phone-bt-$(date +%Y%m%d-%H%M%S).log
pull() { rm -f "$W/launchd.plist"; "$SSHP" pull "$CACHE" "$W/launchd.plist" >/dev/null; }
hint() { echo "phone-bt: launchd reads the cache at boot only. Reboot: scripts/net/ssh-phone.sh reboot" | tee -a "$LOG"; }
case $cmd in
status)
  pull
  python3 "$REPO/scripts/bt/bt-launchd.py" "$W/launchd.plist" status | tee -a "$LOG"
  "$SSHP" "ls -l /dev/uart.bluetooth /dev/cu.bluetooth /dev/btwake /usr/libexec/negroni-bluetool /usr/local/bin/hcitest $ORIG 2>&1; ps ax | grep -i -e bluetoothd -e BlueTool -e negroni-bluetool | grep -v grep" | tee -a "$LOG" || true
  ;;
on)
  for b in negroni-bluetool hcitest; do [ -f "$U/$b" ] || { echo "missing $U/$b: userland/bluetooth/build.sh" >&2; exit 1; }; done
  pull
  rm -f "$W/bluetoothd.plist"; "$SSHP" pull "$BTD" "$W/bluetoothd.plist" >/dev/null
  python3 "$REPO/scripts/bt/bt-launchd.py" "$W/launchd.plist" on "$W/bluetoothd.plist" | tee -a "$LOG"
  "$SSHP" push "$U/negroni-bluetool" "$U/hcitest" "$W/launchd.plist" /private/var/tmp/
  "$SSHP" "[ -L /var ] || { echo '/var is not a symlink: stop'; exit 1; };
    mkdir -p /var/db/negronibt /usr/local/bin && { [ -f $ORIG ] || cp -p $CACHE $ORIG; } &&
    install -m 755 /private/var/tmp/negroni-bluetool /usr/libexec/negroni-bluetool &&
    install -m 755 /private/var/tmp/hcitest /usr/local/bin/hcitest &&
    cat /private/var/tmp/launchd.plist > $CACHE &&
    rm /private/var/tmp/launchd.plist /private/var/tmp/negroni-bluetool /private/var/tmp/hcitest &&
    ls -l $CACHE $ORIG /usr/libexec/negroni-bluetool /usr/local/bin/hcitest" | tee -a "$LOG"
  hint
  ;;
off)
  if "$SSHP" "[ -f $ORIG ]"; then
    "$SSHP" "cat $ORIG > $CACHE && rm $ORIG && ls -l $CACHE" | tee -a "$LOG"
  else
    pull
    python3 "$REPO/scripts/bt/bt-launchd.py" "$W/launchd.plist" off | tee -a "$LOG"
    "$SSHP" push "$W/launchd.plist" /private/var/tmp/launchd.plist
    "$SSHP" "cat /private/var/tmp/launchd.plist > $CACHE && rm /private/var/tmp/launchd.plist" | tee -a "$LOG"
  fi
  hint
  ;;
test)
  "$SSHP" "launchctl stop com.apple.bluetoothd 2>/dev/null; sleep 1; /usr/local/bin/hcitest ctl; /usr/local/bin/hcitest dev; launchctl start com.apple.bluetoothd 2>/dev/null; true" | tee -a "$LOG"
  ;;
log)
  sh "$REPO/scripts/net/phone-log.sh" -g 'BlueTool|HCI Transport|Booting chipset|Powering on|uart|No bluetooth|serial port|local-mac|BT_' bluetoothd 2>&1 | tee -a "$LOG" || true
  ;;
*) echo "usage: $0 on | off | status | test | log" >&2; exit 2 ;;
esac
echo "log: $LOG"
