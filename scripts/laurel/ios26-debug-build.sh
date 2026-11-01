#!/bin/bash
# The debug tools that only the iOS 26 first-boot root has: out/laurel/debug/ios/ksysctl (userland/ssh/ksysctl.c). The rest comes from out/ssh/ios (userland/ssh/build.sh), as on iOS 16.
#   scripts/bg.sh ios26-debug-build scripts/laurel/ios26-debug-build.sh
# Plain arm64, minos 16.0, ad hoc (ldid), as the other tools; a check of every tool against 23F84 follows: scripts/laurel/ios26-injected-check.py. Writes nothing to a device.
# Linux: the toolchain of userland/ssh/build.sh. macOS: Xcode with the iPhoneOS SDK.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
SSH=$OUT/ssh; [ -x "$SSH/ios/dropbearmulti" ] || SSH=$MAIN/out/ssh
D=$OUT/laurel/debug/ios
mkdir -p "$D"
case "$(uname -s)" in
Darwin)
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  "$(xcrun -sdk iphoneos --find clang)" -arch arm64 -isysroot "$SDK" -mios-version-min=16.0 -O2 -Wall "$REPO/userland/ssh/ksysctl.c" -o "$D/ksysctl"
  codesign --force -s - --entitlements "$REPO/userland/ssh/entitlements.plist" "$D/ksysctl" ;;
Linux)
  T=${THEOS:-$OUT/laurel-kernel/theos}; [ -x "$T/toolchain/linux/iphone/bin/ld" ] || T=$MAIN/out/laurel-kernel/theos
  TC=$T/toolchain/linux/iphone/bin
  SDK=${IOS_SDK:-$SSH/sdk/iPhoneOS16.5.sdk}
  [ -x "$TC/ld" ] && [ -d "$SDK/usr/include" ] || { echo "ios26-debug-build: need $TC/ld (scripts/laurel/kernel-linux.sh) and $SDK (userland/ssh/fetch-sdk.sh)" >&2; exit 1; }
  clang -target arm64-apple-ios16.0 -arch arm64 -isysroot "$SDK" -mios-version-min=16.0 --ld-path="$TC/ld" -Wno-unused-command-line-argument -O2 -Wall "$REPO/userland/ssh/ksysctl.c" -o "$D/ksysctl"
  "$TC/ldid" -S"$REPO/userland/ssh/entitlements.plist" "$D/ksysctl" ;;
*) echo "ios26-debug-build: macOS or Linux" >&2; exit 1 ;;
esac
python3 -I "$REPO/scripts/laurel/armv80-check.py" "$D/ksysctl"
# every tool that goes into the first-boot root, against the 23F84 cache. Slow (minutes): CHECK=0 skips it
if [ "${CHECK:-1}" != 0 ]; then
  (cd "$SSH/ios" && python3 -I "$REPO/scripts/laurel/ios26-injected-check.py" "$PWD/dropbearmulti" "$PWD/dash" "$PWD/toybox" "$PWD/usbnetcfg" "$PWD/laurelnet" "$PWD/usbreboot" "$PWD/oslogstream" "$D/ksysctl")
fi
echo "ios26-debug-build: $D/ksysctl"
