#!/bin/sh
# Host test of the Mi A3 camera pure code. macOS and Linux (cc, python3). A few seconds.
#   scripts/laurel/cam-test.sh
# Step 1 (patch 2770: bsd/dev/laurel_cam_core.h): tools/laurel-cam-test/cam_test.c; with out/laurel/camera/sensors.txt
#   (scripts/laurel/camera-inventory.sh) every sensor address and chip ID against the stock libraries.
# Step 2 (patch 2771: laurel_cam_lib.h, laurel_cam_rdi.h): tools/laurel-cam-test/cam2_test.c unit checks; with the
#   stock libraries in out/laurel/camera/lib/ the C parser's tables must equal scripts/laurel/camera-tables.py's
#   (independent Python reading of the same layout), byte for byte.
# Step 3 + 4 (patch 2772: laurel_cam_dev.h; userland/camera): tools/laurel-cam-test/cam3_test.c, a mock NCFRAME1 client with the
#   client's own header (negronicam.h, layout compared at compile time) and ISP: session numbers, ring, limits, AE, colours, preview.
# Quality (patch 2773): tools/laurel-cam-test/cam4_test.c.
# Signal self-check (patch 2784: laurel_cam_light.h): tools/laurel-cam-test/cam7_test.c.
# The headers come from the patches (new files there), so the test checks exactly the code in the kernel.
set -eu
. "$(dirname "$0")/../lib/env.sh"
P1=$REPO/patches/laurel/xnu/2770-laurel-camera.patch
P2=$REPO/patches/laurel/xnu/2771-laurel-camera-rdi.patch
P3=$REPO/patches/laurel/xnu/2772-laurel-camera-dev.patch
P4=$REPO/patches/laurel/xnu/2773-laurel-camera-quality.patch
P5=$REPO/patches/laurel/xnu/2784-laurel-camera-light.patch
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
take "$P3" laurel_cam_dev.h
take "$P4" laurel_cam_mode.h
take "$P5" laurel_cam_light.h
# 2773 changes laurel_cam_dev.h of 2772: its part of the patch on the copy
awk '/^diff -ruN a\/bsd\/dev\/laurel_cam_dev\.h /{p=1; print; next} /^diff /{p=0} p' "$P4" | (cd "$D" && patch -s -p3 laurel_cam_dev.h)
# 2784 changes laurel_cam_mode.h of 2773
awk '/^diff -ruN a\/bsd\/dev\/laurel_cam_mode\.h /{p=1; print; next} /^diff /{p=0} p' "$P5" | (cd "$D" && patch -s -p3 laurel_cam_mode.h)
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
${CC:-cc} -O2 -Wall -Wextra -Wno-unused-parameter -I"$D" -I"$REPO/userland/camera" -o "$D/cam3_test" \
  "$REPO/tools/laurel-cam-test/cam3_test.c" "$REPO/userland/camera/camera_isp.c" "$REPO/userland/camera/camera_still.c" -lm
"$D/cam3_test"
# Quality (patch 2773: laurel_cam_mode.h; userland/camera/camera_still.c): real frame rates of all modes, lens motor library, 5x5 demosaic, finish, tuning file
${CC:-cc} -O2 -Wall -Wextra -Wno-unused-parameter -I"$D" -I"$REPO/userland/camera" -o "$D/cam4_test" \
  "$REPO/tools/laurel-cam-test/cam4_test.c" "$REPO/userland/camera/camera_isp.c" "$REPO/userland/camera/camera_still.c" -lm
"$D/cam4_test" "$OUT/laurel/camera/lib"
# Signal self-check (patch 2784): raw statistics, colour bars, register values after the tables, kernel = plug-in
${CC:-cc} -O2 -Wall -Wextra -Wno-unused-parameter -I"$D" -I"$REPO/userland/camera" -o "$D/cam7_test" \
  "$REPO/tools/laurel-cam-test/cam7_test.c" "$REPO/userland/camera/camera_isp.c" "$REPO/userland/camera/camera_still.c" -lm
"$D/cam7_test" "$OUT/laurel/camera/lib"
echo "cam-test: OK"
