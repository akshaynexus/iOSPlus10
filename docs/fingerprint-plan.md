# Under-display fingerprint sensor (Goodix optical G7) on the OnePlus 10 Pro: facts, plan, iOS design

Status 2026-10-26 (evening): stages A/B (0350/0351) and stage C probes (0352 MCU frames, 0353 capture) written and
built; section 7 has the protocol facts from the public HAL source and the public Goodix MCU protocol.
Not run on the phone (battery flat). [V] = verified in a file (file:line given), [I] = inference.

## 1. Hardware facts

### 1.1 The sensor and its kernel-visible pins (live device tree, `out/live.dts`)

| Item | Value | Where [V] |
|---|---|---|
| Sensor node | `goodix_fp`, `compatible = "goodix,goodix_fp"`, `status = "ok"` | live.dts:36711-36713 |
| Chip | `oplus_fp_common` child `goodix_optical_G7`, `chip-name = "G_OPTICAL_G7"`, `vendor-chip = <0x0b>`, `oplus,fp-id = <0x01>` | live.dts:36695-36708 |
| ID pin | `oplus,fp_gpio_0 = <TLMM 42>`; pinctrl `gpio_id2_default`: input, pull-up, 2 mA | live.dts:36698, 5544-5560 |
| IRQ pin | `goodix,gpio_irq = <TLMM 40 1>`, `interrupts = <40 0>`; pinctrl `gpio_goodix_irq_default`: input, pull-down, 2 mA | live.dts:36714-36717, 5563-5578 |
| Reset pin | `goodix,gpio_reset = <TLMM 41 0>` | live.dts:36718 |
| Power | `ldo-supply = <0x347>` = `pm8350c_l11` (RPMh `ldoc11`), `ldo-config = <3000000 3000000 150000>` = 3.0 V, 150 mA load; `power-num = 1`, one `power_source_1 { power-mode 1, power-name "ldo", delay-time 0 }` | live.dts:36715-36716, 36723-36729; regulator 11248-11257 (range 2.4-3.008 V, init 2.5 V) |
| Panels it is tied to | `panel = <0x70d 0x70f 0x70e 0x70c>` (the four `oplus21631_samsung_1440_3216_dsc_cmd` S6E3HC3 panel nodes) | live.dts:36722, 32974, 33795, 34627, 35552 |
| Touch panel flags | `fingerprint_underscreen_support`, `screenoff_fingerprint_info_support` in the Synaptics touch node | live.dts:14405, 14408 |
| Panel fp type | `oplus,ofp-fp-type = <0x88>` = bit 3 "optical fingerprint new solution (dim layer and pressed icon not controlled by kernel)" + bit 7 "ultra low power AOD"; bit 4 (local HBM) is clear | live.dts:32994; `out/src/op-modules/.../display-drivers/oplus/oplus_onscreenfingerprint.h:73-82`, `.c:33-40` |

**There is no SPI bus node for the sensor** [V]: `goodix_fp` is a platform device without
`spi-max-frequency` or a parent `spi@`, and every `qcom,spi-geni` node in the HLOS tree is
`status = "disabled"` (live.dts 14115, 14193, ..., 15289: the SPI function of each SE is off,
only I2C/UART children are "ok"). On Android the sensor's SPI is driven by the TEE
(QSEE "secure SPI"); the HLOS kernel driver only does power, reset, IRQ and a netlink to the HAL.

Which serial engine [I, strong]: the SPI pins next to the fingerprint GPIOs are TLMM 36-39 =
`qupv3_se10_spi` (live.dts:2314-2322: function "qup10", 6 mA, bias-disable; sleep state =
gpio inputs 2332). No HLOS node references these pins (grep of `pins = "gpio3[6-9]"`: only the
qupv3_se10 pinctrl entries). SE10 = QUP1 SE2 = `spi@a88000` (live.dts:14795-14811,
`clocks = <GCC 108 GCC 136 GCC 137>`; `out/src/op-kernel/include/dt-bindings/clock/qcom,gcc-waipio.h:120,148,149`
= `GCC_QUPV3_WRAP1_S2_CLK`, `WRAP_1_M_AHB`, `WRAP_1_S_AHB`), wrapper `qcom,qupv3_1_geni_se@ac0000`
(live.dts, phandle 0xef). The function number of "qup10" on GPIO 36-39 is 1
(mainline `drivers/pinctrl/qcom/pinctrl-sm8450.c:1460-1463`, copy in `out/fp/ref/`).

GCC registers for that SE [V `out/src/op-kernel/drivers/clk/qcom/gcc-waipio.c`]:
`gcc_qupv3_wrap1_s2_clk` vote APCS 0x62008 bit 24, halt 0x28274 (2869-2873); `wrap_1_m_ahb`
bit 20 halt 0x28004 (3141-3147); `wrap_1_s_ahb` bit 21 halt 0x28008 (3156-3162); `wrap1_core`
bit 19 halt 0x33140 (2820-2824); `wrap1_core_2x` bit 18 halt 0x3314c (2807-2811); RCG
`gcc_qupv3_wrap1_s2_clk_src` cmd_rcgr 0x2827c, parent map 0 (XO = src 0), freq table
`ftbl_gcc_qupv3_wrap0_s0_clk_src` (1101-1105, 776-789: 19.2 MHz = XO, div 1).
Correction (audit 2026-10-26): `spi@a88000` is at live.dts:14757-14775 (14795 is `spi@a8c000`).

### 1.2 The OnePlus kernel driver

The OnePlus kernel source drop (`out/src/op-kernel`, `out/src/op-modules`) **does not contain the
fingerprint driver** [V: `find ... -iname '*fingerprint*' -o -iname '*goodix*' -o -iname '*fp_common*'`
finds only `display-drivers/oplus/oplus_onscreenfingerprint.[ch]`]. The Lineage tree
(`out/src/lineage-kernel`) has none either. What the vendor images show about it [V]:

- `/odm/etc/init/vendor.oplus.hardware.biometrics.fingerprint@2.1-service.rc`: `chown system
  system /dev/goodix_fp`, `/sys/kernel/oplus_display/hbm`, `/sys/kernel/oplus_display/notify_fppress`
  (extracted copy of the HAL in `out/fp/odm/`, git-ignored).
- `libgf_hal_G7.so` strings: `/dev/goodix_fp`, `GF_IOC_INIT/EXIT/RESET/ENABLE_IRQ/DISABLE_IRQ/
  ENABLE_POWER/DISABLE_POWER/HOLD_WAKE_LOCK/CLEAN_TOUCH_FLAG`, netlink messages
  `GF_NETLINK_TP_TOUCH_DOWN/UP`, `GF_NETLINK_UI_READY/UI_DISAPPEAR`; QSEE: `libQSEEComAPI.so`,
  "Load ta: %s from path[%s]", search paths `/vendor/firmware`, `/vendor/firmware_mnt/image`,
  `/odm/vendor/firmware`, ...; `GF_ERROR_SPI_*`, `GF_ERROR_CHIP_ID_NOT_CORRECT`.

So the kernel part is a thin shim: power (the LDO), reset GPIO, IRQ -> netlink, ioctls. **The
capture, the SPI protocol, the image processing and the matching run in a trusted application
(TA) under QSEE** on Android. For us this means: no Linux source gives the sensor's SPI register
map or chip ID command; a userland matcher must be written or ported (stage D); and the TA
cannot be reused (it needs QSEE and its keys). Linux mainline has no Goodix optical driver
(only the Goodix touch controllers under `drivers/input/touchscreen/goodix*`) [V: no
`goodix` under `drivers/input/misc`/`drivers/spi` in `out/src/linux`].

The TA file was not found in `vendor.img` `/firmware` (137 files, none fingerprint-related),
`odm.img` `/firmware` (cs_press.bin, fastchg, tfa98xx.cnt, tp, ufs) or the `modem` partition's
FAT names (8.3 scan found `CMNLIB` but nothing Goodix) [V]. It is probably loaded from
`/vendor/firmware_mnt/image` with a short name or from the `tz`/`oplus_sec` partitions [I].
Not needed for stages A-D.

### 1.3 The display part (why the sensor needs the panel)

An optical under-display sensor photographs the finger lit by the OLED above it. The stock
flow (`out/src/op-modules/vendor/qcom/opensource/display-drivers/oplus/oplus_onscreenfingerprint.c`) [V]:

- The HWC sets the connector property `HBM_ENABLE` with bits `DIM_LAYER`, `FINGERPRESS_LAYER`,
  `ICON_LAYER` (`.h:31-34`). With `FINGERPRESS_LAYER` set and a non-zero backlight,
  `oplus_ofp_hbm_handle` (c:1150-1222) calls `oplus_ofp_set_panel_hbm(c_conn, true)`, which sends
  `DSI_CMD_HBM_ON` (c:1118-1123).
- `fp_type 0x88` means **no local HBM**: the whole panel goes to HBM and the HWC draws a dim layer
  everywhere except the "pressed icon" (a bright disc at the sensor). The DCS set for the
  1080x2412 @ 120 Hz timing (live.dts:33140, `timing@fhd_sdc_120` 33068-33103) is:
  `F0 5A 5A` / `F0 A5 A5` (wait 8 ms) / `53 E0` (HBM mode) / `51 0E FF` (DBV 0xEFF, wait 8 ms) /
  `F0 5A 5A` / `B0 00 01 BD` / `BD 02` / `B0 02 B9 65` / `65 00 AC 00 AC 00 AC` / `F7 0F` / `F0 A5 A5`;
  off (33139): `53 28` / `51 06 9F` / ... `65 01 5E 01 5E 01 5E` / `F7 0F` / `F0 A5 A5`.
  Command state `dsi_hs_mode` (33121-33124). The 90/60 Hz timings differ only in the wait bytes
  (0x0b, 0x0a).
- Frame sync: the HAL must not capture before the icon frame and HBM are on the panel. The
  driver counts TE/read-pointer interrupts: `oplus,ofp-hbm-on-period = <2>` (live.dts:33146) and
  `oplus_ofp_panel_hbm_status_update` (c:1263-1335) sets `panel_hbm_status` after that many TEs;
  `oplus_ofp_pressed_icon_status_update` (c:1339-1410) walks WR_PTR -> PP_DONE -> ON for the icon
  layer; then `oplus_ofp_send_uiready_event` (c:1417-1441) raises
  `DRM_PANEL_EVENT_ONSCREENFINGERPRINT_UI_READY`, which the fingerprint shim forwards as netlink
  `GF_NETLINK_UI_READY`; the HAL's `Sensor::waitSensorUIReady` then starts the capture (HAL strings
  `ui_ready_time:%dms`, `uiready_timeout`).
- The icon position and size are **not in the device tree** [V: no `fp_area`/`sensor_loc`
  property; grep of live.dts]. The HAL reads the runtime properties
  `persist.vendor.fingerprint.optical.sensorlocation`, `.iconsize`, `.authicon`, `.enrollicon`
  (libgf_hal_G7.so strings) that the OPLUS framework sets; no build.prop in vendor, odm or
  my_product carries them [V grep]. So the centre/radius for stage B are boot-args with
  placeholder defaults (section 3, stage B).

### 1.4 What we already have in the kernel

- TLMM MMIO helpers (`bsd/dev/negroni_touch/tlmm.h`, slop 0093), RPMh LDO vote
  `negroni_rpmh_vreg_enable("ldoc11", mV)` (slop 0062 `bsd/dev/negroni_rpmh.c:374-380`: exactly
  this rail, 2950-3400 mV, high-power mode); an off vote exists as `RH_MODE_OFF` (0311, `negroni_rpmh.c:53`),
  0350 wraps it as `negroni_rpmh_vreg_disable`.
- DSI DCS writes `negroni_dsi_dcs_write(buf, len, lp)` (patch 0250, NegroniBacklight.cpp:158) and
  the panel-memory copy path with a per-frame CPU hook (`negroni_draw_badge`,
  NegroniFramebuffer.cpp, present()).
- No GENI driver: the touch uses GPIO bit-bang I2C because "QUP0 SE4 has its FIFO disabled
  (GPI only, DMA block secure-locked)" (negroni_touch.c:1-6). The same can be true for QUP1 SE2:
  stage A checks `GENI_IF_DISABLE_RO` and the firmware protocol before any transfer.

## 2. What is realistic (summary)

| Stage | What | Proof | State |
|---|---|---|---|
| A | kernel: SE clocks, SE probe, LDO, reset, chip-ID frames over SPI, IRQ pin poll | `NEGRONI FP: step N ...` lines, raw RX bytes, IRQ rise after reset, IRQ changes on touch | patch 0350, built, not run |
| B | kernel: highlight disc in the panel memory after each copy + panel HBM DCS set | a white disc on screen at the sensor; `NEGRONI FP HL: panel HBM on: ok (11 packets)` | patch 0351, built, not run |
| C | kernel: 0352 MCU message frames (`negronifp=3`), 0353 one capture + `/dev/negroni-fp` (`negronifp=4`) | `VALID message pack` / `VARIED DATA` lines; a PNG from `scripts/fp/raw-to-png.py` | patches written and built, not run; the readout command is a public-protocol guess (section 7) |
| D | userland: matcher + iOS lock-screen integration | unlock with a finger | design (section 4.3) |

Stage C depends on the SPI protocol, which only the TA knows (section 7 has everything the
public files give: the TA command ids, the frame size, the public MCU framing). Stage A sends
the capacitive `F1` frame; stage C sends the public MCU frames; a bus capture on a second device
or the TA's disassembly would give the rest.

## 3. Stage A and B design (what the patches do)

### Stage A, patch 0350 (`bsd/dev/negroni_fp.c`, `negronifp=1|2`, default 0)

Thread started from `negroni_ufs_init` (after `negroni_bt_init`), sleeps `negronifp_delay`
s (default 15, after the USB console), then:

1. `map`: QUP1 wrapper 0xac0000 (0x2000), SE 0xa88000 (0x4000), GCC pages 0x160000, 0x128000,
   0x130000 (16 KiB each), TLMM 36-43 (0xf124000, 0x8000). 6 `ml_io_map` calls = 96 KiB of
   io_submap (0290 budget).
2. `GCC`: record APCS vote 0x62008; vote M_AHB, S_AHB, core_2x, core; RCG 0x2827c CFG = XO div 1
   + UPDATE/ROOT_EN; vote S2; each branch waits for CBCR bit 31 (CLK_OFF) clear, 1 ms.
3. `SE probe`: the first reads of 0xac0004 / 0xa88000 (a fault here means the XPU/TEE owns the SE): QUP HW version (0xac0004), `GENI_FW_REVISION_RO` protocol (must be 1 = SPI),
   `GENI_IF_DISABLE_RO` bit 0 (FIFO disabled -> stop), `HW_PARAM_0` FIFO depth/width.
   **Stop here** with a reason line if the SE is not SPI or FIFO-less (expected possibilities:
   the qupfw/TZ config decides).
4. `SE init`: `geni_se_init` + FIFO mode as `qcom-geni-se.c:241-284`; 8-bit packing (4 bytes per
   FIFO word, MSB first, `geni_se_config_packing`), `SE_SPI_WORD_LEN = 4`, loopback 0, demux 0,
   CPOL/CPHA from `negronifp_mode`, CS not toggled by hardware, `GENI_SER_M_CLK_CFG = div<<4 | 1`
   with div = ceil(19.2 MHz / `negronifp_hz`) (default 4.8 MHz).
5. `pins`: reset 41 output low, IRQ 40 input pull-down, ID 42 input pull-up, 36-39 to function 1
   (qup10) 6 mA. Logs the ID pin (expected 1 = G7 per `oplus,fp-id`).
6. `power`: `negroni_rpmh_vreg_enable("ldoc11", 3000)` (DT 3.0 V); `negronifp_ldo=0` skips it.
7. `reset`: 41 low 5 ms, high, then watches the IRQ pin for 20 ms (Goodix chips raise IRQ after a
   reset: "the chip answers the reset" line) [I].
8. `chip ID`: `CS assert` / TX `F1 00 00` / RX 8 bytes / `CS deassert` (Goodix register-read frame
   [I]), then a 1-byte `00` + 8 bytes, then the F1 frame again. Raw bytes are logged; all-00 or
   all-FF = no answer. Expected chip ID value: **unknown** [I]; the HAL only has
   `GF_ERROR_CHIP_ID_NOT_CORRECT`. A non-constant answer is the proof.
9. `IRQ poll` (`negronifp=2`): every 5 ms for `negronifp_poll` s (default 60), logs level changes.

Every sequencer command is bounded (20 ms poll, then cancel 10 ms, abort 10 ms). The failure
path `power_down()` runs in reverse: reset low, SPI pins back to GPIO inputs (the DT sleep
state), our GCC votes removed (only the bits we added), and the LDO off through the new
`negroni_rpmh_vreg_disable("ldoc11")` (one VRM command, enable = 0, `RH_MODE_OFF` as 0311's camera
power-down) when the vote was ours. `negroni_rpmh_vreg_enable` has no disable path, so 0350 adds one in
`negroni_rpmh.c`. `negronifp_keep=1` leaves everything on.

### Stage B, patch 0351 (NegroniFramebuffer.cpp, `negronifp_hl=1|2`, default 0)

- After every copy into the panel memory (the `negroni_draw_badge` point in `present()`), a
  filled white disc is drawn at (`negronifp_hl_x`, `negronifp_hl_y`) radius `negronifp_hl_r`
  (panel pixels; defaults 540, 2080, 95 [I placeholders]). GPU copies: the fence wait that the
  badges use is extended to this overlay, so the disc is drawn after the engine's copy.
  Zero-copy frames (0234, the engine scans CA's surface) are not touched.
- With `negronifp_hl` > 0 every GPU frame waits on its copy fence in `presentFinish` (as the badges do),
  so the disc is drawn on every frame.
- `negronifp_hl=1` also sends the panel's HBM-on set once (the DT bytes above), from a thread
  call 50 ms after the first drawn frame (DSI writes sleep on the 0250 lock). `negronifp_hl=2`
  draws only. `negroni_fp_hbm(bool)` is exported for later stages (HBM off set included).
- Not done: HBM off at display sleep (0258 fades to DBV 0 and sends 0x28/0x10; the next
  brightness write from iOS overrides 0x51 but leaves 0x53 = 0xE0). Test boot-arg only.

## 4. iOS side: analysis and design (stage D)

### 4.1 What iOS 16 has, and why none of it works here

- iOS biometrics are Touch ID (`AppleBiometricSensor` over SPI to the Mesa sensor, matched inside
  the Secure Enclave by the SEP's biometric firmware; userland `biometrickitd`, `BiometricKit`,
  `LocalAuthentication`) or Face ID (Pearl: the TrueDepth camera, matching in the SEP). Both
  store templates and run the match in the SEP; the AP only sees "matched / not matched".
- Our kernel has no SEP (`AppleSEPManager`, `AppleMesaSEPDriver`, `AppleSEPKeyStore` are Apple
  kexts not in the NEGRONI build), no Mesa/Pearl hardware, and the ADT identity is the iPhone X
  (d22ap: Face ID). So `biometrickitd` finds no sensor, `LAContext.canEvaluatePolicy(
  deviceOwnerAuthenticationWithBiometrics)` is false, and the lock screen offers the passcode.
  Nothing to patch there: the match cannot be moved out of the SEP in Apple's design.
  (Shared-cache check [V]: the 20H392 cache contains `com.apple.biometrickitd` 6 times and `AppleBiometricSensor`
  once, i.e. the userland stack is present; the kernel side is not.)

### 4.2 Design: an unlock service outside the Apple biometric stack

Components (all new code; sizes are guesses):

1. **Kernel** (stages A-C, ~1500 lines): sensor power/reset/IRQ, SPI capture into a kernel
   buffer, the highlight + HBM + "ui ready" sequence. Interface to userland through the existing
   USB command server style or a small IOService (`NegroniFingerprint`, like 0301's
   `NegroniVibrator`): properties `capture` (start, returns frame id), `frame` (the raw image),
   `irq` (finger down/up events), `highlight` (on/off).
2. **Daemon `negronifpd`** (launchd, ~3000 lines): waits for IRQ "finger down", asks the
   framebuffer for the highlight + HBM, waits one frame (the equivalent of ui-ready: the vsync
   after the disc is drawn + `ofp-hbm-on-period` 2 TEs = 17 ms), captures, removes the highlight,
   runs the matcher, and on a match performs the unlock.
3. **Matcher** (open source, ~0 new lines + glue): minutiae extraction and matching, e.g.
   SourceAFIS (Java/C#, MIT: there is a C port) or NBIS `mindtct` + `bozorth3` (public domain,
   C). Optical images need preprocessing (the moire/background subtraction the TA does:
   HAL strings `moireCoordinateArray`, `badpoint_filter`): a calibration capture without a finger,
   subtracted from each frame [I]. Templates in `/var/db/negronifp/` (owner-only; not SEP-grade:
   say so to the owner).
4. **Enrolment UI**: a small app (like PowerMenu) that captures 8-12 frames, shows quality, stores
   the template.
5. **Unlock**: two options. (a) Passcode injection: the daemon stores the device passcode (a
   keychain item is not available without the SEP; a root-only file) and, after a match, drives
   SpringBoard's lock screen through the accessibility/HID path (type the passcode as HID key
   events on the passcode pad, as the USB command server already injects input). Works with
   `negroni-aks-no-passcode` (0220) absent; simple and robust. (b) `SBLockScreenManager`
   hook: a dylib injected into SpringBoard (needs `MobileSubstrate`-like loading; AMFI is already
   relaxed by 0221) calling `-[SBLockScreenManager unlockUIFromSource:withOptions:]` after an
   XPC message from the daemon; this bypasses the passcode only when the device has no
   passcode (0220 path) because the keybag needs the passcode to unlock data protection. Hence
   (a) is the realistic one when a passcode is set, (b) when none is set.
6. **LAContext shim** (optional): a dylib in apps' `LocalAuthentication` path that answers
   `canEvaluatePolicy` true and forwards `evaluatePolicy` to the daemon; app-level only, no
   keychain ACL semantics (SEP-bound keys stay unusable).

Risks of the design: the matcher's false-accept rate without liveness detection (the TA has
`detect_fake`), image quality without the TA's calibration, and the stored passcode. The owner
decides whether (a) is acceptable.

### 4.3 Stage D decisions (2026-10-26)

**Matcher** (license and size checked on GitHub 2026-10-26 [V `gh api`]):

| Option | Language | License | Size | Fit |
|---|---|---|---|---|
| SourceAFIS (robertvazan/sourceafis-java, -net, -rust) | Java / C# / Rust | Apache-2.0 | 2.3 MB / 2.7 MB repos | no Java/.NET on iOS; the Rust port (apache-2.0) builds for arm64 iOS and is the first choice |
| libAFIS (Simprints/libAFIS) | C | BSD-3-Clause | small (a SourceAFIS port, 42 stars) | compiles anywhere; the fallback when the Rust toolchain is not wanted |
| NBIS mindtct + bozorth3 (NIST; the copy inside libfprint) | C | public domain (NIST); libfprint itself LGPL-2.1 [V Debian copyright file] | mindtct ~1 MB source | proven on optical images, no dependencies; bozorth3 scores are not calibrated for FAR |

Pick: **SourceAFIS (Rust port) as the matcher, NBIS mindtct as the second extractor for an A/B test**
[I]; both take an 8-bit grayscale image at ~500 dpi. The G7 frame is 364 x 252 of a ~9 x 6 mm area
[I: the public HAL header says 364*252*2 bytes, the sensing area is the "pressed icon" ~ r95 px =
~6 mm]: ~1000 dpi, so the daemon downsamples 2:1 after the calibration subtraction.

**Preprocessing** the TA does and we must redo [V HAL strings + public header]: dark base
(`cali_seq1_darkbase`), moire removal (`moireCoordinateArray`, `sBaseMoire`), bad pixels
(`badpoint_filter`), gain (`DELMAR_CALI_STATE_PGA_GAIN`). Stage D step 1 captures a no-finger frame
under HBM (the "base") and subtracts it from each frame; a 2D FFT notch at the OLED pixel pitch
(the moire) is step 2 only if the SourceAFIS quality stays below its 40-minutiae threshold.

**Enrol / verify UX**: an own app (like PowerMenu): enrol = 8 to 12 captures with the disc drawn by
0351 (the app asks the daemon; the daemon tells the framebuffer to draw and the kernel to capture),
a quality bar per capture, the template saved; verify = one capture, 300 ms budget.

**Lock-screen hook, compared**:

| | (a) passcode injection | (b) SBLockScreenManager hook |
|---|---|---|
| How | the daemon types the passcode as HID key events into SpringBoard's passcode pad (the USB command server already injects input) | a dylib in SpringBoard calls `-[SBLockScreenManager unlockUIFromSource:withOptions:]` on an XPC message |
| Works with a passcode set | yes (the keybag gets the real passcode) | no: data protection stays locked without the passcode |
| Needs | the passcode stored by the daemon (root-only file, encrypted with a key held in the daemon's container) | 0220 (no passcode) and a SpringBoard dylib loader |
| Risk | the stored passcode; wrong-pad timing | none for data, but no data protection at all |
| Pick | **(a)** when a passcode is set | (b) only in the no-passcode test setup |

**Security notes**: templates live in the daemon's container (`/var/db/negronifp/`, 0600, root), encrypted
with a per-device key derived from the UFS serial + a random salt in the same directory (no SEP, no
keychain ACLs: an attacker with root reads both; say so to the owner). No liveness check (the TA has
`detect_fake`): a photo of a finger on the display may pass. The matcher threshold starts at SourceAFIS's
default 40 (FMR ~0.01 %) and is raised after the owner's own false-accept test with 5 other fingers.

## 5. Risks of running stages A and B (for the owner)

- Rails: the only rail touched is `pm8350c_l11` = `ldoc11` at **3000 mV** (DT `ldo-config`
  live.dts:36716, regulator range 2.4-3.008 V live.dts:11248-11257). The vote is through the
  existing allow-listed RPMh path. The panel rails, the touch rails and every other LDO are not
  touched. No rail is written when `negronifp` is absent or 0.
- XPU: QUP1 SE2 is normally owned by the TEE on Android. If the hypervisor/XPU blocks HLOS access
  to 0xa88000 the first read in step 3 faults (SError -> panic, with `negronipanic=30` the phone
  reboots). Step 2 (GCC votes) comes first and is HLOS-legal. The QUP1 wrapper version read
  (0xac0004) is an address the HLOS I2C drivers use.
- Clocks: our votes are added bits in the APCS vote register and removed at the end; the RCG for
  SE2 is set to XO (a shared SE2 RCG is not used by any HLOS device, all SPI nodes are disabled).
- The highlight (stage B) at `negronifp_hl=1` sets the panel to HBM with DBV 0xEFF (full HBM)
  until reboot or an HBM-off call: the panel is bright, battery drain is higher. Use `=2` to
  test the disc alone.
- Nothing is written to any partition. All boot-args default off.

## 6. Files

- `patches/xnu/0350-negroni-fingerprint-stage-a.patch`: `bsd/dev/negroni_fp.c`, `bsd/conf/files`,
  `bsd/dev/negroni_ufs.c` (init call).
- `patches/xnu/0351-negroni-fingerprint-highlight.patch`: `iokit/Kernel/arm/NegroniFramebuffer.cpp`.
- `patches/xnu/0352-negroni-fingerprint-mcu-frames.patch`: `bsd/dev/negroni_fp.c` (MCU frames, EBUSY retry).
- `patches/xnu/0353-negroni-fingerprint-capture.patch`: `bsd/dev/negroni_fp.c` (capture, `/dev/negroni-fp`), `NegroniFramebuffer.cpp` (`negroni_fb_te_wait`).
- `scripts/fp/get-references.sh` (public HAL + kernel shim + goodix-fp-dump into `out/fp/ref`), `scripts/fp/find-ta.sh` (TA scan of the partition dump), `scripts/fp/raw-to-png.py`.
- `patches/xnu/README-fingerprint.md`: boot-args and expected log lines.
- `out/fp/` (git-ignored): extracted OTA images (`payload/`), HAL copies (`odm/`), references (`ref/`).
- Test images: `out/ios16-fp` (`negronifp=2 negronifp_hl=1 ...`), `out/ios16-fp3` (`negronifp=3 negronifp_hl=2 negronipanic=30 negronipanicreason=2`); `scripts/fp/build-test-image.sh NAME BOOTARGS`.

## 7. Stage C: the G7 protocol, what the files we own say (2026-10-26)

Sources (all read-only, nothing decrypted): the stock HAL `libgf_hal_G7.so` strings (`out/fp/lists`), the
public HAL source of the same HAL (`out/fp/ref/oplus-secure/.../goodix_optical/goodix_G7`, from
`techyminati/android_vendor_oplus_secure`, fetched by `scripts/fp/get-references.sh`), the OPLUS kernel shim
(`out/fp/ref/op-sm8475/drivers/input/oplus_fp_driver/goodix_optical_fp`), the public Goodix MCU protocol
(`out/fp/ref/goodix-fp-dump`), and the partition dump scan (`scripts/fp/find-ta.sh` -> `out/fp/lists/ta-scan.txt`).

### 7.1 Facts [V]

- **The HAL never touches SPI.** Every sensor operation is a QSEE command to the TA with a `gf_cmd_header_t`
  (`target`, `cmd_id`): `GF_CMD_DELMAR_SENSOR_READ_IMAGE = 101` (base 100, `NOTIFY_RESET = 102`,
  `GET_CALI_LOAD_ERROR = 103`; `gf_delmar_types.h:221-226`), `DelmarSensor::readImage` fills
  `gf_delmar_read_image_t` (sensor ids, ui type, press area, coordinates) and calls `invokeCommand`
  (`DelmarSensor.cpp:333-363`). The generic ids `GF_CMD_SENSOR_INIT`, `GF_CMD_SENSOR_CAPTURE_IMG` ...
  are an enum from 0 in `gf_sensor_types.h:10`. The kernel shim is the same: `/dev/goodix_fp` ioctls
  `GF_IOC_INIT 0 .. GF_IOC_STOP_WAIT_INTERRUPT_EVENT 23` (magic `'g'`, `Device.cpp:49-79`), the reset is
  `gf_hw_reset`: reset low 5 ms, high, `delay_ms` = 10 (`gf_platform.c:443-456`, `gf_spi.c:445`): 0350's
  5 ms pulse matches. `GF_IOC_ENABLE_SPI_CLK` only turns the QUP clocks on for the TEE (`gf_spi.c:193-265`,
  under `AP_CONTROL_CLK`); **no SPI frame exists in the HAL or the shim**.
- **The module has an MCU in front of the sensor.** HAL strings: `test reset and interrupt pin between mcu
  and sensor`, `GF_ERROR_HOLD_MCU_FAILED`, `fw_app_version`, `fw_bootcode_version`,
  `GF_ERROR_SPI_FW_DOWNLOAD_FAILED`, `GF_ERROR_SPI_CFG_DOWNLOAD_FAILED`, `GF_ERROR_SPI_RAW_DATA_CRC_FAILED`,
  `GF_ERROR_SPI_RAW_DATA_BUF_BUSY`. Public header: `DELMAR_C_CHIP_TYPE_GW183`, `GW183D_ECO1/2`
  (`gf_delmar_types.h:270-275`: the "C chip" = the sensor die), sensor types
  `DELMAR_SENSOR_TYPE_SINGLE_T_SE1 = 1 .. SE5 = 3`, `SINGLE_CS_SE1 = 0x101 ..`, `GM182 = 0x10001`
  (`gf_delmar_config.h:176-189`); the stock HAL names `GF_CHIP_DELMAR_T_SE1`. So the SPI partner is a Goodix
  MCU with a boot code + downloadable application firmware, like the Goodix USB/SPI laptop sensors.
- **Frame geometry.** `DELMAR_ORIGIN_BUFFER_LEN = 183456 = 364 * 252 * sizeof(uint16_t)` (the sensor
  origin frame), `DELMAR_RAW_BUFFER_LEN = 182 * 132` words (the processed raw), `DELMAR_BMP_BUFFER_LEN =
  182 * 132` bytes, `DELMAR_SENSOR_OTP_INFO_LEN 14`, `DELMAR_CHIP_ID_BUFFER_LEN 32`, `DELMAR_OTP_INFO_BUFFER_LEN 64`
  (`gf_delmar_types.h:52-66`). The sensor-init answer carries `o_sensor_id[4][18]`, `o_c_chip_type`,
  `io_sdcard_otp[4][64]`, `o_qr_code_data` (`:289-311`). Capture parameters the TA takes: exposure mode
  short/long, continue-frame count (max 5), `lb_mode`, `is_check_highlight`, `light_sensor_val`
  (`gf_delmar_capture_image_t` `:340-352`).
- **Calibration the TA applies** (`DelmarHalDump` csv names): dark base, black/flesh min/mid/max frames,
  circle and chart, `moireCoordinateArray`, `maxBlackFreshAvg`, `badpoint`; `DELMAR_CALIBRATION_DATA_LEN
  191813`, `DELMAR_AUTOCALI_PARAM_BUFFER_LEN 888945` (`:81-96`). The per-device calibration lives in
  `/data/vendor/goodix/fpdata` and `gf_data/encrypted_data/cali` (strings) -> not in any image we own.
- **The TA file.** Search of the HAL strings: it is loaded with `QSEECom_start_app` from
  `/vendor/firmware_mnt/image`, `/vendor/firmware`, `/odm/vendor/firmware`, `/my_product/vendor/firmware`,
  ... (hal-strings.txt). `vendor.img` and `odm.img` `/firmware` have no Goodix file (lists). The partition dump
  scan result is in `out/fp/lists/ta-scan.txt` (modem = `firmware_mnt`, tz, oplus_sec, ...; result below in
  7.4). A TA is a signed `.mbn`/`.b00-b07` split image whose segments are encrypted on production devices
  (QSEE), so even a found file gives strings of the ELF headers only; we do not try to decrypt it.
- **Public Goodix MCU protocol** (`goodix-fp-dump/goodix.py:56-114`, USB sensors 5110/5117/521d/5395/55x4 and
  the SPI 5120): message pack `A0 | len16 LE | sum8(A0,len)` around a message protocol
  `cmd | (plen+1)16 LE | payload | 0xAA - sum8` (0x88 = no checksum). Commands: `NOP 00`, `MCU_GET_IMAGE 20`,
  `FDT_DOWN/UP/MODE 32/34/36`, `NAV 50`, `MCU_SLEEP 60`, `MCU_IDLE 70`, `WRITE/READ_SENSOR_REGISTER 80/82`,
  `UPLOAD_CONFIG_MCU 90`, `SET_POWERDOWN_SCAN_FREQUENCY 94`, `ENABLE_CHIP 96`, `RESET A2`, `MCU_ERASE_APP A4`,
  `READ_OTP A6`, `FIRMWARE_VERSION A8`, `QUERY_MCU_STATE AE`, `ACK B0`, `REQUEST_TLS D0`, `PRESET_PSK E0/E4`,
  `WRITE/READ/CHECK_FIRMWARE F0/F2/F4`, `GET_IAP_VERSION F6`. The answer to every command is an ACK pack
  (`B0`, payload `cmd, flags`) then the reply pack. Image readout: `MCU_GET_IMAGE` payload `01 00`, the reply
  pack flags `B2` (TLS data on USB chips), pixels 12-bit packed 6 bytes -> 4 pixels (`tool.py:36-46`).
  SPI transport of the 5120 (`protocol.py:147-185`): write = `CC F2 seq16` + pack, read = `BB F1 00 00` +
  clocked bytes (256 at a time), IRQ GPIO falling edge = answer ready.
- **Pixel/Trusty hint**: a public GrapheneOS log of a Pixel 8 shows the Goodix Trusty TA logging
  `gf_delmar_t_dc` / `delmar_read_chip_id` -> "Delmar T" is the same family on Google's phones; no source.

### 7.2 Inferences [I]

- The G7 MCU **may** speak the public message-pack protocol over SPI (same vendor MCU family, same
  "fw app / boot code / download firmware and config" model, `GF_CMD_TEST_SPI`, `GF_CMD_TEST_GET_OTP_INFO`,
  `GF_CMD_TEST_GET_VERSION` map 1:1 to `READ_OTP`/`FIRMWARE_VERSION`). The TLS layer of the USB chips
  (PSK, `B0/B2` flags) is probably replaced by the QSEE trust on phones, i.e. plain packs. Stage C tests
  exactly this: 0352 sends the frames in both transports and logs the raw answer.
- The 364 x 252 x 16-bit origin frame is what `GF_CMD_DELMAR_SENSOR_READ_IMAGE` returns from the TA; the MCU
  wire format is unknown (12-bit packed on the USB chips; 16-bit words on the TA side).
- Which SE: QUP1 SE2 (section 1.1). A wrong SE gives MISO idle in step 8 and step 10 and no IRQ reaction.

### 7.3 What 0352 and 0353 do

- 0352 (`negronifp=3`): step 10 after the chip-ID frames. For each transport (plain SPI; `CC F2`
  wrapper; `negronifp_wrap` selects) the frames nop, query MCU state (`AE 55`), firmware version
  (`A8 00 00`), read OTP (`A6 00 00`), read sensor register 0 (`82 00 00 00 04`): TX under one CS, the IRQ
  pin watched for `negronifp_irqwait` ms (default 100), then 16..80 clocked bytes read in FIFO pieces and
  decoded. Proof lines: `irq40 changed N ms after the frame` (the MCU reacts), `VALID message pack at byte
  i: cmd xx payload n bytes` (it speaks the protocol), `MCU probe result: ...` (the verdict). 0352 also
  fixes the audit items: the ldoc11 vote retries EBUSY 40 x 50 ms and the thread stops on failure.
- 0353 (`negronifp=4`): step 11: `negroni_fp_hbm(true)` (0351's DCS set), `negroni_fb_te_wait(2, 100)`
  (new, NegroniFramebuffer.cpp: the 0259 tearcheck frame counter; 17 ms timed when `negronifb_te=0`),
  `MCU_GET_IMAGE 01 00` over the transport that answered (plain when none), a bounded read of
  then HBM off right after the frame and its IRQ wait (<= 100 ms: the exposure is at the frame, the readout
  needs no light; the HBM-on time is ~20-120 ms, not the read time), a bounded read of `negronifp_img`
  bytes (default 183456) in 64-byte pieces under one CS (the `BB F1 00 00` read header once; the public
  5120 driver re-sends it per 256-byte read, protocol.py:182), early stop after 16 idle pieces when nothing
  looked like data, statistics (00/ff counts, distinct values, a pack header). `/dev/negroni-fp` (0600) =
  32-byte header + the bytes; `scripts/fp/raw-to-png.py` (`--self-test`) writes PNGs for the 16-bit,
  12-bit-packed and 8-bit interpretations.
- Not done (needs the answer of step 10 first): the MCU reset/idle/config sequence before a capture
  (public: `RESET`, `MCU_SWITCH_TO_IDLE`, `UPLOAD_CONFIG_MCU` with a per-chip config blob we do not have),
  exposure/gain registers, the 12-bit vs 16-bit wire format, multi-frame averaging.

### 7.4 Plan after the first run

| Step 10/11 result | Meaning | Next |
|---|---|---|
| `VALID message pack` on either transport | the public protocol holds; the transport is known | capture via 0353; then `READ_OTP`, `FIRMWARE_VERSION` strings go into notes; add `RESET`/`IDLE` before the capture; find the config blob (the TA's data: not available) or run without (the MCU boots with its flashed config) |
| `irq40 changed` but `bytes ... no message pack` | the MCU answers with another framing | log 128 bytes raw; vary `negronifp_mode` 0..3 and `negronifp_hz` (1.2/2.4/4.8 MHz); look for a length field and a checksum in the dump |
| MISO idle, no IRQ change, step 8 idle too | expected for a Delmar-T direct sensor (7.4 TA result): the frames are wrong, or the SE/pins/mode are | try QUP1 SE0/SE1/SE3 (0xa80000/0xa84000/0xa8c000, same pins check) and the TLMM function 2/3 of GPIO 36-39; check the ID pin and the LDO really rose (voltmeter on the FPC) |
| capture `VARIED DATA` | an image or noise | pull `/dev/negroni-fp`, `raw-to-png.py`, look for ridges under HBM with a finger; compare a no-finger frame |

TA scan result (`scripts/fp/find-ta.sh`) [V]: no Goodix string in `modem_a` (= firmware_mnt), `tz_a`, `oplus_sec_a`,
`tzsc`, `keymaster_a`, `qupfw_a` (modem's `qfp_*` strings are Qualcomm's ultrasonic sensor stack); the log partitions
`oplusreserve2/3/5` carry the TA path **`/odm/vendor/vendor/firmware/goodixfp.mdt`** (HAL search path 4). The split
image `goodixfp.mdt/.b00..` is pulled by `scripts/fp/extract-ta.sh` into `out/fp/ta` (strings in
`out/fp/lists/ta-strings.txt`; the code segments are QSEE-encrypted on a production device, the ELF/hash headers are
plain). Section 1.2's "not found" is corrected by this. Result [V]: `goodixfp.{mdt,b00-b07}` extracted to `out/fp/ta`
(odm.img `/vendor/firmware`), an aarch64 ELF with plain strings (`out/fp/lists/ta-all-strings.txt`): two sensor paths,
`gf_bus_mcu_*` (MCU variant, embedded `malibu` MCU firmware, GM182) and `gf_bus_dc_*` / `gf_delmar_t_*` (direct
sensor: `secspi_read_byte/word`, `secspi_write_bytes`, `get_trim`, `get_hr_image`, `delmar_dc_wakeup`,
`gf_delmar_t_read_chip_id`). The stock HAL's `GF_CHIP_DELMAR_T_SE1` is the direct path [I]: **the sensor is a
register-mapped SPI device, not an MCU with the public message-pack protocol**. Consequence for 0352/0353: the
public frames are a negative control (expected: MISO idle); the register frame (`gf_bus_dc_secspi_read_word`) lives
in the TA code. Next decision for the owner: analyse the TA binary further (we own the file, it is not encrypted),
or get the frame from a bus capture on a second device.

## 8. Overlay rule since 0354 (2026-10-27)

The overlay is never drawn from boot. `negronifp_hl=1|2` only allows it. The lock-screen glyph (dim grey rings,
no fill, no HBM) needs `negronifp_hl=1` in the boot-args AND a root built with `FPD=1` (negroni-fpd writes
`kern.negroni_fp_ui` from the SpringBoard lock state); it shows whenever the phone is locked with the screen on,
so also over Control Center, Notification Center and the camera opened from the lock screen. The white disc (+ HBM
in mode 1) shows only during 0353's capture while a finger is inside the circle. Details: patches/xnu/README-fingerprint.md "0354".
