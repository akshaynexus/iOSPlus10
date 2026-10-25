# Battery level and charging state (patches 0270-0271)

Status 2026-10-25: built with all other `patches/xnu` patches (result below). Not run on the phone yet.

Marks: **[V]** seen in source, DT, firmware or log. **[I]** inference.

| Patch | Files | What |
|---|---|---|
| `0270-negroni-battery-spmi-v7.patch` | `bsd/dev/negroni_spmi.c`, `.h` | SPMI access for the battery service, rewritten for the SM8450 arbiter v7 |
| `0271-negroni-battery-service.patch` | `iokit/Kernel/arm/NegroniBattery.cpp`, `iokit/KernelConfigTables.cpp` | the IOPMPowerSource (AppleSmartBattery key set) and its personality |

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
  SID 1/3 APID map (TYPE/SUBTYPE, owner EE) for later work.
- PMK8350 ADC_TM7 (0x3400): monitors board thermistors only (pa3, msm, cam_flash, hot_pocket,
  wide_rfc, usb_conn, wl_chg, xo) [V DT].
- PM8350B BCL (0x4700): has VBAT/IBAT comparators; its read registers are in the downstream
  `bcl_pmic5.c`, which was not available here [I].
- No battery-related SDAM cell in the HLOS DT (PMK8350 SDAMs: 0x7000-0x9d00, reboot reason, LPG,
  haptics, AMOLED ECM, PON log) [V DT].

## 3. What the patches do

**0270** (`negroni_spmi.c`): arbiter v7 access, same layout as `negroni_keys.c` and patch 0210:
core 0x0c400000 (version, APID count at +4, APID map at +0x2000), cnfg 0x0c42d000 (owner, 4 *
APID), observer 0x0c440000 (0x8000 * EE + 0x20 * APID), chnls 0x0c500000 (0x1000 * APID).
Allowlist: reads of SID 0 0x31xx and of TYPE/SUBTYPE (0x04/0x05) of SID 1/3 peripherals; writes only
to 0x3140-0x3145 and 0x3147, and only if the owner table gives the VADC APID to EE 0. 0x3146 (ADC
enable) is never written. A timed-out channel is not used again. The keys (PON 0x013, GPIO 0x18d),
the reboot reason (SDAM 0x071) and the RTC use other APIDs.

**0271** (`NegroniBattery.cpp` + personality on IOResources): every 20 s it measures VBAT (mean of
4 conversions), USBIN, charge current, input current and skin temperature, then:
- `ExternalConnected` = USBIN >= 4000 mV.
- SoC estimate: OCV curve for a 4.45 V class cell (3300 mV = 0 %, 4400 mV = 100 %; DT vfloat 4435 mV,
  power-off 3300 mV), charge-current compensation (80 mOhm, max 150 mV), coulomb counting of the
  charge current on a charger, never up on battery, never down on a charger, at most 1 %/min down,
  first value directly from the voltage. 0 % only after 5 polls below 3300 mV on battery; else at
  least 1 %.
- `IsCharging` = on a charger, not full and charge current > 50 mA (if the current is unreadable:
  percent < 100). `FullyCharged` = 100 % and charge current < 150 mA.
- Keys: `CurrentCapacity` (percent), `MaxCapacity` 100, `BatteryInstalled`, `ExternalConnected`,
  `ExternalChargeCapable`, `IsCharging`, `FullyCharged`, `Voltage`, `Amperage`, `InstantAmperage`,
  `Temperature` (hundredths of a degree, skin value clamped to 0-45 C), `CycleCount` 0,
  `DesignCapacity`/`NominalChargeCapacity`/`AppleRawMaxCapacity` 5000, `AppleRawCurrentCapacity`,
  `AppleRawBatteryVoltage`, `AppleRawExternalConnected`, `TimeRemaining`/`AvgTimeToEmpty`/
  `AvgTimeToFull`/`InstantTimeToEmpty` 0xffff, `DesignCycleCount9C`, `PermanentFailureStatus`,
  `BatteryCellDisconnectCount`, `built-in`, `CapacityEstimated`, `BatteryData`, `AdapterDetails`
  (FamilyCode 0 when unplugged, 0xe0004007 USB when plugged), the legacy battery-info dictionary,
  and `NegroniBattery*` diagnostics. `AtCriticalLevel` stays false (an estimate must not shut iOS down).
- One log line per change of percent / external / charging / full:
  `NEGRONI BATTERY: estimated 57% 3891mV 0mA 31.20C external=0 charging=0 full=0 usbin=0mV`.

Boot-arg `negronibatt`: `0` no power source (the kernel before this patch), `1` measured (default),
`2` measured + a raw line per poll + the one-time census, `3` static 100 % on AC (old fallback, no
PMIC access). If the arbiter or the VADC ownership check fails, the service publishes the static
fallback and says why.

## 4. Verification

- Kernel build: `scripts/bg.sh kernel-local-batt scripts/kernel/build-local.sh`, see the result in
  `docs/notes.md` (Battery) and `logs/kernel-local-batt.log`.
- On the phone (not done): boot with `negronibatt=2`, capture `make usblog`, and check:
  1. `SPMI arbiter 0x7...`, `VADC 0x3100 APID n owner EE 0 (conversions allowed)`.
  2. `raw vbat` 3300-4450 mV and close to Android's value at the same charge (Android:
     `cat /sys/class/power_supply/battery/voltage_now` gives the pack or cell value; compare
     `vph` and `mid2s`).
  3. Plug/unplug: `usbin` about 5000 mV / 0, `external` follows, `ichg` > 0 while it charges.
  4. Compare the % with Android's after the same rest time; tune `kOcv` / `NB_R_MOHM`.

## 5. Risks

- The PMIC writes are ADC7 conversion requests to the HLOS VADC (what Android does all the time);
  no charger, interrupt or enable register. If the ADSP later uses the same VADC user peripheral,
  requests can collide [I: the ADSP is expected to use its own ADC user]. Use `negronibatt=3`
  (no PMIC access) to rule the driver out.
- The SoC is an estimate: load sag on battery reads low (slew limit hides most), the curve is not
  this cell's profile, and there is no discharge-current coulomb counting. Expect +-10 % [I].
- Units of `ichg_fb`/`iin_fb` (uA after pre-scaling) and the VBAT divider are not verified [I].
- Charging without the ADSP: the PM8350B charger runs on its hardware/XBL defaults; nothing
  configures it (no OPLUS JEITA, no SuperVOOC). `ichg` shows whether it charges at all [I].
- Temperature is the skin thermistor, not the cell.

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

- Apply order: after the slop patches and 0200-0260 (name order). 0270 replaces the file that only
  NegroniBattery uses; `bsd/conf/files` is unchanged (0231/0240 context lines stay valid).
- Default on (`negronibatt=1`). Add `negronibatt=2` to the debug image boot-args for the first test.
- Reference sources: `scripts/battery/fetch-sources.sh` (Linux upstream, OnePlus official) into
  `out/research/battery/` (git-ignored).
