#!/bin/sh
# Host test of the kernel speaker guard (patch 0244, bsd/dev/negroni_audio_guard.c). A few seconds.
#   scripts/audio/test-guard.sh [TREE]   TREE: a patched kernel tree (scripts/kernel/patched-tree.sh);
#                                         without one, the guard is taken from patches/xnu/0244 alone.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/audio/test-guard
rm -rf "$W"; mkdir -p "$W/sys"
if [ -n "${1:-}" ]; then
  cp "$1/bsd/dev/negroni_audio_guard.c" "$1/bsd/dev/negroni_audio_guard.h" "$W/"
else
  # the two new files of the patch, without git: a new file's hunk is all '+' lines
  for f in negroni_audio_guard.c negroni_audio_guard.h; do
    awk -v F="b/bsd/dev/$f" '$0 ~ "^\\+\\+\\+ "F"$" {on=1; next} /^diff --git/ {on=0} on && /^\+/ {print substr($0,2)}' \
      "$REPO/patches/xnu/0244-negroni-audio-amp-tfa9874.patch" > "$W/$f"
  done
fi
: > "$W/sys/systm.h"                    # the kernel header the guard includes; nothing from it is used
${CC:-cc} -O2 -Wall -Wextra -DARM64_BOARD_CONFIG_NEGRONI -I"$W" -include sys/param.h -include stdbool.h -include strings.h \
  "$HERE/test-guard/test-guard.c" "$W/negroni_audio_guard.c" -o "$W/test-guard" -lm
"$W/test-guard"
