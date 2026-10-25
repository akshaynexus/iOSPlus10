# Battery level and charging state (patches 0270-0271)

Status 2026-10-25: finished, read-only by default, full local build (section 4). Not run on the phone yet.

Marks: **[V]** seen in source, DT, firmware, build or log. **[I]** inference.

| Patch | Files | What |
|---|---|---|
| `0270-negroni-battery-spmi-v7.patch` | `bsd/dev/negroni_spmi.c`, `.h`, `bsd/dev/negroni_rtc.c` | one shared SPMI arbiter v7 mapping (RTC of 0203 + battery), the battery's read allowlist (reads with `sk_read8` of `negroni_spmi_keys.h`), the opt-in VADC write path |
| `0271-negroni-battery-service.patch` | `iokit/Kernel/arm/NegroniBattery.cpp`, `iokit/KernelConfigTables.cpp` | the IOPMPowerSource (AppleSmartBattery key set) and its personality on IOResources |

## 1. Why iOS showed a wrong battery level

1. The base tree compiles `NegroniBattery`, but slop patch 0089 ("... no NegroniBattery") removed its
   personality from `iokit/KernelConfigTables.cpp`. No IOPMPowerSource exists, so powerd has no
   internal battery and the status bar shows an empty battery [V: `KernelConfigTables.cpp` of `base`;
   slop `0089-negroni-ufs-power-no-battery.patch`; the same empty/red icon in slop NOTES:125,133 before
   their battery service].
2. The class itself is the sweet (SM6150 + PM6150) driver, copied unchanged [V: slop 0062]:
   - It reads SID 0 peripherals 0x10/0x11/0x13/0x48 as PM6150 SCHG/QG. On SM8450, SID 0 is the
     PMK8350: 0x1300 is its PON block (the power/volume keys, `negroni_keys.c`), and there is no QG
     at 0x4800 [V: live DT `pon_hlos@1300`].
   - `negroni_spmi.c` used the sweet arbiter v5 addresses (core 0x0c440000, which is the v7
     observer here; observer 0x0e600000; cnfg 0x0c40a000) and rejected every arbiter version
     >= 0x70000000. SM8450 has v7 [V: live DT `qcom,spmi@c42d000` regs; `negroni_keys.c`].
   - Result with `negronibattery=1`: SPMI init fails, the service publishes the static fallback
     (100 %, on AC). Without the boot-arg: the same static values.
   - It published `CurrentCapacity` in mAh (5020 of 5020). iOS readers that take
     `CurrentCapacity` as a percentage show the wrong number (bergamota found "5020" in
     BatteryCenter, fixed in its 0130) [V: bergamota `0130-beryllium-battery-ios-capacity.patch`].

## 2. Where the battery data is on SM8450 (no ADSP)

The phone has a 2S battery (two cells in series, 5000 mAh) [V: DT `qcom,vbatt_num = <2>`,
`qcom,batt_capacity_mah = <0x1388>`; OnePlus `oplus_battery_sm8450.c` sets
`DOUBLE_SERIES_WOUND_CELLS`]. The **fuel gauge is an external gauge IC that the ADSP reads** [V: DT
`qcom,battery_charger` has `qcom,external_gauge`, `qcom,fg_info_package_read_support`,
`oplus,chg_ops = "plat-pmic"`, `qcom,voocphy_support = <1>`; there is **no I2C gauge node** in
`out/live.dts`: none of the gauge compatibles in the stock `oplus_chg.ko`/`oplus_chg_v2.ko`
(`oplus,bq27541-battery`, bq28z610, zy0602/zy0603, sh366002, nfg8011b, `cellwise,cw2217`) is in the
DT]. The OnePlus source (OnePlusOSS `android_kernel_modules_and_devicetree_oneplus_sm8450`, branch
`oneplus/sm8450_v_15.0.0_oneplus_10_pro`, `vendor/oplus/kernel/charger/charger_ic/oplus_battery_sm8450.c`)
reads SoC, voltage, current and temperature of this gauge only through the ADSP (section 6) [V].
The gauge bus is not in the HLOS DT, so its address and bus are unknown [I: ADSP-owned bus].

What the application processor can reach without the ADSP: the **PMK8350 VADC** (ADC7), SID 0,
peripheral 0x31 (`vadc@3100`, compatible `qcom,spmi-adc7`). It measures channels of other PMICs:
virtual channel = SID << 8 | channel [V: DT, Linux `qcom-spmi-adc5.c`].

| Quantity | Channel | Pre-scaling | Source |
|---|---|---|---|
| Battery voltage | 0x38f `pm8350b_vbat_sns` | 1/3 | DT [V] |
| System rail | 0x38e `pm8350b_vph_pwr` | 1/3 | DT [V] |
| 2S midpoint | 0x396 `ADC7_VBAT_2S_MID` | unknown (logged with 1/3) | Linux `qcom,spmi-adc7-pm8350b.h` [V], not in DT |
| USBIN (VBUS) | 0x311 `pm8350b_usb_in_v_div_16` | 1/16 | DT [V] |
| Charge current | 0x3a1 `pm8350b_ichg_fb` | 1000/305185 (result in uA) | DT [V], unit [I] |
| Input current | 0x317 `pm8350b_iin_fb` | 32/100 (result in uA) | DT [V], unit [I] |
| Charger die temp | 0x310 `pm8350b_chg_temp` | 1/1 | DT [V] (not used) |
| Skin temperature | 0x146 `pm8350_hot_pocket_therm` | ratiometric, 100 k, 200 us | DT; OPLUS `oplus,skin_temp_chan` [V] |
| Battery NTC | none | | not an ADC7 HLOS channel; the gauge has it [I] |

ADC7 conversion (Linux `adc7_configure` / `adc7_do_conversion`), registers at 0x3100 + offset:
`0x40` APP_SID bits 3:0 = SID of the measured PMIC; `0x42` DIG_PARAM (bit 6 cal value 0 = timer,
bits 5:4 cal select 1 ratiometric / 2 absolute, bits 3:2 decimation 2); `0x43` FAST_AVG bits 2:0;
`0x44` channel; `0x45` bits 3:0 hw settle; `0x47` CONV_REQ = 0x80; `0x08` STATUS1 (bit 0 EOC,
bit 1 REQ_STS, bit 7 CONV_FAULT); result `0x50`/`0x51`, 0x8000 = invalid. Volts:
`code * 1.875 V / 0x70e4 * den / num`. Ratiometric: `R = code * 100k / (16384 - code)`, then the
`adcmap7_100k` table [V: `qcom-spmi-adc5.c`, `qcom-vadc-common.c`].

Why the voltage is a per-cell value [I]: with 1/3 the ADC (0..1.875 V) reads at most 5.6 V, so it
cannot see a 2S pack (6-9 V) at 1/3. Either the PMIC VBAT pin is on the 1S side of the 2:1 divider
(pack / 2), or the hardware divider is 1/6 (upstream `adc7_chans_pmic` uses index 3 = 1/6) on the
pack. In both cases the 1/3 calculation gives pack / 2 = the mean cell voltage. The first log
(`negronibatt=2`, `vph` and `mid2s`) shows which one.

Other sources that were checked and are not usable without the ADSP:
- PM8350B charger (SCHG), QBG and their SDAMs: owned by the ADSP charger PD; the HLOS DT has no node
  and the register map is not public (PM8350B in HLOS DT: temp-alarm 0xa00, PBS 0x1900, BCL 0x4700,
  GPIO 0x8800, haptics 0xf000, AMOLED 0xf800-0xfa00) [V DT]. `negronibatt=2` logs a census of the
  SID 3 APID map (TYPE/SUBTYPE, INT_RT_STS, owner EE) for later work.
- PMK8350 ADC_TM7 (0x3400): monitors board thermistors only (pa3, msm, cam_flash, hot_pocket,
  wide_rfc, usb_conn, wl_chg, xo) [V DT].
- PM8350B BCL (0x4700) is usable read-only: VBAT_READ 0x76 and IBAT_READ 0x86 (downstream
  `bcl_pmic5.c` of the OnePlus SM8450 kernel, fetched later; section 3) [V source]. It is the
  default source of 0271. There is also a PM8350C BCL (SID 2 0x4700) [V DT]; it is not used.
- No battery-related SDAM cell in the HLOS DT (PMK8350 SDAMs: 0x7000-0x9d00, reboot reason, LPG,
  haptics, AMOLED ECM, PON log) [V DT].

## 3. What the patches do

**0270** (`bsd/dev/negroni_spmi.c`):
- `negroni_spmi_arbiter()` maps the arbiter once: core 0x0c400000 (0x3000), EE 0 observer
  0x0c440000 (0x8000 = 1024 APIDs x 0x20), cnfg (owner table) 0x0c42d000 (0x1000). The RTC
  (`negroni_rtc.c`, patch 0203) now takes its mapping from this call instead of three own
  `ml_io_map` calls, so the RTC and the battery share one mapping. Nothing is ever unmapped
  (io_submap entries are permanent, see docs/notes.md "io_submap") [V: source].
- Reads: `sk_read8()` of `negroni_spmi_keys.h` (the keys/RTC code: EXT_READL on the observer
  channel, at most SK_POLLS = 100000 status reads). A timed-out APID is not used again this boot.
  Read allowlist: SID 3 0x47xx (PM8350B BCL), SID 0 0x31xx (PMK8350 VADC), SID 3 offsets
  0x04/0x05/0x10 (TYPE/SUBTYPE/INT_RT_STS, census only). No other driver reads a SID 3 APID or
  0x031 (keys 0x013/0x18d, reboot 0x071/0x008, RTC 0x061), so no observer channel is shared [V: grep of
  all patches].
- Writes: locked. Only `negroni_spmi_vadc_unlock()` (boot-arg modes 4/5) opens SID 0
  0x3140-0x3145 and 0x3147 (ADC7 request registers), and only if the owner table gives that APID
  to EE 0; then one 0x1000 channel window (chnls 0x0c500000 + 0x1000 x APID) is mapped. Each write
  waits at most 2000 x 1 us. 0x3146 (EN_CTL1), charger, fuel gauge, BCL, interrupt and enable
  registers are never written [V: source].

**0271** (`NegroniBattery.cpp` + personality on IOResources): every 20 s (IOTimerEventSource on its
own work loop):
- Default (`negronibatt=1`), **read only**: PM8350B BCL (SID 3 0x4700, DT `bcl@4700`
  "qcom,bcl-v5", downstream `bcl_pmic5.c`): 0x46 MONITOR_EN (bit 7), 0x72 VBAT_CONV_REQ,
  0x76 VBAT_READ (49.827 mV/bit, 0x7f = no reading), 0x86 IBAT_READ (s8, 78.127 mA/bit with the
  default range factor 10, + = discharge; 0 = no new reading, so only non-zero samples are
  averaged) [V: `down-bcl_pmic5.c`]. 8 samples, 1 ms apart (IOSleep). The values are used only when
  MONITOR_EN bit 7 is set (Linux sets it at probe; this driver never writes it). A VBAT value above
  5000 mV is taken as the 2S pack and halved [I].
- `negronibatt=4/5` add the PMK8350 VADC conversions (VBAT 0x38f, USBIN 0x311, ichg 0x3a1, iin
  0x317, skin therm 0x146; section 2).
- `ExternalConnected`: VBUS >= 4000 mV when the VADC measures it; else the battery current
  direction with hysteresis (>= +50 mA charging = on a charger, <= -50 mA = on battery).
- SoC estimate: OCV curve for a 4.45 V class cell (3300 mV = 0 %, 4400 mV = 100 %), IR compensation
  (80 mOhm, max 150 mV), coulomb counting of the battery current (5000 mAh, 1S equivalent), a slow
  pull toward the voltage value, never up on battery, never down on a charger, at most 1 %/min down
  beyond the coulomb count, first value directly from the voltage. 0 % only after 5 polls below
  3300 mV on battery; else at least 1 %.
- `IsCharging` = on a charger, not full and current > 50 mA (current unknown: percent < 100).
  `FullyCharged` = on a charger, 100 % and current < 150 mA.
- No voltage at all (monitor off, VADC off): the static fallback (100 %, on AC, not charging) until
  a measurement arrives; after 3 failed polls one line says why.
- Keys (all checked against the strings of 20H392 `powerd`, which matches `IOPMPowerSource`):
  `CurrentCapacity` (percent), `MaxCapacity` 100, `BatteryInstalled`, `ExternalConnected`,
  `ExternalChargeCapable`, `IsCharging`, `FullyCharged`, `Voltage` (mV, mean cell), `Amperage`,
  `InstantAmperage` (mA, + = charging), `Temperature` (hundredths of a degree; VADC skin value
  clamped to 0-45 C, else 25.00 C), `CycleCount` 0, `DesignCapacity`/`NominalChargeCapacity`/
  `AppleRawMaxCapacity` 5000, `AppleRawCurrentCapacity`, `AppleRawBatteryVoltage`,
  `AppleRawExternalConnected`, `TimeRemaining`/`AvgTimeToEmpty`/`AvgTimeToFull`/`InstantTimeToEmpty`
  0xffff, `DesignCycleCount9C`, `PermanentFailureStatus` 0, `BatteryCellDisconnectCount` 0,
  `built-in`, `CapacityEstimated`, `BatteryData`, `AdapterDetails` (FamilyCode 0 unplugged,
  0xe0004007 USB plugged), the legacy battery-info dictionary, `AtCriticalLevel` false (an
  estimate must not shut iOS down), and `NegroniBattery*` diagnostics (source, BCL monitor,
  current valid, ...). `updateStatus()` after each poll sends the change message [V: source,
  `strings powerd`].
- Log (prefix `NEGRONI BATTERY:`): the arbiter/APID line, the mode line with BCL TYPE/SUBTYPE,
  MONITOR_EN and VBAT_CONV_REQ, then one line per change of percent / external / charging / full:
  `NEGRONI BATTERY: 57% 3891mV -420mA 25.00C external=0 charging=0 full=0 source=PM8350B BCL usbin=0mV`.

Boot-arg `negronibatt`: `0` no power source (the kernel before this patch), `1` read-only BCL
estimate (default), `2` = 1 + a raw line per poll + a one-time SID 3 census + a line per change of a
SID 3 INT_RT_STS (plug a cable to find the USBIN peripheral), `3` static 100 % on AC (no PMIC
access), `4` = 1 + VADC conversions (writes the ADC7 request registers), `5` = 4 + the diagnostics
of 2. The default is on because it is read only and every SPMI access has a time-out.

## 4. Verification

- [V] `scripts/kernel/compile-one.sh` OK for `negroni_spmi.c` and `negroni_rtc.c`;
  `NegroniBattery.cpp` with its clang++ line of build.log: no diagnostic in the file (2026-10-25).
- [V] Both patches apply with `git apply --check` on a `patched-tree.sh` tree of all patches up to
  0261 + 0213 (all 24 02xx applied, 2026-10-25).
- [V] Full build 2026-10-25 (`scripts/bg.sh kernel-battery scripts/kernel/build-local.sh`): exit 0,
  `out/kernel/local-20261025-130140/kernel.development.negroni` (sha256 f5c01805913a5ed4...), all 27
  patches/xnu applied (0200-0261, 0270, 0271, 0290), only the 4 usual dxb skips; the battery and RTC
  log strings and the NegroniBattery personality are in the kernel (`logs/kernel-battery.log`).
- On the phone (not done): boot with `negronibatt=2`, capture `make usblog`, and check:
  1. `SPMI arbiter 0x7...`, the BCL APID, `MONITOR_EN` (bit 7 = 0x80 needed for the default mode)
     and `VBAT_CONV_REQ` (non-zero needed for VBAT). If MONITOR_EN is 0, the default mode shows the
     static 100 %: boot `negronibatt=5` to measure with the VADC.
  2. `raw bcl ... vbat` 3300-4450 mV (`pack/2` shows that the register gave the pack) and close to
     Android's value at the same charge (`cat /sys/class/power_supply/battery/voltage_now`).
  3. `ibat`: negative (discharge) on battery; plug a charger: positive, `external` goes to 1.
     The `rt_sts` lines while plugging show which PM8350B peripheral reports USBIN.
  4. The RTC line `NEGRONI RTC: PMK8350 RTC APID ...` still appears (shared mapping).
  5. Status bar and Settings > Battery show the percent; compare with Android after the same rest
     time; tune `kOcv` / `NB_R_MOHM`.

## 5. Risks

- The default mode makes only observer reads. Modes 4/5 write the ADC7 request registers of the
  HLOS VADC (what Android does all the time); if the ADSP later uses the same VADC user peripheral,
  requests can collide [I]. `negronibatt=3` (no PMIC access) or `0` rules the driver out.
- The BCL may be off (nobody sets MONITOR_EN without Linux): then the default mode shows the static
  100 % [I].
- The SoC is an estimate: VBAT has 50 mV steps (about 5 % of the curve), load sag reads low, the
  curve is not this cell's profile. Expect +-10 % [I].
- Which node the BCL VBAT/IBAT sees on the 2S pack (1S side of the 2:1 divider or the pack) is not
  verified; the coulomb count assumes 1S-side current and 5000 mAh [I].
- Charging without the ADSP: the PM8350B charger runs on its hardware/XBL defaults; nothing
  configures it (no OPLUS JEITA, no SuperVOOC). `ibat` shows whether it charges at all [I].
- Temperature is 25.00 C in the read-only mode (no read-only source of the cell temperature; the
  ADC_TM7 results need a configured monitor) [I]; the VADC modes use the skin thermistor.
- A timed-out SPMI read disables only that APID; a hung MMIO access (no arbiter answer at all on
  the bus) cannot be timed out in software [I].

## 6. Later: exact values from the ADSP (battmgr over GLINK)

After the audio ADSP work (patch 0240 starts the ADSP; HackiOS `redwood_adsp.c` has a GLINK + battmgr
client to copy), the exact gauge values come from the charger PD:
- Transport: GLINK edge to the ADSP (remote pid 2, IPCC client 3 signal 0), channel
  `PMIC_RTR_ADSP_APPS` (opened by the ADSP); protection domain `msm/adsp/charger_pd`
  (`tms/servreg`) [V: DT `qcom,pmic_glink`; audio-plan.md].
- Header `struct pmic_glink_hdr { le32 owner = 32778 (MSG_OWNER_BC); le32 type = 1 request/answer,
  2 notify; le32 opcode; }` [V: Linux `qcom_battmgr.c`, OnePlus `oplus_battery_sm8450.h`].
- Property get: opcode `0x30` battery / `0x32` USB / `0x34` wireless, body `{battery_id 0,
  property_id, value 0}`; answer `{property_id, value, ret_code 0}`. Properties on this phone
  (OnePlus enum = upstream sm8350 up to 23): 0 STATUS (1 charging, 2 discharging, 3 not charging,
  4 full), 1 HEALTH, 2 PRESENT, 3 CHG_TYPE, **4 CAPACITY (hundredths of a percent)**, 5 SOH,
  6 VOLT_OCV, 7 VOLT_NOW (uV), 8 VOLT_MAX, 9 CURR_NOW (uA), 12 TEMP, 14 CHG_COUNTER (uAh),
  15 CYCLE_COUNT, 16 CHG_FULL_DESIGN, 17 CHG_FULL, 19 TTF_AVG, 20 TTE_AVG, 22 POWER_NOW; USB: 0 ONLINE,
  1 VOLT_NOW, 3 CURR_NOW, 5 INPUT_CURR_LIMIT, 6 USB_TYPE, 7 ADAP_TYPE. HackiOS saw TEMP at 13 on a
  different firmware: dump all properties once (`battmgr=2` style) before trusting the numbers.
- OPLUS gauge package (what OxygenOS uses on this phone, because `voocphy_support` = ADSP VOOCPHY):
  [I: value 1 = ADSP_VOOCPHY not checked in the enum] opcode `0x10000` (OEM_OPCODE_READ_BUFFER), body `{data_size = 512}`; answer `{u32 data[128];
  u32 data_size}`: data[0] temperature (0.1 C), [1] current (uA), [2] voltage (uV), **[3] SoC
  (hundredths of a percent)**, [4] remaining capacity (mAh per cell, x2 for the pack), [5] cycle
  count, [6] full charge capacity, [7] cc, [8] SoH, ... [V: `oplus_battery_sm8450.c`
  `handle_oem_read_buffer`, `fg_bq27541_get_battery_soc`].
- Notifications: `0x04` BC_SET_NOTIFY_REQ to subscribe, `0x07` BC_NOTIFY_IND (0x30/0x32/0x80
  events). Send gets only: no set (0x31/0x33), no ship mode (0x36), no charge limits (0x48).
- Integration: feed the values into `NegroniBattery` (a C entry like HackiOS
  `RedwoodBatteryReport`) and keep the ADC estimate as the fallback while the channel is closed.
- A running ADSP starts the charger PD: OPLUS JEITA / fast charging policy then comes from the
  firmware, not from iOS [I].

## 7. Integration notes

- Apply order: after the slop patches and 0200-0261 (name order). 0270 changes the 0203 file
  `negroni_rtc.c` (one include, the mapping call): a changed 0203 may need a refresh of 0270.
  `bsd/conf/files` is unchanged (`negroni_spmi.c` is already listed).
- Default on (`negronibatt=1`, read only). Add `negronibatt=2` to the debug image boot-args for the
  first test.
- Not used: the USB driver forces VBUS valid (`negroni_usb.c` UTMI_OTG_VBUS_VALID), so it cannot
  tell a charger; its "configured" state (host enumerated) would be a read-only charger hint for a
  later patch [V: source].
- Reference sources: `scripts/battery/fetch-sources.sh` (Linux upstream, Qualcomm downstream
  `bcl_pmic5.c`, OnePlus official) into `out/research/battery/` (git-ignored).
