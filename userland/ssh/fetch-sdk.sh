#!/bin/sh
# Linux (and macOS without Xcode): the iPhoneOS 16.5 SDK for userland/ssh/build.sh, from theos/sdks
# (the SDK hackios-scion userland/build.sh and theos use). Only the one directory is fetched (sparse,
# blobless clone at a pinned commit: git checks every object against the commit hash).
#   userland/ssh/fetch-sdk.sh        (in tmux: scripts/bg.sh ssh-sdk userland/ssh/fetch-sdk.sh)
# Output: out/ssh/sdk/iPhoneOS16.5.sdk (Apple SDK headers and .tbd stubs: never in git; out/ is ignored).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$REPO/out/ssh/sdk
SDKS_SHA=0222fd5413cf4b9af096f37b4621afa2688572f7     # theos/sdks master, 2026-11-01
NAME=iPhoneOS16.5.sdk
if [ -f "$W/$NAME/SDKSettings.json" ] || [ -f "$W/$NAME/SDKSettings.plist" ]; then
  echo "fetch-sdk: $W/$NAME already there"; exit 0
fi
rm -rf "$W/.git-sdks"
mkdir -p "$W"
git init -q "$W/.git-sdks"
git -C "$W/.git-sdks" remote add origin https://github.com/theos/sdks.git
git -C "$W/.git-sdks" sparse-checkout set --no-cone "/$NAME/"
git -C "$W/.git-sdks" fetch -q --depth 1 --filter=blob:none origin "$SDKS_SHA"
git -C "$W/.git-sdks" checkout -q FETCH_HEAD
[ "$(git -C "$W/.git-sdks" rev-parse HEAD)" = "$SDKS_SHA" ] || { echo "fetch-sdk: wrong commit" >&2; exit 1; }
rm -rf "${W:?}/$NAME"
mv "$W/.git-sdks/$NAME" "$W/$NAME"
rm -rf "$W/.git-sdks"
echo "fetch-sdk: $W/$NAME (theos/sdks $SDKS_SHA)"
