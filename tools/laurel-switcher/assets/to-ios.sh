# Android -> iOS on the Mi A3: runs as root through adbd, sent by the app (tools/laurel-switcher). docs/laurel_sprout/boot-menu.md.
#   sh to-ios.sh check    all checks, no change
#   sh to-ios.sh switch   checks, then slot b through the boot control HAL, then a normal Android reboot
# Each outcome ends in one line: LAUREL SWITCH: ok ... | LAUREL SWITCH: refused: <reason>. Nothing is written before all checks pass.
# POSIX sh: mksh on the phone, dash in the host test (scripts/laurel/boot-menu-test.sh).
B=${LS_BLOCK:-/dev/block/by-name}

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
  [ -e "$B/iosroot" ] || refuse "no partition iosroot: iOS is not installed"

  [ "$(dd if="$B/boot_b" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] || refuse "boot_b holds no boot image"
  CMD=$(dd if="$B/boot_b" bs=1 skip=64 count=512 2>/dev/null | tr -d '\000')
  v=$(field laurel_ios_image) || refuse "boot_b does not hold our image (Android boot image?)"
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
