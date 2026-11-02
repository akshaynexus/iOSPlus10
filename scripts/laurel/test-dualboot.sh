#!/bin/sh
# Host test of the Mi A3 dual boot (docs/laurel_sprout/dual-boot.md). No phone, no root, no write outside out/. Some minutes: run it with scripts/bg.sh.
#   scripts/laurel/test-dualboot.sh
#   1. op10tool unit tests: the GPT plan: layout numbers, every wrong table refused, the real layout when the backup is on this machine (no GPT bytes in git).
#   2. The patch carries laurel_dualboot.h.
#   3. The real bsd/dev/sweet_ufs.c (the tree of `AUDIT=1 scripts/laurel/kernel-linux.sh` or a build) over a RAM disk: 0 blocks outside iosroot change; the fence; each unexpected GPT = off, no block changed.
#   4. The phone helper, built for this host: scripts/laurel/ldbhelper-test.sh: the real gpt-write on a sparse disk, a power cut after each step, a torn primary, one writer; and the phone's own code with real O_DIRECT and the block rules of 4.14 (test/dio_check.c). (aarch64 build: compile check only.)
#   5. The numbers of scripts/lib/laurel-layout.sh = what the tool prints; the real backup through the tool and an independent reader (python, no op10tool).
#   6. scripts/laurel/android-guard-test.sh and scripts/laurel/dual-boot-test.sh: the scripts themselves, with a fake adb and fastboot. PATH holds no real adb or fastboot there.
# Proves the code on the host. Nothing here proves anything about the phone.
set -eu
. "$(dirname "$0")/../lib/env.sh"
T=$REPO/tools/laurel-dualboot
D=$OUT/laurel-dualboot-test
X=$OUT/laurel-kernel/xnu-src/xnu-8796.141.3
P=$REPO/patches/laurel/xnu/2950-laurel-dual-boot.patch
rm -rf "$D"; mkdir -p "$D"
CC=${CC:-clang}
CT=${CARGO_TARGET_DIR:-$OUT/cargo}
case "$CT" in /*) ;; *) CT=$PWD/$CT ;; esac

echo "== 1. op10tool unit tests"
(cd "$REPO/tools/op10tool" && CARGO_TARGET_DIR=$CT cargo test --release gpt) > "$D/cargo-test.out" 2>&1 || { tail -30 "$D/cargo-test.out"; echo "test-dualboot: FAILED: cargo test" >&2; exit 1; }
grep -E '^test |^test result' "$D/cargo-test.out"
(cd "$REPO/tools/op10tool" && CARGO_TARGET_DIR=$CT cargo build --release) > "$D/cargo-build.out" 2>&1 || { tail -30 "$D/cargo-build.out"; exit 1; }
TOOL=$CT/release/op10tool

echo "== 2. the patch carries this header"
awk '$0 ~ /^\+\+\+ b\/bsd\/dev\/laurel_dualboot.h/ {p=1; next} p && /^diff / {exit} p && /^@@/ {next} p && /^\+/ {print substr($0, 2)}' "$P" > "$D/from-patch.h"
cmp "$D/from-patch.h" "$T/laurel_dualboot.h" || { echo "test-dualboot: FAILED: patch 2950 has another laurel_dualboot.h: regenerate it" >&2; exit 1; }
echo "ok   patch 2950 has the same laurel_dualboot.h"

echo "== 3. the real sweet_ufs.c over a RAM disk"
[ -f "$X/bsd/dev/sweet_ufs.c" ] && grep -q 'laurel 2950' "$X/bsd/dev/sweet_ufs.c" || { echo "test-dualboot: FAILED: no patched tree: AUDIT=1 scripts/laurel/kernel-linux.sh" >&2; exit 1; }
cmp "$X/bsd/dev/laurel_dualboot.h" "$T/laurel_dualboot.h"
mkdir -p "$D/k/sys" "$D/k/miscfs/devfs" "$D/k/kern" "$D/k/machine" "$D/k/arm" "$D/k/vm" "$D/k/pexpert" "$D/k/libkern"
for h in sys/param.h sys/systm.h sys/buf.h sys/conf.h sys/disk.h sys/errno.h sys/proc.h sys/uio.h sys/sysctl.h miscfs/devfs/devfs.h kern/locks.h kern/clock.h kern/sched_prim.h machine/machine_routines.h arm/caches_internal.h vm/pmap.h vm/vm_kern.h pexpert/pexpert.h pexpert/device_tree.h libkern/libkern.h machine/atomic.h kern/kalloc.h; do
  : > "$D/k/$h"
done
# the one change to the driver: its SCSI command goes to the RAM disk. ufs_scsi_hw (the MMIO path) stays compiled and unused.
sed -e 's/^ufs_scsi(const uint8_t \*cdb/ufs_scsi_hw(const uint8_t *cdb/' -e 's/\bufs_scsi(\([a-z]\)/ufs_scsi_fake(\1/g' "$X/bsd/dev/sweet_ufs.c" > "$D/k/sweet_ufs_host.c"
cp "$T/laurel_dualboot.h" "$D/k/"
grep -q '^ufs_scsi_hw(const' "$D/k/sweet_ufs_host.c"
sed -i '1i static int ufs_scsi_fake(const uint8_t *cdb, unsigned cdb_len, uint32_t len, bool write);' "$D/k/sweet_ufs_host.c"
$CC -std=gnu11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter -Wno-format -Wno-duplicate-decl-specifier \
  -I"$D/k" -I"$T/test" -o "$D/test_kernel" "$T/test/test_kernel.c"
ASAN_OPTIONS=detect_leaks=0 "$D/test_kernel" > "$D/test_kernel.out" 2>&1 || { grep -v '^SWEET' "$D/test_kernel.out" | tail -40; echo "test-dualboot: FAILED: test_kernel" >&2; exit 1; }
grep -E '^ok|^test_kernel:' "$D/test_kernel.out"
LDB_MARKER=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$T/laurel_dualboot.h")
LC_ALL=C grep -aqF "$LDB_MARKER" "$D/test_kernel" || { echo "test-dualboot: FAILED: the kernel object has no marker text $LDB_MARKER" >&2; exit 1; }
echo "ok   H1 the driver built with the marker holds the text: $LDB_MARKER"
grep -E 'LAUREL DUALBOOT: (on|off)' "$D/test_kernel.out" | sed 's/^/     /' | sort -u
# A kernel's own strings must not read as a boot-arg token, or the guard calls each read-only image writable (laurel_can_write). The real files, when they are built.
. "$REPO/scripts/lib/laurel-layout.sh"
for k in "$OUT/laurel-kernel/out/kernel.development.sweet.4k" "$OUT/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k"; do
  [ -f "$k" ] || { echo "note $k is not built: its strings were not checked"; continue; }
  if laurel_can_write < "$k"; then echo "test-dualboot: FAILED: $k holds text that reads as ufsrw or rootrw" >&2; exit 1; fi
  echo "ok   F7 no text in $(basename "$k") reads as a boot-arg token"
done

echo "== 4. the phone helper"
HC="$CC -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -Wall -Wextra -Wno-unused-parameter"
$HC -DLDB_TEST_FILE -o "$D/ldbhelper" "$T/ldbhelper.c"
$HC --target=aarch64-linux-gnu -o "$D/ldbhelper-arm64" "$T/ldbhelper.c"
file "$D/ldbhelper-arm64" | cut -d, -f1-3
LC_ALL=C grep -aq 'LDB_TEST_STOP' "$D/ldbhelper-arm64" && { echo "test-dualboot: FAILED: the phone binary holds the test hook" >&2; exit 1; }
echo "ok   the phone binary has no test hook"
H=$D/ldbhelper
# the phone's own code for this host, no test define: it runs under dio_check.c, with real O_DIRECT and the block rules of 4.14 (ldbhelper-test.sh, F1). x86_64 Linux: the tracer knows that ABI.
$HC -o "$D/ldbhelper-direct" "$T/ldbhelper.c"
LC_ALL=C grep -aq 'LDB_TEST_STOP' "$D/ldbhelper-direct" && { echo "test-dualboot: FAILED: the direct binary holds the test hook" >&2; exit 1; }
$CC -std=gnu11 -O1 -Wall -o "$D/dio_check" "$T/test/dio_check.c"
LDB_DIRECT=$D/ldbhelper-direct LDB_DIO=$D/dio_check LDB_TEST_DIR=$D sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$H" "$TOOL" || { echo "test-dualboot: FAILED: ldbhelper-test" >&2; exit 1; }
echo "== 5. the numbers in one place"
. "$REPO/scripts/lib/laurel-layout.sh"
python3 -I "$REPO/scripts/laurel/gpt-fake.py" dumps "$D/fh" "$D/ft"
"$TOOL" gpt plan --head "$D/fh" --tail "$D/ft" -o "$D/fplan" > "$D/fplan.txt"
grep -q "^IOSROOT_FIRST=$IOSROOT_FIRST IOSROOT_LAST=$IOSROOT_LAST IOSROOT_BYTES=$IOSROOT_BYTES IOSROOT_VOLUME_MAX=$IOSROOT_VOLUME_MAX USERDATA_LAST=$USERDATA_LAST\$" "$D/fplan.txt" || { echo "test-dualboot: FAILED: scripts/lib/laurel-layout.sh differs from op10tool gpt plan:" >&2; grep ^IOSROOT "$D/fplan.txt" >&2; exit 1; }
[ "$IOS26_VOLUME_BYTES" -le "$IOSROOT_VOLUME_MAX" ] && [ $((16 << 30)) -le "$IOSROOT_VOLUME_MAX" ] || { echo "test-dualboot: FAILED: a root does not fit" >&2; exit 1; }
echo "ok   layout file = tool: iosroot $IOSROOT_BYTES bytes; the iOS 26 volume $IOS26_VOLUME_BYTES + log $LOG_BYTES leaves $((IOSROOT_VOLUME_MAX - IOS26_VOLUME_BYTES)) bytes; 16 GiB fits"
BK=$(ls -d "$HOME"/laurel-backup/android-* 2>/dev/null | sort | tail -1)
if [ -n "$BK" ] && [ -f "$BK/gpt-sda-head.bin" ]; then
  # the real table, read only: a plan, and the new table applied to a sparse copy, read by the independent reader
  "$TOOL" gpt plan --head "$BK/gpt-sda-head.bin" --tail "$BK/gpt-sda-tail.bin" -o "$D/rplan" | sed 's/^/     /'
  truncate -s $((30119936 * 4096)) "$D/rdisk"
  dd if="$BK/gpt-sda-head.bin" of="$D/rdisk" conv=notrunc bs=4096 2>/dev/null
  dd if="$BK/gpt-sda-tail.bin" of="$D/rdisk" conv=notrunc bs=4096 seek=$((30119936 - 256)) 2>/dev/null
  "$H" gpt-write "$D/rplan" "$D/rdisk" | tail -1
  python3 -I "$REPO/scripts/laurel/gpt-fake.py" check "$D/rdisk" > "$D/rcheck"
  grep -q 'primary valid backup valid' "$D/rcheck" && grep -q "^userdata $USERDATA_FIRST $USERDATA_LAST\$" "$D/rcheck" && grep -q "^iosroot $IOSROOT_FIRST $IOSROOT_LAST\$" "$D/rcheck" || { cat "$D/rcheck"; echo "test-dualboot: FAILED: the real layout" >&2; exit 1; }
  "$H" gpt-dump "$D/rdisk" "$D/rh" "$D/rt" >/dev/null
  "$TOOL" gpt verify-new --head "$D/rh" --tail "$D/rt" --ref-head "$BK/gpt-sda-head.bin" --ref-tail "$BK/gpt-sda-tail.bin" | tail -1
  rm -f "$D/rdisk"
  echo "ok   the real backup layout ($(basename "$BK")): plan, write on a sparse copy, the independent reader and verify-new agree"
else
  echo "note no backup with gpt-sda-head.bin under $HOME/laurel-backup: the real layout was not tested"
fi
echo "== 6. guards and the dual boot script, with a fake adb and fastboot"
sh "$REPO/scripts/laurel/android-guard-test.sh" || { echo "test-dualboot: FAILED: android-guard-test" >&2; exit 1; }
OP10TOOL=$TOOL sh "$REPO/scripts/laurel/dual-boot-test.sh" || { echo "test-dualboot: FAILED: dual-boot-test" >&2; exit 1; }
echo "test-dualboot: PASS"
