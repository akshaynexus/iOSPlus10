# Audio plan (iOS 16.7.16 on the NE2211, SM8450)

Status date: 2026-10-24. Audio does not work. Nothing in this plan ran on the phone yet.

Marks: **[V]** verified in code, DT, firmware or logs. **[I]** inference. **[U]** unknown.

## Summary

The audio path has five stages. Each stage has its own boot-arg and log prefix, and each stage
is off by default.

| Stage | What | State | Effort |
|---|---|---|---|
| 0 | mediaserverd stops aborting: a HAL plug-in with a "Speaker" device that plays into nothing | planned | 1-2 days |
| a | ADSP firmware load + start (PAS id 1), SMP2P ready | **code done, untested** (patch 0240, `negroniadsp=1`) | 1-3 days of tests |
| b | GLINK + QRTR + GPR, AudioReach graph for the speaker (PRM clocks, TDM/I2S sink) | planned | 2-3 weeks, highest risk |
| c | 2x TFA9874 init over I2C, TDM slots | planned | 4-7 days |
| d | kernel `/dev/negroni-audio` + the stage 0 plug-in writes to it | planned | 2-4 days |

The model is HackiOS (`external/hackios-xnu-kernel`, `external/hackios-xnu-userland`). HackiOS plays
iOS 16.5 sound through the speakers of an SM7325 phone with an iPhone X identity (the same identity
as ours, D22). Its chain is: AudioServerPlugIn in mediaserverd -> `/dev/redwood-audio` -> kernel
sink -> ADSP. Its ADSP start (SMEM, SMP2P, GLINK, QRTR) applies to SM8450 with other numbers. Its
audio services layer (APR: AFE/ADM/ASM) does not apply: SM8450 uses AudioReach (GPR).

## Facts

| Item | Value | Source |
|---|---|---|
| Audio DSP | `remoteproc-adsp@03000000`, `qcom,waipio-adsp-pas`, PAS id 1 | live DT [V] |
| ADSP carveout | **0x85700000, size 0x2800000 (40 MiB)**. The node name says `adsp_region@85e00000`; mainline uses 0x85e00000/0x2100000, which is too small for this image | live DT `reserved-memory` [V] |
| Mu memory map | "PIL Reserved" 0x85200000 + 0x1C200000 covers the carveout; XNU RAM starts at 0x841000000 | `negroniPkg` MemoryMapLib [V] |
| ADSP firmware | `image/adsp.mdt` + `adsp.b00`-`b25` (no `b24`: BSS), 18 MiB, ELF32, 26 program headers, load 0x86300000-0x88b00000 (40.0 MiB), relocatable, hash segment 25 packed after the headers in the .mdt | `scripts/audio/extract-adsp-fw.sh` on the OTA modem image [V] |
| servreg domains | `adspr.jsn` msm/adsp/root_pd; `adspua.jsn` msm/adsp/audio_pd with service avs/audio; `battmgr.jsn` charger PD | modem image [V] |
| Rails | cx = `lcx.lvl`, mx = `lmx.lvl`, both level 384 while it boots | live DT `cx-uV-uA <0x180 0>` [V] |
| SMP2P | `qcom,smp2p-adsp`: smem items <443 429> (in, out), local pid 0, remote pid 2; IPCC client 3 signal 2; slave-kernel bits fatal 0, ready 1, handover 2, stop-ack 3, shutdown-ack 7 | live DT [V] |
| GLINK | edge pid 2, IPCC client 3 signal 0, channels `IPCRTR` (QRTR), `adsp_apps` (GPR), `PMIC_RTR_ADSP_APPS` (charger), `fastrpcglink-apps-dsp` | live DT [V] |
| GPR clients (Android) | `spf_core` port 3, `q6prm` port 7, `audio-pkt` port 0x17 (`apr_audio_svc`) | live DT [V] |
| AOSS QMP | 0xc300000, IPCC client 0 | live DT [V] |
| SMEM | 0x80900000 + 2 MiB, hwlock TCSR mutex 3 (0x1f43000) | live DT [V] |
| Speakers | 2x TFA9874 on QUP SE13 `i2c@a94000`: 0x34 (`tfa_channel 0`, reset GPIO50), 0x35 (channel 1, reset GPIO51), 400 kHz, VDD = `pm8350_s10` (smpb10, 1.8 V) | live DT [V] |
| I2C pins | SE13 GPIO48 (SDA), GPIO49 (SCL) | live DT `qupv3_se13_i2c_active` [V] |
| TDM | TERTIARY: GPIO121 SCK (`mi2s2_sck`), 123 WS, 122 DIN, 124 DOUT; group 0x9120, port 0x9020 (TERT_TDM_RX_0), data delay 1, invert sync 1, clk internal, 1.536 MHz in DT; max 8 slots; tert needs the LPASS HW vote | live DT `qcom,msm-dai-tdm-tert-rx`, `waipio-asoc-snd` [V] |
| Audio SMMU | `qcom,msm-audio-ion`: iommus `<apps_smmu 0x1801 0>`, sid mask 0xf, IOVA pool 0x10000000 + 256 MiB | live DT [V] (same SID as HackiOS) |
| Headset/mics | WCD9385 over SoundWire (`lpass-cdc` rx/tx/va macros) | live DT [V]; out of scope here |

## Stage 0: stop the mediaserverd abort (quick, no audio hardware)

Observation [V] (`logs/usblog-20261024-195455.txt`): on the first NE2211 boot mediaserverd crashed
twice with SIGABRT, at 20:27:03 and 20:41:05, at the same place both times:

```
CRASH mediaserverd[28] sig 6 code 0x0 sub 0x0 slide 0x4a48000 mh 0x1001a0000
CRASH mediaserverd pc 0x1c705f198 lr 0x1d65ee5f8 ...
CRASH mediaserverd bt 0x1926a44b8 0x1d6526f54 0x1d6517a4c 0x184b1aafc 0x1d6526424 0x1d65263d4 ...
```

The crash is deterministic (same pc/lr, same slide). It is not symbolicated yet [U].

What we know [V]:
- iOS 16 runs the audio server (CoreAudio HAL) inside **mediaserverd**. HackiOS
  `audio_plugin.c`: "the HAL of CoreAudio, inside mediaserverd". `audiomxd` is the iOS 17+ split of
  the audio server [I]; for iOS 26 the same plug-in goes into audiomxd.
- The slop root tweaks (`external/slop/tools/sweet-root-tweaks.py`, `audio()`) move
  `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin` to `HAL.disabled/` and set
  `StartRecorderServer=false`. Before that, mediaserverd crashed with SIGSEGV in VirtualAudio
  (`ApplyBeamFormerPreference`): the default virtual device `vdef` did not exist because no audio
  hardware device exists (slop NOTES, Codex `mediaserverd-report.md`).
- Without VirtualAudio, the HAL has only CoreAudio's `Null_Device`. The routing layer above it
  (MediaExperience / AudioSession, built for VirtualAudio) gets no route [I]. The SIGABRT is
  probably that layer [I].
- HackiOS keeps VirtualAudio.plugin and adds its own AudioServerPlugIn
  (`RedwoodAudio.driver`, MIT license). VirtualAudio knows iPhone devices by UID. It builds the
  speaker route only if two devices exist: **"Speaker"** (stereo output + silent stereo input) and
  **"Hawking"** (one silent input; the `vhaw` companion of `vdef` in the D22 routing tables).
  Optional: "Codec" (mic input), "Actuator" (haptics output). With those devices mediaserverd runs,
  the speaker port, the volume HUD and Control Center work.

Plan:
1. Symbolicate the two CRASH lines: `external/slop/tools/sweet-crash.py CACHE ROOT` with the
   20H392 shared cache (from `~/op10-apple/ios16-root.img`; needs `ipsw`, `brew install
   blacktop/tap/ipsw`). Record the function in this file.
2. Port `hackios-xnu-userland/userland/src/audio_plugin.c` as `NegroniAudio.driver`
   (CFPlugIn type `443ABAB8-E7B3-491A-B985-BEB9187030DB`, factory function, `Info.plist` like
   `audio_plugin.plist`). Stage 0 variant: the "Speaker" output **drops the samples** (no kernel
   device). The device clock is `mach_absolute_time()` at 48000 frames/s, so the HAL I/O thread
   paces itself without hardware.
3. Root build (`scripts/ios16/root-tweaks-extra.py`, change not made yet): put the bundle into
   `/System/Library/Audio/Plug-Ins/HAL/NegroniAudio.driver`, move `VirtualAudio.plugin` back to
   `/Library/Audio/Plug-Ins/HAL/`, keep `Library/Audio/Tunings/D22/` and
   `System/Library/Audio/UISounds/` in the root. Keep `StartRecorderServer=false` (the portrait
   prewarm calls a NULL GL function without a GPU; HackiOS skips it with `inject_media.c`).
4. Sign the bundle like the other root binaries (ldid). The negroni AMFI stub accepts it [I]
   (HackiOS: its unsigned plug-in loads under its AMFI stand-in).

Check: the USB log shows no `CRASH mediaserverd`; `exec mediaserverd` appears once; SpringBoard
shows the volume HUD on the volume keys (if the keys reach it).

If step 1 shows a different cause (for example a missing IOKit service such as
`AppleEmbeddedAudio`/IOAudio2), note it here first. iOS gets its built-in devices from Apple kernel
drivers through IOAudio2 (HackiOS `audio_plugin.c` header); the plug-in route does not need them [V].

## Stage a: ADSP start (patch 0240, implemented, UNTESTED)

Files: `patches/xnu/0240-negroni-adsp-boot.patch` (worktree `out/kernel/wt-audio`, branch
`audio`, `git diff base`). New `bsd/dev/negroni_adsp.c`; `negroni_ufs.c` gets a read-only ADSP area
reader and the init call; `negroni_rpmh.c` gets ARC level votes (the VRM path is unchanged).
Host syntax check with stubs: OK. No XNU build yet (needs the kernel CI).

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
format `NEGRADSP` (64 entries, SHA-256 each).

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

## Stage b: GLINK, QRTR, GPR and an AudioReach speaker graph (planned)

1. **GLINK SMEM transport** (Linux `qcom_glink_smem.c`, HackiOS `glink_*`): create item 478
   (descriptor) and 479 (our TX FIFO), get the ADSP's 480 (RX FIFO), version negotiation, open the
   channels `IPCRTR` and `adsp_apps`, give RX intents (`adsp_apps`: 20 x 512 bytes, DT
   `qcom,intents <0x200 0x14>`). A polling thread replaces the IPCC IRQ.
   Log: `GLINK: version 1 ok`, `channel adsp_apps open (remote rcid N)`.
2. **QRTR** on `IPCRTR` (HackiOS `qrtr_*`): HELLO, record NEW_SERVER messages. Look for the
   servreg/PD-mapper questions from the ADSP (HackiOS line 2356 saw a "locator" lookup).
   Open question [U]: the audio services are in **audio_pd**, not in root_pd (SM7325 had them in
   root_pd). Linux waits for PDR "avs/audio" UP before it uses GPR, and PD start can need a
   servreg locator on the AP (Linux `qcom_pd_mapper`). If GPR gets no answer, add a minimal
   SERVREG_LOCATOR (QMI service 0x40) server that answers from the three `.jsn` files.
3. **GPR** on `adsp_apps` (Linux `soc/qcom/apr.c` GPR mode, `audioreach.h`): header
   (version, sizes, src/dst domain APPS 3 / ADSP 2 [I: check dt-bindings], ports, token, opcode).
   First message: `APM_CMD_GET_SPF_STATE` (0x01001021) to the APM (port 1) until state = 1.
   Log: `GPR: SPF READY`.
4. **PRM** (port 2 [I]): LPASS core HW vote, then the TERT TDM IBIT clock at 48000 x 32 x slots
   (`PRM_CMD_REQUEST_HW_RSC`, `PARAM_ID_RSC_AUDIO_HW_CLK` / `PARAM_ID_RSC_HW_CORE`; IDs from Linux
   `q6prm.c`, `q6prm-clocks.h`). Pins 121-124 to the `mi2s2_*` functions (TLMM).
   Check: TLMM reads of GPIO121/123 toggle while the clock runs (HackiOS `sound=1` check).
5. **Graph** (`APM_CMD_GRAPH_OPEN` 0x01001000, `SET_CFG`, `PREPARE`, `START`): one sub-graph with
   WR_SHARED_MEM_EP -> PCM decoder/converter -> MFC -> TDM (or I2S) sink. Module IDs, instance
   IDs and the sink parameters come from one of: (i) the Android ACDB (`/vendor/etc/acdbdata`,
   in the `vendor`/`odm` OTA images, not extracted yet), (ii) Linux `audioreach-topology`
   (SM8450 HDK topology; it uses codec DMA, not TDM), (iii) a capture of AGM/PAL on Android
   (`audio-pkt` port 0x17 traffic). [U] whether a TDM sink module ID is in mainline; fallback: the
   I2S sink on MI2S2 (same pins) with the TFA9874 set to I2S.
6. **Shared memory**: map our sample buffer for the ADSP through the apps SMMU stream 0x1801
   (sid mask 0xf, IOVA from 0x10000000) like HackiOS `redwood_sound.c`, then
   `APM_CMD_SHARED_MEM_MAP_REGIONS` and `DATA_CMD_WR_SH_MEM_EP_DATA_BUFFER` per period.
   Check: `WR_SH_MEM_EP_DATA_BUFFER_DONE` events at 48 kHz pace (HackiOS `sound=2` check).

Effort: 2-3 weeks. Highest risk: the graph content (step 5) and audio_pd startup (step 2).

## Stage c: TFA9874 amplifiers (planned)

- Bus: QUP SE13 at 0xa94000. Check first whether its FIFO mode is usable; the touch SE4 had its
  FIFO disabled (GPI-only), so negroni uses GPIO bit-bang I2C (`bsd/dev/negroni_touch/tlmm_i2c.h`).
  Reuse that code on GPIO48/49 at 100 kHz.
- Reset: GPIO50/51 (pulse, then read the revision register 0x03; TFA9874 rev 0x0a74 [I]).
- Supplies: VDD = smpb10 1.8 V (already on for other users [I]); VBAT from the battery.
- Settings: the NXP container `tfa98xx.cnt` (in the vendor or odm image [U: path]; extract with a
  new script, never commit). TFA9874 has no on-chip speaker-protection DSP [I]; Android runs NXP's
  algorithm on the ADSP. We do as HackiOS did for its Awinic amps: write the container profile
  registers, no protection algorithm, keep the level low, and put a software guard (gain limit,
  high-pass, peak limiter; HackiOS `redwood_guard.c`) in the kernel sink.
- TDM: each amp takes its slot (`tfa_channel` 0/1); start the amps only while the bit clock runs,
  stop after 3 s of silence (HackiOS `sound=4` policy).
- Check: register read-back over I2C (no clock needed); then status register bits (PLL lock,
  no faults) with the clock running; then a -20 dBFS tone audible at low volume.

Effort: 4-7 days, plus finding the container file.

## Stage d: iOS output device (planned)

- Kernel: `/dev/negroni-audio` char device (HackiOS `redwood_audio.c` + `sys/redwood_audio.h`):
  `write()` of S16LE stereo 48 kHz frames, never blocks; ioctl SET_VOLUME. A sink function pointer
  connects it to stage b/c.
- User space: the stage 0 plug-in writes the "Speaker" output to `/dev/negroni-audio` instead of
  dropping it. The D22 tunings (`d22_speaker_general`) process the samples first. iOS keeps the
  D22 speaker in software volume mode, so the plug-in volume stays at 0 dB and iOS scales the
  samples itself (HackiOS observation).
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
- AudioReach graph details are not public for this board [U].
- Licensing: HackiOS kernel files are APSL 2.0 (XNU), the userland is MIT. slop has no license.

## Files

| Path | What |
|---|---|
| `scripts/audio/extract-adsp-fw.sh` | OTA (payload-dumper-go `-p modem`) or `--dump` (partition dump) -> `out/firmware/adsp/` + SHA256SUMS + LISTING.txt |
| `scripts/audio/fatcopy.py` | read-only FAT12/16/32 reader (no mtools needed) |
| `scripts/audio/mkadsparea.py` | `out/firmware/adsp-area.bin` (32 MiB) for patch 0240 |
| `patches/xnu/0240-negroni-adsp-boot.patch` | stage a kernel code, default off |

Run on 2026-10-24 [V]: OTA modem.img sha256 `bcd07e89...f71e`, 29 files extracted (adsp.mdt,
25 segments, 3 .jsn), `adsp-area.bin` 18.7 MB used of 32 MiB.
