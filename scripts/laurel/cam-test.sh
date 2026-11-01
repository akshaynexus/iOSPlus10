#!/bin/sh
# Host test of the Mi A3 camera core (patch 2770: bsd/dev/laurel_cam_core.h). macOS and Linux (cc). About 1 s.
#   scripts/laurel/cam-test.sh [PATCH]
#     PATCH  default patches/laurel/xnu/2770-laurel-camera.patch
# The header comes from the patch (a new file there), so the test checks exactly the code in the kernel. With
# out/laurel/camera/sensors.txt (scripts/laurel/camera-inventory.sh) it also checks every sensor address and chip
# ID against the stock libraries. Test source: tools/laurel-cam-test/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/laurel/xnu/2770-laurel-camera.patch}
D=$OUT/laurel-cam-test
rm -rf "$D"
mkdir -p "$D"
awk '/^\+\+\+ b\/bsd\/dev\/laurel_cam_core\.h/ {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/laurel_cam_core.h"
[ -s "$D/laurel_cam_core.h" ] || { echo "cam-test: no laurel_cam_core.h in $PATCH" >&2; exit 1; }
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/cam_test" "$REPO/tools/laurel-cam-test/cam_test.c"
"$D/cam_test" "$OUT/laurel/camera/sensors.txt"
