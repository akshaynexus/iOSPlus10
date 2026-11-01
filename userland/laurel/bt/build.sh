#!/bin/bash
# Build the Mi A3 Bluetooth userland (kernel side: patches/laurel/xnu/2600, docs/laurel_sprout/bluetooth.md):
# the BlueTool stand-in userland/bluetooth/negroni-bluetool.c (bluetoothd asks com.apple.BlueTool to boot the
# chip; the kernel already did it, so every script request answers result 0), with the WCN3990 firmware string.
#   userland/laurel/bt/build.sh          (a few seconds; no tmux needed)
# Linux: the theos iPhone toolchain (clang, ld64, ldid) and MacOSX13.3.sdk headers that scripts/laurel/kernel-linux.sh
#        downloads into out/laurel-kernel/{theos,deps}; the link uses a libSystem text stub (.tbd) made from the
#        object's undefined symbols (libxpc, libdispatch, blocks and libc are all re-exported by libSystem).
# macOS: Xcode's iPhoneOS SDK + codesign.
# Output: out/laurel/bt/negroni-bluetool (arm64 executable, minos 16.0, ad hoc signed with
#         userland/bluetooth/entitlements.plist) + out/laurel/bt/SHA256SUMS.
# Install into a root: scripts/laurel/root-bt.sh (root.sh calls it).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SRC=$REPO/userland/bluetooth
OUT=$REPO/out/laurel/bt
W=$OUT/build
BIN=negroni-bluetool
MINOS=16.0
CFLAGS="-O2 -Wall -fblocks"
FW='-DFIRMWARE="WCN3990 crbtfw21.tlv + crnv21.bin (loaded by the kernel, laurel 2600)"'
rm -rf "$W" "$OUT/$BIN"
mkdir -p "$W"

if [ "$(uname -s)" = Darwin ] && xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  CC=$(xcrun -sdk iphoneos --find clang)
  (cd "$OUT" && "$CC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS $CFLAGS "$FW" "$SRC/$BIN.c" -o $BIN)
  NM="xcrun nm"; OTOOL="xcrun otool"
  sign() { codesign --force -s - --entitlements "$SRC/entitlements.plist" "$1"; }
else
  TC=$REPO/out/laurel-kernel/theos/toolchain/linux/iphone/bin
  SDK=$REPO/out/laurel-kernel/deps/MacOSX13.3.sdk
  for f in "$TC/clang" "$TC/ld" "$TC/ldid" "$TC/llvm-nm" "$SDK/usr/include/xpc/xpc.h"; do
    [ -e "$f" ] || { echo "bt: missing $f (run scripts/laurel/kernel-linux.sh once: it fetches theos + the SDK)" >&2; exit 1; }
  done
  # headers: the macOS SDK's (libxpc, libdispatch, libc); the target is iOS 16 arm64
  "$TC/clang" -target arm64-apple-ios$MINOS -isysroot "$SDK" -Wno-incompatible-sysroot $CFLAGS "$FW" \
    -c "$SRC/$BIN.c" -o "$W/$BIN.o"
  R=$W/sysroot
  mkdir -p "$R/usr/lib"
  syms=$("$TC/llvm-nm" -u "$W/$BIN.o" | awk '{print $NF}' | paste -sd, - | sed 's/,/, /g')
  printf -- '--- !tapi-tbd-v3\narchs: [ arm64 ]\nplatform: ios\ninstall-name: /usr/lib/libSystem.B.dylib\ncurrent-version: 1311\ncompatibility-version: 1\nexports:\n  - archs: [ arm64 ]\n    symbols: [ dyld_stub_binder, %s ]\n...\n' \
    "$syms" > "$R/usr/lib/libSystem.tbd"
  # relative -o: ld writes the output path into LC_UUID (same bytes in every checkout)
  (cd "$OUT" && "$TC/clang" -target arm64-apple-ios$MINOS -fuse-ld="$TC/ld" -B"$TC" -isysroot "$R" -nostdlib \
    -lSystem "$W/$BIN.o" -o $BIN)
  NM="$TC/llvm-nm"; OTOOL="$TC/otool"
  sign() { "$TC/ldid" -S"$SRC/entitlements.plist" "$1"; }
fi

# checks: arm64 executable, minos 16.0, libSystem only
fail=0
file "$OUT/$BIN" | grep -q 'Mach-O 64-bit arm64 executable' || { echo "bt: not an arm64 executable" >&2; fail=1; }
minos=$($OTOOL -l "$OUT/$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "bt: minos $minos, expected $MINOS" >&2; fail=1; }
libs=$($OTOOL -L "$OUT/$BIN" | tail -n +2 | awk '{print $1}' | tr '\n' ' ')
[ "$libs" = "/usr/lib/libSystem.B.dylib " ] || { echo "bt: unexpected libraries: $libs" >&2; fail=1; }
$NM -u "$OUT/$BIN" | grep -q '_xpc_connection_create_mach_service$' || { echo "bt: no XPC listener import" >&2; fail=1; }
[ $fail = 0 ] || exit 1
# launchd job com.apple.BlueTool: platform-application + no-sandbox (as negroni)
sign "$OUT/$BIN"
rm -rf "$W"
(cd "$OUT" && { sha256sum $BIN 2>/dev/null || shasum -a 256 $BIN; } > SHA256SUMS)
echo "bt: $OUT/$BIN ($(wc -c < "$OUT/$BIN") bytes, minos $minos)"
