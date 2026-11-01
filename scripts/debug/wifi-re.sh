#!/bin/bash
# What iOS 16 20H392 expects from Wi-Fi requests RSSI (16), RATE (8), MCS (57), RSSI_BOUNDS (106), CURRENT_NETWORK (103)
# and which events it listens to: read from IO80211.framework and wifid, so docs/laurel_sprout/wifi.md can say what is verified.
#   scripts/bg.sh wifi6-re scripts/debug/wifi-re.sh             -> out/wifi-re/*.s + the symbol lists
#   scripts/debug/wifi-re.sh dis NAME VADDR COUNT               -> one more listing, out/wifi-re/NAME.s
# Needs: ipsw (out/laurel-metal/ipsw/ipsw or PATH), apfs-fuse; the Cryptex dmg in ~/op10-apple/20H392, the root image
# ~/op10-apple/laurel-ios16-root.simg. macOS + Linux. All read-only.
set -euo pipefail
here=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
main=$(git -C "$here" worktree list --porcelain | sed -n '1s/^worktree //p')
IPSW=${IPSW:-$(command -v ipsw || echo "$main/out/laurel-metal/ipsw/ipsw")}
[ -x "$IPSW" ] || { echo "wifi-re: needs ipsw (scripts/laurel/metal-build.sh fetch)" >&2; exit 1; }
mnt=$here/out/mnt-cryptex
if [ ! -d "$mnt/root/System" ]; then
  mkdir -p "$mnt"
  apfs-fuse -o ro "$HOME/op10-apple/20H392/087-86593-047.dmg" "$mnt"
fi
DSC=${DSC:-$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64}
W=$here/out/wifi-re
mkdir -p "$W"
A2S=$W/dsc.a2s

dis() {  # dis NAME VADDR COUNT
  "$IPSW" dyld disass "$DSC" --vaddr "$2" --count "$3" --cache "$A2S" --quiet 2>/dev/null |
    python3 -I "$here/scripts/debug/dsc-annotate.py" "$DSC" > "$W/$1.s"
  echo "== $1 ($2): $W/$1.s"
}
if [ "${1:-}" = dis ]; then
  dis "$2" "$3" "$4"
  exit 0
fi
for image in IO80211 WiFiPolicy CoreWiFi; do
  [ -s "$W/$image-syms.txt" ] || "$IPSW" dyld symaddr "$DSC" --image "$image" > "$W/$image-syms.txt" 2>/dev/null || true
  wc -l "$W/$image-syms.txt"
done
# wifid is outside the cache
if [ ! -s "$W/wifid" ]; then
  mkdir -p "$W/wifid-root/usr/sbin"
  python3 -I "$here/scripts/audio/hfs-extract.py" "$HOME/op10-apple/laurel-ios16-root.simg" "$W/wifid-root" /usr/sbin/wifid
  find "$W/wifid-root" -name wifid -type f -exec cp {} "$W/wifid" \;
fi
ls -l "$W/wifid"
# disassembly of wifid (arm64e), for the requests and the scale of the signal
[ -s "$W/wifid.s" ] || llvm-objdump -d --no-show-raw-insn --mattr=+v8.5a "$W/wifid" > "$W/wifid.s"
python3 -I "$here/scripts/debug/dsc-dis.py" "${DSC%/*}" dis 0x1d3ebaff4 0x3a000 > "$W/io80211-raw.s"
wc -l "$W/wifid.s" "$W/io80211-raw.s"
# what was read (docs/laurel_sprout/wifi.md "What iOS expects"): dis NAME 0x1d3ed90f0 560 (the RSSI_CHANGED event), 0x1d3ec639c 40
# (RSSI_BOUNDS), 0x1d3ec470c 60 (RSSI), 0x1c59910a4 220 (SpringBoard's bars); wifid: 0x10003f65c (scale), 0x10005cd14 (RSSI event);
# scripts/debug/wifi-xref.py out/wifi-re/wifid out/wifi-re/wifid.s TEXT... lists where wifid loads a string
