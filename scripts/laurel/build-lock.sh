#!/bin/sh
# Shared tree: one build at a time in the main checkout (owner, 2026-11-07: all agents work on one branch and one worktree). A kernel, Mu, image or root build, or a git commit-and-push, takes this lock, so two agents do not write out/ or the index at once.
#   scripts/laurel/build-lock.sh NAME COMMAND...     waits for the lock (up to LOCK_WAIT_S, default 1800), runs COMMAND, frees it, and exits with COMMAND's code
#   scripts/laurel/build-lock.sh --who               says who holds it
# The lock is /tmp/iosplus10-build.lock, one for all worktrees. It frees itself when COMMAND ends or dies. A read of a log or `ps` needs no lock.
set -eu
L=/tmp/iosplus10-build.lock
W=$L.who
if [ "${1:-}" = --who ]; then
  if flock -n "$L" true 2>/dev/null; then echo "build-lock: free"; else echo "build-lock: held by $(cat "$W" 2>/dev/null)"; fi
  exit 0
fi
[ $# -ge 2 ] || { echo "build-lock: NAME COMMAND..." >&2; exit 2; }
name=$1; shift
exec 9>"$L"
if ! flock -n 9; then
  echo "build-lock: $name waits for: $(cat "$W" 2>/dev/null)"
  flock -w "${LOCK_WAIT_S:-1800}" 9 || { echo "build-lock: $name gave up after ${LOCK_WAIT_S:-1800} s"; exit 75; }
fi
echo "$name since $(date +%H:%M:%S)" > "$W"
echo "build-lock: $name has the tree"
rc=0
"$@" || rc=$?
: > "$W"
exit "$rc"
