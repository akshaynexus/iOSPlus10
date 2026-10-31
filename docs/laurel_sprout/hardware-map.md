# Mi A3 (laurel_sprout, SM6125) hardware map

Source: downstream 4.14 device trees (reference clones, 2026-10-31). Paths:
Q = `external/laurel-kernel-los/arch/arm64/boot/dts/qcom/`, X = `.../dts/xiaomi/laurel_sprout/`,
D = `external/laurel-device-los/`, C = `external/sm6125-common-los/`. IRQ numbers are GIC SPI.
Board DT: `xiaomi/laurel_sprout-trinket-base.dts` = `qcom/trinket.dtsi` + `laurel_sprout/laurel_sprout-trinket.dtsi`,
`qcom,msm-id = <394 0>`, `board-id = <11 0>`. The mainline clone has only stubs; its DTs are in
`laurel-sprout-mainline/kernel_xiaomi_laurel_sprout-devicetrees` (not cloned yet).
DDR banks: not in the DT (ABL fills `memory`). Read them from the live FDT (root) or ABL.

## Compared with topaz (SM6225), per subsystem

| Subsystem | Mi A3 value | Source | topaz | Port work |
| --- | --- | --- | --- | --- |
| GIC | GICD 0xf200000, GICR 0xf300000 (stride 0x20000) | Q trinket.dtsi:569 | same | none |
| CPUs | Silver MPIDR 0x0-0x3, Gold 0x100-0x103; PSCI 1.0 smc | Q trinket.dtsi:54-305 | same | none |
| cpufreq | OSM pwrcl 0xf521000, perfcl 0xf523000 | Q trinket.dtsi:861 | check | verify 0094 |
| PS_HOLD | 0x440b000 | Q trinket.dtsi:1069 | same | none |
| IMEM restart reason | 0xc12565c | Q trinket.dtsi:1026-1061 | same | none |
| APSS WDT | 0xf017000, SPI 3/4 | Q trinket.dtsi:1188 | check | verify 0088 |
| TLMM | 0x400000; tiles WEST 0x100000, SOUTH 0x500000, EAST 0x900000; 133 GPIOs | pinctrl-trinket.c:28-33 | WEST 0x500000, SOUTH 0x900000, EAST 0xd00000 | **change tile table** |
| Touch bus | QUP0 SE2 I2C 0x04a88000, SPI 329, GPIO 6/7 | Q trinket-qupv3.dtsi:125 | QUP0 SE2 | check clocks (0087) |
| Touch IC | Goodix GT9883 @0x5d **or** FocalTech FT3518 @0x38; IRQ GPIO 88, reset 87, ts_vdd enable GPIO 83 | X touchscreen.dtsi | FT5452 | **FT3518 near FT5452; Goodix path from sweet (0063)**; detect at boot |
| Keys | power + vol-down: PM6125 PON 0x800; vol-up: PM6125 GPIO 5 | Q pm6125.dtsi:32 | check | verify PMIC SIDs |
| Display | MDP 0x5e00000, DSI0 0x5e94000, PHY 0x5e94400, DISPCC 0x5f00000; Samsung s6e8fco or GVO r692a9 AMOLED, video mode, 720x1560@60, 4 lanes | Q trinket-sde.dtsi, X display/ | 1080x2400 LCD | **panel size, DCS backlight (max 2047), AMOLED on/off** |
| Splash FB | 0x5c000000, 0xf00000 | Q trinket.dtsi:541 | same | stride 720*4 |
| GPU | A610 kgsl 0x5900000, SPI 177, chipid 0x06010000; GPUCC 0x5990000; SMMU 0x59a0000; zap `a610_zap` PAS 13 @0x57515000; OPP 320-950 MHz; no GMU | Q trinket-gpu.dtsi | A610 | verify GPU/GPUCC/SMMU bases, zap address |
| Wi-Fi | WCN3990 (icnss) 0xC800000, CE SPI 358-369, MSA 0x53300000 2 MiB; WLFW through modem | Q trinket.dtsi:2958 | WCN39xx via modem | **CE base/IRQs, MSA address** |
| Modem | MPSS PAS 4 at 0x6080000, region 0x4b000000 (0x7e00000); GLINK modem SPI 68 mbox 12; APCS 0x0F111000 | Q trinket.dtsi:1137, 1543 | similar | **regions, IRQs, mbox bits** |
| Bluetooth | WCN3990 over QUP1 SE9 HS-UART 0x4c90000, SPI 312, GPIO 10-13; supplies L9/L17/L23/L16 (PM6125); fw in `bluetooth` partition | Q trinket.dtsi:2048, trinket-qupv3.dtsi:252 | none | **new driver**: GENI UART + QCA HCI + IOBluetooth glue |
| Audio | ADSP PAS 1 @0xab00000, region 0x55300000 (0x2200000); Bolero rx 0x0a440000, tx 0x0a460000, wsa 0x0a480000, va 0x0a4a0000; WCD937x (reset GPIO 120); speaker MAX98927 @0x3a on QUP0 SE1 I2C 0x04a84000 (reset GPIO 95), SEC_MI2S GPIO 125-128 | Q trinket-audio-overlay.dtsi, X audio.dtsi | ADSP + own codec | **codec + amp differ** |
| Vibration | PMI632 LDO vibrator (ERM) `qcom,qpnp-vibrator-ldo`, SID 3, base 0x5700, 3.0 V | Q pmi632.dtsi:412 | none | **new driver**: SPMI write + iOS haptics glue |
| PMICs | SPMI arb core 0x1c40000, chnls 0x1e00000, obsrvr 0x3e00000, intr 0x3f00000, cnfg 0x1c0a000; PM6125 SID 0/1, PMI632 SID 2/3 | Q trinket.dtsi:1948 | check | verify SIDs |
| Charger/gauge | PMI632 smb5 0x1000-0x1600, QG 0x4800; SMB1355 parallel | Q pmi632.dtsi:187-378 | check | verify 0091/0148 |
| USB | DWC3 0x4e00000, SPI 255, QUSB2 PHY 0x1613000; high-speed only | Q trinket-usb.dtsi | check | verify |
| UFS | 0x4804000, SPI 356, PHY 0x4807000 | Q trinket.dtsi:937 | same | none |

## Reserved memory (laurel values)

| Region | Base | Size |
| --- | --- | --- |
| hyp | 0x45700000 | 0x600000 |
| xbl_aop | 0x45e00000 | 0x140000 |
| smem | 0x46000000 | 0x200000 |
| removed | 0x46200000 | 0x4900000 |
| pil_modem | 0x4b000000 | 0x7e00000 |
| pil_video | 0x52e00000 | 0x500000 |
| wlan_msa | 0x53300000 | 0x200000 |
| pil_cdsp | 0x53500000 | 0x1e00000 |
| pil_adsp | 0x55300000 | 0x2200000 |
| ipa_fw / ipa_gsi / gpu zap | 0x57500000 / 0x57510000 / 0x57515000 | 0x10000 / 0x5000 / 0x2000 |
| cont_splash / dfps | 0x5c000000 / 0x5cf00000 | 0xf00000 / 0x100000 |
| qseecom / cdsp_sec | 0x5e400000 / 0x5f800000 | 0x1400000 / 0x1e00000 |
| ramoops / wt_share_mem | 0x61600000 / 0x62000000 | 0x100000 each |

Note: the Xiaomi OSS tree also reserves `camera_region` 0x4ab00000 (0x500000); LOS does not.
