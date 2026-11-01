#!/bin/sh
# Do the new dual boot tests find the defects? Runs each suite against the code from before the fix (git rev, default 037cd81) and reports which test failed there.
#   scripts/bg.sh db-detect scripts/laurel/dualboot-tests-detect.sh [REV]
#   Output: out/laurel-dualboot-detect/{script,guard,helper,kernel}.out, and one line per test that passed on the old code without the mark [R] (= not detected; exit 1 then).
# Test names with [R] (regressions) and [N] (a refusal of a command the old code does not have) may pass there. No phone: the same fakes as the tests. No write outside out/.
# The kernel suite needs the old patched sweet_ufs.c: made here from the patched tree (AUDIT=1 scripts/laurel/kernel-linux.sh or a build): the new patch 2950 taken out, the old one put in.
set -u
. "$(dirname "$0")/../lib/env.sh"
REV=${1:-037cd81}
W=$OUT/laurel-dualboot-detect
rm -rf "$W"; mkdir -p "$W/old"
git -C "$REPO" archive "$REV" scripts tools/laurel-dualboot patches/laurel/xnu/2950-laurel-dual-boot.patch | tar -x -C "$W/old"
CC=${CC:-clang}
TOOL=${OP10TOOL:-$OUT/cargo/release/op10tool}
T=$W/old/tools/laurel-dualboot
HC="$CC -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -I$T"
$HC -DLDB_TEST_NO_PIN -o "$W/old-helper" "$T/ldbhelper.c" 2>/dev/null
rc=0
judge() {   # NAME FILE: a line "ok   X" without [R] means the test passed on the old code
  f=$(grep -c '^FAIL' "$2" || true)
  p=$(grep '^ok   ' "$2" | grep -vE '\[R\]|\[N\]' | grep -v 'cannot be reached' || true)
  echo "== $1: $f tests failed on the old code"
  if [ -n "$p" ]; then printf '%s\n' "$p" | sed 's/^ok   /NOT DETECTED: /'; rc=1; fi
}
OP10TOOL=$TOOL WRITE_WAIT=2 sh "$REPO/scripts/laurel/dual-boot-test.sh" "$W/old" > "$W/script.out" 2>&1
judge "dual-boot-test (fake adb, old dual-boot.sh)" "$W/script.out"
sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/old" > "$W/guard.out" 2>&1
judge "android-guard-test (old guard, restore.sh, uefi-image.sh)" "$W/guard.out"
LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/old-helper" "$TOOL" --old-api > "$W/helper.out" 2>&1
judge "ldbhelper-test (old helper)" "$W/helper.out"
# the kernel: the new test_kernel.c over the old driver + old header
X=$OUT/laurel-kernel/xnu-src/xnu-8796.141.3/bsd/dev/sweet_ufs.c
K=$W/k; mkdir -p "$K/sys" "$K/miscfs/devfs" "$K/kern" "$K/machine" "$K/arm" "$K/vm" "$K/pexpert" "$K/libkern" "$K/ufs"
[ -f "$X" ] || { echo "dualboot-tests-detect: no patched tree: AUDIT=1 scripts/laurel/kernel-linux.sh" >&2; exit 1; }
ufs_part() { sed -n '/^diff -ruN a\/bsd\/dev\/sweet_ufs.c/,$p' "$1"; }
cp "$X" "$K/ufs/sweet_ufs.c"
(cd "$K/ufs" && ufs_part "$REPO/patches/laurel/xnu/2950-laurel-dual-boot.patch" | patch -R -p3 -s --no-backup-if-mismatch sweet_ufs.c &&
  ufs_part "$W/old/patches/laurel/xnu/2950-laurel-dual-boot.patch" | patch -p3 -s --no-backup-if-mismatch sweet_ufs.c) || { echo "dualboot-tests-detect: cannot make the old driver" >&2; exit 1; }
grep -q ldb_bind "$K/ufs/sweet_ufs.c" || { echo "dualboot-tests-detect: that is not the old driver" >&2; exit 1; }
for h in sys/param.h sys/systm.h sys/buf.h sys/conf.h sys/disk.h sys/errno.h sys/proc.h sys/uio.h sys/sysctl.h miscfs/devfs/devfs.h kern/locks.h kern/clock.h kern/sched_prim.h machine/machine_routines.h arm/caches_internal.h vm/pmap.h vm/vm_kern.h pexpert/pexpert.h pexpert/device_tree.h libkern/libkern.h machine/atomic.h kern/kalloc.h; do : > "$K/$h"; done
sed -e 's/^ufs_scsi(const uint8_t \*cdb/ufs_scsi_hw(const uint8_t *cdb/' -e 's/\bufs_scsi(\([a-z]\)/ufs_scsi_fake(\1/g' "$K/ufs/sweet_ufs.c" > "$K/sweet_ufs_host.c"
sed -i '1i static int ufs_scsi_fake(const uint8_t *cdb, unsigned cdb_len, uint32_t len, bool write);' "$K/sweet_ufs_host.c"
cp "$T/laurel_dualboot.h" "$K/"
N=$REPO/tools/laurel-dualboot/test
if $CC -std=gnu11 -O1 -g -Wno-format -Wno-duplicate-decl-specifier -w -I"$K" -I"$N" -o "$W/test_kernel" "$N/test_kernel.c" > "$W/kernel-build.out" 2>&1; then
  r=0; ASAN_OPTIONS=detect_leaks=0 "$W/test_kernel" > "$W/kernel.out" 2>&1 || r=$?
  f=$(grep -c '^FAIL' "$W/kernel.out" || true)
  echo "== test_kernel (new test over the old driver): exit $r, $f checks failed"
  grep -E '^FAIL' "$W/kernel.out" | cut -c1-160 | sed -n 1,16p
  [ "$r" != 0 ] && [ "$f" != 0 ] || { echo "NOT DETECTED: test_kernel passed on the old driver"; rc=1; }
else
  sed 's/^/     /' "$W/kernel-build.out" | head -20; echo "test_kernel did not build against the old driver"; rc=1
fi
echo "dualboot-tests-detect: $([ "$rc" = 0 ] && echo "every new test failed on $REV" || echo "SOME NEW TESTS DID NOT DETECT THE OLD CODE")"
exit "$rc"
