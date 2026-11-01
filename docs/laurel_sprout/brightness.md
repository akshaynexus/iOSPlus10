# Mi A3 brightness: the slider moves, the panel stays (2026-11-01, patches 2201, 2871)

Status: 2201 fix BOOTED at 18:40: the panel still does not follow. 2871 built, NOT BOOTED. Marks: [V] seen in a source or log,
[I] inference, [U] unknown.

## Boot 18:40 (logs/laurel-boot-1840.txt, kernel with the 2201 fix): the owner says the slider does nothing

Every SWEET BL / LAUREL BACKLIGHT line of the log, read:
- [V log] The slider reaches the kernel. iOS writes the legacy property: `FadePeriod = 0`, `brightness = N`, `backlight-level = N`
  (18:45:05: 123, 116; 18:45:07 settled `brightness 255 of 255 -> DBV 2047: panel at it, 52 panel writes, 0 failed`). Settled values
  in the whole boot: 128, 0, 128, 0, 128, 255, 0, 255, 0: one drag; the rest is lock/unlock (`FadePeriod = 12124` = 184 ms).
- [V code] `only 3 SWEET BL: backboardd sets` lines = the cap `fLogged < 3`, and the `backlight set` lines stop at the cap of
  `sweet_bl_log`. Neither is a missing request. The settled-value line is the real record.
- [V log + code] `brightness-nits = 0` and `IOMFBBrightnessLevel = 0` come once at 18:41:12, before the first `brightness`: at most
  one write of DBV 4, then 128. After that `fBlSlider` makes the framebuffer ignore IOMFBBrightnessLevel. `brightness-nits-cap`,
  `CompensationTweak`, `DisplayBrightnessSliderPosition`, `DisplayBrightness` are logged and read by no code. None of them stops the slider.
- [V log] root-brightness.py broke nothing: same property path as the 07:27 boot (`brightness`, FadePeriod 0) with BKEnableALS false.
- [V notes section 15] negroni's path on the iOS side is the same (legacy `brightness`, `FadePeriod`, `backlight-level` in
  IODisplayParameters); there the DCS goes in LP to a command-mode panel. On laurel only the panel side differs.
- [V log] The kernel writes: 52 writes for the drag, 0 failed. The wake runs: `panel sleep out, display on: done`.
- So: every step up to the DMA is proven; the panel does not follow in LP without a line (07:27) and in HS with a line (18:40).
  [V code] DONE says only that the DSI sent something. [U] No read has ever shown what the panel holds. The cause is not settled by
  this log. The start line with the way (`DCS HS, DMA at line ...`) was lost before USB came up.

## 2871: send as Linux, read the panel back

Differences from `dsi_message_tx` / `kickoff_command` found [V dsi_ctrl.c, dsi_ctrl_hw_cmn.c], now the same: DMA FIFO watermarks off
(`DSI_DMA_FIFO_CTRL` 0x50 bits 16, 20), line = 1 + v_bp + v_sw + v_active (line_no starts at 1: Samsung 1568, GVO 1593), TPG DMA FIFO
reset after each command (0x15c = 0, 0x1ec pulse), `53 20` also at start (only a wake sent it; [V DT] Linux sends `53 xx` + `51` first).
[I] The watermarks are the best candidate among these; not proven. Checked and equal: packet bytes `03 00 39 c0 51 hi lo ff`, 8 bytes,
offsets, trigger, MSB first.

Self-check at start (`dsiReadCheck`, boot-arg `laurelbl_read=0` is the kill switch):
1. DCS 0x0A through the memory DMA in LP, in HS, then the TPG FIFO (`kickoff_fifo_command`: no bus master, so bad DMA data cannot
   explain a failure there; topaz-woa says this path is a no-op on DSI 2.4.1, [U] on laurel's 2.3). The first that answers stays,
   for writes too. A read has its bus turnaround in the blanking in every way; CMD_MODE_EN stays on until BTA_DONE (bit 20).
2. 0x52 after two written levels (268 + 16, then 268) in each way (DT mode, other mode, both with and without the DMA line). The first
   way where both follow stays. Two values: the boot chain's level could be ours by chance.
3. No answer at all or no way follows: writes go on as before, one line says it. Never off for this: a failure costs only the check.

Each settled-value line adds what the panel holds. If 0x52 followed at start and differs now, the next way gets the level (at most 4
moves per boot). 3 reads without an answer: reads off. [V dsi_display.c dsi_display_white_reg_read] The Samsung panel answers reads in
video mode under Linux. [I] Risk: a turnaround in video mode may disturb one frame: 16 lines of front porch = 170 us, a read needs ~30 us.
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

## Expected lines (next boot, 2871)

```
LAUREL BACKLIGHT: on: DCS max 2047 (Samsung s6e8fco), DCS HS, DMA at line 1568, memory DMA, reads in LP; panel power 0x9c, control 0x20, DBV follows the writes (DT mode, DMA line); AppleARMBacklight published (RedwoodGPU up: GPU renderer); slider 0..255 -> DBV max * (v/255)^2, one line per settled value; auto-brightness off: no ambient light sensor for iOS
LAUREL BACKLIGHT: brightness 237 of 255 from backboardd -> DBV 1768 (371 nits): panel at it, 14 panel writes, 0 failed; panel holds DBV 1768, power 0x9c
```

What the next log decides (the second `on:` line survives; it comes after USB is up):

| Line says | Meaning | Next step |
|---|---|---|
| `DBV follows the writes (DT mode, ...)`, panel changes | fixed: one of the Linux differences (or the bytes never arrived before) | none |
| `DBV follows the writes`, slider line `holds` = asked, panel looks the same | the panel takes it, the light does not change: panel side | compare `control` with Linux (`53 20`/`53 28`), HBM, on-command keys |
| `DBV DOES NOT FOLLOW`, power answers | link is good, 0x51 ignored or 0x52 not implemented | line `panel 0x52 reads X after writing Y`; send the DT's full on-command set |
| `FIFO, reads in LP` | the memory DMA delivers wrong bytes (SMMU stream of the DSI?) | stays on FIFO; find the stream if needed |
| `PANEL DOES NOT ANSWER READS` | nothing proven; writes blind | check DSI lane/LP config against ABL's |

## Test

Move the slider from low to high and back, with stops of 2 s: the panel must follow; one `brightness ... -> DBV ...; panel holds ...`
line per stop. Lock/unlock: the light comes back at the slider's level; the next settled line shows `power` again. Send the `on:` line
and these lines if the panel stays the same.
