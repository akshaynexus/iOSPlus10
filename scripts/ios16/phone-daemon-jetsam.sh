#!/bin/sh
# Raise one daemon's jetsam memory limits on the running phone (no new root; reversible):
#   scripts/ios16/phone-daemon-jetsam.sh on [NAME] [MB]   NAME (default com.apple.lsd) limits -> MB (default 64)
#   scripts/ios16/phone-daemon-jetsam.sh off               the original plists back (*.orig)
#   scripts/ios16/phone-daemon-jetsam.sh status [NAME]     the values in the phone's plists
# launchd applies daemon limits at spawn from /System/Library/LaunchDaemons/com.apple.jetsamproperties.<model>.plist,
# read at boot: reboot after on/off (out/bin/op10tool ctl reboot, or RAM-boot the test image again). The first "on"
# keeps each original next to it as *.orig. Root image: scripts/ios16/root-tweaks-extra.py (LSD_JETSAM_MB, default 64).
# Why: on a fresh root lsd crosses its 16 MiB limit while it rebuilds the LaunchServices database and is killed in a
# loop, so no app opens (2026-10-27, t26: CRASH lsd sig 9, reason namespace 1 code 7).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
D=/System/Library/LaunchDaemons
cmd=${1:?usage: $0 on [NAME] [MB] | off | status [NAME]}
name=${2:-com.apple.lsd}
mb=${3:-64}
case $mb in *[!0-9]*|"") echo "MB must be a number" >&2; exit 2 ;; esac
W=$REPO/out/daemon-jetsam
mkdir -p "$W"
files=$("$SSHP" "ls $D/com.apple.jetsamproperties.*.plist" | grep -v '\.orig$' || true)
[ -n "$files" ] || { echo "no jetsamproperties plist on the phone" >&2; exit 1; }
case $cmd in
on)
  for f in $files; do
    "$SSHP" "[ -f $f.orig ] || cp -p $f $f.orig"
    b=$(basename "$f")
    "$SSHP" pull "$f" "$W/$b"
    python3 -I "$REPO/scripts/ios16/jetsam_widgets.py" --daemon "$name" --mb "$mb" "$W/$b"
    "$SSHP" push "$W/$b" "$f"
    "$SSHP" "chown root:wheel $f; chmod 644 $f"
  done
  echo "done: reboot the phone so launchd reads the new limits" ;;
off)
  for f in $files; do "$SSHP" "[ -f $f.orig ] && cp -p $f.orig $f || echo no $f.orig"; done
  echo "done: reboot the phone" ;;
status)
  for f in $files; do
    b=$(basename "$f"); "$SSHP" pull "$f" "$W/cur-$b"
    python3 -I -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(sys.argv[1].split("/")[-1], d["Version4"]["Daemon"]["Override"].get(sys.argv[2]))' "$W/cur-$b" "$name"
  done ;;
*) echo "usage: $0 on [NAME] [MB] | off | status [NAME]" >&2; exit 2 ;;
esac
