#!/bin/sh
# Mi A3: one job at a time on the phone. A bench, a UI restart, an install or a test that can hang the GPU takes this lock, so a run of one agent does not spoil a run of another.
#   scripts/laurel/phone-lock.sh NAME COMMAND...     waits for the lock (up to LOCK_WAIT_S, default 1800), runs COMMAND, frees it, and exits with COMMAND's code
#   scripts/laurel/phone-lock.sh --who               says who holds it
# The lock is /tmp/iosplus10-phone.lock, one for all worktrees. It frees itself when COMMAND ends or dies. A read of a log or `ps` needs no lock.
set -eu
L=/tmp/iosplus10-phone.lock
W=$L.who
if [ "${1:-}" = --who ]; then
  if flock -n "$L" true 2>/dev/null; then echo "phone-lock: free"; else echo "phone-lock: held by $(cat "$W" 2>/dev/null)"; fi
  exit 0
fi
[ $# -ge 2 ] || { echo "phone-lock: NAME COMMAND..." >&2; exit 2; }
name=$1; shift
exec 9>"$L"
if ! flock -n 9; then
  echo "phone-lock: $name waits for: $(cat "$W" 2>/dev/null)"
  flock -w "${LOCK_WAIT_S:-1800}" 9 || { echo "phone-lock: $name gave up after ${LOCK_WAIT_S:-1800} s"; exit 75; }
fi
echo "$name since $(date +%H:%M:%S)" > "$W"
echo "phone-lock: $name has the phone"
rc=0
"$@" || rc=$?
: > "$W"
exit "$rc"
