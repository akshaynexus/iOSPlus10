#!/bin/bash
# Build the Mi A3 (laurel_sprout) UEFI boot image: ABL -> Mu BootShim + Mu-Silicium UEFI (laurel_sproutPkg) ->
# UniXNU boot manager -> DarwinBoot -> our XNU (TOPAZ_4K, 8 cores) -> iOS root on userdata.
#   scripts/laurel/uefi-image.sh [CMDLINE]
#   MU_ONLY=1   boot image with Mu UEFI alone (empty ramdisk): Mu's boot menu/front page, no XNU (step 1 of the plan)
#   KERNEL=path (default out/laurel-kernel/out/kernel.development.sweet.4k)   FD=path (default out/laurel/mu/SILICIUM_UEFI-DEBUG.fd)
#   DRAM=BASE:SIZE (default 0x81000000:0x30000000 = the DarwinBoot window: Mu "Kernel RAM" 0x81000000 + 0x3F000000,
#     window at 0x81004000 = the shim path's __TEXT address; patches/laurel/mu/0001)
#   CPUS=N (XNU cpus= boot-arg, default 8)   SIZE_MIB=48 (payload FAT)
# Output: out/laurel/uefi/laurel-uefi-boot.img (+ laurel.adt, payload.img, kernel.gz, cmdline.txt)
# Flash: scripts/bg.sh laurel-flash sh -c 'BOOT=reboot scripts/laurel/flash-boot.sh out/laurel/uefi/laurel-uefi-boot.img'
#
# Layout (docs/laurel_sprout/uefi-boot.md): boot image v2 with the stock header values and the stock DTB (as
# scripts/laurel/shim.sh; the Mi A3 ABL refuses `fastboot boot`, so it goes to boot_b). kernel = gzip(BootShim.bin +
# SILICIUM_UEFI.fd) (Mu's own recipe, Resources/Configs/laurel_sprout.toml: FD at 0x5FC00000, kernel header), ramdisk =
# the UniXNU payload FAT (scripts/laurel/mkdarwinboot.py); ABL writes its address into the live FDT (/chosen
# linux,initrd-start/end), NegroniBootMemoryDxe publishes it as a block device, UniXNU reads \EFI\UniXNU\unixnu.toml.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
W=$OUT/laurel/uefi
STOCK=${STOCK_BOOT:-$HOME/laurel-backup/stock/images/boot.img}
MU=$OUT/laurel/mu
FD=${FD:-$MU/SILICIUM_UEFI-DEBUG.fd}
SHIM=${SHIM:-$MU/BootShim.bin}
KERNEL=${KERNEL:-$OUT/laurel-kernel/out/kernel.development.sweet.4k}
DRAM=${DRAM:-0x81000000:0x30000000}
CPUS=${CPUS:-8}
SIZE_MIB=${SIZE_MIB:-48}
# boot-args: the shim set (scripts/laurel/shim.sh) without the ones the shim path needed; DarwinBoot copies them unchanged
CMDLINE=${1:-"debug=0xc serial=3 cpus=$CPUS keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=30 sweetfb_stayon=1"}

for f in "$FD" "$SHIM" "$STOCK"; do [ -e "$f" ] || { echo "uefi-image: missing $f (scripts/laurel/mu-build.sh)" >&2; exit 1; }; done
for t in mkbootimg unpack_bootimg gzip python3 uv; do command -v $t >/dev/null || { echo "uefi-image: missing $t" >&2; exit 1; }; done
mkdir -p "$W"
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
  printf '%s\n' "(Mu alone, no payload)" > "$W/cmdline.txt"
else
  [ -f "$KERNEL" ] || { echo "uefi-image: missing kernel $KERNEL (scripts/laurel/kernel-linux.sh)" >&2; exit 1; }
  python3 "$REPO/scripts/laurel/mkadt.py" "$W/laurel.adt" --cores 8 --boot silver --dram "$DRAM" --darwinboot
  "$OUT/venv/bin/python3" "$REPO/scripts/laurel/mkdarwinboot.py" "$KERNEL" "$W/laurel.adt" "$W/payload.img" \
    --cmdline "$CMDLINE" --size-mib "$SIZE_MIB" --timeout 3
  printf '%s\n' "$CMDLINE" > "$W/cmdline.txt"
  rd=$W/payload.img
fi

# 3. stock DTB and header values (header v2, as the stock image and scripts/laurel/shim.sh)
rm -rf "$W/stockboot"
unpack_bootimg --boot_img "$STOCK" --out "$W/stockboot" > "$W/stockboot.txt"
[ -s "$W/stockboot/dtb" ] || { echo "uefi-image: no DTB in $STOCK" >&2; exit 1; }
mkbootimg --header_version 2 --kernel "$W/kernel.gz" --ramdisk "$rd" --dtb "$W/stockboot/dtb" \
  --pagesize 4096 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --os_version 11.0.0 --os_patch_level 2022-08 --cmdline "console=null" \
  -o "$W/laurel-uefi-boot.img"
ls -l "$W/laurel-uefi-boot.img" "$W/kernel.gz" "$rd"
echo "uefi-image: $W/laurel-uefi-boot.img (FD $fdlen bytes$([ "${MU_ONLY:-0}" = 1 ] && echo ', Mu alone' || echo ", kernel $(basename "$KERNEL"), cpus=$CPUS, dram $DRAM, boot CPU Silver 0x0"))"
