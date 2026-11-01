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
addr() {   # addr IMAGE 'exact symbol'
  awk -v s="$2" -F'\t' 'index($0, s) && $3 == s { sub(":", "", $1); print $1; exit }' "$W/$1-syms.txt"
}
dis() {    # dis NAME ADDR COUNT
  "$IPSW" dyld disass "$DSC" --vaddr "$2" --count "$3" --cache "$A2S" --quiet 2>/dev/null |
    python3 -I "$here/scripts/debug/dsc-annotate.py" "$DSC" > "$W/$1.s"
  echo "== $1 ($2): $W/$1.s"
}
syms UIKitCore
syms SpringBoard
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
