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
Status 05:55 (camera userland agent 2): the userland was complete but never ran with the ADT nodes; fix, hot off switch
and the live test procedure in section 7.

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

## 7. 2026-10-27 05:55: why Camera.app stayed black, the fix, the live test

### Observations [V]

- The bundle was on the phone: the root of 03:31 (`logs/root-refresh.log` hook camera, driver sha256 d5ab3cc9...)
  went to userdata by `reflash-root.sh` at 03:44-03:50 (`logs/reflash.log`).
- No test image of tonight had the camera ADT nodes: `grep -c -a camera-rear` = 0 for `out/ios16-t20..t23`
  (all ADT sha256 24948e87..., the `out/ios16-everything` ADT of 2026-10-26 23:19, made before the camera root).
  Cause: the test images run `scripts/ios16/build.sh payload` + `boot` only on a copied `negroni.adt`; the camera nodes
  come from the `adt` step. So MobileGestalt had no `camera-rear` source for `rear-facing-camera` / `still-camera`.
- The kernel stream works from user space: `dd` with toybox read 3 frames (t15); `bootlog-5.txt`: `ios session:
  start (IMX789)` ... `end (closed) after 6 frames`, SMMU context 7 FSR 0x400 (no fault) at teardown.
- No boot log or USB log has a `|mediaserverd|` line or `exec Camera` after 03:50; the plug-in's own lines go only
  to the unified log (os_log) and stderr. So there is no evidence yet that the hooks were installed or not.
- Stock `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` (20H392 0x1a1f40c84, `ipsw dyld disass`) does not
  cache a nil vendor: under its lock it tries `initWithDeviceCreateFunction:FigCaptureGetCaptureDeviceCreateFunction()`
  again while the static is nil. So a hook installed after an early call still works.
- HAL plug-ins load in mediaserverd: the BTAudioHALPlugin factory ran there (`CFPlugInInstanceCreate <-
  HALS_PlugInManager::CreatePlugIn`, notes section 17). iOS 16 has no cameracaptured; the capture server is in
  mediaserverd (notes section 13). Our XNU has no Sandbox kext (`docs/camera-plan.md`), and `/dev/negronicam` is
  root:mobile 0660, so mediaserverd (uid 501) can open it.

### Guesses [I]

- Main cause of the black/not-opening Camera: no `rear-facing-camera` in MobileGestalt (no ADT node), so CameraUI has
  no back camera to start. Second candidate: the hooks did not install (check the log lines below).

### Changes (build only, nothing on the phone)

- `scripts/ios16/build.sh`: new `adt_cam()`; `payload` now adds the two camera nodes to a copied `negroni.adt` that has
  none (`ADT_CAM=1 adt-extra.py`, other nodes kept; `ADT_CAM=0` keeps the ADT as it is). The stamp rule is "a root got a
  NegroniCamera build" (any sha; a newer local build gives a note). Checked on a copy of the t23 ADT: new nodes
  `/arm-io/isp` (camera-rear 1, phandle 0x18) and `/product/camera` (0x19), no node lost.
  Review fixes: the stamp alone decides (also when `out/camera/ios` is not built); `payload` does not change the ADT of
  `out/ios16-safe` (only with `ADT_CAM=1` by hand); `adt-extra.py` keeps the phandle of a node it replaces, so a second
  run gives the same bytes (checked); `phone-camera.sh revert` (without `prev`) removes the stamp.
- `userland/camera/media_hooks.c`: hot off switch: `/var/db/negronicam/off` present -> the constructor logs
  `... exists: off, nothing replaced` and does nothing.
- `scripts/camera/phone-camera.sh`: `restart` (kills Camera.app + mediaserverd), `off` / `on`, `log`, `revert prev`;
  `push` keeps the old bundle in `/var/db/negronicam/NegroniCamera.driver.prev`, kills Camera.app, and writes the stamp.
- Build: `scripts/bg.sh cambuild userland/camera/build.sh` -> `out/camera/ios/NegroniCamera.driver`, 144 720 bytes,
  sha256 ea16947ef687534f807c3df0769e75457357fb59ad4509373b91c57a8bc84dae, arm64, minos 16.0, ad hoc, no entitlements,
  ISP self test PASS. Hook table unchanged (`scripts/camera/check-cache.sh` PASS of 02:34 still applies).

### Live test (main session; the phone on iOS with SSH)

1. Image: the next test image needs the camera nodes. `IOS16_OUT=out/ios16-tNN ... scripts/ios16/build.sh payload`
   now adds them (look for `payload: ... has no camera nodes: adding them`), or run the `adt` step. Boot-args:
   `negronicam=7 negronicam_smmu=3` (t23 has them; `negronicam_src=1` for colour bars). RAM boot as usual.
2. Plug-in without a new root: `scripts/camera/phone-camera.sh push` (installs the 05:55 build, keeps the old one,
   clears the MobileGestalt cache, kills Camera.app and mediaserverd; launchd restarts mediaserverd).
   MobileGestalt reads the ADT nodes only after a boot: if step 1 needs a reboot, push first, then boot.
3. Log: `scripts/bg.sh camlog scripts/camera/phone-camera.sh log` (unified log of mediaserverd + Camera, lines
   `negroni: camera`). Kernel: `make usblog`, lines `NEGRONI CAM:`. After the mediaserverd restart, expect:
   - `negroni: camera hooks: in mediaserverd (pid N), cache 20H392, slide 0x..., /dev/negronicam there`
   - `negroni: camera hooks: the software HEVC encoder of VCPHEVC.videocodec registered for 'hvc1' (0)`
   - `negroni: camera hooks: HAL factory called: no audio driver in this bundle (...)`
   - up to 8 lines `negroni: camera hooks: ... replaced (k of 8)` (each when its class loads; CMCapture loads late);
     a `left alone` line means a wrong address: report it.
4. Open Camera.app. Expect `the camera's device vendor made (camera_device.c) (/dev/negronicam there)`,
   `negroni: camera: the device made: one stream, the back camera (IMX789, /dev/negronicam)`, `device: streams asked
   for (1)`, `stream: the graph starts the stream`, `stream: frames begin`, `frames of 4000x3008 from the kernel`,
   `PrimaryScaler: the first picture given (2016x1512 ...)`. Kernel: `NEGRONI CAM: ios session: start (IMX789)`,
   then `ios session: 30 frames in N ms`.
5. Wrong colours: `scripts/camera/phone-camera.sh frame` (4 PPMs, one per Bayer order), then `negronicam_bayer=N`.
   Upside down: `touch /var/db/negronicam/turned` on the phone, then `phone-camera.sh restart`.
6. Fault lines: `no device: /dev/negronicam ... is not there` (no `negronicam=7`), `the kernel's camera has had a
   fault (EIO)` (reboot needed), `5 reads in a row failed`; no `in mediaserverd` line at all = the HAL did not load
   the bundle (`phone-camera.sh status`).

Rollback, fastest first: `scripts/camera/phone-camera.sh off` (switch file + restart; the 05:55 build and later),
`phone-camera.sh revert prev` (the bundle of before the push), `phone-camera.sh revert` (no camera plug-in at all).
None writes a partition. A hung Camera.app launch is limited by the root tweak `FBLaunchWatchdogScale` 3.

### Risks [I]

- MobileGestalt may keep a cached `rear-facing-camera` = false: push removes both cache files; a boot rebuilds them.
- A crash in the plug-in kills mediaserverd (audio too); launchd restarts it, and the next start crashes again.
  Then `phone-camera.sh off` (works before the hooks install) or `revert`.
- The section 6 risks stay (IFE latch event, Bayer order, gain formula, CPU ISP speed at 12 MP).

## 8. 2026-10-27 18:00: Camera.app hangs in launch: no capture server in mediaserverd (root cause + fix)

Marks: [V] seen in a tool output or a file, [I] inference.

### Observations [V]

- `logs/camlog4-full.txt`: Camera[702] logs `Camera launched.`, the two orientation lines, and then nothing from its main
  thread. Its UIKit adds deactivation reasons 10, 5, 11 and never removes one (MobileSafari in `camlog3` removes 10 at
  +0.5 s, then 11 and 12). No tccd request for kTCCServiceCamera, no CMCapture/AVFCapture line, no capture session in
  mediaserverd, no `ios session: start` in the kernel. The same in `camlog5` (Camera[301], started at boot).
- FrontBoard stackshots on the phone, `Camera-2026-10-27-050719.ips` and `-051639.ips` (copied to `logs/`; "failed to
  terminate gracefully"): `python3 -I scripts/debug/ips-stackshot.py logs/Camera-2026-10-27-051639.ips Camera`:
  - main thread: `-[CAMApplicationDelegate application:didFinishLaunchingWithOptions:]` ->
    `_createSubsystemsWithLaunchOptions:` -> `-[CUCaptureController init...]` -> `-[CAMCaptureEngine
    initWithPowerController:options:]` -> `prewarmedCaptureSession` -> `_prewarmAVCaptureSession` ->
    `_dispatch_once_wait` (the once is owned by the session-queue thread);
  - `com.apple.camera.capture-engine.session-queue`: `-[AVCaptureSession init]` -> `pthread_once` ->
    `csr_ensureClientEstablished` -> `FigXPCRemoteClientCreate` -> `xpc_connection_send_message_with_reply_sync`;
    `turnstileInfo`: "turnstile blocked on task pid 1". The block sends to `"com.apple.coremedia.capturesource"`
    (CMCapture 20H392 0x1a20307ec..0x1a2030820, `ipsw dyld disass`).
  - mediaserverd (pid 460) in the same stackshot: no CMCapture or capture-server thread.
  So launchd (pid 1) still holds the receive right of the service: nobody checked it in.
- `com.apple.mediaserverd.plist` (20H392) has `com.apple.coremedia.capturesource`, `capturesession`, `cameraviewfinder`
  in MachServices. iOS 16.7 has no cameracaptured.
- Who starts them: mediaserverd `main` -> `FigMediaServerStart` (MediaToolbox 0x194fee230) -> `if
  (feServer_ShouldStartSubServer(plist, "StartRecorderServer")) FigStartCaptureServers()` (CMCaptureCore 0x1d3fdc828:
  FigCaptureMemoryReporterStart, FigPreloadShaders, FigCaptureSourceServerStart, FigCameraViewfinderServerStart,
  FigCaptureSessionServerStart, FigFlashlightServerStart, FigCaptureDeferredContainerManagerServerStart). The plist
  is `CelestialCFCreatePropertyList("SubServerConfiguration.plist")` = `MediaToolbox.framework/D22/...`.
- On the phone, `D22`, `D221` and `Default/SubServerConfiguration.plist` all have `StartRecorderServer` **false**. Set by
  slop `sweet-root-tweaks.py` and by our `scripts/audio/root-add-audio.sh` step 3 (2026-10: "the portrait prewarm calls
  a NULL GL function without a GPU", a mediaserverd crash loop).
- HAL plug-ins load in `AudioToolboxServerInit` before `FigMediaServerStart` (camlog4: `HALS_PlugInManager::LoadPlugIns`
  24.109, all 8 hooks replaced at 24.191, the Fig servers after that). So our portrait-prewarm stub is in place before
  any capture server code can run.
- MobileGestalt: the cache (`systemgroup.com.apple.mobilegestaltcache/.../com.apple.MobileGestalt.plist`, read over SSH)
  has CacheVersion 20H392, 5346 entries in CacheData (bit-packed, keys hashed); no camera key in CacheExtra. [I] The
  icon shows and CameraUI starts its capture engine, so the MobileGestalt camera answers are not the blocker.
- HakiOS (`out/src/hackios-next`) does not touch SubServerConfiguration: its hooks come in by launchd
  `DYLD_INSERT_LIBRARIES` before `main`, and its root keeps the stock plist [I: the stock value is true; with false no
  iPhone could use its camera]. Everything else HakiOS needed (VIS refused, audio source 'nope', quality, GNR,
  NULL samples, HEVC encoder, buffer pool, metadata) is already in our 8 hooks and `camera_device.c`.

### Root cause [V for the chain, I for "nothing else blocks after it"]

StartRecorderServer = false on our root -> mediaserverd never starts the capture servers -> launchd keeps
`com.apple.coremedia.capturesource` -> `-[AVCaptureSession init]` in Camera.app waits for ever in its first XPC
message -> the main thread waits on the same dispatch_once in `didFinishLaunching` -> no UI, black screen, no
device-vendor call, no `/dev/negronicam` open. Our hooks worked (all 8 replaced); nobody asked for a device.

### Fix (build only; nothing written on the phone)

- `userland/camera/media_hooks.c`: the constructor queues `start_capture_servers()` on the main queue (runs once
  mediaserverd's `main` is in its run loop, after FigMediaServerStart). It:
  1. reads the same plist with `CelestialCFCreatePropertyList` and does nothing when StartRecorderServer is on (no
     double start);
  2. needs the portrait prewarm stub and the vendor hook replaced, else it does not start (the old crash);
  3. calls FigStartCaptureServers' list in its order **without FigPreloadShaders** (a Metal shader precompile; its other
     effect is flags for SIS/TMBNR/HDR/GNR processors that this phone does not have; `FigWaitForPreloadShadersCompletion`
     with no preload queue returns at once [V disasm]);
  4. knobs in `/var/db/negronicam`: `noservers` = do not start (Camera.app then hangs as before), `preload` = call the stock
     `FigStartCaptureServers` with the shader preload. The old `off` switch stops everything (no hooks, no servers).
  Log lines: `negroni: camera hooks: capture servers started (6 of 6, shader preload skipped): ...`.
- No root change: StartRecorderServer stays false (audio keeps the old safe state; the servers come only with our
  plug-in and its hooks).
- `scripts/camera/phone-camera.sh servers on|off` (the `noservers` file + restart); `status` shows StartRecorderServer and
  the Camera.app process.
- `scripts/debug/ips-stackshot.py`: symbolicates a FrontBoard stackshot `.ips` (all threads, waitInfo, turnstiles).
- Build: `userland/camera/build.sh` -> `out/camera/ios/NegroniCamera.driver/NegroniCamera` 145 008 bytes, sha256
  35f07636079acc1d52d750cbe38053b413a863bbc45b031372860b7affb5ab11 (18:14, after the review: all-or-nothing start). `scripts/camera/check-cache.sh` PASS (all new dlsym names exported).

### Test (main session)

1. `scripts/camera/phone-camera.sh push` (installs the bundle, kills Camera.app and mediaserverd; launchd restarts it).
2. `scripts/bg.sh camlog scripts/camera/phone-camera.sh log`. Expect after the mediaserverd start: the old lines (hooks,
   8 replaced, HAL factory) and then `capture servers started (6 of 6, shader preload skipped)`.
   `scripts/camera/phone-camera.sh status`: mediaserverd keeps its pid (no crash loop).
3. Open Camera.app. Expect `the camera's device vendor made`, `the device made: one stream`, `stream: frames begin`;
   kernel (USB log) `NEGRONI CAM: ios session: start (IMX789)`. The app UI (shutter, modes) shows even without frames.
4. If Camera.app still hangs: new `.ips` in `/var/mobile/Library/Logs/CrashReporter/` -> `scripts/net/ssh-phone.sh pull`
   -> `scripts/debug/ips-stackshot.py FILE Camera,mediaserverd`.
5. Rollback: mediaserverd crash loop or no audio -> `phone-camera.sh servers off` (or `off`, or `revert prev`).
   A crash in FigCaptureSourceServerStart / our device: `servers off`, then report the mediaserverd `.ips`.

### Risks [I]

- The capture servers have never run on this root: a crash in their start (e.g. FigFlashlightServerStart without a torch,
  FigCaptureSourceInitialize with our vendor) kills mediaserverd, so audio too. `servers off` is the hot way back.
- The server checks camera access with tccd; tccd here fails to make sandbox extensions ("Failed to issue sandbox
  extension", camlog3) but answers authValue 2. Camera.app has the private TCC entitlement.
- The `preload` knob runs Metal shader compiles in mediaserverd; use it only to test the GPU path.

## 9. 2026-10-27 18:15: Camera.app runs, no preview: the app is "not authorized" (tccd sandbox extension)

### Observations [V, `logs/camlog6-full.txt`, mediaserverd[603], Camera[614] from 05:42:04]

- The section 8 fix works: `capture servers started (6 of 6, ...)`; the iOS prewarm made our device
  (`the device made: one stream`) and a kernel session ran (82 frames, then closed). Camera.app launches.
- `FigCaptureGetCaptureDeviceCreateFunction: Failed to load CaptureDeviceCreate function` is the stock lookup of the
  Apple ISP driver; our vendor hook covers it (`-[BWFigCaptureDeviceVendor _createDevice:clientPID:]` follows at once).
  Not a cause.
- The cause: Camera[614] `TCC ... Code=6 "server error: Failed to issue Sandbox Extension for kTCCServiceCamera"`, then
  `Creating an AVCaptureDeviceInput for the captureDevice (... [Back Camera] ...) failed: (AVFoundationErrorDomain
  Code=-11852 "Cannot use Back Camera" ... This app is not authorized to use Back Camera.)`. The same for the
  microphone. So the session has no camera input. The rest follows from that [I]: `Failed to find video output
  connection for <AVCapturePhotoOutput>`, `CAMModeAndDeviceCommand configuration failed! (-32200)`, `Failed to set
  exposure mode ... not supported by (null)` (no device), `startRunning succeeded` with nothing to run, no kernel session.
- tccd grants the service (authValue 2) and then fails `sandbox_extension_issue` because our kernel's Sandbox stand-in
  answers op 5 (extension issue) and op 6 (consume) with ENOENT (slop 0050, kept by our 0223).
- HakiOS: its `kern_minimac.c` Sandbox stub answers every op except 4 with 0 ("allowed"), so tccd works there.

### Fix: kernel patch 0386 (build-only; userland cannot fix it: tccd builds the extension classes in, no plist)

- `patches/xnu/0386-negroni-sandbox-extensions.patch`: op 5 writes a fixed token into the library's 0x800-byte buffer
  (arg offset 0x20, layout from `__sandbox_extension_issue` 20H392 0x1d1af4f98), op 6 returns 0. Boot-arg
  `negronisbext=0` = old behaviour. Details: `patches/xnu/README-aks-amfi.md` "0386". Syntax check OK, applies on the
  current patched tree. No new kernel built (one combined build by the main session).
- No change in userland/camera for this. The 18:08 NegroniCamera.driver stays.

### Test

1. Build the kernel with 0386 (with the other pending patches), new test image, RAM boot as usual (`negronicam=7`).
   The plug-in is on the root already (pushed 18:11).
2. `scripts/bg.sh camlog scripts/camera/phone-camera.sh log`; open Camera.app. Expect: no `Failed to issue Sandbox
   Extension` for Camera[pid], no `-11852`; mediaserverd `captureSession ... graph` lines, `negroni: camera: device:
   streams asked for (1)`, `stream: the graph starts the stream`, `frames of 4000x3008`; kernel `ios session: start`.
3. Kernel log once per boot: `NEGRONI Sandbox: tccd op 5` (first use).
4. If something else fails after that, the next blocker is in the graph build (formats/preset): grep mediaserverd for
   `captureSession_buildGraph`, `-[BWFigCaptureDevice`, `FigCaptureStream`.

## 10. t27 18:25: mediaserverd aborts after the first pictures (uncaught Objective-C exception); diagnosis build

### Observations [V]

- t27 (0386 + 0385, plug-in of 18:11): tccd talks to the stand-in, Camera.app opens, the kernel starts `ios session:
  start (IMX789)` at once. Then mediaserverd ends with sig 6 after about 2 frames, on each new session (18:25:25, :45,
  :48 ...). No mediaserverd `.ips` is written (`Failed to send exception EXC_CORPSE_NOTIFY`).
- Kernel backtrace (`logs/usblog-20261027-171256.txt` line 114339+; cache slide 0x45f4c000 = pc - `__pthread_kill`+8):
  `pthread_kill` <- `abort` <- `demangling_terminate_handler` <- `_objc_terminate` <- `std::__terminate` <-
  `std::terminate` <- `_dispatch_client_callout` <- `_dispatch_lane_serial_drain` <- `_dispatch_lane_invoke` <-
  `_dispatch_root_queue_drain`. So an Objective-C exception escaped a block on a serial dispatch queue. The frames of
  the thrower are not in the kernel backtrace (unwound before terminate).
- The boot prewarm session (no client) read 84 frames and gave 0 pictures without a crash; so the throw comes after our
  first pictures reach the graph [I].

### Change (diagnosis; no fix of the cause yet)

- `media_hooks.c`: an uncaught-exception handler (`objc_setUncaughtExceptionHandler`, then the previous handler) says
  `negroni: camera hooks: UNCAUGHT EXCEPTION <name>: <reason>` and 16 return addresses of the throw, unslid for the
  shared cache (`ipsw dyld a2s out/dsc/cache/dyld_shared_cache_arm64 ADDR`).
- `camera_device.c` + `media_hooks.c`: every `negroni: camera` line also goes to `/dev/console`, so the USB kernel log
  has them (the way NegroniMetal's NMTL lines get there).
- Build 18:28: 145 264 bytes, sha256 2557791af79d45e8033c9c6b16d65a686fb0ab1f99fe94dff41a046c6c8bde92; on top of the
  reviewed all-or-nothing servers code (c26ce1c). check-cache PASS.

### Test

1. `scripts/camera/phone-camera.sh push` (restarts mediaserverd; it is in a crash loop only while a session runs).
2. Owner opens Camera.app once. USB log: `grep -a 'negroni: camera' logs/usblog.log` -> the UNCAUGHT EXCEPTION line
   and `#N cache 0x...` lines. Symbolicate: `for a in ...; do ipsw dyld a2s out/dsc/cache/dyld_shared_cache_arm64 $a
   --cache out/dsc/20H392.a2s; done`.
3. Stop the loop: `phone-camera.sh servers off` (Camera.app then waits, mediaserverd and audio stay up).

## 11. t27 18:29: the exception is the display's plane alignment property (number, not dictionary); fix

### Observations [V]

- Diagnosis build: `UNCAUGHT EXCEPTION NSInvalidArgumentException: -[__NSCFNumber objectForKey:]: unrecognized selector`
  at each session start (`logs/camera-exception-1829.txt`, `logs/camlog7-full.txt`). Throw stack (unslid):
  `FigGetAlignmentForIOSurfaceOutputToDisplayService`+124 (VideoToolbox) <- `-[BWImageQueueSinkNode
  _updateInputRequirements]` <- `-[BWImageQueueSinkNode initWith...]` <- `-[FigCapturePreviewSinkPipeline
  _buildImageQueuePreviewSinkPipeline...]` <- `_buildVideoPreviewSinkPipeline` <- `captureSession_buildGraphWithConfiguration`
  <- `captureSession_startRunningInternal`. Not our frames or metadata: the graph build of the preview sink.
- The function (0x194f3b410) reads the AppleCLCD property `DisplayPipePlaneBaseAlignment` with
  `IORegistryEntrySearchCFProperty` and calls `CFDictionaryGetValue(it, "PlaneBaseAlignmentLinear")`. The phone's
  `ioreg`: `"DisplayPipePlaneBaseAlignment" = 64` (a number; set by slop 0046/0061, kept in our 0250/0253).
  `DisplayPipeStrideRequirements` (dictionary with `StrideLinearHorizontal`) is not published: NULL, no exception.
- The answer is cached in VideoToolbox statics `_planeBaseRequirement.requirement` (__DATA 0x1dd2bd42c) and
  `_planeBaseRequirement.checked` (__bss 0x1dd2bd853).
- The `#N cache` lines of the diagnosis build reached the unified log but not the USB log (16 console writes in a row);
  they are now one `throw stack:` line.

### Fix (userland/camera; build 18:31)

- `media_hooks.c` `seed_display_alignment()` (constructor, mediaserverd, 20H392 cache only): checks the function's first
  word (0xd10183ff) and the `ldrb` of `checked` (0x39614f28), then stores 64 in `requirement` and 1 in `checked`, so
  VideoToolbox never reads the registry property. Log: `display plane base alignment seeded (64 bytes; ...)`.
  `scripts/camera/check-cache.sh` step 5 checks the words and the statics' names (PASS).
- The exception logger stays (self-check). Build: 145 264 bytes, sha256
  c5f161941636d5e4a67a9977531e9e182a48a6350e054469c3472c68aff82f86.
- [I] Kernel alternative: publish `DisplayPipePlaneBaseAlignment` as `{PlaneBaseAlignmentLinear: 64}` as real AppleCLCD
  does. Not done: other readers of the number (QuartzCore, our own code) are not checked.

### Test

1. `scripts/camera/phone-camera.sh push`.
2. USB log: `negroni: camera hooks: display plane base alignment seeded (64 bytes ...)`, `capture servers started`.
3. Open Camera.app: no UNCAUGHT EXCEPTION; `negroni: camera: ... the first picture given (2016x1512 ...)`; the preview.
4. If a new exception comes: the `UNCAUGHT EXCEPTION` + `throw stack:` lines in the USB log; `ipsw dyld a2s` each `c` address.

## 12. t27 18:36-18:40: sig 5 at graph stop, sig 10 in H264SW (YouTube), blank preview

### sig 5 (18:36:29, 18:37:01, 18:38:56) [V]

- pc 0x1a1f6fde0 (unslid) = `-[BWGraph stop:]`+828, a `brk #1` after `"<<<< BWGraph >>>> %s: <%p> Not all sink nodes
  became idle after waiting 10s."`, `_logActiveNodesAfterGraphStopTimeout`, `_logActiveSinkNodesAfterGraphStopTimeout`
  and `WriteStackshotReport`. Caller `captureSession_stopGraph` <- `captureSession_stopRunningInternal`. Our stream had
  stopped 11 s before (`stream: stop (66 frames, 45 pictures given)` 18:36:18). So one sink node did not finish.
- [I] Candidates: the preview image-queue sink (backboardd does not consume '420f' surfaces: Metal refused planar
  IOSurfaces, `IOK backboardd: matching AppleM2ScalerCSCDriver -> none` at 18:36:18), or a node with GPU work: mediaserverd
  had `native-metal: refused ... render pipeline (colorCubeVertex / colorCubeFragment2D, color0 fmt 540)` and many `heap
  texture refused: OutOfMemory(Heap)` at 18:36:16.
- Change (diagnosis): hook 9 `-[BWGraph _logActiveSinkNodesAfterGraphStopTimeout]` (0x1a218a970, first word 0xa9ba6ffc,
  check-cache OK): after the stock log, says each sink `ACTIVE|idle name (class)` and the count to the USB log. The trap
  stays. Build 18:39: 145 552 bytes, sha256 e09795da64e8d07f2c4cbcd4b296a0664e91f10906205af86001819fea624bd4.

### sig 10 (18:39:03 ... 18:40:07, YouTube playback, not the camera) [V]

- pc unslid 0x1f0f4c914 in `/System/Library/VideoCodecs/H264SW.videocodec` (a 3-row 16-byte copy loop, `str q0,[x10,x3]`),
  whole stack in H264SW worker threads (`_pthread_start`). The write address is inside the dyld shared region (r-x,
  tag 35; unslid it is library text, e.g. 0x1c55b8040), each time a different one, always ending in 0x040. The kernel
  logs `mediaserverd[N] triggered unnest of range ... of DYLD shared region` just before each crash.
- So the software H.264 decoder writes a decoded picture to a destination base that points into the shared cache
  [I: the destination CVPixelBuffer/IOSurface base address is wrong; an IOSurface/VideoToolbox-output problem, not the
  camera code]. None of the 8/9 hooks are on the decode path; the HEVC encoder registration adds an encoder only.
- [I] The one plug-in change that VideoToolbox decode can see: the seeded plane base alignment (64, the same value as
  the stock default when the property is absent). Before the seed, any VideoToolbox caller of
  `FigGetAlignmentForIOSurfaceOutputToDisplayService` threw the `-[__NSCFNumber objectForKey:]` exception (section 11).

### Test to separate the plug-in from the decode crash (main session with the owner)

1. `scripts/camera/phone-camera.sh off` (no hooks, no seed, no capture servers; restarts mediaserverd).
2. Play the same YouTube video. Watch the USB log for `CRASH mediaserverd`, `triggered unnest`, and `NMTL[... mediaserverd]`
   / CoreFoundation exception lines.
   - SIGBUS in H264SW again: not the plug-in (IOSurface / VideoToolbox decode output; kernel or Metal side).
   - An abort with `-[__NSCFNumber objectForKey:]` instead: the AppleCLCD property breaks playback too; the kernel
     dictionary fix is needed (the seed only covers mediaserverd while the plug-in is on).
   - No crash: the plug-in is involved; report and I bisect (seed only / hooks only).
3. `scripts/camera/phone-camera.sh on` afterwards.

## 13. 18:44 SpringBoard crash loop ("NSMotionUsageDescription"): not 0386 (analysis)

### Observations [V]

- `logs/usblog-20261027-171256.txt` 18:44:28-18:46: SpringBoard sig 6 every ~5 s, reason "attempted to access
  privacy-sensitive data without a usage description ... NSMotionUsageDescription". Unslid bt: `TCCAccessRequest` <-
  CoreMotion `-tccServiceMotionAccessWithBlock:` helper (func 0x191c8ad4c, the only TCCAccessRequest caller there) ->
  `tccd_send_message` -> reply block -> `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`. The TCC client crashes this way
  when tccd's reply says `require_purpose` (TCC strings: `require_purpose`, `Missing Usage String`).
- SpringBoard (20H392) has no `kTCCServiceMotion` in `com.apple.private.tcc.allow` (11 services: AddressBook ... BluetoothAlways)
  and no `NSMotionUsageDescription` in its Info.plist. So no entitlement is "lost"; this request never had one.
- No Motion request in any earlier log (camlog2-7, phone-full 17:43). TCC.db has no SpringBoard rows.
- From 18:44:28, every backboardd and SpringBoard start logs `CODE SIGNING: cs_invalid_page(...): p=N[SpringBoard] final
  status 0x22000000, allowing (remove VALID) page`. Before 18:44 only `launchd_cache_lo` had this line, never SpringBoard.
- The Metal bundle on the phone (`/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal`, `libvulkan_freedreno.dylib`)
  was changed at phone 06:14 = 18:44 host time (the phone clock is 12 h 30 min behind), just before the respring at
  18:44:28. Copied off, the bundle is "valid on disk" (codesign).
- 0386 was active at 18:24 and 18:41 and SpringBoard started normally both times.

### Cause [I, strong]

The Metal push of 18:44 put new signed Mach-Os on the root; every process that mapped them (backboardd, SpringBoard) hit
a code page whose hash did not match and lost CS_VALID (status 0x22000000 = SIGNED | DYLD_PLATFORM, no VALID). [I] The
likely way: a file written over the old inode keeps the old code signature on the cached vnode. With CS_VALID gone,
tccd no longer treats SpringBoard as verified platform code. For a Motion request it then asks for a purpose string, and
SpringBoard has none, so it crashes. Before, the same request (if made) got a quiet answer. 0386 (ops 5/6) is not in
this chain; with 0386 off (t28) it can still happen while the cs_invalid_page condition lasts. A reboot clears it.

### Fix

- `scripts/metal/phone-test.sh push`: unlinks every file of the archive before `tar -x`, so each new file is a new
  inode (toybox tar 0.8.15 on the phone; whether it unlinks by itself is not checked [I]).
- No change to 0386, no TCC.db or tccd change: TCC behaved as designed for a process without CS_VALID.

### Test (RAM boot)

1. t28 (`negronisbext=0`) boots: SpringBoard up, no `cs_invalid_page` for SpringBoard (fresh vnodes).
2. Next RAM boot with 0386 on (no `negronisbext=0`), no Metal push before it: expect SpringBoard stable, no
   `cs_invalid_page`, `NEGRONI Sandbox: tccd op 5`, Camera.app authorized (no `-11852`).
3. Then a Metal push with the new `phone-test.sh push` + respring: grep the USB log for `cs_invalid_page` and `CRASH
   SpringBoard`. Expected: neither.

## 14. 19:10 preview "flashes various colours of RGB" after the f6a96b7d Metal push: plane bytesPerRow 0 (root cause + fix)

### Observations [V]

- `logs/usblog-20261027-171256.txt`: 19:08:40 `PrimaryScaler: the first picture given (1504x1128 420f)`; 19:08:41
  `NMTL[577 backboardd]: native-metal: first texture over a surface with planes: fmt 500, plane 0 of 2, OSType 0x34323066`
  (YCBCR8_420_2P over the preview's '420f' planes); 19:08:41 mediaserverd `texture fmt 53 usage 0x2 over plane 0 of 2 of a
  '420f' surface: ... RowPitch { bytes_per_row: 0, row_bytes: 1128 }`; 19:08:42 mediaserverd `command buffer refused:
  renderCommandEncoder: ... Unsupported ... MTLPixelFormatYCBCR8_420_2P`. backboardd 'b3a8': `RowPitch { bytes_per_row: 0, ... }`.
- flame/0016 passes `IOSurfaceGetBytesPerRowOfPlane(surface, plane)` and plane 1's to metal2vulkan: both 0.
- IOSurface.framework 20H392: `IOSurfaceClientGetBytesPerRowOfPlane` reads IOSurfaceClient + 0xe0 + plane*0x80 (lock result
  0x78 + plane*0x80 = plane record +0x10); width +0x00, height +0x04, offset +0x0c, size +0x14, bpe +0x18 match 0046. 0046
  wrote bytesPerRow at +0x08. `CVPixelBufferBacking::getBytesPerRowOfPlane` calls `IOSurfaceGetBytesPerRowOfPlane`.
- `camera_device.c` `render_piece` -> `isp_render_nv12(..., CVPixelBufferGetBytesPerRowOfPlane(pb, 0) = 0, ..., (pb, 1) = 0)`:
  `y + row * 0`: every row on row 0, 8 threads at once. The rest of each pool buffer is whatever the memory held.

### Cause

The kernel's IOSurface lock result has each plane's bytesPerRow at the wrong offset, so every planar surface reports
bytesPerRow 0. The camera plug-in writes each frame into the first row only; backboardd now samples the rest of the
pool buffers (old memory) through metal2vulkan's YCbCr path (with luma/chroma rows 0 apart): flashing colours. Not the
non-coherent import (m2v/0001) and not a missing IOSurface lock: the bytes were never written.

### Fix

- Kernel patch `patches/xnu/0390-negroni-iosurface-plane-bpr.patch`: bytesPerRow at plane +0x10; boot line `NEGRONI SURF:
  plane bytesPerRow at +0x10 of each plane record (IOSurface 20H392 layout)`; kill switch `negronisurf_planebpr=0`.
  Compile-check: `scripts/kernel/compile-one.sh out/kernel/tree-surfbpr iokit/Kernel/arm/NegroniSurface.cpp` exit 0;
  applies after 0389.
- `camera_device.c` `deliver()`: a 420f/420v buffer whose plane bytesPerRow is under the width is not rendered or given;
  one line `<output>: off: WxH 420f buffer planes have bytesPerRow A/B, under the width (... patch 0390)`. Build 19:23
  sha256 18df5fbc... (isp selftest PASS). Not pushed.
- flame/0016: a plane texture with bytesPerRow 0 (plane 0, or plane 1 of a 2-plane surface) is refused with one line.

### Test (needs a RAM boot with 0390; not done here)

1. Boot log: `NEGRONI SURF: plane bytesPerRow at +0x10 ...`.
2. Camera.app: no `RowPitch { bytes_per_row: 0` and no `MTLPixelFormatYCBCR8_420_2P` refusal from mediaserverd; no `off:`
   line from the plug-in; live preview. If mediaserverd still refuses a YCbCr render, the next item is that pass
   (metal2vulkan render shadow: `ycbcr_render_shadow`).
3. YouTube: check whether the H264SW sig 10 is gone (same cause [I]).
