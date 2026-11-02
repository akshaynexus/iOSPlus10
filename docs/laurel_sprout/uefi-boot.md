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
  -> DarwinBoot: Payloads\kernel.macho + kernel.macho.adt, window of darwinboot-memory-size (3264 MiB since 2100; was 768) in
     the first conventional-memory run that fits = Mu "Kernel RAM" 0xE1000000 (was 0x81000000) -> window 0xE1004000, boot_args (Darwin 23
     layout, 1024-byte command line), ExitBootServices, MMU off, green bar, jump to the kernel entry in EL1
  -> XNU xnu-8796.141.3 TOPAZ_4K (4 KiB pages, 8 cores), patches external/ios-topaz + patches/laurel/xnu/2000-2012
  -> iOS 16.7.16 root on userdata (rd=ufsroot0, already flashed; never write userdata again)
```

Dual boot: the menu has an entry "Android", 5 s to iOS, `laurelpanic=30`: `boot-menu.md`. `BOOT_MENU=0` builds the old menu.

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

## RAM, memory map, screen surfaces, canvas [2026-11-01 05:15, kernel 2100/2101/2103, Mu 0101-0103 + late/0101; NOT BOOTED]

Problem [V boot 03:59, live log 04:04]: XNU had only the 768 MiB window. backboardd's 720x1560 BGRA surface (4.8 MB)
needs one physically contiguous run: `vm_page_find_contiguous(num=1172,low=0): found 0 pages ... scanned 188404 pages`
(= all 736 MiB), then `SWEET SURF: backboardd create id 0 720x1560 ... -> 0xe00002bd` in a loop. No frame was ever swapped.
[V code] Two causes: (1) the window is small and fragmented; (2) on the TOPAZ_4K kernel every surface buffer is 16 KiB aligned
(`SWEET_UPAGE`, user tasks have 16 KiB pages), and IOBufferMemoryDescriptor makes any buffer with alignment > page_size
physically contiguous (`IOBufferMemoryDescriptor.cpp`: `if (alignment > page_size) options |= kIOMemoryPhysicallyContiguous`).
So even surfaces that no hardware reads needed a contiguous run (the scanout attempt with a mask below 4 GiB and the generic
attempt each gave two `vm_page_find_contiguous` lines per create).

### Memory map (kernel 2974: larger pool and window; host only, NOT BOOTED)

Why XNU stopped at 3264 MiB [V code]: not a kernel limit. Mu "Kernel RAM" started at 0xE1000000 because the pools sat below it, and mkadt.py left 256 MiB for UEFI, then rounded down to a 64 MiB multiple (304 MiB left).
Limits that are far off: XNU `LAUREL_RAM_MAX` and DarwinBoot `DARWINBOOT_MAX_WINDOW` 4608 MiB (start.s: 16 bootstrap table pages; 3904 MiB at 0xC1004000 needs 11, `ram-map-test.py`), DarwinBoot parser 8 GiB.
No bank above 0x1C0000000 [I from RamManagerDxe's lists, see below; the sum is 5.95 GiB]. All of the 6 GB (6144 MiB of addresses):

| Range | Size | Owner | Why not kernel RAM |
| --- | --- | --- | --- |
| 0x40000000-0x7CC00000 | 972 MiB | firmware carve-outs, Mu FD and heap; 0x65E00000-0x7CC00000 (366 MiB) is free | not next to the window: XNU manages one range. [U] free RAM there is unused by anything |
| 0x7CC00000-0x80000000 | 52 MiB | outside every bank [I] | no RAM |
| 0x80000000-0xC0000000 | 1024 MiB | Adreno GPU pool | must be contiguous, below 4 GiB, and with no cacheable alias |
| 0xC0000000-0xC1000000 | 16 MiB | TopazModem pool | no cacheable alias; below 0xF0000000 |
| 0xC1000000-0xC1004000 | 16 KiB | Mu "Kernel RAM" start | DarwinBoot keeps the kernel's 2 MiB offset |
| 0xC1004000-0x1B5004000 | 3904 MiB | XNU window, 1007 MiB below 4 GiB | `hw.memsize` 4093640704 |
| 0x1B5004000-0x1C0000000 | 176 MiB | UEFI's allocations, top-down from 0x1C0000000 | they live until ExitBootServices. [U] how much UEFI really takes: no boot logged it. Known good: 240 MiB in the first layout, 304 MiB since. The window stays under 4 GiB on purpose (a round number nothing has tried) |

Balance: pool memory serves only the GPU, and scattered pages from kernel RAM take over when it is empty, so the pool stops at the 1 GiB target and the rest goes to the kernel. Below-4-GiB kernel RAM doubles (495 to 1007 MiB).

Failure at boot:
| Failure | Result | Line |
| --- | --- | --- |
| UEFI took more than 176 MiB | DarwinBoot 0102 takes the biggest run (window smaller, same base) | screen `WINDOW <size> OF <asked> @ <base>`, `LAUREL RAM: on: ...; DarwinBoot gave N of the M MiB the ADT asks` |
| window past the ADT banks | 3264 MiB at the same base | `LAUREL RAM: on: 3264 MiB ...; window end 0x.. is past the banks: 3264 MiB` |
| `laurelramgrow=0` | 3264 MiB | `...; kill switch laurelramgrow=0: 3264 MiB` |
| no bank table, base in a pool, `laurelram=0` | 768 MiB (2100, only with a broken ADT) | `LAUREL RAM: off: ...` |
| Mu or the kernel dies before a log | no automatic path: flash the previous boot image, or `MU_RAM_LAYOUT=late` (GPU pool 768 MiB) | none |

The base moves from 0xE1004000 to 0xC1004000, so "the current window" comes back at its old place only with the old FD. An FD of before 2974 with the new kernel and ADT works: 3392 MiB at 0xE1004000 (host test).

### Memory map before 2974 (for the logs of before; areas B and E placed their pools by it)

| Range | Size | Owner | Notes |
| --- | --- | --- | --- |
| 0x40000000-0x7CC00000 | 972 MiB | bank A: fixed carve-outs (hardware-map.md), Mu fixed regions (FD 0x5FC00000, DXE heap 0x62100000) | not kernel RAM |
| 0x7CC00000-0x80000000 | | no RAM | |
| 0x80000000-0xC0000000 | 1 GiB | free for device pools (Mu "Pool RAM", reserved) | e.g. a later pool; topaz TopazAdreno 0x90000000 + 1 GiB (gpu=1 without gpu_midmem) overlaps 0xC0000000+ |
| 0xC0000000-0xE0000000 | 512 MiB | Adreno GPU pool (area B, `laurel-ram-reserved`) | Mu "Pool RAM" |
| 0xE0000000-0xE1000000 | 16 MiB | TopazModem pool (area E, MODEM_POOL_BASE, `laurel-ram-reserved`) | Mu "Pool RAM" |
| 0xE1000000-0xE1004000 | 16 KiB | Mu "Kernel RAM" start; DarwinBoot keeps the kernel's 2 MiB offset | |
| 0xE1004000-0x1AD004000 | 3264 MiB | XNU (DarwinBoot window, boot_args physBase/memSize); 495 MiB of it below 4 GiB | MDP scanout pool, USB/UFS DMA, DSI/flip buffers: below 4 GiB by mask |
| 0x1AD004000-0x1C0000000 | 304 MiB | UEFI's own allocations (top-down from 0x1C0000000), free after ExitBootServices | not kernel RAM |

The static map (Mu 0101) is for the **6 GB Mi A3 only**: it hard-codes bank C up to 0x1C0000000. A 4 GB unit would get RAM
that does not exist and die in PrePi; it needs the late layout below (bank C from SMEM).

XNU's managed RAM is one range from physBase, so pools go below it: no cacheable alias of a pool in the physical aperture,
and nothing XNU allocates lands in one. The UEFI map reserves 0x80000000-0xE1000000 ("Pool RAM"), so NegroniBootMemoryDxe
and RamManagerDxe add no DT hole there and no free run next to "Kernel RAM" can pull the window down. The window base
0xE1004000 keeps a 32 MiB-aligned VA-PA delta (as 0x81004000 did). The 1 GiB at 0x80000000 could become kernel RAM only
with a window from 0x81004000 that passes over the pools (a hole in XNU's range: not supported).

| Piece | Change |
| --- | --- |
| Mu 0101 | "Pool RAM" 0x80000000 + 0x41000000 reserved, "Kernel RAM" 0xC1000000 + 0xFF000000 (2974; first 0x61000000 and 0xE1000000 + 0xDF000000; before that 0x81000000 + 0x3F000000). UEFI now allocates top-down from 0x1C0000000 (before: from 0xC0000000, and RamManagerDxe added bank C late, so no run crossed 0xC0000000). |
| Mu 0102 (DarwinBoot) | no run holds the asked window: take the biggest usable run (2 MiB multiple, >= 256 MiB), screen line `WINDOW <size> OF <asked> @ <base>`; boot_args memSize = that size. With the laurel defines (0103) a run is usable only when the window starts below 4 GiB with >= 256 MiB below 4 GiB, and the window is capped at 4608 MiB; no usable run: `NO WINDOW` + the FREE list. Without the defines (negroni) DarwinBoot behaves as before. |
| Mu 0103 (laurel dsc) | `PcdSmbiosEntryPointProvideMethod 0x2` (SMBIOS 3.8, 64-bit entry point only): SmbiosDxe allocates the 32-bit table `AllocateMaxAddress 0xFFFFFFFF`, which would land at about 0xFFFFF000 inside the window run and split it. DarwinBoot BuildOptions `DARWINBOOT_MAX_WINDOW=0x120000000`, `DARWINBOOT_LOW4G_MIN=0x10000000`. |
| Mu late/0101 (`MU_RAM_LAYOUT=late`) | the fallback layout, see below. |
| mkadt.py `--dram auto --mu-fd FD` | window size from the FD's "Kernel RAM" entry (PrePi table, uncompressed in the FD): largest 64 MiB multiple that leaves 256 MiB for UEFI, max 4608 MiB, no overlap with a pool -> 3264 MiB; older FD -> 768 MiB + `LAUREL RAM: off:` line. `/chosen laurel-ram-banks` = B 0x80000000 + 1 GiB, C 0xC0000000 + 4 GiB; `/chosen laurel-ram-reserved` = 0xC0000000 + 512 MiB, 0xE0000000 + 16 MiB. `uefi-image.sh` default `DRAM=auto`. |
| kernel 2100 | `osfmk/arm64/laurel_ram.c` before arm_vm_init: window inside one run of `laurel-ram-banks`, XNU manages <= 4608 MiB (the real limit is start.s: its 16 bootstrap table pages hold 2 L1 + one L2 per GiB of V=P and of KVA + 1 FB L2 = 15 for 4608 MiB; start.s maps the whole memSize before this check, so 0102 and mkadt cap the window too), no overlap with `laurel-ram-reserved` (a pool above the base caps the window; the base inside a pool = off), >= 128 MiB below 4 GiB. When the window crosses 4 GiB: `vm_himemory_mode = FALSE` (pmap_startup fills the free queue from the top, so zones and user pages use RAM above 4 GiB first; only the pmap_steal boot allocations come from just above the kernel). Failure or `laurelram=0`: XNU keeps the first 768 MiB of the window (maxmem path); at 0xE1004000 that is 495 MiB below 4 GiB + 273 MiB above (the old size, not the old place). USB and UFS DMA blocks (kmem_alloc_contig) get max_pnum = 4 GiB. |
| kernel 2101 | LAUREL SPOOL: IOCoreSurfaceRoot::start (before user space) takes 6 x 12 MiB contiguous, 16 KiB-aligned buffers below 4 GiB for the scanout path (screen-sized BGRA surfaces; 12 MiB also holds the 1125x2436 surface of `sweetfb_native=0`); reuse only at retain count 1; pool full: wired pages at once (no contiguous scan); the line ends with `below-4G free N MiB`. LAUREL SURF (TOPAZ_4K, no GPU): other surfaces get a pageable IOBMD wired by prepare() (own VM object, offset 0: correct for 16 KiB user pages; no physical run); the old allocation stays as the fallback. Kill switches `laurelspool=0`, `laurelsurf=0`. |
| kernel 2103 | native canvas: AppleCLCD presented the topaz iPhone X canvas 1125x2436 unless `sweetfb_native=1` (not in the UEFI boot-args): the panel showed only the centre 64 % of the UI, and IOMFB's size did not match the ADT canvas 720x1560. Now native is the default when disp0 canvas-width/height = the panel and `/chosen display-scale` (2) divides it: 360x780 points. Kill switch `sweetfb_native=0`. The layout is set at the top of AppleCLCD::start, so area C's `sweet_hid_set_geometry()` call (2200, later in start) gets it. Self-report (was 2102): `LAUREL FB CANVAS: first frame on the panel: swap N, L layer(s), surface ..., canvas WxH, direct|copy path` at the first swap with a layer (direct = scanout surface copied to the back buffer and flipped; copy = composed). |

### Late layout (fallback if Mu dies with the static map)

The static map makes UEFI allocate above 4 GiB from its first DXE (`AllocateAnyPages` starts at 0x1C0000000). Before mu 0101,
every Qualcomm DXE that ran before RamManagerDxe (DisplayDxe, SdccDxe/UFSDxe, UsbfnDwc3Dxe, ...) got RAM below 0xC0000000. If a
binary DMA buffer above 4 GiB hangs Mu or the panel before UniXNU, build `MU_RAM_LAYOUT=late make laurel-mu` (or
`MU_RAM_LAYOUT=late scripts/laurel/mu-build.sh`): mu late/0101 replaces 0101 (applied last).

| Range | Mu entry | Notes |
| --- | --- | --- |
| 0x80000000-0x81000000 | "Pool RAM Guard", reserved | |
| 0x81000000-0x90000000 | "UEFI RAM", conventional, 240 MiB | the highest RAM until RamManagerDxe runs: every early UEFI allocation stays below 4 GiB |
| 0x90000000-0xC1000000 | "Pool RAM", reserved | GPU pool 0x90000000 + 768 MiB, modem pool 0xC0000000 + 16 MiB |
| 0xC1000000-0x1C0000000 | none: RamManagerDxe adds the bank C hole late (one run) | DarwinBoot window 0xC1004000 + 3904 MiB; later UEFI allocations top-down from 0x1C0000000 |

NegroniBootMemoryDxe gets `NEGRONIMEM_ADD_BELOW=0xC1000000` from the dsc (a no-op define for other platforms): without it, it would
add 0xC1000000-0x100000000 early as a DT hole below 4 GiB, and UEFI's early allocations would cut the window run. The late layout
works on any RAM size. mkadt.py `--dram auto` recognises the FD by its "UEFI RAM" entry and plans the same window.
Test note: this ABL refuses `fastboot boot`, so every test is a `boot_b` flash (`scripts/laurel/flash-boot.sh`); keep the previous
image to flash back. Images of 2026-11-01 05:15 (area A worktree): `out/laurel/uefi/laurel-uefi-boot.img` (static) and
`laurel-uefi-boot-late.img` (late).

[I] Early alias: until arm_vm_init, start.s maps the whole boot window cacheable. A pool inside it exists only with an old Mu FD and a
new ADT (2100 then caps the window below the pool); nothing touches the pool then. The final physical aperture ends at physBase +
mem_size.

Display path without a GPU (topaz 0092-0103, 0945, unchanged): backboardd swaps (IOMFB SwapEnd) -> `showPending` -> flush timer
(`sweetfb_hz=30`) -> `present()`: one full-screen scanout surface -> `directPresent` (copy into the cached flip buffer, MDP VIG0
flips to it); several layers -> copy path (composed into the back buffer). The first swap hides the kernel console
(`fConsShown = false`; `sweetfb_console=1` keeps it).

Expected boot lines: `LAUREL RAM: on: 3904 MiB at 0xc1004000..0x1b5004000 (banks 0x80000000..0x1c0000000; 1007 MiB below 4 GiB, used
last)`, `TopazGPU: kernel RAM 0xc1004000+0xf4000000, GPU pool 0x80000000+0x40000000 (ADT laurel-ram-reserved)`, `LAUREL GPU POOL: on: 1024 MiB at 0x80000000, 16 chunks of 64 MiB`, `TopazGPU: zap: ... metadata 6860 bytes at 0xc0008000 (modem pool)`, `LAUREL SPOOL: on: 6 x 12 MiB contiguous below 4 GiB at 0x..-0x.. for screen surfaces; below-4G free N MiB` (N should be
several hundred; both lines again at the first surface, so they are in the USB log), `LAUREL FB CANVAS: on: native 720x1560 at display-scale 2 (360x780 points)`, `SWEET FB: modes published: 720x1560
at 60 Hz`, `LAUREL SURF: on: surfaces from wired pages (no contiguous RAM needed), first N bytes`, `SWEET SURF: backboardd create id
N 720x1560 ... -> 0x0`, no `vm_page_find_contiguous` lines, `LAUREL FB CANVAS: first frame on the panel: swap N, ...`, `SWEET FB: swap
...` (copy path, first 16) or `SWEET FB: 1000 swaps`. `hw.memsize` 4093640704.
Failure signs: no UniXNU menu (Mu 0101: a UEFI driver that cannot use RAM above 4 GiB; flash the previous image, then try the late
layout),
`WINDOW ... OF ...` on the screen (DarwinBoot shrank the window), `LAUREL RAM: off: ...`, a red status bar (no iOS layout for
360x780 points; fixed in the root by `scripts/laurel/root-statusbar.py`, docs/laurel_sprout/rtc-statusbar.md; `sweetfb_native=0`
returns to the cropped iPhone X canvas).

## Boot CPU: Gold 0x100 after a PSCI hand-off at the kernel entry [decision 2026-11-01 03:40, patch 2016]

Boot 03:14 (patch 2015) showed why Silver 0x0 cannot be the boot CPU: `ISENABLER0 0x00000000 ISPENDR0 0x08280000
IGROUPR0 0x00000000` after pe_init_fiq had written the enable, `GICD_CTLR 0x12` (DS = 0: two security states).
TrustZone keeps the SGIs/PPIs of the firmware's boot core in Group 0 (Secure); Non-secure writes to IGROUPR0 and
ISENABLER0 for them are RAZ/WI; the virtual timer (INTID 19) pends for ever and no tick reaches EL1 NS. A core
started with PSCI CPU_ON gets a redistributor set up for a NS OS (the shim path booted this kernel on Gold 0x100 that
way, timer OK).

`patches/laurel/xnu/2016-laurel-boot-handoff-gold.patch`: at the first instructions of `start_first_cpu` (MMU and
caches off, x0 = boot_args PA, DarwinBoot's DarwinEnter state) a Silver core (MPIDR Aff1 == 0) calls
PSCI CPU_ON(0x100, `laurel_handoff_entry` PA, boot_args PA), writes the result into `laurel_handoff_state` and turns
itself off with PSCI CPU_OFF (shim patch 0002 logic: a parked core is ALREADY_ON for the kernel's later CPU_ON; the
wfi loop stays as a fallback). Gold 0x100 arrives at `laurel_handoff_entry` at EL1 (or EL2: the EL2 setup of
`sweet_secondary_entry` is repeated and it drops to EL1), stores its MPIDR/EL, and continues in `start_first_cpu`
as the boot CPU: the white stage-0 band is then drawn by Gold. CPU_ON refused: Silver boots the kernel itself
(2012 accepts MPIDR 0x0). DarwinBoot and Mu are unchanged (no MMU state to rebuild: the entry already runs with the
MMU off and a physical x0). No kill switch (boot-args are not parsed yet); the feature turns itself off on a PSCI
refusal. Report on the panel (SweetCPU::startAll): `LAUREL CPU: boot cpu mpidr=0x100 (Gold; hand-off from Silver
0x0: PSCI CPU_ON rc=0, arrived mpidr=0x100 at EL1)` or `(Silver; hand-off off: PSCI CPU_ON rc=N, ...)`.
ADT: `mkadt --boot gold` again (cpu0 = 0x100 `state = running`, Gold cluster 0 'P', Silver cluster 1 'E').
2015 now writes only what NS may write (no IGROUPR0/IGRPMODR0/GICR_PWRR writes) and keeps its read-back lines.

### Earlier decision (02:00, superseded): Silver 0x0, no hand-off

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
2026-11-01: `launchd_disable_all_timeouts=1` added (5 s extension check-in limit, metal.md section 11.2; `LAUNCHD_TIMEOUTS=1` builds without it).

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

- 2026-11-01 02:10 [V]: everything builds; both images exist.
- 02:16 first Mu-only boot [V photo]: the ABL inflates gzip(BootShim + FD) and Mu runs (so the v2 boot image recipe
  with the stock DTB works). Loaded: RngDxe, DDRInfoDxe, SimpleTextInOutSerial, ConPlatformDxe, ConSplitterDxe,
  GraphicsConsoleDxe, NegroniBootMemoryDxe, DarwinBoot.efi, RamManagerDxe, SmbiosDxe, SmBiosTableDxe; the display
  console works. NEGRONIMEM: device tree at 0x454FD000 (502099 bytes), 3 memory ranges, 21 reserved ranges, system
  memory added 0x57E00000-0x5BBFFFFF, 0x5D000000-0x5E3FFFFF, 0x65E00000-0x7CBFFFFF, 0x80000000-0x80FFFFFF
  (0x1D000000 bytes). RamManagerDxe (RAM partition protocol, gaps of the EFI memory map): 0x45700000-0x45CF0000,
  0x45D00000-0x45F20000, 0x45F40000-0x46000000, 0x46200000-0x4AB00000, 0x57D00000-0x57E00000, 0x5E400000-0x5F800000,
  0x5FF8C000-0x5FF8D000, 0x5FFD0000-0x5FFF7000, 0x60000000-0x62000000, 0x65D00000-0x65E00000, 0xC0000000-0x1C0000000.
  Then `Synchronous Exception at 0x6288CF64` in DDRInfoDxe.dll (Qualcomm binary, NicobarLAA RELEASE), called from
  SmBiosTableDxe (Silicium) <- DxeCore: ESR 0x96000007 (data abort, translation fault level 3), FAR 0x0447D220,
  X0 0x46008170 (SMEM); ASSERT [ArmCpuDxe] CpuExceptionHandlerLib.c(438), Mu stops.
- Fix [V source]: upstream `laurel_sproutPkg` MemoryMapLib has no "MCCC_MCCC_MSTR" region; ginkgo, willow, lime, fog,
  spes, tapas, citrus, veux, gta4l map it at 0x0447D000 (4 KiB MMIO). 0x0447D220 is inside it. `patches/laurel/mu/0001`
  adds the region. No change to SmBiosTableDxe/DDRInfoDxe.
- RAM layout [I from the two lists]: RamManager maps a RAM partition hole only where the EFI memory map has nothing, so
  its lists give the partitions: bank A 0x40000000-0x7CC00000 (its last hole ends at 0x65E00000 where NEGRONIMEM's piece
  starts; 0x7CC00000-0x80000000 was mapped by nobody = outside every bank), bank B 0x80000000-0xC0000000 (NEGRONIMEM
  added 0x80000000-0x81000000, "Kernel RAM" covers the rest), bank C 0xC0000000-0x1C0000000. Sum 0x3CC00000 + 1 GiB +
  4 GiB = 5.95 GiB = the 6 GB Mi A3. So "Kernel RAM" 0x81000000-0xC0000000 lies in bank B and the DarwinBoot window
  0x81004000 is valid; the 4 GiB above 0xC0000000 is conventional memory after it in map order (DarwinBoot takes the
  first run that fits, so the window stays at 0x81004000). `patches/laurel/mu/0002` prints `NEGRONIMEM: DT memory bank
  0x..-0x..` per bank so the next photo confirms this.
- `NEGRONIMEM: initrd 0x456FE000-0x456FE05E is not a whole number of sectors`: the Mu-only image's empty cpio (94 bytes)
  is not a 512 multiple; expected, harmless (no payload wanted). `uefi-image.sh` now pads it to 4096 bytes and writes the
  Mu-only image to `laurel-mu-only-boot.img` (before, both modes wrote `laurel-uefi-boot.img`).
- 02:23 [V]: Mu rebuilt (both patches apply, 52 images, 15 s), both images rebuilt. NOT BOOTED since the fix. Next:
  owner puts the phone in fastboot (Power+VolDown), flash the Mu-only image, photo: expect the bank lines, no
  exception, the Mu front page; then the full image.
- 02:28 **first full-chain boot [V photo]: the whole chain works.** Mu (both patches), UniXNU, DarwinBoot, XNU on Silver
  0x0. Panel lines: keepsyms, "No POST boot-arg set", SWEET platform expert, `LAUREL REBOOT: on: PSCI off/reset, IMEM
  reason at 0xc12565c`, AKS, WDT, SURF, HID touch/buttons, `CPUFREQ gold 0->7 (2016 MHz)`, AMFI, `LAUREL FB SCANOUT: on:
  VIG0 (0x5e05000) fetches 0x5c000000 720x1560 stride 2880` (Mu's SimpleFb stages the screen on VIG0, as topaz), DSI0,
  INTF1, `SWEET CPU: requested=8 selected=8 (limit=8)`, `LAUREL CPU: boot cpu mpidr=0x0 (Silver, UEFI path)`, `SWEET USB:
  running (DSTS 0x00820001 after 0 ms), DMA at 0x83113000`, `LAUREL USB: on: ECM 192.168.7.2 ...`, vnguard, `SWEET: trust
  caches unavailable (Image4/AMFI not installed)` = last line. No `SWEET CPU: cpu=1 CPU_ON`, no bsd_init copyright banner.
  Host (xHCI, 02:28:02-02:28:36): "new high-speed USB device", `device descriptor read/64, error -110` then `-71`, port
  power cycle, "device not accepting address", "unable to enumerate": the DWC3 connected (pull-up, HS link) and no one
  served EP0.
- Reading [I, strong, from the code]: after the trust-cache line kernel_bootstrap_thread runs STARTUP_SUB_LOCKDOWN,
  OSKextRemoveKextBootstrap, machine_lockdown, then `PE_lockdown_iokit()` = `ml_wait_max_cpus()`, which sleeps until
  `SweetCPU::startAll` calls `ml_set_max_cpus` after every core came up; then bsd_init (`printf(copyright)` is its first
  console line). startAll had printed its first two lines, then waits for the boot CPU's own self-SGI and each
  secondary's start with `IOSleep(1)`; `ud_thread` (USB) waits with 1 ms sleeps. All three stop at once if the timer
  interrupt does not reach Silver CPU0 (every IOSleep/thread_block needs it), which also explains the silent panel
  (the "not alive after 5 s" and "CPU_ON" lines come after a sleep). On the shim path (ABL -> shim, boot CPU Gold
  0x100) the same kernel got past this point. Differences: the boot CPU (CPU0's redistributor was used by ABL and Mu),
  Mu's GIC exit state (`GicV3ExitBootServicesEvent`: sources, CPU interface and distributor disabled; pe_init_fiq
  re-enables them), the timer PPI (sweet uses the ADT `virtual-timer-intid`; Mu used INTID 18, the physical timer,
  and disabled it). Alternative [I]: kernel_bootstrap_thread spins without blocking; both cases starve the threads.
- Fixes built 02:56 (kernel 215 patches, 0 LSE/RCpc; image `laurel-uefi-boot.img` 52862976 bytes), details in
  `usb-debug.md` "Patches 2013 and 2014": **2013** serves the USB gadget from a 1 ms `timer_call` (interrupt context,
  no scheduler) until bsd_init attaches ue0, with a self-check at STARTUP(LOCKDOWN) that prints on the panel whether
  the first tick came (`LAUREL USB: timer service: on, first tick after N us`) or the full CPU/GIC state when no tick
  comes in 50 ms; pe_init_fiq clears `ICC_AP1R0_EL1`. **2014** puts kprintf (bootstrap step names, bsd_init steps) into
  the console ring = the USB log. NOT BOOTED yet; `scripts/bg.sh laurel-test ...` waits for fastboot (owner: Power+VolDown).
  Expected next photo: the `timer service:` line right after `trust caches`; if "on", the host enumerates the ECM
  device and `logs/laurel-boot-*.log` ends with the last `kernel_bootstrap_thread:` / `SWEET CPU:` line.
- [V photo 03:14, image 93fa4fd] `LAUREL USB: timer service: NO tick in 50 ms: EL1 DAIF 0x200 ISR 0x0 CNTV_CTL 0x5 TVAL
  -2070685 ICC SRE 0x1 PMR 0xf0 IGRPEN1 1 RPR 0xff CTLR 0x440 | GICD_CTLR 0x00000012 GICR WAKER 0x00000000 ISENABLER0
  0x00000000 ISPENDR0 0x08280000 ISACTIVER0 0x00000000 IGROUPR0 0x00000000 prio 0x80 intid 19`: right frame (19, 21, 27
  pending), enable refused, IGROUPR0 reads 0, DS = 0. Conclusion and fix: section "Boot CPU" above (patch 2016).
