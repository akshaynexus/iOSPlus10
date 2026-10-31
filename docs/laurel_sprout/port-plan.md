# Xiaomi Mi A3 (laurel_sprout, SM6125) port

Branch `laurel-sprout`. Goal: iOS 16 first, then iOS 26, on the Xiaomi Mi A3.
Device facts come from `scripts/device/info.sh` (output `logs/device-info-laurel_sprout.txt`, not in git).

Labels: [V] measured or read in source, [I] inference, [U] unknown.

## Device facts (2026-10-31, measured on the connected phone) [V]

| Item | Value |
| --- | --- |
| Model | Xiaomi Mi A3, `laurel_sprout`, board `trinket` |
| SoC | Qualcomm SM6125 (Snapdragon 665), modem build `MPSS.AT.4.3.1.c1-00047-NICOBAR_G` |
| CPU | 4x Kryo 260 Gold MIDR `0x51AF8002` (Cortex-A73 class) + 4x Kryo 260 Silver MIDR `0x51AF8014` (Cortex-A53 class) |
| ISA | ARMv8.0: `fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid`. **No LSE atomics, no RCpc, no PAC, no PAN** |
| RAM | 6 GB variant (MemTotal 5738336 kB) |
| GPU | Adreno 610 v1 |
| Display | 720x1560, 320 dpi, Samsung AMOLED (`sys.panel.display=SDC`) |
| Storage | UFS at `soc/4804000.ufshc` (Lineage `BOARD_KERNEL_CMDLINE`) |
| Android | Android One 11, `V12.0.26.0.RFQMIXM`, patch 2022-08-01, kernel 4.14.180-perf |
| Boot | A/B, **active slot `_b`**, no dynamic partitions, bootloader unlocked, `verifiedbootstate=orange` |
| Root | None (`su` absent). `/proc/cmdline` and `/sys/firmware/devicetree` are not readable |

## Closest reference: ios-topaz [V]

`external/ios-topaz` (MakrSas, Redmi Note 12 4G, SM6225 "khaje") boots iOS 16.7.16 (iPhone X userland) to the
home screen. It has the same CPU, GPU and many MMIO addresses as the Mi A3:

| Item | topaz (SM6225) | Mi A3 (SM6125) | Source |
| --- | --- | --- | --- |
| CPU MIDRs | Gold `0x51AF8002`, Silver `0x51AF8014` | same | topaz README, our `/proc/cpuinfo` |
| GPU | Adreno 610 | Adreno 610 v1 | topaz README, kgsl `gpu_model` |
| GIC dist / redist | `0xf200000` / `0xf300000` | `0xF200000` / `0xF300000` | topaz README, Mu `NicobarPkg` PCDs |
| UFS | `0x4804000` | `0x4804000` | topaz README, Lineage BoardConfig |
| Splash framebuffer | `0x5c000000` | `0x5C000000` (16 MiB "Display Reserved") | topaz `mkadt.py`, Mu `laurel_sproutPkg` MemoryMapLib |
| Panel | 1080x2400 LCD | 720x1560 AMOLED | |
| Touch | FocalTech FT5452, QUP0 SE2 | [U] read from the Lineage/mainline DT | |
| Wi-Fi | WCN3988 through the modem (WLFW) | WCN3990-family through the modem [I] | |

What topaz already solved and we reuse [V, from its README]:

- XNU runs only on the Gold cores: the Silver cores have no 16K granule (`ID_AA64MMFR0.TGran16 = 0`).
  The shim wakes Gold CPU `0x100` with PSCI `CPU_ON` and parks the Silver boot core.
- ARMv8.0: the kernel is built with `-mcpu=cortex-a53`, PAN off, the commpage `casa` is an LDXR/STXR loop.
  LSE atomics and `ldapr` in the iPhone X userland are emulated in `handle_uncategorized`.
- The shim prepares the GIC redistributors for all Gold cores before the jump to XNU.
- Boot path without UEFI: stock ABL `fastboot boot` of a boot image v4 shim with XNU appended after `_end`.

## Boot path choice [I]

Two paths. Both start from RAM with `fastboot boot`, so no partition write is needed for the first tests.

1. **topaz shim path (first):** ABL -> shim (boot.img) -> XNU. Proven on the same CPU. Smallest delta.
2. **This repo's path (later):** Mu-Silicium UEFI (`external/Mu-Silicium/Platforms/Xiaomi/laurel_sproutPkg`,
   on `NicobarPkg`) -> UniXNU/DarwinBoot -> XNU. Mu has a laurel_sprout package already; its boot state is [U].
   The Gold-core wake and the GIC prepare must then move into DarwinBoot or a DXE.

## iOS 26 blocker [V + I]

iOS 26 userland is arm64e. The Mi A3 CPUs have **no PAC** (ARMv8.0). The OnePlus 10 Pro route (native PAC keys)
does not apply. The only known route is the UniXNU-zeta way: lower the PAC instructions in the shared cache and
binaries to plain arm64 (zeta lowered 29.6M PAC words and reached launchd, then faulted, see
`docs/research-report.md`). In addition all LSE/RCpc/v8.3+ instructions need emulation or rewrite, and iOS 26
needs more RAM and a GPU path. Treat iOS 26 on this phone as research, after iOS 16 works.

## Source trees (reference clones, `scripts/setup/get-references.sh`)

| Name | Repo | Use |
| --- | --- | --- |
| `ios-topaz` | MakrSas/ios-topaz `topaz` | XNU patches, shim, ADT builder, userland tweaks for Kryo 260 |
| `Mu-Silicium` | Project-Silicium/Mu-Silicium `main` | `laurel_sproutPkg` + `NicobarPkg` UEFI |
| `laurel-kernel-oss` | MiCode/Xiaomi_Kernel_OpenSource `laurel-r-oss` | Xiaomi stock 4.14 kernel source (drivers, DT) |
| `laurel-kernel-los` | LineageOS/android_kernel_xiaomi_sm6125 `lineage-24.0` | maintained 4.14 kernel, defconfig `vendor/laurel_sprout.config` |
| `laurel-device-los` | LineageOS/android_device_xiaomi_laurel_sprout `lineage-24.0` | board config, cmdline, partitions |
| `sm6125-common-los` | LineageOS/android_device_xiaomi_sm6125-common `lineage-24.0` | common SM6125 board files |
| `laurel-mainline` | laurel-sprout-mainline/laurel_sprout_mainline `mainline-6.18-split` | mainline DT `sm6125-xiaomi-laurel-sprout.dts` and drivers |

Fetch: `scripts/bg.sh refs-laurel scripts/setup/get-references.sh ios-topaz Mu-Silicium laurel-kernel-oss laurel-kernel-los laurel-device-los sm6125-common-los laurel-mainline`.

Firmware (modem, ADSP, Wi-Fi) comes from the phone's own partitions (`modem_b`, `dsp_b`, ...), never from git.

## Phone safety for this device (owner must confirm) [U]

The negroni rules in `CLAUDE.md` name slot B as forbidden. On the Mi A3 the **active slot is `_b`**.
Before any partition write, the owner must set the allowed targets for this phone. Until then: only
`fastboot boot` (RAM) and `userdata` (iOS root, erases Android user data) after explicit owner approval.
Back up first (needs root or a TWRP `fastboot boot`; Magisk on `boot_b` is one option).

## Next steps

1. Back up: full stock firmware for `V12.0.26.0.RFQMIXM` + dump of the small partitions (needs root).
2. Read the live FDT (root): memory banks, reserved regions, touch controller, panel, PS_HOLD, TLMM.
3. Port topaz to laurel_sprout: new MMIO table (TLMM, PS_HOLD, IMEM restart, QUP touch), memory bank, panel size
   720x1560, ADT from `mkadt.py` with Mi A3 values.
4. Build XNU (topaz `xnu.yml` on GitHub macOS runners) and the shim; `fastboot boot` test with `cpus=1`.
5. iOS 16.7.16 iPhone X root on `userdata` (owner approval).
6. Then: Mu UEFI path, GPU (Adreno 610 through Mesa freedreno like topaz), iOS 26 research.
