#!/bin/sh
# Build XNUtils.app (the owner's app, formerly PowerMenu.app) and its root helper for iOS 16 arm64
# (userland/rebootapp/README.md). The app name comes from CFBundleExecutable in Info.plist.
# macOS + Xcode only (iPhoneOS SDK, codesign); scripts/ios16/root-add-powermenu.sh then installs
# the result on macOS or Linux.
#   userland/rebootapp/build.sh            (a few seconds; scripts/bg.sh powermenu-build ... also works)
# Output (out/powermenu/):
#   XNUtils.app/        main.m + Info.plist (dev.iosplus10.xnutils), arm64, minos 16.0, ad hoc signed
#                       with entitlements.plist
#   powermenu-helper    setuid-root helper (restart/shutdown/bootloader), signed with helper.entitlements
#   pmregister          LaunchServices register tool for a running phone, signed with pmregister.entitlements
#   SHA256SUMS
# Reproducible: the same sources and Xcode give the same bytes in every checkout. ld writes the
# output path into LC_UUID, so each binary is linked in out/powermenu/build with a relative -o.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/powermenu
B=$W/build
MINOS=16.0

[ "$(uname -s)" = Darwin ] || { echo "build.sh needs macOS with Xcode (iPhoneOS SDK)" >&2; exit 1; }
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICC=$(xcrun -sdk iphoneos --find clang)
T="-target arm64-apple-ios$MINOS -isysroot $SDK"
APP=$(plutil -extract CFBundleExecutable raw "$HERE/Info.plist")   # XNUtils
# PowerMenu.app: the old name of the app (before 2026-10-25 19:32); remove it so no hook installs it.
rm -rf "$B" "$W/PowerMenu.app" "$W/$APP.app" "$W/powermenu-helper" "$W/pmregister" "$W/SHA256SUMS"
mkdir -p "$B"

# ---- compile + link (relative output names, see above) ----------------------------------------
# The app: same flags as the owner's hand builds (no -O; XNUtils adds -framework Metal), which this
# script reproduces.
(cd "$B" &&
 "$ICC" $T -fobjc-arc -framework UIKit -framework Foundation -framework QuartzCore -framework Metal "$HERE/main.m" -o "$APP" &&
 "$ICC" $T -O2 -Wall -Wno-deprecated-declarations "$HERE/powermenu-helper.c" -o powermenu-helper &&
 "$ICC" $T -O2 -Wall -fobjc-arc -framework Foundation "$HERE/pmregister.m" -o pmregister)

# ---- bundle + signing -------------------------------------------------------------------------
A=$W/$APP.app
mkdir -p "$A"
cp "$B/$APP" "$A/$APP"
cp "$HERE/Info.plist" "$A/Info.plist"
chmod 755 "$A" "$A/$APP"; chmod 644 "$A/Info.plist"
codesign --force -s - --entitlements "$HERE/entitlements.plist" "$A" 2>/dev/null
for t in powermenu-helper pmregister; do
  cp "$B/$t" "$W/$t"; chmod 755 "$W/$t"
done
codesign --force -s - --entitlements "$HERE/helper.entitlements" "$W/powermenu-helper" 2>/dev/null
codesign --force -s - --entitlements "$HERE/pmregister.entitlements" "$W/pmregister" 2>/dev/null

# ---- checks -----------------------------------------------------------------------------------
fail=0
plutil -lint "$A/Info.plist" >/dev/null || { echo "Info.plist: not a valid plist" >&2; fail=1; }
bid=$(plutil -extract CFBundleIdentifier raw "$A/Info.plist")
[ "$bid" = dev.iosplus10.xnutils ] || { echo "CFBundleIdentifier is $bid, not dev.iosplus10.xnutils" >&2; fail=1; }
codesign --verify --strict "$A" || { echo "$APP.app: signature check failed" >&2; fail=1; }
for b in "$A/$APP" "$W/powermenu-helper" "$W/pmregister"; do
  f=$(basename "$b")
  lipo -archs "$b" | grep -qx arm64 || { echo "$f: not arm64-only" >&2; fail=1; }
  minos=$(otool -l "$b" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  [ "$minos" = "$MINOS" ] || { echo "$f: minos $minos, expected $MINOS" >&2; fail=1; }
  # weak imports = symbols the SDK knows but iOS 16 may not have (they resolve to NULL there)
  weak=$(nm -m "$b" | grep 'weak external' || true)
  [ -z "$weak" ] || { echo "$f: weak imports (symbols newer than iOS $MINOS?):" >&2; echo "$weak" >&2; fail=1; }
done
# The negroni AMFI stand-in reads the XML entitlements blob (DER-only signatures get none).
python3 -I - "$A/$APP" "$W/powermenu-helper" "$W/pmregister" <<'EOF' || fail=1
import struct, sys
bad = 0
for p in sys.argv[1:]:
    d = open(p, 'rb').read()
    ncmds = struct.unpack_from('<I', d, 16)[0]; off = 32; cs = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x1d: cs = struct.unpack_from('<II', d, off + 8)
        off += size
    if cs is None: print(p, 'no code signature'); bad = 1; continue
    o = cs[0]; n = struct.unpack_from('>I', d, o + 8)[0]
    kinds = [struct.unpack_from('>II', d, o + 12 + 8 * i) for i in range(n)]
    magics = {struct.unpack_from('>I', d, o + bo)[0] for _, bo in kinds}
    if 0xfade7171 not in magics: print(p, 'no XML entitlements blob'); bad = 1
sys.exit(bad)
EOF
[ $fail = 0 ] || { echo "checks failed" >&2; exit 1; }

(cd "$W" && shasum -a 256 "$APP.app/$APP" "$APP.app/Info.plist" "$APP.app/_CodeSignature/CodeResources" \
   powermenu-helper pmregister > SHA256SUMS)
echo "$APP.app + helper + pmregister (arm64, minos $MINOS, ad hoc signed, XML entitlements present):"
cat "$W/SHA256SUMS"
