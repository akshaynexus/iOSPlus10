# Mi A3 (laurel_sprout) speaker audio

Kernel patch `patches/laurel/xnu/2500-laurel-audio-speaker-apr.patch` (TopazAudio.cpp + sweet_i2c1.c), HAL plug-in
`userland/laurel/audio/build.sh`, root install `scripts/laurel/root-audio.sh` (root.sh calls it). Area F of the
2026-11-01 parallel session, branch `t3/laurel-audio-speaker-adsp`. Status: **built, not booted** (no phone access
for this agent; the coordinator tests).

## Facts found [V]

| Item | Value | Source |
| --- | --- | --- |
| ADSP firmware | `QC_IMAGE_VERSION_STRING=ADSP.VT.5.4-00283-NICOBAR-1`, OEM `c4-xm-ota-bd035.bj`, 2021-11-19 | strings of `image/adsp.b*` in `~/laurel-backup/stock/images/NON-HLOS.bin` |
| Protocol | **Elite / APR**: string `apr_audio_svc` present, `adsp_apps` (GPR) absent, 88 `elite` strings, no AudioReach | same |
| Image files | `image/adsp.mdt` + `adsp.b00`..`b27` (29 files, 5.3 MB largest), FAT16, 4 KiB sectors, 4 sectors/cluster | `mdir -i NON-HLOS.bin ::/image` |
| Segments | phdr 1 = hash (0x57500000, 0x1f18 B); loadable 0x55300000..0x57500000 = the whole carveout 0x2200000, relocatable (bit 27) | ELF phdrs of adsp.mdt |
| pd-mapper | `adspr.jsn` root_pd, `adspua.jsn` audio_pd (tms/servreg + avs/audio), `adsps.jsn` sensor_pd, instance 74 | the jsn files; equal to topaz's `pd_map` table |
| SMP2P / GLINK | SMP2P items 443 (in) / 429 (out), APCS bit 10; GLINK lpass edge APCS bit 8, channels `IPCRTR`, `apr_audio_svc` | Q trinket.dtsi:1599-1830 (same numbers as topaz) |
| PIL proxy votes | VDD_CX TURBO, CXO, mas-crypto (not sent: topaz boots its modem PAS without them) | Q trinket.dtsi:1263 |
| Audio SMMU | `msm_audio_ion` iommus `<&apps_smmu 0x41 0>`, `qcom,smmu-sid-mask 0xf` -> address msw = 1 | Q trinket-audio.dtsi:16 |
| Speaker path | SEC_MI2S_RX (`dai_mi2s1`, rx-lines 1 = SD0), 48 kHz S16_LE 2 ch, CPU master (CBS_CFS), IBIT 48000 x 2 x 16 = 1.536 MHz | techpack/audio/asoc/sm6150.c 420, 697-730, 5600-5650, 5891 |
| Pins | SEC_MI2S GPIO 125..128 EAST tile (0xd00000), function 2 `sec_mi2s`, 8 mA; amp reset GPIO 95 SOUTH (0x900000); I2C GPIO 4/5 WEST (QUP0 SE1) | X laurel_sprout-trinket-pinctrl.dtsi, pinctrl-trinket.c |
| Amp | `maxim,max98927L` at I2C 0x3a on QUP0 SE1, mono; chip is MAX98927 (REV_ID 0x01ff bit 6) or MAX98937 (0x0600 bit 6); 16-bit register addresses | X laurel_sprout-trinket-audio.dtsi, asoc/codecs/max98937.c |
| Amp protection | Android runs Maxim DSM inside the ADSP AFE with IV feedback on SEC_MI2S_TX; without DSM the vendor driver uses `spk_safe_gain 1`, `digital_safe_gain 44` | max98937.c 1590-1606, 2838-2841 |
| Microphones | analog mics on WCD937x (TX macro + SoundWire): no I2S mic | X laurel_sprout-trinket-audio.dtsi routing |
| DRAM at the pool | 0xE0000000 (TopazModem pool, 16 MiB, shared bump allocator with area E) is in Mu "Pool RAM" (reserved), below XNU's window 0xE1004000-0x1AD004000 (area A) | docs/laurel_sprout/uefi-boot.md "Memory map" |

## What the kernel does (patch 2500)

Order (one thread, polled, like topaz):
1. `topaz_soc_map()` (waits for UFS, maps SMEM, pool, APCS) -> `/dev/topaz-audio` + `/dev/redwood-audio` (0935 alias)
   are made now, so mediaserverd's plug-in can open them at load time; writes are dropped until the path is up.
2. Refuse when SMEM already has items 443/480 (a DSP of an earlier run).
3. Firmware through `topaz_part_fw_size/read` = TopazModem's FAT index of modem_<active slot> (area E, patch 2400);
   2500 needs 2400 (it had its own FAT16 reader until E's review fixes landed).
4. PAS 1: init_image (metadata in the pool), mem_setup, segments into 0x55300000, auth_and_reset; SMP2P READY.
5. GLINK + QRTR + pd-mapper (topaz code), APR channel `apr_audio_svc`; `AVCS_CMD_ADSP_EVENT_GET_STATE` every 200 ms
   until 1 (30 s limit).
6. Amp: GPIO 95 low 1 ms / high, REV_ID, vendor "mono" channel map + common map, I2S slave 16-bit 48 kHz BSEL 32, safe
   gains, global/amp enable off. SEC_MI2S pins. Apps SMMU identity context for SID 0x41 (`topaz_smmu_identity`).
7. Self-check = the whole path once with silence and the amp off: AFE clock + I2S config + start, ASM map (8 x 4 KiB
   periods in the pool, msw 1), ADM open (NULL COPP, 2 ch 16-bit 48 kHz, port 0x1002), ASM open write v3, route, media
   format, run, 8 writes; the DSP must give 2 periods back in 500 ms; then close + stop.
8. One line: `LAUREL AUDIO: on: ADSP up (APR), MAX98927 rev 0x.., SEC_MI2S 48 kHz (2 periods back in N ms)` or
   `LAUREL AUDIO: off: <reason>` (the reason names the step: PAS, READY, APR core, amp I2C, SMMU, DSP periods).
9. Playback: a write that is not silence (|s| > 8) starts the path (same sequence) and unmutes the amp; each period the
   DSP returns is refilled from a 16384-frame ring (volume ioctl applied in Q15); 2 s without sound: amp off, ASM/ADM
   close, AFE stop + clock off. Write tokens carry a generation, so events of a closed stream are ignored.

Kill switch: `adsp=0` or `laurelaudio=0` (the node stays, audio off). A failure turns off only the sound; the ADSP is
left running after a failure in steps 5-7 (GLINK/pd-mapper keep being served).

Log lines to look for (USB log): `TopazAudio: firmware: modem_b, 29 adsp files`, `PAS init_image: ret=0 res=0`,
`PAS auth_and_reset: ret=0`, `slave-kernel 00000002 READY`, `glink ADSP OPEN "apr_audio_svc"`, `apr: ADSP core state 1
READY`, `amp: MAX989x7 rev 0x.. at 0x3a configured`, `SEC_MI2S pins 125..128: cfg 0c8 ...`, `smmu: audio identity (sid
41 ...) -> OK`, then the `LAUREL AUDIO:` line; at a sound `stream: playing (start N)` and `stream: stopped (...)`.

## Memory rule (after area A, 2026-11-01)

Every buffer the ADSP reads needs a PA below 4 GiB: the audio SID's low bits go in the upper address word (msw = 1).
XNU now runs at 0xE1004000-0x1AD004000, mostly above 4 GiB, so nothing the ADSP reads may come from the kernel heap.
- ADSP reads: carve-out 0x55300000 (fixed), PAS metadata and the 8 periods (TopazModem pool 0xE0000000, checked
  `< 4 GiB` at allocation: else `PAS ... not below 4 GiB` / `LAUREL AUDIO: off: periods at ...`), GLINK FIFOs (SMEM).
- CPU only: the 64 KiB ring (IOMallocZero; writer -> ring -> period_fill copies into the pool), FAT buffers (UFS DMA
  goes to sweet_ufs's bounce buffer, below 4 GiB since 2100), the APR packets (copied into SMEM by GLINK).

## Review fixes (2026-11-01, after review "ACCEPT-WITH-FIXES")

- 4 GiB checks above; core-poll token 0x40000000 (call tokens < 0x01000000, writes bit 31); `vol_applied = ~0u` after
  the self-check; a failed period send is re-queued (bit back in `returned`); devfs order rule in the comment of
  `audio_dev_init` (devfs_make_node before vfsinit panics; only after the UFS wait); idle wait 20 ms for 1 s after
  GLINK traffic, then 200 ms (5 wakeups/s; a write wakes the thread at once); `PAS auth_and_reset: ... N ms` (no proxy
  votes sent: a slow crypto engine shows here).
- FAT reader: removed. The branch is rebased on area E (origin/t3/laurel-wifi-modem-firmware 282bc27, which holds
  laurel-int-1); TopazAudio calls `topaz_part_fw_*` (2400 index of modem_<active slot>) again. 2500 sorts after
  2400-2404 and touches neither TopazModem.cpp nor sweet_ufs.c.
- Shared TopazModem.cpp fixes (scm() lock + busy retry, smmu_identity() lock, pool-vs-XNU-window check) are area E's
  patch 2404 (in this branch now).
- root-audio.sh: `--image` checks the fsck verify result before the sparse step (only the known Linux "Volume header
  needs minor repair" is accepted, as in root.sh); no toolchain -> exit 1, table row `audio missing` (root.sh goes on to the other features, then exit 1
  if the script fails); `--image` is Linux only (stated in the script).
- Open question from the review: VirtualAudio back on. RedwoodAudio always publishes "Speaker" + "Hawking" (also when
  `/dev/redwood-audio` does not open), which removes topaz's crash cause; count `CRASH mediaserverd` over several boots
  before calling it fixed.

## Userland

- `userland/laurel/audio/build.sh`: topaz/HackiOS `audio_plugin.c` unchanged -> `out/laurel/audio/RedwoodAudio.driver`.
  Linux: theos clang 11 + ld64-609 + ldid, MacOSX13.3.sdk headers, `.tbd` stubs of libSystem/CoreFoundation from the
  object's undefined symbols (no iOS SDK needed). macOS: Xcode iPhoneOS SDK. Checks: arm64 bundle, minos 16.0, one
  export `_RedwoodAudio_Create`, only libSystem + CoreFoundation. [V] builds on this Linux host (69296 bytes).
- `scripts/laurel/root-audio.sh MOUNTED_ROOT` (root.sh step 2, `AUDIO=0` skips) or `--image ROOT.img` (existing image:
  mount, install, fsck, new .simg; run in tmux): plug-in to `/System/Library/Audio/Plug-Ins/HAL/`, VirtualAudio.plugin
  back from `HAL.disabled` (topaz moved it out because without "Speaker"/"Hawking" it crashed mediaserverd), and
  BTAudioHALPlugin.driver to `HAL.disabled` (no Bluetooth stack; its XPC trapped mediaserverd on negroni).
  [V] tested on a fake root (idempotent).

## Not done / open

- Microphone: done, see "Microphone" below (patch 2920, built, not booted).
- Headphones (WCD937x HPH + MBHC), earpiece (WCD937x EAR): not done. They share the codec and its rails, but need more:
  the RX macro + RX SoundWire master, class-H, the jack sense (MBHC), and new HAL devices. See "Microphone": what is reusable.
- Haptics: the plug-in's "Actuator" writes `/dev/redwood-haptic` (absent: PMI632 LDO vibrator is area work elsewhere).
- No speaker protection (DSM): safe gains only. Louder needs the AFE DSM module + SEC_MI2S_TX IV feedback.

## Microphone (patch 2920, plug-in `mic-input.patch`, 2026-11-01). Status: **built + host-tested, NOT BOOTED**

Owner: "Voice input is not working." Cause [V]: no kernel `/dev/redwood-mic`, no codec driver. The plug-in's "Codec" input was
already there and read silence.

### The path [V, sources, not the phone]

| Item | Value | Source |
| --- | --- | --- |
| Main mic | AMIC1, analog, MIC BIAS1 1.8 V | X laurel_sprout-trinket-audio.dtsi routing; trinket-audio-overlay.dtsi `cdc-micbias1-mv` (laurel has no override) |
| Other mics | AMIC2 = headset, AMIC3 (ADC2 MUX INP3) = second mic | mixer_paths_qrd.xml `amic2`, `amic3`, `handset-mic` |
| Codec | WCD937x. **SoundWire, not SPMI**: TX slave 0x01170223, RX slave 0x01170224 | trinket-audio-overlay.dtsi. Rouleur (SPMI) is not on this board. So `sweet_spmi.c` is not used |
| Rails | L9A (static) + L14A (on demand), 1.8 V, RPM `ldoa` | same; trinket-regulator.dtsi |
| Reset | GPIO 120, SOUTH, 0x978000: gpio, 16 mA, output | trinket-pinctrl.dtsi, pinctrl-trinket.c |
| SoundWire pins | GPIO 106, 107, 108, EAST, function 1 `swr_tx`, 10 mA, bus hold (TLMM, not LPI on this board). Slew 0xD8E000 = 3 | same; `bolero` `slew_rate_reg1` |
| Master | TX SoundWire 0x0a470000; port 2 = ADC1; codec port 0 | `qcom,swr-port-mapping`, `qcom,tx_swr_ch_map` |
| Port timing | 50 rows x 16 cols, 9.6 MHz, ssp 6; `tx_frame_params_superset[1]`: si 3, off1 1, off2 0, lane 0 | swrm_port_config.h, swr-mstr-ctrl.c |
| Digital | TX macro 0x0a460000: `TX SMIC MUX0` ADC0, `TX DEC0 MUX` SWR_MIC, DEC0, 48 kHz, gain +18 dB. VA macro 0x0a4a0000: fs-gen only (`qcom,va-without-decimation`) | mixer path `amic1` + defaults (`TX_DEC0 Volume` 102), tx-macro.c |
| Analog gain | `ADC1 Volume` 12 | mixer path `amic1` |
| Clocks | AFE clock 0x30c + 0x30d, 19.2 MHz. No `lpass_core_hw_vote` on trinket (sm6150 has it) | trinket-audio-overlay.dtsi |
| AFE | TX_CDC_DMA_TX_3 0xB037, `AFE_PARAM_ID_CODEC_DMA_CONFIG`, 48 kHz 16-bit 1 ch, mask 1 (DEC0) | audio_platform_info_qrd.xml, mixer path `audio-record`, sm6150.c |
| ADM / ASM | ADM record COPP (NULL topology), matrix TX; ASM session 2, open read v3, 8 reads of 20 ms | the APR commands of redwood_mic.c (works on redwood), q6asm.c, q6adm.c |

Mi A3 differences from the redwood driver [V]: WCD937x has no TX clock rate register and no `TX_ANA_MODE`; the master is older
(no `COMP_STATUS`, no HCTL write in the 4.14 driver); no LPASS votes; pins on the TLMM; DEC0 instead of DEC1; one codec DMA mask.

### What runs

- Kernel: patch 2920, `TopazAudio.cpp` includes `LaurelMic{Regs,Hw,Codec,Ring,Path,Stream,Dev}.inc`. Everything is on the audio thread,
  because GLINK and APR have no locks. `mic_wait()` pumps GLINK and the speaker during the bring-up.
- Boot: `mic_self_check()` runs the whole path once after the speaker's check. It does not need the speaker to be up.
- Node `/dev/redwood-mic`, mode 0666, but `d_open` admits only `mediaserverd`, `audiomxd` or root. **Why:** every app runs as `mobile`, so the mode
  bits cannot stop an app, and TCC sits above the HAL. An open by the audio server starts the path; close stops it (codec back in reset). A read never
  waits: ring of 341 ms, reader kept 40 ms behind, what is missing is silence in the plug-in.
- Capture gain: `ioctl _IOW('r', 2)`, eighths of a dB under the top: DEC0 gain 18 dB down to -6 dB. HAL: a volume control on the Codec input, 24 dB,
  **no mute**: if VirtualAudio sets it to 0 the mic is quiet, not dead, and the rms line shows it.
- Plug-in: `userland/laurel/audio/mic-input.patch` on the topaz source (only the volume control; "Codec" and `imic` were there).

### Log lines

```
TopazAudio: /dev/redwood-mic: ready
TopazAudio: mic: SoundWire 0x........, codec device 1, chip 0x.., variant 0x.
LAUREL MIC: on: WCD937x TX device 1 (chip 0x.., variant 0x.), SoundWire 0x........, TX_CDC_DMA_TX_3 48 kHz mono (2 reads back in N ms)
LAUREL MIC: off: <reason>                (mic=0, adsp=0, no clock, no WCD937x on SoundWire, DSP refused a command, N of 2 reads, 3 failed starts, ADSP fatal)
TopazAudio: mic: recording N: path up in N ms
LAUREL MIC: first capture: rms N (peak P, F frames)      (once per boot, 1 s of samples after the filter settled)
TopazAudio: mic: recording N ended after N ms: F frames, rms R, peak P, N reads, N errors, N skipped, N dry
TopazAudio: mic: codec 0x....: wrote 0x.., reads 0x..       (up to 8; not fatal: Android never reads these back)
TopazAudio: mic: open refused for NAME
```
Plug-in (mediaserverd's stderr, only if a syslog relay shows it): `redwood: audio: the microphone is listened to (/dev/redwood-mic: open)`,
`...first samples...`, `the capture gain is ...`, `the microphone stops: ...`.

Reading the rms: 0 = no data at all (port wrong or decimator muted). A few tens or less, no change when you clap = noise floor only (apollo saw peak 197
at the wrong routing): wrong mic, no bias, or a mux. Hundreds or more and it follows the voice: it works.

### iOS side (task: can iOS see it)

- Input route [V code, other ports]: VirtualAudio makes the built-in mic port from a device with UID "Codec" and a data source it knows (`imic`). The plug-in
  has both. Both other ports with this plug-in and the D22 identity (redwood, apollo) record: hackios notes, "Voice Memos records and draws the wave";
  apollo boot 93 "the audio recorder ... the mic is 100% working". Mi A3 has the same identity (`mkadt.py`: D22AP, iPhone10,3). **On this phone: [U].**
- MobileGestalt `microphone` [I]: iOS answers it per product (D22), not from hardware. Nothing in this repo overrides it, and those two ports did not. Not read
  on the Mi A3. Apollo used `mgcache-reset.txt` once around its first mic boot, cause unclear: if Voice Memos never starts I/O, reset the cache once.
- TCC: `tccd` needs Sandbox ops 5/6: patch 2903 has them [V code]. With ENOENT there, every TCC request failed. Apollo's "red button does nothing" went away after
  its sandbox fixes (boot 93) [I that it was the cause]. Expect a permission prompt for Voice Memos.
- MediaSafetyNet [V hackios `rc.jobs.mic`]: mediaserverd stops a background recorder after about 9 s without the status bar pill. Test in the foreground app.
- Siri + Dictation: need assistantd + Apple network services: not reachable, not tested.
- `system-features.md` said "Voice Memos opens, records silence": no log line backs it. `logs/` has no plug-in lines (mediaserverd's stderr is not in the kernel log) [V].

### Camera link

`-[BWAudioSourceNode start:]` hook (`userland/camera/media_hooks.c`) does **not** block capture audio. It only changes the error 'nope' into success. The stock comment
says the node's capture session goes through a brokered HAL plug-in that is absent; that may be a different plug-in from ours [U]. Removing the hook would bring back the
preview bursts if 'nope' stays, so it **stays**. New line for the decision: `negroni: camera hooks: the session's audio source started: video records sound`, else the old
`...there is no capture audio on this phone...`. Video with sound is therefore unproven. The guard that does not pass on a NULL sample buffer (`emit_sample_buffer`) stays too.

### Headphones and earpiece (not done, did not block the mic)

Reusable: rails, reset, SoundWire helpers, codec init. New work: the RX macro 0x0a440000, RX master 0x0a450000 (ports `rx_frame_params`, RX SWR pins), RDAC/EAR/HPH + class-H sequences, RX_CDC_DMA_RX_0
(ASM + ADM + AFE), MBHC for the jack, and HAL devices VirtualAudio knows ("Receiver", "Headphones"). Mixer paths `handset`, `headphones` hold the routing.

### Tests

- Host: `scripts/laurel/mic-host-test.sh`: `hal_test.c` (the real plug-in with a mock node: what iOS sees, samples, short read, read error, mic off, gain, playback untouched) and `seq_test.c`
  (2920's sequence on a register model; the expected values are the stock driver's, written out by hand; ring + rms). Passing proves the sequence and the plug-in, **not the chip, the DSP or iOS**.
- Phone (flash kernel image + root; owner approves):
  1. Boot. `grep "LAUREL MIC" usblog`: the `on` line. `off` names the step.
  2. Play a sound: the speaker must still work (`LAUREL AUDIO: on`).
  3. Open Voice Memos, allow the microphone, record 10 s while you talk. Expected: the timer + wave, orange dot; lines `mic: recording 1: path up`, `LAUREL MIC: first capture: rms N` with N in the hundreds.
  4. Stop, play the memo back.
  5. Clap near the bottom, then cover the mic: rms and peak in `recording N ended` must change.
  6. Play music while recording: the speaker must not stop. A click at the path's start is expected ([I] the bring-up holds the audio thread for about 100 ms).
  7. Camera video: which of the two camera hook lines comes.
  8. Boot with `mic=0`: `LAUREL MIC: off: kill switch (boot-arg mic=0)`, the speaker works, Voice Memos records silence.
