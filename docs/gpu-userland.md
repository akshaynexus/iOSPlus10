# GPU user space (negronigl + Turnip), status 2026-10-24

Goal: `out/gpu/negronigl.dylib` (Mesa freedreno GLES behind an EAGL shim, injected into
backboardd) and `libvulkan_freedreno` (Turnip) for iOS 16 arm64 on the Adreno 730
(chip id 0x07030001, FD730).

**Status: NOT finished.** The Mesa configure and the GL-side static libraries build.
negronigl.dylib does not build yet: its sources are incomplete. Turnip does not compile yet.

## Versions (pins in `scripts/gpu/env.sh`)

| Item | Value |
|---|---|
| Mesa | 25.0.7, sha256 `592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6` (archive.mesa3d.org) |
| freedreno-on-Darwin patches | oosexgang/hackios-xnu-userland `b4c5513e2df93689895d21fd3b93b723a7bcfdd3` (MIT), the same pin as `external/slop/.github/workflows/gpu-mesa.yml`: `freedreno-darwin`, `ir3-round-default`, `ir3-shift-split`, `ir3-ssbo-subdword` (read with `git show COMMIT:tools/mesa/...`) |
| Our Mesa patch | `userland/negronigl/mesa-patches/0001-negronigl-target.patch` (adds `src/gallium/targets/negronigl`) |
| Toolchain | Xcode 27.1, iPhoneOS 27.1 SDK, `-target arm64-apple-ios16.0` (checked: LC_BUILD_VERSION minos 16.0), meson 1.7.2 (uv venv `out/gpu/venv`), ninja 1.13.2, brew bison 3.8.2, brew glslang 16.6.0 (needed by Turnip) |

## Build steps (macOS; run each one through tmux)

```sh
scripts/bg.sh gpu-fetch scripts/gpu/mesa-fetch.sh        # venv, archive + hash, patched tree out/gpu/mesa-25.0.7
scripts/bg.sh gpu-setup scripts/gpu/mesa-setup.sh        # meson -> out/gpu/mesa-build-ios (copies userland/negronigl in)
#   NEGRONIGL_TARGET=0 scripts/gpu/mesa-setup.sh         # Mesa + Turnip without our target
#   VULKAN_DRIVERS= scripts/gpu/mesa-setup.sh            # without Turnip
scripts/bg.sh gpu-build sh -c 'PATH=$PWD/out/gpu/venv/bin:$PATH ninja -C out/gpu/mesa-build-ios -j$(sysctl -n hw.ncpu)'
```

Linux: `scripts/gpu/env.sh` has a clang + lld + llvm-ar path with `SDK=` pointing to an
iPhoneOS SDK copied from a Mac. That path is NOT tested.

## Observed results (build `gpu-build1`, NEGRONIGL_TARGET=0, Turnip on)

- Configure: OK (gallium freedreno, vulkan freedreno, freedreno-kmds msm, shared-glapi, GLES2).
- 737 of 740 steps OK, including `libfreedreno.a`, libmesa, libgallium, glapi.
- 3 failures, all on the Turnip side:
  1. `src/vulkan/runtime/vk_drm_syncobj.c`: `drmSyncobjTimelineSignal`, `drmSyncobjSignal`,
     `drmSyncobjQuery` are not in our `xf86drm.h`.
  2. `src/vulkan/wsi/wsi_common_drm.c`: `drmDevicePtr`, `drmGetDevice2`, `drmDevicesEqual`,
     `drmFreeDevice`, `drmSyncobjTransfer` are missing, and `-Werror=missing-prototypes`.
     There is no window system here, so this file can probably be left out of the build (guess).
  3. `src/freedreno/vulkan/tu_device.cc:2712`: `pthread_condattr_setclock` does not exist on Darwin.

## What Turnip needs from the kernel ABI (for docs/gpu-abi.md)

These facts come from the errors above and from Mesa 25.0.7's msm backend. They are not tested on the device.
- **DRM syncobjs.** The Vulkan runtime syncs the msm Turnip backend with `vk_drm_syncobj`
  (create, destroy, wait, reset, signal, timeline signal/wait, query, transfer, fd import and export).
  Two options: (a) the kernel adds syncobj selectors, or (b) negroni_drm.c emulates syncobjs
  in user space over the msm fence seqnos. With (b), queue submit must accept
  `MSM_SUBMIT_SYNCOBJ_IN/OUT` without the kernel. Either way the ABI must state it. The
  scalar ABI rejects these flags today.
- The same buffer, submit, fence and param requests as freedreno gallium. Turnip also asks
  for `MSM_PARAM_VA_START/VA_SIZE` (userspace VMA). The emulation answers EINVAL today (msm 1.7 softpin).

## Files

- `scripts/gpu/env.sh`, `mesa-fetch.sh`, `mesa-setup.sh`, `sync-target.sh`
- `userland/negronigl/drm/ngl_abi.h`: the kernel ABI in one header, with two ABIs: scalar
  (sailfish-style selectors 10-16) and msm struct passthrough (slop 0118 / HackiOS). `NEGRONIGL_ABI` picks one at run time.
- `userland/negronigl/drm/negroni_drm.c`, `negroni_drm.h`, `xf86drm.h`: libdrm/msm emulation (complete, not compiled yet).
- `userland/negronigl/{negronigl.c,negronigl.h,log.c,meson.build}`: screen, contexts, self tests, log.
- `userland/negronigl/surface.c`: **incomplete** (the file stops mid-function).
- Missing: `eagl.c`, `shaders.c`, `ca_fixes.c`, `gen-gli.py`, `gli-slots.txt`, `exports.txt`,
  `tools/ngl_test.c`, `scripts/gpu/build.sh`, `scripts/gpu/root-add-negronigl.sh`.

## Kernel-side requirement for injection (not in this scope)

dyld honours `DYLD_INSERT_LIBRARIES` in backboardd only if the AMFI policy answers
`amfi_check_dyld_policy_self` (`__mac_syscall("AMFI", 0x5a, ...)`). The slop kernel names
its policy "NEGRONI AMFI", so dyld ignores the variable. References: ios-flame
`xnu/patches/0114-flame-amfi-dyld-policy.patch` (MIT), ios-sailfish `0139-sailfish-amfi-dyld-policy.patch`.
