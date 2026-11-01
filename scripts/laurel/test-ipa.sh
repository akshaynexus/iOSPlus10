#!/bin/sh
# Host test of the IPA v4.2 AP side (patches 2775 + 2780 + 2782), with the kernel files taken from the patches:
#   1. qmi_test: QMI 0x31 messages (INIT_MODEM_DRIVER bytes vs the 4.14 driver, its answer, our service, indication)
#   2. pas_test part 1: the shared PAS loader (topaz_pas.c) with a simulated TrustZone and the stock ipa_fws layout
#   3. ext4_test + pas_test part 2: the ext4 reader and lipa_fw_load() against the stock vendor image (raw ext4,
#      or Android sparse with simg2img), compared with debugfs (e2fsprogs) dumps. Skipped with a note when there
#      is no image: out/ipa-fw/vendor.raw or vendor.img (or VENDOR_IMG=...). The image never goes into git.
#   4. gsi_test: GSI channel allocation against a simulated GSI (stock order and command words, failure paths)
#   5. gate_test: laurel_ipa.c + _link.c: no NEW_SERVER or INIT_MODEM_DRIVER before all self-checks passed
#   6. ipa_cell_test: laurel_ipa*.c + laurel_cell.c (2760 + 2780 + 2786) together: ONLINE only after LAUREL IPA: on, also when the modem's first mode read says 5;
#      a modem assert after INIT_MODEM_DRIVER leaves no ONLINE; ipa=0 keeps the radio off
# macOS and Linux (needs cc; debugfs optional). Quick, foreground is fine.
#   scripts/laurel/test-ipa.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
P_PAS=$REPO/patches/laurel/xnu/2775-laurel-pas-load.patch
P_IPA=$REPO/patches/laurel/xnu/2780-laurel-ipa-v42.patch
P_GSI=$REPO/patches/laurel/xnu/2782-laurel-ipa-gsi-channels.patch
D=$OUT/laurel-ipa-test
T=$REPO/tools/laurel-ipa-test
rm -rf "$D"
mkdir -p "$D/inc/sys" "$D/inc/kern" "$D/inc/mach" "$D/inc/pexpert" "$D/out" "$D/ref"

# a new file of a patch (only "+" lines of its one hunk)
extract() {
  awk -v f="$2" '$0 == "+++ b/bsd/dev/" f || index($0, "+++ b/bsd/dev/" f "\t") == 1 {p=1; next}
       p && /^diff / {exit}
       p && /^@@/ {next}
       p && /^\+/ {print substr($0, 2)}' "$1" > "$D/$2"
  [ -s "$D/$2" ] || { echo "test-ipa: no bsd/dev/$2 in $1" >&2; exit 1; }
}
for f in laurel_ext4.c laurel_ext4_dir.c laurel_ext4.h laurel_ipa.c laurel_ipa_hw.c laurel_ipa_qmi.c laurel_ipa_fw.c laurel_ipa_regs.h; do
  extract "$P_IPA" $f
done
# 2782 changes these files and adds laurel_ipa_gsi.c + laurel_ipa_link.c (its bsd/conf/files part is not for the test)
awk '/^diff / {p = index($0, "bsd/dev/") != 0} p' "$P_GSI" | (cd "$D" && patch -s -p3) || { echo "test-ipa: 2782 does not apply" >&2; exit 1; }
# 2941: the AP data pipes: changes these files, adds laurel_ipa_data.c + laurel_ipa_data2.h
awk '/^diff / {p = index($0, "bsd/dev/") != 0} p' "$REPO/patches/laurel/xnu/2941-laurel-ipa-data-path.patch" | (cd "$D" && patch -s -p3) || { echo "test-ipa: 2941 does not apply" >&2; exit 1; }
for f in topaz_pas.c topaz_pas.h; do extract "$P_PAS" $f; done
# the ARM barrier of topaz_pas.c on an x86 host: a full compiler + CPU fence (same meaning for the test)
case "$(uname -m)" in arm64|aarch64) ;; *) sed -i.bak 's/__asm__ volatile ("dsb sy" ::: "memory")/__sync_synchronize()/' "$D/topaz_pas.c" "$D/laurel_ipa_data.c" ;; esac
for h in sys/param.h sys/systm.h sys/errno.h sys/sysctl.h kern/kalloc.h kern/clock.h kern/locks.h kern/thread.h mach/mach_time.h \
    pexpert/pexpert.h; do
  echo '#include "kstub_ipa.h"' > "$D/inc/$h"
done
CC=${CC:-$(command -v clang || echo cc)}
# -Wno-format: Linux hosts have uint64_t = unsigned long (the kernel: unsigned long long, %llx); the kernel build checks formats
CF="-DARM64_BOARD_CONFIG_SWEET=1 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-parameter -Wno-format -I$D/inc -I$T -I$REPO/tools/laurel-cell-test -I$D"
# shellcheck disable=SC2086
$CC $CF -o "$D/qmi_test" "$T/qmi_test.c"
# shellcheck disable=SC2086
$CC $CF -o "$D/ext4_test" "$T/ext4_test.c"
# shellcheck disable=SC2086
$CC $CF -o "$D/pas_test" "$T/pas_test.c" "$D/topaz_pas.c" "$D/laurel_ipa_fw.c" "$D/laurel_ext4.c" "$D/laurel_ext4_dir.c"
# shellcheck disable=SC2086
$CC $CF -o "$D/gsi_test" "$T/gsi_test.c"
# shellcheck disable=SC2086
$CC $CF -o "$D/gate_test" "$T/gate_test.c"
# shellcheck disable=SC2086
$CC $CF -o "$D/data_test" "$T/data_test.c"

# laurel_cell.c as the kernel has it: the new file of 2760, then the hunks of 2780 and 2786
extract "$REPO/patches/laurel/xnu/2760-laurel-cellular-qmi.patch" laurel_cell.c
for p in "$P_IPA" "$REPO/patches/laurel/xnu/2786-laurel-cell-radio-state.patch" "$REPO/patches/laurel/xnu/2940-laurel-cell-radio-online.patch" "$REPO/patches/laurel/xnu/2942-laurel-cell-data.patch"; do
  awk '/^diff / {p = ($0 ~ /b\/bsd\/dev\/laurel_cell\.c$/)} p' "$p" | (cd "$D" && patch -s -p0 laurel_cell.c) || { echo "test-ipa: $(basename "$p") does not apply to laurel_cell.c" >&2; exit 1; }
done
for f in laurel_cell_data.c laurel_cell_data2.h laurel_cell_data.h; do extract "$REPO/patches/laurel/xnu/2942-laurel-cell-data.patch" $f; done
# shellcheck disable=SC2086
$CC $CF -c -o "$D/laurel_cell.o" "$D/laurel_cell.c"
# shellcheck disable=SC2086
$CC $CF -c -o "$D/laurel_cell_data.o" "$D/laurel_cell_data.c"
# shellcheck disable=SC2086
$CC $CF -o "$D/ipa_cell_test" "$T/ipa_cell_test.c" "$D/laurel_cell.o" "$D/laurel_cell_data.o"

echo "== 1. QMI 0x31 messages"
"$D/qmi_test"
echo "== 4. GSI channels"
"$D/gsi_test"
echo "== 5. the gate before the handshake"
"$D/gate_test"
echo "== 6. IPA and cellular together"
"$D/ipa_cell_test"
echo "== 7. AP data pipes (2941)"
"$D/data_test"

IMG=${VENDOR_IMG:-}
[ -n "$IMG" ] || for c in "$OUT/ipa-fw/vendor.raw" "$OUT/ipa-fw/vendor.img"; do [ -f "$c" ] && { IMG=$c; break; }; done
if [ -n "$IMG" ] && [ "$(od -An -tx4 -N4 "$IMG" | tr -d ' ')" = ed26ff3a ]; then
  if command -v simg2img >/dev/null; then
    simg2img "$IMG" "$D/vendor.raw" && IMG=$D/vendor.raw
  else
    echo "note: $IMG is an Android sparse image and simg2img is missing: vendor image part skipped"; IMG=
  fi
fi
FILES="ipa_fws.mdt ipa_fws.b00 ipa_fws.b01 ipa_fws.b02 ipa_fws.b03 ipa_fws.b04"
if [ -z "$IMG" ]; then
  echo "== 2. shared PAS loader (no vendor image: put the stock vendor.img/raw into out/ipa-fw for part 3)"
  "$D/pas_test"
  echo "test-ipa: PASS (vendor image part skipped)"
  exit 0
fi
echo "== 3. ext4 reader on $IMG"
# shellcheck disable=SC2086
"$D/ext4_test" "$IMG" "$D/out" $(for f in $FILES; do printf '/firmware/%s ' $f; done)
if command -v debugfs >/dev/null; then
  for f in $FILES; do debugfs -R "dump -p /firmware/$f $D/ref/$f" "$IMG" >/dev/null 2>&1; done
  for f in $FILES; do cmp "$D/out/$f" "$D/ref/$f" || { echo "test-ipa: FAIL: $f differs from debugfs" >&2; exit 1; }; done
  echo "ok: the 6 ipa_fws files are byte-equal to debugfs"
  REF=$D/ref
else
  echo "note: no debugfs (e2fsprogs): part 3 compares with the ext4 reader's own files"
  REF=$D/out
fi
cat "$D/out/ipa_fws.b00" "$D/out/ipa_fws.b01" | cmp - "$D/out/ipa_fws.mdt" && echo "ok: ipa_fws.mdt = .b00 + .b01"
echo "== 2+3. shared PAS loader + lipa_fw_load end to end"
"$D/pas_test" "$IMG" "$REF"
echo "test-ipa: PASS"
