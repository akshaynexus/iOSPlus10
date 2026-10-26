# Vibration / haptics plan (2026-10-26, haptics agent; patches 0300-0301)

Marks: **[V]** seen in source, DT, ADT, shared cache or build log. **[I]** inference.

Status: 0300 (direct play + boot proof) and 0301 (iOS "vibrator" IOService) built, **not run on the
phone** (phone off). Image `out/ios16-hap` = config boot-args + `negronihap=1`.
Update (evening): 0302 (UI haptics: closed-loop node + `/dev/negroni-haptic` from the NegroniAudio "Actuator"
device) and 0303 (closed-loop brake + hBoost-ready wait) built into `out/ios16-hap2`: section 8.

## 1. Hardware

- [V] `out/live.dts`: `qcom,hv-haptics@f000` under `qcom,pm8350b@3` (SPMI bus 0, SID 3),
  `status = "ok"`, `reg = <0xf000 0xf100 0xf200>` (HAP_CFG, HAP_PTN, HAP_BOOST), irq "fifo-empty".
  Properties: `qcom,vmax-mv` 1680, `qcom,lra-period-us` 5882 (170 Hz LRA), `qcom,drv-sig-shape` 1
  (sine), `qcom,brake-mode` 1 (CL_BRAKE), **`qcom,brake-pattern = [ff 3f 1f]`** and `qcom,brake-sig-shape` 1
  (live.dts:13110-13113; the first version of this file left the pattern out), `qcom,fifo-vmax-mv` 8700, `qcom,vibrator-type` 8151 (= `VIBRATOR_TYPE_SLA0815`
  in the OnePlus driver), `nvmem = <hap_cfg_sdam>` = PMK8350 `sdam@9d00` (SID 0),
  `nvmem-cells = <hap_cl_brake>` = sdam@7100 offset 0x7c, `qcom,pbs-client` = PM8350B `pbs@1900`.
- [V] `swr_haptics@f0170220` (`qcom,pm8350b-swr-haptics`) under the LPASS SoundWire RX master: the same
  block, fed by an audio stream (the "SWR" pattern source). Android plays rich effects that way; it needs
  the LPASS/ADSP audio path. Not used here.
- [V] No I2C LRA: no `awinic,*`, `aw869*`, `oplus,haptic` node in live.dts. The OnePlus module tree
  (out/src/op-modules) has only `vendor/oplus/kernel/dfr/fault_inject/vibrator/` (fault injection) and
  `audio-kernel/asoc/codecs/swr-haptics.c` (path listed, not checked out).

## 2. Linux driver sequence (out/src/op-kernel e9da592, drivers/input/misc/qcom-hv-haptics.c)

Constant effect = DIRECT_PLAY (`haptics_load_constant_effect` 2134, `haptics_playback` 2688):

| Step | Register (SID 3 unless noted) | Linux |
|---|---|---|
| VMAX = mV / 50 | 0xf048 | `haptics_set_vmax_mv` 1271 (`VMAX_STEP_MV` 50, line 112) |
| amplitude 0..255 | 0xf126 HAP_PTN DIRECT_PLAY | `haptics_set_direct_play` 1349 |
| auto-resonance off (OPLUS build) | 0xf063 bit 7 | `haptics_enable_autores(chip, false)` 2194 |
| clear faults | 0xf066 = 0x07 | `haptics_enable_play` 1612 |
| FORCE_VREG_RDY = 0 (first play, no kept hBoost) | 0xf068 bit 0 | `haptics_open_loop_drive_config` 1540 |
| PLAY_EN \| source DIRECT_PLAY (1) | 0xf04c = 0x81 | `haptics_enable_play` 1629 |
| hBoost on via PBS | SID 0 SDAM 0x9d42 = 1, 0x9de5 = 1 | `haptics_boost_vreg_enable` 1366 |
| stop | 0xf04c = 0x01 | `haptics_enable_play(false)` |
| hBoost off 2 s later | SDAM 0x9d42 = 2, 0x9de5 = 1 | `haptics_disable_hbst_timer` 6054 |
| module enable | 0xf046 bit 7 | `haptics_module_enable` 2008 (probe does not write it; resume does, 6354) |
| T_LRA open loop | 0xf05c/0xf05d = us / 5 (x 1024/1000 when CAL_EN 0xf072 bits 3:2 = 1) | 2853, 986 |

## 3. Patch 0300 (`bsd/dev/negroni_haptic.c`, `.h`)

- `negronihap=0` (default): nothing. `=1`: census + APID owner log + a 300 ms buzz at strength 255 (the
  proof). `=2`: the same without the buzz. `negronihap_force=1` writes even when another EE owns the APIDs;
  `negronihap_mv=N` VMAX (default 1680, 500..3600); `negronihap_pbs=0` never writes the SDAM.
- Reads: shared arbiter mapping (`negroni_spmi_arbiter`, 0270) + `sk_read8`. Owners from the cnfg table
  (as `negroni_spmi.c`). Writes: own channel windows `0x0c500000 + 0x1000 * APID` for PPIDs 0x3f0, 0x3f1,
  0x3f2, 0x09d (4 maps of 0x1000 bytes; each map takes one 16 KiB kernel page of io_submap, so 64 KiB
  in total [V notes section 20: round_page with 16 KiB pages]; never unmapped).
- The writes stay off when HAP_CFG/PTN/BOOST are not all owned by EE 0 (log line "not all owned by EE 0").
- Review fixes (2026-10-26): PLAY_EN is written only when the whole setup chain succeeded; `nh_playing`
  follows the SPMI_PLAY write alone, so the stop timer is armed whenever PLAY_EN may be set (a failed PLAY_EN
  write is followed by SPMI_PLAY = 0x01). Refused-write log lines are capped at 16.
- Known gaps versus Linux qcom-hv-haptics.c [I: effect not measured] (all three closed by 0302/0303, section 8):
  - no BRAKE_EN in SPMI_PLAY and no brake pattern: the LRA rings down by itself after stop (a soft tail);
  - no `haptics_wait_hboost_ready` poll (Linux 1436: up to 100 x 200 us = 20 ms for HBST VREG_EN / STATUS4):
    the first ms of a play can run before hBoost is up;
  - no CAL_EN RC-clock toggle when FORCE_VREG_RDY is set (Linux 1555-1575): we never set FORCE_VREG_RDY on a
    first play, but a play within 2 s of the last one (hBoost kept on) sets it without the toggle.
- API: `int negroni_haptic_play(uint32_t ms, uint32_t strength)`: returns at once; a thread call stops the
  motor after ms; a new call while playing changes the amplitude and the stop time; ms 0 or strength 0 stops.
  `bool negroni_haptic_ready(void)`.
- Proof lines to look for in the usblog / serial log:
  ```
  NEGRONI HAPTIC: HAP_CFG 0xf000 PPID 0x3f0: APID <n>, owner EE <e>     (x4, the SDAM too)
  NEGRONI HAPTIC: HAP_CFG rev ... type ... subtype ..., HAP_PTN rev2 ..., HAP_BOOST rev ...
  NEGRONI HAPTIC: init: EN_CTL ... VMAX ... SPMI_PLAY ...
  NEGRONI HAPTIC: ready (negronihap=1, vmax 1680 mV)
  NEGRONI HAPTIC: proof: 300 ms direct-play buzz, strength 255
  NEGRONI HAPTIC: play 300 ms strength 255: rc 0
  NEGRONI HAPTIC: playing +100 ms: ... SPMI_PLAY 0x81 ... HBST VREG_EN ...
  NEGRONI HAPTIC: stopped +500 ms: ... SPMI_PLAY 0x01 ...
  NEGRONI HAPTIC: hBoost off +2.7 s: ...
  ```
  Expected [I]: owner EE 0 for SID 3 0xf0-0xf2 (the HLOS DT owns the haptics node). If the owner is not 0,
  the reads give 0xff and no write is made. If the log says "rc 0" but nothing buzzes: try
  `negronihap_mv=2500`, then check `HBST VREG_EN` bit 7 in the "playing" line (hBoost did not start).

## 4. iOS 16 (20H392) path

Addresses are unslid shared-cache vaddrs (out/dsc/cache/dyld_shared_cache_arm64, `ipsw dyld`).

- [V] System-sound vibration (AudioServicesPlaySystemSound(4095), ring/alert patterns): MediaExperience
  `_CMSessionMgrVibrateForSystemSoundWithOptions` 0x195ad742c -> FigVibrator.
- [V] `_FigVibratorInitialize` 0x195a93b3c: dlopen `AudioToolbox.framework/libVibeSynthEngine.dylib`, call
  `VibeSynthEngineHasHardwareSupport` (0x1f3eb3bfc). True -> VibeSynth (audio HAL). False ->
  `IOServiceNameMatching("vibrator")` (string 0x195b0e295, call 0x195a93d04).
- [V] `VibeSynthEngineHasHardwareSupport`: `ProductSupportsClosedLoopHaptics()` (MobileGestalt key
  `gqDnklGQnpv5ilgh5uHckw`, libAudioToolboxUtility 0x1a5ed4af8) nonzero -> "Using New Unified Haptic/Vibe
  Engine", returns 1. Zero -> "Using Legacy Vibe Engine", returns whether a HAL audio device exists
  (`CAHALAudioSystemObject::GetAudioDeviceForUID` 0x1f3eb3c44; the UID was not read).
- [V] CoreHaptics / AVHapticPlayer / UIKit feedback use the same closed-loop answer (`sHapticsSupported`,
  0x1a0a4d36c) and play on the HAL device `VirtualAudioDevice_Actuator` (0x1a0aa9c6c). On a real D22 that
  is the CS42L75 codec "Actuator" stream (D22 ADT: `audio-codec` `audio-control,cs42l75`,
  `function-haptic_master`, `mca5a/audio-haptic` `audio-data,actuator`, `/product/haptics closed-loop = 1`).
  No haptic IOUserClient with selectors exists in the cache [V by string search].
- [V] Legacy IOKit path (FVIOKit_*, 0x195a42410-0x195a43b34), `IORegistryEntrySetCFProperties(service, obj)`,
  return value ignored:
  - start (0x195a42608): `{ "hertz_millisecs" = ( {"intensity" = SInt32 (float * 65536)}, on_ms, false,
    off_ms ), "repeat" = bool }`
  - pattern (0x195a427dc): `hertz_millisecs` from the caller's VibePattern, `repeat` = false
  - stop (0x195a428b4): a bare CFNumber 0
- [V] Our ADT (`out/ios16/negroni.adt`, mkadt.py) has **no** `/product/haptics` node (strings of the ADT:
  no "haptics"/"closed-loop"). [I] So the closed-loop answer is false on our phone, and with no codec HAL
  device the legacy check returns false: FigVibrator uses the IOKit "vibrator" service. Not proven:
  MobileGestalt may have a per-product default.
- [I] Consequence: with 0301, system-sound / ringtone / alert vibration can work. CoreHaptics,
  UIFeedbackGenerator (keyboard and UI taps) stay silent: they need the closed-loop Actuator HAL device.
- Other MobileGestalt keys [V names, I use]: `ProductSupportsVibrator` `/9luHerXthRoPoNt/PVkTg`
  (0x1a5ee1a90), `ProductSupportsHaptics` `cBy4BcYs5YWtFHbBpt4C6A` (0x1a5ee1a9c).

## 5. Patch 0301 (`iokit/Kernel/arm/NegroniVibrator.cpp`)

- Personality on IOResources (KernelConfigTables). `start` only with `negronihap >= 1` and `negronivib != 0`
  (default 1); `setName("vibrator")`, `registerService()`.
- `setProperties`: OSNumber -> stop. OSDictionary with `hertz_millisecs` OSArray -> pairs (state, ms):
  state = dictionary with `intensity` (strength = intensity * 255 / 65536), true (255) or false (off).
  At most 64 steps, 10 s per step; `repeat` loops for at most 5 min. Steps run on a work loop timer; an on
  step calls `negroni_haptic_play(ms + 20, strength)`.
- Log lines: `NEGRONI VIBRATOR: published "vibrator" (haptics ...)`, `NEGRONI VIBRATOR: start: N steps
  (first X ms strength S), repeat R`, `NEGRONI VIBRATOR: stop`.

## 6. Test plan (owner approval needed for the `boot_a` write)

1. `fastboot boot out/ios16-hap/boot_a.img` (or flash `boot_a` after approval). Watch the usblog for the
   section 3 lines; feel for the 300 ms buzz about 1-2 s after the UFS root mounts.
2. With iOS up: `ioreg -n vibrator` (on the phone) shows the service. Trigger a vibration: Settings >
   Sounds > Ringtone > Vibration (preview), or a small tool that calls `AudioServicesPlaySystemSound(4095)`.
   Expect `NEGRONI VIBRATOR: start` lines. If none: mediaserverd did not take the IOKit path (check its log
   for "Using Legacy Vibe Engine" / "Using New Unified") or its sandbox denied the property set.
3. Next for UI haptics (large): a `VirtualAudioDevice_Actuator` HAL device (audio plug-in that turns the
   actuator PCM stream into envelope -> `negroni_haptic_play` amplitude updates, or the FIFO mode of the
   PM8350B block), and `/product/haptics closed-loop = 1` only after that exists.

## 7. Build (2026-10-26)

- [V] `hap-kernel` job: full patch set (all patches/xnu incl. 0300, 0301; only the 4 usual dxb skips), kernel
  `out/kernel/local-20261026-072436/kernel.development.negroni`, sha256
  `0f22dbf4890705dcc6263f7024c8fc5c60915d5496c434a3e43f90440412c8fd`; 20 `NEGRONI HAPTIC`/`NEGRONI VIBRATOR`
  strings; the `NegroniVibrator` personality is in the kernel's config table. No warnings in the two new files
  except the tree-wide declaration-after-statement one. Rebuilt after the review fixes (logs/hap-kernel.log).
- [V] Image `out/ios16-hap` (config boot-args + `negronihap=1`): boot_a.img sha256
  `99a1123a3119214b39a6af64961aa73ab081cb59df9e9442e46c3c8cc9b7997c`, vendor_boot_a.img `c29329ee...`,
  negroni.adt `fd837f16...` (`out/ios16-hap/SHA256SUMS`). Not flashed, not booted.

## 8. UI haptics: patches 0302-0303 + NegroniAudio Actuator (2026-10-26 evening, build-only)

### 8.1 How iOS 16 turns a feedback into hardware [V 20H392 cache, unslid addresses]

| Step | Where | Fact |
|---|---|---|
| UIKit level | `-[UIDevice(_UIFeedbackEngineSupport) _feedbackSupportLevel]` 0x1890dc6d8, block 0x189255318 | 2 if `+[CHHapticEngine supports1stPartyHaptics]`, else `MGGetBoolAnswer("cBy4BcYs5YWtFHbBpt4C6A")` (DeviceSupportsHaptics: 0 or 1). Internal pref `DisableLevel2Feedback` |
| Level needed | `-[_UIImpactFeedbackGeneratorConfiguration requiredSupportLevel]` 0x1890dd1e4 | `mov w0, #2`: impact (and the keyboard) need level 2. Level 1 = `_UIFeedbackSystemSoundEngine` (system sounds 1519-1521), not enough |
| CoreHaptics | `+[CHHapticEngine supports1stPartyHaptics]` 0x1af54fd4c -> `supportsHapticServer` 0x1af588880 -> `+[AVHapticPlayer supportsHaptics]` 0x1af58e924, block 0x1af58e964 | `PlatformUtilities_iOS::ProductSupportsClosedLoopHaptics()` 0x1af56cbb0 = `MGGetBoolAnswer("gqDnklGQnpv5ilgh5uHckw")` |
| MobileGestalt | libMobileGestalt key table (extracted dylib, entries {key, handler}): `gqDnklGQnpv5ilgh5uHckw` -> 0x19c564a9c, `cBy4BcYs5YWtFHbBpt4C6A` -> 0x19c576454 | the key = base64(md5("MGCopyAnswer" + name))[:22]: **DeviceSupportsClosedLoopHaptics** = `IODeviceTree:/product/haptics` property `closed-loop` (obfuscated name `XKpK5v7PGzbe7igjloNBpQ` = md5 of "closed-loop"); **DeviceSupportsHaptics** = `IODeviceTree:/product` + `haptics` (`6S9CvPHPtzHQqKudHSfsag`), the child node [I: the D22 /product has no "haptics" property, only the child] |
| D22 ADT | external/slop/research/ipsw-x/d22ap.adt `/product/haptics` | `closed-loop` = 01000000, `supports-3rd-party-haptics` = 01000000. Our negroni.adt `/product` has no children [V] |
| Haptic server | launchd plist com.apple.mediaserverd.plist: MachService `com.apple.audio.hapticd` | AVHapticServer (AudioToolbox, `AVHapticServer.mm`) runs in **mediaserverd** |
| HAL device | `VirtualAudioDevice_Actuator` (AudioToolbox 0x1a0aa9c6c, MediaExperience, libVibeSynthEngine) | made by VirtualAudio.plugin (`Device_Actuator_Aspen.cpp`, `VAD_Actuator`, `Creating Actuator Port`, `Could not find actuator port after 8 seconds`) on top of the physical HAL device with UID **"Actuator"**: NegroniAudio.driver has it (HackiOS design) |
| Waveforms | root `/Library/Audio/Tunings/D22/Haptics/*.wav` (read with the hard-link fix of scripts/audio/hfs-extract.py) | 48 kHz mono S16 taps: MicroTap 3.6-10.8 ms, MiniTap 4.7-16.9 ms, FullTap 7.5-28.6 ms active, peak 1.0 FS; Keyboard-Key/Delete/Modifier.wav 44.1 kHz, **peak 0.10 FS, 3.2-6.8 ms active**; hapticengineconfig.plist `BaseSineFrequency` 145 |
| Keyboard | UIKitCore `CHHapticPatternLibraryKeyKeyboardInputText`, `...Deletion`, `...Other` | the keyboard plays CoreHaptics library patterns: same server, same Actuator. iOS 16 setting: Settings > Sounds & Haptics > Keyboard Feedback > Haptic [I: off by default] |
| Ringtone/alerts | `VibeSynthEngineHasHardwareSupport` (section 4) | with closed-loop true: "New Unified Haptic/Vibe Engine" (HapticServerManager_VibeEngine*): vibration patterns also go to the Actuator, not to 0301 |

HackiOS (external/hackios-xnu-kernel bsd/dev/redwood_haptic.c, hackios-xnu-userland audio_plugin.c, MIT) used the
same chain on the POCO X5 (D22 identity, iOS 16.5): mkidentity.py copies `/product/haptics`; the plug-in writes the
Actuator samples to `/dev/redwood-haptic`. Their source comment [V text, I result]: tap peaks 1000..33000 of 32768,
vibration ~17000; strength proportional to the peak was not felt, so a floor of 5/8 and full from 1/3 scale.

### 8.2 What was built

- **0302** (`bsd/dev/negroni_haptic_ui.c`, new; `NegroniVibrator.cpp`; `negroni_haptic.c`; conf line anchored after
  `negroni_rtc.c`, no collision with 0310/0330/0350). `negronihap_ui=1` (needs `negronihap=1|2`):
  - `NegroniVibrator::start` adds `IODeviceTree:/product/haptics` {`name`, `closed-loop` = 1,
    `supports-3rd-party-haptics` = 1} (attachToParent in gIODTPlane), before its own negronivib check. If the ADT has the
    node it is kept.
  - `/dev/negroni-haptic` (0666): write S16LE mono 48 kHz. 2 ms blocks (96 frames) -> block peak -> queue (latency cap
    96 ms). A kernel thread plays the queue in real time: envelope = max of the last 4 blocks (8 ms, longer than one
    145-300 Hz period), strength = 0 below 256, `negronihap_uifloor` (160) .. 255 linear up to 1/3 FS, then 255;
    `negroni_haptic_play(40 ms, s)` on a change of >= 8 or every 16 ms (a stalled thread stops the motor in 40 ms);
    an onset plays at least `negronihap_tapms` (20 ms = 3.4 LRA periods; Keyboard-Key.wav is only 3.2 ms); a late
    write holds the level 12 ms; a play is cut at 5 s and the motor rests 1 s. Idle: the thread sleeps on an event.
  - The Linux CAL_EN RC-clock toggle (1555-1575) when a play sets FORCE_VREG_RDY (hBoost kept on: the common case
    when typing).
- **0303** (`negroni_haptic.c`): closed-loop brake (BRAKE_MODE_CFG 0x50 = 0x41 under mask 0xcf; HAP_PTN 0x70..0x77 =
  ff 3f 1f 00 00 00 00 00; SPMI_PLAY play 0x89, stop 0x09; `negronihap_brake=0` = the 0300 behaviour), and the
  hBoost-ready wait (100 x 200 us while VREG_EN or STATUS4 bit 0 says busy; open loop = ready; skipped when hBoost
  is kept on, as Linux). Not done: the CL-brake SDAM store (Linux `haptics_store_cl_brake_settings`); the PMIC keeps
  Android's CL brake registers 0x51-0x53 over an AP reboot [I].
- **NegroniAudio.driver** (`userland/audio/NegroniAudio.c`, ABI `userland/audio/negroni_haptic.h`): Actuator WriteMix
  -> lock-free SPSC ring (16384 frames) -> "haptic writer" thread (started at the Actuator's first StartIO, joined at
  the last StopIO) -> `/dev/negroni-haptic`. The I/O thread makes no system call. Only sound and the 20 ms after it
  are copied; silence costs nothing. The writer polls every 2 ms for 500 ms after sound, else every 8 ms. Open
  failure: dropped, retry every 2 s, logged once per change. Host test (`userland/audio/build.sh`): 29280 frames in,
  1440 sent (480 tap + 960 tail), 27840 silent not sent, FIFO got the same 1440 frames: PASS.
- **Why not FIFO mode**: the FIFO path (Linux `haptics_set_fifo`, the fifo-empty IRQ, refill from a thread at the
  play rate, the per-revision FIFO sizes) is several hundred lines and needs the IRQ or a fast poll; the direct-play
  path is not run on the phone yet. The envelope gives the felt result of a tap (an LRA at 170 Hz cannot follow a
  145-300 Hz carrier anyway). FIFO stays the next step if taps feel too uniform.

### 8.3 Proof lines (usblog) and test

```
NEGRONI HAPTIC: closed-loop brake (pattern ff 3f 1f): on
NEGRONI HAPTIC UI: /dev/negroni-haptic ready: S16LE mono 48000 Hz, 2 ms blocks, tap >= 20 ms, floor 160, cut at 5000 ms
NEGRONI HAPTIC UI: IODeviceTree:/product/haptics closed-loop = 1, supports-3rd-party-haptics = 1: published (...)
NegroniAudio: Actuator starts (haptic writer thread runs)            (mediaserverd stderr, if it reaches the log)
NegroniAudio: /dev/negroni-haptic open: the Actuator (haptics) goes to the motor
NegroniAudio: the Actuator plays: N frames to the motor, peak P of 32768
NEGRONI HAPTIC UI: play 1: 20 ms, peak P of 32768, strength S (last S); F frames in, 0 blocks dropped
```

1. Root: `userland/audio/build.sh`, then `scripts/haptics/phone-haptics.sh push` on the running phone (or a root build
   with `HAPTICS=1`). It removes the MobileGestalt cache (it may hold closed-loop = false).
2. Boot `out/ios16-hap2` (owner approval for `boot_a`).
3. Feel: Settings switches, long press on an icon, pull-to-refresh, Control Center; keyboard after turning on
   Settings > Sounds & Haptics > Keyboard Feedback > Haptic; ringtone preview in Settings > Sounds & Haptics.
4. If nothing: no `Actuator starts` line = VirtualAudio did not make VirtualAudioDevice_Actuator (look for `Could not
   find actuator port`), or MobileGestalt still answers false (cache). `peak` lines but no feel: `negronihap_mv=2500`,
   `negronihap_uifloor=220`, `negronihap_tapms=30`; `negronihap_uilog=N` = log the first N plays (default 24).

Risks [I]: VirtualAudio may want an "ActuatorIV" (current/voltage sense) input for closed loop (HackiOS ran without it);
with closed-loop on and no working Actuator chain, ringtone vibration is lost too (0301 is no longer used): boot without
`negronihap_ui` and clear the MobileGestalt cache to go back; hBoost stays on 2 s after each tap (battery while typing).

