#!/bin/sh
# Host test of the Mi A3 GPU pool bookkeeping (patch 2156: iokit/Kernel/arm/laurel_gpu_pool_core.h).
# macOS and Linux (needs cc with pthreads). Takes about 2 s, foreground is fine.
#   scripts/laurel/gpu-pool-test.sh [PATCH]
#     PATCH  default patches/laurel/xnu/2156-laurel-gpu-pool-lock.patch
# The header comes from the patch (a new file there) and GPU_POOL_UNIT/CHUNK/MAX from 2150, so the test
# checks exactly the code that goes into the kernel. Test source: tools/gpu-pool-test/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/laurel/xnu/2156-laurel-gpu-pool-lock.patch}
P2150=$REPO/patches/laurel/xnu/2150-laurel-gpu-trinket.patch
D=$OUT/gpu-pool-test
rm -rf "$D"
mkdir -p "$D"
awk '/^\+\+\+ b\/iokit\/Kernel\/arm\/laurel_gpu_pool_core\.h$/ {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/laurel_gpu_pool_core.h"
[ -s "$D/laurel_gpu_pool_core.h" ] || { echo "gpu-pool-test: no laurel_gpu_pool_core.h in $PATCH" >&2; exit 1; }
grep -E '^[ +]#define GPU_POOL_(UNIT|CHUNK|MAX) ' "$P2150" | cut -c2- > "$D/gpu_pool_defs.h"
[ "$(wc -l < "$D/gpu_pool_defs.h")" -eq 3 ] || { echo "gpu-pool-test: GPU_POOL_UNIT/CHUNK/MAX not found once each in $P2150" >&2; exit 1; }
${CC:-cc} -O2 -Wall -Wextra -Werror -pthread -I"$D" -o "$D/gpu_pool_test" "$REPO/tools/gpu-pool-test/gpu_pool_test.c"
"$D/gpu_pool_test"
