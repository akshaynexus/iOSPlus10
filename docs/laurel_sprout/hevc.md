# Mi A3: HEVC/HEIC decode on iOS 16.7.16 (20H392)

Owner: "Do not convert HEIC to PNG; write a proper HEIC driver." Branch `t3/laurel-heic-driver`, 2026-11-01. Built and host-tested, NOT BOOTED.
Labels: [V] log, source or binary; [I] inference; [U] unknown.

## 1. Result

`HEVCH8.videodecoder`: a software HEVC decoder for VideoToolbox, built on FFmpeg's hevc decoder. No hook, no injection, no change to a system file.
Host result: all 48 wallpaper images (42 with alpha) are bit-exact with libde265, an independent decoder. The phone has not run it.

The PNG step (`root-wallpaper.sh`) is removed. Every HEIC stays as Apple ships it.

## 2. The old explanation is wrong: this system has a software decoder

`metal.md` section 11 and four other ports say "no HEVC hardware, so ImageIO gets no data". The 20H392 binaries do not support "no decoder". Read with
`scripts/laurel/hevc-re.sh` + `scripts/laurel/dsc-image.py` (cache UUID 8F970452):

| Step | Evidence [V cache] |
|---|---|
| ImageIO | `HEIFReadPlugin::updateHardwareDecodeOptions`: `kCMPhotoDecompressionOption_AccelerationMode` = 0 (auto) by default; 1 only for `kCGImageSourceUseHardwareAcceleration` false, 2 for true |
| CMPhoto | `__decodePixelBuffer`, `HEIFItemDecoderCreate`: mode 1 = `PreferSoftwareCodec`, 2 = `RequireHardwareCodec`. `VTDecompressionPluginClass_create` asks for hardware only with `RequireHardwareCodec`. Auto = `EnableHardwareAcceleratedVideoDecoder` true, software allowed |
| CMPhoto | `CMPhotoSupportsHEVCHWDecode` = MobileGestalt key `N8lZxRgC7lfdRS3dRLn+Ag`. Two callers: the HW queue and `__determineDecodeStrategy` (a strategy flag, no refusal) |
| VideoToolbox | `VTDecompressionSessionCreateWithOptions`: clients go to `VTDecompressionSessionRemote_Create` (mediaserverd, `com.apple.coremedia.decompressionsession.xpc`) unless `VTRunVideoDecodersInProcess` is set or the caller is `FigServer_IsServerProcess` |
| VideoToolbox | `VTLoadVideoDecoders`: a fixed list of dlopen path + register function. It holds `/System/Library/VideoCodecs/VCPHEVC.videocodec` + `VCPHEVCRegisterDecoder` and `/System/Library/VideoDecoders/AVD.videodecoder` + `AVDRegister` |
| VCPHEVC | The once-block of `VCPHEVCRegisterDecoder` calls `VTRegisterVideoDecoderWithInfo('hvc1', {IsHardwareAccelerated: false}, HEVCVideoDecoder_CreateInstance)`. No gate |
| VCPHEVC | `armv80-check` patterns on its whole `__text`: 0 instructions newer than ARMv8.0, so it can run on Kryo 260 |
| AVD | `AVDRegister` -> `AppleAVDCheckPlatform`: IOKit match on `AppleAVD`; no patch of this kernel publishes it [V grep of `patches/`], so it registers nothing [I] |

HakiOS says the same from a running phone [V `external/hackios-xnu-userland/userland/src/inject_media.c`, iOS 16.5]: "There is no hardware decoder here; VideoToolbox takes its software one (VCPHEVC.videocodec)", and it keeps mediaserverd for that reason.

Why ports saw no data [I]: flame had a decoder crash too: SIGBUS in `H264SW.videocodec` through a wrong pointer (HANDOFF "Playback"). Negroni found the cause of the same crash: plane
`bytesPerRow` at the wrong record offset, so stride 0 on every YUV surface (`docs/camera-ios-2026-10-27.md` section 14, patch 0390). A software decoder that writes through those planes dies or
writes one row; a dead mediaserverd gives `kCMPhotoError_XPCError` and an image with no data. Mi A3 has that fix as patch 2001.

**Where the call fails on the Mi A3 now: [U]. No log shows a HEVC decode failing.** All boot logs have 0 lines about it, and the 18:40 black wallpaper was attributed to HEIC by inference only. Candidates: (1) nothing fails in
the decoder and the black wallpaper has another cause (CollectionsPoster, CA, Metal); (2) mediaserverd dead at that moment: [V] `low swap` killed it at 2689 MB in earlier boots; (3) a surface format or XPC fault. Section 8 tells them apart on the phone.

## 3. Path decision

| Path | Verdict | Why |
|---|---|---|
| (a) Apple's VCPHEVC alone | The fallback, always present | [V] reachable with no gate. [U] on this phone. It logs only through syslog, so a failure stays invisible |
| (b) Own plug-in with FFmpeg | **Chosen** | Works without any Apple hardware; host-proven; 8/10/12 bit, mono, 4:2:0/4:2:2/4:4:4; logs each step to the USB log; has a kill switch; VCPHEVC stays behind it |
| (b') Own plug-in with libde265 | No | [V its source tree] NEON only for 32-bit ARM, no arm64 assembly: slow on A53/A73 for each 512x512 tile. Used here as the independent test reference |
| (c) Venus hardware | Later, for video only | Section 9 |

Why (b) and not only (a): the owner asked for a real decoder, and the plug-in is the first thing in this path that gives a line per process. It also splits the question: `laurel_hevc=0` runs the same boot on Apple's decoder. If both draw, Apple's is enough and this plug-in, with its LGPL and patent notes, can go (section 10).

Limit: if the fault is outside the decoder (mediaserverd dead, XPC, IOSurface, CA), this plug-in alone does not end a black wallpaper. It will show that in the log.

## 4. How it fits

- **Slot** [V]: `VTLoadVideoDecoders` lists `/System/Library/VideoDecoders/HEVCH8.videodecoder` + `HEVCH8Register`. The iPhone X system has no such file (not in the image list of the cache, not in the OS image). VT dlopens it and calls the function in every process that fills its registry. A failed dlopen is silent, so the build checks imports against the cache.
- **Who runs it**: mediaserverd, for all clients (section 2): wallpaper layers, Photos, Safari need no entitlement and no sandbox rule of ours: they speak XPC to mediaserverd as on stock iOS. The file is on the root under `/System`, ad hoc signed, no entitlements: as `NegroniCamera.driver`, which [V] runs in mediaserverd now. A process that loads it in-process gets a harmless registration.
- **Order** [V `vtSortRegistryItemsByRating`]: higher `kVTVideoDecoderInfo_Rating` first; VCPHEVC has none. Ours: 100. `IsHardwareAccelerated` false, honestly: `VTIsHardwareDecodeSupported('hvc1')` stays false, and a caller that requires hardware still gets none.
- **ABI** [V, private; all through dlsym]: `CMDerivedObjectCreate(alloc, vtable, VTVideoDecoderGetClassID(), &out)`, vtable `{NULL, base, class}` (VCPHEVC 0x1e22b6868). Base class v1: storage size, invalidate +0x18, finalize +0x20, debug +0x28, copy +0x30, set +0x38. Decoder class v3 [V VT's callers]: start +0x08, decode +0x10, copy supported +0x18, set +0x20, serializable +0x28, canAccept +0x30, finishDelayed +0x38. `VTDecoderSessionEmitDecodedFrame(session, frame, status, info, image)`.
- **Output**: `VTDecoderSessionGetDestinationPixelBufferAttributes` is read first. 8-bit: `420f`/`420v`; 10-bit: `xf20`/`x420` (value in the high bits); mono: `L008` when asked for, else 4:2:0 with neutral chroma; VT's pixel transfer does the rest. 4:2:2 and 4:4:4 become 4:2:0 by dropping samples. Colour tags: format description first, else the stream.
- **Threads**: slice threads for a session without temporal processing. [V host test] a tile comes out at once (held back 0 of 48 files). With `kVTDecodeFrame_EnableTemporalProcessing`: frame + slice threads, pictures come later. Each frame handle goes back once; the rest at `finishDelayedFrames`.

## 5. Self-checks and failure

| Case | Result |
|---|---|
| `laurel_hevc=0` boot-arg | not registered, one `off` line, VCPHEVC decodes |
| HEVC=0 at root build | file not in the root |
| A private symbol missing | not registered, one `off` line naming it |
| Plane `bytesPerRow` under the width (the old stride-0 bug) | frame refused with one line; the check is real on every frame |
| Crash before a process's first picture | Dead-man: one strike per process start, cleared by a good picture. At 3: `create_instance` refuses, VT takes VCPHEVC. File: `/var/mobile/Library/Caches/laurel-hevc-strikes`, else `/var/tmp`, `/tmp`. No writable folder: the `on` line says `dead-man off` |
| Bad sample | error for that frame only, one line |

Failure of this file never touches Wi-Fi, USB or the boot. The worst case [I] is mediaserverd restarts until the third strike: sound and camera drop for those seconds.

## 6. Build

`scripts/bg.sh heic-build scripts/laurel/hevc-build.sh` (host clang, theos ld64, iPhoneOS16.5.sdk; about 3 minutes): FFmpeg n7.1.1, commit db69d06eeeab, fetched by git, never changed, `--disable-all` + the hevc decoder, `--disable-dotprod --disable-i8mm`, `-mcpu=cortex-a53`. Result: 1 619 808 bytes, one export. `armv80-check: 0 instructions newer than ARMv8.0`. `hevc-check-imports: 150 imports ... missing: none; private missing: none`.
`scripts/laurel/build-all.sh` builds it; `scripts/laurel/root.sh` calls `root-hevc.sh` (HEVC=0 skips). RE inputs: `scripts/laurel/hevc-re.sh` (no third-party binary).

## 7. Host test

`scripts/bg.sh heic-test scripts/laurel/hevc-host-test.sh`. The same `hevc_core.c` as the plug-in, with FFmpeg's C code on x86_64. Python reads the HEIF boxes as CMPhoto would, the program decodes as VT would, and the reference is libde265 through ctypes, tile by tile. (`heif-dec` itself un-premultiplies these layers, so its planes differ on purpose; it checks the size only, after `clap`.)

| Input | Result [V 2026-11-01] |
|---|---|
| 48 stock wallpaper images from 20H392 (`/Library/Wallpaper/Collections`), tile grids 512x512, one 650x684 single | 48 PASS: Y, Cb, Cr all infinite PSNR (identical) |
| Their 42 alpha images (monochrome 4:0:0) | 42 PASS: identical |
| Picture timing | tiles held back 0, 12 tiles of Body 1271x1823: about 165 ms on the x86 C path (says nothing about the phone) |
| Made clips with B-frames: 8-bit, 10-bit, mono 8, mono 10, 4:2:2 10-bit, slice and frame threads | 10 PASS: 30 of 30 pictures, output order differs from input, luma identical with libde265 |

**Not tested on any host:** FFmpeg's aarch64 NEON assembly, the code the phone runs. The static scan is clean (0 newer instructions), and upstream tests it, but here it has never run. A run under `qemu-aarch64 -cpu cortex-a53` needs an arm64 libc: the fetch and build of musl for that was refused by this session's permission check. The owner decides; it is the cheapest next proof.

## 8. Phone test (only the phone can prove these)

Only the phone: dlopen in mediaserverd, the private ABI, `CMDerivedObjectCreate`, pool and IOSurface for `420f`/`L008`/`x420` on our kernel, what CMPhoto asks for alpha, XPC of surfaces to clients, colours on screen, NEON output, speed on A73/A53, memory, Photos, Safari, video. The registry fills at the first decoder use: a boot with no HEVC use has no line.

Root build: `laurel-root: hevc: on: HEVCH8.videodecoder, 1619808 bytes, sha256 cec33ddebb6191d1`.
USB log (`grep 'LAUREL HEVC'`):
```
LAUREL HEVC: on: FFmpeg db69d06 software decoder for 'hvc1', rating 100, ahead of VCPHEVC; dead-man /var/mobile/Library/Caches/laurel-hevc-strikes, 0 strikes
LAUREL HEVC: first frame in mediaserverd[PID]: 512x512 8-bit chroma_idc 1 -> '420f' in N ms: status 0
LAUREL HEVC: first frame in mediaserverd[PID]: 512x512 8-bit chroma_idc 0 -> 'L008' in N ms: status 0
```

Steps (root rebuild + flash need the owner):
1. `scripts/bg.sh laurel-root sudo scripts/laurel/root.sh`; the owner flashes as `scripts/laurel/root.sh` says at its top; boot.
2. Look at the home wallpaper and lock wallpaper. Open a HEIC in Photos (take a photo, it is HEIC). Open a HEIC page in Safari.
3. `grep -E 'LAUREL HEVC|CRASH mediaserverd|low swap' <usb log>`.
4. Boot once with `laurel_hevc=0` and repeat.

| Result | Meaning |
|---|---|
| Wallpaper right, `first frame ... status 0` | Done. Step 4 says if Apple's decoder is enough too |
| Black, `first frame ... status 0` | Decode is good: the fault is after it (CA, Metal, poster). Not HEVC |
| Black, no `LAUREL HEVC` line | dyld refused the file, or nothing asked to decode. Next: is a poster running; `first frame` missing with a HEIC in Photos means the load failed |
| Black, `on` line, no `first frame` | Decode was not requested, or the process died: look for `CRASH mediaserverd` |
| `frame refused`, `no pixel buffer attributes` | Surface layer: the line has the numbers |
| Good with plug-in, black with `laurel_hevc=0` | VCPHEVC fails here: keep the plug-in |
| Black in both, with `first frame` | The decoders are not the cause |

## 9. Venus hardware decode: realistic, later, not for stills

[V `external/laurel-mainline/drivers/media/platform/qcom/venus`] Mainline has a Venus driver, about 16 kLOC of C with V4L2, and no SM6125 entry (nearest: qcm2290, sdm660); downstream `msm_vidc` and `trinket-vidc.dtsi` are in `external/laurel-kernel-los`. A port needs on XNU: firmware load through PAS (`venus.mdt` from the phone, no git), its reserved memory, GCC clocks and GDSCs, interconnect votes, a SMMU context bank, HFI queues + interrupt, then a user client and a `VTVideoDecoder` that wraps it, with IOSurface import for its buffers. Weeks [I]; each step can hang the SoC. HEIC stills do not need it: tiles are 512x512. It matters for 1080p video, where software will be weak on 4 A73 + 4 A53 [I, not measured]. Plan: measure the plug-in on video first.

## 10. License and patents, for the owner

- **FFmpeg**: LGPL-2.1-or-later as configured (`License: LGPL version 2.1 or later` in its configure log; no `--enable-gpl`). The plug-in links it statically. LGPL allows that if the receiver can relink: the recipe is `scripts/laurel/hevc-build.sh`, and its source is at a public pinned commit. Nothing is shared now: the root is private. If a binary is ever shared, give the FFmpeg source and the relink recipe with it. `THIRD_PARTY_NOTICES.md` lists it.
- **HEVC patents**: HEVC is covered by patent pools (Access Advance, Via LA, Velos Media) and others. FFmpeg's license gives no patent rights. Apple's own decoder is under Apple's licences, for Apple's devices. Own experiments on a private phone carry a low practical risk [I]; distributing or selling a decoder is a different matter. This is no legal advice. To carry no third-party decoder, set `HEVC=0`: Apple's code alone, if section 8 shows it works.
- **libde265, musl, ipsw**: not shipped, not in the root. libde265 is only the host test reference.
