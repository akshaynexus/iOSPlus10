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
| Local Mesa patches | `0001-negronigl-target.patch`, `0002-turnip-darwin.patch` |
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
storage via `surface.c`); CoreAnimation's private `attachImage:toCoreSurface:invertedRender:` and
`texImageIOSurface:` paths use the imported texture resource. Not run on the phone.

**No phone test has been run.** The kernel GPU service, its IOSurface import behavior, cache
coherency, fence sequence behavior, CA framebuffer rendering, and backboardd injection must still
be verified on the device. The userland build alone does not prove the GPU path works. The kernel
ABI is described in `userland/negronigl/drm/ngl_abi.h`; `docs/gpu-abi.md` is maintained by the kernel
GPU work and was not present when this userland change was prepared.

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
| `glFlush` = finish, because the display swaps without waiting for the GPU; `RedwoodWaitsForGPU` property lets the bridge skip it | HackiOS eagl.c `display_waits()`, spes 0102 | `ngl_h_Flush` does `glFinish()`; the property is not read yet (kernel plan, README-gpu-kernel.md section 13) |
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
- `negronigl: negronigl (Mesa 25.0.7, freedreno A730 / softpipe), screen FD730 (freedreno)`
- `negronigl: selftest ... : PASS`, `negronigl: surface selftest ... : PASS`
- `negronigl: preflight PASS renderer=FD730 triangle=PASS iosurface=PASS after N ms`
- `negronigl: EAGL shim installed`, then `negronigl: EAGLContext 0x... API 3 on Mesa (GLI 0x...)` (CA's
  context) and the UI on the panel. Kernel side (`make usblog`): `NEGRONI FB STAT: ... presents/s N (cpu N
  gpu N zc N)` with `gpu` or `zc` > 0, `RedwoodGPU: present N: surface ...` lines.
- Failure: `preflight FAIL`, `GL error 0x... after slot N`, `shader N compile failed`, a black or frozen
  screen (then `off` + `restart`; `restore` if backboardd does not come up at all).

Unverified [I]: nothing of this ran on the phone. Open points: ad hoc re-signed backboardd under our
AMFI (slop 0025/0035/0036 + 0221 accept ad hoc platform binaries for the Metal bundle, but a main
executable with entitlements was not tried); the 30 s synchronous preflight delays backboardd's start by
the GPU's readiness; CA's `renderbufferStorage:fromDrawable:` returns NO on Mesa contexts (not used by
the render server); `glFinish` per flush costs frames until the kernel fence waits (section 13 plan).
