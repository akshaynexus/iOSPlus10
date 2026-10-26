# GPU user space: Mesa freedreno, EAGL shim and Turnip

Target: iOS 16.7.16 (20H392), arm64, OnePlus 10 Pro NE2211, Adreno 730 (Mesa chip id
`0x07030001`, FD730). Mesa 25.0.7 is cross-compiled for iOS 16.0. The GL path aims to make
CoreAnimation's OpenGL ES renderer in `backboardd` use freedreno. Turnip provides Vulkan for
later Metal-on-Vulkan work.

## Pinned inputs

| Input | Version |
|---|---|
| Mesa | 25.0.7, SHA-256 `592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6` |
| HackiOS Darwin patches | `oosexgang/hackios-xnu-userland` `b4c5513e2df93689895d21fd3b93b723a7bcfdd3`, MIT: `freedreno-darwin`, `ir3-round-default`, `ir3-shift-split`, `ir3-ssbo-subdword` |
| Local Mesa patches | `userland/negronigl/mesa-patches/0001-negronigl-target.patch`, then `userland/turnip/mesa-patches/0001-turnip-darwin.patch` (the one Turnip-on-Darwin patch, shared with `scripts/gpu/turnip-build.sh`; the GL tree's own copy `0002-turnip-darwin.patch` was removed on 2026-10-26: it had drifted and the GL build does not build Turnip) |
| Cross toolchain | Xcode 27.1 iPhoneOS SDK, `-target arm64-apple-ios16.0`, Meson 1.7.2, Ninja 1.13.2, Homebrew Bison 3.8.2 and glslang 16.6.0 |

## Build on macOS

Long jobs use the repository tmux wrapper. It records the log in `logs/gpu-build.log` and the exit
code in `logs/gpu-build.exit`.

```sh
scripts/bg.sh gpu-build scripts/gpu/build.sh
scripts/bg.sh -s gpu-build
```

The build script fetches the pinned Mesa archive if needed, applies both local patches, configures
freedreno GLES and Turnip for iOS arm64, builds `negronigl.dylib`, `libvulkan_freedreno.dylib` and
`ngl_test`, then ad-hoc signs the three Mach-O files. Outputs are in `out/gpu/`. The exact Meson
setup is in `scripts/gpu/mesa-setup.sh`; `scripts/gpu/env.sh` pins the SDK target and tools.

Linux cross-builds are not verified. They need an iPhoneOS SDK copied from a Mac and `SDK=/path/to/iPhoneOS.sdk`;
the script selects clang, lld and LLVM binutils. The Linux path must be confirmed before relying on it.

Build run `gpu-build` completed with exit 0 on 2026-10-25. `out/gpu/negronigl.dylib` is 15,119,584
bytes, `out/gpu/libvulkan_freedreno.dylib` is 11,612,528 bytes, and `out/gpu/ngl_test` is 50,256
bytes. All three are arm64 Mach-O files with `LC_BUILD_VERSION` minimum iOS 16.0 and ad-hoc
signatures. The Turnip dylib links its own copy of `negroni_drm.c` and `log.c`; `nm -u` showed no
unresolved DRM symbols. The link uses `-undefined dynamic_lookup`, which Xcode warns is deprecated
on iOS. `nm -m` reports 650 weak `_wsi_*` symbols as dynamically looked up; their runtime binding
and the Turnip load path still need a device check.

## Installation into a root image

`scripts/gpu/build.sh` also makes `out/gpu/NegroniGL.bundle` (`NegroniGL` + `Info.plist`, ad hoc
signed). It exports the 129 GLD names of libGFXShared's table plus `gldInitializeLibrary` and
`gldTerminateLibrary`; the build fails if one is missing. The hook in `scripts/ios16/root-finish.sh`
installs it when `NEGRONIGL=1`:

```sh
NEGRONIGL=1 scripts/gpu/root-add-negronigl.sh /path/to/MOUNTED_ROOT     # as root
scripts/gpu/test-root-add-negronigl.sh                                   # fake-root check, no root needed
```

It copies the bundle to `/System/Library/Extensions/NegroniGL.bundle` (root:wheel, 755/644) and
removes the old `DYLD_INSERT_LIBRARIES=/usr/lib/negronigl.dylib` entry of backboardd if a root has it.
The fake-root check passed on 2026-10-25.

Status (2026-10-25): the GLI part (EAGL contexts on Mesa) is written and builds. The bundle exports
all 18 `gli*` entries; `ngl_gli_register` redirects OpenGLES's `_gli_plugin` to us so EAGL binds them,
and `gldChoosePixelFormat` returns the pixel format (notes section 15a). Not run on the phone yet.

Driver choice in `ngl_init`: freedreno when RedwoodGPU opens, else softpipe (CPU, IOSurfaces mapped in
place by `sw_winsys.c`). `NEGRONIGL_DRIVER=softpipe|freedreno` or the boot-arg `negronigl_sw=1` override.
Turnip is no longer built by `build.sh`; `scripts/gpu/turnip-build.sh` owns it.

## Kernel interface and limits

`userland/negronigl/drm/ngl_abi.h` supports the scalar `RedwoodGPU` selectors and the MSM struct
passthrough ABI. The scalar path handles GEM allocation/import, submit, waits, parameters and CPU
prep. User-space binary syncobjs map to MSM fence sequence numbers; queue-submit input syncobjs wait
on those fences and output syncobjs receive the returned sequence. `DRM_CAP_SYNCOBJ_TIMELINE` is
reported as zero. Timeline entry points exist for Mesa compatibility, but timeline points are not
implemented. Cross-process sync-file/opaque-fd sharing is not supported. The MSM struct ABI's
kernel-side syncobj submission also remains unimplemented; the default build config selects the
scalar ABI first.

IOSurfaces are described through the public IOSurface API, imported through the RedwoodGPU
surface/GEM path and wrapped with Mesa `resource_from_handle`. The current path accepts a single
plane and formats mapped by `surface.c`. Multi-plane YUV surfaces and the copy fallback for layouts
that freedreno cannot address are unsupported. `renderbufferStorage:fromDrawable:` is now served through
the GLI plugin (`plugin/gli_view.c` gliBindViewES: the drawable IOSurface becomes GL_RENDERBUFFER
storage via `surface.c`; since 2026-10-26 the code is `view.c`, shared with the dylib's shim); CoreAnimation's private `attachImage:toCoreSurface:invertedRender:` and
`texImageIOSurface:` paths use the imported texture resource. Not run on the phone.

**Phone status (2026-10-26):** `ngl_test` passed on the phone on 2026-10-25 23:35 ("Device testing over SSH" below:
`GL_RENDERER FD730`, triangle and IOSurface selftests PASS), so the kernel GPU service, the IOSurface import and the
fence path work for a test process. Still unverified on the device: backboardd on GL past CoreAnimation's first frame
(kernel 0257 and the eagl.c guard are built, not run), the NegroniGL.bundle GLI route for apps, `ngl_test --layer`.
The kernel ABI is in `userland/negronigl/drm/ngl_abi.h` and `docs/gpu-abi.md`.

## Device testing over SSH

After a root image boots with the kernel GPU service and USB SSH available, use the existing
`scripts/net/phone-run.sh` workflow. It copies a signed binary to the phone, runs it, prints the
result and removes the remote copy by default.

```sh
scripts/net/phone-run.sh -s out/gpu/ngl_test
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -target arm64-apple-ios16.0 -isysroot "$SDK" \
  -Iout/gpu/mesa-25.0.7/include userland/metal/probes/vkprobe.c -o out/gpu/vkprobe
codesign -s - -f out/gpu/vkprobe
scripts/net/phone-run.sh -s out/gpu/vkprobe --icd /usr/lib/libvulkan_freedreno.dylib --clear
```

`ngl_test` checks the GPU identity, a GLES draw/readback and an IOSurface round trip. `vkprobe`
enumerates Turnip and, with `--clear`, submits a clear and readback. No device results are claimed
here.

## GL path (ported from ios-spes)

Second acceleration route for CoreAnimation, beside the Metal path (NegroniMetal -> metal2vulkan -> Turnip)
and the GLD plugin route above (NegroniGL.bundle, which needs kernel patch 0205). It is the route the
reference port `external/ios-spes` (Redmi Note 11, Adreno 610) runs its UI on: backboardd loads an EAGL
bridge dylib at start, the bridge replaces the `EAGLContext` methods CoreAnimation uses, and every GL call
goes to Mesa freedreno. Nothing in the kernel chooses it; it is an A/B switch in user space.

What spes does (compact):

| spes piece | spes file | our port |
|---|---|---|
| backboardd gets an `LC_LOAD_WEAK_DYLIB /redwood/lib/libredwood-gl.dylib` written into the zero padding after the load commands, ad hoc re-signed with the original entitlements; only backboardd, no launchd or `DYLD_INSERT_LIBRARIES` change | `tools/stage-spes-eagl.py` | `scripts/gpu/stage-backboardd-gl.py` (same algorithm; dependency `/usr/lib/negronigl.dylib`) |
| EAGL bridge = HackiOS `userland/src/eagl.c` (ObjC method replacement on EAGLContext) + `gl_osmesa.c` over `libOSMesa.8.dylib` (Mesa 25.0.7, freedreno msm, redwood-drm) | `tools/build-spes-eagl-macos.sh`, `tools/build-spes-mesa-macos.sh` | `userland/negronigl/eagl.c` + `negronigl.c` (one dylib with Mesa linked in, our `drm/negroni_drm.c`); built by `scripts/gpu/build.sh` |
| preflight before any method is replaced: boot-arg `spesgpu=1`, wait 30 s for `RedwoodGPU`, ES 3.0 context, renderer must say FD610, green triangle on blue read back; else "keeping Apple methods" | `xnu/graphics/spes_gl_preflight.c` | `ngl_preflight()` in `negronigl.c`: gate file instead of the boot-arg, wait `NEGRONIGL_WAIT` s (30), renderer must say `FD730`, `ngl_selftest()` (red triangle, FBO) and `ngl_surface_selftest()` (BGRA IOSurface) must PASS |
| attachImage fills the mirrored target by a GPU blit instead of a CPU hash+upload; BGRA refills by `glTexSubImage2D` | `tools/eagl-attach-gpu.patch` | not needed: our `surface.c` binds the IOSurface itself as the GL resource (import by IOSurface ID, selector 0x7e), there is no mirror copy |
| `glFlush` = finish, because the display swaps without waiting for the GPU; `RedwoodWaitsForGPU` property lets the bridge skip it | HackiOS eagl.c `display_waits()`, spes 0102 | `ngl_h_Flush` = `ngl_flush()` (view.c): `glFlush` when RedwoodGPU publishes `RedwoodWaitsForGPU` (kernel 0289: the IOSurface CPU lock waits for the surface's fence; the display waits on the fence recorded at SwapEnd, 0254), else `glFinish`. `glFinish` also with `NEGRONIGL_FINISH=1` or the file `finish` ("Flush and fences" below) |
| bank layout: `highest_bank_bit = 14` for chip 0x06010001 | `build-spes-mesa-macos.sh` PYBANK | A730 (0x07030001) keeps Mesa's 16 (notes 16); `FD_MESA_DEBUG=sysmem` (spes: `sysmem,noubwc`) |

Differences for the A730: chip id 0x07030001 (FD730, a7xx gen1), our msm-style ABI in `negroni_drm.c`
(scalar RedwoodGPU selectors + struct passthrough), 16 KiB pages split into 4 KiB GPU pages by the kernel,
IOSurface import by ID (0x7e). spes imports the surface's bytes through redwood-drm `surfaceBuffer` and
needs BGRA, plane 0, not inverted, whole surface for zero copy; ours wraps the imported GEM with
`resource_from_handle` (surface.c, one plane).

### Build and stage

```sh
scripts/bg.sh gl-build scripts/gpu/gl-build.sh      # Mesa + dylib + stage + check-imports
scripts/bg.sh -s gl-build
```

`out/gpu/stage/`: `usr/lib/negronigl.dylib`, `usr/local/bin/ngl_test`, `usr/libexec/backboardd` (Apple's
20H392 backboardd + the weak load command; made from `IOS_ROOT=/private/tmp/iosroot-ro`),
`var/db/negronigl/clients` (empty gate). Build 2026-10-25: exit 0; stripped `negronigl.dylib` 14,214,272
bytes, `ngl_test` 50,336 bytes, staged `backboardd` 1,159,536 bytes (original 1,184,848; the ad hoc
signature is smaller), `otool -L` shows `/usr/lib/negronigl.dylib ... weak`; `check-imports.py` against the
20H392 cache: PASS (0 missing; 264 imports in 7 libraries).

Build 2026-10-26 (`gl-build`, exit 0, no root attached: backboardd from the earlier `out/gpu/backboardd-gl`, cache
`out/dsc/cache`): the stage also has `System/Library/Extensions/NegroniGL.bundle/{NegroniGL,Info.plist,apps}`.
Stripped sizes and sha256: `negronigl.dylib` 14,233,120 (2b7dd515...), `ngl_test` 50,496 (8f7d3778...),
`NegroniGL` 13,777,024 (bf4c7bde...), backboardd unchanged 1,159,536 (39cb14d1...). check-imports PASS (0 missing)
for all three binaries; NegroniGL 129/129 GLD + 18/18 GLI names. Full list: `out/gpu/stage.SHA256SUMS`.

### The switch

The dylib's constructor (`ngl_load`) installs the shim only when
1. `/var/db/negronigl/off` is absent and the process name is in `/var/db/negronigl/clients` (`*`,
   `-NAME` as in `/var/db/negronimetal/clients`); `NEGRONIGL_EAGL=1|0` in the environment overrides; and
2. the preflight passes (above). A failed preflight logs `negronigl: preflight FAIL ...: Apple's EAGL kept`
   and backboardd runs on Apple's software GL as before.

### Phone test (SSH up, `scripts/net/ssh-phone.sh`)

```sh
scripts/gpu/phone-gl.sh push          # dylib, ngl_test, clients (single files, no archive)
scripts/gpu/phone-gl.sh test          # ngl_test: GPU identity, triangle PASS, IOSurface PASS
scripts/gpu/phone-gl.sh backboardd    # backboardd.orig kept, the weak-dylib copy installed
scripts/gpu/phone-gl.sh on            # backboardd into the gate
scripts/gpu/phone-gl.sh restart       # or scripts/net/ssh-phone.sh reboot
scripts/gpu/phone-gl.sh log           # live: negronigl lines from backboardd
scripts/gpu/phone-gl.sh off; scripts/gpu/phone-gl.sh restart     # A/B back
scripts/gpu/phone-gl.sh restore       # Apple's backboardd back
```

Proof lines (backboardd, `/dev/console` + os_log `dev.iosplus10.negronigl`):
- `negronigl: loaded into backboardd (pid N), EAGL shim wanted`
- `negronigl: image base 0x... /usr/lib/negronigl.dylib (atos -o out/gpu/negronigl.dylib -l BASE ADDR)`
  (symbolicate a crash pc/lr against the unstripped build with this base)
- `negronigl: negronigl (Mesa 25.0.7, freedreno A730 / softpipe), screen FD730 (freedreno)`
- `negronigl: selftest ... : PASS`, `negronigl: surface selftest ... : PASS`
- `negronigl: preflight PASS renderer=FD730 triangle=PASS iosurface=PASS after N ms`
- `negronigl: EAGL shim installed`, then `negronigl: EAGLContext 0x... API 3 on Mesa (GLI 0x...)` (CA's
  context) and the UI on the panel. Kernel side (`make usblog`): `NEGRONI FB STAT: ... presents/s N (cpu N
  gpu N zc N)` with `gpu` or `zc` > 0, `RedwoodGPU: present N: surface ...` lines.
- Failure: `preflight FAIL`, `GL error 0x... after slot N`, `shader N compile failed`, a black or frozen
  screen (then `off` + `restart`; `restore` if backboardd does not come up at all).

Seen on the phone [V] 2026-10-25 23:35, `NEGRONIGL_LOG=stderr /usr/local/bin/ngl_test` (shim off, gate
empty), after the `get_param` fix (notes.md 15a; before it the first context jumped to address 0):
```
negronigl: loaded into ngl_test (pid 352), EAGL shim off
negronigl: image base 0x100fcc000 /usr/lib/negronigl.dylib (atos -o out/gpu/negronigl.dylib -l BASE ADDR)
negronigl: RedwoodGPU open, scalar ABI, chip 0x7030001, GMEM 2048 KiB, max 818 MHz, kernel ABI "scalar 10-16, msm 0x09 0x40-0x4c 0x7e, userptr 0x49, va shared"
negronigl: negronigl (Mesa 25.0.7, freedreno A730 / softpipe), screen FD730 (freedreno)
negronigl: GL_VERSION OpenGL ES 3.2 Mesa 25.0.7 / GL_RENDERER FD730 / GLSL OpenGL ES GLSL ES 3.20
negronigl: selftest fbo 0x8cd5 linked 1 err 0 px(32,32) ff0000ff px(224,224) 0000ffff context 99.3 ms draw+readback 12.88 ms: PASS
negronigl: second frame clear+draw+finish 1.44 ms
negronigl: surface selftest bound 1 fbo 0x8cd5 BGRA(32,32) 0000ffff BGRA(224,224) ff0000ff: PASS
selftest PASS, surface selftest PASS
```

Unverified [I]: the backboardd steps (staged backboardd, gate, preflight in backboardd) did not run yet. Open points: ad hoc re-signed backboardd under our
AMFI (slop 0025/0035/0036 + 0221 accept ad hoc platform binaries for the Metal bundle, but a main
executable with entitlements was not tried); the 30 s synchronous preflight delays backboardd's start by
the GPU's readiness. (2026-10-26: `renderbufferStorage:fromDrawable:` and `presentRenderbuffer:` work on Mesa
contexts, and flush no longer finishes: next section.)

### Flush and fences (2026-10-26)

[V code] Why `glFlush` is enough with kernel 0254:
- CA's frame ends in `glFlush` (GLI slot `Flush`) and then an IOMobileFramebuffer swap. `ngl_flush()` (view.c)
  calls `glFlush`: Mesa freedreno flushes the batch and submits at once. Submit merging (`should_defer`,
  `freedreno_ringbuffer_sp.c`) never defers a submit that lists a shared bo, and an imported IOSurface is a shared
  bo (`fd_bo_from_dmabuf` sets `FD_BO_SHARED`). The msm backend has no submit thread (only virtio has one), so the
  submit ioctl is done when `glFlush` returns.
- `negroni_drm.c s_gem_submit` copies every bo handle of the submit into the kernel's list (`hdr->nr_bos`). The
  kernel (0230) sets `gpuFence` of each imported surface in that list to the submission's fence. 0254 records that
  fence at SwapEnd and shows the frame only when it is done (docs/gpu-abi.md section 8).
- A later reader on the GPU (backboardd sampling an app's surface) is behind the render on the same ring.
- CPU readers (`IOSurfaceLock` + read: snapshots, CA's CPU fallback, a CPU-composited backboardd sampling an app's
  surface): kernel patch 0289 (2026-10-26, built into `out/ios16-gl2`, not booted) makes the IOSurface lock trap wait
  for the surface's `gpuFence` (up to `negronisurf_gpuwait` ms, default 50; a stopped GPU is not waited for) and drop
  the cached lines of a cached mapping, once per fence value. RedwoodGPU then publishes `RedwoodWaitsForGPU = true`.
  `view.c` reads that property once per process (`ngl_drm_kernel_waits_for_gpu`): a kernel without it (older than
  0289) gets `glFinish` on every flush, logged as `negronigl: flush = glFinish (the kernel has no RedwoodWaitsForGPU
  ...)`; with it, `flush = glFlush + kernel fence (default: RedwoodWaitsForGPU)`. Build 2026-10-26 (`gl-build`, exit
  0): stripped `negronigl.dylib` 14,233,360 bytes (sha256 38af4413...), `NegroniGL` 13,777,152 (90fc522a...), `ngl_test`
  50,496 (8f7d3778..., unchanged), check-imports PASS (0 missing); the GL tree now carries `userland/turnip`'s
  `0001-turnip-darwin.patch` (stamp `turnip 0001-turnip-darwin.patch 4ea756a5`).
- `glFinish` comes back with `NEGRONIGL_FINISH=1` (environment), the file `/var/db/negronigl/finish`, or
  `NegroniGL.bundle/finish` (readable by sandboxed apps); `NEGRONIGL_FINISH=0` wins over the files.
  `scripts/gpu/phone-gl.sh finish on|off` writes both files. Use it with a kernel older than 0254. Read once per
  process; the log says `negronigl: flush = glFlush + kernel fence (default)` or `= glFinish (WHY)`.
- `glFinish` stays in `FinishObjectAPPLE`, `TestObjectAPPLE`, `FinishFenceAPPLE` (CA asks for a real wait there).

### CAEAGLLayer drawables (2026-10-26, view.c)

Sources: out/gpu/re/OpenGLES.s and QuartzCore.s (20H392 cache, unslid, `ipsw dyld disass`). Each fact names the
instruction that shows it.
- [V] `-[EAGLContext renderbufferStorage:fromDrawable:]` 0x1d3f518f4: target GL_RENDERBUFFER (`cmp x2, x8` with
  x8 = 0x8d41, 0x1d3f51918/0x1d3f5191c); `respondsToSelector:` + `performSelector:` `nativeWindow` (0x1d3f51930..
  0x1d3f5194c) and `drawableProperties` (0x1d3f5195c..0x1d3f51978); key strings `"EAGLDrawablePropertyRetained"`
  (0x1d3f51988, `eagl_dict_read_bool`), `"EAGLDrawablePropertyColorFormat"` (0x1d3f5199c, `objectForKey:`).
  Colour format by pointer compare (`cmp x0, x8`): `EAGLColorFormat8888` (0x1d3f519ac) or nil -> 0x8058,
  `EAGLColorFormat565` (0x1d3f519c4) -> 0x8d62 (0x1d3f51afc), `EAGLColorFormatS8888` (0x1d3f519d4) -> 0x8c43
  (0x1d3f51b04), `EAGLColorFormatSRGB_XR10` (0x1d3f519e4) -> 0x93f2, `EAGLColorFormatRGBA_XR10_64BPP` (0x1d3f519f4)
  -> 0x8a76, `EAGLColorFormatSRGBA_XR10_64BPP` (0x1d3f51a04) -> 0x8a77, `EAGLColorFormatSRGB_XR10_A8_2P`
  (0x1d3f51a14) -> 0x93f9 (0x1d3f51a24). Then `_gli_plugin+0x88` twice: (ctx, 0, 0, 0) at 0x1d3f51ab0, (ctx, nw,
  retained, format) at 0x1d3f51ad0; YES when the second returns nonzero. Our shim compares the strings by value.
- [V] `presentRenderbuffer:` 0x1d3f51b48 (`mov w1, #0`, `fmov d0, xzr`, `blr` at 0x1d3f51b90), `:atTime:`
  (`mov w1, #0` 0x1d3f51be8), `:afterMinimumDuration:` (`mov w1, #0x1` 0x1d3f51c44): `gliPresentViewES(ctx, 0|0|1, d0)`.
- [V] Native window table, `-[CAEAGLLayer nativeWindow]` 0x188468d68: `calloc(1, 0x108)` (0x188468e90/0x188468e94),
  `str w9, [x0]` with w9 = 5 (0x188468ecc/0x188468ed8), `stp x8, x9, [x0, #0x8]` attach/detach (0x188468eac),
  `stp x10, x8, [x0, #0x18]` begin_iosurface/swap (0x188468eec), `stp x9, x11, [x0, #0x28]` collect/begin_properties
  (0x188468ef0), `str x8, [x0, #0x38]` with x8 = native_window_estimated_size (0x188468ef8/0x188468efc).
- [V] `native_window_begin_iosurface` 0x188469a30 returns NULL (`mov x0, #0` 0x188469a94) when bit 1 of +0x84 is
  clear (`tbz w8, #0x1` 0x188469a80: not attached) or when +0xc0 is set (`ldr x8, [x20, #0xc0]` 0x188469a84,
  `cbz x8` 0x188469a88 is the only way to the allocation). [I] +0xc0 is the drawable that is out (it is stored
  at 0x188469b10 after the new buffer is made; we did not trace where swap clears it), so one surface per swap.
- [V] begin_iosurface passes `ldp w1, w2, [x20, #0xd0]` (0x188469ae8) as arguments 2 and 3 of
  `get_preflight_buffer(nw, unsigned, unsigned, unsigned, unsigned)`. [I] They are the drawable width and height
  that CA sets from the layer bounds x scale (the store was not found).
- [V] `native_window_begin_properties` also calls `get_preflight_buffer` (0x18846a204).

`view.c` does it once for both routes: the dylib's shim (eagl.c `m_rb_storage`, `m_present`, `m_present_at`,
`m_present_after`, dealloc detaches) and the bundle's `gliBindViewES`/`gliPresentViewES` (plugin/gli_view.c is now
a wrapper). Bind: detach the old window, attach(nw, 'BGRA', {ctx, create -> 1, destroy, preflight NULL}),
begin_properties, begin_iosurface, the surface becomes the bound renderbuffer's storage (surface.c,
`_mesa_EGLImageTargetRenderbufferStorageOES`). Present: `ngl_flush()`, swap(nw, mode, t) (mode 1, or 3/5 with a
time on version >= 5, as GLEngine 0x1f6f57e94), then the next `begin_iosurface` surface becomes the storage of the
same renderbuffer (the app's FBO keeps it attached). No next drawable (NULL): `view_surface` is cleared (logged once)
and the next present gets one before its swap; if it still gets none, that present returns NO without a swap.
[I] The frame drawn in between lands in the old storage, which CA now owns. All colour formats draw as BGRA 8-bit.

Test: `ngl_test --layer [WxH]` (`scripts/gpu/phone-gl.sh test --layer`) installs the shim in ngl_test, makes a
CAEAGLLayer (bounds WxH, scale 1, opaque, RGBA8, not retained), puts it into `+[CAContext localContext]`, commits,
makes an API 3 EAGLContext, `renderbufferStorage:fromDrawable:`, clears green, reads it back with `glReadPixels` and
from the drawable IOSurface on the CPU (after `glFinish`), presents, clears blue into the next drawable, presents
again. Lines: `negronigl: layer selftest: renderbuffer N = drawable IOSurface ID, WxH, framebuffer 0x8cd5`,
`negronigl: layer selftest frame 1 green: GL 00ff00ff, IOSurface ID BGRA word ff00ff00 (want ff00ff00): ok`,
`negronigl: layer selftest WxH: present 1 1, drawables IOSurface A then B: PASS`. Exit 3 = no drawable surface
[I: a shell process may give the layer no size; then the test says `NO DRAWABLE`, not FAIL]. Not run yet.

## GL driver for apps (NegroniGL.bundle, 2026-10-26)

The normal iOS driver route, for every app and framework that makes an EAGLContext (CoreImage, GLKit, games):
`-[EAGLSharegroup initWithAPI:]` -> `eagl_init` -> GLEngine `gliInitializeLibrary` -> libGFXShared
`gfxInitializeLibrary` reads `IOGLESBundleName` of the `IOAcceleratorES` service, dlopens
`/System/Library/Extensions/NegroniGL.bundle/NegroniGL`, calls `gldInitializeLibrary`; there the bundle replaces
`_gli_plugin[0]` with its own handle (`ngl_gli_register`, gli_table.c), so eagl_init binds the bundle's 18 `gli*`
entries and every `glFoo()` of OpenGLES.framework goes to Mesa (notes.md 15, 15a).

| Piece | State |
|---|---|
| Kernel `IOGLESBundleName = "NegroniGL"` on `IOAcceleratorES` | [V patch] 0205 (`negronigl=1` default; `negronigl=0` removes it). In every kernel built since 2026-10-24. No `IOGLESMetalBundleName`, so the CFPreferences `UseMetal` choice never applies |
| 129 GLD names + gldInitialize/TerminateLibrary, 18 GLI + gliTerminateLibrary | [V build] `scripts/gpu/build.sh` checks them |
| Chained fixups | [V build] 2026-10-26: the bundle was linked with LC_DYLD_INFO + lazy stubs and imported `dyld_stub_binder`, which the 20H392 cache does not export (check-imports MISSING); now `-Wl,-fixup_chains` (meson.build), check-imports PASS for the bundle too |
| The app gate | `plugin/gld.c apps_gate`, once per process, below |
| Drawables, present, fences | `view.c` (sections above) |

App gate (the NegroniMetal design: a sandboxed app can read its bundle, not /var/db):
1. `NEGRONIGL_APPS=1|0` in the environment wins.
2. `BUNDLE/off` exists, or cannot be checked (not ENOENT): closed. `/var/db/negronigl/off` exists: closed.
3. `BUNDLE/apps` (staged, lists nobody), `BUNDLE/apps.local` (the owner's), `/var/db/negronigl/apps`: `*` = all,
   `-NAME` = never; a `-NAME` in any file wins. Not listed: closed.
4. `ngl_init()` must give freedreno (softpipe only with `NEGRONIGL_ALLOW_SW=1` or `NEGRONIGL_DRIVER=softpipe`).
Closed = no `ngl_gli_register`: GLEngine's table, our `gldChoosePixelFormat` refuses, EAGLContexts are nil, as
without the bundle. Log: `negronigl: NegroniGL app gate open for NAME (freedreno)` or `... closed for NAME: WHY`.
The backboardd shim gate (`/var/db/negronigl/clients`) is separate, so `phone-gl.sh on|off` and `apps on|off` are
two independent switches.

Phone (SSH up):
```sh
scripts/gpu/phone-gl.sh apps on             # bundle to /System/Library/Extensions (if it differs), apps.local = "* -backboardd"
scripts/gpu/phone-gl.sh apps on MyGame      # only these process names
scripts/gpu/phone-gl.sh apps status
scripts/gpu/phone-gl.sh apps off            # BUNDLE/off + empty apps.local: nil contexts again for apps started later
```
`root-add-negronigl.sh` (root image, `NEGRONIGL=1`) installs the bundle without a list: it stays closed until
`apps on`.

