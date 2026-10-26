# Audit 2026-10-26: camera, haptics, fingerprint (patches 0300/0301, 0310/0311, 0350/0351)

Scope: the owner asked "review our changes against the original source, kernel and drivers; say what is done
and what remains". Read-only audit. No build, no phone. Marks: **[V]** = read in the named file at the named
line today; **[I]** = inference. "Nnnn.patch:L" = line L of `patches/xnu/Nnnn-*.patch`. `live.dts` =
`out/live.dts`. `hv-haptics.c` = `out/src/op-kernel/drivers/input/misc/qcom-hv-haptics.c`. `op-modules` =
`out/src/op-modules` (sparse clone; files not checked out are read with `git show HEAD:<path>`).
Nothing in these three areas has run on the phone [V docs/notes.md:376-380, 1800, 1842].

Reference sources that are **not** in the sparse checkouts and were read with `git show` today: camcc-waipio.c,
gdsc-regulator.c, pinctrl-waipio.h, pinctrl-msm.c (op-kernel), i2c-qcom-cci.c and camss.c (Linux),
cam_cci_*.c/h, cam_sensor_core.c, lx7_core.c (op-modules). `out/fp/ref/spi-geni-qcom.c` is a copy of the
Linux SPI driver [V].

## Summary

| Area | Done (code, built) | Verified against the original | Open |
|---|---|---|---|
| Camera | levels 1-2: camcc + CCI0 + IMX789 power + chip ID | register offsets, clock entries, CCI command encoding, rail values, power order: all match [V] | levels 3-5: CSIPHY/CSID/IFE raw frame, ICP PAS, SMMU, ISP pipeline, the iOS capture service |
| Haptics | 0300 direct play + 0301 "vibrator" IOService | SPMI register map and the Linux play sequence match [V]; three Linux steps left out (brake, hBoost-ready wait, CAL_EN toggle) | UI taps (CoreHaptics -> Actuator HAL device), brake, calibration |
| Fingerprint | 0350 stage A (SE probe, LDO, reset, guessed chip-ID frame, IRQ poll) + 0351 highlight disc + panel HBM | DT pins/rail, GCC bits, GENI register map match [V]; SE choice and SPI frames are guesses [I] | the Goodix "Delmar" SPI protocol (TEE-only), image capture, matcher, iOS unlock UX |

Two documentation errors found (no code effect): docs/fingerprint-plan.md names `spi@a88000` at live.dts:14795;
that line is `spi@a8c000`. `spi@a88000` is at live.dts:14757-14775 [V]. The haptics plan says the DT has
`qcom,brake-mode 1` but does not say that the DT also carries a brake pattern `[ff 3f 1f]` (live.dts:13112)
[V]; see B.2.

---

## A. Camera (patches 0310, 0311; docs/camera-plan.md; README-camera.md; notes 13)

### A.1 Function -> ours -> status

| Function | Original (Android) | Ours | Status |
|---|---|---|---|
| GCC camera clocks | `gcc_camera_ahb/xo` CLK_IS_CRITICAL, `hf/sf_axi` halt-skip, hwcg bit 1 (gcc-waipio.c:1859-1915 [V]) | `l1_gcc` 0310.patch:424-461: enable only when clear, hwcg skip of CLK_OFF | done [V]; register offsets 0x36004/10/18/20 match |
| CPAS / titan top GDSC | `cam_cpas_start` -> gdsc (DT 0xadf31dc, timeout 500 us, retain-regs live.dts:1018-1023 [V]); bits PWR_ON 31, RETAIN_FF 11, HW_CONTROL 1, SW_COLLAPSE 0 (gdsc-regulator.c:30-36 [V]) | `l1_gdsc` 0310.patch:464-499: `cam_cc_gdsc_clk` 0x1320c (camcc-waipio.c:3789 [V]), clear SW_COLLAPSE, poll PWR_ON, set RETAIN_FF | done [V]; no MMCX ARC vote, no `cam_ahb` interconnect vote (0310.patch:56-59, [I] that UEFI leaves them up) |
| camcc RCGs + branches at TCXO | 19.2 MHz TCXO entries camcc-waipio.c:955, 988, 1257, 1587, 1926; RCG offsets 0x13194, 0x1312c, 0x10018, 0x10034, 0x15000 (:962, 994, 1266, 1932, 1594); branches 0x131ac, 0x13144, 0x131f0, 0x13164, 0x1316c, 0x15018 (:2033, 2069, 2105, 2123, 2159, 2951); TCXO = source 0 (:814, 830) [V all] | `rcg_to_xo` 0310.patch:267-279, `cc_branches[]` 0310.patch:222-233, `l2_mclk` 0311.patch:331-343 | done [V]. Deviation: `rcg_to_xo` writes divider field 0; Linux writes the freq-table pre_div 1. Both mean "divide by 1" in RCG2 [I from clk-rcg2 rate math]. |
| CCI0 controller | `cam_cci_init`: IRQ masks 0x7fff7ff7 / 0x00110000, RESET_CMD RMSK 0x0f73f3f7 then 0x1, RD threshold except v1.2.9 (cam_cci_soc.c:55-57, 203-214; cam_cci_hwreg.h:9-71; cam_cci_dev.h:75 [V]) | `cci_init` 0310.patch:341-372, `cci_reset` :308-326, `cci_timing` :329-338 | done [V]; every offset and mask in 0310.patch:107-146 matches cam_cci_hwreg.h |
| CCI timing | Android: DT 37.5 MHz node values; Linux 19.2 MHz standard table thigh 78 ... tsp 1 (i2c-qcom-cci.c:253-265 [V]), sm8450 = cci_v2 (:871 [V]) | 0310.patch:140-143 same nine values | done [V]; at 19.2 MHz the bus is 100 kHz standard mode, not the Android 400 kHz/1 MHz [I: slower, not wrong] |
| Sensor rails | DT slot 0 `rgltr-min/max-voltage` 1800000 2800000 1800000 1104000 0 2800000, loads 600000 ... (live.dts:22220-22222 [V]); supplies ldoc2/ldoi3/ldoi5/ldoi1/ldoi7 (live.dts:22225-22230 [V]) | `rails[]` 0311.patch:98-105, `rail_vote` :207-233 (range check, HPM/LPM by load), whitelist `negroni_rpmh_cam_rail` 0311.patch:444-466 | done [V]; off = one VRM enable=0 command (`RH_MODE_OFF`, 0311.patch:415-420) |
| Power-up order | module file: VANA, VDIG, VIO, VAF, CUSTOM_REG1, RESET +1 ms, MCLK +1 ms; down the reverse (out/camera/modules.txt:49-50 [V]); the kernel runs `cam_sensor_core_power_up` then `camera_io_init` (cam_sensor_core.c:1760, 1769 [V]) | `cam_thread` 0311.patch:420-427 order pins -> rails -> reset -> mclk -> cci pins -> read; `cam_down` 0311.patch:238-269 | done [V] |
| Pins | reset gpio120, MCLK0 gpio100 func 1 `cam_mclk`, CCI0 gpio110/111 func 1 `cci_i2c` (pinctrl-waipio.h:1735, 1747-1748 [V]); pulls NO/DOWN/UP = 0/1/3 (pinctrl-msm.c:330-334 [V]) | `tlmm_set` 0311.patch:191-203, `l2_pins`/`l2_cci_pins` :296-304, :346-358 | done [V] |
| Chip ID read | `cam_cci_read`: SET_PARAM, LOCK, WRITE_DISABLE_P with address bytes at `<< ((addr_type - i) << 3)`, READ n, UNLOCK; first byte of the first FIFO word is the slave id, not data (cam_cci_core.c:1393-1397, 1472-1495 [V]) | `cci_read16` 0311.patch:138-188: same encoding (low byte << 16, high byte << 8), value = byte1 << 8 \| byte2 | done [V]; expected 0x0789 at 0x0016 (modules.txt:44 [V]); OnePlus kernel tests `sensor_id == 0x789` (oplus_cam_sensor_core.c:201 [V]) |
| CSIPHY (slot 0 = CSIPHY1, C-PHY 3 trios) | `cam_csiphy_2_1_0_hwreg.h` (op-modules, listed [V]); DT `qcom,csiphy-v2.1.0` x6 (live.dts:21905-22040 [V]) | none | missing |
| CSID / IFE raw capture | `cam_ife_csid680.h`, `cam_ife_csid_hw_ver2.c`, `cam_vfe680.h` (op-modules [V]); DT `qcom,csid680` / `qcom,vfe680` x3 (live.dts:23503-23628 [V]); Linux `camss-csid-680.c`, `camss-vfe-680.c` exist (git ls-tree [V]) | none | missing |
| ICP (LX7) / PAS 33 | `lx7_core.c` (op-modules, listed [V]); DT `qcom,lx7` + `camera_region@9f500000` (docs/camera-plan.md "ICP firmware") | none | missing; only IPE/BPS need it [I] |
| Request manager / sync | `cam_req_mgr`, `cam_sync` (Android userland contract) | none | missing; not needed for a kernel-internal raw capture [I] |
| SMMU for camera buffers | `msm_cam_smmu_ife` under `apps-smmu@15000000` (live.dts:15350, 22583 [V]) | none | missing; unknown whether the SMMU streams are in bypass or Gunyah-owned [I] |
| ISP pipeline (BPS/IPE), JPEG | ICP firmware + CAMX tuning (Android binaries) | none | missing; no open source for the pipeline |
| iOS capture service | `applecamerad` (IOResources property), `H10ISP.mediacapture`, `AppleH10CamIn` x13 in the shared cache (out/camera/ios-stack.txt:4, 34-50 [V]; shared cache grep today: AppleH10CamIn 13, applecamerad 5 [V]) | none; our ADT builder has no isp/camera nodes (scripts/ios16/adt-extra.py: no match [V]) | missing |

### A.2 Deviations and risks

- Rails: every voltage is a live-DT value, checked twice (0311.patch:211-215 range, :444-466 whitelist) [V]. The
  rail list matches live.dts:22220-22230 [V]. Risk is low. One real risk stays: an RPMh timeout sets `rh_poisoned`
  and every later vote is refused (negroni_rpmh.c `rh_vreg_enable`, tree copy :353-362 [V]); the power-down votes
  then fail and the five rails stay on until reboot. The code logs `WARNING: rails still voted on` (0311.patch:265)
  [V]. The README tells the owner to reboot [V README-camera.md "WARNING"].
- RPMh try-lock: `rail_vote` retries EBUSY for 1 s (0311.patch:223-229) [V]. Other agents' votes (Wi-Fi, ADSP,
  BT, fingerprint) share the lock; a longer collision fails the step and powers down [I].
- No MMCX vote: if the UEFI display vote is not enough for the titan GDSC, step 3 stops with "GDSC did not power
  on (MMCX off?)" (0310.patch:483) [V]. Safe failure.
- No interconnect vote for `cam_ahb`: the first camcc read can hang the bus if the NoC path is off (0310.patch:58-59
  [I]). This is the one failure that is not bounded by a timeout.
- `rcg_to_xo` clears the whole CFG mask including the MND mode bits (0310.patch:272) [V]; for the five RCGs used
  the TCXO entry has no M/N (camcc-waipio.c:955-1926 `F(19200000, P_BI_TCXO, 1, 0, 0)`) [V]. OK.
- CCI at 100 kHz standard mode instead of the Android 37.5 MHz / 400 kHz: slower, harmless for one read [I].
- The power-down also runs after a failure at step 1 only when all three maps exist (0310.patch:538) [V]. A failed
  TLMM map at level 2 returns before the GCC map check (0311.patch:280-288): nothing is on yet, so nothing leaks [V].
- `ml_io_map_unmappable` with VM_WIMG_IO on kernel_map (0310.patch:60) avoids the io_submap budget of notes
  section 20 [V comment; I on the mechanism].

### A.3 What remains, ordered by value

| # | Item | Size [I] | Hardest unknown |
|---|---|---|---|
| 1 | Run level 2 on the phone (image out/ios16-cam, `negronicam=2`) | 0 code, 1 boot | whether the first camcc access hangs (no NoC vote) |
| 2 | Level 3a: TPG -> CSID -> IFE RDI write to a physical buffer, no sensor (`qcom,cam-tpg103`, `cam_ife_csid680.h`, `cam_vfe680.h`) | 1500-2500 lines; CPAS top + CAMNOC register init from `cpastop_v680_*.h` | SMMU: whether `msm_cam_smmu_ife` streams (mask 0x460) are in bypass; if Gunyah owns the SMMU the IFE cannot write to memory [I] |
| 3 | Level 3b: CSIPHY1 C-PHY + IMX789 init/mode tables (`cam_sensor_settings.h:6017` per docs/camera-plan.md) + stream on | 1000-1500 lines + the register tables | C-PHY lane configuration; the mainline camss C-PHY status was not checked. A D-PHY slot (1 or 3) is the easier first stream [V plan] |
| 4 | Level 5a: a kernel service + an own app that shows the RDI frame (CPU debayer) | 1500 lines kernel + app | none hard; the owner decides whether an app-only camera is acceptable |
| 5 | Level 4: ICP PAS 33 (`qcom_mdt_load` + `qcom_scm_pas_auth_and_reset(33)`, lx7_core.c) | 500 lines (reuse 0240) | TZ may need `assign_mem` for the carve-out; the ICP HFI protocol after that is large |
| 6 | Level 5b: an `AppleH10CamIn` look-alike for CMCapture / applecamerad | months | the D22 kernelcache user-client selectors and the Apple ISP firmware semantics (not reversed; not in the root) [V plan, I size] |
| 7 | ISP pipeline (BPS/IPE), JPEG, AE/AWB | not realistic without CAMX | Android-only binaries and the signed ICP firmware |

The ISP plus the iOS capture stack (items 5-7) is the hardest part: no open source, no documentation, and the
iOS side expects an Apple ISP. Items 1-4 give a picture in an own app; that is the realistic goal.

---

## B. Haptics (patches 0300, 0301; docs/haptics-plan.md; notes 23)

### B.1 Function -> ours -> status

| Function | Original | Ours | Status |
|---|---|---|---|
| Hardware | `qcom,hv-haptics@f000` SID 3, reg 0xf000/0xf100/0xf200, vmax 1680, T_LRA 5882 us, sine, brake-mode 1 **+ brake-pattern [ff 3f 1f]**, vibrator-type 8151 (live.dts:13105-13126 [V]); no awinic/aw862x node (grep [V]); `swr_haptics@f0170220` = same block over SoundWire (live.dts:27456-27461 [V]) | 0300 drives the SPMI block only | correct choice [V] |
| Register map | EN_CTL 0x46, VMAX 0x48, DRV_WF_SEL 0x49, SPMI_PLAY 0x4c (PLAY_EN bit 7, BRAKE_EN bit 3), BRAKE_MODE 0x50, TLRA_OL 0x5c/0x5d, AUTORES 0x63 bit 7, FAULT_CLR 0x66, VSET_CFG 0x68 bit 0, CAL_EN 0x72, PTN DIRECT_PLAY 0x26, BOOST STATUS4 0x0b, HW_FOLLOW 0x41, VREG_EN 0x46 (hv-haptics.c:67-305 [V]) | 0300.patch:80-112 | all match [V] |
| Direct play | `haptics_load_constant_effect` 2134: set VMAX (1271: mV/50), set brake, DIRECT_PLAY amplitude (1349: raw u8), autores off (2194, OPLUS build); `haptics_enable_play` 1597: FAULT_CLR 0x07, open-loop config 1540, SPMI_PLAY = src \| BRAKE_EN \| PLAY_EN, then `haptics_boost_vreg_enable` 1366 (SDAM 0x42 = 1, 0xe5 = 1); stop: PLAY_EN 0, hBoost off 2 s later (6054) [V all] | `negroni_haptic_play` 0300.patch:396-452: EN_CTL, VMAX, DIRECT_PLAY, autores off, FAULT_CLR, VSET_CFG, SPMI_PLAY 0x81, SDAM; `nh_stop_locked` :359-371; `nh_hbst` :253-261 | done [V] except the three gaps in B.2 |
| hBoost via PBS | PBS_ARG 0x42 on=1 off=2, TRIG 0xe5 = 1 (hv-haptics.c:1361-1365 [V]); `haptics_wait_hboost_ready` polls up to 100 x 200 us (1436-1470 [V]) | SDAM writes yes; no ready wait | partial |
| Brake | DT `qcom,brake-mode 1` = CL_BRAKE (enum 356-361 [V]), pattern [ff 3f 1f] -> `verify_brake_samples` enables it (810-824 [V]) -> `haptics_set_brake` writes BRAKE_MODE and HAP_PTN BRAKE_AMP (1651-1680 [V]) -> BRAKE_EN in SPMI_PLAY (1622-1623 [V]) | none: SPMI_PLAY = 0x81, no BRAKE_EN, no pattern (0300.patch:98 comment, :431) | missing (documented in docs/haptics-plan.md "Known gaps") |
| Calibration (T_LRA, auto-res, CAL_EN) | `haptics_hw_init` 2872-2950: store CL brake from SDAM, read CLAMP_5V, VMAX, DRV_WF, BRAKE_MODE, CAL_EN auto, close-loop T_LRA from `haptics_get_closeloop_lra_period`, T_LRA_OL, DRV_WF_FMT [V]; `qcom,cal-data-restore` (4287 [V]) | reads CAL_EN/T_LRA/DRV_WF/BRAKE (0300.patch:306-320); writes T_LRA_OL only when 0 (:338-350); sets sine (:352) | partial; the PMIC keeps Android's values across an AP reboot [I: SPMI registers are not reset by the AP]; after a PMIC power cycle the block is uncalibrated |
| Module enable | EN_CTL bit 7 (2008-2020 [V]) | written when clear (0300.patch:413-416) | done [V] |
| Owner / safety | n/a (Linux owns the APIDs) | APID owner table check, writes refused unless EE 0 owns HAP_CFG/PTN/BOOST (0300.patch:286-333); 16-line cap on refused-write logs (:224-230) | done [V] |
| iOS: which process asks, with what API | `_CMSessionMgrVibrateForSystemSoundWithOptions` (MediaExperience) -> `_FigVibratorInitialize` -> `VibeSynthEngineHasHardwareSupport` false -> `IOServiceNameMatching("vibrator")` + `IORegistryEntrySetCFProperties` {hertz_millisecs, repeat} / CFNumber 0 (docs/haptics-plan.md section 4 with unslid addresses) | shared-cache strings re-counted today: `hertz_millisecs` 1, `Using Legacy Vibe Engine` 1, `VibeSynthEngineHasHardwareSupport` 3, `ProductSupportsClosedLoopHaptics` 8, `VirtualAudioDevice_Actuator` 3 [V grep over out/dsc/cache]; the addresses and control flow are the haptics agent's disassembly [not re-checked today] | the process is mediaserverd (MediaExperience runs there) [I]; the API is IOKit properties [V strings] |
| 0301 IOService | FVIOKit: `hertz_millisecs` = ( {intensity 16.16} \| bool, ms, ... ), `repeat`; stop = CFNumber 0 | `NegroniVibrator` on IOResources (0301.patch:220-226), `setName("vibrator")` (:95), parser (:125-186), timer steps (:187-205), on step plays ms + 20 (:202) | done [V code]; the parser's pair layout (state, ms) is from the agent's disassembly [not re-checked] |
| UI taps (UIFeedbackGenerator, CoreHaptics, keyboard) | `sHapticsSupported` from the closed-loop MobileGestalt key; audio HAL device `VirtualAudioDevice_Actuator` (CS42L75 codec stream on D22) | nothing; our ADT has no `/product/haptics` node (scripts/ios16/adt-extra.py: no "haptics" [V]) | missing; stays silent [I] |

### B.2 Deviations and risks

- **LRA drive without brake.** Android uses closed-loop brake with the DT pattern [ff 3f 1f] (live.dts:13111-13112
  [V]); ours stops with PLAY_EN = 0 and lets the LRA ring down. Effect: a soft tail of a few T_LRA periods
  (5.9 ms each) [I]. Not a hardware risk. Fix size: ~30 lines (BRAKE_MODE 0x50 = mode 1, HAP_PTN BRAKE_AMP
  samples, BRAKE_EN in SPMI_PLAY) [V hv-haptics.c:1651-1680 for the sequence].
- **No hBoost-ready wait.** Linux waits up to 20 ms for the boost before PLAY_EN (hv-haptics.c:1436-1470 [V]).
  Ours writes PLAY_EN first and then triggers the PBS (0300.patch:431-434) [V]. Linux does the same order
  (SPMI_PLAY then `haptics_boost_vreg_enable`, 1625-1640 [V]); the wait is at the playback entry, before
  `haptics_enable_play` [I: not read]. Effect: the first milliseconds can run below VMAX. Low risk.
- **CAL_EN toggle.** Linux toggles the RC clock calibration when FORCE_VREG_RDY is set (1555-1575 [V]); ours sets
  FORCE_VREG_RDY on a play within 2 s of the last one without the toggle (0300.patch:425-426) [V]. Low risk.
- **VMAX cap.** `negronihap_mv` is capped at 3600 (0300.patch:122, below the factory AT 3700, hv-haptics.c:122 [V]).
  Linux clamps at 5000 when CLAMP_5V is set (1282-1283 [V]). OK.
- **APID writes through own channel windows** (0300.patch:214-245): the arbiter refuses writes from a non-owner
  (status error bits); the code stops after a timeout and marks the APID dead [V]. OK.
- **0301 runs on `negronihap >= 1`** so the boot buzz (mode 1) and the service come together; mode 2 gives the
  service without the buzz [V 0301.patch:75-82, 0300 header].

### B.3 What remains, ordered by value

| # | Item | Size [I] | Hardest unknown |
|---|---|---|---|
| 1 | Boot out/ios16-hap: `NEGRONI HAPTIC: ready`, the buzz, then a ringtone vibration preview (`NEGRONI VIBRATOR: start`) | 0 code | whether mediaserverd takes the legacy IOKit path on our ADT (MobileGestalt per-product default not proven, docs/haptics-plan.md 4) |
| 2 | Brake pattern + BRAKE_EN | 30 lines | none |
| 3 | UI taps: a `VirtualAudioDevice_Actuator` audio HAL device whose PCM stream drives the haptics (envelope -> DIRECT_PLAY amplitude, or the block's FIFO mode), then `/product/haptics closed-loop = 1` in the ADT | weeks: an audio HAL plug-in or a kernel audio device that AudioToolbox accepts | **the iOS actuator integration**: which kernel class / HAL plug-in CoreAudio expects for the actuator device (the D22 has the CS42L75 codec driver, Apple kext, not available); the haptic PCM format and timing of CoreHaptics |
| 4 | hBoost-ready wait + CAL_EN toggle | 20 lines | none |
| 5 | Rich effects (SoundWire path, LPASS) | large | needs the audio stage first |

---

## C. Fingerprint (patches 0350, 0351; docs/fingerprint-plan.md; README-fingerprint.md; notes 25)

### C.1 Function -> ours -> status

| Function | Original | Ours | Status |
|---|---|---|---|
| Power | `goodix_fp` ldo-supply pm8350c_l11 (phandle 0x347), `ldo-config <3000000 3000000 150000>` (live.dts:36715-36716 [V]); regulator 2.4-3.008 V (live.dts:11250-11257 [V]) | `negroni_rpmh_vreg_enable("ldoc11", 3000)` (0350.patch:666) via the existing whitelist 2950-3400 mV HPM (negroni_rpmh.c tree copy :380-386 [V]); off vote `negroni_rpmh_vreg_disable` (0350.patch:776-783) | done [V]. Deviation: the off vote is **one** VRM enable=0 command; when the enable vote returns EBUSY the code continues unpowered and logs "continuing" (0350.patch:668) [V] |
| Reset, IRQ, ID pins | IRQ TLMM 40 pull-down input, reset TLMM 41, id TLMM 42 pull-up (live.dts:36714-36718, 36698 [V]) | step 5 (0350.patch:654-662), reset pulse 5 ms low (:674-694) | done [V]; the reset timing (5 ms) is a guess [I] |
| SPI serial engine | no SPI node for the sensor; every `qcom,spi-geni` node is `status = "disabled"` (20 nodes, live.dts:14099-15235 [V]); `spi@a88000` = QUP1 SE2, clocks GCC 108/136/137, pins phandle 0xf8 = `qupv3_se10_spi` TLMM 36-39 "qup10" (live.dts:14757-14775, 2314-2322 [V]) | SE 0xa88000, wrapper 0xac0000, pins 36-39 func 1 (0350.patch:85-98, 516-531) | SE choice is [I strong]; qup10 = function 1 (pinctrl-sm8450.c:1449-1452: `PINGROUP(36..39, qup10, ...)`, first function slot [V]) |
| GCC clocks | APCS vote 0x62008 bits 24/20/21/19/18, halt 0x28274/0x28004/0x28008/0x33140/0x3314c, RCG 0x2827c, parent map 0, 19.2 MHz = XO div 1 (gcc-waipio.c:2807-2873, 3141-3162, 776-789, 1101-1105 [V]) | 0350.patch:105-124, `gcc_branch_on` :275-287, `gcc_s2_rcg_xo` :289-303 (CFG = 0x1: src 0, div field 1), `gcc_restore` :305-315 (only the bits we added) | done [V] |
| GENI SE probe + FIFO mode | geni-se.h: FW_REVISION_RO 0x68, IF_DISABLE_RO 0x64, HW_PARAM_0 0xe24, M_CMD0 0x600, opcode shift 27, RX_LAST_BYTE_VALID bits 30:28 (geni-se.h:85-277 [V]); spi-geni-qcom.c: SE_SPI_* 0x224-0x278, TX_ONLY 1, RX_ONLY 2, CS_ASSERT 8, CS_DEASSERT 9, FRAGMENTATION BIT(2), WORD_LEN = bpw - 4, `geni_se_init(tx_fifo_depth - 3, - 2)` (:20-65, 286-289, 577 [V]); packing vectors (qcom-geni-se.c:539-592 [V]) | 0350.patch:126-203 defines, `se_init_fifo` :333-351, `se_packing_8bit` :353-374, `se_spi_setup` :376-399, `se_tx/se_rx` :430-492 | done [V]; stops when protocol != SPI or FIFO disabled (:619-648) |
| Chip ID | TEE-owned. HAL strings: `GF_CHIP_DELMAR_T_SE1`, `GF_CMD_DELMAR_SENSOR_READ_IMAGE`, `"chip_id":` (strings of out/fp/odm/libgf_hal_G7.so [V today]); no SPI frame format anywhere in our sources [V: no goodix driver in op-kernel/op-modules/linux] | frame `F1 00 00` + 8 bytes, then `00` + 8, then F1 again (0350.patch:696-717) | **protocol unknown**; the F1 frame is the public capacitive gf_spi.c convention [I]. The "Delmar" family is optical and TA-driven; a non-constant answer is the only proof |
| HBM / highlight sync with TE | `oplus_ofp_hbm_handle` 1145 -> `oplus_ofp_set_panel_hbm` 1064 -> `DSI_CMD_HBM_ON` 1120; `panel_hbm_status_update` 1258 counts `oplus_ofp_hbm_on_period` (= 2, live.dts:33146) read-pointer IRQs (1310); `pressed_icon_status_update` 1339; `send_uiready_event` 1417 -> `DRM_PANEL_EVENT_ONSCREENFINGERPRINT_UI_READY` 1433 (oplus_onscreenfingerprint.c [V]); fp_type 0x88 = optical new solution, no local HBM (live.dts:32994; .h:73-82 [V]) | 0351: disc after every panel copy (`negroni_fp_draw_highlight` 0351.patch:137-178), HBM-on set once 50 ms after the first disc (:173), bytes = live.dts:33140 verbatim (0351.patch:42-53 vs live.dts:33140 [V byte compare]); HBM-off set = live.dts:33139 (:55-65 [V]) | partial: no TE/ui-ready count, no HBM off at sleep, no dim layer; position 540,2080 r 95 is a placeholder [I]; the stock position is a runtime property (`persist.vendor.fingerprint.optical.sensorlocation`, out/fp/lists/hal-strings.txt [V]) |
| Image capture protocol | TA (`GF_CMD_DELMAR_SENSOR_READ_IMAGE`) over secure SPI; raw data dump helpers in the HAL (`dumpRawDataToBmp` etc. [V strings]) | none | missing; unknown (TEE) |
| Template matching | TA (`GF_CMD_ALGO_*`, `detect_fake`, `moire`, calibration [V strings]) | none; design = open matcher (SourceAFIS / NBIS) in docs/fingerprint-plan.md 4.2 | missing |
| Enrol / verify UX on iOS | Touch ID / Face ID through the SEP (`com.apple.biometrickitd` 22, `AppleBiometricSensor` 1 in the shared cache [V grep today]); our kernel has no SEP kexts | design only: own daemon + passcode injection or an `SBLockScreenManager` hook (plan 4.2) | missing |

### C.2 Deviations and risks

- **XPU fault.** The first read of 0xa88000 / 0xac0004 can fault when TZ owns the SE (0350.patch:619 says so) [I].
  With `negronipanic=30` the phone reboots after 30 s [V boot-args of out/ios16-fp]. The GCC votes before it are
  HLOS-owned bits [V gcc-waipio.c enable_reg 0x62008].
- **FIFO disabled.** QUP0 SE4 (touch) has its FIFO disabled (negroni_touch.c:1-4 [V]); the same can hold for QUP1 SE2.
  The code stops cleanly (0350.patch:640-648) [V].
- **Rail stays on after a lock collision.** `negroni_rpmh_vreg_enable` returns EBUSY at once (no retry, unlike the
  camera `rail_vote`); then `fp.ldo_voted` is false, the sensor runs unpowered, and the chip-ID bytes are
  meaningless (0350.patch:666-668) [V]. In the "everything" image the camera thread starts at boot and the
  fingerprint thread 15 s later (0350.patch:583-585), so a direct collision is unlikely; BT/ADSP/Wi-Fi votes can
  still collide [I].
- **HBM stuck.** `negronifp_hl=1` sets DCS 0x53 = 0xE0 and DBV 0x0EFF and never sends the off set (0351.patch:95-114
  has it; nothing calls it) [V]. The iOS brightness writes change 0x51 but leave 0x53 = 0xE0: the panel stays in HBM
  mode at a normal DBV after the next brightness change [I from README-fingerprint.md "0x53 = 0xE0"]. The queued test
  uses `negronifp_hl=2` (disc only) [V out/ios16-everything cmdline], so this risk is not in the queue.
- **Every GPU frame waits on its copy fence** with `negronifp_hl > 0` (0351.patch:188, 199) [V]: the same cost as
  `negronibadge=1`; frame latency goes up on the GPU path [I].
- **Zero-copy frames carry no disc** (0351.patch header) [V]: on a zero-copy frame the sensor sees the normal UI.
- `negronifp_keep=1` leaves the SE clocks and the LDO on (0350.patch:738-742) [V]; default off.
- io_submap: 6 maps of 16 KiB = 96 KiB (0350.patch:589-595 comment) [V]; inside the 0290 budget [I].

### C.3 What remains, ordered by value

| # | Item | Size [I] | Hardest unknown |
|---|---|---|---|
| 1 | Run stage A (`negronifp=2`): does the SE answer, does IRQ 40 react to a touch, does MISO move | 0 code | XPU ownership of QUP1 SE2 |
| 2 | If SE2 is not SPI or FIFO-less: GPIO bit-bang SPI on TLMM 36-39 (like the touch I2C) | 300 lines | none |
| 3 | **The Goodix Delmar SPI protocol**: register map, chip-ID command, frame read command, image size/format | unknown; sources: HAL + TA disassembly (TA not found in vendor/odm/modem images [V plan 1.2]), or a bus capture on a second device | the TA is signed for QSEE and not in our images; without it the protocol must come from reverse engineering or a logic analyser |
| 4 | Stage C: capture into a kernel buffer + dump over the USB command server; ui-ready = disc drawn + 2 TEs | 800 lines | depends on 3 |
| 5 | Stage D: daemon + open matcher + enrol app + unlock path (passcode injection or lock-screen hook) | 3000-5000 lines | image preprocessing (moire/background subtraction the TA does); false-accept rate without liveness; the stored passcode (owner decision) |
| 6 | HBM off at sleep, dim layer, correct sensor position (from the stock Settings/HWC on Android) | 200 lines | the stock position value (runtime property, not in the images) |

---

## D. Risks for the queued tests

Queued (out/ios16-everything cmdline [V]): `negronihap=1 negronicam=2 negronifp=2 negronifp_hl=2 negronipanic=30
negronipanicreason=2` (plus negroniwlan=6, negroniadsp=1, bt, te, vrr per notes). Single images: out/ios16-cam
(`negronicam=2`), out/ios16-fp (`negronifp=2 negronifp_hl=1`), out/ios16-hap (`negronihap=1`) [V cmdline.txt files].

1. **Bus hang on the first camcc access** (camera step 3/4, no NoC vote): not bounded by a timeout; the thread or
   the phone hangs with no further `NEGRONI CAM` line [I]. `negronipanic=30` does not help against a silent hang.
   Mitigation: test out/ios16-cam alone first; a hang there is diagnostic.
2. **XPU fault on QUP1 SE2** (fingerprint step 3): SError -> panic -> reboot after 30 s [I]. Clean failure.
3. **RPMh poison**: one timed-out vote (camera 5 rails, fingerprint ldoc11, Wi-Fi/ADSP/BT votes) refuses every
   later vote for the boot: camera rails and ldoc11 stay on until reboot [V negroni_rpmh.c rh_poisoned, 0311.patch:265
   warning]. Reboot after a `WARNING: rails still voted on` or `refusing further access` line.
4. **RPMh lock collisions** in the "everything" image: the fingerprint enable vote has no retry (C.2); the camera
   retries 1 s. The fingerprint result is then false-negative. Prefer the single images for the first result.
5. **Haptics writes refused**: if another EE owns the HAP APIDs the code does nothing (0300.patch:322-326) [V];
   `negronihap_force=1` is the override and is not in the queue [V cmdlines]. Safe.
6. **A buzz at boot** (negronihap=1) with VMAX 1680 mV, 300 ms, no brake: harmless [I].
7. **Highlight disc at hl=2**: a white 190 px disc at 540,2080 on every copied frame; no HBM. Cosmetic only; the
   fence wait adds latency on GPU frames [I].
8. **Camera rails**: only slot-0 rails at DT voltages; power-down after every path [V]. The one unbounded case is
   item 3.
9. **io_submap**: haptics 64 KiB + fingerprint 96 KiB + the other agents' maps; the 0290 budget was sized for this
   [I: not re-added today].
10. **Patch order**: 0350 needs 0310 (bsd/conf/files context), 0311 (RH_MODE_OFF) and 0330 (negroni_ufs.c context)
    (0350.patch:1-5) [V]; the 084051 kernel has all of them (notes 25) [V notes].

## E. Facts the agents stated that this audit did not re-verify

- The unslid shared-cache addresses and the control flow of FigVibrator / VibeSynthEngine (docs/haptics-plan.md 4):
  only the strings were re-counted today.
- The `hertz_millisecs` array layout (state, ms pairs): from the haptics agent's disassembly.
- `cam_csiphy` C-PHY tables and `cam_sensor_settings.h:6017`: file names seen in the op-modules index only.
- The QUP1 SE2 choice for the fingerprint SPI: the elimination argument in docs/fingerprint-plan.md 1.1 [I strong];
  no node in the DT names it.
