# Plan and status

Status date: 2026-10-26 (14:30).

## Next (owner + main session)
1. Charge in fastbootd to > 60 %. Then `scripts/flash/ios16.sh userdata` (fastbootd; writes the root + firmware areas),
   `vendor_boot`, `vbmeta`, `dtbo`, `boot` with `IOS16_OUT=out/ios16-all2` (safe baseline) or `out/ios16-everything`
   (diagnostic: every addition on), `active`.
2. First boot: charger test (`out/ios16-chg3` or everything + `negronichg_glink=1`): expect `write USB_INPUT_CURR_LIMIT
   1500 mA ... ok` and ibat positive by hundreds of mA. Then display perf (`out/ios16-perf`): presents/s 100-120 while
   scrolling, clock still. Then by eye: Siri orb (MPS), lock-screen poster `uncaught exception` line, WebGL page.
3. Reviews/audits: docs/audit/2026-10-26-*.md (resume the agents after 17:20), then fold into this plan.
4. Open code items: 0331 BT HCI; the panel wake with the full on-command (negronifb_sleep=1 is unsafe until then);
   Wi-Fi step 25+ (WLAN_CFG/MODE, CE/HTC/WMI, iOS 80211 glue); audio stage c (amps) + mic; camera level 3 (CSIPHY/IFE);
   fingerprint stage C/D; haptics UI path (VirtualAudioDevice_Actuator); GPU reset/recovery after a hang.

## Done
- Charger over GLINK (2026-10-26, battery agent; patch 0274, docs/charger-glink-plan.md, README-battery.md section 9):
  the HLOS cannot write the PM8350B charger (no APID, debug arbiter fused off); the ADSP charger PD owns it. 0274
  `negronichg_glink=1` (with `negroniadsp=1`) opens GLINK PMIC_RTR_ADSP_APPS, reads battery/USB status and the
  external-gauge SoC every 20 s, and after the PD answers sets the USB input limit (`negronichg_ma`, default 1500) and
  charging enable over pmic_glink. Built: kernel out/kernel/local-20261026-084835 (6acdaacf...), image out/ios16-chg3
  (boot_a 9286b5e3...). Not booted. Next: owner `fastboot boot`s out/ios16-chg3 (ADSP firmware area must be on
  userdata); check `GLINK UP`, `glink: ... READY`, the property dump, `input limit read back`, and that ibat goes
  clearly positive at idle on the charger. If PMIC_RTR_ADSP_APPS never opens: try `negroniadsp_step=10` (servreg locator).
- Camera levels 1-2 (2026-10-26, camera agent; patches 0310, 0311, patches/xnu/README-camera.md, docs/camera-plan.md):
  0310 `negronicam=1`: GCC camera clocks, camcc titan top GDSC, camcc AHB/CAMNOC/CCI0 clocks from the 19.2 MHz TCXO,
  CCI0 reset (proof `level 1 OK`). 0311 `negronicam=2`: rear main IMX789 power-up in the module-file order (5 RPMh
  rails with the live-DT voltages, reset gpio120, MCLK0), CCI0 M0 chip-ID read (expected `chip id 0x0789 ... MATCH`),
  vendor power-down; failure path powers down in that order, all waits bounded. Built: kernel
  out/kernel/local-20261026-082431 (sha256 fe5d2ef5...), image out/ios16-cam (boot_a 280e1223...). Not flashed.
  Next: owner boots out/ios16-cam with a charged phone (`fastboot boot` first); read the `NEGRONI CAM:` lines; then
  level 3 (TPG -> CSID -> IFE RDI, apps SMMU check) on a D-PHY sensor or the C-PHY main sensor.
- Display TE lock + VRR (2026-10-26, display-refresh agent; patch 0259, docs/display-refresh-plan.md,
  README-gpu-kernel.md section 17): Android's path read from live.dts/display-drivers (TE pin -> INTF_1 tearcheck,
  CTL kick per commit, oplus ADFR min-fps DCS `BD[0x14]=N` down to 1 Hz, 60/90/120 timing-switch sets).
  0259: `negronifb_te=1` phase-locks the vsync tick to the panel TE through INTF_TEAR_INT_COUNT_VAL (per-second
  `NEGRONI FB TE:` line with te/s, period, phase, locked ticks); `negronifb_vrr=1` idles the panel at
  `negronifb_vrr_fps` (10) Hz after `negronifb_vrr_ms` (3000) without a swap (min-fps DCS + auto-refresh divider),
  `=2` 60/90 Hz timing switch, `=3` divider only; wake on SwapEnd. Kernel local-20261026-075816 (a39f24e5...),
  image `out/ios16-vrr` (config args + `negronifb_te=1 negronifb_vrr=1`, boot_a b7d9ef7c...). Built, not run.
  Next (phone charged, owner approval): boot out/ios16-vrr, read the `NEGRONI FB TE:` boot line (te pin 1,
  autorefresh 0x80000001) and `locked`, then the lock screen idle -> `NEGRONI FB VRR: idle 10 Hz`, touch ->
  `active 120 Hz`; compare battery mA idle with `negronifb_vrr=0`; on a blank panel boot with `negronifb_vrr=0`.
- WebGPU / MSL source on Metal (2026-10-26, Metal agent; flame/0011, built, phone off, not run): `newLibraryWithSource:`
  compiles in the calling process with Apple's own front end (libGPUCompiler `MTLGPUCompilerBuildFromSourceToBuffer`,
  `userland/metal/plugin/negroni_msl.h`), no MTLCompilerService XPC; argument buffers (`newArgumentEncoderWithArguments:`,
  `newArgumentEncoderWithBufferIndex:`, residency via `useResource`/`useHeap`) and indirect draws/dispatches over
  metal2vulkan; indirect command buffers refused cleanly (nil, one log line). Host test with MoltenVK (`msl` case of
  scripts/metal/host-plugin-test.sh) [V]: MSL text -> in-process front end -> metallib -> m2v -> argument-buffer kernel and
  indirect dispatch give correct results; a compile error answers nil + the compiler text. New probe `mslprobe` (front end
  only). Bundle NegroniMetal sha256 f4f515b3...cc99 (after the review fixes), check-imports PASS. Next (phone on): push the bundle, `mslprobe`,
  `metalprobe --compute --render`, then Safari on a WebGPU/WebGL page with `com.apple.WebKit.GPU` in clients
  (docs/metal-management.md "MSL source compile"); then indirect command buffers if WebGPU render bundles need them.
- GPU power collapse (2026-10-26, power agent, patch 0285, README-gpu-kernel.md section 16): the GX domain was powered
  the whole boot (OOB GPU_SET held since step 18). 0285 asks the GMU for IFPC (HFI FEATURE_CTRL, KGSL gen7 recipe:
  power-up register list in ME_INIT, OOB GPU_SET released after step 22, fenced WPTR, no GX read while collapsed);
  if the GMU refuses (or GX never collapses), slumber after 2 s idle with a warm GMU/GPU restart on the next
  submission. Boot-args `negronigpu_ifpc` / `negronigpu_slumber` (both default 1; both 0 = old behaviour). WATCH line:
  `pm ifpc GX collapsed N% ...`. Kernel `out/kernel/local-20261026-074105` (sha256 27fc0bf8...), image
  `out/ios16-ifpc` (config args, boot_a 22d76f2f...). Built, not run. Next (phone on, owner approval):
  `fastboot boot` / flash out/ios16-ifpc, read `NEGRONI GPU PM:` lines and `GX collapsed`; compare THERMAL gpu C
  and battery mA with out/ios16-pwr under Metal; on a hang boot with `negronigpu_ifpc=0`.
- Wi-Fi levels (2026-10-26, Wi-Fi agent): patches 0263 (`negroniwlan=N` levels 2-4 with `step N NAME` / `failed: REASON` lines, badge, BHI heartbeat, MHI window 0..36-bit, read-only DMA-path check of the PCIe NoC/TBU clocks and the apps SMMU stream 0x1c01; `negroniwlan_smmu` default 1, =2 writes a bypass entry and needs owner approval) and 0264 (IPCR RX/TX buffers on MHI 20/21). Old `negroniwlan=2` = new `negroniwlan=4`. Kernel + image `out/ios16-wlan3` (`negroniwifi=10 negroniwlan=4 negronipanic=30 negronipanicreason=2`): kernel local-20261026-073643 sha256 3be2d780..., boot_a sha256 4ee03eff... (after the review fixes). Not run (phone flat). Next: charge the phone above 50 %, owner-approved boot of out/ios16-wlan3, read the `NEGRONI WLAN: step` lines; then level 5 QRTR and level 6 QMI WLFW (0265/0266, not written).
- Wi-Fi levels 5-6 (2026-10-26, Wi-Fi agent; build-only, phone off): patch 0265 = QRTR over MHI IPCR 20/21 (`negroniwlan=5`: step 16 HELLO, step 17 WLFW service 0x45 lookup; bounded v1/v2 decoder, RX queue, RESUME_TX), 0266 = QMI WLFW client (`negroniwlan=6`: steps 18-24 IND_REGISTER, HOST_CAP, firmware memory REQUEST_MEM/RESPOND_MEM, FW_MEM_READY + CAP with chip/board/firmware ids, BDF regdb.bin type 4 + bdwlan.elf type 1, M3_INFO, FW_INIT_DONE) with a generic QMI TLV coder and field tables (`negroni_wlfw_tables.h`). Host test `scripts/wifi/qmi-host-test.sh` ALL PASS. Kernel out/kernel/local-20261026-083218 (sha256 ae4c817f..., after the review fixes), image `out/ios16-wlan6` (config args + `negroniwifi=10 negroniwlan=6 negronipanic=30 negronipanicreason=2`, boot_a 15cda991...). Not run. Next: owner-approved boot (after wlan3 proves levels 2-4), read `step 16 QRTR HELLO from node N`, `step 17 WLFW service at node N port P`, `firmware version ... build "..."`, `step 24 FW_INIT_DONE_IND received`; then step 25+ (WLAN_CFG/WLAN_MODE, cold-boot calibration, CE/HTC/WMI: README-wifi.md "What step 25+ needs").
- Vibration (2026-10-26, haptics agent): patch 0300 `negronihap=1` = PM8350B HV haptics direct play over SPMI (owner log, census, 300 ms boot buzz) + API `negroni_haptic_play(ms, strength)`; 0301 = iOS "vibrator" IOService (FigVibrator legacy IOKit path, setProperties `hertz_millisecs`/`repeat`). Kernel out/kernel/local-20261026-072436 (sha256 0f22dbf4...), image `out/ios16-hap` (config args + `negronihap=1`, boot_a sha256 99a1123a...). Built, not run. Next: owner-approved boot of out/ios16-hap, check the `NEGRONI HAPTIC:` lines and the buzz, then a ringtone vibration preview (`NEGRONI VIBRATOR: start`). UI haptics (CoreHaptics) need an Actuator HAL device: large, later (docs/haptics-plan.md).
- Wi-Fi/audio (2026-10-26): 0262 rebased on slop 0125; `negroniwifi=10` on the phone: PCIe link UP Gen2 x1 and the QCA6490 answers (17cb:1103, MSI at 0x50) [V]. Stage 1 (`negroniwlan=2`, image out/ios16-wlan2 in boot_a) is untested: the phone browned out at 16 % battery before it logged. ADSP step 1 ran (SMEM OK, PAS query answers 0 -> patch 0241 logs it only); HAL plug-in pushed to the live root (scripts/audio/phone-audio.sh): 3 clean boots, 2 boots with the old SIGABRT, undecided. Next: charge the phone, flash khz12 back, then wlan2 + `negroniadsp_step=4` with `negronipanic=30 negronipanicreason=2`.
- Screen-off freeze (2026-10-26, wake agent): patch 0275 `0275-negroni-display-off-fast.patch` (after 0259; 0260-0264 are WLAN). The 0251 fade read the write-combined panel memory pixel by pixel: ~1 s per vsync tick, 7 s UI freeze per screen-off (`fade 7055 ms`, `late ticks 136`, `swaps/s 0`). 0275 writes black with stores only on tick 0 and calls the backlight on tick 1. Kernel + image `out/ios16-wake` (config args + `negronipanic=30 negronipanicreason=2`): see docs/notes.md section 15 for the hashes. Verify: `display off: black in N us` (N < 10000) and `display off (fade N ms, DCS sleep ok)` with N <= 25, `late ticks 0` around it, then apps open after a wake.
- Audio stage (a) step 9 + stage (b) (2026-10-26, audio agent; patches 0242, 0243; build-only, phone off): 0242 adds ADSP step 9 (GLINK over SMEM: items 478/479, FIFO 480, version 1, channels IPCRTR + adsp_apps) and a per-step time limit + `step N (name) failed: reason` line. 0243 adds `bsd/dev/negroni_audio.c` with steps 10..15 (QRTR, GPR SPF-ready, PRM TER MI2S clock 3.072 MHz + I2S pins, GRAPH_OPEN WR_SH_MEM_EP->PCM_CNV->MFC->I2S_SINK + SET_CFG + PREPARE, SHARED_MEM_MAP + START, and `/dev/negroni-audio` S16->S24 sink). A stage-(b) failure tears the graph down and leaves the ADSP up (no SoC re-reset). After the review fixes: kernel sha256 c4761483... (local-20261026-082825, 0242/0243 applied, no 02xx skipped); out/ios16-audio boot_a.img sha256 edda5229... with `negroniadsp=1 negroniadsp_step=15 negronipanic=30 negronipanicreason=2`. Userland: the mediaserverd `__xpc_api_misuse` crash is BTAudioHALPlugin (XPC to absent bluetoothd); `root-add-audio.sh`/`phone-audio.sh` move it to HAL.disabled by default. NegroniAudio.c stage 1 (ring + writer thread) built, sha256 7770ccb4.... `negroniadsp=1` alone stops at step 9 (GLINK, no audio). Nothing on the phone yet. Next: with the ADSP up (steps 1..8 first), step through `negroniadsp_step=10..15`.

- Phone bought: OnePlus 10 Pro NE2211, PAC confirmed by adb.
- Bootloader unlocked (orange state). Auto updates off; stay on 16.0.3.530.
- Stock backup: official full OTA (MD5 checked) and extracted images in `~/op10-backup/`.
- Research: stack map, PAC analysis of xnu-12377, GPU path (`docs/research-report.md`).
- UEFI firmware check: NE2211 `uefi.img` matches the build the negroni Mu patches target.
- Root: Magisk 30.7 in `boot_a`; adb root works.
- Unique partitions and GPT dumped (`scripts/backup/dump-partitions.sh`, 121 partitions, 540 MB gz).
- RAM measured (`docs/device-facts.md`): 9 GiB contiguous at 0x840000000, so the port's memory
  map and `--dram 840000000:C0000000` need no change for 12 GB.
- Build environment: `docker/Dockerfile` (x86_64, Rosetta on macOS), `scripts/uefi/setup-mu.sh`
  (Mu submodules at the pinned commits; Silicium-ACPI at its real base 2d465ad + patch),
  tmux runner `scripts/bg.sh`.

- Mu UEFI built (`out/mu/SILICIUM_UEFI-DEBUG.fd`, 3 MiB; x86_64 container, all 7 r0q patches ported).
- Boot images built natively and checked: `out/ios16/boot_a.img` (shim + Mu FD + 64 MiB payload,
  kernel run 40007883255), `vendor_boot_a.img` (mainline DTB only), `negroni.adt`, `esp.img`.
- iOS 16.7.16 DMGs downloaded (CRC-32 checked).
- GPU reference found: ios-sailfish (`docs/gpu-plan.md`).
- Native macOS Mu build works too (`make mu-build-macos`: Homebrew LLVM, BaseTools from source, no
  Docker/Rosetta/Mono) -> `out/mu/SILICIUM_UEFI-DEBUG-macos.fd`. The first boot uses the container
  build (`SILICIUM_UEFI-DEBUG.fd`).
- iOS root built on macOS (`make root`): 11 GiB used of 16 GiB, 173 apps, fsck_hfs OK;
  sparse image `~/op10-apple/ios16-root.simg` (11.6 GB, sha256 d5d4437d...).
- Vsync raised to 120 Hz in slop patches 0046/0056/0061 (`NEGRONI_FB_VSYNC_US` 8333); patch set
  re-applies cleanly (129 applied, 4 usual skips). Next: rebuild the kernel image and boot it.
- 120 Hz tools (2026-10-25): patches 0252 (`NEGRONI FB STAT:` line once a second, `negronifb_stats`, default 1)
  and 0235 (`negronigpu_level=N`, GX perf level, default 0 = old 220 MHz vote), and 0253
  (`IOMFBDisplayRefresh` property + vsync interval for CoreAnimation, `negronifb_carefresh`, default 1). Kernel
  `out/kernel/local-20261025-170531` (sha256 a0d0d018...): every 02xx patch applied except 0262 (Wi-Fi power-up;
  conflicts with the new slop 0125 XO_CLK pulse, needs a rebase). Not booted. Next: (1) heartbeat env lever on
  the current phone (`scripts/metal/phone-heartbeat.sh on` + reboot), then owner-approved `boot_a` tests with the
  new kernel: (a) `negronifb_zerocopy=1`, (b) + `negronigpu_level=12`, (c) 0253 A/B with `negronifb_carefresh=0`
  (patches/xnu/README-gpu-kernel.md section 12).
- 0254 (2026-10-25): fixed-deadline 120 Hz vsync, no GPU fence wait on the vsync tick (pending frame waits for
  its fence; give-up only on a client close + 500 ms or 2 s without GPU progress), SwapWait busy until the swap is
  on screen (all modes); STAT line + `gpu-wait skips N gave-up N`. Phone test of the first image: tick OK, but CPU copies 51-54 ms (latest fence);
  amended to swap-time fences: kernel `out/kernel/local-20261025-175017` (sha256 e51e7339...), image `out/ios16-0254b`.
  Amended image not booted.
- 0236 (2026-10-25): GPU clock probe (gpucc PLL/GX dumps, `gxclk N MHz` from CP perf counter 0, step-22 blit timing, revote after GPU_SET with `negronigpu_level>0`); images `out/ios16-clk` (level 12) and `out/ios16-clk1` (default). Phone: gxclk 5 MHz at level 12 (vote does not reach the clock); amended with a late report + third vote from the watch, image `out/ios16-clk2`.
- Metal compositor policy (2026-10-25): m2v/0003 + flame/0007, env `NEGRONIMETAL_POLICY` = exact | compositor (default:
  Turnip 8-bit unorm filter + colour writes, containment on) | compositor-srgb | unsafe; plugin logs `images NegroniMetal
  0x... turnip 0x...` for crash symbolication. Built, check-imports PASS; not on the phone. Next: A/B GPU ms per CA frame.
- GL path for backboardd (ios-spes route, 2026-10-25): `scripts/gpu/gl-build.sh` stages negronigl.dylib + a backboardd with
  a weak load command + the gate `/var/db/negronigl/clients`; `scripts/gpu/phone-gl.sh` pushes and switches it
  (docs/gpu-userland.md "GL path"). Built, check-imports PASS, not run on the phone. Kernel deltas from spes:
  patches/xnu/README-gpu-kernel.md section 13.

- GL ES completion (2026-10-26, build only): flush = glFlush + the kernel's swap-time fence (glFinish only with
  `NEGRONIGL_FINISH=1` / `phone-gl.sh finish on`); CAEAGLLayer `renderbufferStorage:fromDrawable:` and
  `presentRenderbuffer:` (3 forms) on Mesa through `userland/negronigl/view.c` for the backboardd shim and the bundle;
  NegroniGL.bundle as the app GL driver with a bundle-local app gate (`phone-gl.sh apps on|off`), linked with chained
  fixups (the old bundle imported `dyld_stub_binder`, missing in 20H392); `ngl_test --layer`. `gl-build` exit 0,
  check-imports PASS for dylib, ngl_test and bundle. Next (phone on): kernel 0257 image, `phone-gl.sh push`,
  `test --layer`, backboardd A/B (`backboardd`, `on`, `restart`), then `apps on` and one GL app (docs/gpu-userland.md).
  Kernel to add: IOSurface CPU lock waits for `gpuFence` (notes.md 15a).

- GPU clock root cause (2026-10-25): PERF_TABLE sent MHz, the GMU wants kHz; GPU ran at ~5 MHz (0236 probe). Patch 0237
  fixes the units. Next: boot it, read `gxclk`, then the GL path (scripts/gpu/phone-gl.sh) and Metal A/B.

- Metal at the real clock (2026-10-25 23:35): backboardd on Metal 150 s, no crash, 4.5-8 ms per command buffer,
  up to 83 GPU presents/s, late ticks 0. Next: Metal for all processes (SpringBoard), GL path A/B, zero-copy flip,
  then a GPU DCVS governor instead of the fixed level 12.

- Poster extensions on Metal (2026-10-25): XR10 answer NO in every process (AegirPoster XR10 pipelines were refused),
  dead-man ignores SIGKILL before the device opened, strike limit env NEGRONIMETAL_STRIKE_LIMIT (4 for *Poster*).
  Built, not tested on the phone (notes.md section 16 end).

- Clock-shift fragments (2026-10-26): the kernel's `negronifb_clockshift` shift ran before the GPU 2D copy had
  reached the panel memory (fence wait result ignored) and covered 150 rows (54 pt, into the lock screen's date).
  Patch 0256: shift after the fence (deferred to a later tick when needed), 120 rows (44 pt status bar),
  `negronifb_clockrows=N`. Images `out/ios16-noshift` (control, no shift) and `out/ios16-0256`. Visual check: owner.

- IOSurface wrap of client memory (2026-10-26, patch 0257, README-gpu-kernel.md section 12 "0257"): IOSurfaceRoot
  selectors 6/7 (WrapClientImage/WrapClientMemory, CoreAnimation's GL renderer) wrap the caller's page-aligned memory
  as a cached surface and answer the normal lock result; bad input returns kIOReturnUnsupported instead of a zeroed
  success (the backboardd far 0x30 crash of notes 15a). Built: `out/ios16-0257`. Not flashed (phone off). Test: the GL
  path (`scripts/gpu/phone-gl.sh backboardd/on/restart`), no `IOSurface wrap of client memory refused` line.

- Power off (2026-10-26, patch 0214): "Shut down" and `op10tool ctl poweroff` rebooted because PSCI SYSTEM_OFF only
  drops PS_HOLD and the PMK8350 PS_HOLD reset type was a reset [V, log timing]; 0214 sets the type SHUTDOWN
  first (PON GEN3 registers +0x52/+0x53; 0211 used +0x5a/+0x5b) and prints the PMIC PON log at boot. Built; phone
  test pending (battery empty, hold). Fastboot-menu power off is ABL: not covered (notes.md section 22).

- Power (2026-10-26, patches 0280 thermal / 0281 GPU DCVS / 0282 USB reset, README-thermal.md): TSENS readings and a
  70/60 C cap policy (GPU levels, CPU rows), a busy-based GPU governor (idle -> 350 MHz), and the CDC-ECM endpoints
  rebuilt after a host bus reset (the "gone/up, then silence" drops). 0272 amended with per-poll charger diagnostics
  (the phone read 0xff: the SMB5 blocks are not reachable from EE 0 or not in the APID map; the diag tells which).
  All in the `kernel-pwr` build, image `out/ios16-pwr` (config args). Not flashed (phone flat). Next: boot it, read
  `NEGRONI THERMAL`, `NEGRONI GPU DCVS`, `charger diag`; then IFPC/slumber between frames and the charger via the
  debug arbiter or the ADSP charger PD.
- CPU governor (2026-10-26, patch 0284, README-cpufreq.md): a 100 ms thread moves each cluster's EPSS row from
  the kernel's per-CPU busy time (`processor_cpu_load_info`, recount): > 70 % -> +1 row to the cap (0280 thermal cap
  stays the bound), < 30 % for 300 ms -> -1 row to the floor = the ABL row (0098, never lower; floor_mhz only raises
  it). With the ABL rows of boot 0097 only d0 moves (rows 12..14); d1/d2 stay at the top. Logs the LMh limit (`lmh`)
  and `cpu N/N/N MHz` on the GPU WATCH line. Built: `kernel-cpugov5`, image `out/ios16-cpugov`. Not flashed.
  Next: boot it, read `dN table`/`governor on`/minute lines and `lmh`, compare THERMAL cpu C and battery mA with
  `ios16-pwr`; then decide (owner) whether d1/d2 may go below the ABL row (boot 0097 ran d1 15 / d2 14).
- Display sleep / power key (2026-10-26, patch 0258, README-brightness.md, README-reboot.md "0258"): the kernel
  power-key fast-off (0250/0251: < 700 ms press = DBV 0 at once) is removed; the key goes to iOS only. Lock =
  iOS fade, then DBV 0 + DCS 0x28/0x10 (panel sleep, DT off-command timings 21/101 ms); wake = 0x11, 133 ms, 0x29,
  last DBV, redraw; `negronifb_sleep=0|1|2` (default 1; 2 = 1). Panic wakes the panel. Code check: slide to
  power off ends in `negroni_power_off()`; no 0215. Built (review fixes in): `kernel-power4` job (all patches/xnu),
  kernel `out/kernel/local-20261026-072629` (sha256 220a82de...), image `out/ios16-power` (config args;
  boot_a fa6a7f0c...). Not flashed. Next: owner test (short press, press again, long press -> slide, unplugged).
- Charger input (2026-10-26, patch 0272, README-battery.md section 7): the phone drained to 0 % on USB (16 % at 01:31,
  -458 mA, cable in). 0272 logs the PM8350B SMB5 charger registers with the battery line and sets the USB input limit
  to `negronichg_ma` (default 500 mA), un-suspends USBIN and enables charging. Kernel + image `out/ios16-chg` built
  by the `kernel-chg` job (sha256 in logs/kernel-chg.log and `out/ios16-chg/SHA256SUMS`). Not flashed. Next: the owner
  flashes it when the phone has charge; check `charger ...` lines, then the thermal/DCVS work (0280/0281).
- Charger ownership + debug arbiter (2026-10-26, patch 0273, README-battery.md section 8): [V] the ADSP charger PD owns
  the PM8350B charger (DT `qcom,pmic_glink` charger_pd; OnePlus driver uses GLINK only), so EE 0 cannot write it.
  [V] 0272 read three status registers at SMB2 offsets (now DCDC 0x1107/0x1108/0x110b) and set CMD_ICL_OVERRIDE = 1
  (HC mode needs 0): fixed. 0273 adds the EE-independent debug arbiter (0x10b14000; fuse bit 18 of 0x221c8784; AOP
  QMP QDSS clock vote), `negronichg_arb=auto|normal|debug` (default auto, chosen at poll 3), writes still only the
  six 0272 registers with `negronichg_ma` (500). [V] `usbin` channel is right (VADC 0x311 1/16); it is measured only
  with negronibatt=4/5, so the image has `negronibatt=5`. Built: `kernel-chg3` (review fixes) -> out/kernel/local-20261026-073259
  (sha256 461b94bc...; all 52 patches/xnu; 4 usual dxb skips); image `ios16-chg2`
  -> out/ios16-chg2 (boot_a sha256 baa05286...). Not flashed. Next: owner flashes/boots out/ios16-chg2 with the cable
  in; read the `charger route`, `debug arbiter: fuse`, `check read`, `charger blocks`, `charger ...` and `usbin=`
  lines. Fuse bit clear or a hang at "first access": boot `negronichg_arb=normal`; the only path left then is the
  ADSP charger PD over GLINK (after the audio agent's ADSP boot).

## First boot (2026-10-24, 19:48)

- Battery percentage (2026-10-26, patch 0276, README-battery.md section 10): [V] "12 % -> 9 %" was a reboot at 13:32:30
  (two boots; 0271 restarts from the first sample, which was under the 1.24 A boot load); within a boot the value froze
  (never down on a charger, net current ~0). [V] True SoC now about 9 % (rest 3662-3669 mV at 0 mA), losing ~1 % per
  10 min with the cable in. [V] The percent cannot come from a PMIC register (no QG here; the gauge is on an ADSP-only
  bus): 0276 uses 0274's GLINK SoC when fresh, else the OCV estimate with a 1 %/30 s rate limit and a filtered current
  for the direction and `charging`; a 1 s plug tick (`negronibatt_fast`) publishes ExternalConnected within 1 s of
  the cable (`external 0->1 ... after N ms`). 0276 applies with or without 0274 (0274 was rebased by its agent
  before the build). Kernel out/kernel/local-20261026-084328 (sha256 20026d62...; 0274 + 0276 applied, 4 usual dxb
  skips), image `out/ios16-soc` (config args + `negronibatt=5 negronipanic=30 negronipanicreason=2`; boot_a sha256
  400f1f95...). Not booted. Next: boot it
  with the cable in; check `soc src=ocv ocv= target=` and that the percent follows the target within 10 min; with 0274
  active `soc src=glink`. Later: keep `fSoc` across boots (file like the RTC offset).
- Flash: userdata from fastbootd (45 x 256 MiB, 303 s), then vendor_boot_a, vbmeta_a, dtbo_a,
  boot_a, slot a: all OKAY.
- Screen: the ABL log text, then **DarwinBoot's green bar** ("the kernel entry code ran"), then
  nothing. Debug image (`negronifb_noconsole=0`, `negroniusb=2`): same screen, no USB device.
  -> the kernel stops before its console starts.
- Likely cause: Mu "Kernel RAM" was 0x840000000+0x140000000 (the port's later iOS 17 / 4K value; the
  notes say that setup hangs right after the green bar). The 16K iOS 16 kernel needs
  0x841000000+0x13F000000, so DarwinBoot's window (0x841004000) keeps a 32 MiB-aligned VA-PA delta
  (slop NOTES 2026-10-20). Fixed in `patches/mu/0001-negroni-kernel-ram-16k.patch` (applied by
  `scripts/uefi/prepare.sh`); Mu and both boot images rebuilt.

## iOS 16 boots on the NE2211 (2026-10-24, 20:10)

With the Kernel RAM fix (debug image: `negroniusb=2`, `negronifb_noconsole=0`), the live USB log
(`make usblog`) shows the iOS userland: backboardd ("NEGRONI FB: display on"), SpringBoard
(AppleKeyStore calls), com.apple.datamigrator (first-boot migration), thermalmonitord,
CAReportingService, localizationswitcherd, symptomsd. bluetoothd and fairplayd.H2 are relaunched
every ~10 s (no hardware; the port dropped their jobs in its later root). Next: the screen state,
then the normal image (`make flash-boot`).

## Fingerprint status (2026-10-26)

- Done: docs/fingerprint-plan.md (DT facts, driver/TEE analysis, display HBM flow, staged plan, iOS design); patches
  0350 (`negronifp=1|2`: SE clocks, GENI SPI probe, LDO, reset, chip-ID frames, IRQ poll) and 0351 (`negronifp_hl`:
  highlight disc + panel HBM set); scripts/fp/extract-vendor-fp.sh, build-test-image.sh. Built: kernel local-20261026-084051 (f8e2b492...), image out/ios16-fp (boot_a 1926dc56...); notes.md section 25.
- Not done: stage C (raw capture: SPI protocol unknown, lives in the TEE), stage D (matcher + unlock). Not run on the phone.
- Next: phone test `out/ios16-fp` (owner approval: GCC/TLMM/RPMh writes, panel HBM); read the proof lines; find the
  stock icon position (runtime property) to replace the placeholders.

## Bluetooth status (2026-10-26)

- Done: docs/bluetooth-plan.md (facts, firmware list, iOS analysis); scripts/bt/fetch-sources.sh, fetch-firmware.sh;
  patch 0330 (`negronibt=1`: rails, QUP2 clocks, GENI UART, BT_EN sequence). Build results: notes.md section 24.
- Not done: patch 0331 (HCI stage). Not run on the phone (battery flat).
- Next: phone test `negronibt=1` (owner approval: GCC/TLMM/RPMh writes), then 0331.

## Display performance status (2026-10-26)

- Done: measurements (README-gpu-kernel.md section 18: presents/s mean 43.5, DCVS 350-421 MHz, CA's SwapWait busy
  173/s, Metal ctc 15.6 ms); patches 0267 (vsync notification after the frame is queued; clock shift inside the
  GPU/CPU copy, no read of the panel memory) and 0286 (GPU DCVS UI floor 640 MHz at >= 30 swaps/s); host test
  patches/xnu/tests/fb-clock-copy-test.c PASS; scripts/display/build-perf.sh -> kernel
  local-20261026-082629 (sha256 92f50f3a...), `out/ios16-perf` (boot_a 2583f0ab...), `out/ios16-perf-noshift` (boot_a 50d09e1b...).
- Not done: phone test; panel double buffer with a DPU base flip; zero-copy test (0234).
- Next: owner flashes `out/ios16-perf`, scrolls, sends the FB STAT / GPU DCVS lines (goal: presents/s 100-120,
  timeouts < 100/s) and says whether the top-left strip is still; then `out/ios16-perf-noshift` for the A/B.

## Phase 1: iOS 16 (existing negroni port)

1. ~~Measure the 12 GB memory map~~ (done over adb root). Optional: shim probe with `fastboot boot`.
2. Mu UEFI: extract DXEs from the OTA `uefi.img`, run `portpatch2.py` / `mkbinaries.py`, fix
   MemoryMapLib for 12 GB, build `negroniPkg` DEBUG.
3. Kernel from slop CI run 40007883255; ADT with the new `--dram`; payload; `boot_a` image.
4. ~~iOS 16.7.16 (iPhone10,3, 20H392) HFS+ root~~ (done).
5. **Next:** writes with `scripts/flash/ios16.sh`, each approved first. Order: `userdata` from fastbootd
   (8 GiB ABL sparse issue), then in the bootloader `vendor_boot_a`, `vbmeta_a`, erase `dtbo_a`, `boot_a`,
   `set_active a` + reboot.

## Phase 2: iOS 26 kernel and userland

1. xnu-12377.121.6 arm64e from a VMAPPLE-based NEGRONI config.
2. Native PAC keys instead of the VMAPPLE hvc calls (one global key set first).
3. Clear SME/SME2, PAN3, paravirt CTRR in the config.
4. A13 iPhone IPSW (iPhone12,1 / iPhone12,5) as userland.
5. Port the 128 negroni patches, or prelink Apple's arm64e A13 kexts.
6. Find out whether iOS 26 QuartzCore renders without Metal.

## Phase 3: GPU (Adreno 730)

1. Fix the RedwoodGPU user client panic in slop's A730 path.
2. Port UniXNU NativeAdreno board code (GMU, RSC, votes, cmd-db, SMMU) to SM8450.
3. Port NativeMetal (metal2vulkan via Turnip FD730) to the iOS 26 Metal interface.
