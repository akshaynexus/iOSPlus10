# Mi A3 (laurel_sprout): UEFI boot path (Mu-Silicium -> UniXNU -> DarwinBoot -> XNU)

Owner decision 2026-11-01: boot iOS on the Mi A3 the way the negroni port boots the OnePlus 10 Pro, with a UEFI stage
between the stock ABL and XNU. It replaces the topaz shim path (ABL -> shim -> XNU, `scripts/laurel/shim.sh`), which
hung after `mbinit: done` and never brought USB up. UEFI brings up GIC, timer, USB device mode, display and UFS with
Qualcomm's own drivers before XNU starts.

Labels: [V] measured or read in source, [I] inference, [U] unknown.

## Chain

```
stock ABL (boot_b, header v2, stock DTB)
  -> kernel field = gzip(Mu BootShim.bin + SILICIUM_UEFI.fd)       ABL inflates it; BootShim moves the FD to 0x5FC00000
  -> Mu-Silicium UEFI, laurel_sproutPkg (Silicon/Qualcomm/NicobarPkg)   GIC, timer, UFS, USB, SimpleFb 720x1560
     NegroniBootMemoryDxe: the ABL ramdisk (/chosen linux,initrd-start/end of the live FDT) = our payload FAT,
     published as a read-only block device; PartitionDxe + Fat mount it
  -> UniXNU boot manager (UniXNUDxe makes it Boot#### "unixnu:firmware", first in BootOrder): reads
     \EFI\UniXNU\unixnu.toml from the payload, 3 s menu, entry "iOS 16 (laurel XNU, TOPAZ_4K)"
  -> DarwinBoot: Payloads\kernel.macho + kernel.macho.adt, window of darwinboot-memory-size (768 MiB) in the first
     conventional-memory run that fits = Mu "Kernel RAM" 0x81000000 -> window 0x81004000, boot_args (Darwin 23
     layout, 1024-byte command line), ExitBootServices, MMU off, green bar, jump to the kernel entry in EL1
  -> XNU xnu-8796.141.3 TOPAZ_4K (4 KiB pages, 8 cores), patches external/ios-topaz + patches/laurel/xnu/2000-2012
  -> iOS 16.7.16 root on userdata (rd=ufsroot0, already flashed; never write userdata again)
```

## Build and flash

| Step | Command | Output |
| --- | --- | --- |
| Mu UEFI + UniXNU + DarwinBoot | `make laurel-mu` (`scripts/laurel/mu-build.sh`, tmux `laurel-mu`) | `out/laurel/mu/SILICIUM_UEFI-DEBUG.fd` (3 MiB), `BootShim.bin` |
| kernel | `make laurel-kernel` (`scripts/laurel/kernel-linux.sh`, PAGES=4k) | `out/laurel-kernel/out/kernel.development.sweet.4k` |
| boot image | `make laurel-uefi-image` (`scripts/laurel/uefi-image.sh`) | `out/laurel/uefi/laurel-uefi-boot.img` (+ `laurel.adt`, `payload.img`, `kernel.gz`, `cmdline.txt`) |
| Mu alone (step 1) | `make laurel-uefi-image MU_ONLY=1` | same image name, empty ramdisk: Mu's boot menu only |
| flash boot_b | `make laurel-flash-uefi` (`BOOT=reboot scripts/laurel/flash-boot.sh out/laurel/uefi/laurel-uefi-boot.img`) | phone resets into the image |
| restore Android | `BOOTIMG=~/laurel-backup/stock/images/boot.img scripts/laurel/flash-boot.sh` | stock boot_b |

Host: Linux x86_64 (CachyOS), native stuart (no container): clang 23 + lld-link + llvm-lib (CLANGPDB), `uv` venv
`out/venv-mu` with Mu's `pip-requirements.txt`, `CLANGPDB_AARCH64_PREFIX=llvm-`. [V] First build 2026-11-01 02:06:
52 images, 11 s of EDK2 build time on 20 cores; the whole script 35 s once the submodules are cloned.

## Base and binaries [V]

- Base: `external/Mu-Silicium-negroni` (akshaynexus fork of Project-Silicium/Mu-Silicium, pinned 4b524aba). It has
  the UniXNU/DarwinBoot pieces negroni uses and upstream has not: SEC publishes the ABL entry argument (x0 = live FDT)
  in a HOB (`gSiliciumEntryArgHobGuid`), `negroniPkg/Drivers/NegroniBootMemoryDxe` (ramdisk block device + DT memory
  banks), Mu_Basecore fork (timer PCD fallback, boot menu, USB TPL) and Silicium-ACPI fork. Its
  `Platforms/Xiaomi/laurel_sproutPkg` and `Resources/Configs/laurel_sprout.toml` are byte-identical to upstream
  Mu-Silicium 4bd8ae83 (`diff -r`, 2026-11-01), so nothing is lost against upstream.
- Our changes: `patches/laurel/mu/0001-laurel-unixnu-darwinboot.patch` (dsc/fdf/DXE.inc: UniXNU app + UniXNUDxe +
  DarwinBoot + NegroniBootMemoryDxe; MemoryMapLib "Kernel RAM"; DeviceBuild.py PackagesPath; PcdDebugPropertyMask
  0x0F). `mu-build.sh` resets the touched files and applies it (re-runnable). `scripts/uefi/setup-mu.sh` (shared with
  negroni) now skips a fork patch that already reverse-applies: the fork's Mu_Basecore fa7fe5f holds
  `mu_basecore-negroni.patch`, so `patches/apply.sh` failed on it.
- Qualcomm DXEs: the fork's `Binaries` submodule (Project-Silicium/Device-Binaries a1501e0c) has `laurel_sprout/`
  (46 drivers; ButtonsDxe power key -> Enter, ClockDxe keeps the display on; README there). No stock-ROM extraction
  was needed (negroni needed it because no Device-Binaries existed for the NE2211).
- Mu config (`Resources/Configs/laurel_sprout.toml`): FD base 0x5FC00000, size 0x300000, BootShim with kernel header,
  gzip, header v1. We build the boot image ourselves with the stock v2 header values and the stock DTB
  (`scripts/laurel/uefi-image.sh`), because that is what the Mi A3 ABL booted for the shim path; Mu's own
  `Mu-laurel_sprout.img` is kept in `out/laurel/mu/` for reference only.
- Memory map (`laurel_sproutPkg/Library/MemoryMapLib`): upstream has only a 60 MiB DXE heap (0x62100000) as
  conventional memory, no room for a kernel window. Added "Kernel RAM" 0x81000000 + 0x3F000000 (to 0xC0000000):
  above the fixed carve-outs (highest ends 0x62100000), below 4 GiB, the 1 GiB the shim boots ran XNU in
  (`mkadt --dram 0x80000000:0x40000000`). The real DDR banks are still [U] (ABL writes them into the live FDT;
  NegroniBootMemoryDxe reads them and adds up to 1 GiB of their holes below 4 GiB as system memory too, with
  `NEGRONIMEM:` lines in the UEFI log).

## Window placement [V code, I numbers]

DarwinBoot (`external/UniXNU/drivers/DarwinBoot`, 616a8fa): window = ADT `/chosen/darwinboot-memory-size` (>= 256 MiB,
2 MiB multiple), allocated with `AllocateAddress` at `ALIGN(run start, 2 MiB) + (kernel base VA & 0x1FFFFF)` in the
first conventional-memory run that fits (map order). Kernel base VA = lowest non-empty segment = `__TEXT`
0xFFFFFFF007004000 (zero-size `__PRELINK_*` segments are skipped). With "Kernel RAM" at 0x81000000 the window is
0x81004000..0xB1004000 and `__TEXT` lands at PA 0x81004000: the same address the shim path used (its virt_base rounding
gives a 32 MiB-aligned VA-PA delta, 0x7A000000). A region at 0x80000000 would give 0x80004000 (delta 0x79000000, only
2 MiB-aligned); negroni holds back 16 MiB for the same reason (`patches/mu/0002`, "0x841000000"). The runs before it
(DXE heap 60 MiB, DT holes below 0x80000000 at most 419 MiB) cannot take a 768 MiB window, so the placement is
deterministic. boot_args: PhysicalBase = window, MemorySize = MemorySizeActual = 768 MiB (XNU gets exactly the window),
VirtualBase = kernel base VA, DeviceTree inside the window after the kernel, CommandLine 1024 bytes.

ADT (`scripts/laurel/mkadt.py --boot silver --dram 0x81000000:0x30000000 --darwinboot`): `dram-base`/`dram-size` =
the window, `darwinboot-memory-size` = dram-size, `firmware-version` "laurel-uefi". The kernel reads none of
`dram-base` (grep of all topaz and laurel patches); mkpayload (shim path) was its only user.

## Boot CPU: Silver 0x0, no hand-off [decision 2026-11-01]

ABL, BootShim, UEFI and DarwinBoot run on Kryo 260 Silver CPU0 (MPIDR 0x0, Cortex-A53 class, no 16K granule). The
topaz shim woke Gold 0x100 with PSCI CPU_ON and parked Silver because its 16K kernel cannot run on Silver, and topaz
patch 0082 panics unless the boot CPU is 0x100. Our kernel is TOPAZ_4K (4 KiB pages, both clusters, topaz 0140/0141),
so it runs on Silver. Choice: keep DarwinBoot unchanged and boot on Silver.

- `patches/laurel/xnu/2012-laurel-boot-cpu-silver.patch`: under TOPAZ_4K the boot CPU may be MPIDR 0x0 or 0x100
  (logical CPU 0 either way); line `LAUREL CPU: boot cpu mpidr=0x0 (Silver, UEFI path)`. A 16K build keeps 0082.
- ADT `--boot silver`: Silver 0x0-0x3 first (cpu0 = 0x0 `state = running`, cluster 0, type 'E'), Gold 0x100-0x103
  after (cluster 1, 'P'). XNU takes the boot CPU from `state = running` (`ml_is_boot_cpu`) and the cluster IDs in
  first-seen order, so pset0 is the E cluster: the same as every Apple SoC (cpu0 is an E core). `--boot gold`
  (default) keeps the shim-path order.
- Reasons for Silver over a Gold hand-off in DarwinBoot: no change to DarwinBoot or its PSCI/GIC state (UEFI set up
  GICD and CPU0's redistributor; the kernel wakes the other redistributors itself, `pe_fiq.c GICR_WAKER`), the
  console/USB state belongs to the running core, one less stage where a CPU_ON can fail. Risk [U]: 0141's comment
  calls Gold "boot, pset0"; nothing in the patches hard-codes it, but a Silver boot is untested. Fallback if it fails:
  a DarwinBoot patch that does what the shim did (CPU_ON 0x100 with a trampoline, CPU_OFF on Silver) and
  `--boot gold`.

## Kernel changes for DarwinBoot

- `2011-laurel-boot-line-1024.patch` (= negroni 0363): `BOOT_LINE_LENGTH 1024`. DarwinBoot writes the Darwin 23
  layout (bootFlags 0x470, memSizeActual 0x478); with 608 the kernel read memSizeActual from inside the command line
  (negroni root-mount panic, docs/notes.md section 35). The shim path (608-byte mkpayload header) no longer matches
  this kernel.
- `2012` above. Build: `make laurel-kernel`; [V] 2026-11-01 02:03: 213 patches apply, kernel 28.7 s, 0 LSE/RCpc.

## Payload

`scripts/laurel/mkdarwinboot.py KERNEL ADT OUT.img --cmdline ... [--size-mib 48]` (port of slop's
`negroni-ios/tools/mkdarwinboot.py` to topaz's `mkpayload.py` helpers): FAT32 "LAURELESP" with
`/EFI/UniXNU/unixnu.toml` (timeout 3, entry `path = '\Payloads\kernel.macho'`, `args`), `/Payloads/kernel.macho`
(chained fixups applied to the file; this kernel has none: "0 rebases"), `/Payloads/kernel.macho.adt`. It checks the
boot-args against UniXNU's rule (`[A-Za-z0-9_.-]+` with optional `=[A-Za-z0-9_.,-]+`, <= 1000 bytes). The topaz
boot-args of the shim path are kept: `debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1
sweetfb_hz=30 sweetfb_stayon=1`.

Boot image (v2, stock values: pagesize 4096, base 0, kernel 0x8000, ramdisk 0x1000000, tags 0x100, dtb 0x1f00000,
os 11.0.0 / 2022-08, stock DTB): kernel.gz 1.36 MB, ramdisk = 48 MiB FAT, image 52,862,976 bytes [V]. The Mu-only
image is 2,535,424 bytes.

## What to look for on the phone

1. Mu alone (`MU_ONLY=1` image): the Mu-Silicium screen (Project Silicium logo / front page, Volume Down = boot menu
   per the negroni notes), USB device mode (Mu status for laurel_sprout: works). Photo for the owner.
2. Full image: UniXNU menu (3 s) -> DarwinBoot lines `DARWINBOOT: ARM64 va=0xfffffff007004000 pa=0x81004000 ...`
   on the screen log, green bar at the top, then the kernel console (`LAUREL CPU: boot cpu mpidr=0x0`, `SWEET FB`,
   `LAUREL FB SCANOUT`, `SWEET UFS: host`, `LAUREL USB:`), and on the host the USB Ethernet interface + `op10tool ctl
   ping` (`scripts/laurel/boot-test.sh IMG=out/laurel/uefi/laurel-uefi-boot.img`, usblog listener in tmux `usblog`).
3. `NO WINDOW ... FREE ...` on the screen = DarwinBoot found no 768 MiB run: the memory map differs from this
   document; the FREE lines give the real runs.

## Status

- 2026-11-01 02:10 [V]: everything builds; both images exist. NOT BOOTED: the phone was not on USB. Next: owner puts
  the phone in fastboot, `make laurel-flash-uefi` with the Mu-only image first, photo; then the full image.
