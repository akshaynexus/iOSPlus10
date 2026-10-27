# Device facts (NE2211, measured)

Measured on 2026-10-24 over adb root on OxygenOS `NE2211_16.0.3.530(EX01)`.
Raw files: `~/op10-backup/device/` (not in git).

## CPU

| Cores | MIDR part | Core |
|---|---|---|
| cpu0-3 | 0xd46 | Cortex-A510 |
| cpu4-6 | 0xd47 | Cortex-A710 |
| cpu7 | 0xd48 | Cortex-X2 |

`/proc/cpuinfo` features include `paca pacg bti dit sb flagm2 frint i8mm` (ARMv8.3 PAC, BTI).
Android kernel 5.10.236-android12-9, 4K pages, Gunyah hypervisor at EL2 (no `/dev/gunyah`).

## RAM (12 GB variant)

ABL `/memory` node (`/sys/firmware/devicetree/base/memory/reg`):

| Base | Size |
|---|---|
| 0x080000000 | 0x06A000000 (1.66 GiB) |
| 0x0F1400000 | 0x00EC00000 (236 MiB) |
| 0x800000000 | 0x039900000 (921 MiB) |
| 0x840000000 | 0x0C0000000 (3 GiB) |
| 0x900000000 | 0x180000000 (6 GiB) |

The last two banks are contiguous: `/proc/iomem` shows System RAM 0x840000000-0xA7FFFFFFF (9 GiB).

The 8 GB NE2213 that the port was made on had 0x840000000 + 5 GiB. Both fit the port's
settings without change:
- Mu `MemoryMapLib` "Kernel RAM" 0x840000000 + 0x140000000 (5 GiB) is inside the 9 GiB range.
- `mkadt.py --dram 840000000:C0000000` (3 GiB) is inside it too.

Since kernel patch 0401 (2026-10-27): XNU window 7 GiB at 0x841004000, Mu "Kernel RAM" 0x841000000-0xA20000000
(patches/mu/0002), GPU pool region 0xA20000000-0xA80000000 (1.5 GiB; config `[ram]`, docs/notes.md section 90).

## Firmware

- UEFI (XBL core): `BOOT.MXF.2.0-00925.2-WAIPIO-1.81484.5`, the build that the negroni Mu DXE
  binary patches target. All 8 patch sites hold the expected instructions (`docs/research-report.md`).
- ARB (anti-rollback) index 0.

## Storage

UFS, 6 LUNs (sda-sdf), 4096-byte sectors. 131 partitions by name; `userdata` is on LUN 0.
Unique partitions dumped to `~/op10-backup/partitions/`.

## Display and input

- Panel 1080x2412, Samsung, splash region 0xB8000000 size 0x2B00000 (from the port).
- Touch: Synaptics S3908 (TCM), I2C address 0x4B.
