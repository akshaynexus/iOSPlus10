#!/bin/bash
# Build userland/metal/probes/angleprobe.m (WebKit's ANGLE Metal WebGL path as a CLI; header of that file), push it to
# the phone as /usr/local/bin/angleprobe when the copy differs, run it and print the plugin log lines it caused.
#   scripts/metal/angleprobe.sh [--es2|--es3] [--no-iosurface]      run on the phone (log: logs/angleprobe-<time>.log)
#   scripts/metal/angleprobe.sh --build-only
# Env: ANGLEPROBE_TIMEOUT_S (watchdog, default 15). Needs Xcode; env as scripts/net/ssh-phone.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
SRC=$REPO/userland/metal/probes/angleprobe.m
W=$OUT/metal/angleprobe
mkdir -p "$W" "$REPO/logs"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_15.4.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode_15.4.app/Contents/Developer
fi
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
if [ ! -f "$W/angleprobe" ] || [ "$SRC" -nt "$W/angleprobe" ]; then
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" -O1 -g -Wall -fobjc-arc -framework Foundation -framework IOSurface \
    "$SRC" -o "$W/angleprobe"
  codesign --force -s - "$W/angleprobe"
  shasum -a 256 "$W/angleprobe"
fi
[ "${1:-}" = --build-only ] && exit 0
SSHP=$REPO/scripts/net/ssh-phone.sh
local_sum=$(shasum -a 256 "$W/angleprobe" | cut -c1-64)
remote_sum=$("$SSHP" 'sha256sum /usr/local/bin/angleprobe 2>/dev/null | cut -c1-64' </dev/null || true)
if [ "$local_sum" != "$remote_sum" ]; then
  "$SSHP" push "$W/angleprobe" /private/var/tmp/angleprobe
  "$SSHP" 'mv /private/var/tmp/angleprobe /usr/local/bin/angleprobe && chmod 755 /usr/local/bin/angleprobe' </dev/null
fi
LOG=$REPO/logs/angleprobe-$(date +%Y%m%d-%H%M%S).log
before=$("$SSHP" 'wc -l < /private/var/db/negronimetal/metal.log' </dev/null | tr -d ' ')
set +e
"$SSHP" "ANGLEPROBE_TIMEOUT_S=${ANGLEPROBE_TIMEOUT_S:-15} /usr/local/bin/angleprobe $*" </dev/null 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "== metal.log lines of this run (exit $rc) ==" | tee -a "$LOG"
"$SSHP" "sed -n '$((before + 1)),\$p' /private/var/db/negronimetal/metal.log | grep -v 'A730 answer'" </dev/null | tee -a "$LOG"
echo "(saved: $LOG)"
exit "$rc"
