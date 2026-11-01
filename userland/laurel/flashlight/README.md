# LaurelFlashlight.driver: the mediaserverd side of the Mi A3 torch

Kernel side: patch 2780 (`docs/laurel_sprout/torch.md`), `/dev/laureltorch`, write `0`..`100` (percent).
Status (2026-11-01): built on Linux (arm64 bundle, minos 16.0, ad hoc signed). NOT RUN on the phone.

- `laurel_flashlight.c`: a HAL plug-in (factory `LaurelFlashlight_Create` returns NULL) that mediaserverd loads from
  `/System/Library/Audio/Plug-Ins/HAL` (as RedwoodAudio.driver). Its constructor, in mediaserverd only, checks the cache
  UUID (20H392), opens `/dev/laureltorch`, pins the bundle, and on the main queue: loads CMCapture, replaces
  `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` (address + first word checked) so that FigFlashlight callers
  get a torch vendor (device + stream; `TorchLevel` 0..1 -> percent), then starts `FigFlashlightServerStart` when
  `StartRecorderServer` is false (the laurel root). Every guard that fails leaves mediaserverd as it is and logs one
  `LAUREL FLASHLIGHT: off: <why>` line (os_log + /dev/console = the USB log).
- Ported from negroni `userland/flashlight` (its fallback vendor; the HakiOS idea, MIT) without the camera parts.
- Build: `userland/laurel/flashlight/build.sh` -> `out/laurel/flashlight/LaurelFlashlight.driver`.
- Root: `scripts/laurel/root-flashlight.sh MOUNTED_ROOT` (root.sh; `TORCH=0` skips).
- Hot off switch on the phone: `touch /var/db/laurel/flashlight-off` (next mediaserverd start does nothing).
