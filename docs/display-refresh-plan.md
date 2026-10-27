# Display refresh: 120 Hz, TE lock and VRR on the AMB670YF08 (2026-10-26, display-refresh agent)

Goal (owner): true 120 Hz refresh and a variable refresh rate, ported from the Android sources;
the device runs hot and does not charge. This report says how Android drives this panel, what the
exact DCS byte sequences and DPU registers are, what our kernel can do without a DPU driver, and
what patch 0259 implements. [V] = read in the named file or measured; [I] = inferred, not tested.

Sources on disk (git-ignored): `out/live.dts` (the device tree of the booted Android), display
driver `out/src/op-modules/vendor/qcom/opensource/display-drivers` (`msm/dsi`, `msm/sde`, `oplus`),
the UEFI panel XML `external/Mu-Silicium-negroni/Binaries/negroni/RawFiles/Panel_samsung_amb670yf08_1440_3216_dsc_cmd.xml`.
Decoded command sets: `scripts/display/panel-dts-dump.py` (this report's generator) writes them from live.dts.

## 1. The panel and its modes [V live.dts]

- Node `qcom,mdss_dsi_panel_samsung_amb670yf08_fs_1440_3216_dsc_cmd` (line 35551; the kernel command
  line names it, line 16). `oplus,mdss-dsi-vendor-name = "S6E3HC3"` (35568), DSI command mode, DSC 1.2
  (`qcom,mdss-dsc-version 0x12`, 10 bpc, 8 bpp, slice 540x36, 2 encoders), `qcom,mdss-dsi-te-pin-select 1`,
  `qcom,mdss-dsi-te-using-te-pin`, `qcom,mdss-dsi-te-check-enable`, `qcom,mdss-dsi-te-dcs-command 1`
  (35610-35613), `qcom,qsync-enable`, `qcom,mdss-dsi-qsync-min-refresh-rate 0x18` (24 Hz, 35556-35557),
  `oplus,adfr-config = 0x17` (35555), `qcom,dynamic-te-gpio = <tlmm 0x58>` (GPIO 88, the second TE for
  oplus' real-refresh-rate detector, 35587), `qcom,dynamic-mode-switch-type = "dynamic-resolution-switch-immediate"`
  (35604), `qcom,mdss-dsi-panel-jitter <4 1>`.
- Timings (`qcom,mdss-dsi-display-timings`, 8 nodes): `fhd_sdc_120` (35640, 1080x2412 @120),
  `fhd_sdc_90` (35729), `fhd_sdc_60` (35818), `fhd_oplus_120` (35901), and the same four at WQHD 1440x3216
  (36009-36272). Porches: h 64/48/8 (fp/bp/pw), v 2/8/2; vtotal 2424; clock rate 0x3135a800 = 825 MHz
  per lane. `qcom,mdss-dsi-h-sync-skew` is oplus' mode tag (`h_skew_type` in oplus_adfr.h:33): 0 = SDC_ADFR
  (120/90 Hz), 1 = SDC_MFR (the 60 Hz timing), 2 = OPLUS_ADFR (the "oplus_120" timing with the qsync
  min-fps table 6..60 Hz).
- The UEFI drives the FHD 120 Hz mode: panel XML lines 34-43 `DSIRefreshRate 0x780000` (120),
  `DSIEnableAutoRefresh True`, `DSIAutoRefreshFrameNumDiv 1`, `DSITECheckEnable True`,
  `DSITEUsingDedicatedTEPin True`, `DSITEvSyncStartPos 2412`, `DSITEvSyncInitVal 2412`, `DSITEvSyncSelect 1`.
  The XML `DSIInitSequence` (lines 55-171) is the DTS on-command with `2C/00` fake frames in the 121 ms wait and the
  PPS as `39 9E` + 128 bytes (version 0x12); it ends in the 120 Hz state (see section 3). (Corrected 2026-10-26: an
  earlier version of this report said the sequence is empty.)

## 2. How Android does 120 Hz in command mode [V display-drivers]

- TE-driven: the panel's TE pin goes to the DPU INTF_1 tearcheck block. `sde_encoder_phys_cmd_tearcheck_config`
  (sde_encoder_phys_cmd.c:1197-1313): `vsync_count = vsync_clk / (vtotal * fps)` (vsync_clk is 19.2 MHz:
  2424 x 120 -> 66 clocks = 3437 ns per line), `hw_vsync_mode 0` at setup then external TE after the first
  kickoff, `sync_cfg_height 0xFFF0` (the hardware-generated TE never comes first), `vsync_init_val = vdisplay`
  (2412), `start_pos = vdisplay`, `rd_ptr_irq = vdisplay + 1`, `wr_ptr_irq 1`, `sync_threshold_start 4`
  (DEFAULT_TEARCHECK_SYNC_THRESH_START, :49), continue 4. Registers (sde_hw_intf.c:80-95, INTF_1 base
  0x0AE36000 = MDSS 0x0AE00000 + `qcom,sde-intf-off[1]` 0x36000, live.dts 27892; tear irq block +0x800,
  27889): TEAR_MDP_VSYNC_SEL 0x280, TEAR_CHECK_EN 0x284, SYNC_CONFIG_VSYNC 0x288 (bit 20 TE pin, bit 19
  counter enable, [18:0] vsync_count), SYNC_CONFIG_HEIGHT 0x28C, SYNC_WRCOUNT 0x290, VSYNC_INIT_VAL 0x294,
  INT_COUNT_VAL 0x298 (frame count << 16 | line, sde_hw_intf.c:778-803 get_vsync_info), SYNC_THRESH 0x29C,
  START_POS 0x2A0, RD_PTR_IRQ 0x2A4, WR_PTR_IRQ 0x2A8, TEAR_LINE_COUNT 0x2B0, AUTOREFRESH_CONFIG 0x2B4
  (bit 31 enable, [15:0] frames per refresh, :668-703), VSYNC_TIMESTAMP_CTRL/0/1 0x210-0x218 (SDE >= 8.1,
  sde_hw_catalog.c:2481; a 64-bit stamp of the last vsync). Tear interrupts (sde_hw_interrupts.c:24-26,
  184-188): EN +0x800, STATUS +0x804, CLEAR +0x808; bits 0 AUTOREFRESH_DONE, 1 WR_PTR, 2 RD_PTR,
  3 TE_DETECTED, 4 TEAR_DETECTED.
- Frame flow: the TE resets the counter to 2412; one line later the rd_ptr interrupt fires (the "vsync"
  Android reports to SurfaceFlinger, with `te_timestamp_list` ktime stamps, sde_encoder_phys_cmd.c:320-365);
  a commit kicks the CTL (CTL_START) and the DPU writes the frame (pp_done / wr_ptr); the write may start
  only inside the sync window (start_pos +- threshold) so it stays behind the panel scan. Android does not
  use the auto-refresh for normal frames: no commit, no transfer (the panel self-refreshes from its RAM).
  The auto-refresh (a frame every N TEs with no software kick) is a debug/idle property
  (`_sde_encoder_phys_cmd_config_autorefresh`, :107); the UEFI leaves it on with N = 1, which is why our
  kernel never kicks the DPU and the panel scans 120 Hz for ever.
- Dynamic fps: the 60/90/120 timings share the resolution, so a switch is "seamless VRR"
  (dsi_display.c:8025-8040 `DSI_MODE_FLAG_VRR`): `dsi_panel_switch` (dsi_panel.c:5603) sends the new
  timing's `qcom,mdss-dsi-timing-switch-command` (state `dsi_hs_mode`), the encoder re-runs the tearcheck
  config with the new vrefresh (vsync_count) and SurfaceFlinger's vsync period changes.

## 3. The DCS sequences [V live.dts, decoded with the dsi_panel.c packet format]

Packet format (dsi_panel.c:2556-2575 `dsi_panel_create_cmd_packets`): 7-byte header {type, last, vc,
flags, post-wait ms, len hi, len lo} then the payload; flags 0x40 = batch (no wait before the next).
Samsung level-2 key: `F0 5A 5A` unlock, `F0 A5 A5` lock; `B0 00 oo RR` = byte offset for the next write
to register RR; `F7 0F` = latch.

- On-command (line 35658, 1121 bytes): PPS (`9E` + 88 bytes), `9D 01`, `11` + 12 ms, the C5/B9 blocks,
  121 ms, then `BD 21`, `F2[0x16]=1B 50`, `CB[0x08]=24`, `60 00`, `BD[0x10]=00`, `BD[0x16]=77`,
  `BD[0x14]=00`, `CB[0x63]=08`, `F7 0F`, `BD 23 02`, `F2 00 01`, `35 00` (TE on), `B9 00`, `2A 0000 0437`,
  `2B 0000 096B` (1080x2412 window), the C3 block, F6/F4/B1/63 blocks, `53 28`, `55 00`, 1F block, `29`.
- Timing switch, 120 Hz (35659, 721 bytes, 62 packets): `2A/2B` window, `F0 5A 5A`, `C3 89`, C3 blocks
  at 0x24/0x3A/0x50/0x61 (same as the on-command), `F0 A5 A5`, `F0 5A 5A`, `C5[0x31] 29 14 00 00 00 11 10
  50 05 84 CA ...` (34 bytes), `F0 A5 A5`, `F0 5A 5A`, `FC 5A 5A`, `B9 00`, `60[0x02]=00`, `F2 00 01`,
  `F7 0F`, `FC A5 A5`, `F0 A5 A5`, `F0 5A 5A`, `B9[0x22]=A1 B1`, `B9[0x3A]=02`, `B9[0x26]=00 00`, `F7 0F`,
  `F0 A5 A5`, `F0 5A 5A`, `B9[0x24]=21`, `B9[0x38]=02`, `B9[0x2A]=00 00`, `F7 0F`, `F0 A5 A5`, `F0 5A 5A`,
  `BD 21`, `F2[0x16]=1B 50`, `CB[0x08]=24`, `60 00`, `BD[0x10]=00`, `BD[0x16]=77`, `BD[0x14]=00`,
  `CB[0x63]=08`, `F7 0F`, `BD 23 02`, `F0 A5 A5`.
- 60 Hz (35834, 721 bytes): identical except `B9[0x3A]=05`, `B9[0x38]=05`, `60 01`, `BD[0x14]=01`.
- 90 Hz (35788, 652 bytes): the same up to the B9 blocks with `B9[0x3A]=03`, `B9[0x38]=03`, then
  `F2[0x16]=1B 50`, `CB[0x08]=A4`, `BD 21 82`, `60 09`, `BD[0x10]=00`, `F7 0F`, `F0 A5 A5` (no BD[0x14]/[0x16]).
- So `60` selects the frame rate (00 = 120, 01 = 60, 09 = 90), `B9[0x38]/[0x3A]` the TE/frame timing
  (02/05/03) and `BD[0x14]` the frame hold count.
- Min fps / LTPO idle (oplus "SDC manual min fps", oplus_adfr.c:2521-2630 `dsi_panel_send_auto_minfps_dcs`):
  the `qcom,mdss-dsi-qsync-min-fps-0-command` of the 120 Hz timing (35655) is
  `F0 5A 5A; B0 00 14 BD; BD <N>; F7 0F; F0 A5 A5` with the BD byte replaced by the hold count
  (`OPLUS_ADFR_AUTO_MIN_FPS_*`, oplus_adfr.h:51-60: 0x00 = 120, 0x01 = 60, 0x02 = 40, 0x03 = 30, 0x04 = 24,
  0x05 = 20, 0x0B = 10, 0x77 = 1 Hz; the panel shows 120 / (N + 1) Hz). `dsi_panel_auto_minfps_check`
  (:2470-2487) limits it to 0..0x77 in the 120 Hz timing and 0x01..0x77 in the 60 Hz timing, and clamps a hold
  above `minfps_exidle` (0x05 = 20 Hz) back to 0x05 while idle mode is off: Android uses 10 Hz / 1 Hz only in
  idle mode, with no frames in flight. The oplus_120
  timing's qsync table (35922-35932) is the same write with N = 0x01, 02, 03, 04, 05, 07, 09, 0B, 0E, 13
  for 60, 40, 30, 24, 20, 15, 12, 10, 8, 6 Hz; `qsync-off` = `BD[0x14]=00`.
- ADFR idle (oplus_adfr.c:2836 `oplus_adfr_handle_idle_mode`): when the DPU encoder goes idle (no
  commits), Android sends the min-fps write (down to 1 Hz) and the panel holds the last picture at that
  rate; on the next commit it sends the exit value (20 Hz default, `oplus,adfr-exit-idle-min-fps`), and the
  first new frame shows at once (the panel refreshes on a received frame: adaptive, not a fixed 1 Hz).
  Qsync (`qcom,mdss-dsi-qsync-on-commands`: `BD 23; BD[0x10]=10; BD[0x16]=03; F7 0F`) is the panel's own
  "auto" mode (the DDIC chooses the rate from the frame cadence); Android uses it with the oplus_120
  timing for games. The fakeframe (`2C/3C` write-memory with no data, 35660) is sent before a min-fps
  change in 60 Hz so the brightness does not step.

## 4. What our kernel can do without a DPU driver

Facts about our path [V patches 0231/0250/0253/0254]: the UEFI's INTF_1 auto-refresh (N = 1) sends the
panel RAM on every TE; `negroni_dsi_dcs_write` (NegroniBacklight.cpp) sends one DCS packet per FIFO DMA
behind an MDP-not-busy wait (the DSI STATUS bit, up to 20 ms); the vsync is a fixed-deadline 8333 us
timer (0254) that copies the latest frame and notifies CoreAnimation; `IOMFBDisplayRefresh` (0253)
gives CA its 120 Hz quantum.

(a) Read the real TE: INTF_TEAR_INT_COUNT_VAL at 0x0AE36298 is readable at any time: the frame field
    counts TEs (so TEs per second = the panel rate), the line field is the time since the last TE in
    lines of vsync_count / 19.2 MHz. No interrupt is needed: the tick samples the counter and moves its
    next deadline. INTF_VSYNC_TIMESTAMP (0x210 enable, 0x214/0x218) gives a hardware stamp of the last
    vsync for a check. The MDSS interrupt (GIC SPI 83) and the tear irq block would give a real TE
    interrupt later (a rd_ptr handler = Android's vsync), not needed for the lock.
(b) Lower the refresh when idle, DCS only, autorefresh untouched: the 60 Hz (or 90 Hz) timing-switch set
    verbatim. The panel's TE drops to 60 Hz; the tearcheck counter (height 0xFFF0, init 2412, start 2412)
    keeps waiting for the TE pin, so the auto-refresh then sends one frame per 60 Hz TE [I: the Android
    encoder also re-programs vsync_count for the new rate; with hw TE the counter only models the panel
    scan for the sync threshold, start_pos = init means the transfer starts right after the TE either
    way]. Saves the DPU fetch, the DSI link and the panel scan: 60 Hz instead of 120.
(c) Lower it with the LTPO hold (the Android idle path): the min-fps write BD[0x14] = N on the 120 Hz
    timing AND the auto-refresh divider INTF_TEAR_AUTOREFRESH_CONFIG = 0x80000000 | (N + 1), so the DPU
    sends one frame per panel refresh (with N = 1 and a 120 Hz auto-refresh the host would keep forcing
    120 Hz). One register write plus 5 DCS packets each way; wake = divider back to 1 (instant) + `BD[0x14]=00`.
    10 Hz idle = 0x0B / 12, 1 Hz = 0x77 / 120. [I] Not seen on the phone: whether the panel accepts the
    hold with frames still arriving every N + 1 TEs (Android sends none while idle).
(d) Autorefresh divider only (no DCS): the panel keeps scanning 120 Hz from its RAM, the DPU and the DSI
    link idle. Lowest risk, panel power unchanged.
(e) Not possible without more DPU work: Android-style no-autorefresh operation (software CTL_START per
    frame, the zero-copy 0234 path has the CTL offsets), qsync/auto mode, the 60/90 Hz switch with a
    re-programmed tearcheck, the AOD/LP modes.

## 5. Patch 0259 (`negronifb_te`, `negronifb_vrr`; both default off)

- `negronifb_te=1`: the tick reads INT_COUNT_VAL, computes the phase of its deadline after the TE
  (line - init) x line time, and moves the next deadline by half the error (at most a quarter period);
  the tick period follows the measured TE period (frames/s, within 15 % of nominal). `negronifb_te_off=N`:
  target phase in us after the TE; negative = before the next TE (default -800: the CPU copy starts
  800 us before the TE so it stays ahead of the DPU fetch, which takes ~6 ms of the 8.3 ms). `=2` also
  enables the INTF vsync timestamp and logs it. Boot line: `NEGRONI FB TE: INTF_1 tear_en .. sync_cfg ..
  (te pin .. vsync_count .. = .. ns/line) height .. init .. autorefresh ..`; per second:
  `NEGRONI FB TE: te/s N period us N tick us N phase us N target N err avg/max us N/N adj us N locked
  N/N ticks ...` (`locked` = samples with |err| <= 500 us). Expected: te/s 120, period 8333, locked ~120/120.
  The per-second TE and VRR lines come from statTick: they need `negronifb_stats != 0` (default 1).
- `negronifb_vrr=1` (c above), `=2` (b), `=3` (d); `negronifb_vrr_fps=N` (idle rate: 1..120 for 1/3,
  60 or 90 for 2; default 10), `negronifb_vrr_ms=N` (idle delay, default 3000), `negronifb_vrr_hs=1`
  (DCS mode: default HS for mode 2 as Android sends the switch sets in dsi_hs_mode, LP for mode 1 like the
  brightness; `=0` forces LP). A failed idle switch turns the VRR off for the boot (`VRR off` line) after a
  best-effort `F0 A5 A5` key lock, so retries never reach the 3-failure DSI shutdown of 0250. The display-off
  fade waits (at most 60 ticks, 500 ms) while a VRR set is still being sent, so the 0258 sleep DCS never lands
  inside a set. Idle = no SwapEnd for the delay while
  the display is on; wake = the next SwapEnd (the divider is reset at once in the caller, the DCS goes on a
  thread call), or RequestPowerChange (the panel sleeps and wakes in the full-rate state). Mode 2 also sets
  the tick period, the vsync interval of the notification and `IOMFBDisplayRefresh` to the idle rate.
  Lines: `NEGRONI FB VRR: mode N, idle N Hz (hold 0x.., autorefresh 1/N) after N ms without a swap`,
  `NEGRONI FB VRR: idle N Hz (hold 0x.., autorefresh 1/N, N DCS packets, N ms)`, `NEGRONI FB VRR: active
  120 Hz after N ms idle (...)`, per second `NEGRONI FB VRR: active|idle (...), N idle periods, idle N ms
  in all, DCS errors N`.
- Every DCS write goes through `negroni_dsi_dcs_write` (same lock, same MDP-not-busy wait as 0250);
  the FIFO payload limit went from 16 to 60 bytes (the TPG FIFO is 64 bytes with the header,
  dsi_ctrl.h:58 DSI_CTRL_MAX_CMD_FIFO_STORE_SIZE), needed for the 34-byte C5 write of the switch sets.
  `negroni_dsi_dcs_set()` sends a set in the device-tree format packet by packet (post-wait honoured).
- Modes 1 and 3 refuse to start unless AUTOREFRESH_CONFIG reads 0x80000001 (the UEFI value).

## 6. Risks and recovery

- A timing switch the panel does not like can blank it or tear: boot with `negronifb_vrr=0` (the default;
  the config args do not carry it). The image `out/ios16-vrr` carries `negronifb_te=1 negronifb_vrr=1`.
- Mode 2 sends 62 packets each way, each behind the MDP wait: ~100-300 ms per switch [I]; the picture keeps
  updating meanwhile.
- The min-fps hold on a panel that still receives frames every N + 1 TEs is not what Android does [I];
  if the panel flickers at the idle rate, try `negronifb_vrr=3` (divider only) or `=2` (60 Hz timing).
- The TE lock changes only the tick phase; a wrong line time scales the target offset, not the lock.
  If `te/s` is 0 or `no sample` is high, the counter is not in TE-pin mode: `negronifb_te=0`.
- Heat and charging: the DSI link and DPU at 120 Hz are a few hundred mW [I]; the idle modes remove most
  of it while the screen is static. Charging is a separate problem (0272/0273).

## 7. Next

1. Boot `out/ios16-vrr`, read the `NEGRONI FB TE:` boot line (te pin bit, vsync_count, autorefresh
   0x80000001 expected) and the per-second lines; `locked` should reach ~120/120 within seconds.
2. Lock screen idle: `NEGRONI FB VRR: idle 10 Hz` after 3 s; touch: `active 120 Hz`. Check no flicker;
   compare battery mA (0270 lines) idle vs `negronifb_vrr=0`.
3. Then `negronifb_vrr_fps=1`, `negronifb_vrr=2` (60 Hz timing) and `negronifb_vrr=3` for the power delta
   of each stage; pick the default.
4. Later: a real rd_ptr interrupt (MDSS IRQ) instead of sampling; software kicks without auto-refresh (0234
   CTL path) to reach Android's no-frame idle; qsync auto mode.

## 8. Follow-up patches 0292-0296 (2026-10-26, DSI/DPU agent; build-only)

Details and log lines: patches/xnu/README-gpu-kernel.md sections 22-26. All default off.

- Section 6 "Mode 2 sends 62 packets each way, each behind the MDP wait: ~100-300 ms per switch": 0292
  `negronifb_dsidma=1` sends a set as Android does (memory DMA, batched up to the packet without the 0x40 flag, one
  MDP wait per set). Mode 1 now sends the min-fps set in HS by default (DT state `dsi_hs_mode`, live.dts 35650).
- Section 4 (e) "the 60/90 Hz switch with a re-programmed tearcheck": 0294 writes vsync_count 66/88/132 on each
  mode 2 switch (sde_encoder_phys_cmd.c:1240-1259).
- Section 4 (a) / section 7 item 4 "a real rd_ptr interrupt": 0295 `negronifb_teirq=1` (INTID 115, INTF_1 tear
  rd_ptr at line init + 1) gives 0259's TE lock an interrupt stamp instead of the counter sample.
- Section 4 (e) "Android-style no-autorefresh operation (software CTL_START per frame)": 0296 `negronifb_idle=2`.
  With it, the min-fps hold of mode 1 would be the Android case (no frames while idle); combining both is not done
  (0296 refuses `negronifb_vrr=1|3`, which own AUTOREFRESH_CONFIG).
- ESD and panel reads: 0293 `negronifb_esd=1` (DCS 0x0a every 5 s, re-init through 0268's wake on a bad value).

## 9. The 120 Hz mode for UIKit and CoreAnimation: patch 0364 (2026-10-27, build-only)

Owner goal: the UI runs at 120 Hz. The kernel already ticks vsync at 120 Hz (`NEGRONI_FB_VSYNC_US` 8333), sets
`IOMFBDisplayRefresh` (0253) and, only with `negronifb_vrr=1` (0259 VRR), switches to 10 Hz when idle. What was missing is the display mode.

How iOS 16.7 (20H392) gets the refresh rate [V `ipsw dyld disass` of `out/dsc/cache`]:
- `-[UIScreen maximumFramesPerSecond]` (UIKitCore 0x1890029d0) returns 60 only for apps linked before an old SDK
  (`dyld_program_sdk_at_least`), else `-[UIScreen _maximumFramesPerSecond]` = round(1 / `_refreshRate`), and
  `_refreshRate` = 1 / `[FBSDisplayConfiguration refreshRate]` = 1 / the current `CADisplayMode`'s `refreshRate`.
- `-[CADisplayMode refreshRate]` (QuartzCore 0x1883665f4) = round(bits 29..53 of the packed `Display::Mode` x
  2^-16): the timing's `SyncRate` in 16.16 fixed point. With no mode (all ones) it falls back to 1 / the display's
  refresh interval. `IOMFBDisplay::hardware_refresh_rate` (0x188530454) reads the same field.
- QuartzCore fills its mode set from `IOMobileFramebufferGetSupportedDigitalOutModes` (IOMobileFramebuffer
  `kern_GetSupportedDigitalOutModes` 0x1af228b48: the service properties `ColorElements` and `TimingElements`) and
  the current mode from `IOMobileFramebufferGetDigitalOutMode` (0x1af22438c: GetBlock, selector 79, block 0x40,
  40 bytes; the ids at +4 and +8), matched in `IOMFBDisplay::fetch_current_iomfb_mode` (0x1883a7828). The phone log
  shows backboardd's `sel 79 ... out 0/40` (and a second block of 1580 bytes); we answered zeros.
- `AppleCLCDDisplay::minimum_frame_duration` (0x1882bc4d0) gives 2 frames (60 Hz on a 120 Hz panel) only when a
  flag bit and bit 63 of the mode are set; our mode has bit 63 clear, so the minimum is 1 frame [I: bit 63 is not
  from a key we publish]. Strings `TimingElements`, `HorizontalAttributes`, `SyncRate`, `PreciseSyncRate` are in
  IOMobileFramebuffer/QuartzCore; `CADisableMinimumFrameDurationOnPhone` exists (third-party CADisplayLink cap on
  phones, as on ProMotion iPhones; system UI is not affected [I]).

What 0364 does (`iokit/Kernel/arm/NegroniFramebuffer.cpp`, port of HakiOS `MiniIOMobileFramebuffer.cpp:329-379` and
its GetBlock case, APSL 2.0):
- `publishModes()` before `registerService()`: `TimingElements` = one timing (`ID` 1, `HorizontalAttributes`/
  `VerticalAttributes` with `Active`/`Total` = the presented size 1125 x 2436, `SyncRate` = `PreciseSyncRate` =
  `negronifb_modehz` << 16; default = 120 / the `negronifb_hz` copy interval (`fFlushTicks`), so 120 with the
config's `negronifb_hz=120` and 10 with the code default `negronifb_hz=10`), `ColorElements` = one 8-bit RGB mode (`ID` 1).
- Selector 79 (GetBlock): block 0x40 at offset 0 (the second scalar; IOMobileFramebufferGetDigitalOutMode sends 0)
  answers colour id 1 at +4 and timing id 1 at +8; other blocks and offsets stay zeros.
  The output is now written after the generic clearing. Each block id is logged once.
- Boot-args: `negronifb_modes=0` turns it off (the old behaviour), `negronifb_modehz=N` (1..120).
- VRR is unchanged: the mode says 120 Hz; with `negronifb_vrr=1` the kernel still drops the tick to 10 Hz when
  nothing swaps and goes back to 120 Hz on the first swap.

Expected log:
```
NEGRONI FB: modes: TimingElements 1125x2436 at 120 Hz (SyncRate 0x780000), ColorElements RGB 8-bit, current mode colour 1 timing 1 (negronifb_modes=1 negronifb_modehz=120)
NEGRONI FB: backboardd GetBlock 0x40 (in 2 scalars, out 40 bytes): current mode (colour 1, timing 1)
NEGRONI FB: backboardd GetBlock 0x.. (in 2 scalars, out 1580 bytes): zeros
NEGRONI FB STAT: swaps/s ~120 presents/s ~120 ...     (during a continuous scroll)
NEGRONI FB VRR: idle (idle 10 Hz) ...                  (after the scroll, with negronifb_vrr=1)
```
Before 0364 [V logs/usblog-20261026-233816.txt]: `swaps/s` max 97, most active seconds 52-66.

Test: scroll Settings for 5 s with the finger kept moving; read `FB STAT`. If CA hangs or draws nothing (HakiOS
notes "without a mode it draws nothing", so the mode path is the normal one there), boot `negronifb_modes=0`.
Risks [I]: QuartzCore may now call `SetDigitalOutMode` (accepted, no-op) or read the 1580-byte block (zeros as
before); a CADisplayLink in a third-party app stays at 60 without `CADisableMinimumFrameDurationOnPhone`.

Verification (2026-10-27, build only): [V] compile-one NegroniFramebuffer.cpp, no diagnostic in the file; full build
out/kernel/local-20261026-213038/kernel.development.negroni sha256
127cae2a976695d78131e9116be18f99daa601010f80aa4520b8de9698ac9c7c (after the review fixes B1, C1-C3, C5) (0364 applied, only the 4 dxb skips; strings
`modes: TimingElements`, `GetBlock 0x%llx`, `PreciseSyncRate`). Patch sha256
89ba7e3ea2c1c61adf317f6289c51129697d3d4ada23a263f562787eef6e9c46. Not booted.

## 10. What limits the frame rate at 120 Hz, and patch 0389 (2026-10-27, 120 Hz agent)

Measured with `scripts/display/fbstat-report.py` on logs/usblog-20261027-171256.txt (17:12:56-19:14:00; config args with
`negronifb_te=1 negronifb_vrr=1 negronifb_dbuf=1 negronifb_teirq=1`). Full numbers: patches/xnu/README-gpu-kernel.md section 29.

- The 120 Hz path works when the GPU keeps up: 18:39:35-47 shows 99-119 presents/s at 220 MHz with 0 skips and copy max
  < 350 us (a light scroll). The VRR idle (10 Hz) and the wake (5 DCS packets, 0 ms) work.
- Heavier content falls to 40-60 presents/s: 16 gpu-wait skips/s (frames whose render was not done at the vsync tick),
  GPU at 220-380 MHz with 8-10 governor changes a second (limiter 1), CPU copies of "behind" layers on the tick at 4-7 ms
  with late ticks (limiter 2).
- Section 5 (0259 TE lock) [V]: with the auto-refresh at 1/1 the INT_COUNT_VAL frame field does not count, so the lock had
  "no sample" in 98 % of the ticks at 120 Hz and the tick ran free against the TE (limiter 3). The lock worked only in VRR
  idle (51 % locked). The 0295 interrupt counted 120 TEs/s all the time.
- Section 7 item 4 (a real rd_ptr interrupt instead of sampling): 0389 now uses it for the lock (TE count + stamp, period
  between stamps).
- 0389: GPU pacing floor (`negronigpu_pace=0` = off), GPU input boost at touch (`negronigpu_inputboost=0` = off), GPU copy of behind layers into a 0269 back buffer
  (`negronifb_gpubehind=0` = off), TE lock on the interrupt. Expected lines: README-gpu-kernel.md section 29.
- Next, if 0389 is not enough [I]: present on render completion (fence interrupt) inside CA's 1 ms SwapWait retry; per-frame
  render time from the swap to the fence (a pacing input better than held ticks); better placement of backboardd's render thread on the big cores (CPU agent).
- Update (same day): 0389 also ports the Android GPU governor msm_adreno_tz (TrustZone DCVS, 10 ms bins; `negronigpu_tz=0`
  = off; mapping in README-gpu-kernel.md section 29). 0391 limits the clock shift to panel rows 34..80 and the left-ear box
  50..228 (the step under the punch hole; `negronifb_clockband=0` = off; README-display.md "0391").
