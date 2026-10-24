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

The installer has an explicit guard. Run it only on a mounted scratch or intended root:

```sh
NEGRONIGL=1 scripts/gpu/root-add-negronigl.sh /path/to/MOUNTED_ROOT
```

It installs `/usr/lib/negronigl.dylib`, `/usr/lib/libvulkan_freedreno.dylib` and
`/usr/lib/vulkan/icd.d/freedreno_icd.json`. It adds
`DYLD_INSERT_LIBRARIES=/usr/lib/negronigl.dylib` to the `com.apple.backboardd` job's
`EnvironmentVariables` entry in `System/Library/xpc/launchd.plist`, preserving any existing
inserted libraries, plist mode and owner. The disposable fake-root check is:

```sh
scripts/gpu/test-root-add-negronigl.sh
```

It passed on 2026-10-25. It checks the guard, file copies, existing environment values, idempotence,
plist mode and owner.

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
that freedreno cannot address are unsupported. `renderbufferStorage:fromDrawable:` still returns
failure; CoreAnimation's private `attachImage:toCoreSurface:invertedRender:` and
`texImageIOSurface:` paths use the imported texture resource.

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
