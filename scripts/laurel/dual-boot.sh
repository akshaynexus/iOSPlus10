#!/bin/sh
# Mi A3 dual boot: LineageOS on slot a, iOS on boot_b, the iOS root in a pinned file of Android's /data. Steps, reasons, recovery: docs/laurel_sprout/dual-boot.md.
# NOTHING HERE HAS RUN ON THE PHONE YET. Every step that writes needs CONFIRM=<its name>, and the owner's yes first.
#   dual-boot.sh status                 read-only: slots, /data, the file (pin, flags: encrypted or not), Android side state
#   dual-boot.sh size [ios16|ios26]     read-only: how big the area must be, and the owner's default
#   CONFIRM=allocate  dual-boot.sh allocate [GIB]    new pinned file on /data. Default (owner, 2026-11-02, about 30 % of userdata): SIZE=32G, so the area is 32 GiB + 6 MiB.
#                                                    GIB = area size, may be a fraction. A reserved file, not a partition. Refuses if under 16 GiB stay free for Android.
#   dual-boot.sh map                    read-only: FIEMAP -> out/laurel/dualboot/table.ldbt (validated). The same blocks keep the table id; other blocks get a new id
#   CONFIRM=check-map dual-boot.sh check-map         proof of the mapping: writes through the file, compares the raw blocks; a record on /data; then the immutable flag
#   CONFIRM=install   dual-boot.sh install [IMG]     the root image to the raw blocks of the file, after the file checks and the record; reads it back
#   dual-boot.sh image                  host only: the boot image with the table (scripts/laurel/uefi-image.sh). Build the root with SIZE=32G
#   CONFIRM=flash-slot-b dual-boot.sh flash-slot-b   boot_b = that image, dtbo_b = stock dtbo (phone in fastboot, must answer laurel_sprout); Android stays active
#   CONFIRM=switch    dual-boot.sh switch            Android -> iOS: slot b active, /data frozen, fingerprint, header, immediate reboot with no unmount
#   CONFIRM=to-android dual-boot.sh to-android       iOS -> Android with a computer: fastboot set_active a (phone in fastboot, must answer laurel_sprout: `op10tool ctl bootloader`)
#   dual-boot.sh logs [OUT]             read-only, on Android: iOS console log from the end of the area
#   CONFIRM=remove    dual-boot.sh remove [--unverified]   zero the headers, delete the file (root gone, space back). Only with slot a running and active.
#                                                    --unverified: the file no longer fits the table: no raw write, only the file goes
# A manual update (sideload) writes slot b and makes it active: switch refuses until Android is on slot a and boot_b, dtbo_b are ours again: docs/laurel_sprout/dual-boot.md.
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
DEFAULT_SIZE_GIB=32                 # owner decision 2026-11-02: about 70 % Android, 30 % iOS (30 % of userdata = 32.37 GiB)
OVERHEAD_BYTES=$(((256 + 1025) * 4096))   # 1 MiB header + 4 MiB + 4 KiB console log: laurel_dualboot.h, sweet_ufs.c
MIN_FREE_GIB=16                     # free /data after the allocation: f2fs needs room or GC reaches the pinned file, and Android must work
WRITE_WAIT=${WRITE_WAIT:-300}       # seconds for the result of a raw write after the last byte went out

say() { echo "dual-boot: $*"; }
die() { echo "dual-boot: FAILED: $*" >&2; exit 1; }
need_confirm() { [ "${CONFIRM:-}" = "$1" ] || { echo "dual-boot: refused: this step writes to the phone: CONFIRM=$1 (ask the owner first; docs/laurel_sprout/dual-boot.md)" >&2; exit 4; }; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

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
helper_hash() { cat "$REPO/tools/laurel-dualboot/ldbhelper.c" "$REPO/tools/laurel-dualboot/laurel_dualboot.h" > "$D/helper.src"; sha "$D/helper.src" | cut -c1-32; }
build_helper() {
  clang --target=aarch64-linux-gnu -std=gnu11 -O2 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld \
    -DLDB_HELPER_VERSION="\"$1\"" -I"$REPO/tools/laurel-dualboot" -o "$D/ldbhelper-arm64" "$REPO/tools/laurel-dualboot/ldbhelper.c"
}
# The helper on the phone is built from these sources: rebuilt when a source changed, and asked for its version after the push.
need_helper() {
  need_root
  mkdir -p "$D"
  _v=$(helper_hash)
  # the hash of its sources is in the binary: no stamp file that can disagree with it
  if [ ! -x "$D/ldbhelper-arm64" ] || ! LC_ALL=C grep -aqF "ldbhelper-version $_v" "$D/ldbhelper-arm64"; then build_helper "$_v"; fi
  adb push "$D/ldbhelper-arm64" "$HELPER" >/dev/null || die "adb push of the helper failed"
  ash chmod 700 "$HELPER" || die "chmod of the helper failed"
  _g=$(ash "$HELPER" version) || die "the helper does not run on the phone"
  [ "$_g" = "ldbhelper-version $_v" ] || die "the helper on the phone is '$_g', these sources are $_v: push failed or a stale binary"
}
# userdata in 4 KiB device blocks, from the kernel
geometry() {
  dev=$(ash readlink -f "$PART") || die "readlink $PART failed"
  name=${dev##*/}
  start=$(ash cat "/sys/class/block/$name/start") || die "no start of $name"
  size=$(ash cat "/sys/class/block/$name/size") || die "no size of $name"
  lbs=$(ash cat "/sys/block/${name%%[0-9]*}/queue/logical_block_size") || die "no block size of $name"
  PART_DEV=$(ash cat "/sys/class/block/$name/dev") || die "no device number of $name"
  [ "$lbs" = 4096 ] || die "$name: logical block size $lbs, this design has 4096"
  [ "$name" = sda15 ] || die "userdata is $name, the kernel and these notes have sda15 (LUN 0)"
  [ $((start % 8)) = 0 ] && [ $((size % 8)) = 0 ] || die "$name: start $start, size $size sectors: not 4 KiB multiples"
  PART_FIRST=$((start / 8)); PART_BLOCKS=$((size / 8)); PART_SECTORS=$size
}
# f2fs on dm-default-key on userdata: FIEMAP's address must be the partition's. check-map proves it later; this catches a table that says otherwise before any file exists.
# The format, read on the phone 2026-11-02 [V]: 0-226307992: default-key, aes-xts-plain64 - 0 8:15 0 3 allow_discards sector_size:4096 iv_large_sectors
#                                               range: target, cipher key iv_offset device offset ...
# Anything else stops here: another format, a target over part of the partition, another device, an offset.
check_dm() {
  t=$(ash dmctl table userdata) || die "dmctl table userdata failed"
  _l=$(printf '%s\n' "$t" | grep -E '^[0-9]+-[0-9]+: ' || true)
  [ "$(printf '%s\n' "$_l" | grep -c .)" = 1 ] || die "userdata has not exactly one device-mapper target: $t"
  # shellcheck disable=SC2086
  set -- $_l
  [ "$#" -ge 7 ] || die "unknown dmctl format: $t"
  [ "$2" = default-key, ] || die "userdata is not a default-key device: $t"
  [ "$1" = "0-$PART_SECTORS:" ] || die "the target is '$1', the partition has $PART_SECTORS sectors: it does not cover the whole of userdata from sector 0: $t"
  [ "$5" = 0 ] || die "default-key iv offset is '$5', not 0: $t"
  [ "$6" = "$PART_DEV" ] || die "the target sits on device '$6', userdata (sda15) is $PART_DEV: $t"
  [ "$7" = 0 ] || die "default-key target offset is '$7', not 0: $t"
  # the filesystem on /data must be this device-mapper device
  _m=$(ash mount) || die "mount on the phone failed"
  FSDEV=$(printf '%s\n' "$_m" | awk '$3 == "/data" && $5 == "f2fs" {print $1; exit}')
  [ -n "$FSDEV" ] || die "/data is not f2fs"
  _s=$(ash ls "/sys/block/${FSDEV##*/}/slaves") || die "$FSDEV has no slaves in sysfs: /data is not on device-mapper"
  [ "$_s" = sda15 ] || die "/data ($FSDEV) sits on '$_s', not on sda15"
  say "dm: one default-key target over the whole of userdata: $PART_SECTORS sectors, device $PART_DEV, offset 0; /data = $FSDEV"
}
# the table was made for this partition: first block and size
table_fits() {
  [ -f "$TABLE" ] || die "no table: dual-boot.sh map"
  _c=$("$TOOL" dualboot check "$TABLE") || die "the table does not pass: $_c"
  case "$_c" in
  *"userdata LBA $PART_FIRST + $PART_BLOCKS blocks"*) ;;
  *) die "the table is not for this userdata (LBA $PART_FIRST + $PART_BLOCKS blocks): $_c" ;;
  esac
}
# Exit code of a yes/no question to bootctl: 0 yes, 1 no. A lost phone stops the script.
slot_yes() {
  _r=0; ash "bootctl $1 $2 >/dev/null 2>&1" || _r=$?
  case "$_r" in 0) return 0 ;; 254|255) die "no answer from bootctl $1 $2" ;; *) return 1 ;; esac
}
slot_value() {
  _s=$(ash bootctl "$1") || die "bootctl $1 failed"
  printf '%s\n' "$_s"
}
# The phone on fastboot is one phone, and it says it is the Mi A3. Before every write: the OnePlus 10 Pro must never get boot_b, dtbo_b or set_active from here (CLAUDE.md).
# One getvar can answer wrongly on this ABL (docs/notes.md): three tries; only the positive answer counts.
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
# Back to Android after a failed switch. set-active writes 0x3F to slot a too, which clears its successful bit: mark it again, or slot a is no fallback target.
flip_back() {
  if ash bootctl set-active-boot-slot 0 && ash bootctl mark-boot-successful && [ "$(slot_value get-active-boot-slot)" = 0 ] && slot_yes is-slot-marked-successful 0; then
    say "slot a is active and marked successful again"
  else
    echo "dual-boot: slot b may stay active. The next boot tries iOS: its kernel finds no valid header and stays off, and ABL returns to Android when the retries end. Or: fastboot set_active a" >&2
  fi
}
# What is on boot_b, dtbo_b: read from the phone. A manual update (sideload) writes both and flips the slot.
slot_b_holds() {
  _n=$(wc -c < "$2" | tr -d ' ')
  _h=$(ash "head -c $_n /dev/block/by-name/$1 | sha256sum") || die "cannot read $1 on the phone"
  [ "${_h%% *}" = "$(sha "$2")" ] || die "$1 on the phone is not $2. A manual update (sideload) writes slot b: get Android on slot a again, then: dual-boot.sh image, flash-slot-b (docs/laurel_sprout/dual-boot.md, manual update)"
}

cmd=${1:-}
[ $# = 0 ] || shift
case "$cmd" in
status)
  need_android
  say "Android $(ash getprop ro.build.version.release), slot $(ash getprop ro.boot.slot_suffix), $(ash getprop ro.lineage.version)"
  ash df -h /data | tail -1 || true
  ash mount | grep -E ' /data | /vendor/firmware_mnt ' || true
  if [ "$(ash id -u)" = 0 ]; then
    for c in get-current-slot get-active-boot-slot get-number-slots; do printf '%s: ' "$c"; ash bootctl "$c" || echo "failed"; done
    for s in 0 1; do
      printf 'slot %s: bootable ' "$s"; ash "bootctl is-slot-bootable $s >/dev/null 2>&1 && echo yes || echo no" || echo unknown
      printf 'slot %s: successful ' "$s"; ash "bootctl is-slot-marked-successful $s >/dev/null 2>&1 && echo yes || echo no" || echo unknown
    done
    if ash "[ -e $AREA ]"; then
      ash ls -l "$AREA" || true
      # lsattr: i = immutable (after check-map), E = encrypted: an FBE policy on the file means f2fs counts GC failures also in background GC (docs/laurel_sprout/dual-boot.md)
      _a=$(ash lsattr "$AREA") || _a=unknown
      case "${_a%% *}" in
      *E*) say "file flags $_a: ENCRYPTED: background GC counts against the pin; the folder should have no policy" ;;
      unknown) say "file flags: lsattr failed" ;;
      *) say "file flags $_a: not encrypted" ;;
      esac
    else
      say "no area file ($AREA)"
    fi
    ash 'cat /sys/fs/f2fs/*/gc_pin_file_thresh' | sed 's/^/gc_pin_file_thresh /' || true
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
    # owner decision 2026-11-02: the iOS area is 32 GiB (30 % of userdata), so allocate 32. The volume is the area minus the header and log blocks.
    "$TOOL" dualboot size --donor-bytes "${DONOR_BYTES:-8409579520,5221908480,14680064}" --expand "${EXPAND:-1.68}" --var-gib "${VAR_GIB:-8}" --area-gib "${AREA_GIB:-32}" ;;
  ios16)  # the existing root: 16 GiB HFS+ volume, 12010 MiB used, on the phone as it is
    "$TOOL" dualboot size --donor-bytes $((16 << 30)) --expand 1 --var-gib 0 ;;
  *) die "size: ios16 or ios26" ;;
  esac
  say "owner default for allocate: SIZE=${DEFAULT_SIZE_GIB}G, about 30 % of userdata. It is a reserved file, not a partition: Android cannot use those blocks, and it can use all the others."
  ;;
allocate)
  need_confirm allocate
  need_helper
  geometry; check_dm
  if [ $# -gt 0 ]; then
    bytes=$(awk -v g="$1" 'BEGIN { b = g * 1073741824; s = 2097152; printf "%.0f", (int(b / s) + (b / s > int(b / s))) * s }')
  else
    bytes=$((((DEFAULT_SIZE_GIB << 30) + OVERHEAD_BYTES + 2097151) / 2097152 * 2097152))   # whole 2 MiB f2fs segments
  fi
  _df=$(ash df -k /data) || die "df /data failed"
  free=$(printf '%s\n' "$_df" | awk 'NR==2 {print $4}')
  case "$free" in ''|*[!0-9]*) die "cannot read the free space of /data: $_df" ;; esac
  need=$((bytes / 1024 + MIN_FREE_GIB * 1024 * 1024))
  [ "$need" -le "$free" ] || die "/data has $((free / 1024 / 1024)) GiB free ($free KiB). The area takes $((bytes / 1024 / 1024 / 1024)) GiB ($bytes bytes), and Android must keep at least $MIN_FREE_GIB GiB free (f2fs needs room, or GC can reach the pinned file). Free $(((need - free) / 1024 / 1024 + 1)) GiB on Android, or give a smaller GIB"
  _r=0; ash "[ ! -e $AREA ]" || _r=$?
  [ "$_r" = 0 ] || { [ "$_r" = 1 ] && die "$AREA exists: remove it first"; die "cannot test $AREA (status $_r)"; }
  ash mkdir -p "${AREA%/*}" || die "mkdir ${AREA%/*} failed"
  ash "$HELPER" alloc "$AREA" "$bytes" "$PART" "$FSDEV" > "$D/map.txt" || die "alloc failed: $(cat "$D/map.txt")"
  rm -f "$TABLE"   # a new allocation is a new table id: an old boot image must not fit it
  say "allocated $bytes bytes: $(grep -c ^extent "$D/map.txt") FIEMAP extents. A reserved file, not a partition: Android cannot use those blocks, and it can use all the others."
  "$0" map
  ;;
map)
  need_helper
  geometry; check_dm
  ash "$HELPER" map "$AREA" > "$D/map.txt" || die "map failed: $(cat "$D/map.txt")"
  id=
  if [ -f "$TABLE" ]; then
    _o=$("$TOOL" dualboot check "$TABLE") || die "the old table does not pass: $_o"
    id=$(printf '%s\n' "$_o" | sed -n 's/.* id \([0-9a-f]*\),.*/0x\1/p')
    [ -n "$id" ] || die "no id in the old table: $_o"
  fi
  "$TOOL" dualboot table --fiemap "$D/map.txt" --part-first "$PART_FIRST" --part-blocks "$PART_BLOCKS" ${id:+--id "$id"} -o "$D/table.new"
  # The same blocks as before: the id stays, and the area and the boot image are still one. Other blocks: a new id, so that the old boot image and the old check-map record do not fit.
  if [ -f "$TABLE" ] && ! cmp -s "$D/table.new" "$TABLE"; then
    say "the file's blocks are not the ones in the old table: new table id. Run check-map, install, image, flash-slot-b again"
    "$TOOL" dualboot table --fiemap "$D/map.txt" --part-first "$PART_FIRST" --part-blocks "$PART_BLOCKS" -o "$D/table.new"
  fi
  mv "$D/table.new" "$TABLE"
  ;;
check-map)
  need_confirm check-map
  need_helper
  geometry; check_dm; table_fits
  adb push "$TABLE" "$HELPER.table" >/dev/null || die "adb push of the table failed"
  ash "$HELPER" check-map "$HELPER.table" "$AREA" "$PART" || die "check-map did not pass: the file stays without the immutable flag; do not install"
  ash "$HELPER" lock "$AREA" || die "lock failed: the file has no immutable flag"
  ;;
install)
  need_confirm install
  need_helper
  geometry; check_dm; table_fits
  img=${1:-$APPLE/laurel-ios16-root.img}
  [ -f "$img" ] || die "missing $img"
  adb push "$TABLE" "$HELPER.table" >/dev/null || die "adb push of the table failed"
  # adb exec-in copies stdin to the phone and returns 0 when stdin ends: no remote output, no remote exit code, and the remote side can still be running [V adb source, client/commandline.cpp].
  # So the helper's text and exit code go to a file on the phone, and the host waits for that file. No file = failed.
  R=$HELPER.result
  ash rm -f "$R" "$R.t" || die "cannot clear $R"
  rm -f "$D/stream.rc"
  { rc=0; "$TOOL" dualboot stream "$TABLE" "$img" --index "$D/root.idx" || rc=$?; echo "$rc" > "$D/stream.rc"; } |
    adb exec-in "$HELPER write $HELPER.table $PART $AREA > $R.t 2>&1; echo rc=\$? >> $R.t; mv $R.t $R" || say "adb exec-in stopped early; the result file decides"
  say "stream sent; waiting for the result on the phone"
  w=0; res=
  until res=$(ash "cat $R" 2>/dev/null); do
    w=$((w + 2)); [ "$w" -le "$WRITE_WAIT" ] || die "no result of the raw write after $WRITE_WAIT s ($R): the state of the area is unknown; do not seal. Run install again"
    sleep 2
  done
  printf '%s\n' "$res"
  case "$res" in *"${NL}rc=0"|"rc=0") ;; *) die "the raw write failed on the phone: $res" ;; esac
  [ "$(cat "$D/stream.rc" 2>/dev/null || true)" = 0 ] || die "op10tool stream failed: the image did not go out in full"
  frames=$(($(wc -c < "$D/root.idx") / 32 - 1))
  case "$res" in *"write ok: $frames frames"*) ;; *) die "the phone wrote another number of frames than the $frames that were sent: $res" ;; esac
  # the read-back: a command with a real exit code, its numbers checked here. The index is a file on the phone, so nothing here depends on exec-in.
  adb push "$D/root.idx" "$HELPER.idx" >/dev/null || die "adb push of the index failed"
  v=$(ash "$HELPER verify $HELPER.table $PART $AREA < $HELPER.idx") || die "the read-back failed: $v"
  printf '%s\n' "$v"
  case "$v" in *"verify: $frames frames, 0 wrong"*) ;; *) die "the read-back does not say $frames frames, 0 wrong: $v" ;; esac
  say "installed $img, read back: $frames frames, 0 wrong. The area is not sealed yet: dual-boot.sh image, flash-slot-b, switch"
  ;;
image)
  [ -f "$TABLE" ] || die "no table: dual-boot.sh map"
  env DUALBOOT_TABLE="$TABLE" OP10TOOL="$TOOL" "$REPO/scripts/laurel/uefi-image.sh"
  ;;
flash-slot-b)
  need_confirm flash-slot-b
  [ -f "$STOCK_DTBO" ] || die "missing $STOCK_DTBO"
  need_fastboot_mi_a3
  "$REPO/scripts/laurel/android-guard.sh" boot-image "$BOOT_IMG"
  _cs=$(fastboot -s "$FB_S" getvar current-slot 2>&1 | sed -n 's/^current-slot: //p' | tr -d '\r')
  [ "$_cs" = a ] || die "current slot is '$_cs', not a: Android must be on slot a (after a manual update: docs/laurel_sprout/dual-boot.md)"
  # Why stock dtbo: iOS has only booted with the stock DTB + stock dtbo (dtbo_b holds Lineage's now; ABL stops on an overlay failure). Slot a has its own dtbo_a.
  fastboot -s "$FB_S" reboot bootloader; sleep 6
  need_fastboot_mi_a3
  fastboot -s "$FB_S" flash boot_b "$BOOT_IMG"
  fastboot -s "$FB_S" reboot bootloader; sleep 6
  need_fastboot_mi_a3
  fastboot -s "$FB_S" flash dtbo_b "$STOCK_DTBO"
  say "boot_b and dtbo_b written. Slot a stays active. fastboot reboot starts Android; a switch comes from Android."
  ;;
switch)
  need_confirm switch
  need_helper
  geometry; check_dm; table_fits
  # slots: Android runs on a, a is active, a can take a fallback. A manual update or the Updater moves these.
  [ "$(ash getprop ro.boot.slot_suffix)" = _a ] || die "Android is not on slot a (a manual update moves it): docs/laurel_sprout/dual-boot.md, manual update"
  [ "$(slot_value get-current-slot)" = 0 ] || die "bootctl: the current slot is not 0: docs/laurel_sprout/dual-boot.md, manual update"
  [ "$(slot_value get-active-boot-slot)" = 0 ] || die "bootctl: slot a is not active (an update finished and waits for a reboot?): docs/laurel_sprout/dual-boot.md, manual update"
  slot_yes is-slot-bootable 0 || die "slot a is not bootable: no way back"
  slot_yes is-slot-marked-successful 0 || die "slot a is not marked successful: ABL has nothing to fall back to. Boot Android to the end first"
  # the image: fence kernel in it, the same table as here, and it is what boot_b holds
  "$REPO/scripts/laurel/android-guard.sh" boot-image "$BOOT_IMG"
  im=$(sed -n 's/^table //p' "$BOOT_IMG.dualboot" 2>/dev/null || true)
  [ "$im" = "$(sha "$TABLE")" ] || die "the boot image has another table: dual-boot.sh image, flash-slot-b"
  [ -f "$STOCK_DTBO" ] || die "missing $STOCK_DTBO"
  slot_b_holds boot_b "$BOOT_IMG"
  slot_b_holds dtbo_b "$STOCK_DTBO"
  adb push "$TABLE" "$HELPER.table" >/dev/null || die "adb push of the table failed"
  # Slot first: bootctl goes through binder and the HAL, which must run with /data not frozen. A boot right now goes to slot b with no new seal: the kernel compares the old fingerprint and stays off.
  ash bootctl set-active-boot-slot 1 || { _e=$?; flip_back; die "bootctl set-active-boot-slot 1 failed (status $_e): no seal was made"; }
  [ "$(slot_value get-active-boot-slot)" = 1 ] || { flip_back; die "slot b is not active after set-active: no seal was made"; }
  # 0x3F (priority 3, active, 7 retries, successful clear). A slot b still marked successful: ABL does not count down, so there is no way back without a computer.
  if slot_yes is-slot-marked-successful 1; then flip_back; die "slot b stays marked successful after set-active: ABL would not count down: no seal was made"; fi
  # The seal reboots the phone itself, with no unmount: a clean reboot (adb reboot) writes a CP_UMOUNT checkpoint, and the fingerprint would no longer fit.
  rc=0; s=$(ash "$HELPER" seal "$HELPER.table" "$PART" "$FSDEV" "$AREA") || rc=$?
  [ -z "$s" ] || printf '%s\n' "$s"
  case "$rc:$s" in
  255:*"sealed: generation"*|254:*"sealed: generation"*)
    say "sealed, /data frozen, phone rebooting into iOS. Android: an unclean reboot on a clean checkpoint (docs/laurel_sprout/dual-boot.md). Back: docs/laurel_sprout/dual-boot.md" ;;
  255:*|254:*)
    # adb gone and no line from the helper: reboot or a lost cable. Each state is safe for the data: a header that is not current stays off. Nothing here can tell which.
    if [ "$(adb get-state 2>/dev/null || true)" = device ]; then
      flip_back
      die "adb lost the seal, the phone still answers: no reboot came; slot a set active again if the line above says so"
    fi
    echo "dual-boot: UNKNOWN: adb lost the phone during the seal and no 'sealed' line came. Slot b is active. If iOS does not say 'LAUREL DUALBOOT: on', ABL returns to Android when the retries end." >&2
    exit 5 ;;
  0:*)
    flip_back
    die "the seal returned without a reboot: $s" ;;
  *)
    flip_back
    die "the seal failed (status $rc): no iOS boot from this switch: $s" ;;
  esac
  ;;
to-android)
  need_confirm to-android
  need_fastboot_mi_a3
  fastboot -s "$FB_S" set_active a
  fastboot -s "$FB_S" reboot
  ;;
logs)
  need_helper
  [ -f "$TABLE" ] || die "no table: dual-boot.sh map"
  o=${1:-$REPO/logs/dualboot-ioslog-$(date +%Y%m%d-%H%M%S).bin}
  _c=$("$TOOL" dualboot check "$TABLE") || die "the table does not pass: $_c"
  blocks=$(printf '%s\n' "$_c" | sed -n 's/.*(\([0-9]*\) blocks).*/\1/p' | head -1)
  [ -n "$blocks" ] || die "no block count in: $_c"
  adb push "$TABLE" "$HELPER.table" >/dev/null || die "adb push of the table failed"
  # adb exec-out has no remote exit code: the size is the check
  adb exec-out "$HELPER" read "$HELPER.table" "$PART" $((blocks - 1025)) 1025 > "$o" || die "adb exec-out failed"
  [ "$(wc -c < "$o" | tr -d ' ')" = $((1025 * 4096)) ] || die "$o has $(wc -c < "$o" | tr -d ' ') bytes, not $((1025 * 4096)): the read failed on the phone"
  say "$o: first 4 KiB = header SWEETLOG, then the 4 MiB ring"
  ;;
remove)
  need_confirm remove
  need_helper
  [ "$(ash getprop ro.boot.slot_suffix)" = _a ] || die "Android is not on slot a"
  [ "$(slot_value get-current-slot)" = 0 ] || die "bootctl: the current slot is not 0"
  [ "$(slot_value get-active-boot-slot)" = 0 ] || die "slot b is active: the next boot would go to iOS. First: bootctl set-active-boot-slot 0 (owner yes)"
  _r=0; ash "[ -e $AREA ]" || _r=$?
  case "$_r" in
  0) ;;
  1) say "no file on the phone"; rm -f "$TABLE"; exit 0 ;;
  *) die "cannot test $AREA (status $_r)" ;;
  esac
  if [ "${1:-}" = --unverified ]; then
    # for a file that no longer has the blocks of the table: no raw write can be right here. A stale header in freed blocks only makes a kernel stay off.
    ash "$HELPER" unlink-only "$AREA" || die "cannot remove the file; the table stays"
  else
    geometry; check_dm; table_fits
    adb push "$TABLE" "$HELPER.table" >/dev/null || die "adb push of the table failed"
    # zero first (the mount has discard, but discard is no promise), remove after: the helper does both, in this order
    ash "$HELPER" wipe "$HELPER.table" "$PART" "$AREA" || die "wipe failed: the file and the table stay. If the file has moved: dual-boot.sh remove --unverified"
  fi
  _r=0; ash "[ ! -e $AREA ]" || _r=$?
  [ "$_r" = 0 ] || die "the file is still on the phone (status $_r): the table stays"
  rm -f "$TABLE"
  say "file removed, area header and volume header zero. boot_b still holds iOS: its kernel finds no header and writes nothing. Restore boot_b: BOOTIMG=~/laurel-backup/lineage-24.0-20261027/boot.img ANDROID_IMAGE=1 scripts/laurel/flash-boot.sh"
  ;;
*)
  sed -n 2,19p "$0" >&2; exit 2 ;;
esac
