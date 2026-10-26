# Thermal, GPU DCVS and USB reset (patches 0280-0282)

Status 2026-10-26: written, compile-checked, in the full build of the `kernel-pwr` job. Not run on the phone
(it was flat). Marks: **[V]** seen in source, DT, log or build. **[I]** inference.

| Patch | Files | What |
|---|---|---|
| `0280-negroni-thermal-tsens.patch` | `bsd/dev/negroni_thermal.c` (new), `bsd/conf/files`, `bsd/dev/negroni_ufs.c`, `bsd/dev/negroni_cpufreq.c` | TSENS readings once a second, a line a minute, GPU/CPU caps above 70 C |
| `0281-negroni-gpu-dcvs.patch` | `bsd/dev/negroni_adreno.c` | busy-based GX perf-level governor on the watch thread |
| `0282-negroni-usb-reset-reconfigure.patch` | `bsd/dev/negroni_usb.c` | the CDC-ECM data endpoints come back after a host bus reset |

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
  `negronigpu_level` (12 in the config; 0 = the table top), lowered by the thermal cap of 0280. The bw
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
