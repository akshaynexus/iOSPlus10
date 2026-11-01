#!/bin/sh
# Mi A3 dual boot: LineageOS on slot a, iOS on boot_b, the iOS root in the GPT partition iosroot on LUN 0. Steps, reasons, recovery: docs/laurel_sprout/dual-boot.md.
# NOTHING HERE HAS RUN ON THE PHONE YET. Every step that writes needs CONFIRM=<its name>, and the owner's yes first. First path: iOS 26. TARGET=ios16 takes the iOS 16 inputs.
#   dual-boot.sh status                            read-only: slots, partitions, /data
#   dual-boot.sh check-slot-b                      read-only: slot b firmware against the backup's hashes (set-active moves the boot LUN to xbl_b)
#   dual-boot.sh gpt-plan                          host only: from the backup dumps: plan file, table before and after
#   dual-boot.sh gpt-write --dry-run               read-only: device check, fresh table = backup, the exact commands, the table before and after
#   CONFIRM=gpt-write dual-boot.sh gpt-write       THE GPT WRITE, LUN 0 only: 4 table blocks, the 2 superblock blocks of userdata. Reads it back before any reboot. Android's data is gone after the next reboot
#   CONFIRM=after-gpt dual-boot.sh after-gpt       phone in fastboot (adb reboot bootloader): ABL must see the new sizes; then reboot to recovery. There the owner does Format data
#   dual-boot.sh android-check                     read-only: Android opened its data on the new layout; a record on the host
#   CONFIRM=install dual-boot.sh install [IMG]     phone in fastboot: the root image to iosroot (tmux). Only iosroot
#   dual-boot.sh image [rw]                        host only: boot image. Default read-only (no ufsrw, no rootrw); rw refuses until the read-only run is on record
#   CONFIRM=flash-slot-b dual-boot.sh flash-slot-b [rw]   phone in fastboot: boot_b = that image, dtbo_b = stock dtbo; Android stays active
#   CONFIRM=switch dual-boot.sh switch [rw]        Android -> iOS: all checks, slot b active, normal reboot
#   dual-boot.sh ro-result LOG                     host only: the line of the read-only boot from a USB log or typed from the screen: a record on the host
#   CONFIRM=to-android dual-boot.sh to-android     BACK TO ANDROID: phone in fastboot (Power + Vol Down, or op10tool ctl bootloader): fastboot set_active a, reboot
#   dual-boot.sh gpt-restore --dry-run; CONFIRM=gpt-restore dual-boot.sh gpt-restore    the old table back, with the same helper, from Android or a root shell in recovery. Then Format data again
#   dual-boot.sh gpt-restore-print                 host only: the last resort over fastboot: prints it, runs nothing: it ERASES ALL OF LUN 0
# All adb steps need root adb: Settings -> System -> Developer options -> Rooted debugging (owner), then `adb root`. A wipe turns that setting off.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/lib/laurel-layout.sh"
D=$OUT/laurel/dualboot
G=$D/gpt
RESULT=$D/first-boot.result
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
need_android() {
  [ "$(adb get-state 2>/dev/null || true)" = device ] || die "no phone on adb"
  _d=$(ash getprop ro.product.device) || die "cannot read ro.product.device"
  [ "$_d" = laurel_sprout ] || die "this is not the Mi A3 (ro.product.device '$_d')"
}
need_root() {
  need_android
  _u=$(ash id -u) || die "id -u on the phone failed"
  [ "$_u" = 0 ] || die "adb is not root: Settings -> System -> Developer options -> Rooted debugging (owner), then: adb root"
}
helper_hash() { mkdir -p "$D"; cat "$REPO/tools/laurel-dualboot/ldbhelper.c" > "$D/helper.src"; sha "$D/helper.src" | cut -c1-32; }
build_helper() {
  clang --target=aarch64-linux-gnu -std=gnu11 -O2 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld \
    -DLDB_HELPER_VERSION="\"$1\"" -o "$D/ldbhelper-arm64" "$REPO/tools/laurel-dualboot/ldbhelper.c"
}
# The helper on the phone is built from this source: rebuilt when the source changed, and asked for its version after the push.
need_helper() {
  need_root
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
backup_with_gpt() {
  for _b in $(ls -d "$LAUREL_BACKUP"/android-* 2>/dev/null | sort -r); do [ -f "$_b/gpt-sda-head.bin" ] && [ -f "$_b/gpt-sda-tail.bin" ] && { echo "$_b"; return 0; }; done
  die "no backup with gpt-sda-head.bin and gpt-sda-tail.bin under $LAUREL_BACKUP"
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
make_plan() {
  mkdir -p "$G"
  _b=$(backup_with_gpt)
  "$TOOL" gpt plan --head "$_b/gpt-sda-head.bin" --tail "$_b/gpt-sda-tail.bin" -o "$G/$1" ${2:+--reverse} || die "the backup's table does not give a plan (or $TOOL has no gpt command: scripts/setup/build-op10tool.sh)"
}

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
  make_plan plan.bin
  ;;
gpt-write)
  [ "${1:-}" = --dry-run ] && DRY=1 || DRY=0
  # --resume: a run stopped in the middle (adb lost, power). The helper compares each block with the plan: only "first steps new, the rest old" goes on.
  [ "${1:-}" = --resume ] && RESUME=1 || RESUME=0
  [ "$DRY" = 1 ] || need_confirm gpt-write
  need_helper
  need_slots_a
  need_sda_size
  _b=$(backup_with_gpt)
  make_plan plan.bin
  pull_table now
  if ! "$TOOL" gpt same --head "$G/now.head" --tail "$G/now.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin"; then
    [ "$RESUME" = 1 ] || die "the table on the phone is not the backup's: nothing written. After a stopped run only: CONFIRM=gpt-write dual-boot.sh gpt-write --resume"
    say "--resume: the table differs from the backup: the helper now decides by the plan's bytes"
  fi
  if [ "$DRY" = 1 ]; then
    say "dry run: nothing was written. The write runs exactly:"
    echo "  adb push $G/plan.bin $HELPER.plan"
    echo "  adb shell $HELPER gpt-write $HELPER.plan $SDA"
    echo "    steps: backup entries LBA 30119931; backup header LBA 30119935; zero userdata superblocks LBA $USERDATA_FIRST + 2; primary header + entries LBA 1 + 2, one command"
    echo "  adb shell $HELPER gpt-dump $SDA $HELPER.head $HELPER.tail ; adb pull both ; op10tool gpt verify-new"
    echo "  then, by hand: adb reboot bootloader ; CONFIRM=after-gpt dual-boot.sh after-gpt"
    exit 0
  fi
  adb push "$G/plan.bin" "$HELPER.plan" >/dev/null || die "adb push of the plan failed"
  _h=$(ash sha256sum "$HELPER.plan") || die "cannot hash the plan on the phone"
  [ "${_h%% *}" = "$(sha "$G/plan.bin")" ] || die "the plan on the phone is not the plan here"
  ash "$HELPER" gpt-write "$HELPER.plan" "$SDA" || die "gpt-write failed or adb was lost. Do not reboot. See what is there: CONFIRM=gpt-write dual-boot.sh gpt-write --resume goes on only from a state of this plan: docs/laurel_sprout/dual-boot.md"
  pull_table after
  "$TOOL" gpt verify-new --head "$G/after.head" --tail "$G/after.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin" || die "the table read back is not the planned one. Do not reboot: docs/laurel_sprout/dual-boot.md"
  mkdir -p "$D"; echo "gpt-written $(date +%Y-%m-%dT%H:%M:%S)" > "$RESULT"
  say "new table on the flash and read back. The running kernel keeps the old table until its reboot. Next, now: adb reboot bootloader, then CONFIRM=after-gpt dual-boot.sh after-gpt"
  ;;
after-gpt)
  need_confirm after-gpt
  need_fastboot_mi_a3
  need_fastboot_layout
  fastboot -s "$FB_S" reboot recovery
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
gpt-restore)
  [ "${1:-}" = --dry-run ] && DRY=1 || DRY=0
  [ "$DRY" = 1 ] || need_confirm gpt-restore
  need_helper
  need_sda_size
  _b=$(backup_with_gpt)
  make_plan restore.bin reverse
  if [ "$DRY" = 1 ]; then
    say "dry run: nothing was written. The write runs: adb push $G/restore.bin $HELPER.plan ; adb shell $HELPER gpt-write $HELPER.plan $SDA. It zeroes the f2fs superblocks of userdata: Format data in recovery after it"
    exit 0
  fi
  adb push "$G/restore.bin" "$HELPER.plan" >/dev/null || die "adb push of the plan failed"
  ash "$HELPER" gpt-write "$HELPER.plan" "$SDA" || die "gpt-write failed or adb was lost: run this step again: the helper goes on only from a state of this plan"
  pull_table after
  "$TOOL" gpt same --head "$G/after.head" --tail "$G/after.tail" --ref-head "$_b/gpt-sda-head.bin" --ref-tail "$_b/gpt-sda-tail.bin" || die "the table read back is not the backup's"
  say "the old table is back. Reboot to recovery and Format data. iosroot no longer exists; its bytes become userdata"
  ;;
gpt-restore-print)
  _b=$(backup_with_gpt)
  mkdir -p "$G"
  "$TOOL" gpt image --head "$_b/gpt-sda-head.bin" --tail "$_b/gpt-sda-tail.bin" -o "$G/gpt_both0-old.bin"
  cat <<PRINT
LAST RESORT, printed only, nothing was run. Use it only when neither Android nor a root shell in recovery can run: dual-boot.sh gpt-restore. A reboot with a wrong table does not need this.
fastboot flash partition:0 ERASES ALL OF LUN 0 first [V ABL WriteGpt: "Erase the entire card"]: ssd persist misc keystore frp product_a product_b odm_a odm_b oem minidump system_a system_b metadata userdata.
It needs "fastboot flashing unlock_critical" state [V ABL: L"partition" is a critical partition]: check with: fastboot oem device-info. Each line below is a partition write: the owner decides, also for persist.
  fastboot flash partition:0 $G/gpt_both0-old.bin
  for each partition P of the list except userdata, metadata: gzip -dc $_b/P.img.gz > /tmp/P.img ; fastboot flash P /tmp/P.img
  then: recovery, Format data.
PRINT
  ;;
*)
  sed -n 2,20p "$0" >&2; exit 2 ;;
esac
