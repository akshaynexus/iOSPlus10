#!/bin/bash
# Open a URL in Safari on the running phone, over SSH (no tap needed). Builds userland/uiopen/uiopen.m for
# iOS arm64 (ad hoc signed with uiopen.entitlements), pushes it to /usr/local/bin/uiopen when the phone's
# copy differs, then runs it. The phone shows the URL in the foreground app that owns the scheme (Safari).
#   scripts/net/phone-open-url.sh https://get.webgl.org
#   scripts/net/phone-open-url.sh --build-only        build out/uiopen/uiopen, no phone
# Needs Xcode (macOS). Env as scripts/net/ssh-phone.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
HERE=$REPO/userland/uiopen
W=$OUT/uiopen
mkdir -p "$W"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_15.4.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode_15.4.app/Contents/Developer
fi
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
if [ ! -f "$W/uiopen" ] || [ "$HERE/uiopen.m" -nt "$W/uiopen" ] || [ "$HERE/uiopen.entitlements" -nt "$W/uiopen" ]; then
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -Wall -fobjc-arc -framework Foundation \
    "$HERE/uiopen.m" -o "$W/uiopen"
  codesign --force -s - --entitlements "$HERE/uiopen.entitlements" "$W/uiopen"
  shasum -a 256 "$W/uiopen"
fi
[ "${1:-}" = --build-only ] && exit 0
url=${1:?usage: $0 URL}
SSHP=$REPO/scripts/net/ssh-phone.sh
local_sum=$(shasum -a 256 "$W/uiopen" | cut -c1-64)
remote_sum=$("$SSHP" 'sha256sum /usr/local/bin/uiopen 2>/dev/null | cut -c1-64' </dev/null || true)
if [ "$local_sum" != "$remote_sum" ]; then
  "$SSHP" push "$W/uiopen" /private/var/tmp/uiopen
  "$SSHP" 'mv /private/var/tmp/uiopen /usr/local/bin/uiopen && chmod 755 /usr/local/bin/uiopen' </dev/null
fi
"$SSHP" "/usr/local/bin/uiopen '$url'" </dev/null
