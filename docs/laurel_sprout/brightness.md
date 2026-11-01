# Mi A3 brightness: the slider moves, the panel stays (2026-11-01, patch 2201 fix)

Status: kernel built, NOT BOOTED. Marks: [V] seen in a source or log, [I] inference, [U] unknown.
Patch: `patches/laurel/xnu/2201-laurel-backlight-panel-power.patch` (only `SweetFramebuffer.cpp`, backlight path:
dsiSend, setPanelOn/Level, laurel_bl_set, blWork, blLog, dsiSelfCheck, the AppleARMBacklight setter). Root:
`scripts/laurel/root-brightness.py` (auto-brightness off).

## Owner report and log

Log `logs/usblog-20261101-001446.txt` (main checkout), boot 07:20:52, GPU renderer:
- 07:21:10 `LAUREL BACKLIGHT: on: DCS max 2047 (Samsung s6e8fco), AppleARMBacklight published (RedwoodGPU up: GPU renderer)`
- 07:21:22 `first AppleARMBacklight brightness from backboardd: 128 of 255`, `SWEET FB: panel level 0x203: done`
- 07:27:15 brightness 0 with FadePeriod 184 ms -> `panel level 0x1d7 ... 0xfb: done` (6 lines), display off, 07:27:17 on
- 07:27:28-29 `SWEET BL: backboardd sets brightness 129..237 (fade 0 ms) -> DBV 523..1768` (the 30th line is the
  last: the per-step cap), no `panel level` line after them; the owner saw no change on the panel.

## Findings

1. [V code] The missing `panel level` lines are a log cap, not missing writes: `setPanelLevel` logged its first 8 calls
   only (`logs++ < 8 || !done`). Count in this boot: the start self-check (before the USB log), 0x203, and the 6 fade
   steps = 8. Every later write was silent unless it failed; no `NO DONE` and no `DSI cmd ... not done` line came, so
   the DMA reported DONE for them. So the kernel very likely did send the slider values [I], and the panel did not
   follow them.
2. [V DT] The Samsung s6e8fco panel's command states are all `dsi_hs_mode`
   (`dsi-panel-s6e8fco-samsung-amoled-hdp-video.dtsi:217-227`: brightness, on, off, dimming, ...). The GVO r692a9 has
   brightness and on in LP, off in HS. 2201 (from topaz, whose panel took commands only in LP) sent everything in LP.
3. [V source] Video mode on DSI 2.2+ (trinket = `qcom,dsi-ctrl-hw-v2.3`): Linux `dsi_message_tx` always calls
   `dsi_ctrl_hw_22_schedule_dma_cmd(line)` with line = v_back_porch + v_sync_width + v_active (the first line of the
   front porch): `DSI_DMA_SCHEDULE_CTRL` (0x100) = BIT(28) | line, so the packet goes out in the blanking and not into
   the active video. 2201 never set it. Samsung: 5 + 2 + 1560 = 1567; GVO: 28 + 4 + 1560 = 1592.
4. [I] 2 + 3 are the cause: the DMA completes (DONE), but the panel does not take an LP packet put anywhere in the video
   stream. Not proven: no visible test of any DCS write on laurel exists yet (display off shows the kernel's black
   frame, so 0x28/0x10 cannot be told apart either). A DCS read of 0x52 (brightness) would prove it; not done (BTA in
   video mode is a risk for the link).
5. [V code] Smaller bugs in the same path:
   - `blWork` was a plain thread call: a call entered while it runs can run in parallel on a second thread; now
     `THREAD_CALL_OPTIONS_ONCE` (one walker; entered while it runs = one more run with the latest level).
   - A new value without a fade kept the step of an older fade (it walked instead of jumping).
   - `fBlLast` took the clamped 4 of backboardd's dim to 0 before display off, and the wake used `fBlLevel` (4) when it
     was >= 4: the wake came back at the minimum until backboardd sent its level again.
   - 30 `SWEET BL: ... sets brightness` lines per boot (one per slider step), then nothing.
6. [V strings, 20H392 Preferences/backboardd] the Auto-Brightness switch is `BKEnableALS` in `com.apple.backboardd`
   (shown when MobileGestalt answers `ambient-light-sensor`). [V laurel-device-los] the Mi A3 has a Sensortek stk3x3x
   light sensor, but on the ADSP sensor hub (sensors.qti, `nicobar_qrd_stk3x3x_0.json`): no ALS for iOS here.

## Fix (2201)

- Per panel: `bl_hs/on_hs/off_hs`, `vbp/vpw` in `laurel_panels[]`; `dsiSend` takes the mode from `fDsiHsNow` (set by the
  caller under `fBlLock`; `sweetdsi_hs=0/1` still forces one) and writes `DSI_DMA_SCHEDULE_CTRL` before the trigger;
  DONE wait 50 ms (a scheduled packet waits up to one frame).
- Start self-check (`dsiSelfCheck`): the default level the Linux way; no DONE -> again without the DMA line -> again in
  LP without the line (the old 2201 way) -> off. The way that worked is in the start line.
- `blWork` ONCE + jump on a new unfaded value; wake level = the user's last level.
- Logs: `setPanelLevel` logs failures only (first 8, then every 100th). One line per settled value, 700 ms after the
  last request (`blLog`, at most 200 per boot, then every 50th). The per-step line stays for the first 3 requests.
- Mapping unchanged: DBV = max * (v / 255)^2 (perceptual; apollo 0154), at least 4 while the display is on.
- Auto-brightness: the start lines say `no ambient light sensor for iOS (auto-brightness off)`; the root sets
  `BKEnableALS` false for mobile and root (`root-brightness.py`, `BRIGHTNESS=0` skips).

## Expected lines (next boot)

```
LAUREL BACKLIGHT: on: DCS max 2047 (Samsung s6e8fco: INTF1 hsync 0x57c0028), DCS HS, DMA at line 1567, level 268, 430 nits (estimate), fade 300 ms, AppleARMBacklight waits for RedwoodGPU; no ambient light sensor for iOS (auto-brightness off)
LAUREL BACKLIGHT: on: DCS max 2047 (Samsung s6e8fco), AppleARMBacklight published (RedwoodGPU up: GPU renderer); slider 0..255 -> DBV max * (v/255)^2, one line per settled value; auto-brightness off: no ambient light sensor for iOS
LAUREL BACKLIGHT: brightness 237 of 255 from backboardd -> DBV 1768 (371 nits): panel at it, 14 panel writes, 0 failed
```
If the self-check falls back: `DCS HS, DMA unscheduled (line 1567: no DONE)` or `DCS LP, DMA unscheduled (HS + line
1567: no DONE)`; `LAUREL BACKLIGHT: off: no DONE in HS/LP, with and without a DMA line ...` = feature off.

## Test

Move the slider from low to high: the panel must follow; one `brightness ... -> DBV ...` line per stop. Lock/unlock:
the light comes back at the slider's level. If the panel still does not follow with `DCS HS, DMA at line 1567`, the next
step is a DCS read of 0x52 / 0x0A (port of negroni 0293) to see what the panel holds.
