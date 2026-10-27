# NegroniCamera.driver: the stock Camera.app on the rear main camera

Status (2026-10-27): built and checked on the host only. Not run on the phone. Marks: [V] seen in a tool output or
a source, [I] inference.

## What it is

- A bundle that mediaserverd loads from `/System/Library/Audio/Plug-Ins/HAL/NegroniCamera.driver`, the same way it
  loads `NegroniAudio.driver` (`docs/notes.md`, audio). Its CFPlugIn factory `NegroniCamera_Create` returns NULL (no
  audio driver). The HAL loads the code to call the factory, and the bundle's constructor runs in mediaserverd only.
- The constructor replaces 8 CMCapture methods (`media_hooks.c`, from HakiOS `inject_media.c`). The main one is
  `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]`: where the stock one gives nil (no Apple ISP driver), it
  gives `[[BWFigCaptureDeviceVendor alloc] initWithDeviceCreateFunction:negroni_camera_device_create]`.
- The capture servers: our root has `StartRecorderServer` false (slop + `scripts/audio/root-add-audio.sh`), so
  mediaserverd does not start `com.apple.coremedia.capturesource`/`capturesession` and Camera.app waits for ever in
  `-[AVCaptureSession init]`. The constructor queues `start_capture_servers()` on the main queue: after the hooks, it
  calls FigStartCaptureServers' list without FigPreloadShaders (`docs/camera-ios-2026-10-27.md` section 8).
- `camera_device.c` (HakiOS, MIT): a FigCaptureDevice with one FigCaptureStream (back camera). Frames come from
  `/dev/negronicam` (kernel patch 0318, boot-arg `negronicam=7`; ABI in `negronicam.h`), go through the CPU ISP
  `camera_isp.c` (HakiOS, MIT), and go to the capture graph as CVPixelBuffers.
- The ADT nodes make SpringBoard show Camera.app: `/arm-io/isp` with `camera-rear` = 1 and `/product/camera`
  (`scripts/ios16/adt-extra.py`, `ADT_CAM=1`). [I, from HakiOS `docs/ru/notes.md:1712-1722` and
  `xnuloader/loader.c:3125-3145,3226-3234`, not from our own disassembly of libMobileGestalt] MobileGestalt then
  answers `still-camera`, `rear-facing-camera` and `video-camera`. No `camera-front` (the IMX615 has no kernel
  driver). No `flash` (no torch driver).
- [V] launchd: no job of the 20H392 root has `_LimitLoadToDeviceTree` `isp` or `camera` (the only ones: hilo,
  pearl-sep, wlan/marconi-wifi, twodbl). applecamerad and dietapplecamerad start on IOResources properties. The new
  nodes start no Apple camera daemon.
- Ship together: `scripts/camera/root-add-camera.sh` writes `out/camera/root-has-camera` (sha256 of the installed
  driver; `scripts/camera/phone-camera.sh push` writes it too, `revert` removes it). `scripts/ios16/build.sh` sets
  `ADT_CAM=1` by default when the stamp exists (a sha other than the built driver's gives only a note); without the
  stamp it adds no camera nodes (a warning when the driver is built). Build the root first, then the image (or set
  `ADT_CAM=1` by hand). The `payload` step adds the nodes to a copied ADT without them, except in `out/ios16-safe`.

## Files

| File | What |
|---|---|
| `negronicam.h` | the 0318 ABI: 120-byte `NCFRAME1` header, 24-byte command (static asserts) |
| `camera_device.c` | HakiOS `camera_device.c`, adapted (below) |
| `camera_isp.c`, `camera_isp.h` | HakiOS CPU ISP, only renamed (`hakios_camera_*` -> `negronicam_*`) |
| `media_hooks.c` | the hook part of HakiOS `inject_media.c`, 20H392 addresses, guards, HAL factory |
| `isp-host.c` | host tool: ISP self test (RAW10 colour bars in each Bayer order), NCFRAME1 dump -> PPM |
| `Info.plist` | AudioServerPlugIn type -> factory `NegroniCamera_Create` (UUID 278D395E-6A43-49D1-AA38-98A7A42795F7) |
| `build.sh` | build + checks -> `out/camera/ios/NegroniCamera.driver`, `out/camera/host/isp-render` |
| `LICENSE.HakiOS` | the MIT text of the HakiOS sources |

Scripts: `scripts/camera/check-cache.sh` (the cache against the hook table), `scripts/camera/root-add-camera.sh`
(root image, `CAMERA=1`), `scripts/camera/phone-camera.sh` (live phone over SSH: `push`, `status`, `frame`,
`restart`, `off`, `on`, `log`, `revert [prev]`). Live test steps and rollback: `docs/camera-ios-2026-10-27.md`
section 7.

Hot off switch (builds of 2026-10-27 05:55 and later): a file `/var/db/negronicam/off` makes the constructor log
`negroni: camera hooks: /var/db/negronicam/off exists: off, nothing replaced` and do nothing (`phone-camera.sh off`).
Capture-server knobs (builds of 2026-10-27 18:00 and later): `/var/db/negronicam/noservers` = hooks only, no capture
servers (`phone-camera.sh servers off`); `/var/db/negronicam/preload` = the stock `FigStartCaptureServers` with the
Metal shader preload.

## Build and check

```sh
userland/camera/build.sh                 # a few seconds; macOS + Xcode
scripts/camera/check-cache.sh            # needs ipsw and out/dsc/cache/dyld_shared_cache_arm64
```

`build.sh` refuses a result that is not arm64-only, minos 16.0, without weak imports, with exports other than the
factory, without the hook functions, or with entitlements. It signs ad hoc (no entitlements; the AMFI stand-in
treats signed files on the root as platform code, patch 0221). `PREVIEW_BIN=1` makes the scaler outputs full size.

## Hooks (20H392, cache UUID 8F970452-C9E3-3E88-B114-FEB1864BC9E0, base 0x180000000)

[V `scripts/camera/check-cache.sh`, PASS 2026-10-27]

| Method | unslid address | first word |
|---|---|---|
| `+[BWCoreImageFilterRenderer prewarmPortraitFilterVersion:semanticStyleFilters:]` (skipped) | 0x1a2165b8c | 0xa9be4ff4 |
| `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` | 0x1a1f40c84 | 0xa9bd57f6 |
| `-[BWAudioSourceNode start:]` ('nope' swallowed) | 0x1a1f3f998 | 0xd10583ff |
| `-[FigVideoCaptureConnectionConfiguration videoStabilizationMethod]` (0) | 0x1a1ee9e78 | 0xb01db7e8 |
| `-[FigVideoCaptureConnectionConfiguration videoStabilizationType]` (0) | 0x1a2128ec8 | 0xd01da5e8 |
| `-[FigCaptureStillImageSettings qualityPrioritization]` (at most 1) | 0x1a1fa335c | 0xb940fc00 |
| `-[BWGNRNode renderSampleBuffer:forInput:]` (passed through) | 0x1a1f18338 | 0xd102c3ff |
| `-[BWNodeOutput emitSampleBuffer:]` (NULL dropped) | 0x1a1ef3760 | 0xd10343ff |

Guards, each fails safe (the method or everything stays stock):
- the running cache UUID must be the 20H392 one, else no method is replaced;
- each implementation must be at its address + slide and start with its first word, else "left alone";
- the bundle pins itself (`RTLD_NODELETE`), because the replaced methods point into it; if the pin fails, no
  method is replaced.

Also checked [V]: the H10ISP vtable versions in 20H392 are base 1, device 3, stream 2 (the layout HakiOS built for
16.5), and every `dlsym()` target is exported (CMCapture, CMCaptureCore, CoreMedia, VideoToolbox, VCPHEVC).

## Safety: no launch block

- `negroni_camera_device_create` checks only two things: `access("/dev/negronicam")` (absent without
  `negronicam=7`) and `negronicam_failed`. If either fails, it returns -12783 at once: the vendor exists but has no
  device. [I] Camera.app then shows its "no camera" state. The stock nil vendor came with a hung Camera launch
  (`docs/notes.md` "2026-10-26 handoff (main session, afternoon)"); the root tweak `FBLaunchWatchdogScale` 3 limits
  any hang that is left.
- EIO (a 0318 fault, EIO until reboot), a header that is not NCFRAME1 RAW10, 5 failed reads in a row, or no memory
  are seen only by the frame worker of a device that already exists. The worker sets `negronicam_failed`, sets
  `running` false and stops: in that session the preview stays black and the shutter waits [I]. The next stream
  start and the next device create are refused at once. The create function does not read a header itself: the
  first read starts a kernel session and waits up to 6 s.

## Changes to the HakiOS sources

- `camera_device.c`: one camera (back, kernel sensor 1) instead of back + front; no torch device (TorchLevel is
  logged only); `/dev/negronicam` + header check (magic, RAW10, sizes); `negronicam_failed` (open failure, EIO,
  bad header, 5 failed reads, no memory; the worker then ends with `running` false and is joined at the next start)
  and the immediate refusal in `negroni_camera_device_create`; scaler outputs (preview, video) at most
  the sensor's 2x2 cells (`PREVIEW_BIN` 2: 2016x1512 for "Photo"), the StillImage output stays full size; tuning
  file from the bundle (`camera-imx789.isp`, none exists yet: identity colour matrix, no lens shading, grey-world
  AWB); `/var/db/negronicam/turned` turns the picture half round; log prefix `negroni: camera:` to stderr and
  os_log.
- `camera_isp.c` / `.h`: names only. Note: the preview path subtracts a fixed black level of 64 (the IMX789 value
  [I]); the TPG (black 0) loses its lowest 64 levels, which does not matter for colour bars.
- `media_hooks.c`: no flashlight code; photo-encoder timing only for pictures 3000+ wide (previews are 2016); 20H392 addresses + first words; cache UUID check; self pin; HAL factory;
  vendor made also without the device (refusing create function); HEVC encoder registered only when
  `/dev/negronicam` exists.

## Test (after the next image + root, owner approval for the flash)

1. Image: kernel with 0317/0318, boot-arg `negronicam=7` (`negronicam_src=1` for colour bars without the sensor
   first), `ADT_CAM=1` (default when the stamp of a CAMERA=1 root exists). Root: `CAMERA=1` (default when the
   bundle is built); build the root before the image. For a live
   test without a new root: `scripts/camera/phone-camera.sh push`, then a reboot (MobileGestalt re-reads the ADT).
2. Home screen: the Camera icon is there (top right of page 1 on the iPhone X layout).
3. Logs: `scripts/net/phone-log.sh mediaserverd` -> `negroni: camera hooks: in mediaserverd ... /dev/negronicam
   there`, 8 lines `replaced`, then on Camera start `the camera's device vendor made`, `the device made: one
   stream`, `frames of 4000x3008 from the kernel`, `PrimaryScaler: the first picture given`. Kernel (USB log):
   `ios session: start (IMX789)`.
4. Screen: the preview (colour bars with `negronicam_src=1`). Shutter: one photograph (HEIC through the software
   HEVC encoder).
5. Colours wrong: `scripts/camera/phone-camera.sh frame` (writes 4 PPMs, one per Bayer order); set
   `negronicam_bayer=N` of the one that looks right. Upside down: `touch /var/db/negronicam/turned` on the phone.
6. Without `negronicam=7`: Camera.app opens and shows no picture / its error; other apps still launch.

## Not verified

- [I] The HAL accepts a factory that returns NULL and keeps going (it loads the code first, so the hooks are in
  either way). If the HAL dislikes it, merge the objects into `NegroniAudio.driver` (one bundle).
- [I] The frames on the phone: the IFE address latch event (SOF vs BUF_DONE, 0318 logs `late address updates`), the
  IMX789 Bayer order of the FTM mode (`negronicam_bayer`), the analog gain formula (1024 - 1024/gain) and the black
  level 64.
- [I] Camera.app's behaviour with a vendor whose device create fails.
- [I] Sensor mounting (picture turned or not), CPU time per preview frame (15 MB copy + 2016x1512 render, 8 pieces).
