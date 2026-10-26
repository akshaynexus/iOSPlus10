#!/bin/sh
# Host-side USB recovery of the phone gadget on macOS (see tools/usb-host-kick/usb-host-kick.c):
#   scripts/debug/usb-host-kick.sh reenum|suspend|resume     (asks for sudo; SUDO_PASS=... for tmux jobs)
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
B=$REPO/out/bin/usb-host-kick
[ "$(uname)" = Darwin ] || { echo "macOS only (Linux: echo 0 > /sys/bus/usb/devices/X/authorized, or usbreset)" >&2; exit 1; }
mkdir -p "$REPO/out/bin"
[ "$B" -nt "$REPO/tools/usb-host-kick/usb-host-kick.c" ] || clang -O2 -o "$B" "$REPO/tools/usb-host-kick/usb-host-kick.c" -framework IOKit -framework CoreFoundation
if [ -n "${SUDO_PASS:-}" ]; then echo "$SUDO_PASS" | sudo -S "$B" "$@"; else sudo "$B" "$@"; fi
