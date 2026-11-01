#!/bin/bash
# Build XNUtils.app for the Mi A3 on Linux (no Mac, no Xcode): userland/laurel/xnutils, docs/laurel_sprout/xnutils.md.
#   scripts/laurel/xnutils-build.sh          (a few seconds; build-all.sh runs it)
# Toolchain = scripts/laurel/gpu-env.sh (stock clang + theos cctools ld64/ldid + iPhoneOS16.5.sdk); another checkout's copies can be
# used with THEOS=... SDK=... Checks: arm64 only, no instruction newer than ARMv8.0, XML entitlements blob, no Metal in the app.
# Output: out/laurel/xnutils/root/ = what scripts/laurel/root-xnutils.sh installs, laid out as on the phone:
#   Applications/XNUtils.app/{XNUtils,Info.plist,AppIcon60x60@2x.png}  usr/local/libexec/powermenu-helper  usr/local/bin/pmregister
#   (+ out/laurel/xnutils/root.SHA256SUMS)
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
gpu_fetch_sdk
S=$REPO/userland/laurel/xnutils
OLD=$REPO/userland/rebootapp
N=$OUT/laurel/xnutils
# XNUTILS_IOS26=1: the iOS 26 root's copy, with the Metal options + bench (helper_ios26.c, bench.m). The default build has neither.
XT_APP_EXTRA=() XT_HELPER_EXTRA=() XT_FLAGS=()
if [ "${XNUTILS_IOS26:-0}" = 1 ]; then
  N=$OUT/ios26/xnutils
  XT_FLAGS=(-DXT_IOS26=1)
  XT_APP_EXTRA=("$S/bench.m" -framework QuartzCore)
  XT_HELPER_EXTRA=("$S/helper_ios26.c")
fi
R=$N/root
A=$R/Applications/XNUtils.app
DSYM=$N/dsym                      # (gpu_dsym writes here)
rm -rf "$R" "$N/obj"
mkdir -p "$A" "$R/usr/local/libexec" "$R/usr/local/bin" "$N/obj"

# -sdk_version: ld64 reads an SDK version from digits in the -syslibroot path otherwise (a worktree path, docs/notes.md gotcha)
LDFLAGS="-Wl,-sdk_version,16.5"
cc_log() { # NAME OUT ARGS...: warnings stop the build, as in notch-build.sh
  local name=$1 out=$2; shift 2
  gpu_cc "$out" $LDFLAGS "$@" 2> "$N/obj/$name.log" || { cat "$N/obj/$name.log"; gpu_die "$name did not build"; }
  [ ! -s "$N/obj/$name.log" ] || { cat "$N/obj/$name.log"; gpu_die "compiler warnings in $name"; }
}
cc_log app "$A/XNUtils" -Wextra -Wno-unused-parameter -fobjc-arc -framework UIKit -framework Foundation -framework CoreGraphics \
  "${XT_FLAGS[@]+"${XT_FLAGS[@]}"}" "$S/main.m" "$S/list.m" "$S/stream.m" "${XT_APP_EXTRA[@]+"${XT_APP_EXTRA[@]}"}"
cc_log helper "$R/usr/local/libexec/powermenu-helper" -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -I"$S" \
  -framework CoreFoundation -framework IOKit "${XT_FLAGS[@]+"${XT_FLAGS[@]}"}" "${XT_HELPER_EXTRA[@]+"${XT_HELPER_EXTRA[@]}"}" \
  "$S/helper.c" "$S/helper_files.c" "$S/collect_ios.c" "$S/collect_files.c" "$S/collect_procs.c" "$S/collect_dev.c" \
  "$S/report_core.c" "$S/report_row.c" "$S/report_gfx.c" "$S/report_sys.c" "$S/report_io.c"
cc_log pmregister "$R/usr/local/bin/pmregister" -fobjc-arc -framework Foundation "$OLD/pmregister.m"
install -m 644 "$S/Info.plist" "$A/Info.plist"
python3 -I "$S/mkicon.py" "$A/AppIcon60x60@2x.png"

gpu_dsym "$A/XNUtils"
gpu_dsym "$R/usr/local/libexec/powermenu-helper"
gpu_dsym "$R/usr/local/bin/pmregister"
"$LDID" -S"$OLD/entitlements.plist" "$A/XNUtils"
"$LDID" -S"$OLD/helper.entitlements" "$R/usr/local/libexec/powermenu-helper"
"$LDID" -S"$OLD/pmregister.entitlements" "$R/usr/local/bin/pmregister"

fail=0
for f in "$A/XNUtils" "$R/usr/local/libexec/powermenu-helper" "$R/usr/local/bin/pmregister"; do
  gpu_check_v80 "$f" || { echo "xnutils-build: $(basename "$f") has ARMv8.1+ instructions" >&2; fail=1; }
done
# The screen must draw without Metal [owner]: neither the app nor the helper may link it
if llvm-objdump --macho --dylibs-used "$A/XNUtils" "$R/usr/local/libexec/powermenu-helper" | grep -iE 'Metal|OpenGLES'; then
  echo "xnutils-build: links Metal or GL" >&2; fail=1
fi
# The kernel's AMFI stand-in reads the XML entitlements blob (DER-only signatures get none)
python3 -I - "$A/XNUtils" "$R/usr/local/libexec/powermenu-helper" "$R/usr/local/bin/pmregister" <<'EOF' || fail=1
import struct, sys
bad = 0
for p in sys.argv[1:]:
    d = open(p, 'rb').read()
    magic, cpu = struct.unpack_from('<Ii', d)
    if magic != 0xfeedfacf or cpu != 0x0100000c: print(p, 'not thin arm64'); bad = 1; continue
    ncmds = struct.unpack_from('<I', d, 16)[0]; off = 32; cs = None; minos = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x1d: cs = struct.unpack_from('<II', d, off + 8)
        if cmd == 0x32: minos = struct.unpack_from('<I', d, off + 12)[0]
        off += size
    if minos != 0x100000: print(p, 'minos is not 16.0:', hex(minos or 0)); bad = 1
    if cs is None: print(p, 'no code signature'); bad = 1; continue
    o = cs[0]; n = struct.unpack_from('>I', d, o + 8)[0]
    magics = {struct.unpack_from('>I', d, o + bo)[0] for _, bo in (struct.unpack_from('>II', d, o + 12 + 8 * i) for i in range(n))}
    if 0xfade7171 not in magics: print(p, 'no XML entitlements blob'); bad = 1
sys.exit(bad)
EOF
python3 -I -c 'import plistlib, sys; p = plistlib.load(open(sys.argv[1], "rb")); assert p["CFBundleIdentifier"] == "dev.iosplus10.xnutils" and p["CFBundleExecutable"] == "XNUtils" and "UILaunchScreen" in p' "$A/Info.plist" ||
  { echo "xnutils-build: Info.plist: not as root-xnutils.sh and the helper expect" >&2; fail=1; }
[ $fail = 0 ] || exit 1
# the layout of out/powermenu, for scripts/net/phone-add-powermenu.sh on a running phone (POWERMENU_OUT)
rm -rf "$N/flat"; mkdir -p "$N/flat"
cp -R "$A" "$N/flat/XNUtils.app"
cp "$R/usr/local/libexec/powermenu-helper" "$R/usr/local/bin/pmregister" "$N/flat/"
(cd "$R" && find . -type f | sort | { while read -r f; do gpu_sha256_files "$f"; done; } > "$N/root.SHA256SUMS")
cat "$N/root.SHA256SUMS"
ls -l "$A/XNUtils" "$R/usr/local/libexec/powermenu-helper" "$R/usr/local/bin/pmregister" | awk '{print $5, $9}'
echo "xnutils-build: $R (root-xnutils.sh installs it)"
