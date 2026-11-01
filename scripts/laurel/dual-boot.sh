#!/bin/sh
# Mi A3 dual boot: LineageOS on slot a, iOS on boot_b, the iOS root in a pinned file of Android's /data. Steps, reasons, recovery: docs/laurel_sprout/dual-boot.md.
# NOTHING HERE HAS RUN ON THE PHONE YET. Every step that writes needs CONFIRM=<its name>, and the owner's yes first.
#   dual-boot.sh status                 read-only: slots, /data, the file, Android side state
#   dual-boot.sh size [ios16|ios26]     read-only: how big the area must be (AREA_MIB overrides at allocate)
#   CONFIRM=allocate  dual-boot.sh allocate GIB      new pinned file on /data (GIB may be a fraction: 16.1)
#   dual-boot.sh map                    read-only: FIEMAP -> out/laurel/dualboot/table.ldbt (validated)
#   CONFIRM=check-map dual-boot.sh check-map         proof of the mapping: writes through the file, compares the raw blocks; then the immutable flag
#   CONFIRM=install   dual-boot.sh install [IMG]     the root image to the raw blocks of the file; reads it back
#   dual-boot.sh image                  host only: the boot image with the table (scripts/laurel/uefi-image.sh)
#   CONFIRM=flash-slot-b dual-boot.sh flash-slot-b   boot_b = that image, dtbo_b = stock dtbo (phone in fastboot); Android stays active
#   CONFIRM=switch    dual-boot.sh switch            Android -> iOS: seal, set slot b active, reboot
#   CONFIRM=to-android dual-boot.sh to-android       iOS -> Android with a computer: fastboot set_active a (phone in fastboot: `op10tool ctl bootloader`)
#   dual-boot.sh logs [OUT]             read-only, on Android: iOS console log from the end of the area
#   CONFIRM=remove    dual-boot.sh remove            delete the file (root gone, space back). Only with iOS not active.
# All adb steps need root adb: Settings -> System -> Developer options -> Rooted debugging (owner), then `adb root`.
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/laurel/dualboot
TABLE=$D/table.ldbt
AREA=/data/laurel-ios/root.area
HELPER=/data/local/tmp/ldbhelper
PART=/dev/block/by-name/userdata
TOOL=${OP10TOOL:-$OUT/bin/op10tool}
APPLE=${APPLE:-$HOME/op10-apple}
STOCK_DTBO=${STOCK_DTBO:-$HOME/laurel-backup/stock/images/dtbo.img}
BOOT_IMG=${BOOT_IMG:-$OUT/laurel/uefi/laurel-uefi-boot.img}

say() { echo "dual-boot: $*"; }
die() { echo "dual-boot: FAILED: $*" >&2; exit 1; }
need_confirm() { [ "${CONFIRM:-}" = "$1" ] || { echo "dual-boot: refused: this step writes to the phone: CONFIRM=$1 (ask the owner first; docs/laurel_sprout/dual-boot.md)" >&2; exit 4; }; }
ash() { adb shell "$@" | tr -d '\r'; }
need_android() {
  [ "$(adb get-state 2>/dev/null || true)" = device ] || die "no phone on adb"
  [ "$(ash getprop ro.product.device)" = laurel_sprout ] || die "this is not the Mi A3"
}
need_root() {
  need_android
  [ "$(ash id -u)" = 0 ] || die "adb is not root: Settings -> System -> Developer options -> Rooted debugging (owner), then: adb root"
}
need_helper() {
  need_root
  [ -x "$D/ldbhelper-arm64" ] || build_helper
  adb push "$D/ldbhelper-arm64" "$HELPER" >/dev/null
  ash chmod 700 "$HELPER"
}
build_helper() {
  mkdir -p "$D"
  clang --target=aarch64-linux-gnu -std=gnu11 -O2 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld \
    -I"$REPO/tools/laurel-dualboot" -o "$D/ldbhelper-arm64" "$REPO/tools/laurel-dualboot/ldbhelper.c"
}
# userdata in 4 KiB device blocks, from the kernel
geometry() {
  dev=$(ash readlink -f "$PART"); name=${dev##*/}
  start=$(ash cat "/sys/class/block/$name/start"); size=$(ash cat "/sys/class/block/$name/size")
  lbs=$(ash cat "/sys/block/${name%%[0-9]*}/queue/logical_block_size")
  [ "$lbs" = 4096 ] || die "$name: logical block size $lbs, this design has 4096"
  [ "$name" = sda15 ] || die "userdata is $name, the kernel and these notes have sda15 (LUN 0)"
  [ $((start % 8)) = 0 ] && [ $((size % 8)) = 0 ] || die "$name: start $start, size $size sectors: not 4 KiB multiples"
  PART_FIRST=$((start / 8)); PART_BLOCKS=$((size / 8))
}
# f2fs on dm-default-key on userdata: FIEMAP's address must be the partition's. check-map proves it later; this catches a table that says otherwise before any file exists.
check_dm() {
  t=$(ash dmctl table userdata 2>&1) || die "dmctl table userdata: $t"
  case "$t" in *default-key*) ;; *) die "userdata is not a default-key device: $t" ;; esac
  # "<start>-<end>: default-key, <cipher> <key> <iv_offset> <dev> <offset> ..."
  set -- $(printf '%s\n' "$t" | sed -n 's/.*default-key, *//p' | head -1)
  [ "${5:-x}" = 0 ] || die "default-key target offset is '${5:-?}', not 0 (or an unknown dmctl format): stop: $t"
  [ "$(printf '%s\n' "$t" | grep -c default-key)" = 1 ] || die "more than one default-key target: $t"
  say "dm: one default-key target over the whole of userdata, offset 0"
}

cmd=${1:-}
[ $# = 0 ] || shift
case "$cmd" in
status)
  need_android
  say "Android $(ash getprop ro.build.version.release), slot $(ash getprop ro.boot.slot_suffix), $(ash getprop ro.lineage.version)"
  ash df -h /data | tail -1
  ash mount | grep -E ' /data | /vendor/firmware_mnt ' || true
  if [ "$(ash id -u)" = 0 ]; then
    for c in get-current-slot get-number-slots; do printf '%s: ' "$c"; ash bootctl "$c"; done
    for s in 0 1; do
      printf 'slot %s: bootable ' "$s"; ash "bootctl is-slot-bootable $s >/dev/null 2>&1 && echo yes || echo no"
      printf 'slot %s: successful ' "$s"; ash "bootctl is-slot-marked-successful $s >/dev/null 2>&1 && echo yes || echo no"
    done
    ash ls -l "$AREA" 2>/dev/null || say "no area file ($AREA)"
    for n in /sys/fs/f2fs/*/gc_pin_file_thresh; do ash "cat $n" | sed 's/^/gc_pin_file_thresh /'; done
    ash getprop | grep -E 'update_engine|ota' || true
  else
    say "adb is not root: slot attributes and the file need Rooted debugging (owner)"
  fi
  say "Updater: $(ash pm list packages -e org.lineageos.updater | grep -c updater) enabled (an update writes slot b: docs/laurel_sprout/dual-boot.md)"
  ;;
size)
  "$TOOL" dualboot size --help >/dev/null
  case "${1:-ios26}" in
  ios26)  # iPhone12,1 23F84, the owner's donor. Decrypted image sizes as they are on disk (~/op10-apple/ios26/23F84-n104ap/os, 2026-11-02): OS, SystemOS, AppOS. EXPAND: root bytes per donor byte on the iOS 16 root
    "$TOOL" dualboot size --donor-bytes "${DONOR_BYTES:-8409579520,5221908480,14680064}" --expand "${EXPAND:-1.68}" --var-gib "${VAR_GIB:-8}" ;;
  ios16)  # the existing root: 16 GiB HFS+ volume, 12010 MiB used, on the phone as it is
    "$TOOL" dualboot size --donor-bytes $((16 << 30)) --expand 1 --var-gib 0 ;;
  *) die "size: ios16 or ios26" ;;
  esac
  ;;
allocate)
  need_confirm allocate
  gib=${1:?allocate needs GIB}
  need_helper
  geometry; check_dm
  bytes=$(awk -v g="$gib" 'BEGIN { b = g * 1073741824; s = 2097152; printf "%.0f", (int(b / s) + (b % s != 0)) * s }')
  free=$(ash df -k /data | awk 'NR==2 {print $4}')
  [ $((bytes / 1024 + 8 * 1024 * 1024)) -lt "$free" ] || die "/data has $free KiB free: $bytes bytes would leave under 8 GiB for Android (f2fs needs room, or GC can reach the pinned file)"
  ash "[ ! -e $AREA ]" || die "$AREA exists: remove it first"
  ash mkdir -p "${AREA%/*}"
  mkdir -p "$D"
  ash "$HELPER" alloc "$AREA" "$bytes" > "$D/map.txt"
  rm -f "$TABLE"   # a new allocation is a new table id: an old boot image must not fit it
  say "allocated $bytes bytes: $(grep -c ^extent "$D/map.txt") FIEMAP extents"
  "$0" map
  ;;
map)
  need_helper
  geometry; check_dm
  mkdir -p "$D"
  ash "$HELPER" map "$AREA" > "$D/map.txt"
  if [ -f "$TABLE" ]; then
    # same blocks as before? Then the table id stays: the area and the boot image are still one.
    id=$("$TOOL" dualboot show "$TABLE" | sed -n 's/.* id \([0-9a-f]*\),.*/0x\1/p' | head -1)
  else
    id=
  fi
  "$TOOL" dualboot table --fiemap "$D/map.txt" --part-first "$PART_FIRST" --part-blocks "$PART_BLOCKS" ${id:+--id "$id"} -o "$D/table.new"
  mv "$D/table.new" "$TABLE"
  ;;
check-map)
  need_confirm check-map
  need_helper
  [ -f "$TABLE" ] || die "no table: dual-boot.sh map"
  adb push "$TABLE" "$HELPER.table" >/dev/null
  ash "$HELPER" check-map "$HELPER.table" "$AREA" "$PART"
  ash "$HELPER" lock "$AREA"
  ;;
install)
  need_confirm install
  need_helper
  img=${1:-$APPLE/laurel-ios16-root.img}
  [ -f "$img" ] || die "missing $img"
  [ -f "$TABLE" ] || die "no table: dual-boot.sh map"
  adb push "$TABLE" "$HELPER.table" >/dev/null
  "$TOOL" dualboot stream "$TABLE" "$img" --index "$D/root.idx" | adb exec-in "$HELPER" write "$HELPER.table" "$PART"
  adb exec-in "$HELPER" verify "$HELPER.table" "$PART" < "$D/root.idx"
  say "installed $img; the area is not sealed yet: dual-boot.sh image, flash-slot-b, switch"
  ;;
image)
  [ -f "$TABLE" ] || die "no table: dual-boot.sh map"
  env DUALBOOT_TABLE="$TABLE" OP10TOOL="$TOOL" "$REPO/scripts/laurel/uefi-image.sh"
  ;;
flash-slot-b)
  need_confirm flash-slot-b
  "$REPO/scripts/laurel/android-guard.sh" boot-image "$BOOT_IMG"
  [ -f "$STOCK_DTBO" ] || die "missing $STOCK_DTBO"
  [ -n "$(fastboot devices)" ] || die "no phone in fastboot (adb reboot bootloader)"
  [ "$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: //p')" = a ] || die "current slot is not a"
  # Why stock dtbo: iOS has only booted with the stock DTB + stock dtbo (dtbo_b holds Lineage's now; ABL stops on an overlay failure). Slot a has its own dtbo_a.
  fastboot reboot bootloader; sleep 6
  fastboot flash boot_b "$BOOT_IMG"
  fastboot reboot bootloader; sleep 6
  fastboot flash dtbo_b "$STOCK_DTBO"
  say "boot_b and dtbo_b written. Slot a stays active. fastboot reboot starts Android; a switch comes from Android."
  ;;
switch)
  need_confirm switch
  need_helper
  [ -f "$TABLE" ] || die "no table"
  adb push "$TABLE" "$HELPER.table" >/dev/null
  [ "$(ash getprop ro.boot.slot_suffix)" = _a ] || die "Android is not on slot a (an update moved it?): docs/laurel_sprout/dual-boot.md"
  # the same table on the phone as in the image?
  im=$(sed -n 's/^table //p' "$BOOT_IMG.dualboot" 2>/dev/null || true)
  [ "$im" = "$(sha256sum "$TABLE" | cut -d' ' -f1)" ] || die "the boot image has another table: dual-boot.sh image, flash-slot-b"
  fsdev=$(ash mount | awk '$3 == "/data" && $5 == "f2fs" {print $1; exit}'); [ -n "$fsdev" ] || die "/data not f2fs"
  ash "$HELPER" seal "$HELPER.table" "$PART" "$fsdev" "$AREA"
  ash sync
  ash bootctl set-active-boot-slot 1
  say "slot b active, rebooting into iOS. Back: docs/laurel_sprout/dual-boot.md"
  adb reboot
  ;;
to-android)
  need_confirm to-android
  [ -n "$(fastboot devices)" ] || die "no phone in fastboot: out/bin/op10tool ctl bootloader, or Power+VolDown"
  fastboot set_active a
  fastboot reboot
  ;;
logs)
  need_helper
  o=${1:-$REPO/logs/dualboot-ioslog-$(date +%Y%m%d-%H%M%S).bin}
  blocks=$("$TOOL" dualboot show "$TABLE" | sed -n 's/.*(\([0-9]*\) blocks).*/\1/p' | head -1)
  adb push "$TABLE" "$HELPER.table" >/dev/null
  adb exec-out "$HELPER" read "$HELPER.table" "$PART" $((blocks - 1025)) 1025 > "$o"
  say "$o: first 4 KiB = header SWEETLOG, then the 4 MiB ring"
  ;;
remove)
  need_confirm remove
  need_root
  [ "$(ash getprop ro.boot.slot_suffix)" = _a ] || die "Android is not on slot a"
  ash chattr -i "$AREA"
  ash rm "$AREA"
  rm -f "$TABLE"
  say "file removed. boot_b still holds iOS: its kernel finds no header and writes nothing. Restore boot_b: BOOTIMG=~/laurel-backup/lineage-24.0-20261027/boot.img ANDROID_IMAGE=1 scripts/laurel/flash-boot.sh"
  ;;
*)
  sed -n 2,18p "$0" >&2; exit 2 ;;
esac
