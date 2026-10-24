#!/bin/sh
# Install Xcode 15.4 next to the default Xcode, for local xnu-8796 kernel builds (macOS only).
#   scripts/kernel/install-xcode15.sh [XIP]      (run in tmux: make xcode15)
# xnu-8796 needs Xcode 15's iig: Xcode 16+ emits IORPC.kernelContent, which this xnu lacks.
# XIP default: ~/Downloads/Xcode_15.4.xip (developer.apple.com/download/all, Apple ID needed).
# Result: /Applications/Xcode_15.4.app. xcode-select is NOT changed; the build uses DEVELOPER_DIR.
set -eu
. "$(dirname "$0")/../lib/env.sh"
XIP=${1:-$HOME/Downloads/Xcode_15.4.xip}
APP=${XCODE15_APP:-/Applications/Xcode_15.4.app}
if [ -d "$APP" ]; then
  echo "already installed: $APP"
else
  [ -f "$XIP" ] || { echo "missing $XIP" >&2; exit 1; }
  echo "checking the Apple signature of $XIP"
  pkgutil --check-signature "$XIP" | tee /dev/stderr | grep -q "Status: signed Apple Software" || { echo "bad signature" >&2; exit 1; }
  # expand next to the destination (same volume: the final mv is a rename)
  W=$(dirname "$APP")/.xcode15-expand.$$
  mkdir -p "$W"
  (cd "$W" && xip --expand "$XIP")
  mv "$W/Xcode.app" "$APP"
  rmdir "$W"
fi
export DEVELOPER_DIR="$APP/Contents/Developer"
xcodebuild -version
xcrun --find iig
# the license must be accepted once per Xcode version (needs sudo)
xcodebuild -checkFirstLaunchStatus 2>/dev/null || echo "run once: sudo DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -license accept && sudo DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -runFirstLaunch"
