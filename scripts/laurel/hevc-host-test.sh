#!/bin/bash
# Host test of the HEVC decoder with the real 20H392 wallpaper layers. docs/laurel_sprout/hevc.md section 7.
#   scripts/bg.sh heic-test scripts/laurel/hevc-host-test.sh
# Copies each layer from the OS image (apfs-fuse, no root) to out/heic/layers, runs scripts/laurel/hevc-test.py, then hevc-test-video.py (B-frames, 10-bit).
set -euo pipefail
. "$(cd "$(dirname "$0")/../lib" && pwd)/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
T=${HOST_TOOL:-$OUT/laurel/hevc/host/hevc-test}
L=$OUT/heic/layers
RE=$OUT/heic/re
[ -x "$T" ] || { echo "hevc-host-test: no $T: scripts/laurel/hevc-build.sh first"; exit 1; }
if [ "$(ls "$L" 2>/dev/null | wc -l)" -lt 48 ]; then
  mkdir -p "$L" "$RE/os"
  ln -sf "$APPLE/20H392/087-86698-044.dmg" "$RE/os.dmg"
  mountpoint -q "$RE/os" || apfs-fuse -o ro "$RE/os.dmg" "$RE/os"
  find "$RE/os/root/Library/Wallpaper/Collections" -iname '*.heic' -print0 | while IFS= read -r -d '' f; do
    n=$(printf '%s' "$f" | cksum | cut -d' ' -f1)
    cp "$f" "$L/$n-$(basename "$f" | tr ' ' '_')"
  done
fi
find "$L" -iname '*.heic' -print0 | sort -z | xargs -0 -n 4 -P "$NPROC" python3 -I "$REPO/scripts/laurel/hevc-test.py" --tool "$T" > "$OUT/heic/test-raw.txt" || true
sort "$OUT/heic/test-raw.txt" > "$OUT/heic/test-result.txt"
pass=$(grep -c '^PASS' "$OUT/heic/test-result.txt" || true)
fail=$(grep -c '^FAIL' "$OUT/heic/test-result.txt" || true)
grep '^FAIL' "$OUT/heic/test-result.txt" | head -20 || true
sed -n '/^PASS/p' "$OUT/heic/test-result.txt" | head -4
echo "hevc-host-test: $pass files pass, $fail fail; $(grep -o 'lowest plane [^ ]*' "$OUT/heic/test-result.txt" | sort -k3 -n | head -1)"
python3 -I "$REPO/scripts/laurel/hevc-test-video.py" --tool "$T" "$OUT/heic/video"
[ "$fail" = 0 ] && [ "$pass" -gt 0 ]
