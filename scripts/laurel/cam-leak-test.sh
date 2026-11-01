#!/bin/sh
# Host test: memory of the camera plug-in's frame path: tools/laurel-cam-test/cam5_test.c over a mock of CoreFoundation/CoreVideo and of /dev/negronicam.
#   scripts/laurel/cam-leak-test.sh [FRAMES]            plain (heap bytes a picture) + AddressSanitizer (leaks, use after free)
#   OLD=<git ref> scripts/laurel/cam-leak-test.sh       the same run on the plug-in sources of that commit (what a past boot ran)
# Needs clang (-fblocks). What it cannot see: CMCapture's and Metal's own memory.
set -eu
. "$(dirname "$0")/../lib/env.sh"
T=$REPO/tools/laurel-cam-test
D=$OUT/laurel-cam-test/leak
N=${1:-600}
rm -rf "$D"; mkdir -p "$D"
SRC=$REPO/userland/camera
DEF=""
EXTRA="$SRC/camera_still.c"
if [ -n "${OLD:-}" ]; then
  mkdir -p "$D/old"
  git -C "$REPO" archive "$OLD" userland/camera | tar -x -C "$D/old"
  SRC=$D/old/userland/camera
  DEF=-DOLD_SOURCE
  EXTRA=
fi
W="-Wno-unused-parameter -Wno-deprecated-declarations -Wno-format -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-pointer-sign"
BASE="-g -fblocks -DLAUREL_CAMERA=1 -DPREVIEW_BIN=2 $DEF -I$T/stub -I$T -I$SRC $W -pthread"
F="$T/cam5_test.c $T/cam5_mock.c $T/cam5_mock_cv.c $SRC/camera_isp.c $EXTRA -lm"
# shellcheck disable=SC2086
clang -O2 $BASE -o "$D/plain" $F
"$D/plain" "$N"
# shellcheck disable=SC2086
clang -O1 -fsanitize=address -fno-omit-frame-pointer $BASE -o "$D/asan" $F
ASAN_OPTIONS=detect_leaks=1:allocator_may_return_null=1 LSAN_OPTIONS=max_leaks=20 "$D/asan" "$((N / 4))"
if [ -z "${OLD:-}" ]; then
  # the picture checks of boot 20:02 and the filter thumbnails
  # shellcheck disable=SC2086
  clang -O2 $BASE -o "$D/cam6" "$T/cam6_test.c" "$T/cam5_mock.c" "$T/cam5_mock_cv.c" "$SRC/camera_thumbs.c" "$SRC/camera_isp.c" "$SRC/camera_still.c" -lm
  "$D/cam6"
fi
echo "cam-leak-test: OK${OLD:+ on $OLD}"
