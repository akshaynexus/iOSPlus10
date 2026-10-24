#!/bin/sh
# Run a long command in a detached tmux session, independent of the calling shell or agent.
#
#   scripts/bg.sh NAME COMMAND...     start (fails if session NAME exists)
#   scripts/bg.sh -s NAME             status: running/finished + last log lines
#   scripts/bg.sh -l                  list sessions
#
# Output goes to logs/NAME.log (git-ignored). When the command ends, logs/NAME.exit holds its
# exit code and the session closes. Attach with: tmux attach -t NAME
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
LOGS=$REPO/logs
mkdir -p "$LOGS"

case "${1:-}" in
-l) tmux ls 2>/dev/null || echo "no sessions"; exit 0 ;;
-s)
  n=$2
  if tmux has-session -t "$n" 2>/dev/null; then echo "$n: running"; else
    echo "$n: finished, exit $(cat "$LOGS/$n.exit" 2>/dev/null || echo '?')"; fi
  tail -n "${3:-15}" "$LOGS/$n.log" 2>/dev/null || true
  exit 0 ;;
""|-h) sed -n 2,10p "$0"; exit 1 ;;
esac

n=$1; shift
if tmux has-session -t "$n" 2>/dev/null; then echo "session $n already running" >&2; exit 1; fi
rm -f "$LOGS/$n.exit"
# The command goes into a file, so quotes in it need no escaping.
{ echo "cd '$REPO' || exit 1"; for a in "$@"; do printf "'%s' " "$(printf '%s' "$a" | sed "s/'/'\\\\''/g")"; done; echo; } > "$LOGS/$n.cmd"
tmux new-session -d -s "$n" -c "$REPO" \
  "sh '$LOGS/$n.cmd' > '$LOGS/$n.log' 2>&1; echo \$? > '$LOGS/$n.exit'"
echo "started $n (log: logs/$n.log)"
