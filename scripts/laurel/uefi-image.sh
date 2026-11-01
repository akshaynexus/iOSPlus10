#!/bin/bash
# Build the Mi A3 (laurel_sprout) UEFI boot image: ABL -> Mu BootShim + Mu-Silicium UEFI (laurel_sproutPkg) ->
# UniXNU boot manager -> DarwinBoot -> our XNU (TOPAZ_4K, 8 cores) -> iOS root on userdata.
#   scripts/laurel/uefi-image.sh [CMDLINE]
#   MU_ONLY=1   boot image with Mu UEFI alone (empty ramdisk): Mu's boot menu/front page, no XNU (step 1 of the plan)
#   KERNEL=path (default out/laurel-kernel/out/kernel.development.sweet.4k)   FD=path (default out/laurel/mu/SILICIUM_UEFI-DEBUG.fd)
#     The default kernel must have its stamp and match the patches in the repo (build-stamp.py kernel-check), else no image. A KERNEL= by hand
#     needs only its own stamp to be right: an older kernel on purpose (docs/laurel_sprout/build-honest.md).
#   DRAM=BASE:SIZE or auto (default): the DarwinBoot window from the FD's Mu memory map (mkadt.py --dram auto):
#     Mu 0101 ("Kernel RAM" 0xE1000000 + 0xDF000000) or the late layout (MU_RAM_LAYOUT=late) gives 3264 MiB at
#     0xE1004000 (kernel patch 2100); an older FD (Kernel RAM 0x81000000 + 0x3F000000) 768 MiB at 0x81004000
#   CPUS=N (XNU cpus= boot-arg, default 8)   SIZE_MIB=48 (payload FAT)
# Output: out/laurel/uefi/laurel-uefi-boot.img (+ laurel.adt, payload.img, kernel.gz, cmdline.txt); MU_ONLY=1: laurel-mu-only-boot.img
# Flash: scripts/bg.sh laurel-flash sh -c 'BOOT=reboot scripts/laurel/flash-boot.sh out/laurel/uefi/laurel-uefi-boot.img'
#
# Layout (docs/laurel_sprout/uefi-boot.md): boot image v2 with the stock header values and the stock DTB (as
# scripts/laurel/shim.sh; the Mi A3 ABL refuses `fastboot boot`, so it goes to boot_b). kernel = gzip(BootShim.bin +
# SILICIUM_UEFI.fd) (Mu's own recipe, Resources/Configs/laurel_sprout.toml: FD at 0x5FC00000, kernel header), ramdisk =
# the UniXNU payload FAT (scripts/laurel/mkdarwinboot.py); ABL writes its address into the live FDT (/chosen
# linux,initrd-start/end), NegroniBootMemoryDxe publishes it as a block device, UniXNU reads \EFI\UniXNU\unixnu.toml.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
W=${UEFI_W:-$OUT/laurel/uefi}    # own folder: scripts/laurel/ios26-image.sh
STOCK=${STOCK_BOOT:-$HOME/laurel-backup/stock/images/boot.img}
MU=${MU_DIR:-$OUT/laurel/mu}
FD=${FD:-$MU/SILICIUM_UEFI-DEBUG.fd}
SHIM=${SHIM:-$MU/BootShim.bin}
KERNEL_BY_HAND=${KERNEL:-}
KERNEL=${KERNEL:-$OUT/laurel-kernel/out/kernel.development.sweet.4k}
BS=$REPO/scripts/laurel/build-stamp.py
DRAM=${DRAM:-auto}
CPUS=${CPUS:-8}
SIZE_MIB=${SIZE_MIB:-48}
# boot-args: the shim set (scripts/laurel/shim.sh) without the ones the shim path needed; DarwinBoot copies them unchanged
CMDLINE=${1:-"debug=0xc serial=3 cpus=$CPUS keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 launchd_disable_all_timeouts=1 wdt=-1 sweetfb_hz=60 ipa=0"}
# ipa=0: phone test 2026-11-01 17:01: the IPA handshake crashed the modem (GSI channel 1 assert), which stops Wi-Fi too. 2782 adds the
# missing channel allocation, but no self-check can see a modem firmware assert: ipa=0 stays until a phone boot shows the evidence in
# docs/laurel_sprout/cellular.md section 8. That test: IPA_TEST=1 scripts/laurel/uefi-image.sh, then a boot_b flash (this ABL refuses `fastboot boot`: line above and uefi-boot.md).
[ "${IPA_TEST:-0}" != 1 ] || CMDLINE=${CMDLINE% ipa=0}
# launchd_disable_all_timeouts=1: launchd kills an extension that has not checked in after 5 s (ExtensionWatchdogTimeout, a 5 in its data,
# no plist key changes it on this port); here device open + first pipelines take longer at 300 MHz (boot 2026-11-01 18:45: AegirPoster 10
# starts, none finished). Side effects [V launchd 20H392]: SIGTERM -> SIGKILL wait of a service 600 s instead of 3 s, no shutdown limit.
# LAUNCHD_TIMEOUTS=1 builds without it. docs/laurel_sprout/metal.md section 11.
[ "${LAUNCHD_TIMEOUTS:-0}" != 1 ] || CMDLINE=${CMDLINE/ launchd_disable_all_timeouts=1/}
# EXTRA_ARGS: added to the boot-args, e.g. a kill switch for one test (EXTRA_ARGS=gpu_smmu=0)
[ -z "${EXTRA_ARGS:-}" ] || CMDLINE="$CMDLINE $EXTRA_ARGS"

for f in "$FD" "$SHIM" "$STOCK"; do [ -e "$f" ] || { echo "uefi-image: missing $f (scripts/laurel/mu-build.sh)" >&2; exit 1; }; done
for t in mkbootimg unpack_bootimg gzip python3 uv; do command -v $t >/dev/null || { echo "uefi-image: missing $t" >&2; exit 1; }; done
mkdir -p "$W"
file_sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
# pyfatfs for the payload FAT (same venv as scripts/setup/native-tools.sh)
if [ ! -x "$OUT/venv/bin/python3" ]; then uv venv -q "$OUT/venv"; VIRTUAL_ENV=$OUT/venv uv pip install -q pyfatfs pyyaml fdt "setuptools<81"; fi
"$OUT/venv/bin/python3" -c 'import pyfatfs' 2>/dev/null || VIRTUAL_ENV=$OUT/venv uv pip install -q pyfatfs

# 1. kernel blob = BootShim + FD, gzip (ABL inflates it to the kernel address; BootShim moves the FD to 0x5FC00000)
fdlen=$(wc -c < "$FD" | tr -d ' ')
[ "$fdlen" -le $((0x300000)) ] || { echo "uefi-image: FD is $fdlen bytes, the laurel_sprout FD region is 0x300000" >&2; exit 1; }
cat "$SHIM" "$FD" > "$W/kernel.bin"
gzip -9 -n -c "$W/kernel.bin" > "$W/kernel.gz"

# 2. ramdisk: UniXNU payload FAT (kernel + ADT + unixnu.toml), or an empty cpio for Mu alone
if [ "${MU_ONLY:-0}" = 1 ]; then
  rd=$W/ramdisk-empty.cpio.gz
  (d=$(mktemp -d); cd "$d" && find . | cpio -o -H newc --quiet | gzip -9 -n > "$rd"; rm -rf "$d")
  # NegroniBootMemoryDxe publishes the ramdisk as a 512-byte-sector block device and refuses an odd size
  # ("initrd ... is not a whole number of sectors" on the 2026-11-01 boot, 94 bytes): pad to one page.
  truncate -s 4096 "$rd"
  IMG=$W/laurel-mu-only-boot.img
else
  [ -f "$KERNEL" ] || { echo "uefi-image: missing kernel $KERNEL (scripts/laurel/kernel-linux.sh)" >&2; exit 1; }
  # no boot image from a kernel that is not proven: kernel-linux.sh stamps only what passed its checks
  python3 -I "$BS" kernel-check "$KERNEL" ${KERNEL_BY_HAND:+--no-repo} || { echo "uefi-image: FAILED: kernel not good: no boot image" >&2; rm -f "$W/laurel-uefi-boot.img.stamp"; exit 1; }
  STAMP_LINE=$(python3 -I "$BS" image-line "$KERNEL" "$FD")
  # laurel 2950: the iOS root is the partition iosroot (docs/laurel_sprout/dual-boot.md). A kernel without this text takes userdata as its root and writes its console log into Android's data.
  ldb_marker=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
  rm -f "$W/laurel-uefi-boot.img.dualboot"
  DUALBOOT=
  if [ -e "$REPO/config/laurel-android-data" ]; then
    DUALBOOT=1
    # KERNEL= by hand (--no-repo) skips the series check, ios26-image.sh always sets KERNEL: this check is for all of them.
    [ -n "$ldb_marker" ] && LC_ALL=C grep -aqF "$ldb_marker" "$KERNEL" || { echo "uefi-image: FAILED: kernel $KERNEL has no patch 2950 of this version (text $ldb_marker): no boot image" >&2; exit 1; }
    # S1: ABL gives TrustZone the OS version and patch level of the header it loaded: the same as Lineage's, read from the backup. docs/laurel_sprout/dual-boot.md, keys.
    . "$REPO/scripts/lib/laurel-layout.sh"
    LINEAGE_BOOT=${LINEAGE_BOOT:-$(laurel_backup_dir 'lineage-*')/boot.img}
    [ -f "$LINEAGE_BOOT" ] || { echo "uefi-image: FAILED: no Lineage boot image ($LINEAGE_BOOT): its header is an input of this image" >&2; exit 1; }
    os_raw=$(boot_os_raw "$LINEAGE_BOOT")
    OS_VERSION=$(boot_os_version "$os_raw"); OS_PATCH=$(boot_os_patch "$os_raw")
    # dual-boot.sh image: the read-only first boot. No write command can leave the kernel, and the root mounts read-only.
    [ "${LAUREL_READONLY:-0}" != 1 ] || CMDLINE=${CMDLINE/ ufsrw=1 rootrw=1/}
    case " $CMDLINE " in *" ufsrw=1 "*|*" rootrw=1 "*) IMG_MODE=rw ;; *) IMG_MODE=ro ;; esac
    [ "${LAUREL_READONLY:-0}" != 1 ] || [ "$IMG_MODE" = ro ] || { echo "uefi-image: FAILED: LAUREL_READONLY=1, and the command line can write: $CMDLINE" >&2; exit 1; }
  fi
  python3 "$REPO/scripts/laurel/mkadt.py" "$W/laurel.adt" --cores 8 --boot gold --dram "$DRAM" --mu-fd "$FD" --darwinboot --build-stamp "$STAMP_LINE" ${MKADT_EXTRA:-}   # laurel 2016: Gold 0x100 is the boot CPU after the PSCI hand-off
  "$OUT/venv/bin/python3" "$REPO/scripts/laurel/mkdarwinboot.py" "$KERNEL" "$W/laurel.adt" "$W/payload.img" \
    --cmdline "$CMDLINE" --size-mib "$SIZE_MIB" --timeout 3
  printf '%s\n' "$CMDLINE" > "$W/cmdline.txt"
  rd=$W/payload.img
  IMG=$W/laurel-uefi-boot.img
fi

# 3. stock DTB and header values (header v2, as the stock image and scripts/laurel/shim.sh)
rm -rf "$W/stockboot"
unpack_bootimg --boot_img "$STOCK" --out "$W/stockboot" > "$W/stockboot.txt"
[ -s "$W/stockboot/dtb" ] || { echo "uefi-image: no DTB in $STOCK" >&2; exit 1; }
mkbootimg --header_version 2 --kernel "$W/kernel.gz" --ramdisk "$rd" --dtb "$W/stockboot/dtb" \
  --pagesize 4096 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --os_version "${OS_VERSION:-11.0.0}" --os_patch_level "${OS_PATCH:-2022-08}" --cmdline "console=null" \
  -o "$IMG"
ls -l "$IMG" "$W/kernel.gz" "$rd"
if [ "${MU_ONLY:-0}" != 1 ]; then
  python3 -I "$BS" image-seal "$IMG" "$STAMP_LINE" "$KERNEL" "$FD" "$CMDLINE"
  # the sidecar android-guard.sh boot-image asks for
  [ -z "${DUALBOOT:-}" ] || printf 'image %s\nmode %s\nmarker %s\nos %s %s\n' "$(file_sha "$IMG")" "$IMG_MODE" "$ldb_marker" "$OS_VERSION" "$OS_PATCH" > "$IMG.dualboot"
  echo "uefi-image: boot line: LAUREL BUILD: image $STAMP_LINE"
fi
echo "uefi-image: $IMG (FD $fdlen bytes$([ "${MU_ONLY:-0}" = 1 ] && echo ', Mu alone' || echo ", kernel $(basename "$KERNEL"), cpus=$CPUS, dram $DRAM, boot CPU Gold 0x100 after the PSCI hand-off (patch 2016)"))"
