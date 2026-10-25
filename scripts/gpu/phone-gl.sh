#!/bin/sh
# The GL path on the running phone, over SSH (scripts/net/ssh-phone.sh): push the staged files, switch the
# gate, run the self test, read the log. Input: out/gpu/stage from scripts/gpu/gl-build.sh. Model:
# scripts/metal/phone-test.sh, but every file is pushed on its own (never an archive: a "var" directory entry
# once replaced the /var symlink and broke SSH).
#   scripts/gpu/phone-gl.sh push        /usr/lib/negronigl.dylib, /usr/local/bin/ngl_test, /var/db/negronigl/clients (kept if present)
#   scripts/gpu/phone-gl.sh backboardd  install the staged backboardd (weak dylib load); the original is kept once as
#                                       /usr/libexec/backboardd.orig. Takes effect at the next backboardd start.
#   scripts/gpu/phone-gl.sh restore     /usr/libexec/backboardd.orig back
#   scripts/gpu/phone-gl.sh on|off      backboardd into / out of /var/db/negronigl/clients (the A/B switch; off also
#                                       removes /var/db/negronigl/off); then `restart` or a reboot
#   scripts/gpu/phone-gl.sh restart     kill backboardd (launchd starts it again); SpringBoard restarts with it
#   scripts/gpu/phone-gl.sh test        /usr/local/bin/ngl_test (GPU identity, triangle, IOSurface round trip)
#   scripts/gpu/phone-gl.sh status      what is installed and the gate
#   scripts/gpu/phone-gl.sh log         live unified log filtered on "negronigl" (scripts/net/phone-log.sh -g; Ctrl-C ends it);
#                                       the kernel side (RedwoodGPU, NEGRONI FB STAT) is in `make usblog`
# Output also goes to logs/gl-phone-<cmd>-<time>.log. Proof lines: docs/gpu-userland.md "GL path".
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
S=$REPO/out/gpu/stage
D=/var/db/negronigl
cmd=${1:?usage: $0 push|backboardd|restore|on|off|restart|test|status|log}
mkdir -p "$REPO/logs"
LOG=$REPO/logs/gl-phone-$cmd-$(date +%Y%m%d-%H%M%S).log
run() { echo "== $*" | tee -a "$LOG"; "$SSHP" "$@" 2>&1 | tee -a "$LOG"; }
# one file: scp to /private/var/tmp, then cat into place (keeps the owner/mode of an existing file, no rename over a symlink)
put() { # LOCAL REMOTE MODE
  "$SSHP" push "$1" /private/var/tmp/negronigl.new
  run "[ -L /var ] || { echo '/var is not a symlink: stop'; exit 1; }; mkdir -p $(dirname "$2") &&
       cat /private/var/tmp/negronigl.new > $2.new && rm /private/var/tmp/negronigl.new && chmod $3 $2.new && chown 0:0 $2.new && mv -f $2.new $2 && ls -la $2"
}

case $cmd in
push)
  [ -f "$S/usr/lib/negronigl.dylib" ] || { echo "no $S: scripts/gpu/gl-build.sh" >&2; exit 1; }
  put "$S/usr/lib/negronigl.dylib" /usr/lib/negronigl.dylib 755
  put "$S/usr/local/bin/ngl_test" /usr/local/bin/ngl_test 755
  if "$SSHP" "[ -f $D/clients ]"; then echo "push: $D/clients kept" | tee -a "$LOG"
  else put "$S/var/db/negronigl/clients" $D/clients 644; fi
  run "mkdir -p $D && chmod 755 $D && ls -la $D"
  ;;
backboardd)
  [ -f "$S/usr/libexec/backboardd" ] || { echo "no staged backboardd in $S (IOS_ROOT at build time)" >&2; exit 1; }
  run "[ -f /usr/libexec/backboardd.orig ] || cp -p /usr/libexec/backboardd /usr/libexec/backboardd.orig; ls -la /usr/libexec/backboardd.orig"
  put "$S/usr/libexec/backboardd" /usr/libexec/backboardd 755
  run "otool -L /usr/libexec/backboardd 2>/dev/null | grep negronigl || echo '(no otool on the phone: check from the Mac copy)'"
  echo "backboardd: installed; it loads /usr/lib/negronigl.dylib at its next start ($0 restart or reboot)" | tee -a "$LOG"
  ;;
restore)
  run "[ -f /usr/libexec/backboardd.orig ] && cat /usr/libexec/backboardd.orig > /usr/libexec/backboardd && rm /usr/libexec/backboardd.orig && ls -la /usr/libexec/backboardd || echo 'no backboardd.orig'"
  ;;
on)
  run "mkdir -p $D && rm -f $D/off && touch $D/clients && grep -qw backboardd $D/clients || echo backboardd >> $D/clients; cat $D/clients"
  echo "on: backboardd takes the GL path at its next start ($0 restart or reboot)" | tee -a "$LOG"
  ;;
off)
  run "rm -f $D/off; [ -f $D/clients ] && grep -vw backboardd $D/clients > $D/clients.new && mv -f $D/clients.new $D/clients; cat $D/clients 2>/dev/null || true"
  echo "off: backboardd keeps Apple's EAGL at its next start ($0 restart or reboot)" | tee -a "$LOG"
  ;;
restart)
  run "killall backboardd; sleep 3; ps ax | grep -w [b]ackboardd"
  ;;
test)
  run "/usr/local/bin/ngl_test"
  ;;
status)
  run "ls -la /usr/lib/negronigl.dylib /usr/local/bin/ngl_test /usr/libexec/backboardd /usr/libexec/backboardd.orig $D 2>&1; echo '-- clients:'; cat $D/clients 2>/dev/null; [ -f $D/off ] && echo 'off file present'; true"
  ;;
log)
  echo "== phone-log -g negronigl backboardd (live, Ctrl-C ends)" | tee -a "$LOG"
  "$REPO/scripts/net/phone-log.sh" -g negronigl backboardd 2>&1 | tee -a "$LOG" || true
  ;;
*) echo "usage: $0 push|backboardd|restore|on|off|restart|test|status|log" >&2; exit 1 ;;
esac
echo "log: $LOG"
