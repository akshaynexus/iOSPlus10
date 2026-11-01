# Android -> iOS on the Mi A3: runs as root through adbd, sent by the app (tools/laurel-switcher). docs/laurel_sprout/boot-menu.md.
#   sh to-ios.sh check    all checks, no change
#   sh to-ios.sh switch   checks, then slot b through the boot control HAL, then a normal Android reboot
# Each outcome ends in one line: LAUREL SWITCH: ok ... | LAUREL SWITCH: refused: <reason>. Nothing is written before all checks pass.
# POSIX sh: mksh on the phone, dash in the host test (scripts/laurel/boot-menu-test.sh). The fence text and sizes are filled in by scripts/laurel/switcher-asset.sh at build time.
# It does not replace the flow of docs/laurel_sprout/dual-boot.md: a read-only image, or a writable one not built by `dual-boot.sh image rw` after the read-only run, is refused. The gate on the host
# (ro-result, android-check) is in android-guard.sh and dual-boot.sh; what this script can see on the phone is that image's marks.
B=${LS_BLOCK:-/dev/block/by-name}
FENCE='@FENCE_MARKER@'

refuse() { echo "LAUREL SWITCH: refused: $*"; exit 1; }

# a field of the form name=<number>:<sha256> from the boot image's command line (512 bytes at offset 64)
field() {
  for t in $CMD; do
    case "$t" in "$1="*) echo "${t#*=}"; return 0 ;; esac
  done
  return 1
}

check() {
  [ "$(id -u)" = 0 ] || refuse "not root: turn on Developer options -> Rooted debugging"
  [ "$(getprop ro.product.device)" = laurel_sprout ] || refuse "this phone is not the Mi A3"
  [ "$(getprop ro.boot.slot_suffix)" = _a ] || refuse "Android does not run on slot a: an update moved it (boot-menu.md)"
  [ "$(bootctl get-current-slot 2>/dev/null)" = 0 ] || refuse "HAL says the current slot is not 0"
  [ "$(bootctl get-active-boot-slot 2>/dev/null)" = 0 ] || refuse "slot a is not active: an update waits for its reboot"
  # ABL's fallback target and the way home from iOS
  bootctl is-slot-marked-successful 0 >/dev/null 2>&1 || refuse "slot a is not marked successful: wait for Android to finish its boot"
  case "$FENCE" in LAUREL-*) ;; *) refuse "this app was built without the kernel fence text" ;; esac
  # the layout of scripts/lib/laurel-layout.sh, as dual-boot.sh check_layout reads it
  [ -e "$B/iosroot" ] || refuse "no partition iosroot: iOS is not installed"
  r=$(readlink -f "$B/iosroot"); u=$(readlink -f "$B/userdata")
  [ "${r##*/}" = sda16 ] && [ "${u##*/}" = sda15 ] || refuse "iosroot is $r, userdata is $u: expected sda16, sda15"
  [ "$(blockdev --getsize64 "$B/iosroot" 2>/dev/null)" = @IOSROOT_BYTES@ ] || refuse "iosroot does not have the size of the plan"
  [ "$(blockdev --getsize64 "$B/userdata" 2>/dev/null)" = @USERDATA_BYTES@ ] || refuse "userdata does not have the size of the plan"

  [ "$(dd if="$B/boot_b" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] || refuse "boot_b holds no boot image"
  CMD=$(dd if="$B/boot_b" bs=1 skip=64 count=512 2>/dev/null | tr -d '\000')
  v=$(field laurel_ios_image) || refuse "boot_b does not hold our image: a read-only image or an Android image. The read-only boot goes only through dual-boot.sh switch"
  [ "$(field laurel_ios_mode)" = rw ] || refuse "boot_b is not the writable image. The read-only boot goes only through dual-boot.sh switch"
  pages=${v%%:*}; want=${v#*:}
  case "$pages" in ''|*[!0-9]*) refuse "boot_b marker has a bad size" ;; esac
  # 16384 pages = the 64 MiB of boot_b
  [ "$pages" -gt 0 ] && [ "$pages" -lt 16384 ] || refuse "boot_b marker has a bad size"
  got=$(dd if="$B/boot_b" bs=4096 skip=1 count="$pages" 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ "$got" = "$want" ] || refuse "boot_b is damaged or incomplete (hash)"

  v=$(field laurel_ios_dtbo) || refuse "boot_b has no stock dtbo mark"
  bytes=${v%%:*}; want=${v#*:}
  case "$bytes" in ''|*[!0-9]*) refuse "dtbo mark has a bad size" ;; esac
  got=$(head -c "$bytes" "$B/dtbo_b" 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ "$got" = "$want" ] || refuse "dtbo_b is not the stock dtbo that iOS needs"

  # this kernel fence: an image that holds an older one was flashed before this app was built
  grep -aqF "$FENCE" "$B/boot_b" || refuse "boot_b holds no kernel with this fence ($FENCE)"
  # S1: ABL gives TrustZone the OS version of the header it loads: the same for both, or Android's keys change. After a sideload the two differ
  [ "$(od -An -tu4 -j44 -N4 "$B/boot_a" 2>/dev/null | tr -d ' ')" = "$(od -An -tu4 -j44 -N4 "$B/boot_b" 2>/dev/null | tr -d ' ')" ] || refuse "boot_a and boot_b differ in the OS version of their headers: build the image again from a backup of this Lineage"
  # the root the image was built for: same check as dual-boot.sh switch. Only dual-boot.sh image sets this mark, and for rw only after ro-result and android-check
  v=$(field laurel_ios_root) || refuse "boot_b has no root mark: it was not built by dual-boot.sh image rw"
  bytes=${v%%:*}; want=${v#*:}
  case "$bytes" in ''|*[!0-9]*) refuse "root mark has a bad size" ;; esac
  got=$(head -c "$bytes" "$B/iosroot" 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ "$got" = "$want" ] || refuse "iosroot does not start with the root this image was built for"
}

back_to_a() {
  bootctl set-active-boot-slot 0 >/dev/null 2>&1
  bootctl mark-boot-successful >/dev/null 2>&1
}

case "${1:-}" in
check)
  check
  echo "LAUREL SWITCH: ok: ready"
  ;;
switch)
  check
  bootctl set-active-boot-slot 1 >/dev/null 2>&1 || { back_to_a; refuse "the HAL refused slot b; slot a stays"; }
  [ "$(bootctl get-active-boot-slot 2>/dev/null)" = 1 ] || { back_to_a; refuse "slot b is not active after the HAL call; slot a stays"; }
  # the retries of slot b must count, or a broken Mu never falls back to Android (HAL byte 0x3F clears the bit)
  if bootctl is-slot-marked-successful 1 >/dev/null 2>&1; then back_to_a; refuse "slot b stayed marked successful; slot a stays"; fi
  echo "LAUREL SWITCH: ok: slot b active, rebooting"
  svc power reboot 2>/dev/null || setprop sys.powerctl reboot
  ;;
*)
  refuse "usage: to-ios.sh check|switch"
  ;;
esac
