# Review: Turnip + Metal (NegroniMetal), 2026-10-25

Scope: the NegroniMetal plugin for iOS 16.7.16 (20H392) on the Adreno 730, round 2. Marks: [V] seen, [I] inferred.
Nothing in this file ran on the phone.

## What works (host)

- [V] Host shader check of QuartzCore `default.metallib` (`scripts/metal/host-translate.sh`). The script now answers
  every pipeline input the compile asks for: vertex attributes, function constants (first type the constant accepts,
  value zero/false) and attachment formats.

  | Profile | kernel | vertex | fragment | Refusals left |
  |---|---|---|---|---|
  | vk12-floor (bare Vulkan 1.2) | 7/7 | 39/39 | 75/95 | 20 FramebufferFetch |
  | A730 estimate (`scripts/metal/a730-profile.py`) | 7/7 | 39/39 | 93/95 | 2 RasterOrderGroups (`inplace_copy_lpf/lph`) |

  Round 1 had 3/7, 35/39, 73/95. The A730 profile is vk12-floor limits plus the features and extensions that Mesa
  25.0.7 `tu_device.cc` answers for FD730 [I: a source reading, not a capture]. Turnip 25.0.7 has no
  `VK_EXT_fragment_shader_interlock`, so the 2 refusals are real [I: CA uses them only when the device reports raster
  order groups]. The 4 tile kernels pass only as tile pipelines. Function constants are stand-ins, not CA's values.
- [V] Static selector check (`scripts/metal/selector-gap.py`): QuartzCore names 222 Metal protocol selectors. The flame
  frontend lacked 20 of them. Patch `userland/metal/patches/flame/0001-negroni-surface-hook-qc-selectors.patch` adds
  them. Now 0 are missing. [I] A string in QuartzCore is not proof of a call.
- [V] Plugin logic host test on the Mac (`scripts/metal/host-plugin-test.sh`, host bridge + MoltenVK as the loader).
  7 cases pass: unlisted, off, no GPU, 1 ms timeout (twice, then strikes = 2), dead-man, device. The device case ran
  the IOSurface clear self-test through the frontend in 681 ms.

## What changed in the plugin (`userland/metal/plugin/NegroniMetal.mm`)

- Fast refusals before Turnip loads: `/var/db/negronimetal/off`, not in `clients`, boot-arg `negronimetal=0`,
  no `RedwoodGPU` service, no Turnip dylib. Each one returns nil. Metal skips a nil device, so CA uses the GL fallback.
- The open and a self-test run on their own thread (8 MiB stack). The caller waits at most `NEGRONIMETAL_OPEN_MS`
  (default 6000 ms). A timeout keeps the dead-man strike, so two hangs in a row disable the process.
- Self-test: a GPU clear into a 64x64 BGRA8 IOSurface-backed texture, read back on the CPU. That is the render
  server's path (import, submit, fence, cache maintenance). It uses no shaders. When it fails, a plain texture clear
  goes into the log as a diagnosis. `NEGRONIMETAL_SELFTEST=0` skips it.
- IOSurface hook: the frontend tells Turnip's `redwood_drm_note_surface` (GPU agent, `negroni_drm.c`) each surface's CPU
  range and ID before the import. The kernel then imports the surface by ID (selector 0x7e). Kernel 0230 has no
  user-page import.
- backboardd writes the frontend's telemetry to `metal.log` every 10 s while `/var/db/negronimetal/telemetry` exists.
- The allow-list, the crash counter (dead-man) and the boot-arg switches stay.

## What builds

- [V] `scripts/metal/build.sh` (Xcode 27.1, iPhoneOS SDK, minos 16.0): NegroniMetal bundle 21 MB, metalprobe,
  vkprobe, m2vtest. No compiler warnings.
- [V] The plugin and the frontend also compile with Xcode 15.4 (iPhoneOS 17.5 SDK) for arm64-apple-ios16.0.
- [V] `scripts/metal/check-imports.py` against the 20H392 cache: PASS for our binaries.
- [V] The staged Turnip (GPU agent build, 00:22) fails the same check on one symbol: `dyld_stub_binder` (the dylib
  uses LC_DYLD_INFO_ONLY; the symbol is `local` in the 20H392 libdyld). [I] dyld4 can still bind it. A Turnip link
  with chained fixups removes the doubt.

## What is untested

- Everything on the phone: Metal discovery through patch 0205, Turnip on the A730, the kernel user client, the
  self-test, CA pipelines with real function constants and vertex layouts, present.
- The staged Turnip does not export `redwood_drm_note_surface` yet. Without it (and without a kernel user-page import)
  the self-test fails and the plugin returns nil. The GPU agent's uncommitted `negroni_drm.c` has the function.
- The A730 profile is an estimate. CA's real pipeline variants are not tested.
- The new texture answers (swizzle, compression, sparse, `gpuResourceID`) are plain values. Only a non-identity swizzle
  view is refused.

## Next steps (phone test)

1. GPU agent: rebuild Turnip with `redwood_drm_note_surface` exported and with chained fixups. Then
   `scripts/metal/build.sh` (copies Turnip into the bundle) and `check-imports.py` again.
2. Boot with `negroniadreno=22 negroniadreno_keep=1 negronigpu_pool=512` (RedwoodGPU published, WC pool for Turnip).
3. `scripts/metal/phone-test.sh push`, then stages 0, 1, 2, 3. Stage 1 runs the plugin's self-test: read
   `metal.log` for the `device ... self-test on` line.
4. Stage 4: add `backboardd` to `/var/db/negronimetal/clients`, restart backboardd, look at the panel. The kill switches:
   `touch /var/db/negronimetal/off` or boot-arg `negronimetal=0`.
5. Host: capture a real Turnip profile on the phone (vkprobe / vulkaninfo) and rerun `host-translate.sh` with it.
