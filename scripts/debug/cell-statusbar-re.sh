#!/bin/bash
# Evidence for docs/laurel_sprout/cellular.md section 9: the telephony methods of the iOS 16.7 20H392 (iPhone10,3) SpringBoard, STStatus and
# Settings, from the dyld shared cache. macOS + Linux; needs blacktop/ipsw (out/laurel-metal/ipsw/ipsw or IPSW=...).
#   scripts/bg.sh celln-re scripts/debug/cell-statusbar-re.sh     -> out/re-cell/*-syms.txt, out/re-cell/summary.txt
# Cache: $DSC, else the Cryptex at out/mnt-cryptex (mounted here with apfs-fuse, read-only).
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
IPSW=${IPSW:-$(command -v ipsw || echo "$here/out/laurel-metal/ipsw/ipsw")}
[ -x "$IPSW" ] || { echo "cell-statusbar-re: needs ipsw (scripts/laurel/metal-build.sh fetch, or IPSW=...)" >&2; exit 1; }
if [ -z "${DSC:-}" ]; then
  mnt=$here/out/mnt-cryptex
  if [ ! -d "$mnt/root/System" ]; then
    mkdir -p "$mnt"
    ln -sfn "${APPLE:-$HOME/op10-apple}/20H392/087-86593-047.dmg" "$here/out/cryptex.dmg"
    apfs-fuse -o ro "$here/out/cryptex.dmg" "$mnt"
  fi
  DSC=$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
fi
[ -f "$DSC" ] || { echo "cell-statusbar-re: no shared cache at $DSC (set DSC)" >&2; exit 1; }
W=$here/out/re-cell; mkdir -p "$W"
for img in SpringBoard SystemStatus SystemStatusServer UIKitCore CoreTelephony PreferencesUI; do
  [ -s "$W/$img-syms.txt" ] || "$IPSW" dyld symaddr "$DSC" --image "$img" > "$W/$img-syms.txt" 2>/dev/null || true
done
{
  echo "== SpringBoard: SBStatusBarStateAggregator"
  grep -E 'SBStatusBarStateAggregator ' "$W/SpringBoard-syms.txt" | grep -iE 'signal|service|update|setItem|telephony|sim|cell|data' || true
  echo "== SpringBoard: SBTelephonyManager"
  grep -E 'SBTelephonyManager ' "$W/SpringBoard-syms.txt" | head -150 || true
  echo "== UIKitCore: cellular signal view, cellular item"
  grep -E '_UIStatusBar(Cellular|Signal)[A-Za-z]* ' "$W/UIKitCore-syms.txt" | head -80 || true
  echo "== SystemStatus + SystemStatusServer: telephony domain and its provider"
  grep -hE 'ST(Mutable)?Telephony[A-Za-z]* ' "$W/SystemStatus-syms.txt" "$W/SystemStatusServer-syms.txt" | grep -v block_invoke || true
  echo "== PreferencesUI: cellular"
  LC_ALL=C grep -iE 'PSUIPrefsListController .*cellular' "$W/PreferencesUI-syms.txt" || true
} > "$W/summary.txt"
wc -l "$W"/*.txt
