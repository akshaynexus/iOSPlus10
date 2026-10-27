#!/bin/sh
# Shorten configd's InterfaceNamer stack timer on the running phone (no new root; reversible):
#   scripts/wifi/phone-ifnamer-timeout.sh on [SEC]   WaitStackTimeout = SEC (default 10) in InterfaceNamer's Info.plist
#   scripts/wifi/phone-ifnamer-timeout.sh off        the original plist back (Info.plist.orig)
#   scripts/wifi/phone-ifnamer-timeout.sh status     the value on the phone (none = 300 s built-in default)
# configd reads the value once at start: reboot after on/off (out/bin/op10tool ctl reboot).
# Why (docs/notes.md section 71, patches/xnu/README-wifi.md "wifid stall root cause"): wifid's first SCNetworkInterfaceCopyAll
# waits until the configd key Plugin:InterfaceNamer has *QUIET*, *COMPLETE* or *TIMEOUT*. Our kernel has no
# IONetworkStack, so InterfaceNamer never publishes *QUIET* by itself; in about half of the boots the key gets
# *TIMEOUT* only from the 300 s stack timer, and wifid init and the Settings Wi-Fi page wait until then.
# Root image: scripts/ios16/root-tweaks-extra.py (IFNAMER_WAIT_S, default off).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
F=/System/Library/SystemConfiguration/InterfaceNamer.bundle/Info.plist
W=$REPO/out/ifnamer
cmd=${1:?usage: $0 on [SEC] | off | status}
sec=${2:-10}
case $sec in *[!0-9]*|""|0) echo "SEC must be a whole number > 0" >&2; exit 2 ;; esac
mkdir -p "$W"
case $cmd in
on)
  "$SSHP" "[ -f $F.orig ] || cp -p $F $F.orig"
  "$SSHP" pull "$F" "$W/Info.plist"
  python3 -I -c 'import plistlib,sys
p=sys.argv[1]; d=plistlib.load(open(p,"rb")); d["WaitStackTimeout"]=float(sys.argv[2])
plistlib.dump(d,open(p,"wb"),fmt=plistlib.FMT_BINARY)' "$W/Info.plist" "$sec"
  "$SSHP" push "$W/Info.plist" "$F"
  "$SSHP" "chown root:wheel $F; chmod 644 $F"
  echo "done: WaitStackTimeout $sec s; reboot the phone so configd reads it" ;;
off)
  "$SSHP" "[ -f $F.orig ] && cp -p $F.orig $F || echo no $F.orig"
  echo "done: reboot the phone" ;;
status)
  "$SSHP" pull "$F" "$W/cur-Info.plist"
  python3 -I -c 'import plistlib,sys; print("WaitStackTimeout:", plistlib.load(open(sys.argv[1],"rb")).get("WaitStackTimeout", "none (300 s default)"))' "$W/cur-Info.plist" ;;
*) echo "usage: $0 on [SEC] | off | status" >&2; exit 2 ;;
esac
