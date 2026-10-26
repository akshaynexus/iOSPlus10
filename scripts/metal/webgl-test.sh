#!/bin/bash
# WebGL probe on the phone without a tap: serve userland/metal/webtest/ from the Mac on the USB link
# (192.168.7.1:8765), open the page in Safari with scripts/net/phone-open-url.sh, and print what the page
# reports (context ok/null, renderer, draw read-back, 60-frame time). Lines go to logs/webgl-test-<time>.log.
#   scripts/metal/webgl-test.sh [PAGE]        default webgl-test.html; also serves other files in webtest/
#   scripts/metal/webgl-test.sh --serve        only the server (foreground; for tmux: scripts/bg.sh webgl-serve ...)
# Needs: python3, the USB link up (docs/usb-network.md), Xcode for uiopen.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=${WEBTEST_HOST:-192.168.7.1}; PORT=${WEBTEST_PORT:-8765}
mkdir -p "$REPO/logs"
if [ "${1:-}" = --serve ]; then
  cd "$REPO/userland/metal/webtest"
  exec python3 -I "$REPO/scripts/metal/webgl-report-server.py" "$HOST" "$PORT" "$REPO/logs/webgl-report.log"
fi
page=${1:-webgl-test.html}
if ! curl -s -m 2 "http://$HOST:$PORT/$page" >/dev/null; then
  "$REPO/scripts/bg.sh" webgl-serve "$REPO/scripts/metal/webgl-test.sh" --serve
  sleep 1
fi
: > "$REPO/logs/webgl-report.log"
"$REPO/scripts/net/phone-open-url.sh" "http://$HOST:$PORT/$page?r=$(date +%s)"
echo "waiting 20 s for reports"; sleep 20
LOG=$REPO/logs/webgl-test-$(date +%Y%m%d-%H%M%S).log
cp "$REPO/logs/webgl-report.log" "$LOG"; cat "$LOG"; echo "(saved: $LOG)"
