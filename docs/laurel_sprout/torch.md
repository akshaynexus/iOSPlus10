# Mi A3 flashlight (torch): kernel 2781 + 2783, iOS side in NegroniCamera.driver

Status (2026-11-01 19:30, branch t3/laurel-torch-bl-fix): built, the new path NOT BOOTED. Marks: [V] seen in a source, log
or tool output, [I] inference, [U] unknown.

## Boot 18:40: why the button did nothing (logs/laurel-boot-1840.txt)

- [V log] Each press: `LAUREL CAMERA: ios: the flashlight at 850 of 1000 NOT TAKEN (no torch driver)`, then `at 0 of 1000`.
  So Control Center -> FigFlashlight -> camera plug-in's vendor -> stream `TorchLevel` works. [V code] `camera_device.c
  torch_set` only logged.
- [V log] `LAUREL FLASHLIGHT: off: +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] at 0xfb320184 (first word 0),
  expected 0x1a1f40c84`, in each mediaserverd (4 times). [V code + `llvm-nm`] Why that address and word: the first word is
  read only when the address is the expected one, so 0 means "not read". The address is IMP - slide: the IMP is
  NegroniCamera.driver's `_shared_vendor` (offset 0x14184 in the bundle; all 4 lines end in 0x184; 0xfb320184 + slide 0x76f8000
  - 0x14184 = load address 0x102a04000). The camera plug-in loaded first and replaced the method. The guard did its job.
- [V code] The kernel side is up as far as the log can show: LaurelFlashlight checks `open("/dev/laureltorch", O_WRONLY)`
  before the hook and reaches the hook line, so the node exists and opens from mediaserverd. The button exists, so
  `/product/camera flash` was published, and that needs `lt_ready`. `LAUREL SPMI: ... users: ... torch; ... torch 0`.
  [U] No `LAUREL TORCH` line in the USB log (kernel ring lost it) and no SPMI write of the torch was run: LED itself unproven.

## One owner (2783)

- `NegroniCamera.driver` (LAUREL_CAMERA) owns the iOS side when it is in the root: its vendor already answers FigFlashlight and
  it starts the server. `torch_set` writes `/dev/laureltorch` (TorchLevel 0..1 -> 0..1000 -> 0..100 %, > 0 is at least 1 %;
  kernel: 1..100 % = 12.5..150 mA). A stream that goes away while it lit the LED turns it off. A new mediaserverd opens the
  device at load, logs the state and turns off a light that a dead mediaserverd left on.
- `LaurelFlashlight.driver` only in a root without the camera plug-in (`CAMERA=0`); `root-flashlight.sh` removes it otherwise. It
  also stands down itself: `LAUREL FLASHLIGHT: off: NegroniCamera.driver is in the root: it owns the flashlight`.
- Kernel: the button needs one of the two in the root. `TORCH=0` at root build writes `HAL/laurel-flashlight-off`: no button.
- Kernel state visible late: the start results are kept and repeated at the first open. The node is made also when the self-check
  failed (not with `torch=0`): read gives `state=off reason=LAUREL TORCH: off: ...`, write gives EIO.
- [I] Limit: with the camera plug-in in the root and the kernel camera off (`camera=0`), the vendor refuses its device, so the
  button does nothing. Not changed: a kill-switch case only.

## Parts

| Part | File | What |
|---|---|---|
| kernel driver | `bsd/dev/laurel_torch.c` (patch 2781) | PMI632 flash LED in torch mode, `/dev/laureltorch`, watch thread, auto-off, quiesce |
| IOKit service | `iokit/Kernel/arm/LaurelTorch.cpp` (2781, 2783) | `LaurelTorch` (IOResources match) starts the driver; publishes `IODeviceTree:/product/camera` `flash` |
| SPMI user | `sweet_spmi.c/.h` (2781) | user `SWEET_SPMI_TORCH` ("torch") of the one core (2710 rule) |
| halt/panic | `SweetPlatformExpert.cpp` (2781) | `laurel_torch_quiesce()` at halt, restart, panic begin / hold |
| mediaserverd | `userland/camera/camera_device.c` (`torch_set`, LAUREL_CAMERA) | the owner: TorchLevel -> `/dev/laureltorch` |
| mediaserverd, CAMERA=0 | `userland/laurel/flashlight/` | `LaurelFlashlight.driver`: FigFlashlight vendor hook + FigFlashlight server start |
| root | `scripts/laurel/root-flashlight.sh` | one owner: camera plug-in, else LaurelFlashlight.driver; `TORCH=0` = no button |

## Hardware [V]

- `external/laurel-kernel-los/arch/arm64/boot/dts/qcom/pmi632.dtsi:519`: `qcom,leds@d300`, `qcom,qpnp-flash-led-v2`,
  SPMI SID 3 (interrupts `<0x3 0xd3 ...>`), base 0xD300; led-fault, all-ramp-down, all-ramp-up IRQs; short/open
  detection, VPH droop detection, thermal derate (200/500/1000 mA).
- `laurel_sprout-trinket-camera.dtsi`: the camera flash uses `torch-source = <&pmi632_torch0>` and `switch_0` only:
  one LED on channel LED1 (id 0). `laurel_sprout-trinket-power.dtsi`: torch_0 `max-current` 950 mA, `current-ma` 900.
  `pmi632.dtsi`: torch_0 `qcom,ires-ua = <12500>` (12.5 mA steps).
- Registers (offsets from 0xD300, `drivers/leds/leds-qpnp-flash-v2.c`): STATUS1 0x08 (short/open), STATUS2 0x09
  (bits 0-2 OTST thermal levels, bit 4 VPH droop), INT_RT_STS 0x10 (bit 0 led-fault), SAFETY_TMR 0x40+n (0x13 = off),
  TGR_CURRENT 0x43+n (bits 6:0, code = round(mA / 12.5) - 1), MOD_CTRL 0x46 bit 7, IRES 0x47 (2 bits per LED, 0 =
  12.5 mA), STROBE_CTRL 0x49+n (bit 2 HW strobe select), EN_LED_CTRL 0x4C (bit per LED).
- PMI632 power path: the flash module runs from the charger's flash boost (`schgm-flash.c`, SID 2 0xA600). After
  MOD_CTRL on, Linux (`qpnp_flash_poll_vreg_ok`) polls STATUS_2 0xA607 bit 4 VREG_OK every 5 ms up to 300 ms;
  STATUS_3 0xA608 bits 2:0 = 7 is a flash error. Android also sets the charger's FLASH_ACTIVE (qpnp-smb5.c): with USB
  present it holds VBUS at 5 V (no HVDCP). Our charger (2301) runs no HVDCP: nothing to hold [I].
- Mainline `leds-qcom-flash.c` covers the newer 3/4-channel module (PM8150C/PM8350C), not this v2 module [I from the
  register map: TGR_CURRENT/IRES/EN_LED_CTRL offsets differ].

## Sequence (as `qpnp_flash_led_switch_set` / `_switch_disable`)

On: IRES (LED1 bits = 0), STROBE_CTRL bit 2 = 0 (SW strobe), TGR_CURRENT = code, SAFETY_TMR = 0x13, MOD_CTRL bit 7,
VREG_OK poll (charger), EN_LED_CTRL bit 0. Level change while lit: TGR_CURRENT only.
Off: EN_LED_CTRL 0, MOD_CTRL bit 7 off, TGR_CURRENT 0, SAFETY_TMR 0x13.
Every write is read back (masked); a failed write = off for this boot (the off sequence still runs).

## Policy

- Current: 1..100 % = 12.5..150 mA (code 0..11). Cap 150 mA = our choice ([I] a flashlight that does not heat the camera
  module; the DT allows 950 mA). `_Static_assert` keeps the cap <= the DT max.
- Auto-off 600 s after the light came on (a new level does not restart it).
- Thermal: no light while STATUS2 shows an OTST level; lit: an OTST level, the led-fault bit (STATUS1 short/open and VPH
  droop named in the line) or a charger flash error turn it off. Watch every 100 ms while lit. 3 faults = off for the boot.
- Halt, restart, panic: EN_LED_CTRL 0 and MOD_CTRL off as emergency SPMI writes (only when it was lit this boot).
- Kill switch `torch=0`.

## iOS path [V: negroni's disassembly of 20H392, userland/flashlight/README.md; checked again on the laurel cache; [V log 18:40] for 1 and 2]

1. Button: `+[AVFlashlight hasFlashlight]` = `MGGetBoolAnswer("camera-flash")` = `IODeviceTree:/product/camera` has
   `flash`. `LaurelTorch.cpp` publishes it after the root mount, only when the driver is on and the root has a plug-in that
   owns the flashlight (as `/product/haptics` in LaurelVibrator.cpp).
2. Control Center -> XPC `com.apple.coremedia.flashlight` [V: a MachService of the root's com.apple.mediaserverd.plist]
   -> mediaserverd FigFlashlight. The laurel root has `StartRecorderServer` false (topaz sweet-root-tweaks.py), so
   mediaserverd starts no capture server; the camera plug-in starts them all (6 of 6, [V log]).
3. Only with `LaurelFlashlight.driver` (CAMERA=0): it starts `FigFlashlightServerStart` alone, and FigFlashlight asks `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` (0x1a1f40c84, first word 0xa9bd57f6
   = `stp x22, x21, [sp, #-0x30]!` [V laurel cache UUID 8F970452-C9E3-3E88-B114-FEB1864BC9E0]); the plug-in gives
   FigFlashlight callers (return address in 0x1a20007b0-0x1a2000bdc, 0x1a1f3e540-0x1a1f3e668, 0x1a1fa9e70-0x1a1faa0f8)
   its own vendor -> device -> stream; `setProperty:"TorchLevel" value:0..1` writes `round(level * 100)` % to
   `/dev/laureltorch`.
4. Unknown messages to the plug-in's objects are answered nil and logged once (no exception in mediaserverd).

## Lines

```
LAUREL TORCH: on: PMI632 flash LED SID3 0xd300 (APID N, type 0x../0x.. rev 0x.., EN_LED 0x0 MOD_CTRL 0x.., STATUS2 0x0, boost VREG 0x..), LED1 torch 12.5 mA steps, 1..100 % = 12..150 mA (DT max 950 mA), auto-off 600 s, off at over-temperature or a fault; /dev/laureltorch after the root mount
LAUREL TORCH UI: on: /dev/laureltorch, IODeviceTree:/product/camera flash (Control Center button; mediaserverd NegroniCamera.driver -> TorchLevel)
LAUREL TORCH: first open of /dev/laureltorch by mediaserverd; start result: LAUREL TORCH: on: ...
LAUREL TORCH: first open: LAUREL TORCH UI: on: ...
LAUREL CAMERA: ios: the flashlight: this plug-in owns it: /dev/laureltorch: level=0 ma=0 code=0 lit=0 cap_ma=150 auto_off_s=600 faults=0 state=on reason=never lit
LAUREL CAMERA: ios: the flashlight at 850 of 1000 -> 85 % of the 150 mA cap
LAUREL TORCH: lit: 85 % = 125 mA (code 9) by mediaserverd
LAUREL CAMERA: ios: the flashlight at 0 of 1000 -> 0 % of the 150 mA cap
LAUREL TORCH: dark: off (request) (lit N ms)        (first 24 changes; faults and auto-off always)
LAUREL SPMI: on: ... users: pon keys battery haptic rtc torch; spmi errors ... torch 0, forced 0
```
Failure lines: `LAUREL CAMERA: ios: the flashlight: off: /dev/laureltorch does not open (errno N): see the LAUREL TORCH lines`,
`LAUREL CAMERA: ios: the flashlight at 850 of 1000 NOT TAKEN: /dev/laureltorch refused it (errno N): ...`, `LAUREL TORCH: off: torch=0`,
`... no SPMI APID ...`, `... owned by EE N ...`, `... TGR_CURRENT write did not read back ...`,
`LAUREL TORCH UI: off: no NegroniCamera.driver or LaurelFlashlight.driver in the root: no Control Center button`,
`LAUREL FLASHLIGHT: off: <why>` (a root with CAMERA=0).

## Test (a boot image with 2783 + a root with the new NegroniCamera.driver; the camera must still work)

1. Boot log: `LAUREL TORCH: first open of /dev/laureltorch by mediaserverd; start result: LAUREL TORCH: on: ...`, then
   `LAUREL CAMERA: ios: the flashlight: this plug-in owns it: ... state=on`. No `LAUREL FLASHLIGHT` line.
2. Control Center: tap the button: LED on, lines `the flashlight at 850 of 1000 -> 85 %`, `LAUREL TORCH: lit: 85 %`. Tap: off.
   Long press: the levels change the light.
3. Leave it on: after 600 s `LAUREL TORCH: dark: auto-off after 600 s`.
4. Camera app: picture as before; camera torch button, if iOS shows it: same path.
5. `scripts/net/ssh-phone.sh 'cat /dev/laureltorch'` -> `level=0 ... state=on`.
6. If the LED stays dark with `lit:` in the log: kernel side (SPMI sequence, boost VREG): see `reason=` and the `dark:` lines.

## Risks [I]

- The LED was not lit yet on the phone. The register map is the downstream v2 driver's; the flash APID must be EE 0 (Android writes it).
- MobileGestalt may cache `camera-flash`: a boot where the torch was off (or the root had no plug-in) can keep the
  button away until the MobileGestalt cache is rebuilt. `/product/camera` may also turn on other camera answers
  (Camera.app icon) [U].
- STATUS2 OTST bits at idle are taken as real-time [I from Linux calc_thermal_current_lim]; if they latch, the torch
  refuses to light (`over-temperature (OTST), not lit`) and the line shows the value.
- CAMERA=0 only: FigFlashlight may send a selector the stand-in objects do not know: answered nil and logged once.
