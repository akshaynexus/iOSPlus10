#!/bin/sh
# iOS logs over SSH (docs/usb-network.md). Output is also saved in logs/phone-log-<date>.txt.
#   scripts/net/phone-log.sh [-l] [-g TEXT] [PROCESS...]   live unified log (oslogstream on the phone,
#                                                         like `log stream`); falls back to "tail"
#   scripts/net/phone-log.sh tail                         print each new crash report as it appears
#   scripts/net/phone-log.sh crashes                      list crash reports, newest first
#   scripts/net/phone-log.sh crash [NAME]                 print the newest report (whose name contains NAME)
#   scripts/net/phone-log.sh pull [DIR]                   copy all reports to DIR (logs/phone-crashes-<date>)
# Long sessions: scripts/bg.sh phonelog scripts/net/phone-log.sh ... (log in logs/phonelog.log).
# Env as scripts/net/ssh-phone.sh; PHONE_CRASHDIR overrides the report folder. The kernel log is separate: make usblog (UDP 5140).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
CR=${PHONE_CRASHDIR:-/private/var/mobile/Library/Logs/CrashReporter}
mkdir -p "$REPO/logs"
LOG=$REPO/logs/phone-log-$(date +%Y%m%d-%H%M%S).txt

q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
rsh() { "$SSHP" "exec /bin/sh -c $(q "$1")" </dev/null; }   # run a POSIX script whatever the login shell

# Without a tty, a remote command keeps running after ssh dies until it writes; the stream writes
# often, so it ends soon after Ctrl-C.
tail_crashes() {
  echo "phone-log: following new crash reports in $CR (Ctrl-C ends)" >&2
  echo "phone-log: note: root-tweaks-extra.py removes com.apple.ReportCrash, so iOS may write no" >&2
  echo "  reports; the kernel's CRASH lines in the USB kernel log (make usblog) still show crashes." >&2
  rsh "cd $(q "$CR") || exit 1
    old=\$(find . -type f | sort)
    while sleep 2; do
      new=\$(find . -type f | sort)
      for f in \$new; do
        case \"
\$old
\" in *\"
\$f
\"*) ;; *) echo \"=== \$f\"; head -c 32768 \"\$f\"; echo ;; esac
      done
      old=\$new
    done" | tee -a "$LOG"
}

case "${1:-}" in
tail) tail_crashes ;;
crashes)
  rsh "cd $(q "$CR") 2>/dev/null && f=\$(find . -type f) && [ -n \"\$f\" ] && ls -lt \$f | head -50 || echo 'no reports in $CR'" ;;
crash)
  pat=${2:-}
  rsh "cd $(q "$CR") 2>/dev/null || exit 1; all=\$(find . -type f); [ -n \"\$all\" ] || { echo 'no reports' >&2; exit 1; }
    f=\$(ls -t \$all | grep -F -- $(q "$pat") | head -1)
    [ -n \"\$f\" ] || { echo 'no matching report' >&2; exit 1; }; echo \"=== \$f\"; cat \"\$f\"" > "$LOG.part" || rc=$?
  cat "$LOG.part"; cat "$LOG.part" >> "$LOG"; rm -f "$LOG.part"; exit ${rc:-0} ;;
pull)
  dst=${2:-$REPO/logs/phone-crashes-$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$dst"
  "$SSHP" pull "$CR" "$dst/" && echo "phone-log: reports in $dst/$(basename "$CR")" ;;
-h|--help) sed -n 2,11p "$0" ;;
*)
  set +e
  "$SSHP" 'test -x /usr/local/bin/oslogstream' </dev/null
  rc=$?
  set -e
  [ $rc != 255 ] || exit 255
  if [ $rc != 0 ]; then
    echo "phone-log: no /usr/local/bin/oslogstream on the phone (root without SSH=1 tools?)" >&2
    tail_crashes
    exit
  fi
  args=; for a in "$@"; do args="$args $(q "$a")"; done
  echo "phone-log: live unified log -> $LOG (Ctrl-C ends)" >&2
  "$SSHP" "/usr/local/bin/oslogstream$args" </dev/null | tee -a "$LOG" ;;
esac
