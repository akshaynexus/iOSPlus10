# Panel brightness and display sleep (patches 0250, 0251)

Status: written and syntax-checked against `out/kernel/buildtree` (clang `-fsyntax-only`, 0 errors,
no new warnings). **Not built and not tested on the phone yet.**
Both patches apply on `base` together with all other `patches/xnu/0*.patch` (checked 2026-10-24).

| Patch | Content |
|---|---|
| `0250-negroni-panel-brightness.patch` | New `iokit/Kernel/arm/NegroniBacklight.cpp`: DSI0 DCS writes (command DMA, FIFO mode) and an `AppleARMBacklight` service for CoreBrightness. Hook in `AppleCLCD::start`. |
| `0251-negroni-display-sleep.patch` | Display off/on (RequestPowerChange) goes to the backlight: DBV 0 at once, the framebuffer clears the pixels in one pass instead of its 7-step fade. Power-key "fast-off". |

0251 needs 0250. 0250 works alone (brightness slider; display sleep stays as in base).

## Facts and sources

[V] = seen in a file, [I] = inference.

| Fact | Value | Source |
|---|---|---|
| Panel | Samsung AMB670YF08, driver IC S6E3HC3, "samsung S6E3HC3 dsc cmd mode panel" | [V] `out/live.dts` bootargs `msm_drm.dsi_display0=qcom,mdss_dsi_panel_samsung_amb670yf08_fs_1440_3216_dsc_cmd`, node at line ~35551 |
| Mode | AMOLED (`physical-type = "oled"`), DSI command mode, DSC 1.2 (slice 540x36, 8 bpp, 10 bpc), DSI0 only (`dsi-ctrl-num = 0`, `dsi-phy-num = 0`), 4 lanes | [V] live.dts panel node; UEFI XML |
| Mode set by the UEFI | 1080x2412 at 120 Hz, `DSIEnableAutoRefresh = True`, TE on a dedicated pin | [V] `out/uefi/Binaries-negroni/RawFiles/Panel_samsung_amb670yf08_1440_3216_dsc_cmd.xml` |
| Frame path | MDP auto-refresh sends the RAM framebuffer on every TE; the kernel only writes RAM, nothing kicks frames | [V] UEFI XML + no kick code in the kernel (grep) |
| Brightness command | DCS 0x51, 2 parameter bytes, **high byte first** (DBV) | [V] live.dts `hbm-off-command ... 39 .. 03 51 06 9f`, `hbm-exit-switch ... 51 07 ff`; `qcom,mdss-dsi-bl-inverted-dbv` |
| Levels | 1..0x7ff normal (`oplus,dsi-bl-normal-max-level = 0x7ff`), up to 0xfff with HBM (`qcom,mdss-dsi-bl-max-level`), min 1, Android default 0x190 | [V] live.dts |
| HBM | 0x800..0xfff only with the panel's HBM sequences (0x53 0xe0 etc.); not used | [V] live.dts `hbm-on-command` |
| Control | `bl_ctrl_dcs`, sent in LP mode (`qcom,bl-dsc-cmd-state = "dsi_lp_mode"`) | [V] live.dts |
| 0x53 | 0x28 (BCTRL + dimming) is in the UEFI init sequence | [V] UEFI XML `15 53 28` |
| UEFI level | `BacklightDefault 45 %`, 12 bit; the exact DBV after the UEFI is unknown | [V] UEFI XML; [I] value |
| Display off/on | off-command `05 28` (wait 21 ms) `05 10` (wait 101 ms); on: `05 11`, `29` | [V] live.dts `mdss-dsi-off-command`, UEFI `DSITermSequence`, init sequence |
| DSI0 controller | 0x0AE94000, size 0x400, `qcom,dsi-ctrl-hw-v2.6`; MDP INTF 0x0AE36000 | [V] live.dts `qcom,mdss_dsi_ctrl0@ae94000` reg |
| MDSS / MDP | 0x0AE00000 | [V] live.dts `qcom,mdss_mdp@ae00000` |

DSI 2.x register offsets (from Linux `techpack/display/msm/dsi/dsi_ctrl_reg.h`, equal to upstream
`dsi.xml.h` + `DSI_6G_REG_SHIFT` 4; the same offsets work on DSI 1.4 in ios-sailfish 0168) [V in source,
not read on the phone yet]:

| Offset | Register | Use |
|---|---|---|
| 0x000 | HW_VERSION | must be 0x2xxxxxxx (v2.6 = 0x20060000), else no DCS |
| 0x004 | CTRL | bit 0 ENABLE and bit 2 CMD_MODE_EN must be set, else no DCS |
| 0x008 | STATUS | bit 1 CMD_DMA_BUSY, bit 2 CMD_MDP_BUSY |
| 0x03c | COMMAND_MODE_DMA_CTRL | bit 31 broadcast, 30 master (both cleared), 28 embedded mode (set), 26 low power |
| 0x04c | DMA_CMD_LENGTH | bytes of the command (not the pad word) |
| 0x084 | TRIG_CTRL | bits 0-3 DMA trigger; 4 = software (set if different, restored after) |
| 0x090 | CMD_MODE_DMA_SW_TRIGGER | write 1 |
| 0x110 | INT_CTRL | bit 0 CMD_DMA_DONE (write 1 clears); odd bits are enables, kept |
| 0x15c | TEST_PATTERN_GEN_CTRL | `3<<16 | 1<<2 | 1<<1`: command DMA from the TPG FIFO |
| 0x17c | TEST_PATTERN_GEN_CMD_DMA_INIT_VAL | FIFO port, one 32-bit word per write, even number of words |
| 0x1ec | TPG_DMA_FIFO_RESET | 1, then 0 after the command |

Packet words (embedded mode): `[7:0]` data0 / word count low, `[15:8]` data1 / word count high,
`[21:16]` data type, `[23:22]` VC, bit 30 long packet, bit 31 last. Brightness DBV 0x069f:
`0xc0390003` (last, long, 0x39, WC 3), `0x009f0651` (0x51, 0x06, 0x9f), length 8.

CoreBrightness (iOS 16.7 20H392, `CoreBrightness.framework`, from the shared cache of the root image,
disassembled with `otool`; not committed) [V]:

- `-[CBDisplayContaineriOS ...]` uses `IOPropertyMatch {backlight-control: true}` and
  `IOObjectConformsTo(..., "AppleARMBacklight")`. PerfPowerServices (PLDisplayAgent) watches
  `AppleARMBacklight` / `IODisplayParameters` too.
- `DisplayCreateWithID` reads `IODisplayParameters {brightness {value, min, max}}`. With
  `new-backlight-architecture` it reads calibration data (`backlight-calibration-parameters`, ...).
  We do not publish it: CoreBrightness then uses `__DisplaySetPhysicalBrightnessLegacyOnThread`,
  the path sailfish 0168 saw on the same iOS build (`brightness`, `FadePeriod` 16.16 s,
  `backlight-level`).
- `_SetBLDriverNitsValue` sets `brightness-nits` as a 32-bit 16.16 number (it divides by 65536.0
  to log it). The driver accepts it as a fallback (nits * DBVmax / `negronibl_nits`).
- Digital dimming flag (`+0x54c`) = `HardwareAccessibleMinNits > digital-dimming-min-nits`, the
  second read with `IORegistryEntrySearchCFProperty`. Without `digital-dimming-min-nits` the two are
  equal, so digital dimming stays off. This matters: topaz saw <1 fps when CoreBrightness ran digital
  dimming over every frame with the CPU renderer (bergamota `docs/TOPAZ_REVIEW.md`).

## Design

- `AppleARMBacklight` (IOService) attaches to `AppleCLCD`, publishes `backlight-control = true` and
  `IODisplayParameters {brightness {min 0, max 2047, value}}`. The value iOS sends is the device level
  in 0..2047 = the DBV. iOS already maps the slider to light output, and the panel's DBV is close to
  linear in luminance, so the default map is linear (sailfish 0168 maps 1:1 too). `negronibl_curve=1`
  uses DBV = v^2 / max if the low end is too bright.
- `setProperties` only records the target and the fade (`FadePeriod`, at most 5 s) and arms a timer;
  the panel is written from the service's own work loop in 16 ms steps. backboardd never waits for
  the DSI (topaz 0107 lesson).
- DCS write (`negroni_dsi_dcs_write`, exported C function): one IOLock for every DSI command; waits
  for DMA idle (5 ms, else fails without touching the hardware), waits up to 20 ms for the MDP stream
  to be idle (between auto-refresh frames), then FIFO, length, trigger, polls CMD_DMA_DONE for 25 ms,
  resets the FIFO and restores TPG_CTRL, DMA_CTRL and TRIG_CTRL. After 3 failures in a row no more
  DSI writes happen until reboot.
- Logs: one line per setProperties for the first 24 calls (process, keys); panel DBV at most once per
  second during a fade, the end of a fade at most every 250 ms.

Display sleep (0251):

- `RequestPowerChange(0)` (backboardd, power key / auto-lock) calls
  `negroni_backlight_display_power(false)`: it does not block, the work loop sends DBV 0 within
  milliseconds. If the DSI is usable, the framebuffer skips its fade (6 read-modify-write passes over
  10 MB of write-combined memory) and clears the pixels in one write pass on the next vsync tick.
  Pending CPU frames are not waited for (the vsync tick does not present while off, as before).
- `RequestPowerChange(1)`: restores the last level iOS set while the display was on (or the newest
  one); the framebuffer redraws the latest frame as before.
- Default is blank only: the panel stays powered, the link and auto-refresh keep running.
  `negronibl_sleep=1` adds DCS 0x28 / 0x29 (display off / on, as the panel's own lp1/nolp
  sequences do). `negronibl_sleep=2` adds 0x10 / 0x11 (sleep in / out, 120 ms waits): in sleep the
  panel stops TE, so auto-refresh stalls until 0x11; untested, use only to measure power.
- Fast-off (`negronibl_fastoff=N`, default 20 s): the measured lock delay is ~10 s (iOS sends
  RequestPowerChange late because CPU rendering lags). A short press of the power key (< 700 ms)
  while the display is on sets DBV 0 at once. iOS's display-off then takes over. If iOS does not turn
  the display off within N seconds (the press was not a lock, e.g. a call or the power-off slider),
  the level comes back; the next power-key press also brings it back. The key still goes to iOS
  unchanged. `negronibl_fastoff=0` turns it off.

Boot-args: `negronibl=0` (no service, no DSI access, base behaviour), `negronibl_max` (DBV, default
2047, at most 4095 = HBM range, not recommended), `negronibl_curve=1`, `negronibl_hs=1` (HS instead of
LP transmission), `negronibl_sleep=0/1/2`, `negronibl_fastoff=seconds`, `negronibl_nits` (default 500).

Serialization with frame kicks: there is no kick in the kernel today (auto-refresh). If 0230/0231 add
MDP flips (SSPP address + CTL_FLUSH), they do not touch the DSI and need no lock. If a later patch
sends its own DSI commands or turns auto-refresh off and starts frames by hand, it must take the same
path (`negroni_dsi_dcs_write`) or the same lock, and it should not trigger a frame while
`negroni_dsi_dcs_write` runs.

## Files and functions touched (for the integrator)

| File | Change | Patch |
|---|---|---|
| `iokit/Kernel/arm/NegroniBacklight.cpp` | new | 0250 |
| `iokit/conf/files.arm64` | one line appended at the end (after `IOHIDEventServiceUserClient.cpp`) | 0250 |
| `iokit/Kernel/arm/NegroniFramebuffer.cpp` | declaration `void negroni_backlight_attach(IOService *)` before `class IOMobileFramebuffer`; `AppleCLCD::start`: `negroni_backlight_attach(this);` after `registerService()` | 0250 |
| `iokit/Kernel/arm/NegroniFramebuffer.cpp` | `extern "C" bool negroni_backlight_display_power(bool)` after `iso_font`; `IOMobileFramebufferUserClient::externalMethod`, case `kNegroniFBRequestPowerChange`: call it before `IOLockLock`, `fFadeStep = dark ? 6 : 0` | 0251 |
| `bsd/dev/negroni_keys.c` | `extern void negroni_backlight_key(int, int)`; `keys_thread`: `negroni_backlight_key(k, now);` before `negroni_hid_key(k, now);` | 0251 |

If the GPU agent rewrites `vsyncFired`'s power-off branch: keep the meaning of `fFadeStep = 6`
("write black once, no reads") or drop the fade when `negroni_backlight_display_power()` returned true.

## Test

Build with the patches (`make` kernel CI), boot with `negroniusb=2` for the USB live log.

1. Boot: expect
   `NEGRONI BL: DSI0 version 0x2006.... ctrl 0x....` (bits 0 and 2 set) and
   `NEGRONI BL: AppleARMBacklight up, DBV 0..2047, low-power DCS, curve linear, sleep mode 0, fast-off 20 s`.
   Record the printed DSI register values in `docs/notes.md` (they are the first real readout).
2. After SpringBoard: `NEGRONI BL: backboardd sets N keys: brightness ... FadePeriod ...` (which keys
   arrive decides whether the legacy path is in use), then `NEGRONI BL: panel DBV ...`.
3. Move the Control Center slider: the panel must follow, lines `panel DBV x (n writes since last line)`.
   No `FAILED` / `failed` lines.
4. Power key: `fast-off: power key, panel dark ...` at once, then (seconds later) `NEGRONI FB: display
   off` and `NEGRONI BL: display off: panel DBV 0`. Press again: `display on: panel DBV x`.
5. Auto-lock (Settings, 30 s): `display off` without the fast-off line.
6. Optional: `negronibl_sleep=1`, repeat 4 and 5; then `negronibl_curve=1` if the low end is too bright.

Failure signatures: `DSI0 not a running command-mode DSI 2.x controller` (wrong address or the display
is not as the UEFI left it: no DCS, nothing else changes), `DCS 0x51 (3 bytes) failed -3` (no
CMD_DMA_DONE: try `negronibl_hs=1`), `DSI0 commands disabled after 3 failures`,
`MDP stream busy for 20 ms` (auto-refresh never idle: harmless, the command is queued by the controller).
If the slider does nothing and no `sets ... keys` line appears, CoreBrightness did not take the service.

## Risks

- A wrong DSI write can stop the command engine; the picture can freeze or go dark until reboot. The
  code does not panic: it only accesses the DSI0 register page that the display already uses, gives up
  after timeouts, and stops after 3 failures. A register read hangs only if the DSI clocks are off;
  they are on while the UEFI's auto-refresh runs.
- TPG FIFO mode is documented for DSI 1.3+ and used by the DSI 2.x Linux driver code; it was not tested
  on SM8450 yet. The fallback (DMA from memory) needs an SMMU-visible buffer and is not implemented.
- LP transmission during the HS frame stream is what Android does for this panel; if it fails,
  `negronibl_hs=1`.
- DBV above 0x7ff without the HBM sequence: blocked (`negronibl_max` clamps to 4095; keep 2047).
- `negronibl_sleep=2` stops TE; auto-refresh stalls until wake (untested).
- Fast-off can leave the panel dark for up to N seconds after a press that iOS does not treat as lock.
- A panic while the display is off draws the panic text into a dark panel (DBV 0).
