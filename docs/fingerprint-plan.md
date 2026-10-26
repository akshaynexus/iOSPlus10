# Under-display fingerprint sensor (Goodix optical G7) on the OnePlus 10 Pro: facts, plan, iOS design

Status 2026-10-26: facts collected, stage A (patch 0350) and stage B (patch 0351) written and built.
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
| C | kernel: raw image capture into a buffer (needs the G7 SPI protocol: register map, frame format) | an image dump over the USB command server | not started; protocol unknown [I] |
| D | userland: matcher + iOS lock-screen integration | unlock with a finger | design only (section 4) |

Stage C depends on the SPI protocol, which only the TA knows. Ways to get it: (1) Goodix's
public capacitive drivers (`gf_spi.c`: read `{0xF1, addr_hi, addr_lo}` + data, write
`{0xF0, ...}`) as a first guess (stage A sends them and logs the answer); (2) strings/disassembly
of the HAL and of the TA once it is found; (3) bus capture on a second device. Until then the
honest statement is: stage A can prove the SE, the power, the reset and the IRQ; a chip ID is a
bonus.

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
- `patches/xnu/README-fingerprint.md`: boot-args and expected log lines.
- `out/fp/` (git-ignored): extracted OTA images (`payload/`), HAL copies (`odm/`), references (`ref/`).
- Test image: `out/ios16-fp` (config args + `negronifp=2 negronifp_hl=1 negronipanic=30 negronipanicreason=2`).
