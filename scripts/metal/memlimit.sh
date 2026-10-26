#!/bin/bash
# Print the jetsam memory limit and the footprint of processes on the phone (userland/metal/tools/memlimit.c).
#   scripts/metal/memlimit.sh [PID|NAME]...      (no argument: every process)
# Builds out/metal/bin/memlimit for iOS arm64 (scripts/metal/env.sh) and runs it as root through scripts/net/phone-run.sh -s.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
mkdir -p "$MOUT/bin"
SRC=$REPO/userland/metal/tools/memlimit.c
BIN=$MOUT/bin/memlimit
if [ ! -f "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min="$IOS_MIN" -isysroot "$SDK" -O2 -Wall -o "$BIN" "$SRC"
fi
exec "$REPO/scripts/net/phone-run.sh" -s "$BIN" "$@"
