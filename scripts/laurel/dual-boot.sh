#!/bin/sh
# Mi A3 dual boot: LineageOS on slot a, iOS on boot_b, the iOS root in the GPT partition iosroot on LUN 0. Steps, reasons, recovery: docs/laurel_sprout/dual-boot.md.
# NOTHING HERE HAS RUN ON THE PHONE YET. Every step that writes needs CONFIRM=<its name>, and the owner's yes first. First path: iOS 26. TARGET=ios16 takes the iOS 16 inputs.
#   dual-boot.sh status                            read-only: slots, partitions, /data
#   dual-boot.sh check-slot-b                      read-only: slot b firmware against the backup's hashes (set-active moves the boot LUN to xbl_b)
#   dual-boot.sh gpt-plan                          host only: from the backup dumps: plan file, table before and after
#   dual-boot.sh gpt-write --dry-run               read-only: device check, fresh table = backup, the exact commands, the table before and after. Records which backup is the pre-write one: all later steps use only that one
#   dual-boot.sh record-backup DIR                 host only: another backup of the old table becomes the pre-write one (after "not the backup": slot attributes changed)
#   dual-boot.sh rehearsal                         the guide, and what is on record. Before step 2: how the phone reaches recovery, and whether recovery gives root adb. It writes no table and no partition of ours
#   CONFIRM=rehearsal-reach dual-boot.sh rehearsal reach    phone in fastboot: tries fastboot reboot recovery; a refusal is a result. If ABL accepts, ABL itself writes its boot message to misc [V source]
#   dual-boot.sh rehearsal recovery                phone in Lineage recovery, adb on: read-only gpt-dump there, a record. dual-boot.sh rehearsal no-adb: the owner sees no adb in recovery: a record
#   CONFIRM=gpt-write dual-boot.sh gpt-write       THE GPT WRITE, LUN 0 only: 4 table blocks, the 2 superblock blocks of userdata. Reads it back before any reboot. Android's data is gone after the next reboot
#   CONFIRM=after-gpt dual-boot.sh after-gpt       phone in fastboot (adb reboot bootloader): ABL must see the new sizes; then reboot to recovery. There the owner does Format data
#   dual-boot.sh android-check                     read-only: Android opened its data on the new layout; a record on the host
#   CONFIRM=install dual-boot.sh install [IMG]     phone in fastboot: the root image to iosroot (tmux). Only iosroot
#   dual-boot.sh image [rw]                        host only: boot image. Default read-only (no ufsrw, no rootrw); rw refuses until the read-only run is on record
#   CONFIRM=flash-slot-b dual-boot.sh flash-slot-b [rw]   phone in fastboot: boot_b = that image, dtbo_b = stock dtbo; Android stays active
#   CONFIRM=switch dual-boot.sh switch [rw]        Android -> iOS: all checks, slot b active, normal reboot
#   dual-boot.sh ro-result LOG                     host only: the line of the read-only boot from a USB log or typed from the screen: a record on the host
#   CONFIRM=to-android dual-boot.sh to-android     BACK TO ANDROID: phone in fastboot (Power + Vol Down, or op10tool ctl bootloader): fastboot set_active a, reboot
#   dual-boot.sh gpt-restore --dry-run; CONFIRM=gpt-restore dual-boot.sh gpt-restore    the old layout back, made from the table on the disk (slot attributes stay), from Android or a root shell in recovery. Then Format data again
#   dual-boot.sh gpt-repair --dry-run; CONFIRM=gpt-repair dual-boot.sh gpt-repair       a half-written primary (Android cannot start): written from a valid backup, nothing else, from recovery. Then the steps of that table
#   dual-boot.sh gpt-restore-print                 host only: the last resort over fastboot: prints it, runs nothing: it ERASES ALL OF LUN 0
# All adb steps need root adb: Settings -> System -> Developer options -> Rooted debugging (owner), then `adb root`. A wipe turns that setting off.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/lib/laurel-layout.sh"
D=$OUT/laurel/dualboot
G=$D/gpt
RESULT=$D/first-boot.result
PREWRITE=$D/pre-write-backup
REHEARSAL=$D/rehearsal.result
GPT_FEATURES=ldb-gpt-2
HELPER=/data/local/tmp/ldbhelper
SDA=/dev/block/sda
TOOL=${OP10TOOL:-$OUT/bin/op10tool}
APPLE=${APPLE:-$HOME/op10-apple}
TARGET=${TARGET:-ios26}
STOCK_DTBO=${STOCK_DTBO:-$HOME/laurel-backup/stock/images/dtbo.img}

say() { echo "dual-boot: $*"; }
die() { echo "dual-boot: FAILED: $*" >&2; exit 1; }
need_confirm() { [ "${CONFIRM:-}" = "$1" ] || { echo "dual-boot: refused: this step writes to the phone: CONFIRM=$1 (ask the owner first; docs/laurel_sprout/dual-boot.md)" >&2; exit 4; }; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
marker() { sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h"; }
image_path() { [ "${1:-ro}" = rw ] && echo "$OUT/laurel-$TARGET/uefi-rw/laurel-uefi-boot.img" || echo "$OUT/laurel-$TARGET/uefi-ro/laurel-uefi-boot.img"; }
default_root() { case "$TARGET" in ios26) echo "$APPLE/ios26/23F84-n104ap/root/ios26-root.img" ;; ios16) echo "$APPLE/laurel-ios16-root.img" ;; *) die "TARGET=$TARGET: ios26 or ios16" ;; esac; }
mode_arg() { case "${1:-}" in ""|ro) echo ro ;; rw) echo rw ;; *) die "'$1': only rw" ;; esac; }

# A command on the phone. stdout = its stdout, exit code = its REAL exit code, read from a marker line: a pipe here hid it, and an adb that stops early has no marker.
#   255: no marker (adb lost the phone, the result is unknown). 254: marker there but adb itself failed. Every caller acts on the code; a value goes through: v=$(ash ...) || die ...
ASH_MARK=__ldb_rc_$$__
NL='
'
ash() {
  _rc=0
  _o=$(adb shell "$*; _ldb_r=\$?; echo; echo $ASH_MARK\$_ldb_r") || _rc=$?
  _o=$(printf '%s' "$_o" | tr -d '\r')
  _last=${_o##*"$NL"}
  case "$_last" in
  "$ASH_MARK"[0-9]*) ;;
  *)
    [ -z "$_o" ] || printf '%s\n' "$_o"
    echo "dual-boot: no status from the phone for: $*" >&2
    return 255 ;;
  esac
  _rr=${_last#"$ASH_MARK"}
  case "$_rr" in *[!0-9]*) return 255 ;; esac
  _o=${_o%"$_last"}; _o=${_o%"$NL"}; _o=${_o%"$NL"}
  [ -z "$_o" ] || printf '%s\n' "$_o"
  [ "$_rc" = 0 ] || return 254
  return "$_rr"
}
# The op10tool of this source. A stale binary has no gpt command, and "not the backup" from it would be wrong. OP10TOOL= by hand is only checked.
tool_ok() { [ -x "$TOOL" ] && [ "$("$TOOL" gpt features 2>/dev/null)" = "$GPT_FEATURES" ]; }
need_tool() {
  tool_ok && return 0
  if [ -z "${OP10TOOL:-}" ] && command -v cargo >/dev/null 2>&1; then
    say "$TOOL has no GPT support of this source ($GPT_FEATURES): building it now: scripts/setup/build-op10tool.sh"
    "$REPO/scripts/setup/build-op10tool.sh" >&2 || die "scripts/setup/build-op10tool.sh failed"
    tool_ok && return 0
  fi
  die "$TOOL has no GPT support of this source ($GPT_FEATURES). Build it: scripts/bg.sh op10tool scripts/setup/build-op10tool.sh. Nothing was asked of the phone"
}
# $1 = recovery-ok: gpt-restore, gpt-repair and the rehearsal also run in Lineage recovery. adb get-state says recovery there. No /data is mounted: the helper goes to /tmp.
need_android() {
  _st=$(adb get-state 2>/dev/null || true)
  case "$_st:${1:-}" in
  device:*) ;;
  recovery:recovery-ok) HELPER=/tmp/ldbhelper ;;
  recovery:*) die "the phone is in recovery: this step runs only in Android. In recovery: gpt-restore, gpt-repair, rehearsal recovery" ;;
  *) die "no phone on adb" ;;
  esac
  _d=$(ash getprop ro.product.device) || die "cannot read ro.product.device"
  [ "$_d" = laurel_sprout ] || die "this is not the Mi A3 (ro.product.device '$_d')"
}
need_root() {
  need_android "${1:-}"
  _u=$(ash id -u) || die "id -u on the phone failed"
  [ "$_st" != recovery ] || [ "$_u" = 0 ] || die "adb in recovery is not root (uid $_u): gpt-restore cannot run here. docs/laurel_sprout/dual-boot.md, the rehearsal"
  [ "$_u" = 0 ] || die "adb is not root: Settings -> System -> Developer options -> Rooted debugging (owner), then: adb root"
}
helper_hash() { mkdir -p "$D"; cat "$REPO/tools/laurel-dualboot/ldbhelper.c" > "$D/helper.src"; sha "$D/helper.src" | cut -c1-32; }
build_helper() {
  clang --target=aarch64-linux-gnu -std=gnu11 -O2 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld \
    -DLDB_HELPER_VERSION="\"$1\"" -o "$D/ldbhelper-arm64" "$REPO/tools/laurel-dualboot/ldbhelper.c"
}
# The helper on the phone is built from this source: rebuilt when the source changed, and asked for its version after the push.
need_helper() {
  need_root "${1:-}"
  mkdir -p "$D"
  _v=$(helper_hash)
  if [ ! -x "$D/ldbhelper-arm64" ] || ! LC_ALL=C grep -aqF "ldbhelper-version $_v" "$D/ldbhelper-arm64"; then build_helper "$_v"; fi
  adb push "$D/ldbhelper-arm64" "$HELPER" >/dev/null || die "adb push of the helper failed"
  ash chmod 700 "$HELPER" || die "chmod of the helper failed"
  _g=$(ash "$HELPER" version) || die "the helper does not run on the phone"
  [ "$_g" = "ldbhelper-version $_v" ] || die "the helper on the phone is '$_g', this source is $_v: push failed or a stale binary"
}
# bootctl is-slot-*, by source [V AOSP and LineageOS lineage-23.0 system/extras bootctl.cpp, handle_return of optional<bool>]: true: stdout 1, exit 0. false: stdout 0, exit 70 (EX_SOFTWARE).
# HAL error: no stdout, text on stderr, exit 70. So the exit code cannot tell "no" from an error: the output does. Prints yes, no, or unknown.
slot_answer() {
  _r=0; _a=$(ash "bootctl $1 $2 2>&1") || _r=$?
  case "$_r:$_a" in
  0:1|0:yes|0:) echo yes ;;
  70:0|1:0|1:no|70:no|1:) echo no ;;
  *) echo "unknown (exit $_r: $_a)" ;;
  esac
}
slot_yes() {
  _s=$(slot_answer "$1" "$2")
  case "$_s" in yes) return 0 ;; no) return 1 ;; *) die "bootctl $1 $2: $_s: not a yes and not a no" ;; esac
}
slot_value() {
  _s=$(ash bootctl "$1") || die "bootctl $1 failed"
  printf '%s\n' "$_s"
}
# The phone on fastboot is one phone, and it says it is the Mi A3. One getvar can answer wrongly on this ABL (docs/notes.md): three tries; only the positive answer counts.
need_fastboot_mi_a3() {
  _f=$(fastboot devices) || die "fastboot devices failed"
  [ -n "$_f" ] || die "no phone in fastboot (adb reboot bootloader, or out/bin/op10tool ctl bootloader, or Power+VolDown)"
  [ "$(printf '%s\n' "$_f" | grep -c .)" = 1 ] || die "more than one phone in fastboot: $_f"
  FB_S=$(printf '%s\n' "$_f" | awk '{print $1}')
  for _i in 1 2 3; do
    _p=$(fastboot -s "$FB_S" getvar product 2>&1 | sed -n 's/^product: *//p' | tr -d '\r')
    if [ "$_p" = laurel_sprout ]; then return 0; fi
    sleep 1
  done
  die "the phone in fastboot does not say it is the Mi A3 (product '${_p:-no answer}'): nothing was written"
}
fb_var() { fastboot -s "$FB_S" getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'; }
need_fastboot_layout() {
  _u=$(fb_var partition-size:userdata); _i=$(fb_var partition-size:iosroot)
  [ -n "$_i" ] || die "ABL sees no partition iosroot (userdata: '$_u'): the new table is not there"
  [ "$((_i))" = "$IOSROOT_BYTES" ] && [ "$((_u))" = "$USERDATA_BYTES" ] || die "ABL sees iosroot $_i and userdata $_u, the plan has $IOSROOT_BYTES and $USERDATA_BYTES"
  say "ABL sees the new table: iosroot $_i, userdata $_u"
}
# Back to Android after a failed switch. set-active writes 0x3F to slot a too, which clears its successful bit: mark it again, or slot a is no fallback target.
flip_back() {
  if ash bootctl set-active-boot-slot 0 && ash bootctl mark-boot-successful && [ "$(slot_value get-active-boot-slot)" = 0 ] && slot_yes is-slot-marked-successful 0; then
    say "slot a is active and marked successful again"
  else
    echo "dual-boot: slot b may stay active. The next boot tries iOS; ABL returns to Android when the retries end. Or: Power + Vol Down, dual-boot.sh to-android" >&2
  fi
}
# What is on a partition: read from the phone against a host file.
part_holds() {
  _n=$(wc -c < "$2" | tr -d ' ')
  _h=$(ash "head -c $_n /dev/block/by-name/$1 | sha256sum") || die "cannot read $1 on the phone"
  [ "${_h%% *}" = "$(sha "$2")" ] || die "$1 on the phone is not $2. A manual update (sideload) writes slot b: get Android on slot a again, then: dual-boot.sh image, flash-slot-b (docs/laurel_sprout/dual-boot.md, manual update)"
}
newest_backup() {
  for _b in $(ls -d "$LAUREL_BACKUP"/android-* 2>/dev/null | sort -r); do [ -f "$_b/gpt-sda-head.bin" ] && [ -f "$_b/gpt-sda-tail.bin" ] && { echo "$_b"; return 0; }; done
  return 1
}
# The pre-write backup: step 1 records it, with the hashes of its table. A backup made after the write holds the new table: the newest folder is the wrong one from then on.
record_backup() {
  mkdir -p "$D"
  { echo "$1"; sha "$1/gpt-sda-head.bin"; sha "$1/gpt-sda-tail.bin"; } > "$PREWRITE.tmp"
  mv "$PREWRITE.tmp" "$PREWRITE"
}
backup_with_gpt() {
  [ -f "$PREWRITE" ] || die "no record of the pre-write backup ($PREWRITE). Before the write, step 1 makes it: dual-boot.sh gpt-write --dry-run. After the write: dual-boot.sh record-backup DIR, with DIR the backup that holds the old table"
  _b=$(sed -n 1p "$PREWRITE")
  [ -f "$_b/gpt-sda-head.bin" ] && [ -f "$_b/gpt-sda-tail.bin" ] || die "the pre-write backup $_b ($PREWRITE) has no gpt-sda-head.bin, gpt-sda-tail.bin"
  [ "$(sha "$_b/gpt-sda-head.bin")" = "$(sed -n 2p "$PREWRITE")" ] && [ "$(sha "$_b/gpt-sda-tail.bin")" = "$(sed -n 3p "$PREWRITE")" ] || die "the table files of the pre-write backup $_b changed after step 1"
  echo "$_b"
}
# S3: `set-active-boot-slot 1` moves the UFS boot LUN to xbl_b [V bootctrl source]: the next boot runs slot b's boot chain. Each partition against the backup's hash (SHA256SUMS: raw partition dumps).
check_fw_b() {
  _b=$(backup_with_gpt); _sums=$_b/SHA256SUMS
  [ -f "$_sums" ] || die "no $_sums"
  _p=; for _n in $FW_B; do _p="$_p /dev/block/by-name/${_n}_b"; done
  # shellcheck disable=SC2086
  _o=$(ash sha256sum $_p) || die "cannot read the slot b firmware on the phone"
  for _n in $FW_B; do
    _w=$(sed -n "s/^\([0-9a-f]*\)  ${_n}_b\.img\$/\1/p" "$_sums")
    [ -n "$_w" ] || die "$_sums has no ${_n}_b.img"
    _g=$(printf '%s\n' "$_o" | awk -v n="/${_n}_b" 'index($2, n) && substr($2, length($2) - length(n) + 1) == n {print $1; exit}')
    [ "$_g" = "$_w" ] || die "${_n}_b on the phone (${_g:-no hash}) is not the backup's ($_w): set-active would run another boot chain. Stop, read docs/laurel_sprout/dual-boot.md"
  done
  say "slot b firmware: $(echo "$FW_B" | wc -w | tr -d ' ') partitions equal the backup $(basename "$_b")"
}
# The kernel's view: userdata and iosroot as the plan says, /data sits on the shrunk userdata. Format of dmctl, read on the phone 2026-11-02 [V]: 0-226307992: default-key, aes-xts-plain64 - 0 8:15 0 3 allow_discards sector_size:4096 iv_large_sectors
check_layout() {
  _ud=$(ash readlink -f /dev/block/by-name/userdata) || die "no by-name/userdata"
  _ir=$(ash readlink -f /dev/block/by-name/iosroot) || die "no by-name/iosroot: the kernel does not see the new table"
  [ "${_ud##*/}" = sda15 ] && [ "${_ir##*/}" = sda16 ] || die "userdata is $_ud, iosroot is $_ir: expected sda15, sda16"
  for _x in "sda15 $USERDATA_FIRST $((USERDATA_BYTES / 4096))" "sda16 $IOSROOT_FIRST $IOSROOT_BLOCKS"; do
    # shellcheck disable=SC2086
    set -- $_x
    _st=$(ash cat "/sys/class/block/$1/start") || die "no start of $1"
    _sz=$(ash cat "/sys/class/block/$1/size") || die "no size of $1"
    [ "$_st" = $(($2 * 8)) ] && [ "$_sz" = $(($3 * 8)) ] || die "$1: start $_st, size $_sz sectors; the plan has $(($2 * 8)), $(($3 * 8))"
  done
  _t=$(ash dmctl table userdata) || die "dmctl table userdata failed"
  _l=$(printf '%s\n' "$_t" | grep -E '^[0-9]+-[0-9]+: ' || true)
  [ "$(printf '%s\n' "$_l" | grep -c .)" = 1 ] || die "userdata has not exactly one device-mapper target: $_t"
  # shellcheck disable=SC2086
  set -- $_l
  [ "$#" -ge 7 ] || die "unknown dmctl format: $_t"
  [ "$2" = default-key, ] || die "userdata is not a default-key device: $_t"
  [ "$1" = "0-$((USERDATA_BYTES / 512)):" ] || die "the target is '$1', the new userdata has $((USERDATA_BYTES / 512)) sectors: $_t"
  [ "$5" = 0 ] && [ "$7" = 0 ] || die "default-key offset is not 0: $_t"
  [ "$6" = "$(ash cat /sys/class/block/sda15/dev)" ] || die "the target sits on device '$6', not sda15: $_t"
  _m=$(ash mount) || die "mount on the phone failed"
  FSDEV=$(printf '%s\n' "$_m" | awk '$3 == "/data" && $5 == "f2fs" {print $1; exit}')
  [ -n "$FSDEV" ] || die "/data is not f2fs"
  _s=$(ash ls "/sys/block/${FSDEV##*/}/slaves") || die "$FSDEV has no slaves in sysfs: /data is not on device-mapper"
  [ "$_s" = sda15 ] || die "/data ($FSDEV) sits on '$_s', not on sda15"
}
need_slots_a() {
  [ "$(ash getprop ro.boot.slot_suffix)" = _a ] || die "Android is not on slot a (a manual update moves it): docs/laurel_sprout/dual-boot.md, manual update"
  [ "$(slot_value get-current-slot)" = 0 ] || die "bootctl: the current slot is not 0: docs/laurel_sprout/dual-boot.md, manual update"
  [ "$(slot_value get-active-boot-slot)" = 0 ] || die "bootctl: slot a is not active (an update finished and waits for a reboot?): docs/laurel_sprout/dual-boot.md, manual update"
}
# On-disk table of LUN 0, past the page cache, into $G/$1.head, $1.tail on the host
pull_table() {
  mkdir -p "$G"
  ash "$HELPER" gpt-dump "$SDA" "$HELPER.head" "$HELPER.tail" > /dev/null || die "the helper could not read $SDA"
  adb pull "$HELPER.head" "$G/$1.head" >/dev/null || die "adb pull of the table failed"
  adb pull "$HELPER.tail" "$G/$1.tail" >/dev/null || die "adb pull of the table failed"
}
need_sda_size() {
  _s=$(ash cat /sys/block/sda/size) || die "no size of sda"
  [ "$_s" = $((30119936 * 8)) ] || die "sda has $_s sectors, the plan is for $((30119936 * 8))"
  _l=$(ash cat /sys/block/sda/queue/logical_block_size) || die "no block size of sda"
  [ "$_l" = 4096 ] || die "sda has logical block size $_l"
}
make_plan() {  # FILE BACKUP
  mkdir -p "$G"
  "$TOOL" gpt plan --head "$2/gpt-sda-head.bin" --tail "$2/gpt-sda-tail.bin" -o "$G/$1" || die "the table of backup $2 does not give a plan"
}
# One word for the table on the phone: op10tool gpt state. Into $G/$1.head, .tail.
table_state() {
  pull_table "$1"
  "$TOOL" gpt state --head "$G/$1.head" --tail "$G/$1.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin"
}
run_plan() {  # FILE WHAT-ON-FAILURE
  adb push "$1" "$HELPER.plan" >/dev/null || die "adb push of the plan failed"
  _h=$(ash sha256sum "$HELPER.plan") || die "cannot hash the plan on the phone"
  [ "${_h%% *}" = "$(sha "$1")" ] || die "the plan on the phone is not the plan here"
  ash "$HELPER" gpt-write "$HELPER.plan" "$SDA" || die "$2"
}
no_root_text() {
  cat <<NOROOT
dual-boot: RECOVERY GIVES NO ROOT ADB ON THIS PHONE: $(sed -n 's/^recovery no-root[: ]*//p' "$REHEARSAL" 2>/dev/null | tail -1)
  What this means: while Android starts with root adb, gpt-restore runs from Android. If Android does not start (a half-written primary, a table it refuses), no helper can run on this phone.
  The way back is then only dual-boot.sh gpt-restore-print: fastboot flash partition:0, which ERASES ALL OF LUN 0, needs the unlock_critical state [U], and then every partition from the backup, persist included: persist is unique to this phone.
  Step 2 goes on only with the owner's word for that: NO_RECOVERY_ROOT=lun-erase-accepted
NOROOT
}
rehearsal_line() {
  if grep -q '^recovery root ' "$REHEARSAL" 2>/dev/null; then say "rehearsal on record: recovery gives root adb, a read-only gpt-dump ran there: gpt-restore and gpt-repair can run in recovery"
  elif grep -q '^recovery no-root' "$REHEARSAL" 2>/dev/null; then no_root_text
  else say "no rehearsal on record: step 2 refuses. dual-boot.sh rehearsal"; fi
}
# Step 2 needs a result of the rehearsal: the owner knows the way back before the first write.
need_rehearsal() {
  grep -q '^recovery root ' "$REHEARSAL" 2>/dev/null && return 0
  if grep -q '^recovery no-root' "$REHEARSAL" 2>/dev/null; then
    no_root_text >&2
    [ "${NO_RECOVERY_ROOT:-}" = lun-erase-accepted ] || die "refused: recovery gives no root adb, and the owner's word for the LUN erase is not given. Nothing was asked of the phone"
    return 0
  fi
  die "no rehearsal on record ($REHEARSAL): nothing was asked of the phone. Before step 2: dual-boot.sh rehearsal"
}
rehearsal_note() { mkdir -p "$D"; echo "$1 $(date +%Y-%m-%dT%H:%M:%S)" >> "$REHEARSAL"; }
RECOVERY_NEXT="Next, owner: hold Power + Vol Up until recovery shows [I: not tried on this phone; the rehearsal records what works]. If that does not work: fastboot reboot, and Android's init formats userdata by itself (docs/laurel_sprout/dual-boot.md section 8)."

cmd=${1:-}
[ $# = 0 ] || shift
case "$cmd" in
status)
  need_android
  say "Android $(ash getprop ro.build.version.release), slot $(ash getprop ro.boot.slot_suffix), $(ash getprop ro.lineage.version)"
  ash df -h /data | tail -1 || true
  if [ "$(ash id -u)" = 0 ]; then
    for c in get-current-slot get-active-boot-slot get-number-slots; do printf '%s: ' "$c"; ash bootctl "$c" || echo "failed"; done
    for s in 0 1; do
      say "slot $s: bootable $(slot_answer is-slot-bootable "$s"), successful $(slot_answer is-slot-marked-successful "$s")"
    done
    ash "ls -l /dev/block/by-name/iosroot /dev/block/by-name/userdata" || true
    ash getprop | grep -E 'update_engine|ota' || true
  else
    say "adb is not root: slot attributes and the partitions need Rooted debugging (owner)"
  fi
  [ ! -f "$RESULT" ] || { say "record on this host ($RESULT):"; cat "$RESULT"; }
  ;;
check-slot-b)
  need_root
  check_fw_b
  ;;
gpt-plan)
  need_tool
  # a preview: the record of step 1, or the newest backup before that
  if [ -f "$PREWRITE" ]; then _b=$(backup_with_gpt); else _b=$(newest_backup) || die "no backup with gpt-sda-head.bin and gpt-sda-tail.bin under $LAUREL_BACKUP"; fi
  make_plan plan.bin "$_b"
  ;;
record-backup)
  _b=${1:?record-backup needs DIR: a backup folder that holds the old table}
  need_tool
  [ -f "$_b/gpt-sda-head.bin" ] && [ -f "$_b/gpt-sda-tail.bin" ] || die "$_b has no gpt-sda-head.bin, gpt-sda-tail.bin"
  make_plan record-check.bin "$_b" >/dev/null
  record_backup "$_b"
  say "the pre-write backup is now $_b ($PREWRITE)"
  ;;
rehearsal)
  case "${1:-}" in
  "")
    cat <<GUIDE
Rehearsal, before step 2 (docs/laurel_sprout/dual-boot.md section 1). It settles two things: how this phone reaches recovery, and whether recovery gives root adb. No table block, no partition of ours is written.
  1. Step 1 first: dual-boot.sh gpt-write --dry-run (it records the pre-write backup).
  2. adb reboot bootloader; then CONFIRM=rehearsal-reach dual-boot.sh rehearsal reach. It tries fastboot reboot recovery. [V ABL source] that command is under DYNAMIC_PARTITION_SUPPORT (FastbootCmds.c:2596): this ABL can refuse it, and a refusal changes nothing. If ABL accepts it, ABL itself writes its boot message to misc (WriteRecoveryMessage), and recovery clears it. Owner: say yes to that first.
  3. Refused: Power + Vol Up by hand [I], or Android: adb reboot recovery. Write down what worked.
  4. In Lineage recovery: Advanced -> Enable ADB [I from the menu of Lineage recovery; not seen on this phone]. Then: dual-boot.sh rehearsal recovery. It runs the helper from /tmp, a read-only gpt-dump of sda, compares it with the backup, and records root or no-root.
  5. No adb shows at all: dual-boot.sh rehearsal no-adb. It records no-root.
  6. Recovery: Reboot system now. Then step 2.
GUIDE
    [ ! -f "$REHEARSAL" ] || { say "on record ($REHEARSAL):"; cat "$REHEARSAL"; }
    rehearsal_line
    ;;
  reach)
    need_confirm rehearsal-reach
    need_fastboot_mi_a3
    if fastboot -s "$FB_S" reboot recovery; then
      rehearsal_note "reach fastboot-reboot-recovery accepted"
      say "ABL accepted fastboot reboot recovery. Next, in Lineage recovery: Advanced -> Enable ADB, then: dual-boot.sh rehearsal recovery"
    else
      rehearsal_note "reach fastboot-reboot-recovery refused"
      say "ABL refused fastboot reboot recovery: a result, nothing changed. after-gpt prints the other way. $RECOVERY_NEXT Then, in recovery: Advanced -> Enable ADB, then: dual-boot.sh rehearsal recovery"
    fi
    ;;
  recovery)
    need_tool
    _b=$(backup_with_gpt)
    _st=$(adb get-state 2>/dev/null || true)
    [ "$_st" = recovery ] || die "adb says '${_st:-no phone}', not recovery. In Lineage recovery: Advanced -> Enable ADB. If adb never shows there: dual-boot.sh rehearsal no-adb"
    HELPER=/tmp/ldbhelper
    _d=$(ash getprop ro.product.device) || die "adb in recovery does not answer: try again, or dual-boot.sh rehearsal no-adb"
    [ "$_d" = laurel_sprout ] || die "this is not the Mi A3 (ro.product.device '$_d')"
    _u=$(ash id -u) || die "id -u in recovery failed"
    if [ "$_u" != 0 ]; then
      rehearsal_note "recovery no-root: adb in recovery runs as uid $_u"
      no_root_text
      exit 0
    fi
    if ! (need_helper recovery-ok); then
      [ "$(adb get-state 2>/dev/null || true)" = recovery ] || die "adb was lost: no result on record: try again"
      rehearsal_note "recovery no-root: the helper does not run in /tmp"
      no_root_text
      exit 0
    fi
    need_sda_size
    pull_table rehearsal
    if "$TOOL" gpt same --head "$G/rehearsal.head" --tail "$G/rehearsal.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin"; then _same="= the pre-write backup"; else _same="differs from the pre-write backup: step 1 will stop"; fi
    rehearsal_note "recovery root helper $(helper_hash)"
    say "recovery gives root adb; the helper read the table of sda there, $_same. Nothing was written. Recorded: $REHEARSAL. Next: Reboot system now, then step 2"
    ;;
  no-adb)
    rehearsal_note "recovery no-root: the owner reports no adb in recovery"
    no_root_text
    ;;
  *) die "rehearsal: no word, reach, recovery or no-adb" ;;
  esac
  ;;
gpt-write)
  [ "${1:-}" = --dry-run ] && DRY=1 || DRY=0
  # --resume: a run stopped in the middle (adb lost, power). The helper compares each block with the plan: only "first steps new, the rest old" goes on.
  [ "${1:-}" = --resume ] && RESUME=1 || RESUME=0
  [ "$DRY" = 1 ] || need_confirm gpt-write
  need_tool
  [ "$DRY" = 1 ] || need_rehearsal
  need_helper
  need_slots_a
  need_sda_size
  # Step 1 records the backup it has compared with the phone. Every later step uses that one.
  if [ "$DRY" = 1 ] && [ ! -f "$PREWRITE" ]; then _b=$(newest_backup) || die "no backup with gpt-sda-head.bin and gpt-sda-tail.bin under $LAUREL_BACKUP"; else _b=$(backup_with_gpt); fi
  make_plan plan.bin "$_b"
  pull_table now
  # F6: the new table is there: this run has nothing to do, and the record of later steps stays.
  if [ "$RESUME" = 1 ] && "$TOOL" gpt verify-new --head "$G/now.head" --tail "$G/now.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin" >/dev/null 2>&1; then
    grep -q '^gpt-written ' "$RESULT" 2>/dev/null || { mkdir -p "$D"; echo "gpt-written $(date +%Y-%m-%dT%H:%M:%S)" >> "$RESULT"; }
    say "--resume: the new table is already on the flash: nothing written, the record stays. If the phone has not rebooted since the write: adb reboot bootloader, then CONFIRM=after-gpt dual-boot.sh after-gpt"
    exit 0
  fi
  if ! "$TOOL" gpt same --head "$G/now.head" --tail "$G/now.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin"; then
    [ "$RESUME" = 1 ] || die "the table on the phone is not the backup's: nothing written. After a stopped run only: CONFIRM=gpt-write dual-boot.sh gpt-write --resume"
    say "--resume: the table differs from the backup: the helper now decides by the plan's bytes"
  fi
  if [ "$DRY" = 1 ]; then
    [ -f "$PREWRITE" ] || record_backup "$_b"
    say "pre-write backup on record: $_b ($PREWRITE). All later steps use this one"
    rehearsal_line
    say "dry run: nothing was written. The write runs exactly:"
    echo "  adb push $G/plan.bin $HELPER.plan"
    echo "  adb shell $HELPER gpt-write $HELPER.plan $SDA"
    echo "    steps: backup entries LBA 30119931; backup header LBA 30119935; zero userdata superblocks LBA $USERDATA_FIRST + 2; primary header + entries LBA 1 + 2, one command"
    echo "  adb shell $HELPER gpt-dump $SDA $HELPER.head $HELPER.tail ; adb pull both ; op10tool gpt verify-new"
    echo "  then, by hand: adb reboot bootloader ; CONFIRM=after-gpt dual-boot.sh after-gpt"
    exit 0
  fi
  run_plan "$G/plan.bin" "gpt-write failed or adb was lost. Do not reboot. See what is there: CONFIRM=gpt-write dual-boot.sh gpt-write --resume goes on only from a state of this plan: docs/laurel_sprout/dual-boot.md"
  pull_table after
  "$TOOL" gpt verify-new --head "$G/after.head" --tail "$G/after.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin" || die "the table read back is not the planned one. Do not reboot: docs/laurel_sprout/dual-boot.md"
  mkdir -p "$D"; echo "gpt-written $(date +%Y-%m-%dT%H:%M:%S)" > "$RESULT"
  say "new table on the flash and read back. The running kernel keeps the old table until its reboot. Next, now: adb reboot bootloader, then CONFIRM=after-gpt dual-boot.sh after-gpt"
  ;;
after-gpt)
  need_confirm after-gpt
  need_fastboot_mi_a3
  need_fastboot_layout
  # ABL can have no such command: FastbootCmds.c:2596, under DYNAMIC_PARTITION_SUPPORT. A refusal is no failure of this step: the table is good, and the next step is the owner's.
  if ! fastboot -s "$FB_S" reboot recovery; then
    say "ABL refused fastboot reboot recovery. Nothing changed, and the new table is good. $RECOVERY_NEXT"
    [ ! -f "$REHEARSAL" ] || { say "the rehearsal has this on record:"; grep '^reach ' "$REHEARSAL" || true; }
  fi
  say "In Lineage recovery (owner): Factory reset -> Format data / factory reset -> yes; then Reboot system now. Android sets itself up. Then: Rooted debugging on, adb root, dual-boot.sh android-check"
  ;;
android-check)
  need_root
  check_layout
  [ "$(ash getprop sys.boot_completed)" = 1 ] || die "Android has not finished booting"
  [ "$(ash getprop sys.user.0.ce_available)" = true ] || die "user 0's data is not open: unlock the phone once, then run this again"
  [ "$(ash getprop ro.crypto.state)" = encrypted ] || die "ro.crypto.state is not encrypted"
  # the superblock through the decrypting device: block count (byte 1024 + 36) in the new size. No f2fs of the old size can be here.
  _sb=$(ash "dd if=$FSDEV bs=4096 count=1 2>/dev/null | od -An -tu4 -j1024 -N4; dd if=$FSDEV bs=4096 count=1 2>/dev/null | od -An -tu4 -j1060 -N8") || die "cannot read the superblock"
  # shellcheck disable=SC2086
  set -- $_sb
  [ "$#" = 3 ] && [ "$1" = $((0xF2F52010)) ] || die "no f2fs superblock on $FSDEV: $_sb"
  _bc=$(($2 + ($3 << 32)))
  [ "$((_bc * 4096))" -le "$USERDATA_BYTES" ] || die "the f2fs on /data claims $((_bc * 4096)) bytes, userdata has $USERDATA_BYTES: a stale superblock. Stop: Format data in recovery"
  mkdir -p "$D"
  echo "android-opened $(date +%Y-%m-%dT%H:%M:%S) f2fs-bytes $((_bc * 4096))" >> "$RESULT"
  grep -q '^ro-on ' "$RESULT" && echo "android-opened-after-ro $(date +%Y-%m-%dT%H:%M:%S)" >> "$RESULT"
  say "Android opened its data on the new layout: userdata $USERDATA_BYTES bytes, f2fs $((_bc * 4096)) bytes, iosroot $IOSROOT_BYTES bytes. Recorded: $RESULT"
  ;;
install)
  need_confirm install
  grep -q '^android-opened ' "$RESULT" 2>/dev/null || die "no record that Android opened its data on the new layout: dual-boot.sh android-check first"
  img=${1:-$(default_root)}
  [ -f "$img" ] || die "missing $img"
  _sz=$(wc -c < "$img" | tr -d ' ')
  [ "$_sz" -le "$IOSROOT_VOLUME_MAX" ] || die "$img has $_sz bytes: iosroot takes at most $IOSROOT_VOLUME_MAX with the console log"
  _vb=$("$TOOL" hfs-size "$img" | sed -n 's/.* = \([0-9]*\) bytes .*/\1/p') || die "$img has no HFS+ volume"
  [ -n "$_vb" ] || die "$img has no HFS+ volume"
  [ "$_vb" -le "$IOSROOT_VOLUME_MAX" ] || die "the volume in $img has $_vb bytes: too big"
  simg=${img%.img}.simg
  if [ ! -f "$simg" ] || [ "$img" -nt "$simg" ]; then
    say "making $simg (a long step: run this with scripts/bg.sh)"
    "$TOOL" img2simg "$img" "$simg.partial"
    mv "$simg.partial" "$simg"
  fi
  head -c 1048576 "$img" > "$D/root.first1m"
  need_fastboot_mi_a3
  need_fastboot_layout
  "$REPO/scripts/laurel/flash-root.sh" "$simg"
  echo "installed $(date +%Y-%m-%dT%H:%M:%S) $img $(sha "$D/root.first1m")" >> "$RESULT"
  say "iosroot holds $img ($_sz bytes; margin to the log $((IOSROOT_VOLUME_MAX - _sz)) bytes). Android stays active. Next: dual-boot.sh image"
  ;;
image)
  m=$(mode_arg "${1:-}")
  bi=$(image_path "$m")
  if [ "$m" = rw ]; then
    grep -q "^ro-on $(marker) " "$RESULT" 2>/dev/null || die "no recorded result of a read-only boot of this kernel fence: dual-boot.sh ro-result LOG"
    grep -q '^android-opened-after-ro ' "$RESULT" 2>/dev/null || die "Android has not opened its data after the read-only iOS boot: dual-boot.sh android-check"
  fi
  case "$TARGET" in ios26) s=$REPO/scripts/laurel/ios26-image.sh ;; ios16) s=$REPO/scripts/laurel/uefi-image.sh ;; *) die "TARGET=$TARGET: ios26 or ios16" ;; esac
  ro=1; [ "$m" = ro ] || ro=0
  # the app on the phone compares iosroot with this mark (docs/laurel_sprout/boot-menu.md). No record: no mark, the app refuses the image
  _inst=$(sed -n 's/^installed .* \([0-9a-f]\{64\}\)$/\1/p' "$RESULT" 2>/dev/null | tail -1)
  env UEFI_W="${bi%/*}" LAUREL_READONLY=$ro IOSROOT_HEAD_SHA="$_inst" "$s"
  [ -f "$bi.dualboot" ] || die "no $bi.dualboot: config/laurel-android-data must exist for this build"
  grep -q "^mode $m\$" "$bi.dualboot" || die "the image was built as $(sed -n 's/^mode //p' "$bi.dualboot"), not $m"
  say "$bi: mode $m, $(sed -n 's/^os //p' "$bi.dualboot")"
  ;;
flash-slot-b)
  need_confirm flash-slot-b
  m=$(mode_arg "${1:-}")
  bi=$(image_path "$m")
  [ -f "$bi" ] || die "missing $bi: dual-boot.sh image${1:+ $1}"
  [ -f "$STOCK_DTBO" ] || die "missing $STOCK_DTBO"
  need_fastboot_mi_a3
  need_fastboot_layout
  "$REPO/scripts/laurel/android-guard.sh" boot-image "$bi"
  _cs=$(fb_var current-slot)
  [ "$_cs" = a ] || die "current slot is '$_cs', not a: Android must be on slot a (after a manual update: docs/laurel_sprout/dual-boot.md)"
  # Why stock dtbo: iOS has only booted with the stock DTB + stock dtbo (dtbo_b holds Lineage's now; ABL stops on an overlay failure). Slot a has its own dtbo_a.
  fastboot -s "$FB_S" reboot bootloader; sleep 6
  need_fastboot_mi_a3
  fastboot -s "$FB_S" flash boot_b "$bi"
  fastboot -s "$FB_S" reboot bootloader; sleep 6
  need_fastboot_mi_a3
  fastboot -s "$FB_S" flash dtbo_b "$STOCK_DTBO"
  say "boot_b ($m) and dtbo_b written. Slot a stays active. fastboot reboot starts Android; a switch comes from Android."
  ;;
switch)
  need_confirm switch
  m=$(mode_arg "${1:-}")
  bi=$(image_path "$m")
  need_root
  check_layout
  need_slots_a
  slot_yes is-slot-bootable 0 || die "slot a is not bootable: no way back"
  slot_yes is-slot-marked-successful 0 || die "slot a is not marked successful: ABL has nothing to fall back to. Boot Android to the end first"
  grep -q '^android-opened ' "$RESULT" 2>/dev/null || die "no record that Android opened its data on the new layout: dual-boot.sh android-check"
  _inst=$(sed -n 's/^installed .* \([0-9a-f]\{64\}\)$/\1/p' "$RESULT" 2>/dev/null | tail -1)
  [ -n "$_inst" ] || die "no record of an installed root: dual-boot.sh install"
  _h=$(ash "head -c 1048576 /dev/block/by-name/iosroot | sha256sum") || die "cannot read iosroot on the phone"
  [ "${_h%% *}" = "$_inst" ] || die "iosroot does not start with the installed root: dual-boot.sh install"
  [ -f "$bi" ] || die "missing $bi: dual-boot.sh image${1:+ $1}"
  "$REPO/scripts/laurel/android-guard.sh" boot-image "$bi"
  grep -q "^mode $m\$" "$bi.dualboot" || die "$bi is not a $m image"
  # S1: the header of the iOS image against what Android runs now, not only the backup. After a sideload the two differ.
  _r=$(ash "head -c 48 /dev/block/by-name/boot_a | od -An -tu4 -j44 -N4") || die "cannot read the boot_a header"
  [ "$(echo "$_r" | tr -d ' ')" = "$(boot_os_raw "$bi")" ] || die "the header of $bi says OS field $(boot_os_raw "$bi"), boot_a on the phone says $_r: build the image again from a backup of this Lineage"
  [ -f "$STOCK_DTBO" ] || die "missing $STOCK_DTBO"
  part_holds boot_b "$bi"
  part_holds dtbo_b "$STOCK_DTBO"
  check_fw_b
  ash bootctl set-active-boot-slot 1 || { _e=$?; flip_back; die "bootctl set-active-boot-slot 1 failed (status $_e)"; }
  [ "$(slot_value get-active-boot-slot)" = 1 ] || { flip_back; die "slot b is not active after set-active"; }
  # 0x3F (priority 3, active, 7 retries, successful clear). A slot b still marked successful: ABL does not count down, so there is no way back without a computer.
  if slot_yes is-slot-marked-successful 1; then flip_back; die "slot b stays marked successful after set-active: ABL would not count down"; fi
  adb reboot || { flip_back; die "adb reboot failed"; }
  say "Slot b active, a normal reboot started. Watch the line LAUREL DUALBOOT: on / off on the screen or with scripts/debug/usblog.sh. Back to Android: Power + Vol Down, then CONFIRM=to-android dual-boot.sh to-android"
  ;;
ro-result)
  log=${1:?ro-result needs a log file: a USB log, or the line typed from the screen}
  [ -f "$log" ] || die "missing $log"
  grep -q '^android-opened ' "$RESULT" 2>/dev/null || die "no record that Android opened its data on the new layout"
  m=$(marker)
  _l=$(grep -a 'LAUREL DUALBOOT: \(on\|off\|no root\)' "$log" | tail -1 || true)
  case "$_l" in
  *"LAUREL DUALBOOT: on: root = iosroot, LUN 0, first block $IOSROOT_FIRST, $IOSROOT_BLOCKS blocks "*", read-only ($m)"*) ;;
  *"LAUREL DUALBOOT: on:"*) die "the line is not the one of a read-only boot on the plan's partition with this kernel: $_l" ;;
  "") die "$log has no LAUREL DUALBOOT line: no result. The writable image stays refused" ;;
  *) die "the kernel said no: $_l. No result: the writable image stays refused" ;;
  esac
  echo "ro-on $m $(date +%Y-%m-%dT%H:%M:%S)" >> "$RESULT"
  say "recorded: $_l"
  say "Next: back to Android, CONFIRM=to-android dual-boot.sh to-android; then dual-boot.sh android-check. Only then the writable image"
  ;;
to-android)
  need_confirm to-android
  need_fastboot_mi_a3
  fastboot -s "$FB_S" set_active a
  fastboot -s "$FB_S" reboot
  say "Slot a active, Android starts. Android must open its data; then: dual-boot.sh android-check"
  ;;
gpt-restore|gpt-repair)
  [ "${1:-}" = --dry-run ] && DRY=1 || DRY=0
  [ "$DRY" = 1 ] || need_confirm "$cmd"
  need_tool
  need_helper recovery-ok
  need_sda_size
  _b=$(backup_with_gpt)
  _s=$(table_state before) || die "cannot read the state of the table"
  say "the table on the phone: $_s"
  # A half-written primary: first the primary from the valid backup. Only one copy is ever being written, so a valid copy exists at each moment.
  case "$_s" in
  torn-backup-new|torn-backup-old)
    "$TOOL" gpt plan-repair --head "$G/before.head" --tail "$G/before.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin" -o "$G/repair.bin" || die "no repair plan from this table: nothing written"
    if [ "$DRY" = 1 ]; then
      say "dry run: nothing was written. The write runs: adb push $G/repair.bin $HELPER.plan ; adb shell $HELPER gpt-write $HELPER.plan $SDA: the primary from the backup copy, nothing else"
      [ "$cmd" = gpt-repair ] || say "then gpt-restore goes on from the repaired table"
      exit 0
    fi
    run_plan "$G/repair.bin" "the repair failed or adb was lost: run this step again: the helper goes on only from a state of this plan"
    _s=$(table_state before) || die "cannot read the state of the table"
    "$TOOL" gpt verify-plan --head "$G/before.head" --tail "$G/before.tail" --plan "$G/repair.bin" >/dev/null || die "the repaired primary does not read back as planned"
    say "the primary is written from the backup copy and read back: table $_s"
    ;;
  broken) die "neither copy of the table is valid: nothing written. The last resort: dual-boot.sh gpt-restore-print" ;;
  unknown) die "the table is valid, but neither layout of this disk: nothing written. Stop, and report it" ;;
  esac
  if [ "$cmd" = gpt-repair ]; then
    case "$_s" in new) say "next: the new table rules: adb reboot bootloader, then CONFIRM=after-gpt dual-boot.sh after-gpt" ;; old) say "next: the old table rules: Android starts as before the write" ;; *) die "nothing to repair: table $_s" ;; esac
    exit 0
  fi
  case "$_s" in
  new) ;;
  old) say "the old layout is already on the flash: nothing written. If Android does not start: recovery, Format data"; exit 0 ;;
  *) die "table $_s: a stopped gpt-write: the primary is the old layout and the backup differs. Nothing written. In Android: CONFIRM=gpt-write dual-boot.sh gpt-write --resume ends that write, then this step" ;;
  esac
  # F3: from the table on the disk: ABL and the HAL have changed attributes and type GUIDs since the backup. op10tool proves that only the last LBA of userdata and the iosroot slot change.
  "$TOOL" gpt plan-restore --head "$G/before.head" --tail "$G/before.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin" -o "$G/restore.bin" || die "the table on the phone gives no restore plan: nothing written"
  if [ "$DRY" = 1 ]; then
    say "dry run: nothing was written. The write runs: adb push $G/restore.bin $HELPER.plan ; adb shell $HELPER gpt-write $HELPER.plan $SDA. It zeroes the f2fs superblocks of userdata: Format data in recovery after it"
    exit 0
  fi
  run_plan "$G/restore.bin" "gpt-write failed or adb was lost: run this step again: it reads the table again and goes on only from a state of the plan"
  pull_table after
  "$TOOL" gpt verify-plan --head "$G/after.head" --tail "$G/after.tail" --plan "$G/restore.bin" || die "the table read back is not the planned one"
  say "the old layout is back. Reboot to recovery and Format data. iosroot no longer exists; its bytes become userdata"
  ;;
gpt-restore-print)
  need_tool
  _b=$(backup_with_gpt)
  mkdir -p "$G"
  "$TOOL" gpt image --head "$_b/gpt-sda-head.bin" --tail "$_b/gpt-sda-tail.bin" -o "$G/gpt_both0-old.bin"
  cat <<PRINT
LAST RESORT, printed only, nothing was run. Use it only when neither Android nor a root shell in recovery can run: dual-boot.sh gpt-restore. A reboot with a wrong table does not need this.
fastboot flash partition:0 ERASES ALL OF LUN 0 first [V ABL WriteGpt: "Erase the entire card"]: ssd persist misc keystore frp product_a product_b odm_a odm_b oem minidump system_a system_b metadata userdata.
It needs "fastboot flashing unlock_critical" state [V ABL: L"partition" is a critical partition]: check with: fastboot oem device-info. Each line below is a partition write: the owner decides, also for persist.
Each flash has -S 512M: plain fastboot flash fails on this ABL (docs/notes.md, "Requested download size is more than max allowed"). Run them in a clean session: fastboot reboot bootloader first.
  fastboot -S 512M flash partition:0 $G/gpt_both0-old.bin
  for each partition P of the list except userdata, metadata, one by one; a hash that differs stops: that image is damaged, do not flash it:
    gzip -dc $_b/P.img.gz > $G/P.img
    [ "\$(sha256sum $G/P.img | cut -d' ' -f1)" = "\$(sed -n 's/  P\.img\$//p' $_b/SHA256SUMS)" ] || exit 1      (macOS: shasum -a 256)
    fastboot -S 512M flash P $G/P.img ; rm $G/P.img
  then: recovery, Format data.
PRINT
  ;;
*)
  sed -n 2,25p "$0" >&2; exit 2 ;;
esac
