#!/bin/sh
# Host test of the Mi A3 camera pure code. macOS and Linux (cc, python3). A few seconds.
#   scripts/laurel/cam-test.sh
# Step 1 (patch 2770: bsd/dev/laurel_cam_core.h): tools/laurel-cam-test/cam_test.c; with out/laurel/camera/sensors.txt
#   (scripts/laurel/camera-inventory.sh) every sensor address and chip ID against the stock libraries.
# Step 2 (patch 2771: laurel_cam_lib.h, laurel_cam_rdi.h): tools/laurel-cam-test/cam2_test.c unit checks; with the
#   stock libraries in out/laurel/camera/lib/ the C parser's tables must equal scripts/laurel/camera-tables.py's
#   (independent Python reading of the same layout), byte for byte.
# The headers come from the patches (new files there), so the test checks exactly the code in the kernel.
set -eu
. "$(dirname "$0")/../lib/env.sh"
P1=$REPO/patches/laurel/xnu/2770-laurel-camera.patch
P2=$REPO/patches/laurel/xnu/2771-laurel-camera-rdi.patch
D=$OUT/laurel-cam-test
rm -rf "$D"
mkdir -p "$D"
# a new file of a patch -> $D/NAME
take() {
  awk -v f="$2" '$0 == "+++ b/bsd/dev/" f || index($0, "+++ b/bsd/dev/" f "\t") == 1 {p=1; next}
       p && /^diff / {exit}
       p && /^@@/ {next}
       p && /^\+/ {print substr($0, 2)}' "$1" > "$D/$2"
  [ -s "$D/$2" ] || { echo "cam-test: no $2 in $1" >&2; exit 1; }
}
take "$P1" laurel_cam_core.h
take "$P2" laurel_cam_lib.h
take "$P2" laurel_cam_rdi.h
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/cam_test" "$REPO/tools/laurel-cam-test/cam_test.c"
"$D/cam_test" "$OUT/laurel/camera/sensors.txt"
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/cam2_test" "$REPO/tools/laurel-cam-test/cam2_test.c"
"$D/cam2_test"
n=0
for f in "$OUT"/laurel/camera/lib/libmmcamera_laurus_imx58*.so; do
  [ -s "$f" ] || continue
  b=$(basename "$f" .so)
  "$D/cam2_test" --dump "$f" > "$D/$b.c.txt"
  python3 -I "$REPO/scripts/laurel/camera-tables.py" "$f" > "$D/$b.py.txt"
  cmp -s "$D/$b.c.txt" "$D/$b.py.txt" || { echo "cam-test: $b: C parser and camera-tables.py differ" >&2; diff "$D/$b.c.txt" "$D/$b.py.txt" | head >&2; exit 1; }
  echo "cam-test: $b: $(head -1 "$D/$b.c.txt" | cut -d' ' -f2), $(grep -E '^(init|res) ' "$D/$b.c.txt" | tr '\n' ' ')- C = Python"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || echo "cam-test: no stock libraries in out/laurel/camera/lib (camera-inventory.sh): table comparison skipped"
echo "cam-test: OK"
