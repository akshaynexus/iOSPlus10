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

2710: through the one SPMI core of `sweet_spmi.c` (one transaction lock and one channel map for every SPMI user;
docs/laurel_sprout/battery-power.md "SPMI: one core"). APID of PPID 0x357 from the core's map, owner must be EE 0, the
core maps its rw channel. Read = observer EXT_READL (cmd `1<<27 | off<<4 | n-1`, status +0x08, RDATA0 +0x18); write =
rw-channel EXT_WRITEL (WDATA0 +0x10, cmd `off<<4 | n-1`). Same command format as the 2018 PON write that works on the
phone. 2700 had its own lane and lock, with the claim "each APID has its own command registers, so the lanes do not
race": wrong [V boot 06:17: status 0x9 DROPPED and crossed RDATA between users without one lock]. The watchdog no longer
needs a try-lock: the core lock is held for one transaction only (interrupts off, <= ~1 ms).

## Motor policy

| What | Value | Why |
| --- | --- | --- |
| nominal | 3000 mV | DT vmax |
| overdrive | 3544 mV for 30 ms on a start from rest (off >= 60 ms) | Qualcomm's own default of this driver; an ERM spins up slowly and iOS taps are 3-20 ms [I]. Kill switch `laurel_haptic_od=0` |
| min on-time | 30 ms (overdrive on), 50 ms (off, = Linux) | a shorter pulse is not felt [I] |
| duty | heat += 30 % of on-time, -= 70 % of all time; cut at 4000 ms, resume at 2000 ms | 70 % sustainable forever (ringtone patterns 50-67 % [I]); continuous buzz about 13 s, then about 2.9 s rest |
| watchdog | thread call, 1 s, re-armed each motor-thread loop (<= 250 ms while on) | a stalled thread never leaves the motor on |
| failure | 3 failed enables or one SPMI timeout -> LDO off, feature off for the boot | no other feature depends on it |
| repeat cap | a repeating "vibrator" pattern stops 60 s after its start request when no new request comes | iOS ends a loop only with its own stop (see "Repeat" below); a ring lasts at most about 30 s before the network diverts the call (3GPP no-reply timer 5..30 s) [I]; 60 s = 2x margin. Kill switch `laurel_vib_cap=0` (old bound: 5 min) |
| key stop | a power or volume key press stops a running repeat (one-shot patterns run to their end) | iOS silences a ring with these keys; a lost iOS stop must not leave the motor on. Hook: `sweet_keys.c` -> `laurel_vibrator_key()` |

No amplitude: ERM on an LDO, on/off only (lower voltages may not start the motor [I]).

## iOS paths

1. **"vibrator" IOService** (`LaurelVibrator`, port of negroni 0301; IOResources match). FigVibrator's
   legacy path (MobileGestalt closed-loop answer false) [V negroni docs/haptics-plan.md section 4]:
   `{hertz_millisecs = (state, ms, ...), repeat}` / CFNumber 0 = stop. Ringtone, alert, system-sound
   vibration. On steps call `laurel_haptic_vib(ms + 10)`; a repeat ends at the iOS stop, at a power/volume
   key press, or 60 s after its request (section "Repeat").
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

## Repeat: the endless vibration of 2026-11-01 05:29

Seen on the phone (first full boot to SpringBoard; `logs/usblog-20261101-001446.txt`, `logs/laurel-boot-20261101-052311.log`) [V]:
`LAUREL VIBRATOR: stop` at 05:29:20; three power presses 05:29:41-43; `LAUREL VIBRATOR: start: 2 steps (first 400 ms on,
400 ms on in all), repeat 1` at 05:29:45 (AccessibilityUIServer exec in the same second); then 146 plays of 309-411 ms, one
every about 0.54 s, cut by the duty limit at 05:30:18, 05:30:45, 05:31:04; no other `LAUREL VIBRATOR` line until the reboot at
05:31:10. Calls 3..16 would have been logged, so iOS sent no request at all after the start.

iOS 16 20H392 MediaExperience (FigVibrator, unslid shared-cache addresses; the cache is in the Cryptex APFS
`~/op10-apple/20H392/087-86593-047.dmg`, read with `apfs-fuse`) [V disassembly]:

- Play (0x195a42a48, args total, period, on, client, intensity): when total > period it calls the IOKit start
  (0x195a42608) with `{hertz_millisecs = ({intensity}, on, false, period - on), repeat = true}`, sets "vibrating"
  (ctx+0x70) and arms a one-shot dispatch timer at `total` (0x195a42fc0-0x195a43004: CMTimeConvertScale to ns,
  dispatch_time, dispatch_source_set_timer(ctx+0x60, t, FOREVER, 0)). Else one [on, 0] step, repeat false.
- The timer handler (block invoke 0x195a940a8 -> 0x195a43b34) and FigVibratorStop (0x195a940dc) are the only callers
  of the IOKit stop (0x195a428b4), which sends ctx+0x28 = `CFNumberCreate(kCFNumberIntType, 0)` (0x195a93e60-0x195a93e74).
  Our parser takes that form (the 05:29:20 stop).
- The dictionary entry (0x195a94340) reads OnDuration/OffDuration/TotalDuration; with no TotalDuration it sets
  total = 0x4a237a00 = 2678400 s = 31 days (0x195a94448). So such a loop ends only when the iOS client calls
  FigVibratorStop.
- D22 `SystemSoundVibrationPatterns.plist`: on 0.4 / off 0.1 is only `Default` (TotalDuration 0.5 = one period, so it
  plays with repeat false). ToneLibrary has the strings `Looped`, `VibePattern`, `OnDuration`, `OffDuration` and no
  `TotalDuration` [V strings].

Root cause: iOS asked for an open-ended loop (on 400 / off 100 = the Default shape, without a total), and its client never sent
the stop. Our repeat logic ran it as asked (bound only 5 min). Excluded [V]: (a) a stop form we do not accept (iOS 16 has one
stop form, and it worked at 05:29:20); (b) the parse (2 steps, 400 on + 100 off = the 0.5 s play period in the log); (d) the
restart logic (it does what `repeat = true` says). Not known [I]: which client started it and why it did not stop it. Candidates:
the triple press of the side button (Accessibility Shortcut, or Emergency SOS where the region uses a triple press), or a
ToneLibrary alert whose stop waits for its sound to end (laurel has no working audio route yet). The next boot logs the
request kinds and the caller process (`request kind` lines).

Fix (2700, LaurelVibrator.cpp): the repeat cap (60 s after the request, kill switch `laurel_vib_cap=0`), the key stop (power,
volume up, volume down), one log line per request shape. The duty limit stays as the motor's own protection.

## Log lines

```
LAUREL HAPTIC: on: PMI632 LDO vib SID3 0x5700 3000 mV (APID n, type 0x../0x.., VSET was .. mV, EN_CTL 0x.., STATUS1 0x..; overdrive 3544 mV 30 ms, tap >= 30 ms, duty <= 70 %, cut at 4000 ms of heat)
LAUREL VIBRATOR: on: published "vibrator" (FigVibrator hertz_millisecs; a repeat ends after 60 s without a new request, or at a power/volume key press)
LAUREL HAPTIC: /dev/redwood-haptic ready (S16LE mono 48000 Hz, 2 ms blocks, >256 of 32768 = on)
LAUREL HAPTIC UI: off: no /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver in the root: ...
LAUREL VIBRATOR: request kind K from PROC: SHAPE                              (once per request shape, 16 kinds)
LAUREL VIBRATOR: start: N steps (first X ms on, Y ms on of Z ms), repeat R[ (until iOS stops it, a key press, or the cap)]   (first 16 requests)
LAUREL VIBRATOR: stop[ (a pattern was running)]                                (first 16 requests)
LAUREL VIBRATOR: repeat stopped: 60 s and no new request (iOS sent no stop; C cycles of Z ms)
LAUREL VIBRATOR: repeat stopped by the power|volume up|volume down key after T ms (as iOS silences a ring)
LAUREL HAPTIC: play N: X ms (overdrive start); heat H of 4000 ms               (first 24 plays, every cut)
LAUREL HAPTIC: off: <reason>                                                   (self-check or runtime failure)
```

## Test (coordinator, phone)

1. Boot; grep `LAUREL HAPTIC|LAUREL VIBRATOR`. Expect the `on:` line (if `off:`, the reason names the
   failed step: APID missing, owner not EE 0, read failed, VSET read-back).
2. Settings > Sounds & Haptics > Ringtone > Vibration > pick a pattern (preview vibrates). Expect
   `LAUREL VIBRATOR: start` and `LAUREL HAPTIC: play` lines and a felt buzz.
3. If no `LAUREL VIBRATOR: start`: mediaserverd did not take the IOKit path (MobileGestalt, sandbox) [I].
4. Kill switches to isolate: `laurel_haptic=0`, `laurel_haptic_od=0`, `laurel_haptic_ui=0`, `laurel_vib_cap=0`.
5. Endless-vibration check: repeat the 05:29 steps (boot, wake with the power key, three presses). Expect the `request kind`
   lines (the stop shape `N0` and the start shape `{hertz_millisecs=[...],repeat=B:true}` with the caller). A repeat must end
   with `repeat stopped by the ... key` at the next key press, or with `repeat stopped: 60 s` at the latest.
