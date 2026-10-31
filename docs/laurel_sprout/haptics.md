# Vibration / haptics on the Mi A3 (laurel 2700)

Patch: `patches/laurel/xnu/2700-laurel-pmi632-haptics.patch` (range 2700-2799 is this area).
New files: `bsd/dev/laurel_haptic.c`, `iokit/Kernel/arm/LaurelVibrator.cpp`. Touched: `bsd/conf/files`
(after `topaz_redwood_audio.c`), `iokit/conf/files.arm64` (after `SweetBattery.cpp`),
`iokit/KernelConfigTables.cpp` (entry after `SweetBattery`). [V] = read in source, [I] = inference.

## Hardware [V]

- `external/laurel-kernel-los/arch/arm64/boot/dts/qcom/pmi632.dtsi:412-422`: `pmi632_vib`,
  `qcom,qpnp-vibrator-ldo`, SID 3 (`pmi632_3`), reg 0x5700, `qcom,vib-ldo-volt-uv = 3000000`,
  `qcom,disable-overdrive`. No laurel override (ginkgo, a sibling, sets 3.3 V).
- `drivers/leds/leds-qpnp-vibrator-ldo.c`: STATUS1 0x08 bit 7 VREG_READY; VSET_LB/UB 0x40/0x41 =
  `roundup(uV, 8000) / 1000` (mV, LE); EN_CTL 0x46 bit 7; range 1504..3544 mV; min play 50 ms, max 15 s;
  overdrive (when not disabled) = `min(2 * vmax, 3544 mV)` for 30 ms; enable -> poll VREG_READY 100 us
  steps, 1 ms, timeout -> disable.
- 3000 mV = VSET 0x0bb8; 3544 mV = 0x0dd8.

## SPMI [V code, I hardware]

Own lane in `laurel_haptic.c`, no shared state with `sweet_spmi.c` (area D battery reads, 2018 PON lane):
same arbiter bases as 2018 (core 0x1c40000, config 0x1c0a000, observer 0x3e00000 EE 0 0x80/APID, rw
0x1e00000 0x10000/APID), APID of PPID 0x357 from the map table (0x900 + 4n), owner (0x700 + 4n) must be
EE 0. Read = observer EXT_READL (cmd `1<<27 | off<<4 | n-1`, status +0x08, RDATA0 +0x18); write =
rw-channel EXT_WRITEL (WDATA0 +0x10, cmd `off<<4 | n-1`). Same command format as the 2018 PON write that
works on the phone. Each APID has its own command registers, so this lane and area D's lanes do not
race. Overlap to know: both files hard-code the arbiter bases; if area D moves them, change both.

## Motor policy

| What | Value | Why |
| --- | --- | --- |
| nominal | 3000 mV | DT vmax |
| overdrive | 3544 mV for 30 ms on a start from rest (off >= 60 ms) | Qualcomm's own default of this driver; an ERM spins up slowly and iOS taps are 3-20 ms [I]. Kill switch `laurel_haptic_od=0` |
| min on-time | 30 ms (overdrive on), 50 ms (off, = Linux) | a shorter pulse is not felt [I] |
| duty | heat += 30 % of on-time, -= 70 % of all time; cut at 4000 ms, resume at 2000 ms | 70 % sustainable forever (ringtone patterns 50-67 % [I]); continuous buzz about 13 s, then about 2.9 s rest |
| watchdog | thread call, 1 s, re-armed each motor-thread loop (<= 250 ms while on) | a stalled thread never leaves the motor on |
| failure | 3 failed enables or one SPMI timeout -> LDO off, feature off for the boot | no other feature depends on it |

No amplitude: ERM on an LDO, on/off only (lower voltages may not start the motor [I]).

## iOS paths

1. **"vibrator" IOService** (`LaurelVibrator`, port of negroni 0301; IOResources match). FigVibrator's
   legacy path (MobileGestalt closed-loop answer false) [V negroni docs/haptics-plan.md section 4]:
   `{hertz_millisecs = (state, ms, ...), repeat}` / CFNumber 0 = stop. Ringtone, alert, system-sound
   vibration. On steps call `laurel_haptic_vib(ms + 10)`; repeat at most 5 min.
2. **`/dev/redwood-haptic`** (0666, made after the root mount): the node that topaz
   `userland/audio/audio_plugin.c` `actuator_write()` opens (S16LE mono 48 kHz, Actuator output).
   2 ms blocks with peak > 256/32768 = on; runs < 10 ms apart merge; real-time stream clock from the
   write, at most 100 ms ahead.
3. **Closed-loop node** `IODeviceTree:/product/haptics {closed-loop 1, supports-3rd-party-haptics 1}`
   (negroni 0302, D22 values). Needed for CoreHaptics, UIFeedbackGenerator and keyboard taps (UIKit
   feedback level 2). Published by the kernel after the root mount **only if** the root has
   `/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver` and `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin`.
   Reason: with closed-loop on, FigVibrator also goes to `VirtualAudioDevice_Actuator`; without that
   device iOS plays no vibration at all [V negroni notes section 23]. Not in `scripts/laurel/mkadt.py` for
   the same reason. Kill switch `laurel_haptic_ui=0`.

Today [V scripts/laurel/root.sh, topaz sweet-root-tweaks.py]: the laurel root has no RedwoodAudio.driver
and topaz moves VirtualAudio.plugin to `HAL.disabled` (mediaserverd crash). So path 3 is off and only
path 1 works: ringtone/alert vibration yes, keyboard/UI taps no. Taps need the audio area (RedwoodAudio
plug-in in the root + VirtualAudio enabled). After that change, remove the MobileGestalt cache once
(`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`):
it may keep the old closed-loop answer.

## Log lines

```
LAUREL HAPTIC: on: PMI632 LDO vib SID3 0x5700 3000 mV (APID n, type 0x../0x.., VSET was .. mV, EN_CTL 0x.., STATUS1 0x..; overdrive 3544 mV 30 ms, tap >= 30 ms, duty <= 70 %, cut at 4000 ms of heat)
LAUREL VIBRATOR: on: published "vibrator" (FigVibrator hertz_millisecs)
LAUREL HAPTIC: /dev/redwood-haptic ready (S16LE mono 48000 Hz, 2 ms blocks, >256 of 32768 = on)
LAUREL HAPTIC UI: off: no /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver in the root: ...
LAUREL VIBRATOR: start: N steps (first X ms on, Y ms on in all), repeat R      (first 16 requests)
LAUREL HAPTIC: play N: X ms (overdrive start); heat H of 4000 ms               (first 24 plays, every cut)
LAUREL HAPTIC: off: <reason>                                                   (self-check or runtime failure)
```

## Test (coordinator, phone)

1. Boot; grep `LAUREL HAPTIC|LAUREL VIBRATOR`. Expect the `on:` line (if `off:`, the reason names the
   failed step: APID missing, owner not EE 0, read failed, VSET read-back).
2. Settings > Sounds & Haptics > Ringtone > Vibration > pick a pattern (preview vibrates). Expect
   `LAUREL VIBRATOR: start` and `LAUREL HAPTIC: play` lines and a felt buzz.
3. If no `LAUREL VIBRATOR: start`: mediaserverd did not take the IOKit path (MobileGestalt, sandbox) [I].
4. Kill switches to isolate: `laurel_haptic=0`, `laurel_haptic_od=0`, `laurel_haptic_ui=0`.
