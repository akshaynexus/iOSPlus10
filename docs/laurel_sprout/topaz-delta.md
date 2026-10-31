# topaz -> laurel_sprout: what to change

Inputs: `docs/laurel_sprout/hardware-map.md` (Mi A3 DT values) and a read of every topaz board constant
(`external/ios-topaz`, 2026-10-31). Citations `0083:26` = line 26 of `xnu/patches/0083-*.patch`.
Our changes go into `patches/laurel/xnu/2xxx-laurel-*.patch` (applied after the 201 topaz patches) and
`scripts/laurel/` (shim, ADT, payload). [V] = read in files, [I] = inference.

## Same on both SoCs (no change) [V]

GIC 0xf200000/0xf300000, CPU MPIDRs (Silver 0x0-0x3, Gold 0x100-0x103), PSCI IDs, PS_HOLD 0x440b000,
IMEM restart 0xc12565c, UFS 0x4804000, splash FB 0x5c000000 (0xf00000), SPMI core/obs/cnfg, APCS IPC 0x0F111000,
SMEM 0x46000000, GPU 0x5900000 / GPUCC 0x5990000 / GPU SMMU 0x59a0000, WLAN CE 0xC800000, DSI0 0x5e94000,
Gold cpufreq domain 0xf523000, PAS IDs (modem 4, ADSP 1, zap 13), touch bus QUP0 SE2 0x04a88000.

## Must change

| # | Item | topaz | Mi A3 | Where |
| --- | --- | --- | --- | --- |
| 1 | Boot image | v4, payload after `_end` (shim/build.sh:36) | stock is **v2** (page 4096, DTB section); shim needs v2 + the stock DTB so ABL passes x0 = DTB | new `scripts/laurel/shim.sh` |
| 2 | Panel | 1080x2400 LCD, stride 4320 (console.h:5-7, mkadt.py:35) | 720x1560 AMOLED, stride 2880, display-scale 2 [I] | shim, mkadt, 0061/0114 canvas, 0058/0071 touch scaling |
| 3 | 16K early console | stale sweet 0x9c000000 (0010, 0012) | 0x5c000000 | patch |
| 4 | DDR map / pools | highmem 0x140000000+4 GiB, GPU pool 0x90000000 1 GiB, modem pool 0xE0000000 | 6 GB phone; banks [U] until live FDT | mkadt, 0908/0910, 0113 |
| 5 | Carve-outs | modem 0x4AB00000+0x6900000, ADSP 0x53800000+0x2300000, zap 0x55B15000, MSA 0x51900000 | modem 0x4b000000+0x7e00000, ADSP 0x55300000+0x2200000, zap 0x57515000, MSA 0x53300000 (2 MiB) | 0113, 0144, 0901, 0122 |
| 6 | TLMM tiles | WEST 0x500000, SOUTH 0x900000, EAST 0xd00000 (0083:28) | WEST 0x100000, SOUTH 0x500000, EAST 0x900000 + per-GPIO tile map from pinctrl-trinket.c | patch |
| 7 | GCC / GPUCC offsets | gcc-khaje / gpucc-khaje (0083:30, 0087:58, 0091:41, 0901:1591-1638, 0922) | gcc-trinket / gpucc-trinket from `laurel-kernel-los/drivers/clk/qcom/` | patch |
| 8 | Touch | FT5452 @0x38, reset 86, IRQ 80, AVDD GPIO 36 | FT3518 @0x38 **or** Goodix GT9883 @0x5d; reset 87, IRQ 88, ts_vdd GPIO 83; detect both at start | patch (FT path from 0083, Goodix from sweet 0063) |
| 9 | Vol-up | PM6125 GPIO5 (0087) | PM6125 GPIO 5 [V same] | verify |
| 10 | Battery/charger | SM5602 @0x71 + bq2589x @0x6a on I2C (0091, 0148) | PMI632 QG 0x4800 + smb5 over SPMI (SID 2) | new driver |
| 11 | Brightness | DCS 0x51, max 0x7ff | DCS, Samsung max 2047, GVO max 4095 | small patch |
| 12 | Modem firmware tables | hard-coded offsets in HyperOS NON-HLOS (0115, 0121; generator missing) | our `NON-HLOS.bin` from V12.0.26.0.RFQMIXM; write the generator in `tools/op10tool` or Python | new tool |
| 13 | Zap shader | embedded topaz-signed blob (0905) | stock `a610_zap` from our vendor image | build step |
| 14 | WLAN | WCN3988, SID 0x1A0 | WCN3990, SMMU SID 0x80 mask 1 (DT iommus); CE SPI 358-369 | patch |
| 15 | Audio | AudioReach/GPR, WCD937x reset GPIO92, SIA8159 amp @0x2b, RPM ldoa14 | WCD937x reset GPIO 120, **MAX98927 amp @0x3a on QUP0 SE1 (reset GPIO 95), SEC_MI2S**; ADSP firmware is likely APR/Q6 (Android 11, 4.14) [I] | largest change: APR + MI2S path |
| 16 | CPU clock in ADT | 2803200000 | read OSM LUT (SM6125 Gold max ~2.0 GHz [I]) | mkadt |
| 17 | GPU clock | Zonda PLL OPPs (0922) | trinket gpucc PLL; OPPs 320-950 MHz | patch |

## New drivers (topaz has none)

- **Bluetooth:** WCN3990 over QUP1 SE9 HS-UART 0x4c90000 (SPI 312, GPIO 10-13), supplies PM6125 L9/L17/L23/L16 through RPM,
  firmware from `BTFM.bin` (crbtfw/crnv files). Needs GENI UART + QCA HCI setup + the iOS side (bluetoothd expects Apple's
  BT stack; HCI transport glue). Reference: our negroni Bluetooth work (`docs/bluetooth-plan.md`, it works there) and
  HackiOS.
- **Vibration:** PMI632 LDO vibrator (ERM) at SID 3 base 0x5700, 3.0 V: SPMI writes (enable + voltage). iOS side:
  topaz `userland/audio/audio_plugin.c:967-997` writes `/dev/redwood-haptic`; that kernel device (HackiOS) is not in
  topaz. Reference: our negroni haptics work (`docs/haptics-plan.md`).

## Build order

1. Kernel builds on Linux with the 201 topaz patches (scripts/laurel/kernel-linux.sh). Done when it links.
2. Shim v2 + ADT + payload for laurel (items 1-6, 16): `fastboot boot`, kernel console on the panel, `cpus=1`.
3. iOS root on `userdata` (owner approval) -> SpringBoard (touch: item 8).
4. Wi-Fi (modem: items 5, 12, 14), GPU (7, 13, 17), audio (15), battery (10).
5. Bluetooth and vibration drivers.
