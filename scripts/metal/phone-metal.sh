#!/bin/sh
# NegroniMetal switch on the live phone (SSH over USB, scripts/net/ssh-phone.sh). docs/metal-management.md.
#   scripts/metal/phone-metal.sh on [NAMES]   every process gets the Metal device ("*" by default; or a list such
#                                             as "metalprobe m2vtest backboardd SpringBoard"); clears the strikes
#                                             and the off sentinel; then `restart` or a reboot
#   scripts/metal/phone-metal.sh off          no process gets a device (touches /private/var/db/negronimetal/off)
#   scripts/metal/phone-metal.sh probes       back to the root default: the test probes only
#   scripts/metal/phone-metal.sh status       clients, off sentinel, strikes, env
#   scripts/metal/phone-metal.sh strikes      clear the dead-man strikes only
#   scripts/metal/phone-metal.sh restart      kill backboardd (SpringBoard follows); the new one reads the files
#   scripts/metal/phone-metal.sh log [N]      last N lines (50) of /private/var/db/negronimetal/metal.log
# The files live on the root (userdata), so a change stays across reboots until userdata is flashed again;
# scripts/metal/root-add-metal.sh (METAL_CLIENTS) sets the same list in a new root. Output also goes to
# logs/metal-phone-<cmd>-<time>.log.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
D=/private/var/db/negronimetal
USAGE="on [NAMES]|off|probes|status|strikes|restart|log [N]"
cmd=${1:?usage: $0 $USAGE}
shift
mkdir -p "$REPO/logs"
LOG=$REPO/logs/metal-phone-$cmd-$(date +%Y%m%d-%H%M%S).log
run() { echo "== $*" | tee -a "$LOG"; "$SSHP" "$@" 2>&1 | tee -a "$LOG"; }
clients() { # NAMES: rewrite the clients file (comment + one line)
  run "mkdir -p $D $D/strikes && printf '# scripts/metal/phone-metal.sh, %s\n%s\n' '$(date +%Y-%m-%dT%H:%M:%S)' '$1' > $D/clients.new && chmod 644 $D/clients.new && mv -f $D/clients.new $D/clients && cat $D/clients"
}

case $cmd in
on)
  clients "${*:-*}"
  run "rm -f $D/off $D/strikes/* 2>/dev/null; ls -la $D"
  echo "on: processes started from now on get the Metal device ('${*:-*}'); $0 restart or reboot for backboardd/SpringBoard" | tee -a "$LOG"
  ;;
off)
  run "mkdir -p $D && echo 'phone-metal.sh off' > $D/off && ls -la $D/off"
  echo "off: no process gets a device from now on (CPU rasterisation); $0 restart to apply to the UI" | tee -a "$LOG"
  ;;
probes)
  clients "metalprobe m2vtest"
  run "rm -f $D/off"
  ;;
status)
  run "echo '--- clients'; cat $D/clients 2>/dev/null || echo '(none)'; echo '--- off'; ls -la $D/off 2>/dev/null || echo absent; echo '--- strikes'; ls -la $D/strikes/ 2>/dev/null; for f in $D/strikes/*; do [ -f \"\$f\" ] && echo \"\$f: \$(cat \$f)\"; done; echo '--- env'; cat $D/env 2>/dev/null || echo '(none)'"
  ;;
strikes)
  run "rm -f $D/strikes/* 2>/dev/null; ls -la $D/strikes/"
  ;;
restart)
  run 'p=$(ps -A | grep "[/]usr/libexec/backboardd" | sed "s/^ *//" | cut -d" " -f1 | head -1); [ -n "$p" ] && kill -9 $p; sleep 4; ps -A | grep "[/]usr/libexec/backboardd"'   # no killall on the phone
  ;;
log)
  run "tail -n ${1:-50} $D/metal.log 2>/dev/null || echo '(no metal.log yet)'"
  ;;
*) echo "usage: $0 $USAGE" >&2; exit 2 ;;
esac
