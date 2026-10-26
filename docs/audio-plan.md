# Audio plan (iOS 16.7.16 on the NE2211, SM8450)

Status date: 2026-10-26 (evening). Audio does not work yet. Nothing in this plan ran on the phone yet except ADSP step 1.
Newest work: section "Implemented 2026-10-26 evening: patches 0244-0248".

Marks: **[V]** verified in code, DT, firmware or logs. **[I]** inference. **[U]** unknown.

Short source names below: `AK` = `out/src/op-modules/vendor/qcom/opensource/audio-kernel`,
`TFA` = `out/src/op-modules/vendor/oplus/kernel/audio/asoc/codecs/tfa98xx-v6`, `ML` = `out/src/linux`
(mainline 5b0764a), `SPF` = `out/src/audioreach-graphservices/spf/api`, `AS` = `out/audio-src`
(stock vendor/odm files, git-ignored). `scripts/audio/fetch-sources.sh` and
`scripts/audio/extract-vendor-audio.sh` make them; `out/src/COMMITS.txt` has the commits.

## Summary

The audio path has five stages. Each stage has its own boot-arg and log prefix, and each stage
is off by default.

| Stage | What | State | Effort |
|---|---|---|---|
| 0 | mediaserverd stops aborting: HAL plug-in `NegroniAudio.driver` with "Speaker"/"Hawking"/"Actuator"/"Codec", samples dropped. **XPC-misuse crash fix**: BTAudioHALPlugin moved to `HAL.disabled` (its factory sent XPC to absent bluetoothd) | **built, host-tested, on the live root; XPC fix added** (`userland/audio/`, root hook `AUDIO=1`; `scripts/audio/phone-audio.sh`) | phone test |
| a | ADSP firmware load + start (PAS id 1), SMP2P ready, **GLINK up (step 9)** | **code done, builds, untested** (patches 0240/0242, `negroniadsp=1`) | 1-3 days of tests |
| b | GLINK + QRTR + GPR, AudioReach graph for the speaker (PRM clock, **TERT MI2S I2S sink**), shared memory | **code done, builds, untested** (patch 0243, `negroniadsp_step=10..15`) | 2-3 weeks of tests, highest risk |
| c | 2x TFA9874 init over I2C (register writes only), I2S slave; speaker guard; test tone; earpiece route | **code done, builds, untested** (patches 0244-0246, `negroniaudio_amp=1`, `negroniaudio_tone=1`) | phone test |
| d | kernel `/dev/negroni-audio` + the stage 0 plug-in writes to it | **code done in stage (b) step 15 (patch 0243); the plug-in stage 1 (ring + writer thread) is built** (ABI in `userland/audio/negroni_audio.h`) | 2-4 days |

The model is HackiOS (`external/hackios-xnu-kernel`, `external/hackios-xnu-userland`). HackiOS plays
iOS 16.5 sound through the speakers of an SM7325 phone with an iPhone X identity (the same identity
as ours, D22). Its chain is: AudioServerPlugIn in mediaserverd -> `/dev/redwood-audio` -> kernel
sink -> ADSP. Its ADSP start (SMEM, SMP2P, GLINK, QRTR) applies to SM8450 with other numbers. Its
audio services layer (APR: AFE/ADM/ASM) does not apply: SM8450 uses AudioReach (GPR).

## Facts

| Item | Value | Source |
|---|---|---|
| Audio DSP | `remoteproc-adsp@03000000`, `qcom,waipio-adsp-pas`, PAS id 1 | live DT [V] |
| ADSP carveout | **0x85700000, size 0x2800000 (40 MiB)**. The node name says `adsp_region@85e00000`; mainline uses 0x85e00000/0x2100000, which is too small for this image. OnePlus moved `video_region@85700000` to 0x9fd00000 | live DT `reserved-memory` [V] |
| Mu memory map | "PIL Reserved" 0x85200000 + 0x1C200000 covers the carveout; XNU RAM starts at 0x841000000 | `negroniPkg` MemoryMapLib [V] |
| ADSP firmware | `image/adsp.mdt` + `adsp.b00`-`b25` (no `b24`: BSS), 18 MiB, ELF32, 26 program headers, load 0x86300000-0x88b00000 (40.0 MiB), relocatable, hash segment 25 packed after the headers in the .mdt | `scripts/audio/extract-adsp-fw.sh` on the OTA modem image [V] |
| servreg domains | `adspr.jsn` msm/adsp/root_pd; `adspua.jsn` msm/adsp/audio_pd with service avs/audio; `battmgr.jsn` charger PD | modem image [V] |
| Rails | cx = `lcx.lvl`, mx = `lmx.lvl`, both level 384 (= TURBO) while it boots. Mainline votes INT_MAX | live DT `cx-uV-uA <0x180 0>` [V] |
| SMP2P | `qcom,smp2p-adsp`: smem items <443 429> (in, out), local pid 0, remote pid 2; IPCC client 3 signal 2; slave-kernel bits fatal 0, ready 1, handover 2, stop-ack 3, shutdown-ack 7 | live DT [V] |
| GLINK | edge pid 2, IPCC client 3 signal 0, channels `IPCRTR` (QRTR), `adsp_apps` (GPR), `PMIC_RTR_ADSP_APPS` (charger), `fastrpcglink-apps-dsp`. Intents: `adsp_apps` 20 x 512 B; `IPCRTR` 5 x 0x800 + 3 x 0x2000 + 2 x 0x4400 | live DT :6328, :6350 [V] |
| GPR ports | ADSP side (destinations): APM 1, PRM 2, AMDB 3, VCPM 4. Domains: MODEM 1, ADSP 2, APPS 3. The DT values `spf_core` 3, `q6prm` 7, `audio-pkt` 0x17 are **APPS-side source ports** | ML `include/dt-bindings/soc/qcom,gpr.h:8-17`, AK `dsp/spf-core.c:126`, `dsp/audio_prm.c:175` [V] |
| AOSS QMP | 0xc300000 (0x400), IPCC client 0 signal 0 | live DT [V] |
| SMEM | 0x80900000 + 2 MiB, hwlock TCSR mutex 3 (0x1f43000) | live DT [V] |
| **Speaker back end** | **TERT MI2S (I2S), not TDM.** PAL `PAL_DEVICE_OUT_SPEAKER` -> `MI2S-LPAIF-RX-TERTIARY`, 2 ch, 48 kHz, 24 bit (S24_LE); VI feedback `MI2S-LPAIF-TX-TERTIARY` 2 ch 32 bit. Sound node has `qcom,mi2s-audio-intf = <1>` and no TDM intf; `oplus,speaker-i2s-id = <2>` | `AS/odm/etc/resourcemanager.xml:461-467, 518-536`, live DT :27627, :37308 [V] |
| I2S clock | BCLK = 48000 x 2 x 32 = **3.072 MHz** (S24 in 32-bit slots); SoC is master (`qcom,msm-mi2s-master` 1) | AK `asoc/msm_common.c:42, 443-458`, live DT :27652 [V] |
| I2S pins | main TLMM (not LPASS LPI): GPIO121 SCK, 122 SD0 (in: VI), 123 WS, 124 SD1 (out: speaker data); function 1 (`mi2s2_*`), 8 mA, no pull | live DT :4127-4262, `out/src/extra/pinctrl-sm8450.c:1534` [V] |
| TDM node (unused) | `qcom,msm-dai-tdm-tert-rx` group 0x9120, port 0x9020, 1.536 MHz: a legacy node, not used by the AudioReach speaker path | live DT :24572 [V], unused [I] |
| Speakers | 2x TFA9874 on QUP SE13 `i2c@a94000`: 0x34 (`tfa_channel 0`, reset GPIO50), 0x35 (channel 1, reset GPIO51), 400 kHz, VDD = `pm8350_s10` (smpb10, 1.8 V); no other device on the bus; no `qcom,shared` | live DT :14853-14892 [V] |
| I2C pins | SE13 GPIO48 (SDA), GPIO49 (SCL), function `qup13`, pull-up | live DT `qupv3_se13_i2c_active` :2477 [V] |
| Audio SMMU | `qcom,msm-audio-ion`: iommus `<apps_smmu 0x1801 0>`, sid mask 0xf, IOVA pool 0x10000000 + 256 MiB. The address given to the ADSP is IOVA \| (SID & 0xf) << 32, so addr_msw = 1 | live DT :24782, AK `dsp/msm_audio_ion.c:270-282, 880-905` [V] |
| Headset/mics | WCD9385 over SoundWire (`lpass-cdc` rx/tx/va macros) | live DT [V]; out of scope here |

## Stage 0: stop the mediaserverd abort (built, not on the phone)

Observation [V] (`logs/usblog-20261024-195455.txt`): on the first NE2211 boot mediaserverd crashed
twice with SIGABRT, at 20:27:03 and 20:41:05, at the same place both times. Symbolicated
(`logs/symb-mediaserverd.log`, `scripts/debug/symbolicate.sh`) [V]: `abort` <- `demangling_terminate_handler`
<- `_objc_terminate` <- `std::terminate` <- `_dispatch_client_callout` <- `_dispatch_lane_serial_drain`:
an uncaught C++ (or ObjC) exception in a dispatch block. The block itself is not in the backtrace [U].

What we know [V]:
- iOS 16 runs the audio server (CoreAudio HAL) inside **mediaserverd**. `audiomxd` is the iOS 17+
  split of the audio server [I]; for iOS 26 the same plug-in goes into audiomxd.
- The 20H392 HAL looks for plug-ins in `/System/Library/Audio/Plug-Ins/HAL`, `/Library/Audio/Plug-Ins/HAL`
  and `/Library/Apple/Audio/Plug-Ins/HAL` (strings in the 20H392 shared cache) [V]. The root has 9 Apple
  drivers in the first one (AppleUSBAudio, BTAudioHALPlugin, BasebandVoice, AirPlayHalogen, ...), all
  plain arm64 bundles with CFPlugInTypes `443ABAB8-...` [V]. `AudioServerPlugIn_LoadingConditions`
  (IOService matching) is optional: only AppleAOPAudioPlugin has it [V].
- Interface table [V]: 20H392 `BasebandVoice.driver` `__DATA,__data` 0x14000 = pointer to 0x14008;
  0x14008 = NULL (`_reserved`); 0x14010-0x140b8 = 22 function pointers. Same as our
  `AudioServerPlugIn.h` (and the macOS SDK; `userland/audio/layout-check.c` compares 23 sizes,
  offsets and constants with the SDK header at each build).
- The slop root tweaks (`external/slop/tools/sweet-root-tweaks.py`, `audio()`) move
  `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin` to `HAL.disabled/` and set
  `StartRecorderServer=false`. Before that, mediaserverd crashed with SIGSEGV in VirtualAudio
  (`ApplyBeamFormerPreference`): the default virtual device `vdef` did not exist because no audio
  hardware device exists (slop NOTES, Codex `mediaserverd-report.md`).
- Without VirtualAudio, the HAL has only CoreAudio's `Null_Device`. The routing layer above it gets
  no route [I]. The SIGABRT is probably that layer [I].
- HackiOS keeps VirtualAudio.plugin and adds its own AudioServerPlugIn (`RedwoodAudio.driver`, MIT,
  installed in `/System/Library/Audio/Plug-Ins/HAL`). VirtualAudio knows iPhone devices by UID. It
  builds the speaker route only if **"Speaker"** (stereo output + silent stereo input) and
  **"Hawking"** (one silent input; the `vhaw` companion of `vdef`) exist. Optional: "Codec" (mic),
  "Actuator" (haptics). With those devices mediaserverd runs, and the speaker port, the volume HUD
  and Control Center work (HackiOS, on the phone).

What is done (2026-10-25):

| File | What |
|---|---|
| `userland/audio/NegroniAudio.c` | port of HackiOS `audio_plugin.c`: 4 devices, 16-bit 48 kHz streams, volume control (48 dB), data source `imic`, clock = `mach_absolute_time()` at 48000 frames/s. Writes the Speaker output to `/dev/negroni-audio` if the node exists, else drops it. The I/O path takes no lock and does not block (`GetZeroTimeStamp` is O(1), lock-free). Logs `NegroniAudio:` lines to stderr |
| `userland/audio/AudioServerPlugIn.h` | the interface (iOS SDK has none) |
| `userland/audio/layout-check.c` | our header vs the macOS SDK header (build fails on a difference) |
| `userland/audio/test-host.c` | host stand-in for the HAL: devices by UID, formats, volume, clock, 1000 writes without the node |
| `userland/audio/build.sh` | arm64, minos 16.0, no weak imports, one exported symbol, ad hoc signed -> `out/audio/ios/NegroniAudio.driver` |
| `userland/audio/negroni_audio.h` | the stage d user/kernel ABI (write S16LE stereo, SET_VOLUME, GET_STATS) |
| `scripts/audio/root-add-audio.sh` | root hook, `AUDIO=1` (default off): the driver to `/System/Library/Audio/Plug-Ins/HAL/`, VirtualAudio back to `/Library/Audio/Plug-Ins/HAL/`, `StartRecorderServer=false` in the 3 MediaToolbox `SubServerConfiguration.plist` (D22, D221, Default), checks D22 tunings + UISounds. Idempotent |
| `scripts/ios16/root-finish.sh` | calls the hook after the SSH step |

Build result [V, 2026-10-25]: `userland/audio/build.sh` PASS (layout 23/23 equal, test-host 0
failures); imports only CoreFoundation + libSystem symbols that iOS 16 has. Hook tested on a fake
root (no sudo): installs, restores VirtualAudio, sets the plist, second run changes nothing [V].
The paths the hook needs exist in the 20H392 root [V].

Phone test (needs a root rebuild and the owner's flash approval):
1. `userland/audio/build.sh`, then the root build with `AUDIO=1` (root-finish runs as root there).
2. Boot; `make usblog`. Pass: no `CRASH mediaserverd`; one `NegroniAudio: initialized` line (if
   stderr of mediaserverd reaches the log [U]; else check with SSH: `ps`, mediaserverd PID stays the
   same for 5 min); the volume HUD appears on the volume keys.
3. Look for `NegroniAudio: object N (...) has no '....'` lines: properties VirtualAudio asks for that
   we do not have. Add them if mediaserverd still aborts.
4. Fallback if mediaserverd crashes in VirtualAudio: `AUDIO=0` root (the old state).

Risk: the ad hoc signature. The negroni AMFI stand-in treats every signed file on the root as
platform code (`README-aks-amfi.md`) [V], and HackiOS loaded an unsigned plug-in [V], so the bundle
should load [I]. The HAL can also refuse a bundle for other reasons [U]: the USB log then shows
mediaserverd as before, with no `NegroniAudio:` line.

Phone test 2026-10-26 (`scripts/audio/phone-audio.sh push`, live root, no root rebuild) [V]: the plug-in and
VirtualAudio are on the phone's root now. 3 boots without a mediaserverd crash, 2 boots (low battery period) with
the old SIGABRT and one SIGTRAP in a plug-in factory's `xpc_connection_send_message`; not decided yet. Details:
docs/notes.md section 17 (2026-10-26). `phone-audio.sh revert` undoes the change.

## Stage a: ADSP start (patch 0240, builds; step 1 ran on the phone 2026-10-26, patch 0241)

Phone result 2026-10-26 [V]: step 1 parses SMEM (partition 0/2 at 0x80acf000) and finds no SMP2P items; the
PAS-is-supported SCM query answers 0 and stopped the run. Patch 0241 makes that answer a note (Linux's PAS driver
never asks). Steps 2-8 are still untested (notes.md section 17).

Files: `patches/xnu/0240-negroni-adsp-boot.patch` (made in `out/kernel/tree-audio`, a
`scripts/kernel/patched-tree.sh` tree; `git diff HEAD~1`). New `bsd/dev/negroni_adsp.c`;
`negroni_ufs.c` gets a read-only ADSP area reader and the init call; `negroni_rpmh.c` gets ARC
level votes (the VRM path is unchanged). Compiled in full `build-local.sh` runs
(`local-20261024-234223`, and the 2026-10-25 audio run: see notes.md).

Review 2026-10-25 [V, compared with Linux smem.c, smp2p.c, qcom_aoss.c, mdt_loader.c,
qcom_q6v5_pas.c, qcom_scm]: SMEM ptable/partition/private-entry layouts, the uncached and cached
item walks and the allocation match `qcom_smem_alloc_private`; the SMP2P item header (20 bytes,
16 entries of 20 bytes, version written last), IPCC send (client << 16 | signal), QMP open sequence
and the 64-byte message, PAS SMC encoding (arginfo `2 | 2 << 6` for init image), the MDT metadata
(header + packed hash), mem setup only for relocatable images and the segment offsets
(p_paddr - min p_paddr) all match. Change made: the RPMh votes now retry EBUSY for up to 1 s
(`rail_vote`): `negroni_rpmh.c` has a try-lock, and touch/Wi-Fi init use RPMh at the same time as the
ADSP thread; before, step 3 could fail at random or a vote drop could be lost without a log line.
The metadata page is kept (TrustZone may read it until auth; Linux frees it after auth).
Notes [I]: we advertise SMP2P SSR-ACK but do not implement the ack (only needed after a DSP
restart); only the ACTIVE RPMh set is voted (no sleep/wake sets; fine while XNU does not flush
RPMh sleep sets).

**Phone test 2026-10-25 (photo, GPU kept on `negroniadreno=22 negroniadreno_keep=1`, Wi-Fi survey to step 10)**
[V]: `NEGRONI ADSP: steps 1..8 (UNTESTED stage (a)...)`, then
`panic(cpu 1 caller 0xfffffe0007aec438): kmem_alloc(0xfffffe1006230e20, 2097152, 0x10002): failed with 3 @vm_kern.c:178`.
- [V] The caller address is the end of `___kmem_failed_panic` in `out/kernel/local-20261025-103035`
  (no KASLR slide: `nm` gives `___kmem_failed_panic` 0xfffffe0007aec3fc, next symbol 0xfffffe0007aec438).
- [V] 2097152 = 0x200000 = SMEM_SIZE; step 1 `ml_io_map_wcomb(SMEM_PHYS, SMEM_SIZE)` is the first thing
  that runs (no "about to" line before it). Error 3 = KERN_NO_SPACE: io_submap (8 MiB, osfmk/arm/io_map.c:65)
  was full (table: notes.md "io_submap"). [I] The photo's flags 0x10002 lack a digit: io_map passes
  KMA_NOFAIL | KMA_PAGEABLE | KMA_PERMANENT = 0x100021 (only a KMA_NOFAIL request reaches this panic).
- Fix (0240 regenerated 2026-10-25, build `kernel-iofix`): SMEM (2 MiB, kept for GLINK) and the
  40 MiB carveout use `ml_io_map_unmappable(pa, size, VM_WIMG_WCOMB 0x6)` (kernel_map, not io_submap).
  The carveout `ml_io_unmap` at the end of step 6 is now legal (before, it would have panicked in
  vm_map_delete on the permanent io_submap entry, vm_map.c:8188). IPCC, AOSS and the TCSR mutex stay
  on `ml_io_map` (16 KiB each), mapped only once. [I] Untested on the phone.

Boot-args: `negroniadsp=1` (default 0: nothing runs), `negroniadsp_step=N` (stop after N),
`negroniadsp_wait=S` (ready timeout, default 10), `negroniadsp_pause=MS` (sleep before each write
step), `negroniadsp_unvote=0` (keep rail votes after handover). It runs on its own kernel thread,
after the GPU steps, so it does not delay the boot.

Steps (log prefix `NEGRONI ADSP: <step>`):

| Step | Action | Writes | Expected log |
|---|---|---|---|
| 1 | SMEM: $TOC, partition 0/2, item 443 (ADSP ran?), item 429; PAS is-supported(1) | no | `SMEM partition 0/2 at ...`, `no ADSP SMP2P item 443`, `SCM PAS is supported (adsp) -> 0, answer 0x1` |
| 2 | Firmware area header, adsp.mdt, SHA-256 of all 25 segment files, span check | no | `adsp.mdt: 26 program headers, load 0x86300000..0x88b00000 (40960 KiB), ... relocatable` |
| 3 | RPMh ARC votes lcx.lvl, lmx.lvl -> level 384 | RPMh | `NEGRONI RPMH: ARC lcx.lvl level 384 -> hlvl N`, `ACTIVE vote ... complete` |
| 4 | AOSS QMP open (if needed), `{class: image, res: load_state, name: adsp, val: on}` | AOP | `AOP took ...` |
| 5 | PAS init image (metadata = headers + hash), PAS mem setup (0x85700000, 0x2800000) | TZ | `TRUSTZONE ACCEPTS THE ADSP SIGNATURE` |
| 6 | Zero the carveout, write PT_LOAD segments at p_paddr - 0x86300000, read back by SHA-256 | carveout | `segments written at 0x85700000 and read back OK` |
| 7 | SMP2P item 429 (allocated under TCSR mutex 3), entry `master-kernel`, IPCC ring 3/2 | SMEM | `our SMP2P item at ... magic 0x504d5324 version 0x101` |
| 8 | PAS auth and reset; poll item 443 `slave-kernel` | TZ | `+N ms: slave-kernel = 0x2 READY`, `handover ... proxy rail votes dropped`, `THE ADSP IS UP`, GLINK items 478/479/480 |

Failure handling: a fatal bit or no ready -> item 423 (ADSP last words) and PAS shutdown. A
failure after step 5 -> PAS shutdown. Rail votes are dropped on failure. If item 443 exists at
step 1, the ADSP has run in this boot: the code stops and does not start it twice (HackiOS: a
second start of a DSP that was shut down without a stop-ack reset the phone).

Firmware placement: the ADSP image (18 MiB, 26 files) does not fit the GPU firmware area (8 MiB,
16 entries). Patch 0240 adds a second area: **32 MiB right before the GPU area** in userdata,
format `NEGRADSP` (64 entries, SHA-256 each). The root image is 16 GiB (`root-macos.sh SIZE=16g`),
so the end of userdata is free [V].

```sh
scripts/bg.sh adsp-fw scripts/audio/extract-adsp-fw.sh      # OTA -> out/firmware/adsp/ (+ SHA256SUMS)
python3 -I scripts/audio/mkadsparea.py out/firmware/adsp-area.bin
# on the phone (recovery, owner approval first): N = userdata size in 4096-byte blocks
#   dd if=adsp-area.bin of=/dev/block/by-name/userdata bs=4096 seek=$((N-11265)) conv=notrunc,fsync
```

Layout at the end of userdata: log N-1025..N-1, GPU area N-3073..N-1026, ADSP area
N-11265..N-3074. `fastboot flash userdata` erases both firmware areas (same as the GPU area).

Test order: `negroniadsp=1 negroniadsp_step=2` (reads only), then `_step=4`, then the full run.
Read the result with `make usblog` (`grep "NEGRONI ADSP"`).

Risks of stage a:
- PAS calls without the crypto-engine bandwidth vote (`crypto_ddr` interconnect). The GPU zap
  auth works without it [V], but the ADSP image is 18 MiB [I: slower, probably works].
- The ADSP hosts the **charger PD** (`battmgr.jsn`, `qcom,pmic_glink` on `lpass`). A running ADSP
  can change the charging behaviour under iOS [U]. It can also give battery data later over
  `PMIC_RTR_ADSP_APPS` (HackiOS `battmgr_*` in redwood_adsp.c).
- Under Gunyah the carveout must be HLOS-writable before auth. The GPU zap region (0x8b91a000, also
  PIL memory) was writable [V]; the ADSP region is the same kind [I].
- Interrupts are not used (polling). The IPCC doorbells from the ADSP stay pending; nobody in XNU
  enables them [I: harmless].
- The AOP QMP open can race with another QMP user. No other XNU code uses QMP now [V].

## Implemented 2026-10-26 (patches 0242, 0243; build-only, untested on the phone)

**Patch 0242 (ADSP step 9, GLINK over SMEM).** `bsd/dev/negroni_adsp.c` gains `step_glink`. It makes
SMEM items 478 (descriptors, 4 words) and 479 (our 16 KiB TX FIFO), waits for the ADSP's FIFO 480,
runs the GLINK version-1 handshake, opens channels `IPCRTR` (lcid 1) and `adsp_apps` (lcid 2), gives
each channel RX intents (8 x 4 KiB on adsp_apps, 4 x 4 KiB on IPCRTR; an ADSP RX_INTENT_REQ is
granted up to 0x4400 bytes, the largest live-DT intent; our own TX messages stay <= 4096 bytes), and
offers the stable API `negroni_glink_poll`/`_up`/`_set_rx`/`_send` to stage (b) and the charger client
(0274). One recursive mutex inside the API serializes the ADSP thread, the /dev/negroni-audio writer
and the charger client. RX_DONE_W_REUSE only when both sides agree on INTENT_REUSE, else RX_DONE and
the buffer is given again. Repeated GLINK complaints are capped at 8 lines. Also in 0242: every ADSP step now runs under a time limit
(`negroniadsp_steptimeout=MS`, default 15000) and a failed step prints
`NEGRONI ADSP: step N (name) failed: reason`. `smem_alloc_ours` became a general `smem_alloc(item, bytes)`.
New header `bsd/dev/negroni_adsp.h` (the GLINK + stage-b interface). file:line anchors:
`step_glink` in `negroni_adsp.c`; the step table and the fail line in `adsp_thread`.

**Patch 0243 (stage (b) + (d)).** New `bsd/dev/negroni_audio.c` + `bsd/dev/negroni_audio_abi.h` (a kernel
copy of `userland/audio/negroni_audio.h`). `negroni_adsp.c` steps 10..15 call `negroni_audio_step(n, ...)`:

| Step | Action | Pass log |
|---|---|---|
| 10 | QRTR: HELLO on IPCRTR (20-byte control body), record the ADSP's NEW_SERVER list; no servreg locator yet | `QRTR: HELLO from node N` |
| 11 | GPR: `APM_CMD_GET_SPF_STATE` 0x01001021 (+ zeroed 16-byte cmd header, 40 bytes) -> 0x02001007 status 1 | `SPF READY` |
| 12 | PRM: `PRM_CMD_REQUEST_HW_RSC` TER MI2S IBIT clock 0x104 at 3.072 MHz; I2S pins 121..124 to func 1 | `PRM clock up, I2S pins 121..124` |
| 13 | `APM_CMD_GRAPH_OPEN` (WR_SH_MEM_EP -> PCM_CNV -> MFC -> I2S_SINK), SET_CFG each module, PREPARE | `GRAPH SET_CFG and PREPARE ok` |
| 14 | `SHARED_MEM_MAP_REGIONS` of our ring (contiguous, < 4 GiB, given as phys \| (SID 0x1801 & 0xf) << 32), WR EP media format, START | `GRAPH STARTED` |
| 15 | make `/dev/negroni-audio`; `write()` of S16LE stereo converts to S24 and sends periods to the WR EP | `THE SPEAKER SINK IS LIVE` |

Design notes [V in code, I/U for behaviour]:
- The graph has two sub-graphs (stream 0x04000001, device 0x04000002), two containers, four built-in
  modules (WR_SH_MEM_EP 0x07001000, PCM_CNV 0x07001003, MFC 0x07001015, I2S_SINK 0x0700100A), three
  connections. The NXP TFA module is left out (it is a dynamic FastRPC module; stage (c) drives the
  amps by register writes). The I2S sink is TERTIARY (intf 2), SD1, internal WS; MFC/WR EP = 48 kHz,
  S24-in-32-bit, stereo. Module instance ids 0x6001..0x6004; APM iid 1, PRM iid 2.
- Review fixes 2026-10-26 (coordinator review, all applied): BASIC_RSP matched on the echoed command
  opcode; PRM status = payload word 1; GET_SPF_STATE carries the cmd header; QRTR control bodies start
  with the cmd word; the ring is cleaned before each send; default last step 9; the GLINK mutex; the
  unanswered locator announcement removed; TLMM cfg = FUNC 1 | 8 mA (3 << 6).
- SMMU [I]: step 14 assumes the boot chain passes SID 0x1801 untranslated and gives the ADSP the
  physical ring address with the SID bit (like redwood_sound.c's "passed" path). It needs a physically
  contiguous ring and fails cleanly (audio off, no SoC reset) if the ring is not one piece. A full SMMU
  context (redwood_sound.c `space_on`) is NOT ported yet: if the boot chain translates SID 0x1801, step
  14 stops.
- The /dev/negroni-audio write path (step 15) fills the current period frame by frame (the HAL writes
  ~240-frame chunks, not whole 960-frame periods), cleans a full period to PoC (LPASS is not coherent)
  and sends `DATA_CMD_WR_SH_MEM_EP_DATA_BUFFER` 0x04001000 to the WR EP iid. The writer polls GLINK for
  the DONE events (0x05001000); with 7 of 8 periods in flight the new period is dropped, so a period the
  ADSP still reads is never overwritten. write() can block the plug-in's writer thread (not the HAL
  real-time thread) for up to ~1.2 s inside negroni_glink_send. SET_VOLUME: mute is applied,
  `below` is stored only. GET_STATS works. The node exists only after step 15 runs.
- Re-review fixes [V]: adsp_apps gets 8 intents at open (4 slots stay free for RX_INTENT_REQ); the writer
  re-bases its in-flight count (logged once) after 2 x PERIODS busy drops in a row or a DONE count above
  the sent count, so a lost or extra DONE cannot stop it. `negroniaudio_v2=1` sends
  DATA_CMD_WR_SH_MEM_EP_DATA_BUFFER_V2 0x0400100A (11 words, DONE 0x05001004, as Linux q6apm.c and GSL);
  the default is V1 0x04001000 / 0x05001000. If step 15 shows no DONE, try V2 first [I].
- Gating and SoC-reset risk: `negroniadsp=1` alone stops at step 9 (ADSP + GLINK, no audio); stage (b)
  runs only with `negroniadsp_step=10..15`. Each step has a time limit; a stage-(b) failure calls `negroni_audio_stop` (GRAPH_STOP/CLOSE,
  mem unmap) and leaves the ADSP up — it does not re-reset or shut down the DSP, so a graph error does
  not reset the SoC. Only an ADSP firmware fault (steps 1..8) can reset the SoC, and those are gated as
  before.

**Userland (stage 0 + stage 1).** `scripts/audio/hfs-extract.py` (read-only, reads the HFS+ catalog in
`~/op10-apple/ios16-root.simg` with no raw copy) pulled the 20H392 HAL plug-ins to `out/audio/hal-plugins/`.
The mediaserverd `__xpc_api_misuse` SIGTRAP (logs/symb-ms.log, symb-ms2.log, main image + 0x42ee674 /
+0x437a674) is `BTAudioHALPlugin.driver`: its factory `_AudioServerPlugIn_Create` (Info.plist) opens an
XPC connection to `com.apple.BTAudioHALPlugin.xpc` (bluetoothd, absent here) and sends on it [V, offsets
0x32670/0x356f8/0x3576c matched]. Fix [V]: `scripts/audio/root-add-audio.sh` (step 2b) and
`scripts/audio/phone-audio.sh` move `BTAudioHALPlugin.driver` to `HAL.disabled/` by default (`BTAUDIO=1`
keeps it); `phone-audio.sh revert` restores it. The std::terminate SIGABRT is not decided [U]: it also
happened on 2026-10-24 before NegroniAudio existed, so it is not our plug-in [I]. `NegroniAudio.c` stage
1 [V]: the real-time I/O thread copies the Speaker S16LE frames into a lock-free SPSC ring (16384 frames,
341 ms); a writer pthread (StartIO..StopIO) drains it to `/dev/negroni-audio` every 5 ms, keeps bytes the
kernel did not take, drops on a full ring, reopens on ENODEV every 2 s. `build.sh` PASS (layout 23/23,
host test 0 failures, arm64 minos 16.0, iOS 16 imports only). Driver sha256
`7770ccb43a527c236db723280778cdee3371a9a1e55d9376a64eba4f288b6a0b`. ABI `negroni_audio.h`: no change.

## Implemented 2026-10-26 evening: patches 0244-0248 (amps, guard, tone, earpiece, graph, crash watch; build-only)

Read this section first. Nothing here ran on the phone. Audit input: `docs/audit/2026-10-26-audio.md`.

### Which physical path each function uses [V]

| Function | Path on the NE2211 | Source |
|---|---|---|
| Speaker | 2x NXP TFA9874 (I2C SE13 `i2c@a94000`, 0x34 + 0x35), I2S data on TERT MI2S (SD1 = GPIO124), both amps, container profile "speaker" | `out/live.dts:14853-14891`; `resourcemanager.xml:519` (`MI2S-LPAIF-RX-TERTIARY`); `mixer_paths.xml:2011` (`TFA_CHIP_SELECTOR 3`, profile `speaker`) |
| Earpiece | the same TERT MI2S port; **only 0x34** (`TFA_CHIP_SELECTOR 1` = CHIP_SELECTOR_LEFT = `tfa_channel 0` = 0x34) in container profile "receiver". Not the WCD938x EAR output | `resourcemanager.xml:576`; `mixer_paths.xml:2161`; `tfa98xx_v6.c` `tfa98xx_set_stereo_ctl`, `tfa98xx.h:42-44` |
| SoundWire WSA amps | **not used**: `wsa-macro@3240000` status disabled, both `wsa883x` disabled, `qcom,wsa-max-devs = <0>` | `out/live.dts:27474, 27503, 27517, 27637` |
| Headphones | `CODEC_DMA-LPAIF_RXTX-RX-0` -> RX macro -> WCD938x HPHL/HPHR over SoundWire (`rx_swr_master`); USB-C analog through `fsa4480` (I2C 0x42) | `resourcemanager.xml:623`; `mixer_paths.xml:2209`; `out/live.dts:14492, 27620, 27646` |
| Built-in mics | `CODEC_DMA-LPAIF_RXTX-TX-3`; TX macro **digital** mics DMIC3 + DMIC4 (`MSM_DMIC`, LPASS LPI pins `dmic23`/`dmic45`), mic bias from the WCD938x (MIC BIAS3 / MIC BIAS1) | `resourcemanager.xml:117-123`; `mixer_paths.xml:2166` (`handset-mic`), `2100`; `out/live.dts:27127-27235, 27647` |
| Headset mic + detect | WCD938x AMIC2 (`SWR_MIC5`, ADC2) and MBHC in the WCD938x, USB-C analog | `mixer_paths.xml:1919, 2268`; `out/live.dts:27629-27646` |

So the speaker port TER MI2S of 0243 is right. The audit's "mic = WCD9385 over SoundWire" is half right: the main mics
are DMICs on the SoC's TX macro; only their bias (and the headset mic) comes from the WCD938x over SoundWire.

### Speaker protection facts [V unless marked]

- The TFA9874 has no DSP ("non-DSP TFA, like TFA9874", `tfa98xx_v6.c` `tfa98xx_dsp_init`; `is_probus_device = 1`,
  `tfa_dsp_v6.c:296-303`). Android runs NXP's protection algorithm in the ADSP (module 0x1700B911, `libtfadsp_rx.so`,
  V/I feedback on `MI2S-LPAIF-TX-TERTIARY`; Android's volume also goes to that module: `tfa98xx_send_volume`). There is
  no "SpeakerBoost" firmware for this chip: the container's patch is `9874_dummy.patch` with no writes
  (`scripts/audio/tfa-cnt.py dump`).
- Container `odm/firmware/tfa98xx.cnt` (CRC OK, "PM" 3_01): speaker profile TDMSPKG 7 (0x34) / 5 (0x35) with INPLEV 0 and
  the DC-DC boost on (DCA 1); receiver profile TDMSPKG 13 with INPLEV 1 and DCA 0; DCMCC (coil current) 11 / 10.
  TDMSPKG = reg 0x61 bits 9:6 is an ATTENUATION: amplifier gain = 21 dB - TDMSPKG, 1 dB per code (TFA9874B / TFA9875
  data sheet G(TDM-VO) 6..21 dB, "TDMSPKG = 2 typical = 19 dB"; review 2026-10-26). So the vendor speaker runs 14 dB
  (0x34) / 16 dB (0x35), the receiver 8 dB minus the INPLEV attenuation. (An earlier note here said "higher = louder": wrong.)
- Status (vendor check `check_err_tfa9874`): reg 0x10 bit 2 = 0 over-temperature, bit 3 = 1 current high, bit 4 = 0 VBAT
  low, bit 7 = 1 no clock; reg 0x13 bit 8 = 0 VBAT high, bit 9 = 1 clipping; normal 0x0016 / 0x850F.
- MTP 0xF0..0xFF holds the factory calibration (R25C 0xF5): read only, the table loader refuses writes there.

### Patches

| Patch | What | Boot-args | Log |
|---|---|---|---|
| 0244 `negroni-audio-amp-tfa9874` | (1) TLMM fix: 0243 used 0x0f000000 + n * 0x1000 (wrong block; GPIO121..124 stayed GPIO); now 0x0f100000, only GPIO121..124 mapped (32 KiB of io_submap, not 840 KiB). (2) the speaker guard `negroni_audio_guard.c`: cap (default -20 dBFS), HAL volume applied, 20 ms soft start, 200 Hz high-pass, 0.2 s / 3 s power limits, peak limiter, earpiece mix (L+R)/2 to the left slot. (3) `negroni_tfa.c`: bit-banged I2C on GPIO48/49 (the touch driver's `tlmm_i2c.h`), reset pulse GPIO50/51, revision read, the vendor cold start (I2CR, keys, revision table, container device + profile items, INIT_CF, CLKS wait, OPERATING/AMPE 1), TDMSPKG held at or above an attenuation floor (gain = 21 dB - TDMSPKG; never louder than the container) and read back before AMPE, stop (PWDN 1, AMPE 0, MANSTATE 0). Amps start on the first non-silent block, stop after 3 s of silence, on a fault (10 s restart block), on audio stop, on panic/halt (I2C off + reset pins held high, `NegroniPlatformExpert.cpp`). A clipping report lowers the guard 1 dB (max 12 dB). | `negroniaudio_amp=1` (default 0: amps never touched); `negroniaudio_capdb=N` (default 20, min 10); `negroniaudio_spkg=N` (speaker TDMSPKG floor, default 9 = 12 dB; a value below the container's 7/5 is ignored); `negroniaudio_rcvg=N` (receiver floor, default 15 = 6 dB; below the container's 13 ignored); `negroniaudio_amplog=N` (log every register write of the first N starts, default 1) | `NEGRONI TFA:`, `NEGRONI AUDIO: 15 amps on ...` |
| 0245 `negroni-audio-test-tone` | 1 kHz sine, 2 s + 0.5 s zeros, through the guard (-20 dBFS at the I2S), paced on the DONE events; stops early when no DONE comes after 10 periods; amps off at the end | `negroniaudio_tone=1` speaker, `=2` earpiece | `TONE: ...`, `TONE done in N ms ... periods sent, DONE, dropped` |
| 0246 `negroni-audio-earpiece-route` | ioctl `NEGRONI_AUDIO_SET_ROUTE` (1 speaker, 2 receiver; ABI in `userland/audio/negroni_audio.h`), sysctl `kern.negroni_audio_route`, sysctl `kern.negroni_audio_tone` (write 1 or 2: the tone now, root) | `negroniaudio_route=1|2` | `route: ...` |
| 0247 `negroni-audio-graph-mainline` | graph values of the mainline topology: stream container cap CD, device sub-graph direction TX, device container position STREAM, stacks 8192, WR EP media format to the module's own GPR port (`audioreach-topology` `subgraph-*-playback.m4`, Linux `audioreach.c` shmem media format) | `negroniaudio_graph=1` = the 0243 values | `graph values: ...` |
| 0248 `negroni-adsp-crash-watch` | after step 8: poll slave-kernel every 200 ms; on FATAL: last words, amps + sink off, GLINK stopped, master-kernel "stop" bit 0 (live DT `qcom,smem-state-names = "stop"`) + kick, 5 s for STOP-ACK, PAS shutdown; no restart | (with `negroniadsp=1`) | `NEGRONI ADSP: watch: ...`, `ADSP FATAL AFTER START` |

Tables and tools: `scripts/audio/tfa-cnt.py dump|bin` (container -> `out/firmware/adsp/tfa-init.bin`, 139 writes, sha256
0407f7f0...; vendor data, never committed), `scripts/audio/mkadsparea.py` now packs `tfa-init.bin` into the ADSP area
(30 files), `scripts/audio/test-guard.sh` (host test of the guard: PASS; it found the signed/unsigned clamp bug that
turned negative samples positive, fixed in 0244), `scripts/audio/build-audio-kernel.sh` (kernel only; `IMAGE=1` adds `out/ios16-audio2`).
HAL: `NegroniAudio.c` logs the kernel's counters and guard peaks every 30 s (`kernel: ...`); `build.sh` PASS.

Build 2026-10-26 (`scripts/audio/build-audio-kernel.sh`, kernel only by the owner rule; lock out/kernel/.lock held):
`out/kernel/local-20261026-174012/kernel.development.negroni` sha256
daf42c442b7cd2a94e7a82d214d1461ab76f2f28292b6ba0e26369d831765af7 (after the TDMSPKG-floor fix); patch-report: 0242-0248 applied, all patches/xnu
applied, only the 4 usual dxb skips; strings `NEGRONI TFA`, `TONE done`, `negroniaudio_amp`, `ADSP FATAL AFTER START`,
`negroni_audio_route` are in the kernel. Patch sha256: 0244 00a3de42..., 0245 f2cb2217..., 0246 d636a7e6..., 0247
d2ddaa44..., 0248 7d851d26.... Not booted.

### Phone test (owner approval needed for each write)

1. Charge to > 50 %. Write the new ADSP area (it now holds `tfa-init.bin`): `python3 -I scripts/audio/mkadsparea.py
   out/firmware/adsp-area.bin`, then the `dd` line in "Stage a" (userdata, recovery). Without the area the amps stay off
   (`no tfa-init.bin in the ADSP area`).
2. Boot the main session's combined image with these boot-args (owner rule: agents build no image):
   `negroniadsp=1 negroniadsp_step=15 negroniaudio_amp=1 negroniaudio_tone=1 negronipanic=30 negronipanicreason=2`
   (optional: `negroniaudio_capdb=20`, `negroniaudio_spkg=9`, `negroniaudio_rcvg=15`, `negroniaudio_route=1|2`,
   `negroniaudio_graph=1`, `negroniaudio_v2=1`, `negroniaudio_amplog=1`). Hold the phone away from the ear.
3. `make usblog`; pass lines in order: `NEGRONI ADSP: THE ADSP IS UP`, `GLINK UP`, `NEGRONI AUDIO: 11 SPF READY`,
   `12 PRM clock up, I2S pins 121..124 to function 1 (ctl 0x... )` (expect 0xc4 for each: FUNC 1, 8 mA),
   `GRAPH_OPEN ok`, `GRAPH STARTED`, `THE SPEAKER SINK IS LIVE`, `NEGRONI TFA: 0x34 top ...: TFA9874 revision 0x0?74`,
   `0x35 ...`, `probe done: 2 of 2 amps usable`, `TONE: ...`, `NEGRONI TFA: 0x34 ...: AMPE 1, ... MANSTATE 9`,
   `TONE done in ~2500 ms ... DONE 125`. The owner HEARS 2 s of 1 kHz from both speakers.
4. Failure map: `no CLKS after 100 ms` = no I2S clock at the amps (PRM clock, pins, graph not running);
   `TONE stopped: no DONE` = the ADSP does not take the data (try `negroniaudio_v2=1`, then the SMMU); `GRAPH_OPEN failed`
   = try `negroniaudio_graph=1`; `no TFA9874 (rc -2)` = NACK (I2C pins, reset level).
5. Earpiece: `sysctl -w kern.negroni_audio_tone=2` over SSH (or `negroniaudio_tone=2`).

### Not done (honest sizes, from the audit and this review)

- Mic (`/dev/negroni-audio-in`, TX graph): needs the LPASS TX macro DMIC setup (MMIO 0x3220000 + its clocks through PRM),
  the LPI pins, the WCD938x mic bias over the TX/VA SoundWire master (SoundWire master bring-up + WCD938x register access),
  and a CODEC_DMA TX-3 -> RD_SH_MEM_EP graph. 3000+ lines, weeks. Not started; the HAL "Codec" input stays silent.
- Headset: WCD938x RX path + MBHC + the fsa4480 USB-C switch: after the mic work. Not started.
- iOS route to the earpiece: VirtualAudio knows a receiver port ("Built-In Receiver", port type `prec` [I]) but how
  the HAL plug-in must offer it (a data source on the Speaker output or a separate device) is not known [U]. The kernel
  side is done (0246); the plug-in does not call SET_ROUTE yet.
- servreg locator / PD mapper (audit item 3): only if step 11 never reports SPF ready.
- SMMU context for SID 0x1801 (audit item 4): only if no DONE comes with V1 and V2.
- No ACDB calibration, no NXP protection algorithm: the guard + the TDMSPKG floors are the only protection.

## Stage b: GLINK, QRTR, GPR and the AudioReach speaker graph (implemented 2026-10-26, patch 0243; the facts below are the design)

Kernel files (names from the draft `out/kernel/tree-audio/bsd/dev/negroni_audio_internal.h`, not a
patch yet): `negroni_glink.c` (GLINK, QRTR, GPR transport), `negroni_gpr.c` (APM/PRM, the graph),
patch 0241. Boot-arg `negroniaudio=N` (default 0). Log prefix `NEGRONI GPR:`.

1. **GLINK SMEM transport** (Linux `qcom_glink_smem.c`, HackiOS `glink_*`): create item 478
   (descriptor) and 479 (our TX FIFO), get the ADSP's 480 (RX FIFO), version negotiation, open
   `IPCRTR` and `adsp_apps`, offer the DT intents (above). Answer the ADSP's RX_INTENT_REQ (cmd 7)
   with INTENT (5) + REQ_ACK (8); send RX_DONE (6/14) after each packet [V op-kernel
   `drivers/rpmsg/qcom_glink_native.c:909-945`]. A polling thread replaces the IPCC IRQ.
   GPR adds no framing: one GPR packet = one GLINK TX_DATA message [V AK `ipc/gpr-lite.c:156, 319`].
   Log: `GLINK: version 1 ok`, `channel adsp_apps open (remote rcid N)`.
2. **QRTR** on `IPCRTR`: answer HELLO, record NEW_SERVER. Control packets {cmd, service, instance,
   node, port} to port 0xfffffffe [V op-kernel `net/qrtr/ns.c`].
   Startup gate: Android's gpr drops ADSP packets until PDR reports "avs/audio" on
   "msm/adsp/audio_pd" UP [V AK `ipc/gpr-lite.c:126-135`, `dsp/audio_pdr.c:16-35`]; that gate is on
   the AP side only. No source shows that the ADSP needs an AP locator to start audio_pd [U].
   Plan: poll GET_SPF_STATE directly. Only if it never answers, add a minimal SERVREG_LOCATOR
   server (QMI service 0x40, version 0x101, instance 0; GET_DOMAIN_LIST 0x21 from the `.jsn` data,
   audio_pd instance 74) like Linux `qcom_pd_mapper.c` [V ML :18-19, 107-129, 588-597].
3. **GPR** on `adsp_apps` [V ML `include/linux/soc/qcom/apr.h:78-118`]: 24-byte LE header:
   word 0 = version (bits 0-3, 0) | header size in words (bits 4-7, 6) | packet size in bytes (bits
   8-31); byte 4 dst domain, byte 5 src domain, 2 reserved bytes; then u32 src port, dst port,
   token, opcode. Header-only word 0 = 0x1860. Replies: `GPR_BASIC_RSP_RESULT` 0x02001005
   {opcode, status}, `GPR_BASIC_EVT_ACCEPTED` 0x02001006. Our src ports: 3 (APM), 7 (PRM), one
   dynamic port in 0x10000000-0x1fffffff for data.
   First message: `APM_CMD_GET_SPF_STATE` 0x01001021 to APM (port 1) (header only, or with a
   16-byte zero apm_cmd_header as mainline does); reply 0x02001007 {u32 status}, 1 = ready. Retry
   as AK does: 1 s reply timeout, 50 ms gap, 10 s total [V AK `dsp/spf-core.c:29-31, 59-102,
   160-193`]. Log: `GPR: SPF READY`.
4. **PRM** (port 2), after SPF is ready [V ML `sound/soc/qcom/qdsp6/q6prm.c:27-33`, AK
   `include/dsp/audio_prm.h:168-189`, SPF `modules/audio_hw_clk_api.h`]:
   `PRM_CMD_REQUEST_HW_RSC` 0x0100100F (answer 0x02001002), release 0x01001010. Payload (52 bytes):
   apm_cmd_header {0, 0, 0, 36} + param {miid 2, pid `PARAM_ID_RSC_AUDIO_HW_CLK` 0x0800102C,
   size 20, 0} + {num 1, clock id **`CLOCK_ID_TER_MI2S_IBIT` 0x104**, **3072000 Hz**, attribute
   COUPLE_NO 1, root 0}. Optional first: `PARAM_ID_RSC_HW_CORE` 0x08001032 {core 1 = LPASS}
   (Android votes the HW core only for 44.1 kHz-family rates [V AK `asoc/msm_common.c:273-281`]).
   Pins 121-124 to function 1 in TLMM (0xf000000 + 0x1000 x n).
   Check: TLMM input bits of GPIO121/123 toggle while the clock runs (HackiOS `sound=1` check).
5. **Graph** (all to APM port 1; success = BASIC_RSP_RESULT) [V ML `audioreach.h:57-75`,
   `audioreach.c:16-100, 325-590`, SPF `apm/apm_api.h:330-407`]. Opcodes: GRAPH_OPEN 0x01001000,
   PREPARE 0x01001001, START 0x01001002, STOP 0x01001003, CLOSE 0x01001004, SET_CFG 0x01001006.
   GRAPH_OPEN = apm_cmd_header + five params (miid 1, each padded to 8): SUB_GRAPH_CONFIG
   0x08001001, CONTAINER_CONFIG 0x08001000, MODULE_LIST 0x08001002, MODULE_PROP 0x08001003,
   MODULE_CONN 0x08001004. PREPARE/START/STOP/CLOSE take SUB_GRAPH_LIST 0x08001005.
   Order (Linux q6apm-dai): OPEN, SET_CFG, MAP, PREPARE, START, then buffers.
   Our graph: one stream sub-graph + one device sub-graph, built-in modules only:

   `WR_SH_MEM_EP` 0x07001000 -> `PCM_DEC` 0x07001005 (or `PCM_CNV` 0x07001003) -> `MFC` 0x07001015
   -> `I2S_SINK` 0x0700100A.

   Sink config: `PARAM_ID_I2S_INTF_CFG` 0x08001019 {lpaif_type 0, intf_idx 2 (TERTIARY), sd_line
   2 (SD1 = GPIO124), ws_src 1 (internal)} (values from the phone's ACDB, I2S sink iid 0x425A [V]);
   `PARAM_ID_HW_EP_MF_CFG` 0x08001017 {48000, 24, 2, 1}; `HW_EP_FRAME_SIZE_FACTOR` 0x08001018 {1}.
   PCM_DEC/CNV out: `PCM_OUTPUT_FORMAT_CFG` 0x08001008; MFC out: 0x08001024 {48000, 24, 2, L R}.
   The input from iOS is S16; the converter makes 24-bit.
   Reference: the phone's own low-latency speaker graph, read from `AS/odm/etc/acdbdata/acdb_cal.acdb`
   (GKV {0xA1000000: 0xA100000E, 0xA2000000: 0xA2000001, 0xAB000000: 1, 0xAC000000: 0xAC000002},
   `AS/odm/etc/usecaseKvManager.xml:39-54`): stream SG 0xB0000023 (WR_EP, LOG, PCM_DEC, PCM_CNV,
   VOL, SOFT_PAUSE, SPR), stream PP 0xB0000024 (MFC), device PP 0xB0000025 (SYNC, SAL, MFC, MSIIR,
   MBDRC, MFC), device SG 0xB0000002: SAL -> **NXP TFA RX 0x1700B911** (iid 0x425B) -> SPLITTER ->
   LOG -> I2S_SINK 0x425A [V, ACDB chunk parse]. The ACDB format is simple ('ACDB' header, 4CC
   chunks; graph data = GRAPH_OPEN params) [V `out/src/audioreach-graphservices/acdb/src/acdb_parser.c`].
   We leave out the NXP module: it is a dynamic CAPI module (`libtfadsp_rx.so`, loaded with AMDB
   0x0100101E/0x01001020 and fetched over FastRPC [I]); every other module is built in [I].
   Unused here: TDM_SINK 0x0700100E, `PARAM_ID_TDM_INTF_CFG` 0x0800101B (no ACDB graph uses TDM [V]).
6. **Shared memory** [V SPF `apm/apm_memmap_api.h`, ML `q6apm.c:230-256`, `audioreach.h:228-281`]:
   map our sample buffer in the apps SMMU context of SID 0x1801 (IOVA from 0x10000000; HackiOS
   `redwood_sound.c` did the same), address to the ADSP = IOVA with addr_msw = 1.
   `APM_CMD_SHARED_MEM_MAP_REGIONS` 0x0100100C (no apm_cmd_header): {u16 pool 3, u16 nregions,
   u32 flags 0} + {addr_lsw, addr_msw, size}, 4 KiB aligned; reply 0x02001001 {handle}.
   Media format to the WR EP: `PARAM_ID_MEDIA_FORMAT` 0x0800100C by SET_CFG (mainline) or
   `DATA_CMD_WR_SH_MEM_EP_MEDIA_FORMAT` 0x04001001. Each period: `DATA_CMD_WR_SH_MEM_EP_DATA_BUFFER`
   0x04001000 {addr_lsw, addr_msw, handle, size, ts_lsw, ts_msw, flags} from the dynamic port to the
   WR EP iid; buffers 64-byte aligned; DONE event 0x05001000 echoes the token.
   Check: DONE events at the 48 kHz pace (HackiOS `sound=2` check).

Effort: 2-3 weeks. Highest risk: audio_pd startup (step 2) and the SMMU mapping (step 6).

## Stage c: TFA9874 amplifiers (planned)

Facts [V unless marked; `TFA` = the OnePlus tfa98xx-v6 driver, the container parsed read-only]:
- **No on-chip DSP**: "For non-DSP TFA, like TFA9874" (`TFA/tfa98xx_v6.c:4225`), is_probus = 1.
  The shipped `tfa98xx-v6_dlkm.ko` does not talk to the ADSP (`OPLUS_FEATURE_TFA98XX_VI_FEEDBACK`
  off). So **register writes alone bring the amps up**.
- Interface: I2S, the amps are slaves (`CBS_CFS`) (`TFA/tfa98xx_v6.c:4594-4617`); `set_tdm_slot` is
  empty. Mixer "speaker" path: `TFA_CHIP_SELECTOR` 3 (both amps), profile "speaker".
- I2C: 8-bit register, 16-bit value, MSB first [I: regmap default]. Reads need a repeated start
  [I]; our bit-bang helper (`negroni_touch/gpio_i2c.h`) ends every transfer with STOP: add a
  write-then-read transfer.
- Reset is **active-high**: GPIO = 1, 5 ms, GPIO = 0, 5 ms; hold low to run (`TFA/tfa98xx_v6.c:5085-5093`).
- Probe: reg 0x03, accept `(rev & 0xff) == 0x74`; known revisions 0x0a74, 0x0b74, 0x0c74, each with
  its own hard-coded init table (`TFA/tfa_init_v6.c:871-950`). Our phone's revision is [U].
- Start (`TFA/tfa_dsp_v6.c:3088-3140, 4044-4093`): reg 0x00 = 0x0002 (I2CR soft reset); 0x0F =
  0x5A6B; read 0xFB; 0xA0 = 0xFB ^ 0x005A; the revision table; the container device items; the
  "speaker" profile items up to its Default marker; MANSCONF (0x01 bit 2) = 1, PWDN (0x00 bit 0) = 0;
  wait for CLKS (0x11 bit 7); SWPROFIL 0xEE = profile + 1, SWVSTEP 0xEF = 1; AMPE (0x00 bit 3) = 1.
  Mute = AMPE 0. Stop: AMPE 0, PWDN 1, wait MANSTATE (0x14 bits 6:3) = 0 (20 x 5 ms).
- Container `AS/odm/firmware/tfa98xx.cnt` (3979 bytes, "PM" v3, CRC OK, ONEPLUS / TFA / 9874):
  device "P" = 0x34 and "Q" = 0x35; profiles `receiver`, `speaker`, `calibrate.cal`. Common items:
  TDMNBCK 2, TDMSLLN 31, TDMSSIZE 31 (32-bit slots), current sense on, AMPGAIN 190. Per amp:
  TDMSPKS 0 / 1 (0x34 plays slot 0 = left, 0x35 slot 1 = right), TDMSPKG 7 / 5. The container is
  vendor data: a new script extracts its items at build time into a firmware-area file
  (`tfa-init.bin`); never commit it.
- Status while playing (Oplus check, `TFA/tfa98xx_v6.c:2998-3032`): reg 0x10 = 0x0016, reg 0x13 =
  0x850F. Faults: 0x10 bit 2 = 0 over-temperature, bit 3 = 1 over-current, bit 4 = 0 VBAT low,
  bit 7 = 1 no clock; 0x13 bit 9 clipping.
- Speaker gain: TDMSPKG 0x61 bits 9:6 (0..15) is an attenuation: gain = 21 dB - TDMSPKG (see the 0244 section). Impedance window 5000-8000 mOhm
  (DT); calibration in MTP (MTPEX 0xF0 bit 1, R25C reg 0xF5 in mOhm): **read only, never write MTP**.
- Bus: SE13 has GPI DMA in the DT but no `qcom,shared`; FIFO use depends on GENI_IF_DISABLE_RO
  (0xa94064 bit 0) [U: read it on the phone]. Fallback: bit-bang on GPIO48/49 at 100 kHz.
- VDD = pm8350_s10 1.8 V (on already: 18 other users [I]); VBAT from the battery; no enable pin.

Plan (boot-arg `negroniaudio=3`, log `NEGRONI TFA:`):
1. Read only: reset pulse, reg 0x03 of both amps, regs 0x00-0x27, 0x10/0x11/0x13/0x14, 0xF0, 0xF5;
   read 0xa94064. No writes but the reset GPIO.
2. Init without clock: I2CR, keys, the revision table, the container items, profile "speaker";
   read back.
3. With the stage b clock running: PWDN 0, wait CLKS/PLLS, AMPE 1 at a high TDMSPKG (low gain; 0244 uses >= 9);
   log the status regs every second.

Safety: no NXP protection algorithm. Only the on-chip protections (OCP, OTP, UVP/OVP, DCMCC coil
current limit) stay. Keep a low gain, add the software guard in the stage d sink (gain limit,
high-pass, peak limiter; HackiOS `redwood_guard.c`), amps off after 3 s of silence and on panic.

Effort: 4-7 days.

## Stage d: iOS output device (planned)

- Kernel: `/dev/negroni-audio` char device (HackiOS `redwood_audio.c` + `sys/redwood_audio.h`):
  `write()` of S16LE stereo 48 kHz frames, never blocks; ioctl SET_VOLUME / GET_STATS. ABI:
  `userland/audio/negroni_audio.h` (the kernel keeps a copy of the numbers). A sink function
  pointer connects it to stage b/c.
- User space: done in stage 0. The plug-in opens the node at StartIO (retry every 2 s) and writes
  the Speaker output to it. The D22 tunings (`d22_speaker_general`) process the samples first. iOS
  keeps the D22 speaker in software volume mode, so the plug-in volume stays at 0 dB and iOS scales
  the samples itself (HackiOS observation).
- Not needed: IOAudio2/AppleEmbeddedAudio kernel drivers, an `/arm-io` audio node in the ADT
  [I, HackiOS does without them].
- Check: SpringBoard lock sound and key clicks produce writes (kernel counter line in the log),
  then sound.

Effort: 2-4 days (mostly a port of MIT-licensed HackiOS code).

## Verification over the USB kernel log

Every stage prints one line per action and one result line in capitals (`TRUSTZONE ACCEPTS ...`,
`THE ADSP IS UP`, `SPF READY`, ...), like `negroni_adreno.c`. Read it live with `make usblog`.
The persistent log in userdata keeps the lines after a hang.

## Risks (all stages)

- Speaker damage: no NXP protection algorithm. Mitigation: low fixed gain, software guard, amps
  off on silence and on panic.
- Charging behaviour once the ADSP runs (charger PD) [U].
- audio_pd may need an AP-side servreg locator [U].
- Licensing: HackiOS kernel files are APSL 2.0 (XNU), the userland is MIT. slop has no license.
  Qualcomm/OnePlus/Linux code is GPL-2.0: read it for the protocol, write our own code.

## Files

| Path | What |
|---|---|
| `userland/audio/` | stage 0 plug-in, header, layout check, host test, build script, stage d ABI |
| `scripts/audio/root-add-audio.sh` | root hook (`AUDIO=1`), called by `scripts/ios16/root-finish.sh` |
| `scripts/audio/extract-adsp-fw.sh` | OTA (payload-dumper-go `-p modem`) or `--dump` (partition dump) -> `out/firmware/adsp/` + SHA256SUMS + LISTING.txt |
| `scripts/audio/fatcopy.py` | read-only FAT12/16/32 reader (no mtools needed) |
| `scripts/audio/mkadsparea.py` | `out/firmware/adsp-area.bin` (32 MiB) for patch 0240 |
| `scripts/audio/fetch-sources.sh` | sparse clones of the OnePlus/Linux/AudioReach sources -> `out/src/` |
| `scripts/audio/extract-vendor-audio.sh` | stock vendor/odm audio files -> `out/audio-src/` (never commit) |
| `patches/xnu/0240-negroni-adsp-boot.patch` | stage a kernel code, default off |

Run on 2026-10-24 [V]: OTA modem.img sha256 `bcd07e89...f71e`, 29 files extracted (adsp.mdt,
25 segments, 3 .jsn), `adsp-area.bin` 18.7 MB used of 32 MiB.
