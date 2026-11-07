#!/bin/bash
# Builds laurel-memhog (the memory load of scripts/laurel/mem-load.sh): out/laurel/memhog/laurel-memhog. Plain arm64, minos 16.0, ad hoc, as the other root tools. Quick, host only.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../../scripts/lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
SSH=$OUT/ssh; [ -d "$SSH/sdk" ] || SSH=$MAIN/out/ssh
D=$OUT/laurel/memhog
mkdir -p "$D"
SRC=$HERE/memhog.c
FLAGS=(-arch arm64 -mios-version-min=16.0 -O2 -Wall -Wextra)
case "$(uname -s)" in
Darwin)
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  "$(xcrun -sdk iphoneos --find clang)" -isysroot "$SDK" "${FLAGS[@]}" "$SRC" -o "$D/laurel-memhog"
  codesign --force -s - "$D/laurel-memhog" ;;
Linux)
  T=${THEOS:-$OUT/laurel-kernel/theos}; [ -x "$T/toolchain/linux/iphone/bin/ld" ] || T=$MAIN/out/laurel-kernel/theos
  TC=$T/toolchain/linux/iphone/bin
  SDK=${IOS_SDK:-$SSH/sdk/iPhoneOS16.5.sdk}
  [ -x "$TC/ld" ] && [ -d "$SDK/usr/include" ] || { echo "memhog build: need $TC/ld and $SDK (userland/ssh/fetch-sdk.sh)" >&2; exit 1; }
  clang -target arm64-apple-ios16.0 -isysroot "$SDK" --ld-path="$TC/ld" -Wno-unused-command-line-argument "${FLAGS[@]}" "$SRC" -o "$D/laurel-memhog"
  "$TC/ldid" -S "$D/laurel-memhog" ;;
*) echo "memhog build: macOS or Linux" >&2; exit 1 ;;
esac
python3 -I "$REPO/scripts/laurel/armv80-check.py" "$D/laurel-memhog"
echo "memhog build: $D/laurel-memhog"
