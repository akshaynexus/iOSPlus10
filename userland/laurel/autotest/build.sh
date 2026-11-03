#!/bin/bash
# Builds laurel-autotest (the phone's half of scripts/laurel/ios26-autotest.sh): out/laurel/autotest/laurel-autotest. Plain arm64, minos 16.0, ad hoc, as the other root tools.
# Writes nothing to a device. Quick: not a long job. Linux: the toolchain of userland/ssh/build.sh. macOS: Xcode with the iPhoneOS SDK.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../../scripts/lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
SSH=$OUT/ssh; [ -d "$SSH/sdk" ] || SSH=$MAIN/out/ssh
D=$OUT/laurel/autotest
mkdir -p "$D"
SRC=$HERE/laurel_autotest.m
ENTS=$HERE/autotest.ents
FLAGS=(-arch arm64 -mios-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -framework Foundation -framework CoreFoundation -framework IOKit -framework IOSurface)
case "$(uname -s)" in
Darwin)
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  "$(xcrun -sdk iphoneos --find clang)" -isysroot "$SDK" "${FLAGS[@]}" "$SRC" -o "$D/laurel-autotest"
  codesign --force -s - --entitlements "$ENTS" "$D/laurel-autotest" ;;
Linux)
  T=${THEOS:-$OUT/laurel-kernel/theos}; [ -x "$T/toolchain/linux/iphone/bin/ld" ] || T=$MAIN/out/laurel-kernel/theos
  TC=$T/toolchain/linux/iphone/bin
  SDK=${IOS_SDK:-$SSH/sdk/iPhoneOS16.5.sdk}
  [ -x "$TC/ld" ] && [ -d "$SDK/usr/include" ] || { echo "autotest build: need $TC/ld (scripts/laurel/kernel-linux.sh) and $SDK (userland/ssh/fetch-sdk.sh)" >&2; exit 1; }
  clang -target arm64-apple-ios16.0 -isysroot "$SDK" --ld-path="$TC/ld" -Wno-unused-command-line-argument "${FLAGS[@]}" "$SRC" -o "$D/laurel-autotest"
  "$TC/ldid" -S"$ENTS" "$D/laurel-autotest" ;;
*) echo "autotest build: macOS or Linux" >&2; exit 1 ;;
esac
python3 -I "$REPO/scripts/laurel/armv80-check.py" "$D/laurel-autotest"
echo "autotest build: $D/laurel-autotest"
