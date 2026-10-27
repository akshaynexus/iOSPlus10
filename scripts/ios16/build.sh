#!/bin/sh
# Build the iOS 16 boot images for the NE2211 with the native tools (scripts/setup/native-tools.sh once;
# scripts/lib/native-env.sh maps the port's aarch64-linux-gnu-* names to Homebrew aarch64-elf-* on macOS).
#   scripts/ios16/build.sh [adt|payload|boot|vendor_boot|all]      (default all)
# Run it with tmux:  scripts/bg.sh ios16-build scripts/ios16/build.sh
#
# Inputs:  out/kernel/kernel.macho (scripts/ios16/fetch-kernel.sh)
#          external/slop/research/ipsw-x/d22ap.adt (scripts/ios16/fetch-d22ap-adt.sh)
#          out/mu/SILICIUM_UEFI-DEBUG.fd (scripts/uefi/build.sh)
#          config/negroni-ne2211.toml
# Outputs: out/ios16/negroni.adt, esp.img, cmdline.txt, boot_a.img, vendor_boot_a.img, SHA256SUMS
set -eu
. "$(dirname "$0")/../lib/env.sh"
STEP=${1:-all}
C="python3 $REPO/scripts/lib/conf.py"
# Variants: IOS16_OUT=out/ios16-debug BOOTARGS_DROP="negronifb_noconsole=" BOOTARGS_ADD="negronifb_noconsole=0"
O=${IOS16_OUT:-$OUT/ios16}
mkdir -p "$O"
DTB=$REPO/$($C bootimg.dtb)
FD=$OUT/mu/SILICIUM_UEFI-DEBUG.fd

adt() {
  # shellcheck disable=SC2046
  python3 "$REPO/$($C adt.tool)" "$O/negroni.adt" $($C adt.args)
  # Camera nodes (/arm-io/isp camera-rear, /product/camera; userland/camera/README.md): on by default only when
  # a root got the built NegroniCamera.driver (stamp out/camera/root-has-camera from scripts/camera/root-add-camera.sh,
  # same sha256), so the Camera icon never comes without the capture plug-in. ADT_CAM=1/0 overrides.
  cam=$OUT/camera/ios/NegroniCamera.driver/NegroniCamera
  if [ -z "${ADT_CAM:-}" ] && [ -f "$cam" ]; then
    if [ -f "$OUT/camera/root-has-camera" ] && [ "$(cut -d' ' -f1 "$OUT/camera/root-has-camera")" = "$(shasum -a 256 "$cam" | cut -d' ' -f1)" ]; then
      ADT_CAM=1
    else
      echo "adt: WARNING: NegroniCamera.driver is built but no root has it (out/camera/root-has-camera missing or older):" >&2
      echo "     no camera ADT nodes. Build the root with CAMERA=1 first, or set ADT_CAM=1 by hand." >&2
    fi
  fi
  ADT_CAM=${ADT_CAM:-0} python3 "$REPO/scripts/ios16/adt-extra.py" "$O/negroni.adt"
}

payload() {
  [ -f "$OUT/kernel/kernel.macho" ] || { echo "missing out/kernel/kernel.macho (scripts/ios16/fetch-kernel.sh)" >&2; exit 1; }
  args=""
  for a in $($C payload.kernel_args); do
    keep=1
    for d in ${BOOTARGS_DROP:-}; do case "$a" in "$d"*) keep=0 ;; esac; done
    [ $keep = 1 ] && args="$args $a"
  done
  args="${args# } ${BOOTARGS_ADD:-}"; args="${args% }"
  # Owner rule 2026-10-27 (keep USB reachable): every image except the safe boot_a reboots by itself after 60 s
  # without a USB host once configured (patch 0371), so a test that drops USB falls back to boot_a without buttons.
  # LOST_REBOOT=0 turns it off; LOST_REBOOT=S sets another period.
  case "$O" in */ios16-safe) ;; *)
    case " $args " in *" negroniusb_lost_reboot="*) ;; *)
      [ "${LOST_REBOOT:-60}" = 0 ] || args="$args negroniusb_lost_reboot=${LOST_REBOOT:-60}" ;; esac
    # Patch 0375: also reboot after 90 s without a bulk OUT frame from the host (or with a stuck IN transfer) once the
    # host sent data: the gadget can enumerate while its data path is dead. The host must send something at least every
    # 90 s: scripts/debug/usblog.sh sends a broadcast every 10 s (USBLOG_KEEPALIVE). IDLE_REBOOT=0 turns it off.
    case " $args " in *" negroniusb_idle_reboot="*) ;; *)
      [ "${IDLE_REBOOT:-90}" = 0 ] || args="$args negroniusb_idle_reboot=${IDLE_REBOOT:-90}" ;; esac ;; esac
  printf '%s\n' "$args" > "$O/cmdline.txt"
  # iOS 16 userland reads kern.bootargs into 608 bytes (patch 0378 truncates there): the keys it needs must end
  # before byte 607
  for k in wdt_test= wdt= launchd_unsecure_cache= unentitled_ios_sim_launch= ignition_level= rd= -noprogress negronimetal= negronigl_sw=; do
    a=" $args"; pre=${a%%" $k"*}; [ "$pre" = "$a" ] && continue
    rest=${a#"$pre "}; tok=${rest%% *}
    [ $(( ${#pre} + ${#tok} )) -le 607 ] || { echo "boot-arg $tok ends after byte 607: userland cannot see it (move it to the front)" >&2; exit 1; }
  done
  # DarwinBoot passes at most 1023 bytes; kernels before patch 0363 read memSizeActual from inside a command line
  # longer than 620 bytes (docs/notes.md section 35)
  n=$(printf '%s' "$args" | wc -c | tr -d ' ')
  [ "$n" -lt 1024 ] || { echo "boot-args are $n bytes; DarwinBoot passes at most 1023" >&2; exit 1; }
  "$REPO/scripts/lib/native-env.sh" python3 "$REPO/$($C payload.tool)" "$(cd "$OUT/kernel" && pwd -P)/$(readlink "$OUT/kernel/kernel.macho")" \
    "$O/negroni.adt" "$O/esp.img" --cmdline "$args" \
    --size-mib "$($C payload.size_mib)" --timeout "$($C payload.timeout)"
}

boot() {
  [ -f "$FD" ] || { echo "missing $FD (scripts/uefi/build.sh)" >&2; exit 1; }
  [ -f "$O/esp.img" ] || { echo "missing $O/esp.img (payload step)" >&2; exit 1; }
  # Shim (BOARD=negroni) as the kernel. Ramdisk = Mu FD padded to 1 MiB, then the payload FAT
  # (NegroniBootMemoryDxe finds it at that boundary). Same layout as slop uefi/negroni/shim-mu.sh.
  "$REPO/scripts/lib/native-env.sh" sh -c "
    set -e
    BOARD=negroni DTB='$DTB' '$EXT/slop/shim/build.sh' '$FD' > '$O/shim-build.log'
    rd=\$(mktemp); cp '$FD' \"\$rd\"
    fvlen=\$(wc -c < '$FD' | tr -d ' '); truncate -s \$(( (fvlen + 0xfffff) & ~0xfffff )) \"\$rd\"
    cat '$O/esp.img' >> \"\$rd\"
    mkbootimg --kernel '$EXT/slop/shim/out/Image' --ramdisk \"\$rd\" --header_version $($C bootimg.header_version) \
      --pagesize $($C bootimg.pagesize) --os_version $($C bootimg.os_version) \
      --os_patch_level $($C bootimg.os_patch_level) --cmdline '$($C bootimg.cmdline)' -o '$O/boot_a.img'
    rm -f \"\$rd\""
}

vendor_boot() {
  # Header v4 vendor_boot with only the mainline DTB. Base/offsets/pagesize from the stock image.
  "$REPO/scripts/lib/native-env.sh" sh -c "
    set -e
    t=\$(mktemp -d)
    unpack_bootimg --boot_img '$BACKUP/images/vendor_boot.img' --out \"\$t\" --format mkbootimg > \"\$t/args\"
    echo 'stock vendor_boot args:'; cat \"\$t/args\"; echo
    : > \"\$t/empty\"
    eval \"set -- \$(cat \"\$t/args\")\"
    keep=''
    while [ \$# -gt 0 ]; do
      case \"\$1\" in
        --header_version|--pagesize|--base|--kernel_offset|--ramdisk_offset|--tags_offset|--dtb_offset|--vendor_cmdline|--board)
          keep=\"\$keep \$1 '\$2'\"; shift 2 ;;
        *) shift ;;
      esac
    done
    eval \"mkbootimg \$keep --dtb '$DTB' --vendor_ramdisk \\\"\$t/empty\\\" --vendor_boot '$O/vendor_boot_a.img'\"
    rm -rf \"\$t\""
}

case "$STEP" in
adt) adt ;; payload) payload ;; boot) boot ;; vendor_boot) vendor_boot ;;
all) adt; payload; vendor_boot; boot ;;
*) echo "unknown step $STEP" >&2; exit 1 ;;
esac
(cd "$O" && for f in *.img *.adt; do [ -f "$f" ] && shasum -a 256 "$f"; done > SHA256SUMS; cat SHA256SUMS)
