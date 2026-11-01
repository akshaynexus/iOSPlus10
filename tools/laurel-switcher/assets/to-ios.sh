# Android -> iOS on the Mi A3: runs as root through adbd, sent by the app (tools/laurel-switcher). docs/laurel_sprout/boot-menu.md.
#   sh to-ios.sh check    all checks, no change
#   sh to-ios.sh switch   checks, then slot b through the boot control HAL, then a normal Android reboot
#   sh to-ios.sh lock     root: adbd listens on loopback only from now on until the next reboot, and goes back to shell
#   sh to-ios.sh port     no root: where adbd listens
# Each outcome ends in one line: LAUREL SWITCH: ok ... | LAUREL SWITCH: refused: <reason>. Nothing is written before all checks pass.
# POSIX sh: mksh on the phone, dash in the host test (scripts/laurel/boot-menu-test.sh). The fence text, sizes, list and port are filled in by scripts/laurel/switcher-asset.sh at build time.
# It holds what `dual-boot.sh switch` holds, from the phone's side: a read-only image, or a writable one not built by `dual-boot.sh image rw` after the read-only run, is refused.
# The gate on the host (ro-result, android-check) is in android-guard.sh and dual-boot.sh; `android-opened` is checked here live, from the same facts as `dual-boot.sh android-check`.
B=${LS_BLOCK:-/dev/block/by-name}
R=${LS_ROOT:-}
FENCE='@FENCE_MARKER@'
FW_B='@FW_B@'
PORT='@PORT@'
IOSROOT_BYTES='@IOSROOT_BYTES@'
USERDATA_BYTES='@USERDATA_BYTES@'
IOSROOT_FIRST='@IOSROOT_FIRST@'
USERDATA_FIRST='@USERDATA_FIRST@'

refuse() { echo "LAUREL SWITCH: refused: $*"; exit 1; }

# yes, no or unknown: as slot_answer in dual-boot.sh [V fix2, real bootctl]: yes = stdout 1, exit 0; no = stdout 0, exit 70. A HAL error also exits 70, with other text: that is not a no.
slot_answer() {
  a=$(bootctl "$1" "$2" 2>&1); r=$?
  case "$r:$a" in
  0:1|0:yes|0:) echo yes ;;
  70:0|1:0|1:no|70:no|1:) echo no ;;
  *) echo unknown ;;
  esac
}

# a field of the form name=value from the boot image's command line (512 bytes at offset 64)
field() {
  for t in $CMD; do
    case "$t" in "$1="*) echo "${t#*=}"; return 0 ;; esac
  done
  return 1
}

# the partition table the kernel sees, in 512-byte sectors, as dual-boot.sh check_layout
part_is() { # NAME FIRST_BLOCK BYTES
  [ "$(cat "$R/sys/class/block/$1/start" 2>/dev/null)" = "$(($2 * 8))" ] && [ "$(cat "$R/sys/class/block/$1/size" 2>/dev/null)" = "$(($3 / 512))" ]
}

# the same facts as `dual-boot.sh android-check`, live: this Android has opened its data on the new layout
android_opened() {
  [ "$(getprop sys.boot_completed)" = 1 ] || refuse "Android has not finished booting"
  [ "$(getprop sys.user.0.ce_available)" = true ] || refuse "user data is not open: unlock the phone once"
  [ "$(getprop ro.crypto.state)" = encrypted ] || refuse "ro.crypto.state is not encrypted"
  fs=$(mount | awk '$3 == "/data" && $5 == "f2fs" {print $1; exit}')
  [ -n "$fs" ] || refuse "/data is not f2fs"
  [ "$(ls "$R/sys/block/${fs##*/}/slaves" 2>/dev/null)" = sda15 ] || refuse "/data ($fs) does not sit on sda15"
  [ "$(dd if="$fs" bs=4096 count=1 2>/dev/null | od -An -tu4 -j1024 -N4 | tr -d ' ')" = 4076150800 ] || refuse "no f2fs superblock on $fs"
  set -- $(dd if="$fs" bs=4096 count=1 2>/dev/null | od -An -tu4 -j1060 -N8)
  [ "$#" = 2 ] && [ "$((($1 + ($2 << 32)) * 4096))" -le "$USERDATA_BYTES" ] || refuse "the f2fs on /data is larger than the new userdata: format data in recovery"
}

# [V phone] Lineage 24 has no update_engine_client, only the daemon. Then its own files [V update_engine common/constants.h]: an update stopped halfway keeps its next operation, one finished in this boot waits for its reboot.
update_idle() {
  if command -v update_engine_client >/dev/null 2>&1; then
    case "$(update_engine_client --status 2>&1)" in
    *UPDATE_STATUS_IDLE*) ;;
    *) refuse "update_engine is not idle" ;;
    esac
  else
    p=$R/data/misc/update_engine/prefs
    v=$(cat "$p/update-state-next-operation" 2>/dev/null)
    case "$v" in ''|-1) ;; *) refuse "an update is in progress (next operation $v)" ;; esac
    v=$(cat "$p/update-completed-on-boot-id" 2>/dev/null)
    [ -z "$v" ] || [ "$v" != "$(cat "$R/proc/sys/kernel/random/boot_id" 2>/dev/null)" ] || refuse "an update finished and waits for its reboot"
  fi
  [ "$(bootctl get-snapshot-merge-status 2>/dev/null)" = none ] || refuse "a snapshot merge is not finished"
}

check() {
  [ "$(id -u)" = 0 ] || refuse "not root: turn on Developer options -> Rooted debugging"
  [ "$(getprop ro.product.device)" = laurel_sprout ] || refuse "this phone is not the Mi A3"
  case "$FENCE" in LAUREL-*) ;; *) refuse "this app was built without the kernel fence text" ;; esac
  [ "$(getprop ro.boot.slot_suffix)" = _a ] || refuse "Android does not run on slot a: an update moved it (boot-menu.md)"
  [ "$(bootctl get-current-slot 2>/dev/null)" = 0 ] || refuse "HAL says the current slot is not 0"
  [ "$(bootctl get-active-boot-slot 2>/dev/null)" = 0 ] || refuse "slot a is not active: an update waits for its reboot"
  # ABL's fallback target and the way home from iOS
  case "$(slot_answer is-slot-bootable 0)" in yes) ;; no) refuse "slot a is not bootable: no way back" ;; *) refuse "the HAL gives no answer for slot a (bootable)" ;; esac
  case "$(slot_answer is-slot-marked-successful 0)" in yes) ;; no) refuse "slot a is not marked successful: wait for Android to finish its boot" ;; *) refuse "the HAL gives no answer for slot a (successful)" ;; esac
  update_idle

  # the layout of scripts/lib/laurel-layout.sh, as dual-boot.sh check_layout reads it
  [ -e "$B/iosroot" ] || refuse "no partition iosroot: iOS is not installed"
  r=$(readlink -f "$B/iosroot"); u=$(readlink -f "$B/userdata")
  [ "${r##*/}" = sda16 ] && [ "${u##*/}" = sda15 ] || refuse "iosroot is $r, userdata is $u: expected sda16, sda15"
  part_is sda16 "$IOSROOT_FIRST" "$IOSROOT_BYTES" || refuse "iosroot does not have the start and size of the plan"
  part_is sda15 "$USERDATA_FIRST" "$USERDATA_BYTES" || refuse "userdata does not have the start and size of the plan"
  android_opened

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

  # this kernel fence: the mark says which one the image was built with, and the text must be in the image
  v=$(field laurel_ios_fence) || refuse "boot_b has no fence mark"
  [ "$v" = "$(printf '%s' "$FENCE" | sha256sum | cut -d' ' -f1)" ] || refuse "boot_b has another kernel fence than this app: build both again"
  grep -aqF "$FENCE" "$B/boot_b" || refuse "boot_b holds no kernel with this fence ($FENCE)"
  # S1: bytes 44..47 of both headers: ABL gives TrustZone the OS version of the header it loads: the same for both, or Android's keys change. After a sideload the two differ
  [ "$(od -An -tx1 -j44 -N4 "$B/boot_a" 2>/dev/null)" = "$(od -An -tx1 -j44 -N4 "$B/boot_b" 2>/dev/null)" ] || refuse "boot_a and boot_b differ in the OS version of their headers: build the image again from a backup of this Lineage"
  # the root the image was built for: same check as dual-boot.sh switch. Only dual-boot.sh image sets this mark, and for rw only after ro-result and android-check
  v=$(field laurel_ios_root) || refuse "boot_b has no root mark: it was not built by dual-boot.sh image rw"
  bytes=${v%%:*}; want=${v#*:}
  case "$bytes" in ''|*[!0-9]*) refuse "root mark has a bad size" ;; esac
  got=$(head -c "$bytes" "$B/iosroot" 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ "$got" = "$want" ] || refuse "iosroot does not start with the root this image was built for"
  # slot b's boot chain: set-active moves the boot LUN to xbl_b. One hash over the list of dual-boot.sh check_fw_b, last because it reads the most
  v=$(field laurel_ios_fwb) || refuse "boot_b has no slot b firmware mark"
  got=$(for n in $FW_B; do printf '%s %s\n' "$n" "$(sha256sum "$B/${n}_b" 2>/dev/null | cut -d' ' -f1)"; done | sha256sum | cut -d' ' -f1)
  [ "$got" = "$v" ] || refuse "slot b firmware is not the backup's: set-active would run another boot chain"
}

back_to_a() {
  bootctl set-active-boot-slot 0 >/dev/null 2>&1
  bootctl mark-boot-successful >/dev/null 2>&1
  [ "$(bootctl get-active-boot-slot 2>/dev/null)" = 0 ] && [ "$(slot_answer is-slot-marked-successful 0)" = yes ] || echo "LAUREL SWITCH: note: the way back to slot a did not verify: fastboot set_active a"
}

# where adbd listens, from the kernel: loopback, all (also Wi-Fi), none
port_state() {
  hex=$(printf '%04X' "$PORT")
  a=$(awk -v p=":$hex" '$4 == "0A" && substr($2, length($2) - 4) == p {print $2}' "$R/proc/net/tcp" "$R/proc/net/tcp6" 2>/dev/null)
  [ -n "$a" ] || { echo none; return; }
  for x in $a; do
    case "${x%:*}" in 0100007F|00000000000000000000000001000000|0000000000000000FFFF00000100007F) ;; *) echo all; return ;; esac
  done
  echo loopback
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
  # the retries of slot b must count, or a broken Mu never falls back to Android (HAL byte 0x3F clears the bit). A HAL error is not a "no"
  case "$(slot_answer is-slot-marked-successful 1)" in
  no) ;;
  yes) back_to_a; refuse "slot b stayed marked successful; slot a stays" ;;
  *) back_to_a; refuse "the HAL gives no answer for slot b after the HAL call; slot a stays" ;;
  esac
  echo "LAUREL SWITCH: ok: slot b active, rebooting"
  svc power reboot 2>/dev/null || setprop sys.powerctl reboot
  ;;
lock)
  [ "$(id -u)" = 0 ] || refuse "not root"
  # [V adb daemon/main.cpp, socket_spec.cpp] service.adb.listen_addrs goes before the port properties; tcp:localhost:N binds loopback only. The property ends at the reboot; persist.adb.tcp.port stays, so the next boot has its window again
  setprop service.adb.listen_addrs "tcp:localhost:$PORT"
  setprop service.adb.root 0
  echo "LAUREL SWITCH: ok: adbd restarts on loopback as shell"
  setprop ctl.restart adbd
  ;;
port)
  echo "LAUREL SWITCH: ok: $(port_state)"
  ;;
*)
  refuse "usage: to-ios.sh check|switch|lock|port"
  ;;
esac
