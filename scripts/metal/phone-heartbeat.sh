#!/bin/sh
# CoreAnimation heartbeat test on the running phone, no new kernel or root (reversible):
#   scripts/metal/phone-heartbeat.sh on [RATE]   backboardd gets CA_HEARTBEAT_RATE=RATE (default 120)
#   scripts/metal/phone-heartbeat.sh off         the launchd cache from before the first "on" back
#   scripts/metal/phone-heartbeat.sh status      the value backboardd's job has now
# QuartzCore 20H392 (AppleCLCDDisplay::heartbeat_rate) takes 1/CA_HEARTBEAT_RATE as its base quantum
# before the IOMFBDisplayRefresh property (patch 0253) and the 1/60 s default (docs/notes.md section 15).
# launchd on this port reads its jobs only from the cache /System/Library/xpc/launchd.plist (key
# /System/Library/LaunchDaemons/com.apple.backboardd.plist; docs/usb-network.md), so that is the file
# edited, not the plist in LaunchDaemons. The Mac edits a copy (python3 plistlib: the key has dots,
# which plutil's key paths cannot hold; works on Linux too). First "on" keeps the phone's original as
# /var/db/negronimetal/launchd.plist.orig. One plain file is copied, no archive: never push a "var"
# directory entry (it replaced the /var symlink once, scripts/metal/phone-test.sh).
# launchd reads the cache at boot only: reboot afterwards (printed, not run).
# Root image path: scripts/ios16/root-tweaks-extra.py (CA_HEARTBEAT, default 120).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
CACHE=/System/Library/xpc/launchd.plist
ORIG=/var/db/negronimetal/launchd.plist.orig
cmd=${1:?usage: $0 on [RATE] | off | status}
rate=${2:-120}
W=$REPO/out/heartbeat
mkdir -p "$W" "$REPO/logs"
LOG=$REPO/logs/phone-heartbeat-$(date +%Y%m%d-%H%M%S).log

job() { # PLIST show|set RATE|remove
  python3 -I - "$@" <<'PY'
import plistlib, sys
path, op = sys.argv[1], sys.argv[2]
key = '/System/Library/LaunchDaemons/com.apple.backboardd.plist'
data = plistlib.load(open(path, 'rb'))
job = (data.get('LaunchDaemons') or {}).get(key)
if not isinstance(job, dict):
    sys.exit('phone-heartbeat: no backboardd job in ' + path)
env = job.get('EnvironmentVariables') or {}
if op == 'show':
    print('CA_HEARTBEAT_RATE=' + env.get('CA_HEARTBEAT_RATE', '(not set: 1/60 s or the driver property)'))
    sys.exit(0)
if op == 'set':
    env['CA_HEARTBEAT_RATE'] = sys.argv[3]
else:
    env.pop('CA_HEARTBEAT_RATE', None)
job['EnvironmentVariables'] = env
if not env:
    del job['EnvironmentVariables']
with open(path, 'wb') as fh:
    plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
print('phone-heartbeat: edited copy:', 'CA_HEARTBEAT_RATE=' + env.get('CA_HEARTBEAT_RATE', '(removed)'))
PY
}
pull() { rm -f "$W/launchd.plist"; "$SSHP" pull "$CACHE" "$W/launchd.plist" >/dev/null; }
hint() {
  echo "phone-heartbeat: launchd reads the cache at boot only. Reboot to apply: scripts/net/ssh-phone.sh reboot"
  echo "  proof: 'CoreAnimation: GetDisplayInfo returned ...' (scripts/net/phone-log.sh -g GetDisplayInfo backboardd) and the kernel line"
  echo "  'NEGRONI FB STAT: swaps/s N' going from ~60 toward 120 (make usblog)"
}

case $cmd in
status)
  pull
  job "$W/launchd.plist" show | tee -a "$LOG"
  "$SSHP" "ls -l $CACHE $ORIG 2>&1" | tee -a "$LOG" || true
  ;;
on)
  case $rate in ''|*[!0-9.]*) echo "RATE must be a number" >&2; exit 2 ;; esac
  pull
  cp "$W/launchd.plist" "$W/launchd.plist.before"
  job "$W/launchd.plist" set "$rate" | tee -a "$LOG"
  "$SSHP" push "$W/launchd.plist" /private/var/tmp/launchd.plist.new
  # backup once (the first "on"); cat keeps the cache's owner and mode
  "$SSHP" "[ -L /var ] || { echo '/var is not a symlink: stop'; exit 1; };
    mkdir -p /var/db/negronimetal && { [ -f $ORIG ] || cp -p $CACHE $ORIG; } &&
    cat /private/var/tmp/launchd.plist.new > $CACHE && rm /private/var/tmp/launchd.plist.new && ls -l $CACHE $ORIG" | tee -a "$LOG"
  hint
  ;;
off)
  if "$SSHP" "[ -f $ORIG ]"; then
    "$SSHP" "cat $ORIG > $CACHE && rm $ORIG && ls -l $CACHE" | tee -a "$LOG"
    echo "phone-heartbeat: original launchd cache restored" | tee -a "$LOG"
  else
    # no backup (e.g. a root image built with CA_HEARTBEAT): take the key out
    pull
    job "$W/launchd.plist" remove | tee -a "$LOG"
    "$SSHP" push "$W/launchd.plist" /private/var/tmp/launchd.plist.new
    "$SSHP" "cat /private/var/tmp/launchd.plist.new > $CACHE && rm /private/var/tmp/launchd.plist.new && ls -l $CACHE" | tee -a "$LOG"
  fi
  hint
  ;;
*) echo "usage: $0 on [RATE] | off | status" >&2; exit 2 ;;
esac
echo "log: $LOG"
