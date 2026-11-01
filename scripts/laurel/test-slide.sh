#!/bin/sh
# Host test: the kernel's slide function for v5, on all slide pages of the lowered 23F84 cache and of the original one (auth entries). See tools/laurel-a64emu/test/slide-test.c.
#   scripts/laurel/test-slide.sh      needs the iOS 26 kernel tree (kernel-ios26-linux.sh) and $APPLE/ios26/23F84-n104ap. Seconds.
set -eu
. "$(dirname "$0")/../lib/env.sh"
X=$OUT/laurel-kernel-ios26/src/xnu
O=$OUT/a64emu-test
B=${APPLE:-$HOME/op10-apple}/ios26/23F84-n104ap
mkdir -p "$O"
# the function, as it is in the tree; nothing else of the kernel
awk '/^vm_shared_region_slide_page_v5\(/{print "static kern_return_t"; p=1} p{print} p&&/^}/{exit}' "$X/osfmk/vm/vm_shared_region.c" > "$O/slide-v5-from-kernel.inc"
grep -q 'laurel: this CPU has no PAC' "$O/slide-v5-from-kernel.inc" || { echo "test-slide: the function in the tree is not the expected one" >&2; exit 1; }
clang -O2 -w -I "$O" "$REPO/tools/laurel-a64emu/test/slide-test.c" -o "$O/slide-test"
for d in lowered tree/cache; do
  echo "$d:"
  rc=0; "$O/slide-test" "$B/$d"/dyld_shared_cache_arm64e*.dylddata || rc=$?
  [ "$rc" = 0 ] || { echo "test-slide: FAILED on $d"; exit 1; }
done
echo "test-slide: PASS"
