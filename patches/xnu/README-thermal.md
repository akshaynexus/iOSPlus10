# Thermal, GPU DCVS and USB reset (patches 0280-0282)

Status 2026-10-26: written, compile-checked, in the full build of the `kernel-pwr` job. Not run on the phone
(it was flat). Marks: **[V]** seen in source, DT, log or build. **[I]** inference.

| Patch | Files | What |
|---|---|---|
| `0280-negroni-thermal-tsens.patch` | `bsd/dev/negroni_thermal.c` (new), `bsd/conf/files`, `bsd/dev/negroni_ufs.c`, `bsd/dev/negroni_cpufreq.c` | TSENS readings once a second, a line a minute, GPU/CPU caps above 70 C |
| `0281-negroni-gpu-dcvs.patch` | `bsd/dev/negroni_adreno.c` | busy-based GX perf-level governor on the watch thread |
| `0282-negroni-usb-reset-reconfigure.patch` | `bsd/dev/negroni_usb.c` | the CDC-ECM data endpoints come back after a host bus reset |
| `0283-negroni-thermal-trips.patch` | `bsd/dev/negroni_thermal.c` | per-zone DT trips instead of the one 70/60 C rule, BCL level reaction, charger FCC level (section "0283") |

## Why

The phone runs hot and drains on USB: the three CPU clusters sit at their top rows from boot (slop
0096/0098, no governor), the GPU gets one HFI vote at level 12 = 818 MHz (0235/0237) and never
slumbers between frames, and nothing reads a temperature [V: docs/notes.md 15-17, README-gpu-kernel.md
12-14]. The first measured numbers come from this patch set.

## 0280: TSENS

- Hardware [V: out/live.dts]: `thermal-sensor@c263000` (tsens0) and `@c265000` (tsens1), compatible
  `qcom,tsens-v2`, 16 sensors each, `reg = <TM 0x1ff, SROT 0x1ff>` (SROT at 0xc222000 / 0xc223000).
  Thermal zones map the sensors: tsens0 0 aoss-0, 1-4 cpuss-0..3, 5-13 cpu-1-0..8 (the A710/X2 cores),
  14-15 gpuss-0/1; tsens1 0 aoss-1, 1-4 cpu-0-0..3 (A510), 5-7 nspss, 8 video, 9 ddr, 10-13 mdmss,
  14-15 camera.
- Register layout [V: Linux `drivers/thermal/qcom/tsens-v2.c`]: TM `Sn_STATUS` at 0xa0 + 4n, bits 11:0
  the last temperature in tenths of a degree (two's complement), bit 21 valid; SROT 0x0 version,
  0x4 CTRL bit 0 enable (XBL enables it; the patch never writes).
- Thread, every second: all 32 sensors; `cpu` = the hottest cpu*/cpuss*, `gpu` = hottest gpuss*, `ddr`,
  `max` with its name. Log once at start (`tsens0: aoss-0=N cpuss-0=N ...`, both controllers), then
  once a minute and on every policy step:
  `NEGRONI THERMAL: cpu N C gpu N C ddr N C max N C (name) | gpu cap L cpu cap M MHz (n of 32 sensors valid)`.
  The same text is appended to every `NEGRONI GPU WATCH` line (0281).
- Policy, every 10 s: `max >= negronithermal_hot` (70): GPU cap one level down (floor 4 = 350 MHz) and
  CPU cap one step down (3200 -> 2400 -> 1800 -> 1400 MHz, `negroni_cpufreq_cap`, never below the row
  ABL left); `max < negronithermal_cool` (60): one step back up each. Between: nothing.
  `negroni_cpufreq_cap()` is new in `negroni_cpufreq.c` (the EPSS PERF_STATE row per domain, run time).
- Boot-args: `negronithermal=0` (no thread, no caps), `negronithermal_hot=N`, `negronithermal_cool=N`.
- API for 0281: `negroni_thermal_gpu_cap()` (perf level, 12 = none), `negroni_thermal_max_c()`,
  `negroni_thermal_line()`.
- [I] The sensors are valid without Linux (XBL enables TSENS for its own limits); the first
  `tsens0:` line shows -999 for an invalid sensor. If both controllers report `DISABLED`, the thread
  does not start.

## 0281: GPU DCVS

- On the watch thread (the only HFI sender once the GPU is kept; `hfi_send` has no lock): the wait
  becomes 100 ms, the WATCH line still comes once a second. Busy = `RBBM_STATUS` bit 23
  (GPU_BUSY_IGN_AHB, mesa a6xx.xml) or a submitted fence the core has not written yet
  (`negroni_gpu_completed() != gpu_fence`).
- Rules: idle 500 ms -> level 4 (350 MHz); busy in two ticks in a row (200 ms) -> one level up; max =
  `negronigpu_level` (unset since 0384 = the governor runs; N = a fixed level, no DCVS), lowered by the thermal cap of 0280. The bw
  level follows the GX level (3 at the floor, 11 at the top). A vote happens only when the level changes
  (`GX_BW_PERF_VOTE`, blocking ack, quiet: no send/ack lines).
- Starts after the 0236 late report (watch second 5), from the 0235 vote level.
- Log: `NEGRONI GPU DCVS: on: start level 12 (818 MHz), max 12, floor 4, tick 100 ms, idle 500 ms, up 200 ms`,
  then at most one line a second: `NEGRONI GPU DCVS: level 12 -> 4 (350 MHz, bw 3), 1 changes this second,
  busy 7%, cap 12`; the WATCH line gains `dcvs L busy N% | <thermal line>`. `gxclk` on the WATCH line
  shows the real clock (0236).
- Boot-arg `negronigpu_dcvs=0`: the fixed vote of 0235 (the watch back to its 1 s wait).
- [I] 350 MHz is enough for the compositor (backboardd on Metal needs 4.5-8 ms per command buffer at
  818 MHz, docs/plan.md); a frame that arrives at the floor pays up to 200 ms of ramp. Measure with the
  1-second `NEGRONI FB STAT` and the ctc numbers, Metal on. No IFPC/slumber yet: the GX rail stays on.

## 0282: USB bus reset

- [V: logs/usblog.log 01:17-01:22, 01:32, 02:03-02:05] "phone interface gone" then "en10 up" 3 s later,
  then no kernel line and `settime: no reply` until the next boot. The kernel still answered the
  enumeration (the Mac saw the ECM interface again), so it was alive; no frame moved.
- [V: negroni_usb.c] On a bus reset (DWC3 device event type 1) the driver only cleared the address.
  `ud.configured` stayed true, so the host's next SET_CONFIGURATION(1) returned early in
  `ud_configure()`: no DEPSTARTCFG, no RX TRB, `tx_busy` possibly stuck.
- Fix: on the reset, if configured: DALEPENA back to EP0, `tx_busy` = false, `configured` = false,
  `data_alt` = 0, link-down event; `NEGRONI USB: bus reset: data endpoints dropped until SET_CONFIGURATION`.
  The next SET_CONFIGURATION runs `ud_configure()` again. Boot-arg `negroniusb_resetdrop=0` = old behaviour.
- [I] What makes the Mac reset the bus in the first place is not known (the Mac's unified log for the
  period returned nothing for the USB host subsystem). Candidates: the phone not answering a transfer in
  time while the kernel is busy, or the CPU/GPU load; the fix only makes the link come back.

## 0283: thermal parity with the DT trips (2026-10-26)

Status: built in the full set (`pwr-build`, image `out/ios16-pwr`), **not booted**. Fallbacks: `negronithermal=2`
(the 0280 70/60 C rule), `negronithermal=0` (off).

Why [V audit docs/audit/2026-10-26-power.md items 3, 4, 13]: 0280 acts at 70 C on the hottest of all 32 sensors
(modem/aoss/nspss count too) and pulls the GPU and CPU caps down during the 80 C boot burst; the DT acts per zone
at 95-110 C (GPU/CPU), at 53 C for the OPLUS IPA zone, and on the BCL levels.

The trips (checked every second; DT = out/live.dts thermal-zones):

| Trip | Sensor | On / off | Android (DT) | Here |
|---|---|---|---|---|
| `cpu-110C` | any cpu-0-x / cpu-1-x core (not cpuss) | >= 110 / < 100 C | cpu4-emerg0-cfg :8042, cpu0-emerg-cfg :8509 (0x1adb0, hyst 0x2710) -> thermal-pause of the core | CPU cap = the deepest row (`negroni_cpufreq_cap(0)`: the ABL row, or the LUT minimum with 0291 `lut`) |
| `gpu-95C` | gpuss-0/1 | >= 95 / < 90 C | tj_cfg :8404/:8446 (0x17318, hyst 0x1388) -> gpu0_cdev 0..max :8414 | GPU cap -1 level per second while on, +1 per second below 90 C (floor level 4) |
| `ipa-53C` | skin thermistor 0x146 (proxy) | >= 53 / < 51 C | oplus_thermal_ipa ipa-control-temp :10275 (0xcf08, hyst 0x7d0) -> cpufreq cooling of cpu0/4/7 | one CPU cap step per 10 s (3200/2400/1800/1400/deepest), back one per 10 s |
| `xo-78C` / `xo-80C` | pmk8350_xo_therm 0x44 | >= 78 / < 70 C, >= 80 / < 70 C | xo-config0/1 :10087/:10094 -> cpu4/7 freq 15..max, apc1 pause, cdsp, gpu 7 (:10132-10152); 80 C pauses cpu5-7 | CPU cap deepest, GPU cap level 5 (421 MHz) |
| `ddr-90C` | ddr | >= 90 / < 85 C | ddr0-config :8812 (0x15f90, hyst 0x1388) -> gold/gold-plus cpufreq (:8828) | one CPU cap step per 10 s |
| `bcl-lvl0/1/2` | PM8350B BCL 0x4708 bits 0/1/2 | bit set / clear for 10 s | pm8350b-bcl-lvl0/1/2 :9602-9764 -> gpu 2/4/7, cpu5 / cpu6-7 pause, modem, cdsp | GPU cap 10/8/5 (734/599/421 MHz), CPU cap 2400/1800/1800 MHz |

- GPU levels: kgsl cooling state k = DT `qcom,gpu-pwrlevel@k` (818, 791, 734, 640, 599, 545, 492, 421, 350, 317,
  285, 220 MHz for k = 0..11, live.dts gpu-pwrlevels) = our level 12 - k (`gpu_khz[]`, negroni_adreno.c:1539) [V].
- BCL status register: `BCL_IRQ_STATUS` 0x08 of the BCL block, bits L0/L1/L2 = 0x1/0x2/0x4 (bcl_pmic5.c:27, 41-43;
  `bcl_read_lbat` :495-507) [V]. Read through the SPMI observer (`negroni_spmi_read`, SID 3 0x47 is on the read
  allowlist); before NegroniBattery's SPMI init the read fails and the BCL trips stay off.
- With the default `negronicpufreq_floor=abl` every CPU cap of 0280/0283 is a no-op for d1 (A710) and d2 (X2): their ABL rows (17, 20) are their top rows and no cap goes below the ABL row [V negroni_cpufreq.c `negroni_cpufreq_cap`, README-cpufreq.md]. Until `lut` only the d0 caps and the GPU caps act (LMh still throttles in hardware).
- No core pause exists here (XNU has no hotplug for this port) [I]: "pause" becomes the deepest CPU row.
  The cpufreq cap is global (all three domains) [V negroni_cpufreq.c `negroni_cpufreq_cap`].
- The IPA sensor of Android is an OPLUS virtual shell sensor (`oplus,oplus-thermal`, live.dts:36782-36803, used by a
  userspace governor) [V]; the skin thermistor is a proxy [I]. Skin and XO come from the battery service (0278) in
  `negronibatt=4/5` only (the VADC owner); without them `ipa-53C`/`xo-*` stay off.
- Charger FCC level for 0277 [I design: no DT zone uses the charger cooling device; the Android thermal HAL does]:
  skin >= 45 C (off < 43 C) -> level 3 = 1000 mA; `ipa-53C` or `xo-78C`/`xo-80C` -> level 4 = 500 mA (DT
  `qcom,thermal-mitigation` :6647). The battery-temperature bands themselves are in 0277 (JEITA).
- Also fixed: `cpu` in the line is now the core sensors only (`cpu-` prefix; `cpuss` separately, audit item 3); a
  TSENS controller that is not mapped is skipped (0280 read it at address 0 + offset).

Log lines:
```
NEGRONI THERMAL: policy DT trips (0283): cpu-110C, gpu-95C, ipa-53C (skin proxy), xo-78C/80C, ddr-90C, bcl-lvl0..2; ...
NEGRONI THERMAL: trip gpu-95C ON (value 952, on at 950, off below 900)
NEGRONI THERMAL: trip bcl-lvl0 ON (BCL status 0x4708 = 0x1)
NEGRONI THERMAL: cpu 52 C cpuss 49 C gpu 96 C ddr 47 C skin 38 C xo 41 C max 96 C (gpuss-0) | gpu cap 11 cpu cap 3200 MHz chg lvl 0 | trip gpu-95C [step] (32 of 32 sensors valid)
```
The line is also the `NEGRONI GPU WATCH` suffix (0281 copies 160 bytes: the trip list may be cut there; the
`NEGRONI THERMAL:` line itself has 256).

Risks: [I] the per-zone trips act much later than the 0280 rule (95/110 C instead of 70 C): the skin can get warmer
before anything acts (LMh still throttles in hardware, audit row 10). `negronithermal=2` gives back the 0280 rule.
[I] The skin proxy for the IPA zone reads lower or higher than OPLUS's shell estimate. [U] The BCL bits were
never seen set (no brown-out log with 0283 yet).

