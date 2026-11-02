# Mi A3 dual boot: the one place for the numbers of the iOS partition. Sourced by dual-boot.sh, android-guard.sh, uefi-image.sh, flash-root.sh, root.sh, ios26-root.sh.
# From `op10tool gpt plan` on the real table (backup ~/laurel-backup/android-20261102-0137); scripts/laurel/test-dualboot.sh compares them with what the tool prints.
# Blocks are 4096 bytes on LUN 0 of the phone.
USERDATA_FIRST=1831432
USERDATA_LAST=21633535               # about 70 % of the old 28288499 blocks, then up to the 2 MiB boundary
IOSROOT_FIRST=21633536               # 2 MiB aligned
IOSROOT_LAST=30119930                # the last usable block
IOSROOT_BLOCKS=$((IOSROOT_LAST - IOSROOT_FIRST + 1))
IOSROOT_BYTES=$((IOSROOT_BLOCKS * 4096))        # 34760273920
USERDATA_BYTES=$(((USERDATA_LAST - USERDATA_FIRST + 1) * 4096))
LOG_BYTES=$((1025 * 4096))                      # the console log at the end of iosroot: bsd/dev/sweet_ufs.c SWEET_LOG_BLOCKS
IOSROOT_VOLUME_MAX=$((IOSROOT_BYTES - LOG_BYTES))   # the largest HFS+ volume: 34756075520
# The iOS 26 root: this volume size is what ios26-root.sh builds. 34354491392 is the image that exists (built for the old area of 32 GiB): it fits, so it needs no rebuild.
IOS26_VOLUME_BYTES=34354491392
LAUREL_BACKUP=$HOME/laurel-backup
# slot b firmware that the boot LUN switch makes live (dual-boot.sh check_fw_b, the app's mark). boot_b, dtbo_b have their own check. vendor_b, system_b: not firmware of the boot chain, and big.
FW_B="abl bluetooth cmnlib cmnlib64 devcfg dsp hyp imagefv keymaster modem qupfw rpm storsec tz uefisecapp xbl xbl_config vbmeta"

# stdin: a boot-arg line or a boot image. Exit 0 when a token of ufsrw or rootrw can write: any value but the literal 0, also the bare name. [V pexpert/gen/bootargs.c PE_parse_boot_argn] the number parser takes
# 0x1, 01, 1k; a bare name is 1; the last token wins. The kernel opens writes only for the text 1 (patch 2950), so a token this misses cannot write. A kernel holds these names only between NUL bytes.
laurel_can_write() {
  [ -n "$(LC_ALL=C grep -aoE '(^|[[:space:]"])(ufsrw|rootrw)([[:space:]"]|$)|(ufsrw|rootrw)=[^[:space:]"]*' | LC_ALL=C grep -avE '^(ufsrw|rootrw)=0$' | head -1 | tr -d '\000' || true)" ]
}
# A size from getvar: 0x hex or decimal, or no value. One garbled answer (docs/notes.md) must not reach shell arithmetic: a bad value stops the shell with a text of its own, or reads as another number.
laurel_size_ok() {
  case "$1" in
  0x) return 1 ;;
  0x*[!0-9a-fA-F]*) return 1 ;;
  0x*) return 0 ;;
  ""|*[!0-9]*|0[0-9]*) return 1 ;;
  esac
  return 0
}
# COMMAND with a time limit, on macOS and Linux (no `timeout` there). Exit code: the command's; 124 at the limit. The command's stdin is /dev/null and it must not write into a pipe the caller reads to its end: a child of a killed command can hold that pipe.
laurel_with_limit() {
  _lim=$1; shift
  "$@" < /dev/null &
  _lim_p=$!
  _lim_f=$(mktemp "${TMPDIR:-/tmp}/ldb-limit.XXXXXX")
  (
    sleep "$_lim" & _lim_s=$!
    trap 'kill "$_lim_s" 2>/dev/null; exit 0' TERM
    wait "$_lim_s"
    echo limit > "$_lim_f"
    kill "$_lim_p" 2>/dev/null
    sleep 5 & _lim_s=$!
    wait "$_lim_s"
    kill -9 "$_lim_p" 2>/dev/null
  ) > /dev/null 2>&1 &
  _lim_w=$!
  _lim_r=0
  wait "$_lim_p" || _lim_r=$?
  kill "$_lim_w" 2>/dev/null || true
  wait "$_lim_w" 2>/dev/null || true
  if [ -s "$_lim_f" ]; then _lim_r=124; fi
  rm -f "$_lim_f"
  return "$_lim_r"
}
# the newest folder with this name pattern in the backup, or nothing
laurel_backup_dir() { ls -d "$LAUREL_BACKUP"/$1 2>/dev/null | sort | tail -1; }
# os_version field of a boot image header (v0-v2: byte 44): a 32-bit value: (A<<25 | B<<18 | C<<11 | year-2000<<4 | month)
boot_os_raw() { LC_ALL=C od -An -tu4 -j44 -N4 "$1" | tr -d ' \n'; }
boot_os_version() { _v=$(($1 >> 11)); echo "$((_v >> 14)).$(((_v >> 7) & 127)).$((_v & 127))"; }
boot_os_patch() { _l=$(($1 & 0x7ff)); printf '%d-%02d\n' $((2000 + (_l >> 4))) $((_l & 15)); }
# One hash over the list, from a SHA256SUMS of the backup (lines "<hash>  <name>_b.img"): the same text the app's helper hashes on the phone. Empty and exit 1 if a name is missing.
fw_b_combined() {
  _l=
  for _n in $FW_B; do
    _w=$(sed -n "s/^\([0-9a-f]*\)  ${_n}_b\.img\$/\1/p" "$1")
    [ -n "$_w" ] || return 1
    _l="$_l$_n $_w
"
  done
  printf '%s' "$_l" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1
}
