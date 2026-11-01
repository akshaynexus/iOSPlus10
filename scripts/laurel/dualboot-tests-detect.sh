#!/bin/sh
# Do the dual boot tests find the defects? For each fix: a copy of the tree with exactly that fix taken out (the old behaviour put back), and the test that names it. That test must FAIL there.
#   scripts/bg.sh db-detect scripts/laurel/dualboot-tests-detect.sh
# The file design's code is gone, so "the old code" is this: the lines of the fix reversed. F2, F3 also run against the commit before this work (OLD_REV, default 378b2e9), where those scripts exist.
# Needs the patched kernel tree (AUDIT=1 scripts/laurel/kernel-linux.sh or a build) and a built op10tool. No phone, the same fakes as the tests. Writes only under out/.
set -u
. "$(dirname "$0")/../lib/env.sh"
OLD_REV=${OLD_REV:-378b2e9}
W=$OUT/laurel-dualboot-detect
TOOL=${OP10TOOL:-${CARGO_TARGET_DIR:-$OUT/cargo}/release/op10tool}
rm -rf "$W"; mkdir -p "$W"
rc=0
copy() { rm -rf "$W/t"; mkdir -p "$W/t/tools"; cp -R "$REPO/scripts" "$W/t/scripts"; cp -R "$REPO/tools/laurel-dualboot" "$W/t/tools/laurel-dualboot"; }
# mutate NAME FILE OLD NEW: python exact replace; a pattern that is gone stops this script: then the mutation tests nothing
mutate() {
  python3 -I - "$W/t/$1" "$2" "$3" <<'PY' || { echo "dualboot-tests-detect: FAILED: cannot apply a mutation to $1: $2" >&2; exit 1; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
assert a in s
open(p, 'w').write(s.replace(a, b))
PY
}
judge() {   # WHAT OUTPUT: the test must say FAIL
  if grep -q '^FAIL' "$2"; then echo "ok   detected: $1"; else echo "NOT DETECTED: $1"; sed 's/^/     | /' "$2" | tail -3; rc=1; fi
}
guard() { ONLY="$2" sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/t" > "$W/o" 2>&1; judge "$1" "$W/o"; }
script() { ONLY="$2" OP10TOOL=$TOOL sh "$REPO/scripts/laurel/dual-boot-test.sh" "$W/t" > "$W/o" 2>&1; judge "$1" "$W/o"; }

echo "== the commit before this work ($OLD_REV), scripts as they were"
rm -rf "$W/old"; mkdir -p "$W/old"; git -C "$REPO" archive "$OLD_REV" scripts tools/laurel-dualboot | tar -x -C "$W/old"
ONLY='F2 boot-image: a shim*' sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/old" > "$W/o" 2>&1; judge "F2 on $OLD_REV: ANDROID_IMAGE=1 lets a shim through" "$W/o"
ONLY='F2 flash-boot.sh: ANDROID_IMAGE=1 + BOOTIMG*' sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/old" > "$W/o" 2>&1; judge "F2 on $OLD_REV: flash-boot.sh writes the shim" "$W/o"
ONLY='F3 test-boot.sh: the Mi A3*' sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/old" > "$W/o" 2>&1; judge "F3 on $OLD_REV: test-boot.sh boots on any phone" "$W/o"

echo "== each fix taken out of this tree"
copy; mutate scripts/laurel/android-guard.sh '[ -n "$ok" ] || refuse' ': || refuse'
guard "F2: no hash check" 'F2 boot-image: a shim*'
copy; mutate scripts/laurel/android-guard.sh "'LAURELESP|rd=ufsroot0|ufsrw=|rootrw=|Darwin Kernel Version|xnu-[0-9]+\\.|SWEETXNU|LAUREL BUILD'" "'LAURELESP'"
guard "F2: only the old label is searched" "F2 boot-image: 'rd=ufsroot0'*"
copy; mutate scripts/flash/test-boot.sh '"$G" other-device-fastboot   # this script is for the OnePlus 10 Pro: the Mi A3 holds Android' ':'
mutate scripts/flash/test-boot.sh '"$G" other-device-fastboot   # the phone on the cable can have changed during the flash' ':'
guard "F3: no guard in test-boot.sh" 'F3 test-boot.sh: the Mi A3*'
copy; mutate scripts/laurel/android-guard.sh '[ "$(boot_os_raw "$img")" = "$(boot_os_raw "$lb")" ] || refuse' ': || refuse'
guard "S1: the guard does not compare the header" 'S1 boot-image: the stock*'
copy; mutate scripts/laurel/uefi-image.sh 'OS_VERSION=$(boot_os_version "$os_raw"); OS_PATCH=$(boot_os_patch "$os_raw")' 'OS_VERSION=11.0.0; OS_PATCH=2022-08'
guard "S1: the image keeps the stock header" 'S1 uefi-image.sh*'
copy; mutate scripts/laurel/android-guard.sh 'grep -q "^ro-on $m " "$r" 2>/dev/null || refuse' ': || refuse'
mutate scripts/laurel/android-guard.sh "grep -q '^android-opened-after-ro ' \"\$r\" 2>/dev/null || refuse" ': || refuse'
guard "RO gate: the guard lets a writable image go" 'RO gate boot-image: a writable image, no*'
copy; mutate scripts/laurel/uefi-image.sh 'CMDLINE=${CMDLINE/ ufsrw=1 rootrw=1/}' ':'
guard "RO: LAUREL_READONLY=1 keeps ufsrw" 'S1 uefi-image.sh*'
copy; mutate scripts/laurel/dual-boot.sh '  70:0|1:0|1:no|70:no|1:) echo no ;;
  *) echo "unknown (exit $_r: $_a)" ;;' '  *) echo no ;;'
script "F5: a bootctl error reads as no" 'F5 switch: bootctl error on slot b*'
copy; mutate scripts/laurel/dual-boot.sh '  check_fw_b
  ash bootctl set-active-boot-slot 1' '  ash bootctl set-active-boot-slot 1'
script "S3: switch does not check the firmware" 'S3 switch: xbl_b*'
copy; mutate scripts/laurel/dual-boot.sh 'if ! "$TOOL" gpt same' 'if ! true || false && "$TOOL" gpt same'
script "GPT: no fresh read against the backup" 'GPT write: the table on the phone differs*'
copy; mutate scripts/laurel/dual-boot.sh '"$TOOL" gpt verify-new --head "$G/after.head" --tail "$G/after.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin" ||' 'true ||'
mutate tools/laurel-dualboot/ldbhelper.c 'dev_write(fd, s->lba, s->newb, s->blocks);' ';'
mutate tools/laurel-dualboot/ldbhelper.c 'if (!blk_eq(io, s->newb, s->blocks * BLK)) {
				die("a block reads back wrong", 0);
			}' ''
mutate tools/laurel-dualboot/ldbhelper.c 'if (state_of(fd, count, &total) != total) {
		die("the new table does not read back in full", 0);
	}' ''
script "GPT: a write that did nothing is called good" 'GPT write: all well*'
copy; mutate scripts/laurel/dual-boot.sh '[ "$((_bc * 4096))" -le "$USERDATA_BYTES" ] || die' ': || die'
script "Format: a stale superblock passes android-check" 'Android check: a stale*'
copy; mutate scripts/laurel/flash-root.sh '[ -n "$_s" ] || die "the phone has no partition iosroot' ': || die "the phone has no partition iosroot'
mutate scripts/laurel/dual-boot.sh '[ -n "$_i" ] || die "ABL sees no partition iosroot' ': || die "ABL sees no partition iosroot'
mutate scripts/laurel/dual-boot.sh '[ "$((_i))" = "$IOSROOT_BYTES" ] && [ "$((_u))" = "$USERDATA_BYTES" ] || die' ': || die'
mutate scripts/laurel/flash-root.sh '[ "$((_s))" = "$IOSROOT_BYTES" ] || die' ': || die'
script "Install: no check of the partition" 'Install: ABL sees no iosroot*'

echo "== the helper: the order of the steps and the state check"
HC="clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w -DLDB_TEST_FILE"
copy; mutate tools/laurel-dualboot/ldbhelper.c 'die("the table on the device is not the one this plan was made from: nothing written by this run", 0);' 'seen_old = true;'
$HC -o "$W/h1" "$W/t/tools/laurel-dualboot/ldbhelper.c"
LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/h1" "$TOOL" > "$W/o" 2>&1; judge "helper: a table that is not the plan's is written over" "$W/o"
copy; mutate tools/laurel-dualboot/ldbhelper.c 'die("the plan is damaged", 0);' ';'
$HC -o "$W/h2" "$W/t/tools/laurel-dualboot/ldbhelper.c"
LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/h2" "$TOOL" > "$W/o" 2>&1; judge "helper: a damaged plan runs" "$W/o"

echo "== the kernel: the new test over the real driver with the fence taken out"
X=$OUT/laurel-kernel/xnu-src/xnu-8796.141.3/bsd/dev/sweet_ufs.c
[ -f "$X" ] || { echo "dualboot-tests-detect: no patched tree: AUDIT=1 scripts/laurel/kernel-linux.sh" >&2; exit 1; }
kernel() {  # NAME FROM TO: build test_kernel over the driver with this one change
  K=$W/k; rm -rf "$K"; mkdir -p "$K/sys" "$K/miscfs/devfs" "$K/kern" "$K/machine" "$K/arm" "$K/vm" "$K/pexpert" "$K/libkern"
  for h in sys/param.h sys/systm.h sys/buf.h sys/conf.h sys/disk.h sys/errno.h sys/proc.h sys/uio.h sys/sysctl.h miscfs/devfs/devfs.h kern/locks.h kern/clock.h kern/sched_prim.h machine/machine_routines.h arm/caches_internal.h vm/pmap.h vm/vm_kern.h pexpert/pexpert.h pexpert/device_tree.h libkern/libkern.h machine/atomic.h kern/kalloc.h; do : > "$K/$h"; done
  sed -e 's/^ufs_scsi(const uint8_t \*cdb/ufs_scsi_hw(const uint8_t *cdb/' -e 's/\bufs_scsi(\([a-z]\)/ufs_scsi_fake(\1/g' "$X" > "$K/sweet_ufs_host.c"
  sed -i '1i static int ufs_scsi_fake(const uint8_t *cdb, unsigned cdb_len, uint32_t len, bool write);' "$K/sweet_ufs_host.c"
  cp "$REPO/tools/laurel-dualboot/laurel_dualboot.h" "$K/"
  python3 -I - "$K/sweet_ufs_host.c" "$K/laurel_dualboot.h" "$2" "$3" <<'PY' || { echo "dualboot-tests-detect: FAILED: mutation: $2" >&2; exit 1; }
import sys
a, b, x, y = sys.argv[1:]
for p in (a, b):
    s = open(p).read()
    if x in s:
        open(p, 'w').write(s.replace(x, y)); sys.exit(0)
sys.exit(1)
PY
  N=$REPO/tools/laurel-dualboot/test
  clang -std=gnu11 -O1 -g -w -I"$K" -I"$N" -o "$W/test_kernel" "$N/test_kernel.c" > "$W/kb" 2>&1 || { cat "$W/kb" | head; echo "NOT BUILT: $1"; rc=1; return; }
  r=0; "$W/test_kernel" > "$W/o" 2>&1 || r=$?
  [ "$r" != 0 ] && [ "$(grep -c '^FAIL' "$W/o")" -gt 0 ] && echo "ok   detected: $1 ($(grep -c '^FAIL' "$W/o") checks fail)" || { echo "NOT DETECTED: $1"; rc=1; }
}
kernel "fence: no compare with iosroot" 'lba < ldb.first || lba - ldb.first >= ldb.blocks || count > ldb.blocks - (lba - ldb.first) ||' ''
kernel "fence: open when the self-check said no" 'if (!ldb.on || su.lun != 0 ||' 'if (su.lun != 0 ||'
kernel "fence: any LUN" 'if (!ldb.on || su.lun != 0 ||' 'if (!ldb.on ||'
kernel "self-check: no layout rules" 'const char *why = ldb_gpt_layout_check(ldb_ph, ldb_pe, ldb_bh, ldb_be, &first, &blocks);' 'const char *why = ldb_gpt_layout_check(ldb_ph, ldb_pe, ldb_bh, ldb_be, &first, &blocks); why = NULL; first = su.first_block; blocks = su.nblocks;'
kernel "self-check: no HFS+ check" 'if (hfs == 0) {' 'if (0) {'
kernel "rules: the two copies may differ" 'if (pe[i] != be[i]) {' 'if (0) {'
kernel "root: the kernel takes userdata" 'const char *want = LDB_ROOT_NAME;' 'const char *want = "userdata";'
echo "dualboot-tests-detect: $([ "$rc" = 0 ] && echo "every fix is found by its test" || echo "SOME FIXES ARE NOT FOUND")"
exit "$rc"
