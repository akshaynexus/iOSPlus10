#!/bin/sh
# Host test of the Mi A3 UFS read queue (patch 2971: bsd/dev/laurel_ufs_queue.h). macOS and Linux. Some seconds, foreground.
#   scripts/laurel/test-ufs-queue.sh [PATCH]
# The header and the register and descriptor definitions come from the patches, so the test checks the code that goes into the kernel.
set -eu
. "$(dirname "$0")/../lib/env.sh"
P=${1:-$REPO/patches/laurel/xnu/2971-laurel-ufs-read-queue.patch}
D=$OUT/ufsq-test
rm -rf "$D"; mkdir -p "$D"
awk '/^\+\+\+ b\/bsd\/dev\/laurel_ufs_queue\.h/ {p=1; next} p && /^diff / {exit} p && /^@@/ {next} p && /^\+/ {print substr($0, 2)}' "$P" > "$D/laurel_ufs_queue.h"
[ -s "$D/laurel_ufs_queue.h" ] || { echo "test-ufs-queue: no laurel_ufs_queue.h in $P" >&2; exit 1; }
# the definitions of the driver: a copy; with a kernel tree here it must equal the tree
cp "$REPO/tools/laurel-ufsq/ufs_defs.h" "$D/ufs_defs.h"
TREE=$OUT/laurel-kernel-ios26/src/xnu/bsd/dev/sweet_ufs.c
if [ -f "$TREE" ]; then
  awk '/^#define REG_CAP / {p=1} p {print} /^#define DMA_SIZE/ {exit}' "$TREE" > "$D/tree.h"
  tail -n +2 "$REPO/tools/laurel-ufsq/ufs_defs.h" | cmp - "$D/tree.h" || { echo "test-ufs-queue: FAILED: ufs_defs.h differs from the driver: copy it again" >&2; exit 1; }
fi
${CC:-cc} -std=gnu11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -Wall -Wextra -Wno-unused-function -Wno-unused-parameter -Wno-format -I"$D" -o "$D/test_ufsq" "$REPO/tools/laurel-ufsq/test_ufsq.c" -lpthread
ASAN_OPTIONS=detect_leaks=0 "$D/test_ufsq"
