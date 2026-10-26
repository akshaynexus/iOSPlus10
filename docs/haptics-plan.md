# Vibration / haptics plan (2026-10-26, haptics agent; patches 0300-0301)

Marks: **[V]** seen in source, DT, ADT, shared cache or build log. **[I]** inference.

Status: 0300 (direct play + boot proof) and 0301 (iOS "vibrator" IOService) built, **not run on the
phone** (phone off). Image `out/ios16-hap` = config boot-args + `negronihap=1`.

## 1. Hardware

- [V] `out/live.dts`: `qcom,hv-haptics@f000` under `qcom,pm8350b@3` (SPMI bus 0, SID 3),
  `status = "ok"`, `reg = <0xf000 0xf100 0xf200>` (HAP_CFG, HAP_PTN, HAP_BOOST), irq "fifo-empty".
  Properties: `qcom,vmax-mv` 1680, `qcom,lra-period-us` 5882 (170 Hz LRA), `qcom,drv-sig-shape` 1
  (sine), `qcom,brake-mode` 1, `qcom,fifo-vmax-mv` 8700, `qcom,vibrator-type` 8151 (= `VIBRATOR_TYPE_SLA0815`
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
- Known gaps versus Linux qcom-hv-haptics.c [I: effect not measured]:
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
