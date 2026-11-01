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
