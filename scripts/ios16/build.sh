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
  printf '%s\n' "$args" > "$O/cmdline.txt"
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
