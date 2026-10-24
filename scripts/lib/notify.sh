#!/bin/sh
# Desktop notification (macOS: terminal-notifier or osascript; Linux: notify-send). Never fails.
#   scripts/lib/notify.sh "message" [title]
msg=${1:-done}; title=${2:-iOSPlus10}
if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier -title "$title" -message "$msg" -group iosplus10 >/dev/null 2>&1 || true
elif [ "$(uname -s)" = Darwin ]; then
  osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "$title" "$msg" || true
fi
exit 0
