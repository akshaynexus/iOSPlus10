#!/bin/sh
# negroni-locd on the running phone over SSH (docs/location-plan.md, path L1). Simulated positions go into
# locationd through com.apple.locationd.simulation; apps see them as a normal fix (isSimulatedBySoftware = 1).
#   scripts/location/phone-location.sh push            copy out/location/userland/negroni-locd to /usr/local/bin
#   scripts/location/phone-location.sh remove          stop, then remove /usr/local/bin/negroni-locd
#   scripts/location/phone-location.sh set LAT LON [ACC]   one position (ACC m, default 10)
#   scripts/location/phone-location.sh hold LAT LON [ACC]  the same; a background process sends it again every 1 s
#   scripts/location/phone-location.sh listen          background UDP listener on 192.168.7.2:5155
#   scripts/location/phone-location.sh stream LAT LON [ACC] [SEC]
#                                                      listener + send the position from this host every SEC s
#                                                      (default 1) until Ctrl-C (the Mac side of "listen")
#   scripts/location/phone-location.sh stop            end the listener/hold process, stop the simulation
#   scripts/location/phone-location.sh enable|disable  Location Services switch through CoreLocation (L0 fallback)
#   scripts/location/phone-location.sh status          switch state, listener pid, the daemon log tail
#   scripts/location/phone-location.sh log             live unified log of locationd + negroni-locd
# A stream from another program: send UDP lines "LAT LON ACC" (or "stop") to 192.168.7.2:5155 from 192.168.7.1,
# e.g. printf '48.8584 2.2945 10\n' | nc -u -w0 192.168.7.2 5155
# The root is mounted writable (rootrw=1). Needs userland/location/build.sh output and scripts/net/ssh-phone.sh.
# Never writes a partition. Nothing here starts at boot (root hook: scripts/location/root-add-locd.sh).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH=$REPO/scripts/net/ssh-phone.sh
SRC=$REPO/out/location/userland/negroni-locd
BIN=/usr/local/bin/negroni-locd
LOGF=/private/var/log/iosplus10-negroni-locd.log
PORT=5155
IP=${PHONE_IP:-192.168.7.2}
ph() { "$SSH" "$*"; }
need() { ph "test -x $BIN" || { echo "no $BIN on the phone: run '$0 push'" >&2; exit 1; }; }
# the arguments go into a remote shell line: accept plain numbers only (the daemon checks the ranges)
nums() { for a in "$@"; do case $a in ''|*[!0-9.+-]*) echo "not a number: '$a'" >&2; exit 2 ;; esac; done; }

case "${1:-}" in
push)
  [ -f "$SRC" ] || { echo "missing $SRC: run userland/location/build.sh" >&2; exit 1; }
  "$SSH" true || exit 1
  ph "mkdir -p /usr/local/bin && rm -f $BIN.new"
  "$SSH" push "$SRC" "$BIN.new"
  ph "chown 0:0 $BIN.new && chmod 755 $BIN.new && mv -f $BIN.new $BIN && ls -l $BIN"
  echo "pushed $(shasum -a 256 "$SRC" | cut -d' ' -f1)" ;;
remove)
  ph "test -x $BIN && $BIN stop; rm -f $BIN; echo '$BIN removed'" ;;
set)
  shift; [ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: $0 set LAT LON [ACC]" >&2; exit 2; }
  nums "$@"; need; ph "$BIN set $*" ;;
hold)
  shift; [ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: $0 hold LAT LON [ACC]" >&2; exit 2; }
  nums "$@"; need; ph "$BIN stop >/dev/null 2>&1; $BIN -b hold $*" ;;
listen)
  need; ph "$BIN stop >/dev/null 2>&1; $BIN -b listen $PORT" ;;
stream)
  shift; [ $# -ge 2 ] || { echo "usage: $0 stream LAT LON [ACC] [SEC]" >&2; exit 2; }
  lat=$1; lon=$2; acc=${3:-10}; sec=${4:-1}
  nums "$lat" "$lon" "$acc" "$sec"
  command -v nc >/dev/null 2>&1 || { echo "no nc on this host" >&2; exit 1; }
  need; ph "$BIN stop >/dev/null 2>&1; $BIN -b listen $PORT"
  echo "streaming '$lat $lon $acc' to $IP:$PORT every $sec s (Ctrl-C ends; '$0 stop' stops the phone side)"
  while :; do printf '%s %s %s\n' "$lat" "$lon" "$acc" | nc -u -w0 "$IP" "$PORT" || true; sleep "$sec"; done ;;
stop)
  need; ph "$BIN stop" ;;
enable|disable)
  need; ph "$BIN $1" ;;
status)
  need; ph "$BIN status; echo '--- $LOGF (last 20 lines)'; tail -n 20 $LOGF 2>/dev/null || echo 'no log yet'" ;;
log)
  exec "$REPO/scripts/net/phone-log.sh" locationd negroni-locd ;;
*) sed -n 2,22p "$0"; exit 2 ;;
esac
