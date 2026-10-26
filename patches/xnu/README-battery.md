# Battery level and charging state (patches 0270-0271)

Status 2026-10-26: 0270/0271 run on the phone (BCL values, docs/notes.md "Battery"); 0272 (charger input, section 7) built, not run.

Marks: **[V]** seen in source, DT, firmware, build or log. **[I]** inference.

| Patch | Files | What |
|---|---|---|
| `0270-negroni-battery-spmi-v7.patch` | `bsd/dev/negroni_spmi.c`, `.h`, `bsd/dev/negroni_rtc.c` | one shared SPMI arbiter v7 mapping (RTC of 0203 + battery), the battery's read allowlist (reads with `sk_read8` of `negroni_spmi_keys.h`), the opt-in VADC write path |
| `0271-negroni-battery-service.patch` | `iokit/Kernel/arm/NegroniBattery.cpp`, `iokit/KernelConfigTables.cpp` | the IOPMPowerSource (AppleSmartBattery key set) and its personality on IOResources |
| `0272-negroni-battery-charger-input.patch` | `bsd/dev/negroni_spmi.c`, `.h`, `iokit/Kernel/arm/NegroniBattery.cpp` | PM8350B SMB5 charger status in the log, USB input enabled at `negronichg_ma` (section 7) |
| `0276-negroni-battery-soc-source.patch` | `iokit/Kernel/arm/NegroniBattery.cpp` | the percentage: source order gauge (not reachable) > GLINK (0274) > OCV estimate with a rate limit; `soc src=` in the log (section 10) |
| `0277-negroni-charger-loop.patch` | `bsd/dev/negroni_chg_glink.c`, `.h` | the Android HLOS charge loop over GLINK: float voltage + FCC per the DT JEITA bands every 5 s, the thermal FCC level, the power hub (section 11) |
| `0278-negroni-battery-persist-temp.patch` | `bsd/dev/negroni_batt_store.c` (new), `bsd/conf/files`, `bsd/dev/negroni_spmi.c`, `.h`, `iokit/Kernel/arm/NegroniBattery.cpp` | the percentage kept across boots, the cell temperature in `Temperature`, skin/XO to the hub, BCL MONITOR_EN, the QDSS vote release (section 12) |
| `0369-negroni-charger-vooc.patch` | `bsd/dev/negroni_chg_glink.c`, `.h` | VOOC/SuperVOOC with the ADSP VOOC PHY: enable policy, PMIC park/un-park, status decode, 0x59 answer, recovery, telemetry (section 15) |
| `0365-negroni-battery-charging-ui.patch` | `iokit/Kernel/arm/NegroniBattery.cpp`, `bsd/dev/negroni_chg_glink.c`, `.h` | IsCharging/FullyCharged/AdapterDetails (Watts, FamilyCode)/Amperage/times for the iOS battery UI, with and without the charger PD (section 13) |

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

## 7. Charger input (0272, 2026-10-26)

Why: on the phone the battery line showed the pack draining with the USB cable in
(`NEGRONI BATTERY: 16% 3687mV -458mA ... external=0 ... usbin=0mV`, 01:31; earlier in the night 68-73 %
with +0..78 mA when `external=1`) [V: logs/usblog.log]. `usbin=0mV` in mode 1 only means "not measured"
(the VADC runs in modes 4/5), so the line alone does not say whether VBUS is there. Nothing in our kernel
configures the PM8350B charger; OxygenOS drives it from the ADSP charger PD, which is off here
(docs/notes.md "Battery"). The DT asks for 500 mA on an SDP and 2000 mA on a charger
(`qcom,input_current_usb_ma = <0x1f4>`, `qcom,input_current_charger_ma = <0x7d0>`) [V: out/live.dts
`qcom,battery_charger`]. Slop 0074 (USB VBUS override) only forces the DWC3 PHY's "VBUS valid" bit; it does
not touch the PMIC [V: negroni_usb.c QSCRATCH_HS_PHY_CTRL].

Register layout [I: the SMB5 family map of downstream `smb5-reg.h` (PM8150B/PM7250B); bergamota's
PMI8998 SMB2 notes (external/bergamota/enxerto/charger.c) agree on every offset used here; PM8350B
itself has no public HLOS charger driver]. SID 3 (the PM8350B, like its BCL 0x4700 and
`qcom,pm8350b-debug@3`):

| Address | Register | Used bits |
|---|---|---|
| 0x1006 | BATTERY_CHARGER_STATUS_1 | [2:0] 0 inhibit 1 trickle 2 precharge 3 fast 4 taper 5 terminated 6 pause 7 disabled |
| 0x1007 | BATTERY_CHARGER_STATUS_2 | logged |
| 0x1042 | CHARGING_ENABLE_CMD | [0] charging enabled |
| 0x1061 / 0x1070 | FAST_CHARGE_CURRENT_CFG / FLOAT_VOLTAGE_CFG | logged, never written |
| 0x1307 / 0x1308 | APSD_STATUS / APSD_RESULT_STATUS | [0] SDP [1] OCP [2] CDP [3] DCP [4] float [5] QC2 [6] QC3 |
| 0x1310 | USBIN_INT_RT_STS | [4] USBIN plugged in |
| 0x1340 | USBIN_CMD_IL | [0] USBIN suspend |
| 0x1342 | USBIN_CMD_ICL_OVERRIDE | [0] take the CFG limit now (SMB5) |
| 0x1365 | USBIN_LOAD_CFG | [4] ICL override after APSD |
| 0x1366 | USBIN_ICL_OPTIONS | [0] USBIN_MODE_CHG (the CFG register sets the limit) |
| 0x1370 | USBIN_CURRENT_LIMIT_CFG | the limit, 50 mA/LSB [I: PM8150B step; `negronichg_step=25` for 25 mA] |
| 0x1380 | USBIN_AICL_OPTIONS_CFG | [2] AICL enabled, logged |
| 0x1506 / 0x150b | TYPE_C_SNK_STATUS / TYPE_C_MISC_STATUS | logged |
| 0x1607 / 0x1608 | ICL_STATUS / AICL_ICL_STATUS | the limit in force, 50 mA/LSB |
| 0x160b | POWER_PATH_STATUS | [6] USBIN suspended [4] using USBIN |

What 0272 does:
- `negroni_spmi.c`: the read allowlist gains SID 3 peripherals 0x10-0x16 (observer reads only).
  `negroni_spmi_chg_unlock(force)` finds the APIDs of SID 3 0x10 (CHGR) and 0x13 (USBIN), logs their
  owner EE, and maps one 4 KiB channel window each (two more io_submap pages). With `force` = 0 an APID
  that another EE owns stays locked (the same rule as the VADC unlock). `negroni_spmi_write` now takes
  the VADC request registers after the VADC unlock and exactly six charger registers after the charger
  unlock: 0x1042, 0x1340, 0x1342, 0x1365, 0x1366, 0x1370. A refused write (arbiter status error bits)
  is logged; a timed-out APID is not used again.
- `NegroniBattery.cpp`: every poll (20 s) reads the 18 registers above (`readCharger`). One line per
  change of state/plug/suspend/limit:
  `NEGRONI BATTERY: charger fast, USBIN plugged: st1 03 st2 .. en 01 fcc .. fv .. apsd ../.. usb_rt 10
  cmd_il 00 load .. icl_opt .. icl_cfg 0a (500 mA) aicl .. typec ../.. | icl_sts 0a (500 mA) aicl_sts ..
  power_path ..` (every poll with `negronibatt=2/5`). The main line gains `chg=<state> icl=<mA> pp=<hex>`.
  `ExternalConnected` now comes from USBIN_INT_RT_STS bit 4 when the registers read.
- Control (`driveCharger`, boot-arg `negronichg_ma`, default 500, 0 = read only, max 3000): with the
  cable in, when USBIN is suspended (0x1340 bit 0 or 0x160b bit 6), charging is disabled (0x1042 bit 0
  clear) or the limit is not ours (0x1370 != ma/step, 0x1366 bit 0 clear, 0x1365 bit 4 clear), it writes
  in the downstream `smblib_set_icl_current()` order: 0x1370 = ma/step, 0x1366 |= 1, 0x1365 |= 0x10,
  0x1342 = 1, 0x1340 &= ~1, then 0x1042 |= 1; each only when the value differs; at most 5 polls per
  plug; then it re-reads 0x1370/0x1340/0x1607/0x160b and logs `charger after set: ...`.
  Boot-args: `negronichg_step` (25 or 50 mA/LSB, default 50), `negronichg_force=1` (write also when
  EE 0 does not own the charger APIDs; the arbiter answers a refusal in the status word, no hang [I]).
- Nothing else changes: no float voltage, no FCC, no JEITA, no Type-C role, no HVDCP.

Phone result 2026-10-26 03:31 (`out/ios16-chg`): `chg=? icl=0mA pp=ff` on every line = not one of the 18
registers read (`fChgSt1` kept its 0xff init value); the boot-time `charger registers: 0 of 18 readable`
and the unlock/owner lines came before the USB console [V: logs/usblog.log 83940+]. The DT confirms the
bus and SID: `qcom,pm8350b@3` is under `qcom,spmi@c42d000` (bus 0, EE 0), and the HLOS node lists only
temp-alarm, PBS, pinctrl, BCL 0x4700, haptics and AMOLED; the charger blocks are not in the HLOS DT. A
second arbiter node `qcom,spmi@c432000` (bus 1, same core/chnls/obsrvr, cnfg 0xc432000) and a
`qcom,spmi-debug@10b14000` (pmic-arb-debug: an EE-independent path, fuse at 0x221c8784) exist [V: live.dts].
So the reads fail for one of: no APID for PPID 0x310-0x316 in the map (XBL maps only the HLOS
peripherals), or an arbiter error (access denied for a non-owner EE). The amended 0272 prints, every poll
until a read works: `charger diag (0 of 18 read): APIDs 10:-1/EE7 11:... | reads 1006:no-APID ...`
(reason per register: timeout, arbiter-error, not-allowed, no-APID, poisoned) and every third poll
`SID 3 PPIDs in the APID map (n total): 0a/EE0 19/EE0 47/EE0 ...`; and in the first 3 polls and every 15th
a `setup (poll n): ... charger CHGR APID n EE u USBIN APID n EE u, control ...` line. If the PPIDs are not
in the map, the HLOS arbiter cannot reach them at all: the next step is the debug arbiter at 0x10b14000
(Linux `spmi-pmic-arb-debug.c`) or the ADSP charger PD (section 6).

Verification:
- [V] 2026-10-26: `git apply --check` on the full tree (all patches up to 0290), `compile-one.sh`
  OK for `negroni_spmi.c`, `NegroniBattery.cpp` clean with the build's clang++ line (`-fsyntax-only`).
- [ ] Full build and image: see docs/plan.md (kernel-chg job).
- Phone (owner flashes `out/ios16-chg`): watch for `charger CHGR 0x1000 APID n (EE e)`, the first
  `charger ...` line (what XBL left: `cmd_il`, `icl_cfg`, `icl_sts`, `power_path`), `charger set` /
  `charger after set`, then the main line: `mA` positive with the cable in, `chg=fast` or `taper`.
  If `icl_sts` shows half of what was asked, the step is 25 mA: boot `negronichg_step=25`. If the
  owner EE is not 0 and writes are "FAILED", try `negronichg_force=1`; if the arbiter refuses them,
  the only path left is the ADSP charger PD (section 6).

Risks: the SMB5 layout on PM8350B is inferred (the first `charger` line shows nonsense values if it is
wrong: e.g. `st1` above 7 bits, `icl_cfg` 0xff); the step size is inferred; a wrong limit above what
the Mac port gives makes the port drop (AICL stays on and backs off). Writes stop after 5 tries.

## 8. Charger ownership and the debug arbiter path (0273, 2026-10-26)

Finding: on this phone the ADSP owns the PM8350B charger. The HLOS (EE 0) is not designed to touch it.
- [V] `out/live.dts:6637-6645`: `qcom,pmic_glink` (`qcom,pmic-glink-channel = "PMIC_RTR_ADSP_APPS"`,
  `qcom,protection-domain = "tms/servreg", "msm/adsp/charger_pd"`) holds `qcom,battery_charger` with all the
  OPLUS charge limits. The HLOS `qcom,pm8350b@3` (`out/live.dts:13056`) has no SMB5 charger node, and the
  tree has no `qcom,qpnp-smb5` node (grep: 0 matches).
- [V] OnePlus `oplus_battery_sm8450.c` (out/src/op-modules vendor/oplus/kernel/charger/charger_ic/) has no
  regmap/SPMI access (grep: 0 matches). It sets the ICL through GLINK (`usb_psy_set_icl` :2548 ->
  `write_property_id` :878 -> `battery_chg_write` :830 -> `pmic_glink_write` :850), enables charging through
  GLINK (`smbchg_charging_enable` :8270, `BATT_CHG_EN` :8285), and reads VBUS through GLINK
  (`qpnp_get_prop_charger_voltage_now` :9477, `read_property_id(USB VOLTAGE_NOW)`). Qualcomm
  `qti_battery_charger.c` (out/src/op-kernel drivers/power/supply/) is the same "charger in the ADSP" design
  (MSG_OWNER_BC 32778 :26, BC_USB_STATUS_SET 0x33 :37; 0 regmap/SPMI matches).
- [V] Linux arbiter rules (out/src/op-kernel drivers/spmi/spmi-pmic-arb.c): an observer read works for any
  PPID in the APID map, whatever the owner (`pmic_arb_offset_v5` :1124 OBS case); a write needs
  `write_ee == ee` (:1128 "disallowed SPMI write"); a PPID that is not in the map gives -ENODEV
  (`pmic_arb_ppid_to_apid_v5` :1066). So the 0272 reads (all 0xff) failed because the CHGR..MISC PPIDs are
  not in the HLOS APID map, or because of an arbiter error. The 0272 diag line (committed in a0acdd0) says which [I until
  the phone log].
- [I] So the EE 0 path cannot write the charger. Without the ADSP charger PD, nobody sets the ICL: the
  charger keeps the value XBL/ABL left (logs: at best +78 mA net into the pack while idle).

Register map fix [V: out/src/op-kernel drivers/power/supply/qcom/smb5-reg.h, qpnp-smb5.c, smb5-lib.c]:
- `ICL_STATUS` = DCDC 0x1107, `AICL_ICL_STATUS` = 0x1108, `POWER_PATH_STATUS` = 0x110b (DCDC_BASE 0x1100).
  0272 used 0x1607/0x1608/0x160b (the SMB2/PMI8998 MISC offsets). 0273 reads the DCDC registers.
- The HC input mode (`smblib_icl_override(SW_OVERRIDE_HC_MODE)` smb5-lib.c:165) is USBIN_ICL_OPTIONS bit 0 = 1,
  CMD_ICL_OVERRIDE (0x1342) bit 0 = **0**, USBIN_LOAD_CFG bit 4 = 1. 0272 wrote 0x1342 = 1. 0273 reads 0x1342 and
  clears bit 0 only when it is set. The step is 50 mA/LSB on PM8150B/PM7250B (`smb5_pm8150b_params.usb_icl`,
  qpnp-smb5.c:126) [I for PM8350B].

USBIN voltage [V]: `usbin` is the PMK8350 VADC channel 0x311 (`pm8350b_usb_in_v_div_16`, prescale 1/16,
out/live.dts:12406; NegroniBattery `kUsbIn = {3, 0x11, .., 1, 16}`, the same). The value exists only in
`negronibatt=4/5` (VADC conversions); in mode 1/2 the old line printed `usbin=0mV` for "not measured". 0273
prints `usbin=-` when the VADC is off. The channel and register are correct; the phone logs were mode 1.

The debug arbiter (`qcom,spmi-debug@10b14000`, out/live.dts:13393; driver spmi-pmic-arb-debug.c):
- core 0x10b14000 + 0x60: CMD0 0x00 (opcode << 1 starts), CMD1 0x04 ((bytes-1) << 4 | SID), CMD2 0x08
  (peripheral), CMD3 0x0c (offset), STATUS 0x14 (bit 0 done, 1 failure, 2 denied, 3 dropped), WDATA0 0x18,
  RDATA0 0x38. Opcodes: 1 EXT_READL, 0 EXT_WRITEL. Linux waits 100 x 1 us. No EE, no ownership check.
- Fuse: `reg "fuse" 0x221c8784`, `qcom,fuse-enable-bit = <0x12>` (an ENABLE bit, not `qcom,fuse-disable-bit`):
  the bus works only when bit 18 is set; else Linux probe fails ("disabled by fuse") [V: driver probe].
  Whether it is set on a retail NE2211 is unknown [I]: 0273 logs the word.
- Clock: `clocks = <0x41>` = `power-controller@c300000` (qcom,waipio-aoss-qmp, out/live.dts:7236-7244), the
  AOSS QMP "qdss" clock: the AOP message `{class: clock, res: qdss, val: 1}` (out/src/op-kernel drivers/soc/qcom/qcom_aoss.c:286-288).

What 0273 does:
- `negroni_spmi.c`: `negroni_spmi_chg_route(arb, want_write, check_fuse, qdss)`. auto: the debug arbiter when
  the normal path cannot read CHGR 0x1004, or (with writes wanted) when EE 0 does not own the CHGR and USBIN
  APIDs. Open sequence, once per boot: fuse word (bit 18), AOP QMP QDSS vote (link/channel handshake as 0240
  step 4; waits up to 1 s for an empty mailbox), core page map, a log line, 500 ms sleep (the line reaches the
  USB log), check read SID 3 0x4704 (BCL TYPE) through the debug bus, compared with the normal path. Any
  failure or a mismatch keeps the path closed; a timeout closes it for the boot. On the debug route only the
  charger blocks (SID 3 0x10-0x16) go through it; the BCL/VADC/RTC/keys stay on the normal arbiter. Reads keep
  the read allowlist; writes keep the same six registers (0x1042 0x1340 0x1342 0x1365 0x1366 0x1370), only
  after `negroni_spmi_chg_unlock()`. Read reason 6 = `debug-closed`.
- `NegroniBattery.cpp`: the route is chosen at poll `negronichg_route_poll` (default 3, about 40 s after start,
  when the USB console is up). Then it reads CHGR/USBIN TYPE/SUBTYPE, unlocks the writes, and the 0272 logic
  runs (now with the DCDC status registers and the HC mode). Boot-args: `negronichg_arb=auto|normal|debug`
  (or 0|1|2; default auto), `negronichg_dbgfuse=0` (ignore the fuse), `negronichg_qdss=0` (no QDSS vote),
  `negronichg_ma` (default 500, 0 = read only; every write needs it > 0). With `negroniadsp` set, the debug
  route stays read only unless `negronichg_force=1` (the ADSP charger PD could own the charger then).
- Review fixes (2026-10-26, same patch): a debug-bus status error (failure/denied/dropped) is logged at most 8
  times per boot; 32 errors in a row close the debug path (`debug path closed: 32 failures`). The fuse read is
  announced (`reading fuse 0x221c8784`, 200 ms sleep) like the core access. With `negroniadsp` set and
  `negronichg_qdss=1`, 0273 does not send the QDSS vote (0240 uses the same QMP mailbox with no shared lock) and
  keeps the debug path closed (`QDSS vote skipped`). `negronichg_arb=debug` means debug only: no normal-path writes
  before the route poll, and a closed debug path gives `charger: debug path closed: control OFF`.

Expected log lines (phone):
```
NEGRONI BATTERY: charger route (negronichg_arb=auto): normal path read CHGR 0x1004 rc 4, CHGR APID -1 EE 7, USBIN APID -1 EE 7 -> try the debug arbiter
NEGRONI BATTERY: debug arbiter: fuse 0x221c8784 = 0x..., bit 18 set: debug bus enabled
NEGRONI BATTERY: debug arbiter: AOP QMP "{class: clock, res: qdss, val: 1}"
NEGRONI BATTERY: debug arbiter: the AOP took the QDSS clock vote
NEGRONI BATTERY: debug arbiter: first access of 0x10b14000 (a hang here: the bus has no clock)
NEGRONI BATTERY: debug arbiter: check read SID 3 0x4704 = .. (rc 0), normal path .. (rc 0): debug path OPEN
NEGRONI BATTERY: charger writes unlocked through the debug arbiter (0x1042 0x1340 0x1342 0x1365 0x1366 0x1370)
NEGRONI BATTERY: charger blocks through the debug arbiter: CHGR type/subtype ../.. (rc 0/0) USBIN type/subtype ../.. (rc 0/0)
NEGRONI BATTERY: charger path debug arbiter, control on
NEGRONI BATTERY: charger fast, USBIN plugged (debug arbiter): st1 .. en .. usb_rt .. cmd_il .. icl_ovr .. icl_cfg .. | icl_sts .. aicl_sts .. power_path ..
NEGRONI BATTERY: charger set (try 1): want 500 mA ...
NEGRONI BATTERY: charger after set: icl_cfg 0a cmd_il .. en .. icl_sts .. aicl_sts .. power_path ..
```
Failure lines: `bit 18 clear: debug bus disabled by fuse` (then only the ADSP charger PD is left, section 6),
`QDSS clock vote failed (...)`, `check read ... debug path closed`, `debug arbiter read ...: status 0x.. (denied)`.

Risks:
- The first access of 0x10b14000 without a working QDSS clock can stall the bus (a hang, not a panic). The
  log line before it and the 500 ms sleep show it. Fallback boot-args: `negronichg_arb=normal`.
- The fuse page read (QFPROM 0x221c8000) and the QMP handshake are new on this phone (0240 step 4 is not tested
  on hardware either). 0240 and 0273 share the QMP mailbox without a lock: 0273 waits for an empty box first.
- The debug bus has no ownership check. The code limits it to the read allowlist and six write registers:
  0x1042 CHARGING_ENABLE_CMD bit 0 (set), 0x1340 USBIN_CMD_IL bit 0 (clear = un-suspend), 0x1342
  CMD_ICL_OVERRIDE bit 0 (clear), 0x1365 bit 4 (set), 0x1366 bit 0 (set), 0x1370 = negronichg_ma / step (max
  3000 mA -> 60 at 50 mA/LSB, 120 at 25 mA/LSB; default 500 mA -> 10). No float voltage, FCC, JEITA, Type-C or HVDCP
  write. The 5 tries per plug start again at the route switch (poll 3), so up to 5 + 5 per boot. At most 5 tries
  per plug.
- The PM8350B SMB5 layout and the 50 mA step stay inferences: the TYPE/SUBTYPE line and the first `charger`
  line validate them before the writes matter (`icl_sts`/`aicl_sts` half of the request = 25 mA step).
- When the ADSP charger PD runs one day (0240 + GLINK), HLOS writes would fight it: 0273 then stays read only.

Verification:
- [V] 2026-10-26: `git apply --check` on the 0272 state; `compile-one.sh` OK for `negroni_spmi.c`; NegroniBattery.cpp
  `-fsyntax-only` clean with the build's clang++ line.
- [V] Full build `kernel-chg3` (with the review fixes): out/kernel/local-20261026-073259/kernel.development.negroni, sha256
  461b94bcade6f42a6aa669f3b5afadb4e751c14005638c80d35d5d5a9dbd03f4; 0273 applied (patch-report), only the 4 usual dxb
  skips; the strings `charger route (negronichg_arb=%s)` and `debug arbiter` are in the kernel.
- [V] Image out/ios16-chg2 (boot-args + `negronibatt=5`): boot_a.img sha256
  baa0528616fabb7a8cee606962f696f3cec94e2d5df3bb11e98d596b32b02f7e (out/ios16-chg2/SHA256SUMS). Not booted.

## 9. Charger control over GLINK: the ADSP charger PD (0274, 2026-10-26)

Plan and message formats: `docs/charger-glink-plan.md`.

Why [V phone log 2026-10-26 13:17-13:22, `logs/usblog-20261026-131747.txt`]: no APID for the SMB5 blocks
(`CHGR APID -1 EE 7`), the debug arbiter is fused off (`fuse 0x221c8784 = 0x4900000, bit 18 clear`), so 0272/0273
cannot write the charger. With USB in: VBUS 4.87-4.94 V, `iin` 725-1000 mA (saturates near 1000 mA under load),
battery current 0..+146 mA at idle and down to -1289 mA under load. [I] The charger runs at its ~1 A default input
limit and the load takes it all: no net charge. The ADSP charger PD owns the charger (live.dts:6637-6645).

What 0274 does (`bsd/dev/negroni_chg_glink.c`, new; hunks in `negroni_adsp.c/.h`, `NegroniBattery.cpp`,
`bsd/conf/files`):
- GLINK channel 2 `PMIC_RTR_ADSP_APPS` (lcid 3) on the 0242 transport (hunks in negroni_adsp.c/.h: table entry,
  name-match gate, step 9 loops limited to channels 0..1, new `negroni_glink_open()` under the GLINK lock): its
  remote OPEN is answered only with `negronichg_glink=1`; step 9 still waits for IPCRTR/adsp_apps only.
- `NegroniBattery::start` starts the charger thread. It waits up to 600 s for GLINK (ADSP step 9), then up to 30 s
  for the channel (then retries every poll), then every `negronichg_glink_poll` s (20): reads battery ids 0/4/7/9/10/12, the OEM read
  buffer (opcode 0x10000, external-gauge SoC in word 3), USB ids 0/1/3/5/7/26/47. READY = the channel is open and
  a read came back with ret_code 0 (the downstream pmic_glink.c rule). Only after READY: BC_SET_NOTIFY_REQ, a
  one-time dump of battery ids 0..24 and USB ids 0..11, then per plug (max 5 tries each): USB_INPUT_CURR_LIMIT
  (0x33 id 5, uA) in 500 mA steps up to `negronichg_ma` (default 1500, cap 2000; 0 = read only) with a step back
  when VBUS < 4500/4550 mV (AICL point of `oplus_chg_set_input_current`), USB_SUSPEND_PMIC = 0 only when it reads
  non-zero, BATT_CHG_EN = 1 (0x31 id 24). A cycle where no read is answered clears READY (no writes).
- NegroniBattery: `chg=glink icl=NNNNmA` in the status line once READY; registry `NegroniChargerGlink*` (Ready,
  IclMa, SOC in 1/100 %, Status, VbusMv, ChargeEnable). The percentage is not changed by 0274 (patch 0276).
- No SPMI write. With `negroniadsp` set 0273 stays read only.
- Review fixes (2026-10-26): ICL cap 2000 mA (live.dts:6652-6654 `qcom,input_current_charger_ma`/`pd_`/`qc_` = 2000;
  `oplus_chg_set_input_current` clamps to pd_curr_max, oplus_battery_sm8450.c:7960-7962); the plug edge is taken only
  from a cycle where a USB read answered (a lost cycle no longer reads as "USB out" and so cannot restart the 5+5
  writes); after a remote CLOSE `negroni_glink_open` advertises all our RX intents again and clears the ADSP's
  [U: whether the ADSP takes our old lcid without a new OPEN from us].

Boot-args: `negroniadsp=1 negronichg_glink=1 negronichg_ma=1500` (negroniadsp=1 alone runs ADSP steps 1..9 since the
regenerated 0242/0243). Expected log: `NEGRONI ADSP: 9 GLINK UP`, `NEGRONI BATTERY: glink: start`, `glink:
PMIC_RTR_ADSP_APPS is open`, `glink: the charger PD answers ...: READY`, `glink: battery properties ...`,
`glink: write USB_INPUT_CURR_LIMIT 1500 mA (uA) = 1500000: ok`, `glink: input limit read back: 1500 mA`,
`glink: write BATT_CHG_EN = 1: ok`, `NEGRONI BATTERY: 12% ... chg=glink icl=1500mA`.

Risks: `negroniadsp=1` boots the ADSP (0240/0241, SoC-reset risk, needs the ADSP firmware area on userdata). [U] the
charger PD may need an HLOS servreg locator before it opens the channel (then try `negroniadsp_step=10`). [U] the PD
may reset the ICL on plug events (the read-back each cycle catches it, 5 ramps per plug). [I] the PD runs its own
charge policy (JEITA, VOOCPHY) without the OPLUS HLOS algorithm. [I] the OPLUS property ids (24, 26, 47) assume
`OPLUS_FEATURE_CHG_BASIC` in the OnePlus build; the property dump checks them.

Verification (2026-10-26, build only, not booted):
- [V] compile-one OK for negroni_chg_glink.c and negroni_adsp.c; 0274 regenerated on a patched tree up to 0275 (the
  regenerated 0242/0243 of 13:41); `git apply --check` of 0276, 0301, 0330 on top: OK.
- [V] Full build: out/kernel/local-20261026-084835/kernel.development.negroni, sha256
  6acdaacfd2c203985b03574aaac108db34736029e52dd2eb0a8ec68e3e705be8; patch-report applies 0274 and 0276; only the 4
  usual dxb skips. Patch sha256 3512de92d111fe141deb355cb8d9a2b4dc66cfa3400bc67f9fec5f95909dc973.
- [V] Image out/ios16-chg3 (config args + `negronibatt=5 negroniadsp=1 negronichg_glink=1 negronichg_ma=1500
  negronipanic=30 negronipanicreason=2`): boot_a.img sha256 9286b5e3a6639e045d1a09e03a11e663ff90619b0b1609d1d92dacee5bed9ef5,
  vendor_boot_a.img c29329eed53250d753caf8e1a8793c6f44238e2b6983adcda5c65cbdbe47fe5b (out/ios16-chg3/SHA256SUMS).

## 10. The percentage: why 12 % became 9 %, and its source (0276, 2026-10-26)

Owner report: "12 % when the USB-C cable went in, 9 % later". Log: `logs/usblog.log` (kernel local-20261026-074105,
`negronibatt=5`, cable in the whole time).

Findings:
- [V] The phone rebooted at 13:32:30 (`NEGRONI RTC: time set`, launchd `boot-args =` at usblog.log 7585-7990 between
  the two battery series). The 12 % series (13:17-13:31, `soc 1150`) and the 9 % series (13:32:43 on, `soc 913`) are
  two boots. 0271 keeps nothing across boots: the first value is the first sample's table value.
- [V] Boot 1 first sample: 3693 mV at +146 mA -> IR comp 80 mOhm -> 3681 mV -> 11.5 % (`kOcv` 3680 = 10 %, 3720 = 15 %).
  Boot 2 first sample: 3549 mV at -1240 mA (the boot load) -> +99 mV -> 3648 mV -> 9.1 %. The difference is the load at
  the first poll, not a 3 % discharge.
- [V] Within a boot the value never moved: `soc 1150` for 42 polls while `vadc vbat` went 3504-3693 mV. 0271 says
  "never down on a charger" (`external=1`) and the coulomb count is ~0 (ibat 0 or +78 mA at rest, -0.3..-1.3 A in bursts),
  so a cable that only holds the phone froze the number.
- [V] The true state: rest samples (ibat 0 mA, 8 of 8 zero) read `vadc vbat` 3669 mV (boot 1, 19 samples) and 3662 mV
  (boot 2, 16 samples); `mid2s` equals `vbat` (the VBAT pin is on the 1S side). On the 0271 table 3669 mV = 9.3 %,
  3662 mV = 8.8 %. Net coulombs: -68 mAh in 14 min (boot 1), -34 mAh in 8 min (boot 2): the pack loses about 1 %
  per 10 min with the cable in (the input ~1 A at 5 V covers only the idle load; `iin` 580-1000 mA). So 9 % is right
  to within the table's error and 12 % was the overestimate. [I] The table is a generic 4.45 V-class curve
  (DT `qcom,temp_normal_vfloat_mv` = 0x1153 = 4435 mV): +-3 % near 10 %.
- [V] What the raw `soc 1150` is: `fSoc` of NegroniBattery.cpp (hundredths of a percent, our estimate). It is not a
  PMIC register. No QGauge exists here: `out/live.dts` has no `qpnp,qg`/`qg@`/`qbg@` node and no OCV table
  (grep: 0 matches), and the OnePlus kernel's QG driver (`out/src/op-kernel drivers/power/supply/qcom/qpnp-qg.c`,
  `qg-soc.c`, `qg-sdam.c`) is not probed on this board. The BCL `vbat`/`ibat` are voltage/current only.
- [V] Where OxygenOS gets the percentage: the ADSP. `oplus_battery_sm8450.c:10727` `fg_bq27541_get_battery_soc()`:
  with `ADSP_VOOCPHY` it is `read_buffer_dump.data_buffer[3] / 100` (the OEM read buffer from the charger PD,
  `handle_oem_read_buffer` :311), else `BATT_CAPACITY` over GLINK (`read_property_id`); Qualcomm
  `qti_battery_charger.c:760` reads the same `BATT_CAPACITY` (hundredths of a percent). The gauge IC itself (the
  `oplus_bq27541.h` family: bq27541/bq27z561/bq28z610, :33) sits on a bus that only the ADSP has; the HLOS DT has no
  I2C gauge node (`bq27`, `bq28`, `oplus,gauge`, `cw2217`, `sh366`, `nfg8011`: 0 matches), only
  `qcom,external_gauge` (out/live.dts:6804) under `qcom,battery_charger`. Our tree has no GENI I2C driver
  (`negroni_i2c`: 0 matches in patches/xnu). So source (a), the gauge over I2C, is not possible from the AP.

What 0276 does (`iokit/Kernel/arm/NegroniBattery.cpp` only; applies after 0274):
- Source order per poll: `glink` = 0274's `negroni_chg_glink_get()` `soc_centi` when the channel is up, the PD
  answered and the value is at most 3 minutes old (`NB_GLINK_FRESH_NS`); the value is shown as it is (the real
  gauge). Else `ocv`: the estimate below. `gauge` (I2C) is reserved, not implemented.
- OCV estimate: terminal voltage minus I x 80 mOhm (clamped +-150 mV), one bad conversion rejected (a sample more
  than 250 mV from the filtered value is ignored unless three in a row; seen: `vadc vbat 2742mV` once in a 3660 mV
  series), filtered (1/4 at rest |I| <= 100 mA, 1/8 under load), then the `kOcv` table = `target`. The shown value
  moves toward `target` at most 1 % per 30 s (`NB_SOC_RATE_S`); never down while the filtered current is >= +50 mA,
  never up while it is <= -50 mA, both ways at rest (so a cable that only holds the phone no longer freezes it). The
  first value is the first sample's table value (1-3 % low under the boot load; it stays until the pack reaches that value or the phone rests (|I| < 50 mA); under a discharge current the value cannot rise).
- `ExternalConnected` in the full read: VBUS first (the same source as the plug tick), the SMB5 rt_sts bit only without a VBUS reading, else the current direction. Without any AP voltage (static fallback) a ready GLINK SoC is still published.
- `charging` uses the filtered current (no flicker between the +78 mA and 0 mA polls) or, with the GLINK source, the
  PD's `BATT_STATUS` (1 charging, 4 full). `full` the same way.
- Registry: `CapacityEstimated`/`NegroniBatterySOCEstimated` are false with the GLINK source; new
  `NegroniBatterySOCSource` ("ocv"/"glink"), `NegroniBatteryOCVMillivolts`, `NegroniBatterySOCTarget`.
  The IOPMPowerSource keys are unchanged: `CurrentCapacity` = percent, `MaxCapacity` = 100, `IsCharging`,
  `ExternalConnected`, `TimeRemaining` 0xffff, `Amperage` (+ = charging), `Voltage` (mean cell, mV): the set that
  powerd/SpringBoard read (0271, checked against the `powerd` strings).
- Nothing is kept across boots (next step: save `fSoc` with the RTC offset file, as `negroni_rtc.c` does).
- Plug latency (owner report: "5 to 10 s to detect it is charging"; cause: one full read every 20 s): the timer
  now ticks every `negronibatt_fast` ms (default 1000; 0 = off, 250 min). A tick runs `fastCheck()`: the plug
  state only, VBUS through the VADC (modes 4/5, one ADC7 conversion of channel 0x311) or, without the VADC, the
  BCL current direction (observer reads, +-50 mA hysteresis). On a change it logs
  `NEGRONI BATTERY: external 0->1 (usbin 4919 mV) after 998 ms` (ms since the previous tick = the detection
  delay bound), publishes `ExternalConnected`/`ExternalChargeCapable`/`AppleRawExternalConnected` (and
  `IsCharging` = false on unplug) with `updateStatus()` at once, then runs the full read. The 20th tick is the
  full read as before. [V] No plug interrupt is reachable: SMB5 `USBIN_INT_RT_STS` (0x1310 bit 4) has no APID in
  the HLOS map (section 8); the census `rt_sts 327 (0x2700+0x10)` bit 6 toggles 0x80 <-> 0xc0 with the load
  (0xc0 at -458..-1289 mA, 0x80 at -78..+78 mA, 14 toggles in logs/usblog.log 13:17-13:41 with the cable in the
  whole time): a current/BCL-type status, not the cable; `rt_sts 306 (0x0600+0x10)` changed only at the first read.
- 0274 coupling: 0276 touches no 0274 line (its hunks anchor on 0271-0273 code) and includes
  `negroni_chg_glink.h` only `#if __has_include(...)`: it applies and compiles with and without 0274
  (checked both ways, `git apply --check` + compile-one, 2026-10-26). Note: 0274 itself stopped applying at
  13:41 when 0242/0243 (audio agent) changed `bsd/dev/negroni_adsp.c` (`error: patch failed: bsd/dev/negroni_adsp.c:1644`,
  logs/tree-soc2.log, logs/kernel-soc.log); the 0274 agent rebased it before the 14:00 build (`kernel-soc2`: 0274 and 0276 both applied).

Log lines to expect (`negronibatt=5`):
```
NEGRONI BATTERY: soc 9% src=ocv ocv=3665mV target=9.00% avg=-12mA vbat=3662mV cur=0
NEGRONI BATTERY: external 0->1 (usbin 4919 mV) after 998 ms
NEGRONI BATTERY: soc source glink (the charger PD's gauge value 9.40%; ocv estimate 9.10%)      (only with 0274 active)
NEGRONI BATTERY: soc source ocv (the charger PD's value is stale; kept 9.40%, estimate 9.10%)
```
`raw ... soc NNNN` still prints `fSoc` of the previous poll. The main status line is unchanged (0274 owns its
`chg=`/`icl=` fields); 0276 adds its own line on each change of percent, source or whole-percent target:
`NEGRONI BATTERY: soc 9% src=ocv ocv=3665mV target=9.00% avg=-12mA vbat=3662mV cur=0`, and on a plug change
`NEGRONI BATTERY: external 0->1 (usbin 4919 mV) after 998 ms`.

Verification:
- [V] `scripts/kernel/compile-one.sh out/kernel/tree-soc iokit/Kernel/arm/NegroniBattery.cpp` (the script now takes a
  `.cpp` of iokit/ with the build's clang++ line; `COMPILE_LOG=logs/chg3.log` while a full build rewrites build.log):
  no diagnostic in the file.
- [V] Full build `kernel-soc3` (2026-10-26, review fixes in): out/kernel/local-20261026-084328/kernel.development.negroni, sha256
  20026d62616b6dd932737f4cd26e7f73e439d123ed10f2f99d763956b3a236a0; patch-report: 0274 and 0276 applied, only the
  4 usual dxb skips; the strings `soc %u%% src=%s` and `external %d->%d` are in the kernel. Image `out/ios16-soc`
  (config args + `negronibatt=5 negronipanic=30 negronipanicreason=2`): boot_a.img sha256
  400f1f95130907e17aaa2d982c162e0ba395a34a5434d2cd0d8f0d2721bbdaa6, esp.img 25b1d7cc..., negroni.adt e6d00e37...
  (out/ios16-soc/SHA256SUMS). Not booted.
- Phone: the first line's percent is within 3 % of the rest value; after 10 min at rest with the cable in, the
  percent follows `target` (1 % per 30 s); with 0274 running, `soc src=glink`.

## 11. The charge loop over GLINK (0277, 2026-10-26)

Status: built in the full set (section 12 has the build), **not booted**. The phone runs Android.

Why [V audit docs/audit/2026-10-26-power.md row 6, item 9]: 0274 writes only `USB_INPUT_CURR_LIMIT`, `USB_SUSPEND_PMIC`
and `BATT_CHG_EN`. On OxygenOS the HLOS loop checks the battery every 5 s (`OPLUS_CHG_UPDATE_INTERVAL_SEC 5`,
out/src/op-modules/vendor/oplus/kernel/charger/oplus_charger.c:110; `oplus_chg_update_work` :14580 ->
`oplus_chg_protection_check` :10583 -> `oplus_chg_check_tbatt_is_good` :7950, which on a band change calls
`oplus_chg_set_float_voltage` + `oplus_chg_set_charging_current` :8028-8029; then `oplus_chg_battery_update_status`
:11867). Correction (review 2026-10-26): the earlier citation :7556-7558 is `oplus_chg_turn_on_ffc1` (the FFC path).
OxygenOS writes FV/FCC on a band change; 0277 re-sends them every 5 s (same values, so the PD cannot drift).
[I] Without it the PD's own defaults decide the charge curve.

What the loop does (`bsd/dev/negroni_chg_glink.c`, `charge_loop()`), only after the 0274 READY, only with USB in,
every `negronichg_loop_s` (5) s between the 20 s 0274 cycles (review fix: a refused `BATT_CHG_EN = 1` restart
logs only the first 5 failures, as the FV/FCC writes do):
1. Reads `BATT_TEMP` (id 12, hundredths of a degree: `oplus_battery_sm8450.c:3060` divides by 10). No valid value
   (-40..100 C) = no FV/FCC write (logged once): the PD keeps its own values.
2. Picks the JEITA band (table `kBand`, the decision order of `oplus_chg_check_tbatt_status`, oplus_charger.c:8041-8059;
   2.0 C hysteresis back toward normal, `HYSTERISIS_DECIDEGC` :7849):

| Band | Battery temperature | FV per cell | FCC | DT source (out/live.dts) |
|---|---|---|---|---|
| removed | <= -19.0 C | stop | stop | removed_bat_decidegc 0xbe :6681 (negated, oplus_charger.c:5446) |
| low | -19.0 .. -10.1 C | stop | stop | oplus_charger.c:8055, :6890-6894 |
| cold | -10.0 .. -0.1 C | 4435 mV | 600 mA | cold_bat_decidegc 0x64 :6682; 0x1153 :6683; 0x258 :6684 |
| little_cold | 0 .. 4.9 C | 4435 mV | 1100 mA | :6685; :6686; 0x44c :6687/:6689 |
| cool | 5.0 .. 11.9 C | 4435 mV | 1100 mA | 0x32 :6694; :6695; :6696 |
| little_cool | 12.0 .. 15.9 C | 4435 mV | 1100 mA | 0x78 :6702; :6703; :6704 |
| normal | 16.0 .. 44.9 C | 4435 mV | 1100 mA | 0xa0 :6707; 0x44c :6708; 0x1153 :6709 |
| warm | 45.0 .. 53.0 C | 4130 mV | 500 mA | 0x1c2 :6712; 0x1022 :6713; 0x1f4 :6717 |
| hot | > 53.0 C | stop | stop | hot_bat_decidegc 0x212 :6718 (">" at oplus_charger.c:8041) |

   FCC is the plain value (`temp_*_fastchg_current_ma`), not the `pd_`/`qc_` values (2000 mA): 0274 negotiates no
   PD/QC voltage (5 V, ICL <= 2000 mA). Warm uses the screen-on value 500 mA (`temp_warm_fastchg_current_ma_led_on`,
   :6717) instead of 1100 mA (:6714): we do not track the screen [I: the lower one is the safe one]. The DT has
   `_high`/`_low` variants for vbat above 4180 mV; they are equal here (:6687-6696).
3. "stop" bands: `BATT_CHG_EN` = 0 (`smbchg_charging_disable`, oplus_battery_sm8450.c:9136) every loop; 0274 does not
   enable it again while stopped (`chg_stopped`, also across a re-plug); the loop writes `BATT_CHG_EN` = 1 when the
   band is good again.
4. FV = `BATT_VOLT_MAX` (id 8, mV: `smbchg_float_voltage_set`, oplus_battery_sm8450.c:8194-8226, `write_property_id`
   with `vfloat_mv` as it is). OxygenOS writes the per-cell value x `vbatt_num` (oplus_charger.c:7252; DT
   `qcom,vbatt_num = <2>` :6749; `bidirect_cp` is not in the DT, so the x2 branch). The unit is taken from the PD's
   own value at the first loop: 6000-9000 = pack mV (x2), 3000-4600 = cell mV (x1), anything else = **no FV write**
   (logged). So the pack value is 8870 mV in the normal band.
5. FCC = `BATT_CHG_CTRL_LIM` (id 10, uA: `smbchg_set_fastchg_current_raw` :7624-7646) = min(band, thermal level).
   Thermal level (0283 sets it, `negroni_chg_glink_set_thermal_level()`): 0 none, 1..4 = DT `qcom,thermal-mitigation`
   3000/1500/1000/500 mA (:6647). With the band maximum of 1100 mA, levels 1-2 change nothing.
6. Reads back FV and FCC; a difference is logged (bounded). Writes log only on a change or a failure; 5 failed writes
   in a row stop that write for the plug.

Safety [V code]: `bands_ok()` checks every table row against `FV_DT_MV` 4435 (live.dts:6709) and `FCC_DT_MA` 1100
(:6708) at start and turns the loop off when a row is above (`REFUSED, loop off`); every write is checked again
(`fv <= 4435 x scale`, `ma <= 1100`). No FV without a known unit. No write before READY. The FFC values of the DT
(`ffc_temp_normal_vfloat_mv` 0x1194 = 4500 mV, :6769) are never used.

Power hub (0277, `negroni_chg_glink.h`): `negroni_pwr_temp_set/get` (skin, XO, cell temperature, hundredths of a
degree, with an age) so the battery service (0278) and the thermal policy (0283) share values without a direct link.

Boot-args: `negronichg_loop=1` (default when `negronichg_glink=1`; 0 = the 0274 behaviour), `negronichg_loop_s` (2..60, 5).

Log lines (prefix `NEGRONI BATTERY: glink:`):
```
start: channel PMIC_RTR_ADSP_APPS, input limit 1500 mA, poll 20 s, charge loop on (every 5 s, FV <= 4435 mV/cell, FCC <= 1100 mA)
loop: battery 28.4 C: band normal (FV 4435 mV/cell, FCC 1100 mA)
loop: the PD's BATT_VOLT_MAX reads 8870: pack mV (x2, as oplus_charger.c:7252)
write BATT_VOLT_MAX (FV, mV; 4435 mV/cell) = 8870: ok (ret_code 0)
write BATT_CHG_CTRL_LIM (FCC, uA; 1100 mA) = 1100000: ok (ret_code 0)
loop: thermal FCC level 0 -> 3 (1000 mA; band 1100 mA: FCC 1000 mA)
soc ... | fv 8870 loop on band normal fv 8870 fcc 1100 lvl 0
```

Risks: [U] whether the PD accepts `BATT_VOLT_MAX`/`BATT_CHG_CTRL_LIM` from the HLOS on this firmware (a `REFUSED`
line answers it; 5 refusals stop the write). [U] whether the PD's `BATT_VOLT_MAX` reads the pack value (the unit
rule refuses anything outside both ranges). [I] The PD may run its own JEITA too; ours can only lower the values
(every value <= the DT). [I] `BATT_TEMP` comes from the gauge through the PD; a stuck value would keep a band (the
cycle log shows `temp`).

## 12. Percentage across boots, cell temperature, BCL monitor, QDSS release (0278, 2026-10-26)

Status: built in the full set, **not booted**.

What 0278 does:
- **Percentage kept across boots** (`bsd/dev/negroni_batt_store.c`, new): the way 0203 keeps the RTC offset
  (`negroni_rtc.c`: text file in `/private/var/db`, `vnode_open` + `vn_rdwr`, writes on a thread call with
  `VNOP_FSYNC`, retry every 30 s x 60 while the root is read only). File `/private/var/db/negroni_batt`:
  `negroni-batt 1`, `soc <1/100 %>`, `wall <s>`. NegroniBattery reads it at the first OCV estimate (and, while
  `vfs_rootvnode()` is NULL, at the next 15 polls). Sanity check: the saved value is used only when it is within
  15 % of the OCV estimate (`NB_STORE_TRUST` 1500); else the estimate wins (`> 15 %: the estimate wins`). With the
  GLINK source the gauge value wins and no restore happens. Saves: after the restore decision, on each 1 % change,
  at most once a minute. [V phone log 2026-10-26 usblog.log:318] The RTC file in the same directory is written at
  boot, so the directory is writable early.
- **Temperature**: the cell temperature from the PD's gauge (`BATT_TEMP` over GLINK, through the 0277 hub, fresh
  for 60 s, -20..80 C) when the PD is READY; then `NegroniBatteryTemperatureEstimated` = false and
  `NegroniBatteryTemperatureSource` = `glink`; the value is not clamped. Else the skin thermistor as before (clamped
  0-45 C, `skin`), else 25 C (`none`). New registry keys `NegroniSkinTemperature`, `NegroniXoTemperature`.
- **XO thermistor**: modes 4/5 read `pmk8350_xo_therm` (VADC SID 0 channel 0x44, ratiometric, 200 us, live.dts:12226-12231)
  with the skin channel; both go to the hub for 0283 (`xo` in the raw line).
- **BCL MONITOR_EN** [V audit item 11: never written]: at start, `negroni_spmi_bcl_monitor_on()` reads 0x4746; only
  when bit 7 is clear and EE 0 owns the BCL APID (phone log: `BCL APID 462 EE 0`), it writes 0x80 (Linux
  `bcl_configure_bcl_peripheral`, bcl_pmic5.c:777-780) through a one-write window (locked again after it) and reads
  back. With the bit set (the phone logs `mon 80` today) nothing is written. Boot-arg `negronibcl_en=0` = never.
- **QDSS vote release** [V audit item 10]: 0273's AOP vote `{class: clock, res: qdss, val: 1}` is now released with
  `val: 0` (Linux `qmp_qdss_clk_unprepare`, qcom_aoss.c:294-296) on every path where the debug path ends after the
  vote: core map failed, check read failed, a later timeout or 32 failures. While the debug path is open the vote
  stays. With `negroniadsp` set no vote is sent (0273), so nothing to release.

Log lines:
```
NEGRONI BATTERY: BCL monitor: already on (no write)
NEGRONI BATTERY: store: no saved percentage (no file yet, error 2): the OCV estimate 9.10% stays
NEGRONI BATTERY: store: soc restored 41.00% (saved at wall 1793001749; OCV estimate 38.20%, 2.80 % apart)
NEGRONI BATTERY: store: saved 80.00% (wall ...) is 31.00 % from the OCV estimate 49.00% (> 15 %): the estimate wins
NEGRONI BATTERY: store: soc 41.00% saved to /private/var/db/negroni_batt (then on each 1 % change, at most once a minute)
NEGRONI BATTERY: debug arbiter: check read failed: QDSS clock vote released (AOP QMP "{class: clock, res: qdss, val: 0}")
```

Risks: [I] a phone charged by Android between two iOS boots: the saved value is far from the estimate and the
15 % rule drops it (the intended case); a smaller change (< 15 %) is shown first and corrected by the 1 %/30 s
rate. [I] the saved value comes from the OCV estimate itself when GLINK is off, so it carries the table error
(+-3 % near 10 %). [U] the BCL write path was never used (the bit is set on this phone today).

Verification (2026-10-26, build only):
- [V] compile-one: negroni_chg_glink.c, negroni_spmi.c, negroni_batt_store.c, NegroniBattery.cpp, no new diagnostic
  (the `negroni_spmi_keys.h:42` shadow warning is older).
- [V] Order check: 0277 and 0278 applied with `git apply` on the patched tree at 0276, then the original commits
  0280..0351 (the set of 17:56) cherry-picked with 0283 before 0284 and 0291 before 0300: the result equals the work tree.
- [V] Build `pwr-build` (scripts/battery/build-pwr-image.sh, lock out/kernel/.lock held over kernel + image): kernel out/kernel/local-20261026-124827/kernel.development.negroni sha256 01363704dab977e2259aecbe1fb81141133ba5458ec97a59a6b6abf86b981fa3; patch-report applies every patches/xnu patch 0270-0291 incl. 0277/0278/0283/0291 (and the other agent's 0287/0288), only the 4 usual dxb skips; strings `loop: battery`, `store: soc restored`, `trip %s %s (value`, `negronicpufreq_floor`, `QDSS clock vote released` in the kernel. Image out/ios16-pwr was built in that same locked job from that kernel (local-20261026-124827, sha256 01363704...; [V] three 64 KiB pieces of it found byte-equal in out/ios16-pwr/esp.img; the image SHA256SUMS lists only the image files). It is BEFORE review fix 1 (0277 BATT_CHG_EN restart log bound); per the owner the fix gets a kernel-only proof build, the main session builds the combined image. Review fixes 1-4 (2026-10-26 18:5x): kernel-only proof build `pwr-kernel` (IMAGE=0, lock held): out/kernel/local-20261026-132431/kernel.development.negroni sha256 4786905de90c56b9150153d01f33f69ed87bc7769611e494dd111a1c32974b34, 0277/0278/0283/0291 applied, only the 4 usual dxb skips, string `further failures are not logged` (fix 1) in the kernel. 0277 sha256 now in the report. Image (config args + `negronibatt=5 negroniadsp=1 negronichg_glink=1 negronichg_ma=1500 negronifb_sleep=0 negronipanic=30 negronipanicreason=2`): boot_a.img 72ee45050d399b14a1805b55c65c7cd927a90ed45d6b3c8d5596b6582afc9394, vendor_boot_a.img c29329ee..., esp.img 01f9330f..., negroni.adt 12b7654d... (out/ios16-pwr/SHA256SUMS). Not booted. Patch sha256: 0277 cd22073c..., 0278 047a4652..., 0283 564c7390..., 0291 fa95dcd5...


## 13. Charging state and speed for the iOS UI (0365, 2026-10-27)

Status: compile-checked and built in the full set (see Verification), **not booted**.

Owner goal: the battery shows the charging state and the speed. Phone log before 0365
(logs/usblog-20261026-233816.txt 02:03-02:05, `negronibatt=5`, cable in, ADSP not up):
`external=1 charging=0 ... chg=? icl=0mA`; `usbin 5036mV iin 495mA ibat 0mA` at rest, `usbin 4885mV iin 999mA
ibat -849mA` under load. So iOS saw "connected, not charging": no bolt.

Readers [V `ipsw dyld str` of the 20H392 cache]: `IsCharging`, `ExternalConnected`, `FullyCharged`, `AdapterDetails`
in UIKitCore and SpringBoard (status bar bolt, `UIDevice.batteryState`, the plug chime); `Is Charging` and
`AdapterDetails` in BatteryCenter (lock screen "Charging", Batteries widget, from powerd's IOPS dictionaries);
`InstantAmperage`, `AppleRawCurrentCapacity`, `FullyCharged` in PowerlogCore/PowerlogLiteOperators (Settings >
Battery graphs); `BatteryInstalled` in libMobileGestalt.

Rule [I, as Apple PMUs and Linux POWER_SUPPLY_STATUS_CHARGING]: `IsCharging` = the charger feeds the battery path.
Under a load above the input the bolt stays, `Amperage` is negative and the percentage falls (0276 rules unchanged).

What 0365 does (`iokit/Kernel/arm/NegroniBattery.cpp` `chargeState()`; `bsd/dev/negroni_chg_glink.c/.h`):
- (a) Without the charger PD: `charging` = VBUS >= 4000 mV, not full, and VADC `iin` >= 100 mA (`NB_IIN_MA`) or the
  filtered battery current > +50 mA. Without `iin` (no VADC): filtered current > -50 mA; without any current:
  percent < 100. `full` as 0276, and (review C5) also at >= 99 % when the filtered current is between -50 and
  +100 mA (`NB_TAPER_MA`) or unknown: the charge has tapered, so the OCV estimate cannot show "charging" for ever;
  a clear discharge under load is not a taper. `AdapterDetails`: `AdapterVoltage` = VBUS, `Current` = `iin`, `Watts` = VBUS x
  `iin` (rounded), `FamilyCode` 0xe0004007 (USB unknown: the type is the PD's).
- (b) With the charger PD (0274 READY, SoC fresh): `charging` = external and PD `BATT_STATUS` == 1, `full` = 4 (or
  100 % and not 1), as HakiOS `hakios.battery.cpp:118-121`. `AdapterDetails` from `USB_VOLT_NOW` x `USB_CURR_NOW`;
  `FamilyCode` from `USB_ADAP_TYPE` (id 7 = POWER_SUPPLY_PROP_USB_TYPE, `oplus_battery_sm8450.c:231`; 0274 read it,
  0365 stores it as `usb_type`) with the HakiOS table (SDP 0xe0004000, DCP/HVDCP/BrickID 0xe0004004, CDP
  0xe0004005, C 0xe0004009, PD/PD_DRP/PD_PPS 0xe000400a, else 0xe0004007). `InstantAmperage` = PD `BATT_CURR_NOW`
  with its sign learnt from 3 agreeing polls in a row (review C1): status 2 on battery (the current leaves the
  pack), or the AP's filtered BCL current (+ = charging) when both are above 50 mA. Status 1 alone does not name
  it: "charging" can come with a net discharge under a load above the input. Until a PD status newer than the
  plug edge arrives, the VADC rule (a) decides (review C2; `fWhy` "pd stale, ..."), and the 1 s plug tick runs
  the full read at once when a new PD cycle brings a new `BATT_STATUS` (`charge: PD status 3 -> 1: full read
  now`). The no-AP-voltage path (PD SoC only) uses the same `chargeState()` (review C3). HakiOS reads `USB_TYPE` id 6 on
  its Poco X5 Pro firmware; on this OPLUS build the type is id 7 (`[USB_ADAP_TYPE] = POWER_SUPPLY_PROP_USB_TYPE`).
- `Amperage` = the filtered current, `InstantAmperage` = this poll's (both + = charging; before: both the instant
  value). `AvgTimeToFull` = missing mAh x 60 / filtered charge current (> 50 mA), `AvgTimeToEmpty` = mAh left x 60 /
  filtered discharge current on battery, `InstantTimeToEmpty` from the instant current, `TimeRemaining` = the one
  that applies; 65535 = unknown; 1..65534 (linear, no CV taper [I]).
- Registry: `NegroniChargeInputMilliwatts`, `NegroniChargeFamilyCode`, `NegroniChargeSource` (vadc/pd),
  `NegroniChargeReason`.
- Log, on each change of external/charging/full/source and every 3 full reads (60 s) while plugged:
```
NEGRONI BATTERY: charge: 79% external=1 charging=1 full=0 (iin 495 mA avg 0 mA) | adapter 5036mV 495mA 2.49W family 0xe0004007 (vadc) | battery inst 0mA avg 0mA | to full 65535 min to empty 65535 min
NEGRONI BATTERY: charge: 78% external=1 charging=1 full=0 (iin 999 mA avg -212 mA) | adapter 4885mV 999mA 4.88W family 0xe0004007 (vadc) | battery inst -849mA avg -212mA | to full 65535 min to empty 65535 min
NEGRONI BATTERY: charge: 80% external=1 charging=1 full=0 (pd status 1) | adapter 9000mV 2000mA 18.00W family 0xe000400a (pd) | battery inst 1800mA avg 1750mA | to full 34 min ...   (with the ADSP)
NEGRONI BATTERY: charge: the charger PD's BATT_CURR_NOW is negative while charging (3 polls agree; last: status 1, PD -1800 mA, AP avg 1750 mA)   (once, with the ADSP)
```
  The 0271 status line now shows `charging=1` with the cable in.

What the owner should see: the bolt in the status bar within ~1 s of plugging in (0276 plug tick, then the full
read), the plug chime, "Charging" on the lock screen; the percentage rises only when the net current is positive
(at rest on 5 V/~0.5-1 A it rises slowly; under load it can fall with the bolt shown). Unplug: the bolt goes at the
next 1 s tick. Speed: `AdapterDetails` Watts (`ioreg -l -w0 -r -c IOPMPowerSource`) and the `charge:` line.
Today without the ADSP the charger stays at its ~1 A default input limit (section 9), so 2.5-5 W.

Verification (2026-10-27, build only): [V] compile-one NegroniBattery.cpp and negroni_chg_glink.c, no diagnostic in
the files; full build `hzbat-kernel` (lock held): out/kernel/local-20261026-213038/kernel.development.negroni sha256
127cae2a976695d78131e9116be18f99daa601010f80aa4520b8de9698ac9c7c (after the review fixes B1, C1-C3, C5), 257 patches applied incl. 0364/0365, only the 4
usual dxb skips; strings `charge: %u%% external`, `BATT_CURR_NOW is %s`, `NegroniChargeInputMilliwatts` in the
kernel. Patch sha256 3846e7a73bd24ecd8c636378bdbdf7c65710e6c568f76cc0a71dee3a6effe698. Not booted.

## 14. The ADSP charger PD and the USB data lines; GLINK RX log (0368, 2026-10-27)

- [V] With the ADSP up (0240 + `negronichg_glink=1`), the Mac lost the USB device 2-3 s after `THE ADSP IS UP`
  (02:42 and 02:55, logs/usblog-20261026-233816.txt). [V] The ADSP image has HS PHY functions (reset, non-driving mode,
  D+ toggling, the PHY ref clock `gcc_eusb3_0_clkref_en`) next to its BC1.2/APSD and VOOC code. [I] Its port detection
  leaves our PHY unusable; HLOS has no known GLINK message to stop it. Fix and test: README-usb.md "0368" (PHY watch,
  Linux PHY init + soft reconnect after the ADSP touched the PHY).
- 0368 also logs every PMIC_RTR_ADSP_APPS message for 10 s after the first one, then notifications and the other owners
  (UCSI 32779, USBC_PAN 32780) up to 200 lines: `NEGRONI BATTERY: glink: rx #n +T ms: owner .. type .. opcode 0x.. len ..:
  <5 words>`. So the next ADSP boot shows which notifications (BC_USB_STATUS_GET 0x32, BC_APSD_DONE, BC_TYPEC_STATE_CHANGE,
  VOOC ids, oplus_battery_sm8450.c:2130-2240) the charger PD sends after its start. The notifications come only after
  BC_SET_NOTIFY_REQ (0274: after READY).

## 15. VOOC / SuperVOOC with the ADSP VOOC PHY (0369, 2026-10-27)

Status: compile-checked and built in the full set, **not booted**. Default OFF (`negronichg_vooc=0`).

Facts [V, file:line in out/src/op-modules/vendor/oplus/kernel/charger; S = charger_ic/oplus_battery_sm8450.c,
A = voocphy/oplus_adsp_voocphy.c]:
- live.dts: `qcom,voocphy_support = <1>` (ADSP_VOOCPHY), `qcom,vooc_project = <7>` (DUAL_BATT_80W = 80000 mW,
  oplus_charger.h:626-633). The `oplus,adsp-voocphy` DT node is empty: the SVOOC current/temperature tables are in
  the ADSP firmware [I]; `vooc_charge_strategy_*` in the DT is only read by oplus_debug_info.c:1204-1257.
- The ADSP runs the VOOC protocol. HLOS (Android): `USB_VOOCPHY_ENABLE` (usb id 13) = 1 for a DCP (S:1585-1602, every
  5 s), `BATT_SET_MATCH_TEMP` (battery id 29, 0.1 C, every 5 s, oplus_charger.c:10651), `BATT_SET_COOL_DOWN` (28) on
  PRESENT/ONGOING (S:2614-2636), PMIC park on notify 0x52 (`BATT_CHG_EN` 24 = 0, `USB_INPUT_CURR_LIMIT` 5 = 0,
  S:2181-2192, 1373-1383), status on notify 0x48 = `USB_VOOCPHY_STATUS` (12): code bits 0-7, adapter id bits 8-14,
  sub-reason 16-23 (A:141, 227-241; codes A:35-54), answer to 0x59 with `BATT_SEND_CHG_STATUS` (37, S:8417-8444),
  0x60 = un-suspend, 0x61 = the ADSP asks the AP to suspend, recovery 8.5 s after 0x52 without ONGOING (S:8513-8535:
  ICL 0, 1 s, un-park, `USB_VOOCPHY_RESET_AGAIN` 25 = 1). Off: `USB_VOOCPHY_ENABLE` = 0 (oplus_voocphy.c:8640-8670).
- Ids [V, enums oplus_battery_sm8450.h:166-282, counted]: battery 24 CHG_EN, 28 COOL_DOWN, 29 MATCH_TEMP, 37
  SEND_CHG_STATUS; usb 12 VOOCPHY_STATUS, 13 VOOCPHY_ENABLE, 23 VOOC_FAST_CHG_TYPE, 25 VOOCPHY_RESET_AGAIN, 26 SUSPEND_PMIC.
  Notifications (oplus_battery_sm8450.h:69-90): 0x48 VOOC_STATUS_GET, 0x52 VOOC_VBUS_ADC_ENABLE, 0x55 TYPEC_STATE_CHANGE,
  0x56 PD_SVOOC, 0x57 PLUGIN_IRQ, 0x58 APSD_DONE, 0x59 CHG_STATUS_GET, 0x60 CHG_STATUS_SET, 0x61 AP_SUSPEND_CHG, 0x67
  ABNORMAL_PD_SVOOC_ADAPTER.

What 0369 does (`negroni_chg_glink.c`):
- `chg_rx` marks these notifications; the thread handles them every 50 ms (`vooc_events`, from `idle()`).
- 0x52: always park the PMIC charger (also with VOOC off: if the ADSP starts VOOC, the PMIC must not feed in parallel
  [I]); with `negronichg_vooc=0` also write USB_VOOCPHY_ENABLE = 0 again.
- 0x48: read and decode the status; PRESENT/ONGOING: keep parked, cool-down 0, adapter id -> power class
  (`adapter_id_table`, oplus_vooc.c:134-176, capped at 80 W as oplus_configfs.c:3114-3136); any other code: un-park
  (our ICL `negronichg_ma`, not stock's 0xFFFFFFFF; BATT_CHG_EN 1 unless the 0277 loop stopped charging).
- 0x59: `BATT_SEND_CHG_STATUS` = 1 only when not parked, not stopped, no 0x61. 0x60: un-park. 0x61: no VOOC until unplug.
- Recovery after 8.5 s without ONGOING: as stock (RESET_AGAIN only with VOOC allowed).
- Policy every `negronichg_loop_s` (5 s) with USB in: `negronichg_vooc=0` (default): once per plug, USB_VOOCPHY_ENABLE
  read; when not 0, write 0 (plain charging; stock's own "off" path). `negronichg_vooc=1`: send MATCH_TEMP, then allow
  VOOC (enable 1) only when: battery temperature known and 12.0-43.0 C (stock lets the ADSP go to its 45 C warm band),
  the 0277 loop has not stopped charging, no 0283 thermal FCC level, no 0x61, adapter type DCP (SVOOC adapters show as
  DCP). Else enable 0 and un-park. While parked, the 0277 loop and the 0274 ICL/un-suspend/CHG_EN writes stop (the
  ADSP's VOOC path owns the battery); a stop band still disables VOOC first, then stops charging.
- Telemetry: status struct `vooc_mode`, `vooc_enable`, `vooc_active`, `vooc_code`, `vooc_adapter`, `vooc_mw`. Log
  every 30 s while ONGOING: `NEGRONI BATTERY: glink: vooc: ONGOING adapter 0x.. (80 W class) | VBUS .. mV IBUS .. mA =
  .. mW | battery .. mV .. mA | .. C`. The 0365 `AdapterDetails` Watts already use USB_VOLT_NOW x USB_CURR_NOW, so the
  UI shows the real power if the ADSP keeps those current during VOOC [I, not proven]. No Apple FamilyCode exists for
  VOOC; FamilyCode stays from USB_ADAP_TYPE (DCP 0xe0004004).

Review fixes (Opus; 0369 was REJECT until B1/B2):
- B1: VOOC turned off while ONGOING: write ENABLE = 0 but stay parked; un-park only on a status that is not ONGOING
  (0x48, or the loop's own status read); a direct un-park only when not ONGOING and ENABLE reads back 0.
- B2: `vooc_park` sets "parked" only when BATT_CHG_EN = 0 and ICL = 0 were both acked; else "park pending": the PMIC
  writes stay blocked, ENABLE = 0 is written, and the park writes are retried every 1 s.
- F5: before the 8.5 s recovery un-park, USB_VOOCPHY_STATUS is read again; code 2 = ONGOING, no un-park.
- F6: `negronichg_vooc=0`: ENABLE = 0 (when it does not read 0) at READY and at each USB in, in cycle() (also with
  `negronichg_loop=0`). Note: stock writes usb 13 only for a DCP; this write is class 0x10 of 0370's `negronichg_wr`.
- F7: the VOOC state and icl_set/chg_en_set are reset when the PD stops answering or PMIC_RTR_ADSP_APPS closes (ADSP
  restart); while ONGOING, the loop reads the status every 5 s and un-parks when it is not 2.
- F8: BATT_SET_MATCH_TEMP is sent whenever VOOC is ONGOING, in any mode.
- 0368's PHY repair does not run while `vooc_active`.
- Re-review N1: at READY (also after a lost-read reset), USB_VOOCPHY_STATUS is read before any PMIC write; ONGOING
  parks the PMIC again (`vooc: status ... (READY check)`). N2: the park saves the ICL read before it; the un-park writes
  the limit for this adapter type (0370), else the saved ICL, else 500 mA (never the park's 0, also with
  `negronichg_ma=0`), and resets the ICL/CHG_EN/un-suspend write budget.

Limits: no current table is sent (the ADSP has its own); the stock maximums (vooc-max-input 10000 mV / 6500 mA, 80 W)
are the ADSP's. Our temperature window is narrower than stock. [I] Risk: the PMIC + VOOC parallel feed if a 0x52 is
missed (we always park on it, and an ONGOING without 0x52 also parks).

Test (only after the USB fix, README-usb.md "0368", works with the ADSP up):
1. `negronichg_glink=1 negroniadsp=1 ...` (VOOC off): with the Mac cable expect `vooc: USB_VOOCPHY_ENABLE reads 0
   (negronichg_vooc=0): plain charging` or `vooc: enable 0 (...): read back 0`. With the OnePlus SuperVOOC adapter:
   no `vooc: status ... ONGOING`; plain 5 V charging (`charge:` line ~5 V).
2. `negronichg_vooc=1` with the SuperVOOC adapter and cable, battery 12-43 C: expect `vooc: enable 1 (DCP, ...)`,
   `glink: rx ... (BC_NOTIFY_IND)` with 0x52, `vooc: handshake starts (0x52): PMIC charger parked`, `vooc: status
   0x..: PRESENT ... adapter id 0x4b..0x4e or 0x65 (80 W class)`, `ONGOING`, then the 30 s `ONGOING ... mW` lines
   (expect 30-80 W at low SoC). Watch the battery temperature line; unplug at any doubt. A failed handshake shows
   `no ONGOING 8500 ms after the handshake (recovery #1)` and plain charging continues.

## 16. USB lost after the charger client starts: write list, stock comparison, bisect boot-args (0370, 2026-10-27)

Phone [V, main session, t8 03:19-03:20, kernel local-20261026-214742, `negroniadsp=1 negronichg_glink=1`]: the PHY
snapshots at the ADSP start and at ADSP up equal the baseline, no PHY change; `glink: start` at 03:20:26, the Mac loses
the device at 03:20:28. So 0368's PHY repair did not trigger; the PHY registers did not change. [I] The trigger is near
our first charger traffic.

What the client sends in its first seconds (0274/0277/0365/0369 code order, USB in, Mac port):
1. Reads (GET, no writes): battery 0 STATUS, OEM read buffer 0x10000, 4 CAPACITY, 7 VOLT_NOW, 9 CURR_NOW, 12 TEMP,
   10 CHG_CTRL_LIM, 8 VOLT_MAX; usb 0 ONLINE, 1 VOLT_NOW, 3 CURR_NOW, 5 ICL, 7 ADAP_TYPE, 47 IN_STATUS, 26 SUSPEND_PMIC.
2. READY: BC_SET_NOTIFY_REQ (0x04), then a dump: GET battery ids 0..24, usb ids 0..11.
3. Plug edge: `USB_INPUT_CURR_LIMIT` (usb 5) = 500000, 1000000, 1500000 uA (100 ms apart, VBUS read in between).
4. `USB_SUSPEND_PMIC` (usb 26) = 0 only if it read non-zero; `BATT_CHG_EN` (battery 24) = 1.
5. 0369 (after review F6) with `negronichg_vooc=0`: at READY and at USB in, GET usb 13 and, if it is not 0, SET usb 13 = 0
   (up to 3 tries). Charge loop: GET battery 12; then `BATT_VOLT_MAX` (8) = FV and `BATT_CHG_CTRL_LIM` (10) = FCC (band values, <= 4435 mV/cell,
   <= 1100 mA).

Stock at boot (oplus_battery_sm8450.c, oplus_charger.c) [V]: BC_SET_NOTIFY_REQ (probe :12740, subsys up :3402); ICL
per adapter type `oplus_chg_set_input_current` (oplus_charger.c:7031-7046): **SDP = `qcom,input_current_usb_ma` =
500 mA**, CDP 1500, DCP 2000, unknown type = no write; USB_VOOCPHY_ENABLE only for a DCP (:1585-1602); BATT_SET_MATCH_TEMP
at probe (:12755); FV/FCC by oplus_chg. Differences in ours: **1500 mA on a host port** (3x stock) and the usb 13 write
on any adapter type.
[V] ADSP strings: `battmngr_plat_*_set_usb_icl::ICL for SDP/CDP set by HLOS is %d mA`, `...set_usb_icl::ERROR suspending
USB` / `Unsuspending USB` (an ICL write can suspend/unsuspend the USB input), `battmngr_tech_schgp_chg_rerun_apsd`,
`PmSchgUsb_SetRerunApsd`, "port_type[%d]:Enable BC1.2 Retry", "reset voocphy & fastchg rerun check". No string ties
a HLOS property write to an APSD rerun directly.
[I] Candidates: (a) 1.5 A from a Mac port: macOS cuts the port power on overcurrent ("USB accessories disabled"), which
looks exactly like "no USB device at all"; check the Mac for that alert / `log show --last 10m | grep -i overcurrent`.
(b) the usb 13 (VOOC PHY enable) write makes the ADSP reset its VOOC PHY and re-run detection on D+/D-.

0370 (`negroni_chg_glink.c`):
- ICL per adapter type (default `negronichg_icl_bytype=1`): SDP min(negronichg_ma, 500), CDP min(.., 1500),
  DCP/PD/other known types (>= 5) negronichg_ma; unknown type 0, ACA 4 and a failed type read (-1): no ICL write
  (stock maps ACA to the DCP 2000 mA; we write nothing), except (re-review B3) a 500 mA floor when the ICL reads
  below 100 mA and VOOC does not own the path (e.g. after a VOOC recovery wrote 0). `negronichg_icl_bytype=0` = 0274
  (negronichg_ma for all).
- Re-review N3: the VOOC safety writes (park BATT_CHG_EN 0 + ICL 0, the recovery ICL 0, a reactive ENABLE = 0 on
  0x52/ONGOING/turn-off, the un-park restore) ignore `negronichg_wr` and `negronichg_wr_delay_s`. The proactive
  ENABLE = 0 at READY / USB in (class 0x10) obeys them; when the delay ends, the deferred BC_SET_NOTIFY_REQ is sent and
  the proactive ENABLE = 0 runs (`glink: the write delay (N s) ended`).
- The 0369 VOOC-off write of usb 13 (review F6: at READY and USB in, any adapter type) is class 0x10: `negronichg_wr=0x6f` skips it.
- Bisect: `negronichg_wr=<mask>` (default 0x7f): 1 ICL, 2 USB_SUSPEND_PMIC, 4 BATT_CHG_EN, 8 FV/FCC, 0x10 VOOC
  (usb 13/25, battery 28/29/37), 0x20 BC_SET_NOTIFY_REQ, 0x40 other. `negronichg_wr=0` = read only.
  `negronichg_wr_delay_s=N`: no write for N s after the client start. Skipped classes log once:
  `glink: write ... skipped: off by negronichg_wr (class 0x..)`. Every write line now ends with `+N ms` since the start;
  the start line: `glink: writes: class mask 0x7f ..., delay 0 s, ICL per adapter type on`.
- Bisect order (each a RAM boot with `negroniadsp=1 negronichg_glink=1`): `negronichg_wr=0` (reads only) -> if USB
  holds: `negronichg_wr_delay_s=60` (then watch the time of the drop vs the `+N ms` write lines in the 0367 boot log)
  -> single classes `negronichg_wr=1`, `=4`, `=8`, `=0x20`. The default build (per-type ICL = 500 mA on the Mac) is
  itself the test of candidate (a).
