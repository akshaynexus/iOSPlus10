# GPU acceleration plan (iOS 16, Adreno 730)

## Reference: ios-sailfish (working GPU on iOS 16)

`external/ios-sailfish` (joranv1/ios-sailfish, a fork of the same dipa-studio/ios-sweet upstream):
iOS 16.7.16 **20H392** (the same build as ours, iPhone 8 identity) on a Pixel 1 (Snapdragon 821,
**Adreno 530**) with GPU-accelerated CoreAnimation. Reported 2026-10-22: up to 60 Hz display
updates, about 20-40 fps UI (CPU work in backboardd is the limit), no Metal.

How it works:

| Layer | sailfish | Files |
|---|---|---|
| Kernel GPU driver | Adreno 530 power, clocks, SMMU, CP microcode, zap shader via TrustZone; buffer objects + command submit | `bsd/dev/sweet_gpu.c`, `iokit/Kernel/arm/SweetGPU.cpp` (in `xnu/patches/`) |
| Kernel user client | IOService `SweetGPU`, msm-DRM-style selectors 10-16 (GEM new/info/close, submit, wait fence, get param, IOSurface import) | same |
| User-space GL | `sweetgl.dylib`: Mesa freedreno (GLES 3.1) + libdrm/msm emulation over the user client + an **EAGL shim** | `tools/sweetgl/{sweetgl.c,eagl.c,sweet_drm.c,mesa.patch,mesa-setup.sh,build.sh}` |
| Hook | `DYLD_INSERT_LIBRARIES=/usr/lib/sweetgl.dylib` into backboardd (boot-arg `sweetenv=`), so CoreAnimation's own OpenGL ES renderer draws on the GPU | boot-args in its README |
| Display | IOSurface + IOMobileFramebuffer (`AppleCLCD`) stand-ins; GPU scales each frame onto the panel, double-buffered | `SweetSurface.cpp`, `SweetFramebuffer.cpp` |

## Our state (from external/slop, made on the NE2213)

- Kernel A730 bring-up (`bsd/dev/negroni_adreno.c`, patches 0099-0124): all 22 steps pass once
  (GMU, HFI, CP, zap via TrustZone, 2D fill with a pixel check).
- `RedwoodGPU` user client (0118, msm-DRM style: GET_PARAM, GEM_NEW/INFO, a7xx submit, WAIT_FENCE,
  CLOSE; **no IOSurface import, no panel present**). The service panicked after unlock; 0124 moves
  it to an IOResources personality (untested).
- slop's user-space side: Mesa 25.0.7 OSMesa (FD730) + `gl_test`, softpipe only so far.

## Plan

1. First iOS 16 boot without GPU (current step).
2. Boot slop 0124 with the GPU kept on (`negroniadreno=22 negroniadreno_keep=1`); check that
   RedwoodGPU no longer panics.
3. Port sailfish's `sweetgl.dylib` to A730:
   - `sweet_drm.c`: map its SweetGPU selectors to RedwoodGPU's (or give RedwoodGPU the same
     selector table), match the a7xx submit format;
   - Mesa: a7xx needs a newer Mesa than sailfish's a5xx setup (freedreno gallium supports a7xx;
     slop already builds Mesa 25.0.7 with FD730) -> apply sailfish's `mesa.patch` / EAGL shim on top;
   - add IOSurface import + present to RedwoodGPU (sailfish `SweetSurface`/`SweetFramebuffer`).
4. Inject into backboardd with `DYLD_INSERT_LIBRARIES` (sailfish's `sweetenv=` boot-arg patch).
5. Later (iOS 26): Metal is required there (open question in research-report.md); the UniXNU
   NativeMetal path, not this GL path.

Licensing: ios-sailfish has no license file (like slop). Use it as a reference; ask the author
before copying code into this repo.
