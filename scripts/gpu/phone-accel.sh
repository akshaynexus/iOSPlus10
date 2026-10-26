#!/bin/sh
# GPU acceleration on the live phone, both drivers in one go (SSH over USB):
#   scripts/gpu/phone-accel.sh on       NegroniMetal for every process (phone-metal.sh on "*"), NegroniGL for
#                                       backboardd (phone-gl.sh on) and for apps (phone-gl.sh apps on "* -backboardd"),
#                                       then restarts backboardd
#   scripts/gpu/phone-accel.sh off      Metal off, GL off for backboardd and apps, restart backboardd (CPU path)
#   scripts/gpu/phone-accel.sh status   both switches
# The owner's request (2026-10-27): acceleration on by default. The next root build gets the same defaults
# (scripts/ios16/root-update.sh: METAL_CLIENTS="*", NEGRONIGL_CLIENTS="*").
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/scripts/metal/phone-metal.sh
G=$REPO/scripts/gpu/phone-gl.sh
case ${1:?usage: $0 on|off|status} in
on)
  sh "$M" on '*'
  sh "$G" on
  sh "$G" apps on '*' -backboardd || echo "phone-accel: GL apps switch failed (no out/gpu/stage?); Metal + backboardd GL are on" >&2
  sh "$M" restart
  ;;
off)
  sh "$M" off
  sh "$G" off
  sh "$G" apps off || true
  sh "$M" restart
  ;;
status)
  sh "$M" status
  sh "$G" apps status || true
  "$REPO/scripts/net/ssh-phone.sh" "cat /var/db/negronigl/clients 2>/dev/null; ls -la /var/db/negronigl/off 2>/dev/null || echo 'gl off sentinel absent'"
  ;;
*) echo "usage: $0 on|off|status" >&2; exit 2 ;;
esac
