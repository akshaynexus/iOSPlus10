#!/bin/sh
# WidgetKit extension jetsam limit on the running phone, no new root (reversible):
#   scripts/metal/phone-widget-jetsam.sh on [MB]   com.apple.widgetkit-extension limits -> MB (default 64), restart runningboardd
#   scripts/metal/phone-widget-jetsam.sh off       the original plists back (*.orig), restart runningboardd
#   scripts/metal/phone-widget-jetsam.sh status    the values in the phone's plists + the limits of running widgets
# iOS 16 limits every widget extension to 30 MiB (Version4 > Extension > Override > com.apple.widgetkit-extension in
# /System/Library/LaunchDaemons/com.apple.jetsamproperties.D22.plist and .D221.plist). runningboardd reads the file
# once, at its start (RBJetsamPropertyManager), so the script kills runningboardd and launchd starts it again
# (KeepAlive, ThrottleInterval 1); widgets launched after that get the new limit. The phone has no launchctl, so
# no userspace reboot. The first "on" keeps each original next to it as *.orig. The Mac patches a copy with
# scripts/ios16/jetsam_widgets.py. Root image: scripts/ios16/root-tweaks-extra.py (WIDGET_JETSAM_MB, default 64).
# docs/metal-widgets-2026-10-27.md.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
D=/System/Library/LaunchDaemons
cmd=${1:?usage: $0 on [MB] | off | status}
mb=${2:-64}
W=$REPO/out/widget-jetsam
mkdir -p "$W"

restart_rb() {
  "$SSHP" 'sync; p=$(ps -eo pid,comm | grep "runningboardd$" | sed "s/^ *//;s/ .*//"); [ -n "$p" ] && kill -9 $p; sleep 3;
           ps -eo pid,comm | grep -e runningboardd -e chronod'
  echo "runningboardd restarted; widget extensions launched from now on get the new limit"
}

files=$("$SSHP" "ls $D/com.apple.jetsamproperties.*.plist" | grep -v '\.orig$' || true)
[ -n "$files" ] || { echo "no jetsamproperties plist on the phone" >&2; exit 1; }

case $cmd in
on)
  for f in $files; do
    "$SSHP" "[ -f $f.orig ] || cp -p $f $f.orig"
    b=$(basename "$f")
    "$SSHP" pull "$f.orig" "$W/$b"   # always from the original: idempotent
    python3 -I "$REPO/scripts/ios16/jetsam_widgets.py" --mb "$mb" "$W/$b"
    "$SSHP" push "$W/$b" "$f"
    "$SSHP" "chown root:wheel $f; chmod 644 $f"
  done
  restart_rb ;;
off)
  for f in $files; do "$SSHP" "[ -f $f.orig ] && cp -p $f.orig $f || echo no $f.orig"; done
  restart_rb ;;
status)
  for f in $files; do
    b=$(basename "$f"); "$SSHP" pull "$f" "$W/cur-$b"
    python3 -I -c 'import plistlib,sys; print(sys.argv[1].split("/")[-1], plistlib.load(open(sys.argv[1],"rb"))["Version4"]["Extension"]["Override"]["com.apple.widgetkit-extension"])' "$W/cur-$b"
  done
  "$REPO/scripts/metal/memlimit.sh" 2>/dev/null | grep -i -e pid -e widget -e chronod || true ;;
*) echo "usage: $0 on [MB] | off | status" >&2; exit 2 ;;
esac
