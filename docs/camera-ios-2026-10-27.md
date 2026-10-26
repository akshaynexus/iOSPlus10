# Camera.app live image: the iOS side (plan, 2026-10-27)

Marks: [V] seen in a source or a tool output (file:line or command), [I] inference. Kernel side: patches 0317, 0318
(and 0249 for the SMMU helper), `patches/xnu/README-camera.md` "0317, 0318 and 0249". Background:
`docs/references-2026-10-27.md` section 3, `docs/hackios-2026-10-26.md` section 5.

## 1. Why Camera.app is black today [I, from HakiOS + our cache strings]

- [V] `out/camera/ios-stack.txt`: CMCapture logs `<<<< BWFigCaptureDeviceVendor >>>> %s: Cannot find AppleH13CamIn
  driver` when no Apple ISP driver exists. `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` then returns
  nil, the capture session has no device, and the preview stays black.
- There is no kernel frame stream either: 0315 takes one frame at boot only, and its buffers could never be
  allocated (below 4 GiB, fixed in 0317).

## 2. The chosen path: HakiOS's device vendor, not AppleH10CamIn [V]

HakiOS (`out/src/hackios-next`, HEAD 8851317) shows the stock Camera.app preview, AF, zoom and HEIC stills on its
phone without any Apple ISP emulation:

- `userland/src/inject_media.c:98-125`: a replacement for `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]`.
  When the original returns nil and the camera device exists, it returns
  `[[BWFigCaptureDeviceVendor alloc] initWithDeviceCreateFunction:hakios_camera_device_create]`.
- `userland/src/camera_device.c` (1 828 lines, MIT): a FigCaptureDevice + FigCaptureStreams as CoreMedia derived
  objects (vtables of H10ISP 16.5), frames from the kernel device -> CPU ISP -> CVPixelBuffers through the stream's
  `VideoOutputHandlers` blocks; formats named as in `CMCapture.framework/D22/AVCaptureSession.plist`.
- `userland/src/camera_isp.c` + `.h` (1 033 lines, MIT): black level, lens shading, AWB, AE (writes EXPOSURE commands
  back to the kernel), CCM, gamma, demosaic, zoom.
- `inject_media.c:484-505`: 8 method replacements, each checked against the expected unslid address (a mismatch
  leaves the method alone: fails safe, `:517-533`). Constructor `:536-560`: mediaserverd only, registers the HEVC
  encoder for HEIC, `_dyld_register_func_for_add_image` (CMCapture loads later).
- ADT: `/arm-io/isp` with only `camera-rear` = 1 (MobileGestalt `still-camera`, `rear-facing-camera`; SpringBoard
  shows Camera.app), `/product/camera` (MobileGestalt `video-camera`; `flash` only with a torch driver)
  (`docs/ru/notes.md:1712-1722`).

Our kernel ABI is now the same as theirs (0318): `/dev/negronicam` with `struct hakios_camera_frame` /
`hakios_camera_command` layout (120-byte header, magic `NCFRAME1`). Licence: their `userland/src/*` is MIT (keep the
"the HakiOS authors" notice); their kernel camera driver is APSL and is not used.

## 3. Hook addresses for 20H392 [V, `ipsw dyld symaddr out/dsc/cache/dyld_shared_cache_arm64 --image CMCapture`]

| Method | HakiOS 20F66 | ours 20H392 |
|---|---|---|
| `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` | 0x1a1ef0d04 | **0x1a1f40c84** |
| `-[BWAudioSourceNode start:]` | 0x1a1eefa18 | 0x1a1f3f998 |
| `-[FigVideoCaptureConnectionConfiguration videoStabilizationMethod]` | 0x1a1e99ef8 | 0x1a1ee9e78 |
| `-[FigVideoCaptureConnectionConfiguration videoStabilizationType]` | 0x1a20d8f48 | 0x1a2128ec8 |
| `-[FigCaptureStillImageSettings qualityPrioritization]` | 0x1a1f533dc | 0x1a1fa335c |
| `-[BWGNRNode renderSampleBuffer:forInput:]` | 0x1a1ec83b8 | 0x1a1f18338 |
| `-[BWNodeOutput emitSampleBuffer:]` | 0x1a1ea37e0 | 0x1a1ef3760 |
| `-[BWCoreImageFilterRenderer prewarmPortraitFilterVersion:semanticStyleFilters:]` | 0x1a2115c0c | not found in CMCapture by that name [I: renamed or moved; find with `ipsw dyld symaddr ... --image CMCapture -- '-[BWCoreImageFilterRenderer'` prefix search or the class-dump] |

`CACHE_BASE` for the slide: the cache's unslid base (0x180000000 on this cache [I: check with `ipsw dyld info`]).
`initWithDeviceCreateFunction:` exists in 20H392 [V, class-dump of CMCapture `BWFigCaptureDeviceVendor`].
The `flashlight_code` caller ranges (`inject_media.c:94-95`) are 20F66 values; they matter only for a torch.

## 4. Work items (shortest path to a live preview)

Status 2026-10-27 (userland agent): items 2-4 done, build-only: `userland/camera/` (NegroniCamera.driver, way a),
`scripts/camera/{check-cache,root-add-camera,phone-camera}.sh`, `ADT_CAM=1` in `scripts/ios16/adt-extra.py`. The
portrait prewarm in 20H392 is 0x1a2165b8c. Details and test steps: `userland/camera/README.md`, notes section 43.

1. **Kernel test first (build done, not run):** boot `negronicam=5` and get `TPG frame sanity: PASS` and
   `SENSOR frame sanity: PASS` with the new SMMU lines (README-camera.md "Boot-args for the camera test boot").
   Then `negronicam=7` (`negronicam_src=1` for colour bars), and on the phone over SSH:
   `dd if=/dev/negronicam bs=15040120 count=3 of=/tmp/s.raw` (header 120 + 4000*3008*10/8 bytes) and look for
   `ios session: 30 frames` in the USB log. Only then the userland.
2. **`userland/camera/`** (new, macOS build like `userland/audio/build.sh`):
   - `negronicam.h`: copy of the 0318 ABI (= `hakios.camera.h` with `NEGRONICAM_DEVICE "/dev/negronicam"`, magic
     `NCFRAME1`).
   - `camera_device.c`, `camera_isp.c`, `camera_isp.h` from `out/src/hackios-next/userland/src/` (MIT notice kept).
     Edits [I, about 200 lines]: device path and magic; one camera only (rear main, `sensor` 1; the front IMX615 has
     no kernel driver: `REDWOOD/HAKIOS_CAMERA_SENSOR` answers ENODEV for others, so offer one FigCaptureStream);
     frame size 4000x3008 binned RAW10 (the D22 format table matches by size: keep 4032x3024 names, scale);
     tuning tables (`load_tuning`) replaced by neutral values first (CCM identity, no lens shading, gray-world AWB),
     OnePlus CAMX tuning later; `focus` is `NO_FOCUS` (no AK7377 driver yet): AF code stays idle.
   - `media_hooks.c`: the hook part of `inject_media.c` (vendor + the 6 found methods of the table above; skip the
     portrait prewarm until its 20H392 address is known; HEVC encoder registration for HEIC stills).
   - CoreMedia vtable layout: HakiOS used 16.5 (20F66); ours is 16.7.x (20H392). [I] The `CMBaseClass` /
     device / stream class layouts did not change between 16.5 and 16.7, but check the version fields H10ISP's own
     vtables carry in 20H392 (`H10ISP.mediacapture`, image 1455 in `out/camera/ios-stack.txt`) before the first run.
3. **Getting the code into mediaserverd** [I, needs one check on the phone]: launchd probably drops
   `DYLD_INSERT_LIBRARIES` for com.apple.* jobs (`docs/notes.md:945`). Two options:
   - a) An AudioServerPlugIn: mediaserverd loads every `/System/Library/Audio/Plug-Ins/HAL/*.driver` at start (our
     `NegroniAudio.driver` and Apple's `BTAudioHALPlugin.driver` load there: `docs/notes.md:1595-1600`). A
     `NegroniCamera.driver` whose factory returns NULL (no audio device) and whose `__attribute__((constructor))`
     installs the hooks (`getprogname()` == mediaserverd, `_dyld_register_func_for_add_image`) needs no launchd change.
     Or add the hooks to `NegroniAudio.driver` itself (one bundle).
   - b) HakiOS's way (launchd plist `EnvironmentVariables` + their AMFI stand-in): only if a) fails.
   Installer (done): `scripts/camera/root-add-camera.sh` (`CAMERA=1`; root-finish.sh sets it by default when the
   driver is built; it writes the stamp `out/camera/root-has-camera` that `scripts/ios16/build.sh` needs for its
   `ADT_CAM=1` default).
4. **ADT** (`config/negroni-ne2211.toml` + `scripts/ios16/adt-extra.py`, like `ADT_BT=1`): node `/arm-io/isp` with
   `camera-rear` = 1 (4 bytes LE) and no `compatible`; node `/product/camera` (no `flash`). [V] NegroniPlatformExpert
   publishes every `/arm-io` child as a nub (slop 0046, `adt-extra.py:16-17`), but a node without `compatible`
   matches no driver. Gate it with `ADT_CAM=1` so images without the camera stack do not show a dead Camera icon.
5. **Boot-args of the image:** `negronicam=7` (+ `negronicam_src=1` for the first userland test: colour bars prove the
   path without the sensor; then without it).

## 5. Expected proof on the phone

- Kernel: `NEGRONI CAM: level 7: /dev/negronicam for iOS (...)`, then on Camera.app start
  `NEGRONI CAM: ios session: start (IMX789)`, `... ios session: 30 frames in N ms, ... read`.
- mediaserverd (syslog over USB): `... mediaserverd: the camera's device vendor made (camera_device.c)`,
  `frames of 4000x3008 from the kernel`.
- Screen: colour bars (TPG) or the scene in the preview.

## 6. Open risks

- [I] Which event the IFE 680 write master latches the new address on (SOF vs BUF_DONE): 0318 logs `late address
  updates`; a wrong choice gives torn frames, not a crash.
- [I] Bayer order of the IMX789 FTM mode: `negronicam_bayer=0..3` (header field), check with the TPG and a
  colour target (`scripts/camera/raw-to-png.py --bayer`).
- [I] CPU ISP speed at 12 MP: HakiOS scales; use a 2x2 binned preview path in `camera_isp.c` if the preview is slow.
- [I] Exposure: Sony analog gain code formula and the group hold are inferences; AE can run with digital gain only.
- The SMMU stage-1 context has not run on this SoC yet (Wi-Fi 0324/0325 and camera 0317 are both build-only).
