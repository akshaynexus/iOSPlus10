#!/bin/bash
# Reproduce the status bar provider analysis of docs/laurel_sprout/rtc-statusbar.md (why iOS 16.7 20H392 draws the
# red rdar:45025538 bar at 360x780 pt) from the iPhone10,3 dyld shared cache. macOS + Linux; needs blacktop/ipsw.
#   scripts/debug/statusbar-re.sh            -> out/re-statusbar/*.s (annotated listings) + a summary on stdout
# Cache: $DSC, else the Cryptex of ~/op10-apple/20H392 mounted read-only with apfs-fuse at out/mnt-cryptex (as
# scripts/debug/smp-symbolize.sh). ipsw: $IPSW, else ipsw in PATH, else out/laurel-metal/ipsw/ipsw (scripts/laurel/
# metal-build.sh fetch). Selector / class names: scripts/debug/dsc-annotate.py (ipsw 3.1 cannot parse this cache's objc).
# First run ~1 min (ipsw builds its symbol cache out/re-statusbar/dsc.a2s, 10.9 M symbols); run it in tmux:
#   scripts/bg.sh statusbar-re scripts/debug/statusbar-re.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
IPSW=${IPSW:-$(command -v ipsw || echo "$here/out/laurel-metal/ipsw/ipsw")}
[ -x "$IPSW" ] || { echo "needs ipsw (brew install blacktop/tap/ipsw, or scripts/laurel/metal-build.sh fetch)" >&2; exit 1; }
if [ -z "${DSC:-}" ]; then
  mnt=$here/out/mnt-cryptex
  if [ ! -d "$mnt/root/System" ]; then
    mkdir -p "$mnt"; apfs-fuse -o ro "$HOME/op10-apple/20H392/087-86593-047.dmg" "$mnt"
  fi
  DSC=$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
fi
[ -f "$DSC" ] || { echo "no shared cache at $DSC (set DSC)" >&2; exit 1; }
W=$here/out/re-statusbar; mkdir -p "$W"
A2S=$W/dsc.a2s

syms() {   # syms IMAGE -> $W/IMAGE-syms.txt
  [ -s "$W/$1-syms.txt" ] || "$IPSW" dyld symaddr "$DSC" --image "$1" > "$W/$1-syms.txt" 2>/dev/null
}
addr() {   # addr IMAGE 'exact symbol' (objc methods, blocks: tab-separated lines; C functions: "(regular) NAME" lines)
  awk -v s="$2" -F'\t' 'index($0, s) && $3 == s { sub(":", "", $1); print $1; exit }' "$W/$1-syms.txt" | grep . ||
    awk -v s="$2" '$2 == "(regular)" && $3 == s { sub(":", "", $1); print $1; exit }' "$W/$1-syms.txt"
}
dis() {    # dis NAME ADDR COUNT
  "$IPSW" dyld disass "$DSC" --vaddr "$2" --count "$3" --cache "$A2S" --quiet 2>/dev/null |
    python3 -I "$here/scripts/debug/dsc-annotate.py" "$DSC" > "$W/$1.s"
  echo "== $1 ($2): $W/$1.s"
}
syms UIKitCore
syms SpringBoard
syms SpringBoardHome
dis get-provider "$(addr UIKitCore '__UIStatusBarGetVisualProviderClassForScreen')" 220
dis ios-subclass "$(addr UIKitCore '+[_UIStatusBarVisualProvider_iOS visualProviderSubclassForScreen:visualProviderInfo:]')" 40
dis phone-subclass "$(addr UIKitCore '+[_UIStatusBarVisualProvider_Phone visualProviderSubclassForScreen:visualProviderInfo:]')" 85
dis split-subclass "$(addr UIKitCore '+[_UIStatusBarVisualProvider_Split visualProviderSubclassForScreen:visualProviderInfo:]')" 120
dis split-match "$(addr UIKitCore '___87+[_UIStatusBarVisualProvider_Split visualProviderSubclassForScreen:visualProviderInfo:]_block_invoke')" 60
dis fixedsplit-width "$(addr UIKitCore '-[_UIStatusBarVisualProvider_FixedSplit nativeDisplayWidth]')" 20
dis fixedsplit-notch "$(addr UIKitCore '-[_UIStatusBarVisualProvider_FixedSplit notchRect]')" 40
dis sb-default-context "$(addr SpringBoard '+[UISDisplayContext(SpringBoard) sb_embeddedDisplayDefaultContext]')" 60
echo "-- Split classes: native width (px) / notch (pt)"
for c in Split828 Split1080 Split1125 Split1170 Split1242 Split1284; do
  w=$(addr UIKitCore "+[_UIStatusBarVisualProvider_$c nativeDisplayWidth]")
  n=$(addr UIKitCore "+[_UIStatusBarVisualProvider_$c notchSize]")
  printf '%-10s %s / %s\n' "$c" \
    "$("$IPSW" dyld disass "$DSC" --vaddr "$w" --count 3 --cache "$A2S" --quiet 2>/dev/null | python3 -I "$here/scripts/debug/dsc-annotate.py" "$DSC" | grep -o 'double [0-9.]*' | head -1)" \
    "$("$IPSW" dyld disass "$DSC" --vaddr "$n" --count 4 --cache "$A2S" --quiet 2>/dev/null | python3 -I "$here/scripts/debug/dsc-annotate.py" "$DSC" | grep -oE 'double [0-9.]*|fmov\s+d1, #[0-9.]*|mov\s+x8, #0x[0-9a-f]+' | tr '\n' ' ')"
done
echo "-- override key and fallback (get-provider.s):"
grep -E 'UIStatusBarVisualProviderClassName|com.apple.UIKit|_Fallback|No status bar|WARNING' "$W"/get-provider.s | sed 's/^.*; //' || true
grep -E 'Jindo|FixedSplit' "$W"/split-subclass.s | sed 's/^.*; //' || true

# --- part C (docs/laurel_sprout/rtc-statusbar.md "C"): where the notch rect, the safe area and the bar height come from
dis sbh-lookup "$(addr SpringBoardHome '__SBHScreenTypeLookup')" 340
dis sb-shape "$(addr SpringBoard '+[UISDisplaySingleRectShape(SpringBoard) sb_displayShapeForScreenType:]')" 140
dis sb-native-scale "$(addr SpringBoard '__SBHNativeScaleForScreenType')" 120
dis sb-embedded-context "$(addr SpringBoard '+[UISDisplayContext(SpringBoard) sb_embeddedDisplayDefaultContext]')" 70
dis sbh-edge-info "$(addr SpringBoardHome '+[UISApplicationSupportDisplayEdgeInfo(SBHScreenTypes) _sbh_displayEdgeInfoForScreenType:]')" 220
dis fixedsplit-centering "$(addr UIKitCore '-[_UIStatusBarVisualProvider_FixedSplit leadingCenteringEdgeInset]')" 40
dis fixedsplit-edge-insets "$(addr UIKitCore '-[_UIStatusBarVisualProvider_FixedSplit _edgeInsetsFromCenteringEdgeInset:trailing:]')" 60
dis split-height "$(addr UIKitCore '+[_UIStatusBarVisualProvider_Split height]')" 3
dis screen-corner-radius "$(addr UIKitCore '___32-[UIScreen _displayCornerRadius]_block_invoke')" 50
echo "-- screen types, the gesture-phone fallback (sbh-lookup.s: size at table+K -> type N; none -> 4) and the size table:"
python3 -I - "$DSC" "$here/scripts/debug/dsc-annotate.py" "$(addr SpringBoardHome '_SBHShortStringForScreenType')" "$W/sbh-lookup.s" <<'PY'
import importlib.util, re, struct, sys
spec = importlib.util.spec_from_file_location('a', sys.argv[2]); a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
c = a.Cache(sys.argv[1])
q = lambda x: struct.unpack('<Q', c.read(x, 8))[0] & 0xfffffffff
def cfstr(p):
    ptr, n = struct.unpack_from('<QQ', c.read(p, 32), 16)
    return c.read(ptr & 0xfffffffff, n).decode('latin1')
def adrp(i, pc):
    imm = ((i >> 29) & 3) | (((i >> 5) & 0x7ffff) << 2)
    return (pc & ~0xfff) + ((imm - (1 << 21) if imm & (1 << 20) else imm) << 12)
# SBHShortStringForScreenType: cmp x0, #N; b.hi; adrp x8, PAGE; add x8, x8, #OFF; ldr x0, [x8, x0, lsl #3]
fn = int(sys.argv[3], 16)
w = struct.unpack('<5I', c.read(fn, 20))
tab = adrp(w[2], fn + 8) + ((w[3] >> 10) & 0xfff)
names = [cfstr(q(tab + 8 * i)) for i in range(((w[0] >> 10) & 0xfff) + 1)]
print('  types: ' + ' '.join('%d=%s' % (i, n) for i, n in enumerate(names)))
lst = open(sys.argv[4]).read()
page = re.search(r'adrp\s+x22, (0x[0-9a-f]+)\n[^\n]*ldr\s+x22, \[x22, #(0x[0-9a-f]+)\]', lst)
sizes = q(int(page.group(1), 16) + int(page.group(2), 16))
pairs = re.findall(r'ldp\s+d2, d3, \[x22, #(0x[0-9a-f]+)\](?:\n[^\n]*){5}?\n[^\n]*mov\s+w9, #(0x[0-9a-f]+)', lst)
for off, t in pairs:
    wd, ht = struct.unpack('<dd', c.read(sizes + int(off, 16), 16))
    print('  %4.0f x %4.0f pt -> %d %s' % (wd, ht, int(t, 16), names[int(t, 16)]))
PY
echo "-- D22/D22Zoomed notch in px (sb-shape.s, divided by the native scale of the type: D22Zoomed = 3 * 375 / 320):"
grep -E 'double 249\.0' "$W"/sb-shape.s | sed 's/^.*; /  x /' || true
echo "  size: (627, 90) px [table at the ldr q3 of the D22 case]"
echo "-- D22Zoomed edge info (sbh-edge-info.s): top 38 = mov 0x4043..., bottom 29 = fmov #29; _Split +height:"
grep -oE 'double 47\.0' "$W"/split-height.s | head -1 || true
