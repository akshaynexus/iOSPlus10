# Mi A3 flashlight (torch): kernel 2770 + LaurelFlashlight.driver

Status (2026-11-01, branch t3/laurel-brightness-torch): built (kernel and plug-in). NOT BOOTED. Marks: [V] seen in a
source or tool output, [I] inference, [U] unknown.

## Parts

| Part | File | What |
|---|---|---|
| kernel driver | `bsd/dev/laurel_torch.c` (patch 2770) | PMI632 flash LED in torch mode, `/dev/laureltorch`, watch thread, auto-off, quiesce |
| IOKit service | `iokit/Kernel/arm/LaurelTorch.cpp` (2770) | `LaurelTorch` (IOResources match) starts the driver; publishes `IODeviceTree:/product/camera` `flash` |
| SPMI user | `sweet_spmi.c/.h` (2770) | user `SWEET_SPMI_TORCH` ("torch") of the one core (2710 rule) |
| halt/panic | `SweetPlatformExpert.cpp` (2770) | `laurel_torch_quiesce()` at halt, restart, panic begin / hold |
| mediaserverd | `userland/laurel/flashlight/` | `LaurelFlashlight.driver`: FigFlashlight vendor hook + FigFlashlight server start |
| root | `scripts/laurel/root-flashlight.sh` | installs the plug-in (root.sh calls it; `TORCH=0` skips) |

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

## iOS path [V: negroni's disassembly of 20H392, userland/flashlight/README.md; checked again on the laurel cache]

1. Button: `+[AVFlashlight hasFlashlight]` = `MGGetBoolAnswer("camera-flash")` = `IODeviceTree:/product/camera` has
   `flash`. `LaurelTorch.cpp` publishes it after the root mount, only when the driver is on and the root has
   `LaurelFlashlight.driver` (as `/product/haptics` in LaurelVibrator.cpp).
2. Control Center -> XPC `com.apple.coremedia.flashlight` [V: a MachService of the root's com.apple.mediaserverd.plist]
   -> mediaserverd FigFlashlight. The laurel root has `StartRecorderServer` false (topaz sweet-root-tweaks.py), so
   mediaserverd starts no capture server; the plug-in starts `FigFlashlightServerStart` (CMCapture) only.
3. FigFlashlight asks `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` (0x1a1f40c84, first word 0xa9bd57f6
   = `stp x22, x21, [sp, #-0x30]!` [V laurel cache UUID 8F970452-C9E3-3E88-B114-FEB1864BC9E0]); the plug-in gives
   FigFlashlight callers (return address in 0x1a20007b0-0x1a2000bdc, 0x1a1f3e540-0x1a1f3e668, 0x1a1fa9e70-0x1a1faa0f8)
   its own vendor -> device -> stream; `setProperty:"TorchLevel" value:0..1` writes `round(level * 100)` % to
   `/dev/laureltorch`.
4. Unknown messages to the plug-in's objects are answered nil and logged once (no exception in mediaserverd).

## Lines

```
LAUREL TORCH: on: PMI632 flash LED SID3 0xd300 (APID N, type 0x../0x.. rev 0x.., EN_LED 0x0 MOD_CTRL 0x.., STATUS2 0x0, boost VREG 0x..), LED1 torch 12.5 mA steps, 1..100 % = 12..150 mA (DT max 950 mA), auto-off 600 s, off at over-temperature or a fault; /dev/laureltorch after the root mount
LAUREL TORCH UI: on: /dev/laureltorch, IODeviceTree:/product/camera flash (Control Center button; mediaserverd LaurelFlashlight.driver -> FigFlashlight TorchLevel)
LAUREL FLASHLIGHT: on: FigFlashlight server started (com.apple.coremedia.flashlight), vendor hook in, /dev/laureltorch open: ...
LAUREL FLASHLIGHT: FigFlashlight asked for the capture device vendor: it gets the torch vendor (caller 0x1a2000a5c)
LAUREL FLASHLIGHT: TorchLevel 1.000 -> 100 %
LAUREL TORCH: lit: 100 % = 150 mA (code 11) by mediaserverd
LAUREL TORCH: dark: off (request) (lit N ms)        (first 24 changes; faults and auto-off always)
LAUREL SPMI: on: ... users: pon keys battery haptic rtc torch; spmi errors ... torch 0, forced 0
```
Off lines name the reason: `LAUREL TORCH: off: torch=0`, `... no SPMI APID ...`, `... owned by EE N ...`,
`... TGR_CURRENT write did not read back ...`, `LAUREL TORCH UI: off: no ... LaurelFlashlight ... in the root`,
`LAUREL FLASHLIGHT: off: <why>`.

## Test (after a boot image with 2770 + a root with the plug-in)

1. Boot log: `LAUREL TORCH: on:` and `LAUREL TORCH UI: on:`.
2. `scripts/net/ssh-phone.sh 'cat /dev/laureltorch'` -> `level=0 ... state=on reason=never lit`.
3. `echo 20 > /dev/laureltorch` (30 mA) -> LED on, `LAUREL TORCH: lit: 20 % = 30 mA (code 1) by sh`; `echo 0 >` -> off.
4. Control Center: the flashlight button is there; tap -> LED on (`TorchLevel 1.000 -> 100 %`); long press -> levels.
5. Leave it on: after 600 s `LAUREL TORCH: dark: auto-off after 600 s`.

## Risks [I]

- Not run on the phone. The register map is the downstream v2 driver's; the flash APID must be EE 0 (Android writes it).
- MobileGestalt may cache `camera-flash`: a boot where the torch was off (or the root had no plug-in) can keep the
  button away until the MobileGestalt cache is rebuilt. `/product/camera` may also turn on other camera answers
  (Camera.app icon) [U].
- STATUS2 OTST bits at idle are taken as real-time [I from Linux calc_thermal_current_lim]; if they latch, the torch
  refuses to light (`over-temperature (OTST), not lit`) and the line shows the value.
- FigFlashlight may send a selector the stand-in objects do not know: answered nil and logged once.
