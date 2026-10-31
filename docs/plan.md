# Plan and status

## Branch `laurel-sprout`: Xiaomi Mi A3 port (2026-10-31)
Target: Xiaomi Mi A3 (`laurel_sprout`, SM6125, ARMv8.0, no PAC, Adreno 610). iOS 16 first, iOS 26 later (research:
no PAC, needs zeta-style PAC lowering). Done: device facts (`scripts/device/info.sh`), 7 pinned reference trees
(ios-topaz, Mu-Silicium, MiCode `laurel-r-oss`, Lineage kernel/device/common, mainline), port plan with the topaz
comparison. Next: owner sets phone-safety targets (active slot is `_b`), root + backup, live FDT, port the topaz shim.
Details: `docs/laurel_sprout/port-plan.md`.
Flashing (2026-10-31 23:58): `fastboot boot` is refused by this ABL; the shim image goes to `boot_b` with
`scripts/bg.sh laurel-flash scripts/laurel/flash-boot.sh`. The script runs `fastboot reboot bootloader` first:
a session entered with Power+VolDown has a broken ABL USB state (garbled commands, uploads stall at 16 MiB); after the
warm reset the plain full-size flash takes 0.5 s. Latest `out/laurel/laurel-boot.img` (23:16 build, kalloc fix 0102)
flashed and booted at 23:58; result (photo) pending.

Status date: 2026-10-27 (12:15).

## Priorities (2026-10-27 20:55, owner)
1. GPU acceleration working (Metal; 0389/0395/0398/0399 in test).
2. Video playback working (0390 plane layout + 0399 wired-memory guard; t29/t29b froze from wired-memory exhaustion).
3. Audio working (never worked: the ADSP start drops USB; audio agent on it).
RAM for GPU (2026-10-27, RAM agent; compile/host checks only, not booted, not committed): kernel patch 0401 +
patches/mu/0002 + config `[ram]` give XNU 7 GiB (was 3 GiB) at 0x841004000..0xA01004000; the GPU pool (1536 MiB) moves to
0xA20000000 (`negronigpu_poolbase`, added by build.sh to every image). Self-check in the kernel (bank, ADT sizes, GPU region/pool) and
in adt-extra.py (Mu FD "Kernel RAM"); fallback 3 GiB; kill switches `negroniram=0` / `XNU_RAM=0`. Next: rebuild Mu
(scripts/uefi/prepare.sh + build.sh), one combined image, `fastboot boot`, read `NEGRONI RAM:` and `hw.memsize`.
Details: docs/notes.md section 90.
TODO later (owner): cellular. 0397 boots the modem for GNSS only (never ONLINE). 4G/5G data and SIM detection need the
modem ONLINE, IPA, QMI DMS/NAS/WDS/UIM and the iOS CommCenter side.

## TODO (2026-10-27, end of the night session; owner: "bluetooth works, wifi doesn't")
State 2026-10-27 14:50: the phone runs stock Android + Magisk again (restore.sh --magisk, userdata formatted: no iOS root on
the phone). An iOS test session starts with a full iOS flash (scripts/flash/ios16.sh order) and ends with restore.sh --magisk.
Earlier state: boot_a = out/ios16-safe. Latest reviewed kernel out/kernel/local-20261027-023416 (all committed
patches up to 0379 + 0345/0374/0375/0376; no 0380). Test image out/ios16-t23 (ADSP off, Wi-Fi MSI on, camera ADT nodes,
watchdogs 0371=60 s / 0375=30 s). Details: docs/notes.md sections 57-63, patches/xnu/README-*.md.

1. **Wi-Fi does not work for the owner (priority 1).** Proven: with 0344 MSI the chip reaches WMI SERVICE_READY and
   iOS has en0 (t21, notes 57). Not proven: scan and join. 0345 (wifid answers + join fix) is committed, never booted.
   Next: boot t23, open Settings > Wi-Fi, read `NEGRONI WLAN iOS` lines (scan request? scan done? SCAN_RESULT? join?).
   If wifid never asks for a scan: 96 VIRTUAL_IF_ROLE, 51 COUNTRY_CODE, event 55 (README-wifi.md "0345" risks).
   **Owner test on t23 (12:11-12:14, logs/usblog-20261027-060101.txt):** [V] the radio works: the driver's own
   passive scan saw 19 BSS (27 beacons/probe responses). [V] wifid sent NO scan request; it asked twice
   `user client type 0 asked of en0's service: none (ioctl path)` and only polled a few ioctls (CARD_CAPABILITIES,
   SSID ENXIO). Correction (Wi-Fi agent, 2026-10-27, IO80211.framework 20H392 disassembly): [V] when IOServiceOpen
   type 0 fails, Apple80211BindToInterfaceWithService falls back to the ioctl path, and event monitoring falls back to
   the kernel event socket; [V] in boot 16 (02:54) wifid had the same "none" line and still sent SCAN_REQ. So the
   user client is probably NOT the blocker. [V] In two boots wifid's full init (POWER, 106, 254, 207) started within
   1 s of an `exit bluetoothd` line; [I] wifid may wait on bluetoothd (BT/Wi-Fi coex?). [V] The t23 log has a gap
   12:12:18-12:13:04, so "no scan" is proven only for the logged windows. Next: boot with 0345, open Settings > Wi-Fi,
   capture the full log (no gap), and watch bluetoothd state. User-client facts (selectors 0-6, 0x3c30-byte request,
   event ring 0x30-byte records) are in this agent's report if the path is needed later; its run was stopped by a
   safety classifier, no patch exists.
   **Wi-Fi analysis 2 (2026-10-27, README-wifi.md "0346 analysis", notes 66):** the Bluetooth lead is wrong
   (bluetoothd crashed every 10 s in boot 16; the timing was chance). [V] wifid's own init stalls in
   WiFiManagerScheduleWithQueue for up to minutes in about half of the boots with en0; during the stall the WiFiManager
   server is not up, so Settings gets no interface. After the stall wifid powers on and scans (boot 16). Kernel side OK.
   [I] a synchronous wait on another process (runningboardd / cfprefsd / accountsd?). Next test: during the stall run
   scripts/wifi/wifid-stall.sh (spindump of wifid) to name the blocking call; work-around to try: kill wifid over SSH
   (launchd restarts it).
2. **USB data watchdog 0375: first phone test inconclusive.** t23 12:12: armed (`reboot after 30 s without USB data`),
   but 45 s of `ifconfig en10 down` on the Mac did not fire it, so frames still reached the phone (or macOS kept the
   link busy). A second 20 s down at 12:14 lost the link at 12:14:51 (cause not read yet: read `make bootlog`, boot 13
   end mark). Prove 0375 fires before any more ADSP tests (keep-usb-reachable rule).
3. **ADSP + Type-C fix 0374** (notes 58): t22 05:05 got the Mac back as host 6 s after the drop, but the data path
   died and the phone needed a button reset. Retest only with 0375 proven.
4. **Camera.app**: test images now carry the camera ADT nodes; run `scripts/camera/phone-camera.sh push`, boot t23,
   open Camera.app (docs/camera-ios-2026-10-27.md section 7).
5. **Passcode 0221** (committed): owner test in Settings > Passcode (README-aks-amfi.md "0221 passcode").
6. **Sensors**: 0376 (SLPI start, phase 1) committed, needs the ADSP-area write (`scripts/fw/build-areas.sh`,
   `write-areas.sh`; owner approval) and `negronislpi=1..3` tests. Phase 2 (0380 FastRPC file server + sns_client) is
   HELD, unreviewed, outside the repo in out/hold/sensors-phase2-final-20261027-0806/ (its agent run was stopped by a
   safety classifier once); owner decides: review + commit, or leave.
7. Audio (needs the ADSP, item 3), VOOC fast charge (default off, after item 3), location services (not started),
   watchdogd fixed (0378), Bluetooth works (owner, 2026-10-27).

## Next (owner + main session, older list of 2026-10-26)
1. Charge in fastbootd to > 60 %. Then `scripts/flash/ios16.sh userdata` (fastbootd; writes the root + firmware areas),
   `vendor_boot`, `vbmeta`, `dtbo`, `boot` with `IOS16_OUT=out/ios16-all2` (safe baseline) or `out/ios16-everything`
   (diagnostic: every addition on), `active`.
2. First boot: charger test (`out/ios16-chg3` or everything + `negronichg_glink=1`): expect `write USB_INPUT_CURR_LIMIT
   1500 mA ... ok` and ibat positive by hundreds of mA. Then display perf (`out/ios16-perf`): presents/s 100-120 while
   scrolling, clock still. Then by eye: Siri orb (MPS), lock-screen poster `uncaught exception` line, WebGL page.
3. Reviews/audits: docs/audit/2026-10-26-*.md (resume the agents after 17:20), then fold into this plan. Metal/GL audit
   follow-up done without the phone (notes.md section 26): kernel 0289 (IOSurface lock waits for the GPU fence,
   `RedwoodWaitsForGPU`) in `out/ios16-gl2` (boot_a 78c23259...), Metal bundle 7473f41b (flame/0013), GL stage with the
   RedwoodWaitsForGPU check; the on-phone steps are docs/metal-management.md section 4 (8 steps).
4. Open code items: 0331 BT HCI; panel wake 0268 + double buffer 0269 built (`out/ios16-dpu`), phone test pending;
   Wi-Fi step 25+ (WLAN_CFG/MODE, CE/HTC/WMI, iOS 80211 glue); audio stage c (amps) + mic; camera: phone test of levels 0-5 (`negronicam=5`, see "Camera levels 3-6" below);
   fingerprint stage C/D; haptics UI path built (out/ios16-hap2, phone test pending); GPU recovery/idle/KGSL parity built (out/ios16-gpur,
   section "GPU recovery and CPU idle status"), phone test pending.

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
- Camera levels 3-6 (2026-10-26 evening, camera agent; patches 0312-0316, patches/xnu/README-camera.md "Levels 3-6",
  docs/camera-plan.md): 0312 RPMh MMCX NOM + camera NoC BCM votes (CN0/MM1/MM0/SH0/MC0, new `negroni_rpmh_cam_bcm`)
  before the first camcc access at every level (audit 2026-10-26 part A), level 3 CPAS/CAMNOC + apps-SMMU check of the
  IFE/ICP streams (`negronicam_smmu=0|1|2`); 0313 level 4 camcc PLL0/PLL3 + capture clocks + CSIPHY1 C-PHY 3 trios;
  0314 IMX789 FTM table (OnePlus cam_sensor_settings.h:6017, stream on) + frame-counter proof; 0315 level 5 CSID0 +
  IFE0 RDI0 -> memory, TPG13 frame then IMX789 4000x3008 RAW10 frame, `/dev/negronicam-tpg|-sensor`,
  scripts/camera/pull-frame.sh + raw-to-png.py; 0316 level 6 ICP PAS 33 + HFI init + SYS_INIT (CAMERA_ICP in the ADSP
  area: scripts/camera/extract-icp-fw.sh, mkadsparea.py). iOS: AppleH10CamIn user-client table (94 selectors) found in
  the D22 kernelcache (scripts/camera/ios-re.sh); design = own NegroniCamera service + capture app first.
  Build: full kernel out/kernel/local-20261026-173833/kernel.development.negroni, sha256 4e4d155111db6c7329e1b542111c5bc48f9c42afcbeb278eb0ceb378d79a158b (after the review fixes: HFI_Q_WORDS 239, BCM enable x = 0 / y = 1, MXC NOM; all patches applied incl. 0310-0316; skipped only the 4 usual dxb patches). No image (owner rule: the main session builds one combined image).
  Next: the combined image with `negronicam=5` (boot-args table: README-camera.md "Boot-args"; the safe default
  `negronicam_smmu=1` stops before DMA if the IFE streams are not in bypass, then `negronicam_smmu=2`); read the
  `NEGRONI CAM:` lines; `scripts/camera/pull-frame.sh`. Level 6 needs the new ADSP area on userdata.
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
- Wi-Fi levels 7-10 + SMMU S1 (2026-10-26, Wi-Fi agent; build-only, no image per the owner rule): patches 0320 (QMI WLAN_CFG with the ath11k wcn6855 CE pipes / service map / 30 shadow registers + WLAN_MODE mission, steps 25-26; keep-alive poller, DMA-address seam, `negroniwlan_hostcap=android`, M1 -> M2 fix), 0321 (copy engines on HAL SRNG through the BAR0 window, polled, steps 27-28 HTC READY), 0322 (HTC connect + WMI SERVICE_READY/EXT, INIT, READY with the MAC vs ADT, steps 29-32), 0323 (channel list, STA vdev, passive scan: `BSS N: SSID "..." RSSI`, steps 33-35), 0324 (apps-SMMU stage-1 context for stream 0x1c01 with Android's IOVA window, `negroniwlan_smmu=3`, owner approval). Host tests `scripts/wifi/wmi-host-test.sh` and `qmi-host-test.sh` ALL PASS. Kernel out/kernel/local-20261026-173712 sha256 38927346... after the 0324 review fixes (patch-report: 0320-0324 applied, only the 4 usual dxb skips; 0324 sha256 ad81bdaa...). Boot-args for the combined image: `negroniwifi=10 negroniwlan=10 negronipanic=30 negronipanicreason=2`. Not run. Next: prove levels 2-6 on the phone (firmware area first), then 7-10; then 0325+ (join, WPA2 supplicant, HTT data path, en0 + Apple80211 ioctls: README-wifi.md "Final stage design").
- Vibration (2026-10-26, haptics agent): patch 0300 `negronihap=1` = PM8350B HV haptics direct play over SPMI (owner log, census, 300 ms boot buzz) + API `negroni_haptic_play(ms, strength)`; 0301 = iOS "vibrator" IOService (FigVibrator legacy IOKit path, setProperties `hertz_millisecs`/`repeat`). Kernel out/kernel/local-20261026-072436 (sha256 0f22dbf4...), image `out/ios16-hap` (config args + `negronihap=1`, boot_a sha256 99a1123a...). Built, not run. Next: owner-approved boot of out/ios16-hap, check the `NEGRONI HAPTIC:` lines and the buzz, then a ringtone vibration preview (`NEGRONI VIBRATOR: start`). UI haptics (CoreHaptics) need an Actuator HAL device: large, later (docs/haptics-plan.md). Update (evening): UI haptics built: 0302 (`negronihap_ui=1`: /product/haptics closed-loop node + `/dev/negroni-haptic` envelope -> direct play, CAL_EN toggle), 0303 (CL brake ff 3f 1f + hBoost-ready wait), NegroniAudio Actuator -> node (host test PASS), scripts/haptics/{build-haptics-kernel,root-add-haptics,phone-haptics}.sh. Kernel local-20261026-125419 (6c35b3f5...), `out/ios16-hap2` boot_a e479ff37.... Next: `scripts/haptics/phone-haptics.sh push`, boot out/ios16-hap2 (owner approval), feel taps; keyboard needs Settings > Sounds & Haptics > Keyboard Feedback > Haptic. Proof lines: docs/haptics-plan.md 8.3.
- Wi-Fi/audio (2026-10-26): 0262 rebased on slop 0125; `negroniwifi=10` on the phone: PCIe link UP Gen2 x1 and the QCA6490 answers (17cb:1103, MSI at 0x50) [V]. Stage 1 (`negroniwlan=2`, image out/ios16-wlan2 in boot_a) is untested: the phone browned out at 16 % battery before it logged. ADSP step 1 ran (SMEM OK, PAS query answers 0 -> patch 0241 logs it only); HAL plug-in pushed to the live root (scripts/audio/phone-audio.sh): 3 clean boots, 2 boots with the old SIGABRT, undecided. Next: charge the phone, flash khz12 back, then wlan2 + `negroniadsp_step=4` with `negronipanic=30 negronipanicreason=2`.
- Screen-off freeze (2026-10-26, wake agent): patch 0275 `0275-negroni-display-off-fast.patch` (after 0259; 0260-0264 are WLAN). The 0251 fade read the write-combined panel memory pixel by pixel: ~1 s per vsync tick, 7 s UI freeze per screen-off (`fade 7055 ms`, `late ticks 136`, `swaps/s 0`). 0275 writes black with stores only on tick 0 and calls the backlight on tick 1. Kernel + image `out/ios16-wake` (config args + `negronipanic=30 negronipanicreason=2`): see docs/notes.md section 15 for the hashes. Verify: `display off: black in N us` (N < 10000) and `display off (fade N ms, DCS sleep ok)` with N <= 25, `late ticks 0` around it, then apps open after a wake.
- Audio stage (a) step 9 + stage (b) (2026-10-26, audio agent; patches 0242, 0243; build-only, phone off): 0242 adds ADSP step 9 (GLINK over SMEM: items 478/479, FIFO 480, version 1, channels IPCRTR + adsp_apps) and a per-step time limit + `step N (name) failed: reason` line. 0243 adds `bsd/dev/negroni_audio.c` with steps 10..15 (QRTR, GPR SPF-ready, PRM TER MI2S clock 3.072 MHz + I2S pins, GRAPH_OPEN WR_SH_MEM_EP->PCM_CNV->MFC->I2S_SINK + SET_CFG + PREPARE, SHARED_MEM_MAP + START, and `/dev/negroni-audio` S16->S24 sink). A stage-(b) failure tears the graph down and leaves the ADSP up (no SoC re-reset). After the review fixes: kernel sha256 c4761483... (local-20261026-082825, 0242/0243 applied, no 02xx skipped); out/ios16-audio boot_a.img sha256 edda5229... with `negroniadsp=1 negroniadsp_step=15 negronipanic=30 negronipanicreason=2`. Userland: the mediaserverd `__xpc_api_misuse` crash is BTAudioHALPlugin (XPC to absent bluetoothd); `root-add-audio.sh`/`phone-audio.sh` move it to HAL.disabled by default. NegroniAudio.c stage 1 (ring + writer thread) built, sha256 7770ccb4.... `negroniadsp=1` alone stops at step 9 (GLINK, no audio). Nothing on the phone yet. Next: with the ADSP up (steps 1..8 first), step through `negroniadsp_step=10..15`.
- Audio amps + guard + tone + earpiece + graph + crash watch (2026-10-26 evening, audio agent; patches 0244-0248; build-only, phone on Android). [V] Paths: speaker = 2x TFA9874 (I2C 0x34/0x35) on TERT MI2S (0243's port is right); earpiece = 0x34 alone, profile "receiver" (not the WCD938x); WSA SoundWire amps disabled in the DT; headphones = RX macro + WCD938x; main mics = TX-macro DMIC3/4 with WCD938x bias. 0244 fixes 0243's TLMM base (0x0f100000, 32 KiB map), adds the speaker guard (cap -20 dBFS, high-pass, power/peak limiter, soft start; host test PASS after it caught a sign bug) and the TFA9874 cold start from the vendor driver + container table (`scripts/audio/tfa-cnt.py` -> tfa-init.bin in the ADSP area), TDMSPKG (an attenuation: gain = 21 dB - value) held at a floor (9 speaker = 12 dB, 15 receiver = 6 dB; never louder than the vendor), amps off on silence/fault/panic. 0245: `negroniaudio_tone=1|2` 1 kHz 2 s. 0246: route ioctl + sysctls `kern.negroni_audio_route`/`kern.negroni_audio_tone`. 0247: mainline graph values (`negroniaudio_graph=1` = old). 0248: ADSP FATAL watch + stop + PAS shutdown. Kernel out/kernel/local-20261026-174012 sha256 daf42c44..., 0242-0248 applied, only the 4 dxb skips (no image: owner rule). Not done: mic, headset (weeks: SoundWire + WCD938x + TX macro), HAL receiver route (iOS side [U]). Boot-args for the combined image: `negroniadsp=1 negroniadsp_step=15 negroniaudio_amp=1 negroniaudio_tone=1`. Next: owner writes the new ADSP area, boots the combined image and listens.

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
  `scripts/uefi/prepare.sh`); Mu and both boot images rebuilt. (2026-10-27: 0001 is in the Mu submodule commit and
  deleted; patches/mu/0002 makes the region 0x1DF000000 for the 7 GiB window of 0401, docs/notes.md section 90.)

## iOS 16 boots on the NE2211 (2026-10-24, 20:10)

With the Kernel RAM fix (debug image: `negroniusb=2`, `negronifb_noconsole=0`), the live USB log
(`make usblog`) shows the iOS userland: backboardd ("NEGRONI FB: display on"), SpringBoard
(AppleKeyStore calls), com.apple.datamigrator (first-boot migration), thermalmonitord,
CAReportingService, localizationswitcherd, symptomsd. bluetoothd and fairplayd.H2 are relaunched
every ~10 s (no hardware; the port dropped their jobs in its later root). Next: the screen state,
then the normal image (`make flash-boot`).

## Power status (2026-10-26 evening, power agent; build only)

Done [V build]: 0277 charge loop over GLINK (FV/FCC per the DT JEITA bands every 5 s, thermal FCC level), 0278 (percentage
across boots, cell temperature, XO/skin to the hub, BCL MONITOR_EN, QDSS vote release), 0283 (per-zone DT thermal
trips + BCL levels), 0291 (`negronicpufreq_floor=abl|lut`). Build `pwr-build` (scripts/battery/build-pwr-image.sh, lock out/kernel/.lock held over kernel + image): kernel out/kernel/local-20261026-124827/kernel.development.negroni sha256 01363704dab977e2259aecbe1fb81141133ba5458ec97a59a6b6abf86b981fa3; patch-report applies every patches/xnu patch 0270-0291 incl. 0277/0278/0283/0291 (and the other agent's 0287/0288), only the 4 usual dxb skips; strings `loop: battery`, `store: soc restored`, `trip %s %s (value`, `negronicpufreq_floor`, `QDSS clock vote released` in the kernel. Image out/ios16-pwr was built in that same locked job from that kernel (local-20261026-124827, sha256 01363704...; [V] three 64 KiB pieces of it found byte-equal in out/ios16-pwr/esp.img; the image SHA256SUMS lists only the image files). It is BEFORE review fix 1 (0277 BATT_CHG_EN restart log bound); per the owner the fix gets a kernel-only proof build, the main session builds the combined image. Review fixes 1-4 (2026-10-26 18:5x): kernel-only proof build `pwr-kernel` (IMAGE=0, lock held): out/kernel/local-20261026-132431/kernel.development.negroni sha256 4786905de90c56b9150153d01f33f69ed87bc7769611e494dd111a1c32974b34, 0277/0278/0283/0291 applied, only the 4 usual dxb skips, string `further failures are not logged` (fix 1) in the kernel. 0277 sha256 now in the report. Image (config args + `negronibatt=5 negroniadsp=1 negronichg_glink=1 negronichg_ma=1500 negronifb_sleep=0 negronipanic=30 negronipanicreason=2`): boot_a.img 72ee45050d399b14a1805b55c65c7cd927a90ed45d6b3c8d5596b6582afc9394, vendor_boot_a.img c29329ee..., esp.img 01f9330f..., negroni.adt 12b7654d... (out/ios16-pwr/SHA256SUMS). Not booted. Patch sha256: 0277 cd22073c..., 0278 047a4652..., 0283 564c7390..., 0291 fa95dcd5...
Observations vs guesses: all code facts are [V] (file:line in README-battery.md s.11-12, README-thermal.md "0283",
README-cpufreq.md "0291"); the PD's acceptance of FV/FCC writes, its FV unit and the BCL bits are [U] until a boot.
Next: (1) boot out/ios16-pwr (fastboot boot, owner approval; ADSP firmware area on userdata, battery > 30 %):
`grep "glink: loop\|BATT_VOLT_MAX\|NEGRONI THERMAL\|store:"`; expect `band normal`, `BATT_VOLT_MAX reads 8870: pack mV`,
`write BATT_VOLT_MAX ... = 8870: ok`, FCC 1100000 ok, ibat > +500 mA. A `REFUSED`/`unknown unit` line = the loop
stays out (safe). (2) Then a `pwr-lut` image (`negronicpufreq_floor=lut`) after the owner decides. (3) Wi-Fi/BT rail
release on failed stages: proposal in docs/audit/2026-10-26-power.md section 6 for the radio owners.

## Fingerprint status (2026-10-26)

- Done: docs/fingerprint-plan.md (DT facts, driver/TEE analysis, display HBM flow, staged plan, iOS design); patches
  0350 (`negronifp=1|2`: SE clocks, GENI SPI probe, LDO, reset, chip-ID frames, IRQ poll) and 0351 (`negronifp_hl`:
  highlight disc + panel HBM set); scripts/fp/extract-vendor-fp.sh, build-test-image.sh. Built: kernel local-20261026-084051 (f8e2b492...), image out/ios16-fp (boot_a 1926dc56...); notes.md section 25.
- Done (evening): stage C probes. Public sources pulled (`scripts/fp/get-references.sh`: the OPLUS G7 HAL source with
  `gf_delmar_types.h`, the OPLUS kernel shim, goodix-fp-dump); facts in docs/fingerprint-plan.md section 7: the HAL and
  the shim carry no SPI frame (all TA commands: `GF_CMD_DELMAR_SENSOR_READ_IMAGE = 101`), the module has a Goodix MCU
  (fw app/bootcode, GW183 sensor die), the origin frame is 364 x 252 x 16 bit. Patches 0352 (`negronifp=3`: public
  Goodix MCU message-pack frames over plain SPI and the 5120-SPI transport, IRQ watch, decoded answers; ldoc11 EBUSY
  retry + stop) and 0353 (`negronifp=4`: HBM on, 2 TE frames via the new `negroni_fb_te_wait`, get-image frame, bounded
  read, `/dev/negroni-fp` 0600, `scripts/fp/raw-to-png.py`). Stage D decisions in section 4.3 (SourceAFIS Rust port /
  libAFIS / NBIS, passcode injection vs SBLockScreenManager, template storage). Build: see notes 25 (fp3 image).
- Not done: a run on the phone; the real G7 readout (the public get-image command is a guess [I]); the TA was not
  found in vendor/odm firmware (partition scan result in `out/fp/lists/ta-scan.txt`, notes 25); stage D code.
- Next: phone test `out/ios16-fp3` (owner approval: GCC/TLMM/RPMh writes); read `MCU probe result` and `irq40 changed`;
  then the fp4 capture image when step 10 answered; find the stock icon position (runtime property).

## Bluetooth status (2026-10-26)

- Done: docs/bluetooth-plan.md (facts, firmware list, iOS analysis); scripts/bt/fetch-sources.sh, fetch-firmware.sh;
  patch 0330 (`negronibt=1`: rails, QUP2 clocks, GENI UART, BT_EN sequence). Build results: notes.md section 24.
- Done (build-only): patch 0331 (HCI stage: `negronibt=2` reset/version/3 Mbaud, `negronibt=3` + rampatch/NVM from
  the BT pack in the WLAN area, reset, BD address); scripts/bt/mkbtpack.py, mkbtarea.sh, build-test-image.sh.
  Kernel local-20261026-123344 (2c5d53ca...), out/ios16-bt boot_a d01f3d6d... (after the review fix: h4_next deadline on every pass) (`negronibt=3`); out/firmware/wlan-area.bin
  now holds the BT pack (f8e96b65...). Not run on the phone.
- Next: owner approval, write the WLAN area (AREAS=1 root-simg.sh), boot out/ios16-bt; read steps 5, 7, 9-19
  (README-bluetooth.md 0331 table). Then stage B (iOS transport).
- Done (build-only, 2026-10-26, BT stage B agent): patch 0332 (`negronibt=4`: step 20 ADT BD address -> 0xfc14; kernel
  control `com.apple.uart.bluetooth` + `/dev/uart.bluetooth`, `/dev/cu.bluetooth`, `/dev/btwake`; RX thread 1/5/20 ms poll with
  RFR flow control and QCA IBS), patch 0333 (HCI shim: every host OGF 0x3f command answered in the kernel, QCA vendor
  events dropped), userland/bluetooth (`negroni-bluetool` BlueTool stand-in, `hcitest`; out/bt/userland, sha256
  c396870e... / 27ac9492...), scripts/bt/bt-launchd.py, root-add-bt.sh (`BT=1`), phone-bt.sh, `ADT_BT=1` in
  scripts/ios16/adt-extra.py (config `[adt.bluetooth]`). The stock cache has no bluetoothd job: `BT=1` / `phone-bt.sh on`
  add it from LaunchDaemons/com.apple.bluetoothd.plist (the DROP entry in root-tweaks-extra.py removes nothing). Review
  fixes: 0332 makes rx_drain stop at a full ring (RFR holds the controller), h4_close wakes readers. Kernel local-20261026-174538 sha256 cfd8af00... (after the review fixes; first build local-20261026-132747 a94e8f3c...) (0330-0333
  applied, only the 4 usual dxb skips; compile-one clean for the 4 BT files). No boot image (owner rule).
  Boot-args for the combined image: `negronibt=4 negronipanic=30 negronipanicreason=2`; the image needs `ADT_BT=1`.
- Next (BT): combined image + `BT=1` root (or `scripts/bt/phone-bt.sh on`), WLAN area with the BT pack; then
  `phone-bt.sh test` (hcitest), `phone-bt.sh log`, Settings > Bluetooth. [I] Open: bluetoothd chipset id, sandbox on the
  PF_SYSTEM socket, VSCs whose status 0x01 may be fatal.

## Display performance status (2026-10-26)

- Done: measurements (README-gpu-kernel.md section 18: presents/s mean 43.5, DCVS 350-421 MHz, CA's SwapWait busy
  173/s, Metal ctc 15.6 ms); patches 0267 (vsync notification after the frame is queued; clock shift inside the
  GPU/CPU copy, no read of the panel memory) and 0286 (GPU DCVS UI floor 640 MHz at >= 30 swaps/s); host test
  patches/xnu/tests/fb-clock-copy-test.c PASS; scripts/display/build-perf.sh -> kernel
  local-20261026-082629 (sha256 92f50f3a...), `out/ios16-perf` (boot_a 2583f0ab...), `out/ios16-perf-noshift` (boot_a 50d09e1b...).
- 0268 (panel wake = Android's full on-command 94 packets + 0x0A PPS, long DSI packets by memory DMA, auto-refresh
  paused during the set, TE check; `negronifb_wake` 2/1/0) and 0269 (panel double buffering: 3 buffers, SSPP_SRC0_ADDR +
  CTL_FLUSH after the copy's fence; `negronifb_dbuf=1`, default 0): built into `out/ios16-dpu` (config args +
  `negronifb_sleep=1 negronifb_dbuf=1 negronipanic=30 negronipanicreason=2`, scripts/display/build-dpu.sh); README-gpu-kernel.md
  sections 19/20. Not booted. Check on the phone: the `NEGRONI FB: DPU ...` probe lines, `0269 double buffering on`,
  `0269 flip N ... taken after N us`, `NEGRONI FB DBUF:` per second, and after a lock/unlock `display on (on-command 94
  packets, PPS ok, TE on ...)` with a correct picture. Fallbacks: `negronifb_wake=1`, `negronifb_wake=0`,
  `negronifb_sleep=0`, `negronifb_dbuf=0`.
- Not done: phone test; zero-copy test (0234).
- Next: owner flashes `out/ios16-perf`, scrolls, sends the FB STAT / GPU DCVS lines (goal: presents/s 100-120,
  timeouts < 100/s) and says whether the top-left strip is still; then `out/ios16-perf-noshift` for the A/B.

## GPU recovery and CPU idle status (2026-10-26, GPU-recovery agent)

- Done [V build, not booted]: 0287 GPU hang detection + recovery (KGSL gen7_gmu_reset path, `NEGRONI GPU RECOVERY:` lines,
  failed fences -> kIOReturnError / Turnip device lost, max 3 per 60 s); 0288 CPU idle via PSCI CPU_SUSPEND with the DT params
  (`negronicpuidle`, kernel default 0, broadcast wake timer frame 0); 0298 KGSL parity from docs/audit/2026-10-26-gpu.md
  (HWCG, slumber from IFPC, GMU busy counter for DCVS, CP_PROTECT/CHICKEN/ME_INIT BIT(11), rptr shadow, HFI 100 ms, guard page,
  bus votes from cmd-db + CNOC, DCVS bw = DT bus-freq). Review fixes in kernel `out/kernel/local-20261026-174403` (sha256
  dfa9a8a5..., no image: the PSCI feature bits; 0288 idles only with this kernel). Previous kernel `local-20261026-131716` (7804fca8...),
  image `out/ios16-gpur` (boot_a 526eba93..., config args + `negronigpu_recover=1 negronicpuidle=1 negronipanic=30
  negronipanicreason=2`). Details: patches/xnu/README-gpu-kernel.md sections 21 and 27, README-cpuidle.md, notes sections 17 and 22.
- Not done: ACD (needs the AOP QMP mailbox), preemption, GPU completion interrupt. Owner rule: no more images for this work.
- Next (phone): flash `out/ios16-gpur`; check step 17 `bw table` / `CNOC` lines and step 20 `KGSL settings (0298)` line, the WATCH
  `pm ifpc ... slumbers N wakes N busy N%`, `NEGRONI CPUIDLE:` lines (PSCI features, wake timer, per-core `down %`), and the
  battery current at idle against `negronicpuidle=0`. Trouble bisect: `negronigpu_protect=0`, `negronigpu_hwcg=0`,
  `negronigpu_ifpc_slumber=0`, `negronigpu_bwcalc=0`, `negronicpuidle=0`.

## Display DSI/DPU status (2026-10-26, DSI agent; build only)

- Done (code, default off): 0292 DSI command sets by batched memory DMA like Android (`negronifb_dsidma`), 0293 DCS
  reads + ESD 0x0a check + panel ID + re-init through 0268's wake (`negronifb_esd`), 0294 tearcheck vsync_count on a VRR
  mode 2 switch, 0295 TE rd_ptr interrupt (first SPI of the port, `negronifb_teirq`), 0296 clock/GDSC probe
  (`negronifb_pwrprobe`) and Android's no-transfer idle (`negronifb_idle=2`). Details: patches/xnu/README-gpu-kernel.md
  sections 22-26 (boot-arg table at the end), docs/notes.md section 15 (end), docs/display-refresh-plan.md section 8.
- [V] Build: `scripts/display/build-dsi.sh` (kernel only, owner rule), kernel `out/kernel/local-20261026-174206`
  sha256 a0b050bf05d91e0878af954bc4a4033899f5977aa734198a24df76d0efb26d3c (after the review fixes: ESD re-init cap 3, read under the set lock, 0294 counter off/on); 233 patches applied incl. 0268, 0269, 0292-0296; only the 4 usual dxb skips.
  compile-one: every intermediate state 0292..0296 compiles; 0300-0353 apply after them.
- Next (phone, one at a time): config args + `negronifb_dsidma=1 negronifb_esd=1 negronifb_pwrprobe=1` (expect `NEGRONI
  DSI: set of ... rc 0`, `NEGRONI DSI: panel ID ...`, `NEGRONI DSI ESD: power mode 0x9d ok`, `NEGRONI DPU PWR:` lines);
  then `negronifb_te=1 negronifb_teirq=1` (`negronicpuidle=1` + `negronifb_teirq=1` untested together: test apart
  first); then `negronifb_idle=2` with the battery current A/B. Then clock gating in
  idle (README section 26 table), and the 0269 flip + `idle=2` together.

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

## Mi A3 (laurel_sprout) status (2026-11-01, branch laurel-sprout)

Done: kalloc assert fix (0102); SMP CPU_ON -4 panic: shim 0002 (Silver boot core CPU_OFF) + kernel 2004
(SweetCPU soft-fail, dead cores off-line, boot goes on); USB log channel 2005 (negroni protocol: ECM,
UDP 5140 log, UDP 5141 commands, panic hold over USB; docs/laurel_sprout/usb-debug.md); host loop
`scripts/laurel/boot-test.sh`; 2006 early USB start (raw frames from STARTUP(EARLY_BOOT)); 2007 USB power-up by
the kernel (GDSC, clocks, reset, QUSB2 PHY, core) + one line per stage + `no host yet` heartbeat + ue0 attach thread;
`flash-boot.sh BOOT=continue` (ABL boots boot_b without a reset, USB left as fastboot had it).
Boots: 00:40 (2006, `fastboot reboot`): console stops after `mbinit: done`, no USB device, no `LAUREL USB:` line
visible (panel wrapped). 01:03 (2007, `fastboot continue`): no USB device on the host in 180 s; photo pending.
01:19 (2007, `fastboot reboot`, iOS root on userdata): console as usual, then two flashes, then the panel dark.
01:40 fork survey (`docs/laurel_sprout/fork-fixes.md`): the console stop after `mbinit: done` is most likely the
AppleCLCD start moving the kernel console to a shadow buffer scanned through VIG0 while the Mi A3 panel is fed by
another pipe (our shim 0001 finding); 2008 picks the pipe that fetches the boot framebuffer or keeps the console on
it; `sweetfb_stayon=1` stops backboardd's display-off; 2009 checks the UFS GDSC/clocks before the first host access
and keeps the persistent-log thread alive (evergo 0105e); `scripts/laurel/log-pull.sh` reads the 0047 ring.
Image 01:39 (cpus=8, 17481728 bytes) not booted: the phone is off.
Next: owner powers the phone on (Power+VolDown for fastboot) -> `scripts/bg.sh laurel-test scripts/laurel/boot-test.sh`
(warm path) and a film of the panel: `FB pipe=`, `LAUREL FB SCANOUT:`, `SWEET UFS: host`, the `LAUREL USB:` stage lines.
Then `BOOT=reboot` (cold path). If `FB pipe=0` the scan-out theory is wrong and the next suspect is the UFS line.
Exact results go to docs/notes.md.
