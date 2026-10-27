# NegroniFlashlight: the iOS side of the torch

Kernel side: patch 0387 (`patches/xnu/README-flash.md`), `/dev/negroniflash`, write `0`..`10`.
This directory holds code for NegroniCamera.driver (mediaserverd). It is not built yet: the camera agent merges it.

## How iOS 16.7.16 (20H392) drives the flashlight [V, 20H392 dyld cache disassembly, out/camera/ios-re]

1. Button: `+[AVFlashlight hasFlashlight]` = `MGGetBoolAnswer("camera-flash")` (AVFCapture 0x19f0c6338).
   libMobileGestalt (0x19c563598) answers true when `IODeviceTree:/product/camera` has a property `flash`
   (presence only). Without it Control Center has no flashlight button.
2. Control Center / AVFlashlight -> mediaserverd FigFlashlight server (CMCapture `FigFlashlightServerStart`, started by
   our `start_capture_servers()`).
3. `flashlight_setupDevice` (0x1a2000a28): `[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` ->
   `registerClientWithPID:clientDescription:("FigFlashlight")clientPriority:canStealFromClientsWithSamePriority:deviceSharingWithOtherClientsAllowed:deviceAvailabilityChangedHandler:`
   -> `copyDeviceForClient:informClientWhenDeviceAvailableAgain:error:` ->
   `copyStreamForFlashlightWithPosition:1 (back) deviceType:2 (wide) forDevice:` -> if the stream's
   `supportedProperties` has `HighCurrentTorchEnabled`, `setProperty:` it.
4. `flashlight_SetLevel` (0x1a2000860): a level above `-[FigCaptureThermalMonitor maxTorchLevel]` fails (-16530).
   maxTorchLevel = 1.0 at thermal notify state 0, kept at 20..29, 0 above 29.
5. `flashlight_setLevelInternal` (0x1a2000bdc): `[stream setProperty:kFigCaptureStreamProperty_TorchLevel ("TorchLevel")
   value:NSNumber(float 0..1)]`.
6. `flashlight_IsAvailable`: `[vendor activeDeviceEquals:device]`. `flashlight_teardownDevice`: TorchLevel 0, then
   `takeBackDevice:forClient:informClientWhenDeviceAvailableAgain:`. Availability listener: `activeDeviceEquals:`,
   `activeDeviceClientPriority`.
7. Camera.app torch: `hasTorch` / `hasFlash` come from `CMCapture.framework/D22/AVCaptureSession.plist`; the back
   wide device (`built-in_video:0`) has both true on the phone [V]. The level goes to the same stream property `TorchLevel`.
8. Other keys (not needed for the torch): `kFigCaptureSourceProperty_TorchLevel`, `_TorchActive`, `_TorchOverheated`,
   `kFigCaptureStreamProperty_HighCurrentTorchEnabled`, `_FlashMode`.

## What NegroniCamera must answer

- Stream property `TorchLevel` (Number, ReadWrite): set -> `negroni_flashlight_set(level)`; get -> the last level.
  `camera_device.c` already lists it in its supported properties and calls `torch_set()`.
- `HighCurrentTorchEnabled` (Boolean): accepted, ignored (already so).
- Without a camera device (no `/dev/negronicam`, or `negronicam_failed`): the hook of `sharedCaptureDeviceVendor`
  returns `negroni_flashlight_vendor_for(return address)` for FigFlashlight call sites only (20H392 ranges
  0x1a20007b0-0x1a2000bdc, 0x1a1f3e540-0x1a1f3e668, 0x1a1fa9e70-0x1a1faa0f8). That vendor has one device and one
  stream; the stream sets `TorchLevel` only.

## Files

- `negroni_flashlight.c` / `.h`: `negroni_flashlight_init(slide)`, `negroni_flashlight_set(level)`,
  `negroni_flashlight_vendor_for(return_address)`. Level map: N = round(level * 10), at least 1 for level > 0.
  Compiles clean with the iPhoneOS SDK (camera build flags).
- `camera-merge.patch`: the changes to `userland/camera/{camera_device.c, media_hooks.c, build.sh}` (made against the
  files of 2026-10-27 18:32 IST; `git apply --check` passed then). The merged bundle compiled clean.
- ADT: `ADT_FLASH=1 scripts/ios16/adt-extra.py ADT` adds `/product/camera` `flash` = 01:00:00:00 (and the node if
  `ADT_CAM` did not make it). `scripts/ios16/build.sh` does not set `ADT_FLASH` yet: set it by default when the
  kernel has 0387 and the root has the merged NegroniCamera.

## Test (after kernel 0387 + merged bundle + ADT_FLASH=1 image)

1. `scripts/net/ssh-phone.sh 'ls -l /dev/negroniflash'` -> `crw-rw---- root mobile`.
2. Unified log: `negroni: flashlight: on: /dev/negroniflash open`.
3. Control Center: the flashlight button is there. Tap: LED on; log `TorchLevel 1.000 -> level 10/10`
   (or the level of the long-press slider). Tap again: off.
4. Camera.app torch (video mode): the same path through the camera stream.

## Risks [I]

- The caller ranges are 20H392 only (the cache UUID check of media_hooks.c guards them).
- If FigFlashlight registers on the camera vendor while Camera.app owns the device, priority rules of the vendor decide;
  not tested.
- `/product/camera` without `ADT_CAM` makes MobileGestalt answer `video-camera` true.
- mediaserverd sandbox: `/dev/negronicam` opens from mediaserverd [V, camera works]; `/dev/negroniflash` is the same
  owner/mode, so the same rules should apply.
