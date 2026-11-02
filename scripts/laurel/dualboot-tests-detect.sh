#!/bin/sh
# Do the dual boot tests find the defects? For each fix: a copy of the tree with exactly that fix taken out (the old behaviour put back), and the test that names it. That test must FAIL there.
#   scripts/bg.sh db-detect scripts/laurel/dualboot-tests-detect.sh      ONLY_NEW=1: only the block of the install read-back (INSTALL_REV)
# The file design's code is gone, so "the old code" is this: the lines of the fix reversed. F2, F3 also run against the commit before this work (OLD_REV, default 378b2e9), where those scripts exist.
# The GPT fixes: the new tests run on the commit before them (GPT_REV, default 9cad90f), with that commit's scripts, helper, op10tool and driver: each must fail there.
# Needs the patched kernel tree (AUDIT=1 scripts/laurel/kernel-linux.sh or a build) and a built op10tool. No phone, the same fakes as the tests. Writes only under out/.
set -u
. "$(dirname "$0")/../lib/env.sh"
OLD_REV=${OLD_REV:-378b2e9}
GPT_REV=${GPT_REV:-9cad90f}     # the commit before the GPT fixes (docs/laurel_sprout/dual-boot.md): each new test runs against that code, with its own op10tool and its own helper
W=$OUT/laurel-dualboot-detect
TOOL=${OP10TOOL:-${CARGO_TARGET_DIR:-$OUT/cargo}/release/op10tool}
rm -rf "$W"; mkdir -p "$W"
rc=0
INSTALL_REV=${INSTALL_REV:-f1f8216}     # the commit before the install read-back: dual-boot.md step 6b
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

# ---- the install read-back and its review (F1 to F9): the new tests on the code of $INSTALL_REV. Each must FAIL there. Shows the test's own FAIL lines.
install_block() {
  echo "== the commit before the install read-back ($INSTALL_REV): the new tests on the old code: each must FAIL"
  I=$W/inst; rm -rf "$I"; mkdir -p "$I"; git -C "$REPO" archive "$INSTALL_REV" scripts tools/laurel-dualboot tools/op10tool userland/laurel/notch userland/laurel/flashlight userland/laurel/xnutils | tar -x -C "$I"
  cargo build --release --manifest-path "$I/tools/op10tool/Cargo.toml" --target-dir "$W/inst-cargo" > "$W/inst-cargo.log" 2>&1 || { tail -20 "$W/inst-cargo.log"; echo "dualboot-tests-detect: FAILED: the old op10tool does not build" >&2; exit 1; }
  ITOOL=$W/inst-cargo/release/op10tool
  i_script() { ONLY="$2" OP10TOOL=$ITOOL sh "$REPO/scripts/laurel/dual-boot-test.sh" "$I" > "$W/o" 2>&1; judge "$1" "$W/o"; grep -E '^FAIL' "$W/o" | cut -c1-210 | head -"${3:-2}" | sed 's/^/     /'; }
  i_guard() { ONLY="$2" sh "$REPO/scripts/laurel/android-guard-test.sh" "$I" > "$W/o" 2>&1; judge "$1" "$W/o"; grep -E '^FAIL' "$W/o" | cut -c1-210 | head -"${3:-6}" | sed 's/^/     /'; }
  i_script "F1: all well needs a verify-root the old code does not have" 'F1 install, verify-root, switch*'
  i_script "F1: a lost last piece" 'F1 ABL says OKAY*'
  i_script "F1: one byte in a range" 'F1 one byte damaged*'
  i_script "F1: switch with no read-back goes" 'F1 switch with no read-back*'
  i_script "F1: a failed later flash keeps the old record" 'F1 a later flash voids the read-back: a failed one*'
  i_script "F2: a stage failure blocks a good flash" 'F2 install: no fastboot stage*'
  i_script "F2: ABL hangs at reboot: no limit" 'F2 ABL hangs at fastboot reboot*'
  i_script "F3: the record before pm" 'F3 Android check: Updater disable fails*'
  i_script "F3: pm fails after the read-only boot" 'F3 Android check after the read-only boot*'
  i_script "F4: a failed img2simg says ready" 'F4 prepare-root: img2simg fails*'
  i_script "F6: one getvar with no answer: wrong advice" 'F6 flash-root: one getvar*'
  i_script "F6: one garbled size: a shell error" 'F6 flash-root: one garbled*'
  i_script "F6: a garbled size in need_fastboot_layout" 'F6 dual-boot: a garbled*'
  i_guard "F5: the inputs of the FD" 'F5*' 8
  sh "$REPO/scripts/laurel/wrap-guard-test.sh" "$I" > "$W/o" 2>&1; judge "F7: an unwritable state file keeps the library" "$W/o"; grep -E '^FAIL' "$W/o" | cut -c1-210 | sed 's/^/     /'
  sh "$REPO/scripts/laurel/root-helper-test.sh" "$I" > "$W/o" 2>&1; judge "F9: the helper reads a planted name" "$W/o"; grep -E '^FAIL' "$W/o" | cut -c1-210 | sed 's/^/     /'
  sed 's/uint64_t allow = proc_issetugid(p) ? 0 : SWEET_AMFI_DYLD_ALLOW_ALL;/uint64_t allow = SWEET_AMFI_DYLD_ALLOW_ALL;/' "$OUT/laurel-kernel/xnu-src/xnu-8796.141.3/bsd/kern/sweet_amfi.c" > "$W/sweet_amfi-old.c"
  sh "$REPO/scripts/laurel/amfi-dyld-test.sh" "$W/sweet_amfi-old.c" > "$W/o" 2>&1; judge "F9: the kernel answers all to a setuid process" "$W/o"; grep -E '^FAIL' "$W/o" | cut -c1-210 | sed 's/^/     /'
  git -C "$REPO" show "$INSTALL_REV:scripts/laurel/ios26-root-spec.py" > "$REPO/scripts/laurel/.old-root-spec.py"
  python3 -I "$REPO/scripts/laurel/.old-root-spec.py" --self-test > "$W/spec.out" 2>&1; sr=$?; rm -f "$REPO/scripts/laurel/.old-root-spec.py"
  if [ "$sr" != 0 ] && grep -q KeyError "$W/spec.out"; then echo "ok   detected: F8: the old self-test stops with a KeyError with no stages (exit $sr): $(grep KeyError "$W/spec.out" | tail -1 | cut -c1-120)"; else echo "note F8: the old self-test: exit $sr, no KeyError here: the stages of this checkout are all on"; fi
}
install_block
if [ "${ONLY_NEW:-0}" = 1 ]; then
  [ "$rc" = 0 ] && echo "dualboot-tests-detect: PASS (the new block only)"
  exit "$rc"
fi

echo "== the commit before this work ($OLD_REV), scripts as they were"
rm -rf "$W/old"; mkdir -p "$W/old"; git -C "$REPO" archive "$OLD_REV" scripts tools/laurel-dualboot | tar -x -C "$W/old"
ONLY='F2 boot-image: a shim*' sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/old" > "$W/o" 2>&1; judge "F2 on $OLD_REV: ANDROID_IMAGE=1 lets a shim through" "$W/o"
ONLY='F2 flash-boot.sh: ANDROID_IMAGE=1 + BOOTIMG*' sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/old" > "$W/o" 2>&1; judge "F2 on $OLD_REV: flash-boot.sh writes the shim" "$W/o"
ONLY='F3 test-boot.sh: the Mi A3*' sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/old" > "$W/o" 2>&1; judge "F3 on $OLD_REV: test-boot.sh boots on any phone" "$W/o"

echo "== the commit before the GPT fixes ($GPT_REV): the new tests on the old code: each must FAIL"
rm -rf "$W/gpt"; mkdir -p "$W/gpt"; git -C "$REPO" archive "$GPT_REV" scripts tools/laurel-dualboot tools/op10tool | tar -x -C "$W/gpt"
cargo build --release --manifest-path "$W/gpt/tools/op10tool/Cargo.toml" --target-dir "$W/gpt-cargo" > "$W/gpt-cargo.log" 2>&1 || { tail -20 "$W/gpt-cargo.log"; echo "dualboot-tests-detect: FAILED: the old op10tool does not build" >&2; exit 1; }
OLD_TOOL=$W/gpt-cargo/release/op10tool
OHC="clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w"
$OHC -DLDB_TEST_FILE -o "$W/old-helper" "$W/gpt/tools/laurel-dualboot/ldbhelper.c"
$OHC -o "$W/old-direct" "$W/gpt/tools/laurel-dualboot/ldbhelper.c"
clang -std=gnu11 -O1 -w -o "$W/dio_check" "$REPO/tools/laurel-dualboot/test/dio_check.c"
# shows what the old code answers: the test's own FAIL lines, for the report
judge_old() { judge "$1" "$W/o"; grep -E '^FAIL|^dio_check: EINVAL' "$W/o" | cut -c1-200 | head -"${2:-2}" | sed 's/^/     /'; }
old_helper() { ONLY="$2" LDB_DIRECT=$W/old-direct LDB_DIO=$W/dio_check LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/old-helper" "$TOOL" > "$W/o" 2>&1; judge_old "$1" "${3:-2}"; }
old_script() { ONLY="$2" OP10TOOL=$OLD_TOOL sh "$REPO/scripts/laurel/dual-boot-test.sh" "$W/gpt" > "$W/o" 2>&1; judge_old "$1" "${3:-2}"; }
old_guard() { ONLY="$2" sh "$REPO/scripts/laurel/android-guard-test.sh" "$W/gpt" > "$W/o" 2>&1; judge_old "$1" "${3:-2}"; }
old_helper "F1 on $GPT_REV: O_DIRECT, gpt-write: EINVAL" 'F1 gpt-write of the phone*' 3
old_helper "F1 on $GPT_REV: O_DIRECT, the restore plan: EINVAL" "F1 gpt-restore's*" 3
old_script "F2 on $GPT_REV: restore in recovery" 'F2 restore in recovery: state*'
old_script "F2 on $GPT_REV: restore dry run in recovery" 'F2 restore dry run*'
old_script "F3 on $GPT_REV: restore after a slot change" 'F3 restore after a slot change*'
old_script "F3 on $GPT_REV: restore stopped after step 2" 'F3 restore stopped*'
old_helper "F4 on $GPT_REV: header new, entries old" 'F4 header new*'
old_helper "F4 on $GPT_REV: entries new, header old" 'F4 entries new*'
old_helper "F4 on $GPT_REV: header neither" 'F4 header neither*'
old_script "F4 on $GPT_REV: --resume on a torn primary" 'F4 a torn primary, Android*'
old_script "F4 on $GPT_REV: gpt-restore in recovery on a torn primary" 'F4 a torn primary, recovery: gpt-restore*'
old_script "F5 on $GPT_REV: a newer backup after the write" 'F5 a backup after the write is newer: restore*'
old_script "F5 on $GPT_REV: --resume with a newer backup" 'F5 a backup after the write is newer: --resume*'
old_script "F5 on $GPT_REV: no record, no clear error" 'F5 no record*'
old_script "F6 on $GPT_REV: --resume truncates the record" 'F6 --resume, the new table*'
for g in 'ufsrw=0x1' 'ufsrw=01' 'rootrw=0x1'; do old_guard "F7 on $GPT_REV: guard, $g" "F7 boot-image: '$g'*"; done
old_guard "F7 on $GPT_REV: uefi-image.sh" 'F7 uefi-image.sh' 3
old_script "F9 on $GPT_REV: the printed text" 'F9 *'
old_script "S1 on $GPT_REV: after-gpt dies at the refused reboot" 'S1 after-gpt*'
old_script "S1 on $GPT_REV: no rehearsal guide" 'S1 rehearsal: the guide*'
old_script "S1 on $GPT_REV: step 2 with no rehearsal" 'S1 guard: step 2*'
old_script "S2 on $GPT_REV: rehearsal in recovery" 'S2 rehearsal recovery: root*'
old_script "S2 on $GPT_REV: no root: the guard" 'S2 guard*'
old_helper "S5 on $GPT_REV: a second writer" 'S5 a writer holds*'
old_script "O on $GPT_REV: a stale op10tool" 'O stale op10tool by hand*'
# the new kernel test over the old driver: this tree's 2950 taken out, the old one put in
X0=$OUT/laurel-kernel/xnu-src/xnu-8796.141.3/bsd/dev/sweet_ufs.c
if [ -f "$X0" ]; then
  K=$W/kold; rm -rf "$K"; mkdir -p "$K/sys" "$K/miscfs/devfs" "$K/kern" "$K/machine" "$K/arm" "$K/vm" "$K/pexpert" "$K/libkern"
  for h in sys/param.h sys/systm.h sys/buf.h sys/conf.h sys/disk.h sys/errno.h sys/proc.h sys/uio.h sys/sysctl.h miscfs/devfs/devfs.h kern/locks.h kern/clock.h kern/sched_prim.h machine/machine_routines.h arm/caches_internal.h vm/pmap.h vm/vm_kern.h pexpert/pexpert.h pexpert/device_tree.h libkern/libkern.h machine/atomic.h kern/kalloc.h; do : > "$K/$h"; done
  cp "$X0" "$K/drv.c"
  sed -n '/^diff -ruN a\/bsd\/dev\/sweet_ufs.c/,$p' "$REPO/patches/laurel/xnu/2950-laurel-dual-boot.patch" | patch -R -s -p0 "$K/drv.c"
  git -C "$REPO" show "$GPT_REV:patches/laurel/xnu/2950-laurel-dual-boot.patch" | sed -n '/^diff -ruN a\/bsd\/dev\/sweet_ufs.c/,$p' | patch -s -p0 "$K/drv.c"
  sed -e 's/^ufs_scsi(const uint8_t \*cdb/ufs_scsi_hw(const uint8_t *cdb/' -e 's/\bufs_scsi(\([a-z]\)/ufs_scsi_fake(\1/g' "$K/drv.c" > "$K/sweet_ufs_host.c"
  sed -i '1i static int ufs_scsi_fake(const uint8_t *cdb, unsigned cdb_len, uint32_t len, bool write);' "$K/sweet_ufs_host.c"
  cp "$W/gpt/tools/laurel-dualboot/laurel_dualboot.h" "$K/"
  N=$REPO/tools/laurel-dualboot/test
  clang -std=gnu11 -O1 -g -w -I"$K" -I"$N" -o "$W/test_kernel_old" "$N/test_kernel.c" > "$W/kb" 2>&1 || { head "$W/kb"; echo "NOT BUILT: the new kernel test over the old driver"; rc=1; }
  "$W/test_kernel_old" > "$W/o" 2>&1
  for f in F7 F8; do
    if grep -q "^FAIL.*$f " "$W/o"; then echo "ok   detected: $f on $GPT_REV: the new kernel test over the old driver: $(grep -c "^FAIL.*$f " "$W/o") checks fail"; grep "^FAIL.*$f " "$W/o" | cut -c1-200 | head -2 | sed 's/^/     /'; else echo "NOT DETECTED: $f on $GPT_REV"; rc=1; fi
  done
fi

echo "== each fix taken out of this tree"
copy; mutate tools/laurel-dualboot/ldbhelper.c 'long r = sc(SYS_pwrite, fd, (long)wr,' 'long r = sc(SYS_pwrite, fd, (long)p,'
clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w -DLDB_TEST_FILE -o "$W/hm" "$W/t/tools/laurel-dualboot/ldbhelper.c"
clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w -o "$W/hd" "$W/t/tools/laurel-dualboot/ldbhelper.c"
ONLY='F1 *' LDB_DIRECT=$W/hd LDB_DIO=$W/dio_check LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/hm" "$TOOL" > "$W/o" 2>&1; judge "F1: the write from the plan's bytes" "$W/o"
copy; mutate tools/laurel-dualboot/ldbhelper.c '} else if (s->lba == 1 && !seen_old) {' '} else if (0) {'
clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w -DLDB_TEST_FILE -o "$W/hm" "$W/t/tools/laurel-dualboot/ldbhelper.c"
ONLY='F4 header new*' LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/hm" "$TOOL" > "$W/o" 2>&1; judge "F4: a torn primary is refused" "$W/o"
copy; mutate tools/laurel-dualboot/ldbhelper.c '} else if (s->lba == 1 && !seen_old) {' '} else if (s->lba == 1) {'
clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w -DLDB_TEST_FILE -o "$W/hm" "$W/t/tools/laurel-dualboot/ldbhelper.c"
ONLY='F4 a torn primary with an old*' LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/hm" "$TOOL" > "$W/o" 2>&1; judge "F4: a torn primary goes on with no valid backup" "$W/o"
copy; mutate tools/laurel-dualboot/ldbhelper.c '	writer_lock(planpath);
' ''
clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w -DLDB_TEST_FILE -o "$W/hm" "$W/t/tools/laurel-dualboot/ldbhelper.c"
ONLY='S5 a writer holds*' LDB_TEST_DIR=$W sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$W/hm" "$TOOL" > "$W/o" 2>&1; judge "S5: no lock" "$W/o"
copy; mutate scripts/laurel/dual-boot.sh '[ "$DRY" = 1 ] || need_rehearsal' ':'
script "S1: step 2 needs no rehearsal" 'S1 guard: step 2*'
copy; mutate scripts/lib/laurel-layout.sh "| LC_ALL=C grep -avE '^(ufsrw|rootrw)=0\$' " "| LC_ALL=C grep -aE '=[1-9]' "
guard "F7: only a value from 1 to 9 counts" "F7 boot-image: 'ufsrw=0x1'*"
copy; mutate scripts/laurel/dual-boot.sh '  if [ "$RESUME" = 1 ] && "$TOOL" gpt verify-new' '  if false && "$TOOL" gpt verify-new'
script "F6: --resume does not look first" 'F6 --resume, the new table*'
copy; mutate scripts/laurel/dual-boot.sh '  if ! fastboot -s "$FB_S" reboot recovery; then
    say "ABL refused' '  fastboot -s "$FB_S" reboot recovery; if false; then
    say "ABL refused'
script "S1: after-gpt dies at the refused reboot" 'S1 after-gpt*'
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
mutate tools/laurel-dualboot/ldbhelper.c 'if (state_of(fd, count, &total, &torn) != total) {
		die("the new table does not read back in full", 0);
	}' ''
script "GPT: a write that did nothing is called good" 'GPT write: all well*'
copy; mutate scripts/laurel/dual-boot.sh '  need_root_verified
  _inst=$(sed' '  _inst=$(sed'
script "F1: switch asks for no read-back" 'F1 switch with no read-back*'
copy; mutate scripts/laurel/flash-root.sh '>> "$OUT/laurel/dualboot/first-boot.result"' '> /dev/null'
script "F1: a later flash leaves the record of the old read-back" 'F1 a later flash voids*'
copy; mutate scripts/laurel/dual-boot.sh '[ "$((_bc * 4096))" -le "$USERDATA_BYTES" ] || die' ': || die'
script "Format: a stale superblock passes android-check" 'Android check: a stale*'
copy; mutate scripts/laurel/flash-root.sh '[ -n "$_s" ] || die "ABL names no partition iosroot' ': || die "ABL names no partition iosroot'
mutate scripts/laurel/dual-boot.sh '[ -n "$_i" ] || die "ABL sees no partition iosroot' ': || die "ABL sees no partition iosroot'
mutate scripts/laurel/dual-boot.sh '[ "$((_i))" = "$IOSROOT_BYTES" ] && [ "$((_u))" = "$USERDATA_BYTES" ] || die' ': || die'
mutate scripts/laurel/flash-root.sh '[ "$((_s))" = "$IOSROOT_BYTES" ] || die' ': || die'
mutate scripts/laurel/flash-root.sh 'laurel_size_ok "$_s" || die "ABL gives iosroot' ': || die "ABL gives iosroot'
mutate scripts/laurel/dual-boot.sh 'laurel_size_ok "$_i" && laurel_size_ok "$_u" || die' ': || die'
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
kernel "F8: the block count holds the log" '*o = ldb_bsd_blocks() * UFS_BLOCK / su.secsize;' '*o = su.nblocks * UFS_BLOCK / su.secsize;'
kernel "F8: BSD I/O reaches the log" 'uint64_t part_bytes = ldb_bsd_blocks() * UFS_BLOCK;' 'uint64_t part_bytes = su.nblocks * UFS_BLOCK;'
kernel "F7: any number opens writes" "rw = rw_text[0] == '1' && rw_text[1] == '\\0';" "rw = rw_text[0] != '0';"
echo "dualboot-tests-detect: $([ "$rc" = 0 ] && echo "every fix is found by its test" || echo "SOME FIXES ARE NOT FOUND")"
exit "$rc"
