# Mi A3: battery, charger, charge-only boot, power off, thermal + cpufreq (area D, patches 2300-2303)

Status 2026-11-01 04:35: built (`scripts/bg.sh areaD-k2303 scripts/laurel/kernel-linux.sh`: 223 patches applied, 0 LSE; kernel sha256 b96061512f0aed39d72a7d00e63a2b3a3a0bc815b9f126eb0f8d537414f8dc28). NOT BOOTED. [V] = read in files / build,
[I] = inference, [U] = unknown until a boot.

## Why the battery reads failed before 2300 [V]

`SWEET BATTERY: SPMI arb=0x50010000 APIDs=256` came from patch 2018 (trinket arbiter bases). The battery stayed
`static fallback, 100% 4200mV` for three reasons, all in topaz/sweet code:

1. `SweetBattery::poll()` read SPMI only when `fReal` was false, but the SPMI result was `valid = fReal && ...`:
   dead code. With `fReal` true (`sweet_i2c1_init()` works: `SWEET I2C1: SE1 ready`) it called `pollTopaz()`,
   which reads the SM5602 gauge (0x71) and the bq2589x charger (0x6a) on QUP0 SE1 I2C. The Mi A3 has neither
   chip (its SE1 bus holds the MAX98927 amp and the SMB1355), so every read failed -> static fallback.
2. `sweet_spmi_read()` accepted SID 0 only (the PM6150 of sweet). The Mi A3 gauge and charger are in the PMI632
   at SID 2 (`pmi632.dtsi` `qcom,pmi632@2`): PPID 0x248 (QG), 0x210-0x216 (SMB5) were never looked up.
3. The register use was PM6150-only (type checks, SID 0 addresses).

The arbiter path itself works (v5: APID map core 0x900 + 4n, owner cnfg 0x700 + 4n, observer EE 0 at 0x80 * APID,
rw channel 0x10000 * APID; `SWEET KEYS` and the 2018 PON lane use it).

## Patches

| Patch | What |
| --- | --- |
| 2300 | `sweet_spmi.c`: PMI632 SID 2 reads (PON 0x08, SMB5 0x10-0x16, VADC 0x31, QG 0x48, SDAM 0xb1); `sweet_spmi_owner()`; `sweet_spmi_write()` (EE 0 APIDs only, allowlist: CHGR FCC 0x1061 / FV 0x1070, USBIN 0x1342/0x1365/0x1366/0x1370, VADC 0x3142-0x3147, SDAM 0xb1a8-0xb1af) |
| 2301 | new `bsd/dev/laurel_pmi632.c` + `.h`: gauge, NTC, SoC model, SDAM save, SMB5 charger loop + JEITA; `SweetBattery.cpp` uses it and publishes the negroni 0271/0365 key set |
| 2302 | charge-only boot (hook at the start of `load_init_program`), power off sets PS_HOLD type SHUTDOWN before PSCI SYSTEM_OFF |
| 2303 | new `bsd/dev/laurel_thermal.c`: OSM cpufreq governor (Silver + Gold) + TSENS caps; replaces the topaz 0094 Gold pin |

## Registers (PMI632 SID 2) [V source]

| Block | Base | Registers used | Source |
| --- | --- | --- | --- |
| QG | 0x4800 | type 0x04 = 0x0d, subtype 0x05 (3 = 5 A, 4 = 10 A), STATUS1 0x08 bit 0 battery, S7 PON OCV 0x70, LAST_ADC_V 0xc0 (194.637 uV/LSB), LAST_BURST_AVG_I 0xc6 (152.588 / 305.176 uA/LSB, + = discharge) | qg-reg.h, qg-defs.h, qg-util.c |
| QG SDAM | 0xb100 | Linux: valid 0x46, soc 0x47, cycle buckets 0x58 (8 x u16), learned capacity 0x68 (mAh). Ours: 0xa8-0xae `'L' 0x23 soc frac tempL tempH xor` | qg-reg.h, qpnp-qg.c |
| VADC | 0x3100 | ADC5 user: DIG_PARAM 0x42 = ratiometric/dec 2, CH_SEL 0x44 = 0x4a (BAT_THERM_PU2), DELAY 0x45 = 2 (200 us), EN 0x46 bit 7, CONV_REQ 0x47 = 0x80, STATUS1 0x08 (EOC), DATA 0x50/0x51; mV = code * 1875 / 0x70e4; 100k NTC table (lut index 0) | qcom-spmi-adc5.c, qcom-vadc-common.c |
| CHGR | 0x1000 | STATUS_1 0x06 [2:0] (1-4 charging, 5 terminated), STATUS_2 0x07, STATUS_7 0x0d (temp), FCC 0x61 (50 mA), FV 0x70 (3600 + 10 mV) | smb5-reg.h, qpnp-smb5.c pmi632 params |
| DCDC | 0x1100 | ICL_STATUS 0x07 (50 mA), POWER_PATH 0x0b bit 0 valid input | smb5-reg.h |
| USBIN | 0x1300 | APSD_STATUS 0x07, APSD_RESULT 0x08, INT_RT_STS 0x10 bit 4 plug-in, CMD_ICL_OVERRIDE 0x42, LOAD_CFG 0x65, ICL_OPTIONS 0x66, CURRENT_LIMIT_CFG 0x70 | smb5-reg.h, smb5-lib.c |
| TYPEC | 0x1500 | SNK_STATUS 0x06 (Rp 3.0 bit 1, 1.5 bit 2) | smb5-reg.h |

PM6125 PON (SID 0, GEN2 subtype 4, via the 2018 lane): PON_REASON1 0x8c0, WARM_RESET_REASON1 0x8c2, INT_RT_STS 0x810
bit 0 = power key, PS_HOLD_RST_CTL 0x85a (type: 1 warm, 4 shutdown, 7 hard), RST_CTL2 0x85b bit 7 enable
(qpnp-power-on.c PON_OFFSET, qpnp_pon_reset_config).

## Battery (2301)

- Self-check: QG type 0x0d, battery present, vbat 2800-4600 mV; else `LAUREL BATTERY: off: <reason>` and the
  static fallback stays. Kill switch `laurelbatt=0`; `sweetbattery=0` = static fallback as before.
- SoC [I design]: the Linux QG computes the SoC in software with the battery profile; we use
  - start: our SDAM record, else the Linux QG SDAM SoC (valid = 1). After a warm reset (0x8c2 != 0) the saved value;
    after a cold start the saved value only within 10 % of the PON OCV SoC (QG S7, measured before the load),
    else the PON OCV SoC (Sunwoda pc-temp-v1-lut, 25 C column); no OCV: saved value, else the vbat curve.
  - run: coulomb count of the burst-average current over the learned capacity (SDAM 0x68 if 3000-4600 mAh, else
    4000 mAh); at rest (|I| < 30 mA, 3 samples, on battery) a drift > 5 % to the OCV SoC moves 1 % per sample;
    charger `terminated` with the charger in = 100 %, held while plugged; 99 % at most while charging otherwise;
    never below 1 % until vbat < 3300 mV for 3 samples on battery, then 0 % and `AtCriticalLevel` (iOS shuts down).
  - save: our record once a minute when the percentage changed (SDAM APID owned by EE 0; else `save off`).
- Temperature: ADC5 BAT_THERM_PU2 every poll (VADC APID owned by EE 0 and a first conversion works), else 25.0 C
  fixed (`SweetBatteryTemperatureEstimated` true).
- Published keys: CurrentCapacity/MaxCapacity (mAh), IsCharging, FullyCharged, ExternalConnected,
  ExternalChargeCapable, AtWarnLevel (<= 10 % on battery), AtCriticalLevel, Voltage, Amperage, InstantAmperage,
  Temperature (0.01 C), CycleCount (Linux QG buckets / 8), TimeRemaining, AvgTimeToFull/Empty, InstantTimeToEmpty,
  AdapterDetails (AdapterVoltage 5000, Current = ICL status, Watts, Source 0, FamilyCode: DCP/QC
  0xe0004004, CDP 0xe0004005, SDP 0xe0004000, SDP with Type-C Rp 0xe0004009, other 0xe0004007, IsWireless false),
  DesignCapacity 4030, NominalChargeCapacity, AppleRaw*, LaurelBatterySOCSource, LaurelChargerIcl/Fcc/Fv.

## Charger (2301) [V source, I policy]

- HLOS owns SMB5 on Android 4.14 (qpnp-smb5 writes it), so the ownership table should give CHGR/USBIN to EE 0
  [U until boot]. Self-check: owner EE 0 for 0x210 and 0x213, FV read + write-back; else
  `LAUREL CHARGER: off: ...` (reads stay; the hardware keeps charging on its boot defaults).
- Input limit (charger in): APSD DCP/QC 2000 mA, float 1000, CDP 1500, SDP: Type-C Rp 3.0 A -> 2000, 1.5 A -> 1500,
  else the hardware's 500 mA; written as smb5-lib SW_OVERRIDE_HC_MODE (ICL_OPTIONS bit 0, no ICL override,
  LOAD_CFG bit 4). AICL stays on (weak adapters). DT: `qcom,usb-icl-ua = 2000000`, `fcc-max-ua = 3000000`,
  `fv-max-uv = 4400000`.
- JEITA (software, NTC): < 0 C 0 mA, 0-10 C 400, 10-15 C 1200, 15-44 C 3000 (FV 4400), 44-58 C 1500 at 4100 mV,
  >= 58 C 0; to more current only 1.5 C inside the zone. The battery DT (`jeita-fv-ranges`, hard 0/60 C) gives
  the FV split and the limits; the FCC split is ours [I]. The hardware JEITA (hard limits) stays on.
- Every write is read back; one failure -> `LAUREL CHARGER: off: SMB5 write failed ...`.
- SMB1355 parallel charger (QUP0 SE1 I2C, IRQ GPIO 130): not driven. The PMI632 charges alone (3 A max FCC; Linux
  splits with the SMB1355 for more). [I] Enough for 10 W adapters.
- Line on every change: `LAUREL CHARGER: on: SMB5 usbin apsd 0x.. rp 0x.., T C zone Z: ICL N mA, FCC N mA, FV N mV, charging`.

## Charge-only boot and power off (2302)

- What ABL does on a charger insert while off [I]: the PMIC powers on with PON reason USB_CHG (or CBL/DC; on this
  board the PM6125 may report PON1 = "triggered by the secondary PMIC" and the PMI632 the charger reason). ABL then
  either shows its own charger screen (off-mode charge setting) or boots the active slot with
  `androidboot.mode=charger`. Slot B holds our UEFI image, so Mu -> UniXNU -> DarwinBoot -> XNU starts; DarwinBoot
  does not pass the Android command line on, so the kernel decides from the PON registers. [U] Which reason bits
  this phone sets on a cable power-on; the first test prints them (`pon 0x.. warm 0x.. pmi 0x..`).
- Rule: cold (0x8c2 = 0), PON_REASON1 has USB_CHG/CBL/DC (or PON1 + a PMI632 charger reason), and none of
  HARD_RESET/SMPL/RTC/KPD, and the charger is in -> charge mode. Else `LAUREL CHARGE MODE: on: normal boot (...)`.
- Charge mode: before launchd; a console line every 10 s (`LAUREL CHARGE MODE: battery N% charging, mV mA C`);
  the charger loop runs (SweetBattery 10 s poll). Power key -> boot iOS; charger out 3 s -> power off.
- Power off (2003 + 2302): PM6125 PS_HOLD_RST_CTL type 4 (SHUTDOWN) before PSCI SYSTEM_OFF, as Linux does for a
  shutdown. Before, the type was whatever XBL/ABL left (2018 sets warm reset only for reboots with a reason) [I]:
  a hard-reset type turns the PS_HOLD drop into a reboot. Line: `LAUREL REBOOT: PS_HOLD_RST_CTL 0x.. -> 0x..4 (shutdown)`.
- [U] Whether a power off with the charger in powers on again (cable PON trigger level vs edge). If it does, the
  next boot is a charge-mode boot (cold, charger reason), which is the wanted result.

## Thermal + cpufreq (2303) [V source]

- OSM (not cpufreq-hw): `qcom,clk-cpu-osm-trinket`, pwrcl 0xf521000 (Silver), perfcl 0xf523000 (Gold); LUT 0x110 +
  32 * row, 12 rows; perf state 0x920. topaz 0094 used the same Gold offsets (`CPUFREQ gold 0->7 (2016 MHz)` on the Mi A3).
- Governor (100 ms): busiest core per cluster over 300 ms; > 90 % -> cap, > 70 % -> +1 row, < 30 % for 300 ms -> -1
  row; floor = ABL row (Gold: row 0 = 300 MHz, from the topaz line "gold 0->7").
- TSENS v2 at 0x4411000: SN_STATUS 0xa0 + 4n, sensors 6-8 Silver cpuss, 9-12 Gold, 15 GPU. Caps: >= 95 C Gold -1
  row/s, >= 105 C Silver too, < 85 C +1 row / 2 s. Linux DT trips: 110 C passive.
- Lines: `LAUREL CPUFREQ: on: OSM governor, silver rows a..b (MHz..MHz), gold rows ...`, `LAUREL THERMAL: on: TSENS
  cpu N C gpu N C ...`, `LAUREL THERMAL: on|cap: cpu .. | silver N MHz (busy %, cap) gold ...` (a minute / on change).

## Expected lines on the next boot

```
SWEET BATTERY: SPMI arb=0x50010000 APIDs=256, observer reads; PON APID 112 rw lane mapped
LAUREL CHARGER: on: SMB5 owner EE 0, boot FCC N mA FV N mV; JEITA zones, ICL from APSD
LAUREL BATTERY: on: PMI632 QG soc N% (src; pon-ocv N mV) vbat N mV temp N.N C cap N mAh cycles N; pon 0x.. warm 0x.. pmi 0x..; save on
LAUREL CPUFREQ: on: OSM governor, ...
LAUREL THERMAL: on: TSENS cpu N C gpu N C; ...
SWEET BATTERY: PMI632 QG, N% NmV external=1 charging=1
LAUREL CHARGER: on: SMB5 usbin apsd 0x.. rp 0x.., N.N C zone 3: ICL N mA, FCC 3000 mA, FV 4400 mV, charging
LAUREL CHARGE MODE: on: normal boot (pon 0x.. warm 0x.. pmi 0x.. charger 1)
```
The battery/charger/cpufreq lines come before the USB log starts (early lines are not in the live USB log yet):
read them on the panel photo or with `scripts/laurel/log-pull.sh`. The 5-minute `LAUREL BATTERY: on: ... soc N%
vbat N mV ibat N mA temp N` line and the `LAUREL CHARGER` change lines come later and are in the USB log.

## Risks

- [U] SMB5/VADC/SDAM ownership: if not EE 0, the charger/temperature/save turn off (reads stay).
- [I] SoC is a model, not the Linux QG: errors of several % (no ESR, no temperature-dependent capacity).
- [I] The charge-mode rule depends on the PON reason bits; a wrong rule either boots iOS (safe) or holds in charge
  mode until the power key (also safe: power key boots iOS; `laurelchgmode=0` turns it off).
- [I] The PON APID is also polled by the `SWEET KEYS` thread; our PON reads take two agreeing reads.
- [I] Silver/Gold rows below what topaz used: the OSM handles the voltage (CPR) in hardware, as under Linux.
