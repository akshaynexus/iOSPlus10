#!/bin/sh
# Host test of RedwoodGPU's rules (patches 2975-2978): the push rule, keep(), the take of kept buffers, the wait of mapped pool buffers, LAUREL GPU TIME, table runs.
# macOS and Linux (needs cc). Takes a few seconds, foreground is fine.  scripts/laurel/gpu-push-test.sh
# The headers come from the patches, so the test runs exactly the code that goes into the kernel. Test source: tools/gpu-push-test/.
# It also checks the patches: every free of a pool buffer goes through the map check, every map sets dirty, the kernel calls these rules (not a copy).
set -eu
. "$(dirname "$0")/../lib/env.sh"
P=$REPO/patches/laurel/xnu
D=$OUT/gpu-push-test
rm -rf "$D"; mkdir -p "$D"
newfile() { # patch name: a new file of the patch
  awk -v n="$2" '$0 == "+++ b/iokit/Kernel/arm/" n {p=1; next}
       p && /^diff / {exit}
       p && /^@@/ {next}
       p && /^\+/ {print substr($0, 2)}' "$1" > "$D/$2"
  [ -s "$D/$2" ] || { echo "gpu-push-test: no $2 in $1" >&2; exit 1; }
}
newfile "$P/2156-laurel-gpu-pool-lock.patch" laurel_gpu_pool_core.h
awk '/^diff --git a\/iokit\/Kernel\/arm\/laurel_gpu_pool_core\.h/ {p=1}
     p && /^diff --git/ && !/laurel_gpu_pool_core\.h/ {exit}
     p {print}' "$P/2974-laurel-gpu-pool-1g-kernel-ram.patch" > "$D/2974-core.patch"
(cd "$D" && patch -s -p4 laurel_gpu_pool_core.h < 2974-core.patch)
grep -E '^[ +]#define GPU_POOL_(UNIT|CHUNK|MAX) ' "$P/2150-laurel-gpu-trinket.patch" | cut -c2- > "$D/gpu_pool_defs.h"
newfile "$P/2975-laurel-gpu-time.patch" laurel_gpu_time_core.h
newfile "$P/2976-laurel-gpu-kept-need.patch" laurel_gpu_kept_core.h
newfile "$P/2977-laurel-gpu-push-rule.patch" laurel_gpu_push_core.h
newfile "$P/2978-laurel-gpu-table-runs.patch" laurel_gpu_table_core.h
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/gpu_push_test" "$REPO/tools/gpu-push-test/gpu_push_test.c"
"$D/gpu_push_test"
# the kernel side calls the tested code
need() { grep -qF -- "$2" "$P/$1" || { echo "gpu-push-test: $1 does not have: $2" >&2; exit 1; }; }
need 2976-laurel-gpu-kept-need.patch '+	pa = lgk_take(&gGPUKeptOps, gGPUKeptItems, size, va, all, &res);'
need 2976-laurel-gpu-kept-need.patch '+	bytes = lgk_floor(&gGPUKeptOps, gGPUKeptItems, size, floor);'
need 2976-laurel-gpu-kept-need.patch '+	if (!lgk_may_keep('
need 2976-laurel-gpu-kept-need.patch '+	place = &fKept[lgk_keep_pick('
need 2976-laurel-gpu-kept-need.patch '+			(void) redwood_gpu_pool_floor(size, 64ull << 20);'
need 2977-laurel-gpu-push-rule.patch '+			enum lgf_what what = lgf_own_buffer(&own, &dirty_after);'
need 2977-laurel-gpu-push-rule.patch '+		b->dirty = true; '
need 2978-laurel-gpu-table-runs.patch 'lgt_run_add(&gpu_pte_run'
# every way a pool buffer goes back in the kernel: the 3 places of the old code each have the check (freeBuffer, reap, dropKept)
n=$(grep -c '^+.*gpuHeldByMap(' "$P/2976-laurel-gpu-kept-need.patch")
[ "$n" -ge 4 ] || { echo "gpu-push-test: gpuHeldByMap in $n places, want freeBuffer, reap, dropKept, poolKeptItems" >&2; exit 1; }
# the value of VM_WIMG_WCOMB on the arm kernels, where a tree is there (a wrong one only turns the feature off)
for t in "$OUT/laurel-kernel-ios26/src/xnu" "$OUT/laurel-kernel/xnu-src/xnu-8796.141.3"; do
  f=$t/osfmk/arm/memory_types.h; [ -f "$f" ] || f=$t/osfmk/mach/arm/vm_param.h
  [ -d "$t/osfmk" ] || continue
  grep -rqE 'define VM_WIMG_WCOMB +\(VM_MEM_NOT_CACHEABLE \| VM_MEM_COHERENT\)' "$t/osfmk/arm" "$t/osfmk/mach/vm_param.h" "$t/osfmk/vm/" 2>/dev/null || \
    { echo "gpu-push-test: VM_WIMG_WCOMB is not NOT_CACHEABLE | COHERENT in $t" >&2; exit 1; }
done
echo "gpu-push-test: patches call the tested rules"
