# Research report: iOS on OnePlus 10 Pro NE2211 ("negroni", SM8450)

Date: 2026-10-24. Read-only research; no repo and no phone was changed.

Marks: **[V]** verified in code, commits or CI. **[I]** inference. **[U]** unknown.
The community repos say that they are AI-written, so claims were judged by code and logs.

## Repo state

| Repo (submodule) | Last commit | License | State |
|---|---|---|---|
| `external/slop` (MellysInformejtik/slop) | 2026-10-23 | none (fork of MIT dipa-studio/ios-sweet) | The real source tree: `negroni-ios/` (128 xnu patches, up to 0124), `shim/` with BOARD=negroni, `uefi/negroni/`, NOTES.md. CI `negroni-ios` green: run 40007883255, artifact `negroni-ios-kernel` expires 2027-01-21 [V] |
| `external/UniXNU-negroni` (pawlickerr, branch `dev`) | 2026-10-22 | none | Board file and scripts. Claims SpringBoard on an NE2213 (CPU rendering, no Wi-Fi); slop logs support it |
| `external/Mu-Silicium-negroni` (pawlickerr) | 2026-10-23 | BSD-2-Clause | Mu-Silicium with `Platforms/OnePlus/negroniPkg` and submodule patches |
| `external/UniXNU` (UniXNU core) | 2026-10-24 | BSD-2-Clause-Patent | Targets xnu-10063.141.1 (iOS 17), 4 KiB pages [V] |
| `external/UniXNU-ios26` (none24smu, branch `ios26`) + `external/UniXNU-zeta` | 2026-10-22 / 24 | NOASSERTION | xnu-12377.121.6 as plain arm64 (no PAC), BCM2837-based config |
| `external/UniXNU-pong` (Chengdong-Yu) | 2026-10-24 | BSD-2-Clause-Patent | iOS 16.6.1 (iPad7,1 identity) on SM8475 |
| `external/ios-sweet` (akshaynexus) | — | MIT | The original sweet port; source of the shim, mkadt and root tools |

## A. Stack for negroni, bottom to top [V]

1. **ABL (stock, unlocked).** It reads the DTB only from `vendor_boot`. The port flashes
   `vendor_boot_a` with only the mainline `sm8450-oneplus-negroni.dtb` (its `splash_region`
   keeps the panel on), flashes `vbmeta_a` with flags 2/3 and erases `dtbo_a`
   (slop `NOTES.md`, "UPDATE 2026-10-20").
2. **boot_a.** Header v4, built by `uefi/negroni/shim-mu.sh`: the ios-sweet shim (BOARD=negroni)
   as kernel; the ramdisk holds the Mu FD and the 64 MiB FAT payload `NEGRONIESP`. The port
   flashes boot_a: with `fastboot boot` the ABL fastboot screen stays on the panel. A header-v2
   shim probe works with `fastboot boot`.
3. **Mu-Silicium negroniPkg.** A copy of r0qPkg (Galaxy S22). Memory map in
   `Library/MemoryMapLib/MemoryMapLib.c` ("Kernel RAM" 0x840000000 + 5 GiB, measured on an 8 GB
   NE2213). Display: SimpleFbDxe on the ABL splash at 0xB8000000, 1080x2412x32. Own DXEs: keys
   (SPMI), touch (Synaptics S3908), boot memory, PCIe0, WindowsFirst. UFS, clock, RPMh, SPMI,
   TLMM and I2C are Qualcomm binary DXEs taken from the phone's `uefi` image and patched at fixed
   offsets with `portpatch2.py` (slop `uefi/negroni/README.md`).
4. **UniXNU boot manager + DarwinBoot** (UniXNU core `package/UniXNUPkg`, `drivers/DarwinBoot`),
   linked into the Mu tree by hand. Reads `\EFI\UniXNU\unixnu.toml`, loads `kernel.macho` + ADT.
5. **XNU.** xnu-8796.141.3, config NEGRONI, plain arm64, 16K pages, 8 cores via PSCI, EL1 under
   Gunyah. Patches in `negroni-ios/xnu/patches`; CI `.github/workflows/negroni-ios.yml` (macos-14,
   blacktop/darwin-xnu-build).
6. **Drivers in the kernel** (`bsd/dev/negroni_*`): UFS root by GPT name `userdata`, SPMI keys,
   S3908 touch over GPIO-I2C, framebuffer, IOSurface/AppleCLCD stand-ins, HID, AMFI/Sandbox/AKS
   stubs, USB CDC-ECM log (untested), PCIe Wi-Fi link only, A730 bring-up (0099-0124).
7. **iOS root.** iPhone X (iPhone10,3, D22AP) iOS 16.7.16 20H392, HFS+ in `userdata`, built by
   `negroni-ios/tools/build-ios16-root.sh` from `087-86698-044.dmg` (OS),
   `087-86593-047.dmg` (SystemOS), `087-86715-047.dmg` (AppOS), plus Procursus/Sileo.
   Flash: `fastboot -S 512M flash userdata X.simg`.

### What changes for the NE2211

- **UEFI firmware: low risk.** The NE2211 OTA `uefi.img` has the same build string
  `BOOT.MXF.2.0-00925.2-WAIPIO-1` and all 8 documented patch sites hold the expected instructions
  (PmicDxe 0x3e70/0x3e84 `bl`, SPMIDxe 0x2e80 prologue, UFSDxe 0xcad0 `bl`, TzDxeLA 0xf55c 0x00,
  UsbMsdDxe 0x40d1 0x10, UsbConfigDxe 0x51d8 `ldrb/cbz`, ClockDxe 0xedd0 plausible). The OTA
  `uefi.img` is the input; no on-device dump is needed. `scripts/uefi-fv-extract.py` extracts the
  92 DXEs (gzip GUID sections).
- **RAM:** 12 GB instead of about 8 GB. Measure the memory map again (shim probe) and fix
  MemoryMapLib and `--dram 840000000:C0000000`.
- **Paths:** `board.toml` uses Windows/WSL paths.
- **Display rows:** the kernel assumes 2400 rows, Mu uses 2412.
- **Unknown:** whether the OxygenOS 16 ABL accepts the mainline DTB and the header-v4 shim; the
  r0q power-button check that was not ported may shut the UEFI down.

## B. Tracks

### (i) iOS 16 on the NE2211

No secrets are needed [V]: mkadt uses a synthetic ECID (`0x5357454554000001`). `UNIQUE_CHIP_ID`
and `ARTIFACT_KEY` belong only to the separate iPadOS 17 track and can be self-generated.

1. Run the shim probe with `fastboot boot` (writes nothing); record MEM, MIDR, PSCI, GIC.
2. Extract the DXEs from the OTA `uefi.img`; run `portpatch2.py` / `mkbinaries.py`; fix the
   12 GB memory map; `build_uefi.py -d negroni -r DEBUG`.
3. Kernel: `gh run download 40007883255 -R MellysInformejtik/slop -n negroni-ios-kernel`, then
   `build-adt.py` (new `--dram`), `build-payload.py`, `build-bootimg.py`.
4. Download the iPhone10,3 16.7.16 20H392 IPSW and the D22AP DeviceTree; build the root.
5. With approval for each write: `vendor_boot_a` (DTB), `vbmeta_a` (disabled), erase `dtbo_a`,
   `boot_a`, `userdata`.

### (ii) iOS 26

- **Kernel:** xnu-12377.121.6 as **arm64e**, from a NEGRONI config based on VMAPPLE (already
  `NO_MONITOR`, GICv3, no KTRR/CTRR/AMX). 16K pages are fine, so no 4K re-signing of the cache.
- **PAC [V]:** open-source XNU has no PAC key code for real hardware. `SET_JOP/ROP_KEY_REGISTERS`
  (`osfmk/arm64/pac_asm.h`), `ml_enable_user_jop_key` (`machine_routines_asm.s`) and
  `PAC_INIT_KEY_STATE` (`start.s`) only have the `HAS_PARAVIRTUALIZED_PAC` VMAPPLE hvc 0x0-0x6
  path. `cpuid.c` reports ARMv8E only with `HAS_APPLE_PAC`, so a plain arm64 kernel refuses
  arm64e binaries (`ml_grade_binary`) — zeta's EBADARCH. Apple silicon also has APCTL_EL1
  (KernKeyEn/AppleMode), so a stock Apple kernelcache cannot run on Cortex cores.
- **Route [I, medium to large]:** keep the paravirt PAC paths but replace each hvc with native
  `AP{IA,IB,DA,DB,GA}Key{Lo,Hi}_EL1` writes. Simplest: one global key set for the kernel and all
  processes (no switch on exception or context switch; no per-process isolation). Clear
  `HAS_ARM_FEAT_SME/SME2`, `PAN3`, `HAS_PARAVIRTUALIZED_CTRR` and the APPLEVIRTUALPLATFORM
  hypercalls in `VMAPPLE.h`; check `SSBS2`.
- **Gunyah allows EL1 PAC [I, strong]:** Android reports `paca pacg`.
- **Nobody has run arm64e iOS userland on non-Apple PAC hardware yet [V].** zeta (no PAC) lowered
  29.6M PAC words in the shared cache and reaches launchd, then faults. negroni does not need that
  rewrite; the kernel must still sign shared-cache auth rebases during the slide [I].
- **Userland [I]:** an A13 iPhone IPSW (iPhone12,1 or iPhone12,5): lowest iOS 26 ISA baseline, no
  SPTM/TXM/exclaves, Face ID gestures like the working iPhone X identity.
- **Other work:** port the 128 patches to xnu-12377 (IOSurface, IOMFB, AKS, HID, AMFI/Sandbox,
  sysctl identity) or prelink Apple's arm64e A13 kexts (`scripts/analyze-arm64e-kernelcache.py`
  in the ios26 branch); flatten the cryptex or use an APFS root.
- **Open question [U]:** whether iOS 26 QuartzCore renders without a Metal device.

## C. GPU (Adreno 730)

- negroni `chip_id 0x07030001` = Mesa FD730 (a7xx_gen1, 4 CCU); A740 `0x43050a01` = FD740
  (a7xx_gen2). Turnip supports FD730. pong is `0x07030002` = FD725 [V].
- UniXNU NativeAdreno register offsets are equal for A730 and A740 (diff of
  `NativeAdrenoA730HwInit.h` vs `NativeAdrenoA740HwInit.h`); hwcg and protect tables differ. Board
  parts (GMU/RSC, votes, cmd-db, SMMU, firmware `gmu_gen70000.bin` / `a730_sqe.fw` / `a730_zap`,
  HFI, GMU base, 4K page check) come from the sheng device repo and must be ported [V].
- NativeMetal is tied to iPadOS 17.7.11 private Metal SPI; iOS 26 needs a port [I, large].
- AirNir takes `CHIP_ID` and uses Mesa ir3, so it can target FD730 [V].
- Real hardware: only sheng (iPadOS 17, A740) has a Metal-composited UI. pong's "acceleration"
  claim is not confirmed by its own driver README.
- slop already has an A730 path (`bsd/dev/negroni_adreno.c`): 22 steps (power, GMU, HFI, CP, zap,
  2D frame with pixel check) all ran once; the RedwoodGPU user client (0118) panicked; 0124 is
  untested. Mesa OSMesa FD730 is built; gl_test ran only on softpipe.

## D. Blockers, most severe first

1. Mu UEFI on NE2211 / OxygenOS 16 — now small to medium (firmware matches); open: 12 GB map,
   ABL DTB acceptance, power-button check.
2. iOS 26 QuartzCore without a GPU [U] — possibly a hard blocker until Metal works.
3. Metal on the A730 — large, high risk.
4. iOS 26 kernel (xnu-12377 arm64e + patch port or arm64e kext prelink) — large.
5. arm64e PAC key management in XNU — medium to large.
6. AMFI, Sandbox and code signing for iOS 26 — medium to large.
7. Wi-Fi QCA6490 (PCIe link only) — large.
8. Licensing: slop and UniXNU-negroni have no license file.
9. Small fixes: board.toml paths, 2400 vs 2412 rows, `--dram`.

## E. Writes outside boot_a and userdata

- `vendor_boot_a`: custom image with the mainline DTB (required).
- `vbmeta_a`: verification disabled (flags 2/3). On the NE2213 the flags once went back to 0
  after fastboot writes at low battery.
- `dtbo_a`: erased.
- `fastboot set_active a`.
- Inside userdata: the last ~4 MiB hold the persistent log; an 8 MiB GPU firmware area sits
  before it (`mkfwarea.py`); `fastboot flash userdata` erases it.
- Do not repeat the GPT changes from the earlier NE2213 Windows work.
