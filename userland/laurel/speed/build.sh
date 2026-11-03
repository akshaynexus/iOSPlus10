#!/bin/bash
# Builds laurel-speed (userland/laurel/speed/laurel_speed.c): out/laurel/speed/laurel-speed. Plain arm64, ARMv8.0, minos 16.0, ad hoc signed,
# as laurel-autotest. Writes nothing to a device. Linux: the toolchain of userland/ssh/build.sh. macOS: Xcode with the iPhoneOS SDK.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../../scripts/lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
SSH=$OUT/ssh; [ -d "$SSH/sdk" ] || SSH=$MAIN/out/ssh
D=$OUT/laurel/speed
mkdir -p "$D"
SRC=$HERE/laurel_speed.c
FLAGS=(-arch arm64 -march=armv8-a -mios-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter)
case "$(uname -s)" in
Darwin)
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  "$(xcrun -sdk iphoneos --find clang)" -isysroot "$SDK" "${FLAGS[@]}" "$SRC" -o "$D/laurel-speed"
  codesign --force -s - "$D/laurel-speed" ;;
Linux)
  T=${THEOS:-$OUT/laurel-kernel/theos}; [ -x "$T/toolchain/linux/iphone/bin/ld" ] || T=$MAIN/out/laurel-kernel/theos
  TC=$T/toolchain/linux/iphone/bin
  SDK=${IOS_SDK:-$SSH/sdk/iPhoneOS16.5.sdk}
  [ -x "$TC/ld" ] && [ -d "$SDK/usr/include" ] || { echo "speed build: need $TC/ld (scripts/laurel/kernel-linux.sh) and $SDK (userland/ssh/fetch-sdk.sh)" >&2; exit 1; }
  clang -target arm64-apple-ios16.0 -isysroot "$SDK" --ld-path="$TC/ld" -Wno-unused-command-line-argument "${FLAGS[@]}" "$SRC" -o "$D/laurel-speed"
  "$TC/ldid" -S "$D/laurel-speed" ;;
*) echo "speed build: macOS or Linux" >&2; exit 1 ;;
esac
python3 -I "$REPO/scripts/laurel/armv80-check.py" "$D/laurel-speed"
echo "speed build: $D/laurel-speed"
