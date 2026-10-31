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
3. FAT16 reader: `modem_b`, else `modem_a`; boot sector, FAT, root dir, `image` dir, cluster chains.
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
- FAT reader: TODO in the code. When area E's 2400 (FAT index of modem_<active slot>, `topaz_part_fw_*`) is merged,
  `fw_mount/fw_read/fw_size` go and TopazAudio calls `topaz_part_fw_*`. 2500 sorts after 2400-2402 and touches neither
  TopazModem.cpp nor sweet_ufs.c.
- Shared TopazModem.cpp fixes (scm() lock + busy retry, smmu_identity() lock, pool-vs-XNU-window check) are area E's.
- root-audio.sh: `--image` checks the fsck verify result before the sparse step (only the known Linux "Volume header
  needs minor repair" is accepted, as in root.sh); no toolchain -> warning, audio skipped, exit 0 (root.sh also goes on
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

- Microphone: the Mi A3 mics are analog on the WCD937x (Bolero TX macro 0x0a460000/VA 0x0a4a0000 + SoundWire), not on
  I2S: a codec + SoundWire driver (weeks). `/dev/redwood-mic` does not exist; the plug-in's "Codec" input stays silent.
- Headphones (WCD937x HPH + MBHC), earpiece (WCD937x EAR): same codec work.
- Haptics: the plug-in's "Actuator" writes `/dev/redwood-haptic` (absent: PMI632 LDO vibrator is area work elsewhere).
- No speaker protection (DSM): safe gains only. Louder needs the AFE DSM module + SEC_MI2S_TX IV feedback.
