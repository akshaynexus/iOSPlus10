#!/bin/bash
# Build the Mi A3 (laurel_sprout) boot image: topaz shim + XNU payload, boot image v2 (RAM only, fastboot boot).
#   scripts/laurel/shim.sh [CMDLINE]
#   CORES=8 (default, PAGES=4k kernel) | CORES=4 (PAGES=16k kernel)   CPUS=N: XNU cpus= boot-arg (default = CORES)
#   KERNEL=path (default out/laurel-kernel/out/kernel.development.sweet.<4k|16k>)  DRAM=BASE:SIZE (mkadt --dram)
# Output: out/laurel/laurel-boot.img (+ payload.bin, laurel.adt). Boot it with: fastboot boot out/laurel/laurel-boot.img
#
# Differences from topaz shim/build.sh:
#   * clang + lld (no aarch64-linux-gnu-gcc needed), llvm-readelf/nm/objcopy;
#   * panel 720x1560 (console.h FB_W/FB_H; FB_STRIDE follows) at the same splash 0x5c000000;
#   * boot image v2 with the stock DTB and the stock header values (unpack_bootimg of the stock boot.img in
#     ~/laurel-backup, scripts/backup/fetch-laurel-rom.sh): the Mi A3 ABL takes v2 (stock is v2; topaz ABL needs v4).
#     The payload is appended to the Image after _end as on topaz (loader.c finds it there first).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
TOPAZ=$EXT/ios-topaz
STOCK=${STOCK_BOOT:-$HOME/laurel-backup/stock/images/boot.img}
W=$OUT/laurel
S=$W/shim
CORES=${CORES:-8}
CPUS=${CPUS:-$CORES}
case "$CORES" in 8) PAGES=4k ;; 4) PAGES=16k ;; *) echo "shim: CORES must be 8 or 4" >&2; exit 1 ;; esac
KERNEL=${KERNEL:-$OUT/laurel-kernel/out/kernel.development.sweet.$PAGES}
DRAM=${DRAM:-0x80000000:0x40000000}
# boot-args: topaz README set, root on userdata (rd=ufsroot0), kernel console kept on screen (no sweetfb_noconsole)
CMDLINE=${1:-"debug=0xc serial=3 cpus=$CPUS keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=30"}

for f in "$KERNEL" "$STOCK" "$TOPAZ/shim/shim.c"; do [ -e "$f" ] || { echo "shim: missing $f" >&2; exit 1; }; done
for t in clang ld.lld llvm-objcopy llvm-readelf llvm-nm mkbootimg unpack_bootimg cpio python3; do
  command -v $t >/dev/null || { echo "shim: missing $t" >&2; exit 1; }
done

rm -rf "$S"; mkdir -p "$S/out"
cp "$TOPAZ"/shim/*.c "$TOPAZ"/shim/*.h "$TOPAZ"/shim/*.S "$TOPAZ"/shim/shim.ld "$S/"
cp "$REPO/scripts/laurel/shim/libc.c" "$S/"   # strcmp/memcpy/memset: clang emits calls where GCC inlines
sed -i -e 's/^#define FB_W\t\t1080$/#define FB_W\t\t720/' -e 's/^#define FB_H\t\t2400$/#define FB_H\t\t1560/' "$S/console.h"
grep -q $'^#define FB_W\t\t720$' "$S/console.h" && grep -q $'^#define FB_H\t\t1560$' "$S/console.h" ||
  { echo "shim: cannot set the panel size in console.h" >&2; exit 1; }
for p in "$REPO"/patches/laurel/shim/*.patch; do [ -f "$p" ] && (cd "$S" && patch -p1 --quiet < "$p"); done

CC="clang --target=aarch64-none-elf"
# -fno-jump-tables: clang turns small switches into tables of absolute string pointers (ABS64)
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -fno-jump-tables -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra -Wno-unused-command-line-argument"
cd "$S"
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c libc.c; do
  $CC $CFLAGS -c $f -o out/${f%.*}.o &
done
wait
for f in start shim console mmu fdt loader ufs libc; do [ -s out/$f.o ] || { echo "shim: $f did not compile" >&2; exit 1; }; done
# position independent: only start.o (the header's image_size) may hold an absolute address
abs=$(llvm-readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/libc.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "shim: $abs absolute relocations in C objects" >&2; exit 1; }
ld.lld -static -T shim.ld --build-id=none -N out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/libc.o -o out/shim.elf
llvm-objcopy -O binary out/shim.elf out/Image
size=$((16#$(llvm-nm out/shim.elf | awk '$3=="_end"{print $1}')))
truncate -s "$size" out/Image

# ADT + payload (mkpayload takes phys_base/mem_size from the ADT's dram-base/size)
python3 "$REPO/scripts/laurel/mkadt.py" "$W/laurel.adt" --cores "$CORES" --dram "$DRAM"
python3 "$TOPAZ/tools/mkpayload.py" "$KERNEL" "$W/laurel.adt" "$W/payload.bin" --cmdline "$CMDLINE"
truncate -s $(( (size + 0xfff) & ~0xfff )) out/Image
cat "$W/payload.bin" >> out/Image
python3 -c 'import os,struct,sys; f=open(sys.argv[1],"r+b"); f.seek(16); f.write(struct.pack("<Q", os.path.getsize(sys.argv[1])))' out/Image
(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)

# stock DTB and header values
rm -rf "$W/stockboot"
unpack_bootimg --boot_img "$STOCK" --out "$W/stockboot" > "$W/stockboot.txt"
[ -s "$W/stockboot/dtb" ] || { echo "shim: no DTB in $STOCK" >&2; exit 1; }
mkbootimg --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin --dtb "$W/stockboot/dtb" \
  --pagesize 4096 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --os_version 11.0.0 --os_patch_level 2022-08 --cmdline "console=null" \
  -o "$W/laurel-boot.img"
ls -l "$W/laurel-boot.img"
echo "shim: $W/laurel-boot.img ($CORES cores, cpus=$CPUS, kernel $(basename "$KERNEL"), dram $DRAM)"
