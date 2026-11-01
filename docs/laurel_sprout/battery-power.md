# Mi A3: battery, charger, charge-only boot, power off, thermal + cpufreq (area D, patches 2300-2303)

Status 2026-11-01 05:10: unattended-safety follow-up built on laurel-int-1 (`areaD-k2306`: 231 patches applied, 0 LSE;
kernel sha256 7bda8194fc8e77b3867535c5a4202e25ce1023a988ccfcfb278eea475131c6bb). Final safety check of 58b85b8:
SAFE-TO-TEST (supervised bench test); this follow-up is for unattended charging. NOT BOOTED. [V] = read in files / build,
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
| 2710 | `sweet_spmi.c` = the one SPMI core: one transaction lock and one channel map for keys, PON lane, battery/charger/ADC/SDAM/thermal, USBIN lane and vibrator (section "SPMI: one core") |

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
  [U until boot]. Self-check, in order: a working battery NTC (else `off: no battery NTC`), owner EE 0 for 0x210 and
  0x213, FV read + write-back, hardware JEITA hard limits (0x1098/0x1099 hot, 0x109a/0x109b cold, MSB first) near the
  Linux codes 0x15aa (60 C) / 0x6894 (0 C) of `qcom,jeita-hard-thresholds` (smb5-lib.c smblib_update_jeita), written
  and read back when not; JEITA_EN_CFG 0x1090 is logged. Any failure: `LAUREL CHARGER: off: ...` (reads stay; the
  hardware keeps charging on its boot defaults). The boot FCC/FV are saved.
- NTC watchdog: no good NTC sample for 30 s -> FCC 500 mA, FV 4100 mV, control off
  (`off: no battery NTC sample for 30 s; FCC 500 mA FV 4100 mV (safe)`). A stale temperature is never used for a zone.
  It runs first in every sample (before a gauge read can return early) and from its own 10 s thread_call, so a
  stopped SweetBattery poll does not stop it.
- Every control-off: ICL HW_AUTO, input un-suspended, 500 mA / 4100 mV first; the boot FCC/FV come back only when
  they are not above that. Control cannot turn on (no NTC, hard limits, no timer) while CHGR/USBIN are EE 0:
  `LAUREL CHARGER: safe limits FCC 500 mA FV 4100 mV without software JEITA`. `laurelchg=0`: no charger writes.
- USB input suspend (0x1340 bit 0): one left by an earlier boot is released at start (also with control off or
  `laurelchg=0`, while USBIN is EE 0): `LAUREL CHARGER: USB input suspend of an earlier boot released`. Ours is
  released in laurel_power_off / laurel_restart over a lock-free USBIN lane (panic hold, timer call).
- Hard-limit accept window only on the safe side: hot code 0x15aa..0x17aa (trips at <= 60 C), cold 0x6494..0x6894
  (trips at >= 0 C); else the Linux codes are written.
- Unplug: ICL back to HW_AUTO (LOAD_CFG 0x1365 bit 4 cleared), input un-suspended, FCC at most 500 mA until the next
  charger step after a plug-in (10 s poll). No ICL wanted (SDP without Rp): HW_AUTO too.
- Input limit (charger in): APSD DCP/QC 2000 mA, float 1000, CDP 1500, SDP: Type-C Rp 3.0 A -> 2000, 1.5 A -> 1500,
  else the hardware's 500 mA; written as smb5-lib SW_OVERRIDE_HC_MODE (ICL_OPTIONS bit 0, no ICL override,
  LOAD_CFG bit 4). AICL stays on (weak adapters). DT: `qcom,usb-icl-ua = 2000000`, `fcc-max-ua = 3000000`,
  `fv-max-uv = 4400000`.
- JEITA (software, NTC): < 0 C 0 mA, 0-10 C 400, 10-15 C 1200, 15-44 C 3000 (FV 4400), 44-58 C 1500 at 4100 mV,
  >= 58 C 0; to more current only 1.5 C inside the zone. Warm zone: VBAT > FV + 50 mV -> USB input suspended
  (USBIN_CMD_IL 0x1340 bit 0) until VBAT < FV - 50 mV (step-chg-jeita.c handle_jeita, JEITA_SUSPEND_HYST_UV);
  `terminated` counts as full only at FV 4400 mV. The battery DT (`jeita-fv-ranges`, hard 0/60 C) gives
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
- Charge mode: before launchd; power key polled every 200 ms (RT status; a shorter press can be missed [I]); a
  console line every 10 s; power off only when the cable is gone: USBIN plug-in RT bit (0x1310 bit 4) clear for 5
  checks 1 s apart (a collapsing or weak charger keeps that bit, the power path may drop: no off/on loop) (`LAUREL CHARGE MODE: battery N% charging, mV mA C`);
  the charger loop runs (SweetBattery 10 s poll). Power key -> boot iOS; charger out 3 s -> power off; 10 failed
  PMIC reads in a row -> `LAUREL CHARGE MODE: off: N PMIC reads failed in a row: booting iOS`.
- [U] Cable power-on that stops in ABL: if ABL shows its own charger screen or goes to fastboot on a cable power-on
  (off-mode-charge setting, low battery), our kernel never runs; then the phone sits in ABL until the power key or
  unplug. Only the owner's test shows which path this ABL takes.
- Every reset selects its own PS_HOLD type (msm-poweroff): power off type 4 (SHUTDOWN) before PSCI SYSTEM_OFF, the
  old type written back if PSCI returns; plain restart type 7 (HARD_RESET; no `qcom,force-warm-reboot` in the Mi A3 DT);
  restart with a reason type 1 (WARM, 2018). The writes are checked and the type is read back; on a failure the
  S2 enable is still set again and one line says `NOT SET: the PMIC keeps its old type`. Power off and restart
  release our USB input suspend first. Before, the type was whatever XBL/ABL left (2018 sets warm reset only for reboots with a reason) [I]:
  a hard-reset type turns the PS_HOLD drop into a reboot. Line: `LAUREL REBOOT: PS_HOLD_RST_CTL 0x.. -> 0x..4 (shutdown)`.
- [U] Whether a power off with the charger in powers on again (cable PON trigger level vs edge). If it does, the
  next boot is a charge-mode boot (cold, charger reason), which is the wanted result.

## Thermal + cpufreq (2303) [V source]

- OSM (not cpufreq-hw): `qcom,clk-cpu-osm-trinket`, pwrcl 0xf521000 (Silver), perfcl 0xf523000 (Gold); LUT 0x110 +
  32 * row, 12 rows; perf state 0x920. topaz 0094 used the same Gold offsets (`CPUFREQ gold 0->7 (2016 MHz)` on the Mi A3).
- Governor (100 ms): busiest core per cluster over 300 ms; > 90 % -> cap, > 70 % -> +1 row, < 30 % for 300 ms -> -1
  row; governor floor = ABL row (Gold: row 0 = 300 MHz, from the topaz line "gold 0->7"); the thermal cap may go
  below the floor, down to row 0 (the cap wins). Sensors count in -40..125 C; one sensor more than 20 C above all
  others is ignored (outlier). Self-check accepts -40..125 C (cold start) and prints the cap range.
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
- [V] Fixed by 2710: the PON APID was also polled by the `SWEET KEYS` thread without a lock (review m2). Now every SPMI
  user takes the one lock of `sweet_spmi.c` (section "SPMI: one core"). The two agreeing PON reads stay.
- [I] Our SDAM record 0xb1a8-0xb1ae is past the Linux QG area (0x45-0xa3) and below the PBS PON OCV (0xbc), but no
  source proves the bytes free (review m1). If Android boots again, its QG ignores them.

## SPMI: one core (2710, 2026-11-01 06:40, branch t3/laurel-spmi-phantom-keys)

Bug [V, logs/usblog-20261101-001446.txt, boot 06:17, nobody touched the phone]:
- `SWEET KEYS: key=0 down=1 pon=0x7f` + `key=2 down=1 pon=0x7f`, then both up, at 06:19:17, 06:19:27, 06:19:37
  (pon 0x7f, 0x57, 0xc1): exactly every 10 s. Vol-up the same: `key=1 down=1 ... gpio4:c110=0x78` (also 0x28, 0x80,
  0x18, 0x34, 0x2, 0; bit 0 low = pressed) at 06:13:05, :15, :25 and later, each released 1 poll later.
- `SWEET KEYS: read error pon-ok=1 gpio-ok=0 arb-status=0x9` (05:55:20, 06:07:35, 06:15:26): STATUS 0x9 = DONE +
  DROPPED (spmi-pmic-arb.c PMIC_ARB_STATUS_DROPPED = bit 3). Earlier boot: `pon-ok=0 gpio-ok=1 arb-status=0x1`
  (05:30:11..05:54:50; the printed status was the GPIO read's, the PON status was lost) and phantom presses at
  05:29:41-43 (three power presses, then iOS started the endless vibration) and 05:29:59 / 05:30:31 (key=0 + key=2).
- GPIO5 (APID 124) is read by the keys thread only, yet it read garbage: so the cross-talk is between different APIDs.

Cause [V source, I hardware model]:
- Three paths to the one arbiter v5, no common lock: `sweet_keys.c` (topaz 0060/0087: own map, no lock, PON APID 112 +
  GPIO5 APID 124 every 20 ms), `sweet_spmi.c` (IOLock for battery reads/writes; the 2018 PON lane and the 2300 USBIN
  lane without a lock) and `laurel_haptic.c` (2700: own map, own mutex). The 10 s cadence = the charger guard timer
  (`lp_guard_fire`, "retried every 10 s") and the SweetBattery 10 s poll, which run many PMI632 reads.
- [I] The observer channels of one EE are register windows of one command engine, not independent engines: a second
  command while one runs is dropped (status 0x9) or completes with the other command's RDATA (the pon/gpio values above
  look like battery/charger data, not RT_STS bits). Linux never sees this: `spmi-pmic-arb.c` holds `pmic_arb->lock`
  (raw spinlock, irqsave) over every `pmic_arb_read_cmd` / `pmic_arb_write_cmd`. The 2700 note "each APID has its own
  command registers, so the lanes do not race" was wrong.
- [V source] The keys thread took one bad read as a press (no debounce): `now != state` -> event at once.

Fix (2710):
- `sweet_spmi.c` is the one core. One channel map (PPID -> APID, EE 0 entry wins; owner EE per APID), read once in
  `sweet_spmi_init` under a mutex. One transaction lock: a word taken with LDXR/STXR (no LSE), interrupts off, held from
  the command store to the RDATA read (as Linux). DONE wait 1 ms (PMIC_ARB_TIMEOUT_US); FAILURE / DENIED / DROPPED =
  error; a timeout poisons that APID for the boot. Writes only on EE 0 APIDs (rw channel mapped by the core).
- Power off / restart / panic hold (PON lane, USBIN lane) are "emergency" users: if the lock stays busy for 5 ms (a CPU
  stopped by a panic while it held it) the transaction runs without it and is counted (`forced`).
- Users: `pon` (laurel_reboot.c, laurel_pmi632.c PON reasons, charge-mode power key), `keys` (sweet_keys.c), `battery`
  (sweet_spmi_read/_write: laurel_pmi632.c, SweetBattery.cpp, laurel_thermal.c; USBIN lane), `haptic` (laurel_haptic.c).
  Each registers at its start; no driver maps the arbiter itself any more.
- Keys: a key changes state only after 2 polls in a row (20 ms apart) read the new state with a clean status; a failed
  read never changes a key and breaks the run. Press latency +20 ms [I: not felt].

Expected lines:
```
SWEET BATTERY: SPMI arb=0x50010000 APIDs=256, observer reads; PON APID 112 rw lane mapped
LAUREL KEYS: on: power+vol-down polled (PON APID 112), vol-up polled (PM6125 GPIO5 APID 124); shared SPMI lock, a change needs 2 agreeing reads
LAUREL SPMI: on: arbiter 0x50010000, 256 APIDs, one lock and one channel map for every transaction; users: pon keys battery haptic; spmi errors pon 0 keys 0 battery 0 haptic 0, forced 0
LAUREL BATTERY: on: PMI632 QG soc N% ... icl N mA charging; spmi errors pon 0 keys 0 battery 0 haptic 0, forced 0
```
The `LAUREL SPMI` line comes 60 s after the first SPMI init (users that started by then; the haptic user registers when
iOS opens the vibrator, so it can be missing there). The error counts repeat in the 5-minute `LAUREL BATTERY` line.
Test: phone untouched for 5 min: no `SWEET KEYS: key=` line, error counts 0 (or a few, never a key event).

## Review 2026-11-01 (ACCEPT-WITH-FIXES) and what changed

| Item | Fix |
| --- | --- |
| B1 | charger control only with a working NTC; 30 s without a good sample: 500 mA / 4100 mV, control off |
| M1 | hard JEITA thresholds checked (written to the Linux codes if needed, read back); boot FCC/FV restored on control off |
| M2 | ICL HW_AUTO (0x1365 bit 4 clear) on unplug and when no ICL is wanted |
| M3 | warm-zone input suspend (0x1340 bit 0) above FV + 50 mV; full only at FV 4400 |
| M4 | uAh is the SoC master value; written back only on a clamp or correction |
| M5 | charge mode leaves after 10 failed reads in a row; ABL cable-power-on case documented |
| M6 | power off restores the old PS_HOLD type if PSCI returns; plain restart selects HARD_RESET |
| M7 | thermal cap down to row 0; self-check prints the cap range |
| m4, m5, m6 | timestamps (30 s) for rest/empty; safe FCC at unplug; sub-zero thermal self-check |
| m7 | power key polled every 200 ms (RT status; latched status not used: its latch depends on the IRQ enable [I]) |
| m1, m2, m3 | documented / not done (see Risks) |

## Safety re-check 2026-11-01 (FIX-FIRST) and what changed

Rebased onto `origin/laurel-int-1` (A, C, H). The `bsd/conf/files` entries moved after `sweet_i2c1.c` so that
2700's hunk (context `sweet_cpufreq.c` / `topaz_fw.c`) still applies after ours.

| Item | Fix |
| --- | --- |
| MUST 1 | NTC watchdog before every early return of the sample + own 10 s thread_call |
| MUST 2 | every control-off writes 500 mA / 4100 mV first; boot limits only when not above; safe limits when control cannot turn on |
| MUST 3 | USBIN_CMD_IL bit 0 released at start (also control off) and in power off / restart (lock-free lane) |
| SHOULD 4 | hard-limit window only on the safe side |
| SHOULD 5 | TSENS -40..125 C, single outlier > 20 C ignored |
| SHOULD 6 | PS_HOLD writes checked + read back; charge mode powers off only after the plug-in RT bit is clear 5 s |
- [I] Silver/Gold rows below what topaz used: the OSM handles the voltage (CPR) in hardware, as under Linux.

## Unattended-safety follow-up 2026-11-01 (on top of 58b85b8)

| Item | Fix |
| --- | --- |
| F1 | a failed safe write sets `lp_safe_pending`; the 10 s guard timer retries 500 mA / 4100 mV until the read-back is good and never stops while one is pending (`LAUREL CHARGER: safe limits ... written after N retries`) |
| F2 | `set_fcc_fv` writes FV (then FCC, both read back) also when the FV read fails |
| F3 | `SMB5 write check failed` now writes the safe limits too |
| F4 | battery self-check failures after the SPMI start (QG type, no battery, implausible vbat): input suspend released and safe limits written when CHGR/USBIN are EE 0 (`LAUREL CHARGER: off: battery gauge off; safe limits ...`). SPMI arbiter not ready / no lock: no SPMI at all, no writes |
| F5 | kill switches below |
| sleep | see below |

Kill switches: `laurelbatt=0` and `laurelchg=0` mean **no PMIC writes at all**: the charger keeps whatever limits it had
(the XBL/ABL defaults, or the limits of an earlier boot, e.g. 3000 mA / 4400 mV). Use them only on a supervised bench.
`laurelbatt=0` also skips the release of a USB input suspend left by an earlier boot.

System sleep [V source, U behaviour]: topaz and SweetPlatformExpert have no CPU suspend path, so whether iOS ever
puts this kernel to system sleep is unknown. The guard timer is a thread_call on absolute time: it does not fire while
asleep (no code runs then anyway). SweetBattery registers an IOPMrootDomain sleep/wake interest; on
`kIOMessageSystemWillSleep` the charger gets 500 mA / 4100 mV (`LAUREL CHARGER: system sleep: safe limits ...`),
and the first charger step after wake writes the zone limits again. The NTC watchdog does not count sleep time
(absolute time stops), so a wake does not trip it.

