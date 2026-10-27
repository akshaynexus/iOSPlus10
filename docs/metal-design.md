# Metal on the Adreno 730: design (iOS 16.7.16 20H392)

Status 2026-10-25. Plan, stages and risks: [metal-plan.md](metal-plan.md). Evidence marks: **[V]** seen in a binary,
source or log; **[I]** inference. Sources name the file and the commit.

## 1. Architecture

```
app / QuartzCore (backboardd, SpringBoard, ...)
  Metal.framework (Apple, in the shared cache)
    _MTLRegisterDevices: IOServiceMatching("IOAcceleratorES") -> MetalPluginName -> bundle -> MetalPluginClassName
    MTLAddDevice: conformsToProtocol MTLDevice + MTLDeviceSPI, -initLimits, -initFeatureQueries
  NegroniMetal.bundle  (/System/Library/Extensions; ours: userland/metal/plugin/NegroniMetal.mm)
    NegroniMTLDevice : _MTLDevice   gate (clients file, off switch, dead-man) -> returns the frontend's device
    NativeBridgeMetalFrontend.mm   (UniXNU NativeMetal, MIT; iOS 16 fixes by ios-flame 745c434, MIT)
      a runtime subclass of _MTLDevice + own NSObject classes for queue, command buffer, encoders, textures, ...
    libnative_metal_bridge.a       (UniXNU bridge, MIT, C ABI nmb_*)
      metal2vulkan-runtime + metal2vulkan (Rust, GPL-2.0-or-later OR LGPL-3.0-or-later, f6a96b7d + 6 rebased flame patches + 3 ours)
        AIR (metallib LLVM bitcode) -> SPIR-V; Metal object model on Vulkan 1.2+
    libvulkan_freedreno.dylib      (Turnip, Mesa; from the GPU user-space build)
      SPIR-V -> NIR -> ir3 -> A730 code; command streams; KMD backend
  kernel: GPU user client (RedwoodGPU / NegroniGPU, docs/gpu-abi.md) -> A730 (GMU, CP, SMMU)
  display: CA renders into IOSurfaces; the kernel IOMFB stand-in presents them (unchanged)
```

This is the stack that already drew the iOS 16.7.16 **20H392** home screen on a Pixel 4 (Adreno 640) on
2026-10-22: ios-flame HANDOFF.md "Metal at user quality, step 2" [V, their screenshot and log]. UniXNU drew
the iPadOS 17.7.11 UI with it on an Adreno 740 (UniXNU-ios26 68c5134 docs/drivers/native-adreno.md:73-94) [V].
We do not write a new Metal driver: we port that stack to the A730 and to our kernel ABI.

### Why this route

| Route | Status elsewhere | Verdict |
|---|---|---|
| metal2vulkan + Turnip (this design) | iOS 16.7.16 home screen + apps (flame, A640); iPadOS 17 UI (UniXNU, A740) | chosen: owner's priority, full Metal API, on-device shader compiles, Turnip does tiling/UBWC/LRZ |
| AIR -> NIR -> ir3 + own Metal runtime on gallium (hackios `air_to_nir`, bergamota libbgair) | 321/456 iOS 16.5 modules compile; compute/render probes pass; no Metal device for CA yet | fallback shader front end (MIT) for shaders metal2vulkan refuses; no runtime |
| Host-made pipeline templates (flame SweetMetal v1) | CA drew, apps did not | rejected by flame itself (METAL-NEXT.md section TL;DR) |
| No Metal, GL for CA (negronigl, sailfish) | works on iOS 16 | parallel track (GPU user-space agent); stays the default for backboardd until stage 4 passes |

## 2. How Metal.framework finds the driver (iOS 16.7.16 20H392) [V]

From the 20H392 shared cache (`scripts/metal/spi-dump.sh`, ipsw 3.1.739, disassembly in `out/metal/spi/`):

1. `MTLCreateSystemDefaultDevice` (Metal 0x181a37760) runs `MTLDeviceArrayInitialize` once, then returns
   element 0 of the device array (`"MTLCreateSystemDefaultDevice doesn't know what to do with more than one device"`).
2. `MTLRegisterDevices` (0x181b144c8): `IOServiceGetMatchingServices(IOServiceMatching("IOAcceleratorES"))`;
   for each service: `getMetalPluginClassForService`, `[[cls alloc] initWithAcceleratorPort:service]`,
   **skip on nil** (`cbz x0` at 0x181b14584), else `MTLAddDevice(device)`.
3. `getMetalPluginClassForService` (0x181a3c7c8): CFString property `MetalPluginName` ->
   `+[NSBundle bundleWithPath:@"/System/Library/Extensions/<name>.bundle"]` -> CFString property
   `MetalPluginClassName` -> `classNamed:`, else `principalClass` -> **must be a subclass of `_MTLDevice`**
   (`isSubclassOfClass:`, else nil).
4. `MTLAddDevice` (0x181a1b368, exported): asserts `_deviceArray != NULL`,
   `conformsToProtocol:@protocol(MTLDevice)` and `@protocol(MTLDeviceSPI)`; calls `-initLimits`,
   `-initFeatureQueries`, `-allowLibrariesFromOtherPlatforms`; adds `-_deviceWrapper` to the array.
5. Apple's own plugin: `AGXMetalA11.bundle` (227.6.5), `NSPrincipalClass = AGXPrincipalDevice : NSObject`
   (a dead end on purpose; the AGX kernel sets `MetalPluginClassName`, bergamota METAL_ADRENO630.md b2).
   Device chain: `AGXA11Device : AGXA11FamilyDevice : IOGPUMetalDevice : _MTLDevice`. Queues, buffers,
   encoders subclass `IOGPUMetal*` (IOGPU.framework 65.60.1), not `MTLIOAccel*`.
6. `_MTLDevice` on 20H392: instance size **0x210 = 528 bytes** (last ivar `_commandBufferErrorOptions` at 0x208),
   ~525 methods/properties (`out/metal/spi/class-_MTLDevice-re.txt`). iPadOS 17.7.11: 536 bytes (UniXNU
   NativeBridgeMetalFrontend.mm:1477-1497), so UniXNU's size assert must go (flame removed it [V]).
7. iOS 16 has **no `MTLCopyAllDevices`** (public only from the iOS 18 SDK; not in 20H392 Metal) [V].

Consequences: the kernel must publish an `IOAcceleratorES` service with `MetalPluginName = "NegroniMetal"` and
`MetalPluginClassName = "NegroniMTLDevice"`; the plugin may return nil safely. A test tool can register a device
in its own process only, without the kernel: load the bundle, init the class, call `MTLAddDevice`
(`metalprobe --bundle`, idea from bergamota METAL_ADRENO630.md i2) [V for the code path, run pending].

## 3. Shaders

| Fact | Evidence |
|---|---|
| QuartzCore's shaders are precompiled: `default.metallib`, 141 functions (39 vertex, 95 fragment, 7 kernel), MTLB 2.7, **AIR 2.5**, MSL 3.0, iOS 16.7 | `scripts/metal/metallib-info.py` on the 20H392 root [V] |
| QuartzCore loads it with `newLibraryWithURL:error:` and specialises with function constants (`setConstantValue:type:withName:`, `newFunctionWithDescriptor:error:`); it does not call `newLibraryWithSource:` | QuartzCore selector strings [V] |
| The system has 143 metallibs, 134 MTLB containers, 16,903 functions; 128 are AIR 2.5; CoreImage uses `extern` (stitchable) functions linked at run time | `out/metal/spi/metallib-summary.txt` [V] |
| Apple's on-device MSL front end exists: `MTLCompilerService.xpc`, MTLCompiler.framework 306.6.6, libGPUCompiler 31001.722, `/usr/lib/libLLVM.dylib`; the AGX back end is separate (AGXCompilerCore, AGXCompilerService-S2A8) | dsc image list [V] |
| `-[_MTLFunction bitcodeData]` gives a function's AIR; the frontend passes AIR to the bridge | Metal class dump [V]; NativeBridgeMetalFrontend.mm [V] |
| metal2vulkan reads iOS 16.7 AIR: 230 of 242 logged CA pipeline keys translate (12 = keys logged without their constants) | ios-flame HANDOFF 2026-10-22 03:40 [V their run] |
| CA's fixed_frag uber-shader uses 3-wide vector function constants (uchar3); the frontend handles them | flame HANDOFF "iOS 16 fixes" [V their fix] |
| CA tile kernels (`tile_downsample_*`, imageblocks) need emulation; CA does not use them when the device does not report tile shaders | bergamota h2 (13 tile kernels) [V their corpus]; [I] for our families answer |

Route: AIR -> metal2vulkan (SPIR-V, structured control flow) -> `vkCreateShaderModule` -> Turnip `spirv_to_nir`
-> ir3. MSL source (apps, `newLibraryWithSource:`) goes through Apple's own front end in MTLCompilerService to
AIR first [I: the frontend's `newLibraryWithSource:` path works in flame's runs of Safari/apps; to verify with
`metalprobe --compute` on our phone]. Pipeline cache: per process in `/var/db/negronimetal/cache/<proc>`.

## 4. Interfaces

### 4.1 Plugin <-> kernel (registration)

| Item | Value |
|---|---|
| Service class | a subclass of `IOAcceleratorES` (patch 0201 defines the class; the GPU driver adds its service, or 0201's stub gains the properties) |
| Properties | `MetalPluginName = "NegroniMetal"`, `MetalPluginClassName = "NegroniMTLDevice"`, optional `IOGLBundleName` (not read by Metal, flame sets it) |
| Gate | boot-arg `negronimetal=1` publishes the two properties (proposal; default 0 = today's empty stub) |
| Port | Metal passes the service; the plugin reads only its registry ID |

### 4.2 Bridge <-> Turnip (Vulkan)

The bridge `dlopen`s `NegroniMetal.bundle/libvulkan_freedreno.dylib` and needs `vkGetInstanceProcAddr` or
`vk_icdGetInstanceProcAddr` (no loader on iOS). **Vulkan requirements** (metal2vulkan 720ef1ce
`crates/metal2vulkan-runtime/src/enables.rs`, `error.rs:114`; vkprobe checks them):

| Need | Why | Turnip (Mesa 25.0.7 tu_device.cc) |
|---|---|---|
| Vulkan 1.2 + `timelineSemaphore` | runtime floor | yes |
| `VK_EXT_external_memory_host` | IOSurface-backed textures and no-copy buffers (CA renders into IOSurfaces) | **no** in 25.0.7; UniXNU's `turnip-darwin-kmd.patch` adds it over a kernel host-page import |
| `vkGetInstanceProcAddr` export | the bridge opens Turnip as its loader | `vk_icdGetInstanceProcAddr` yes; plain name from the UniXNU patch |
| no `CTR_EL0` read at EL0 | Darwin raises SIGILL (UniXNU patch, `cache_ops_aarch64.c`) | must be patched |
| no `pthread_condattr_setclock` | not on Darwin | GPU agent's 0002 patch has it |
| optional: buffer_device_address, rasterization_order_attachment_access, dynamic_rendering_local_read, custom_border_color, shader_float16_int8, 16bit_storage, extended_dynamic_state(2), robustness2, ycbcr | framebuffer fetch, `gpuAddress`, half shaders, video | yes (25.0.7) |
| release build, `-Db_ndebug=true` | debug Turnip made 58 pipelines take 68 s (UniXNU, flame METAL-NEXT 3) | build option |
| `-target arm64-apple-ios16.0`; no weak imports that iOS 16 lacks | dyld/NULL calls | `scripts/metal/check-imports.py` |

### 4.3 Turnip <-> kernel (needs from the GPU kernel agent, docs/gpu-abi.md)

Turnip's KMD backend is the GPU agents' choice (msm emulation in `userland/negronigl/drm`, or UniXNU's
`tu_knl_darwin.cc` over the NativeAdreno ABI v1). The Metal path needs these properties of the kernel, whatever
the selector table:

1. **Host-page import** (the IOSurface path): pin a user range (an IOSurface's base address, page aligned) and map it
   at a GPU VA. Without it there is no `VK_EXT_external_memory_host` and CA cannot render into its surfaces.
   (UniXNU `BoImport`; hackios/sailfish "IOSurface ID -> BO" also works if Turnip gets a matching import call.)
2. **Client-chosen GPU VAs or per-connection VA windows.** Turnip allocates VAs itself (`tu_knl_darwin`,
   msm `MSM_INFO_SET_IOVA` with `MSM_PARAM_VA_START/SIZE`); every Metal process has its own Turnip instance, so a
   shared address space must give each connection a disjoint window (flame: 4 GiB per connection).
3. **Write-combined CPU mappings that are not aliases of cacheable memory.** Our kernel has no PPL, so the
   physmap maps all managed RAM cacheable; a WC view of a managed page is a mismatched alias (lost writes,
   stale reads). Flame fixed it with a GPU pool of RAM XNU never manages [V flame HANDOFF 03:40]. Our ADT gives
   XNU 3 GiB (`--dram 840000000:C0000000`) of the 9 GiB contiguous RAM at 0x840000000, so 0x900000000-0xA80000000
   is outside XNU [V notes.md section 2]; a GPU pool there is the obvious fix [I: check Gunyah/UEFI reservations].
   Since patch 0401 (notes section 90): XNU 7 GiB (0x841004000..0xA01004000), GPU pool region 0xA20000000-0xA80000000.
4. **Submit with N IBs, fence by CACHE_FLUSH_TS, CCU invalidate at the start** (Turnip assumes msm's
   `a6xx_submit` wrapper; flame's first submits failed without it, METAL-NEXT section 4).
5. **Fence wait with a ns timeout and 0 = poll**; a busy answer when the ring is full.
6. **Device info:** chip_id 0x07030001 (FD730), GMEM size/base, UBWC version/highest_bank_bit (Mesa FD730:
   highest_bank_bit 16, 4 CCU), VA range.
7. **Coherency:** user space cleans and invalidates caches with `dc civac` (the plugin overrides
   `sys_dcache_flush`); EL0 cache maintenance must stay enabled (SCTLR_EL1.UCI) [V flame].
8. **Sandbox:** apps must be able to open the user client. Our Sandbox stand-in is permissive [I]; if not,
   name the user client `AGXDeviceUserClient` (stock profiles allow it; UniXNU NativeAdrenoPublish.cpp:10-12).

### 4.4 Plugin runtime files on the phone

| Path | Use |
|---|---|
| `/System/Library/Extensions/NegroniMetal.bundle/{NegroniMetal,Info.plist,libvulkan_freedreno.dylib}` | the plugin + Turnip |
| `/var/db/negronimetal/clients` | processes that get a device; default `metalprobe m2vtest` |
| `/var/db/negronimetal/off` | exists = no device for anyone |
| `/var/db/negronimetal/env` | KEY=VALUE for the plugin's processes (TU_DEBUG, MESA_LOG_FILE, METAL2VULKAN_*; `NEGRONIMETAL_OPEN_MS` = open + self-test deadline, default 20000; `NEGRONIMETAL_SELFTEST=0` skips the IOSurface clear self-test) |
| `/var/db/negronimetal/telemetry` | exists = backboardd writes the frontend's counters to metal.log every 10 s |
| `/var/db/negronimetal/strikes/<proc>` | dead-man counter (2 = disabled for that process) |
| `/var/db/negronimetal/cache/<proc>/` | metal2vulkan + Turnip pipeline caches |
| `/var/db/negronimetal/metal.log` | log (also /dev/console), lines `NMTL[pid name]:` |

## 5. Build

| Step | Script | Output | Status 2026-10-25 |
|---|---|---|---|
| fetch metal2vulkan 720ef1ce + flame/UniXNU bridge patches 0001-0005, 0100, 0101; export flame frontend; Rust 1.98.0 | `scripts/metal/fetch-sources.sh` | `out/metal/src/` | done [V: all 7 patches apply] |
| bridge static lib (aarch64-apple-ios, iOS 16.0) | `scripts/metal/build-bridge.sh` | `out/metal/bridge/ios/libnative_metal_bridge.a` (309 MB with debug info) | builds [V, 1 min 46 s] |
| probes + plugin + m2vtest (CMake + Ninja, `userland/metal/cmake/ios-arm64.cmake`) | `scripts/metal/build.sh` | `out/metal/stage/` | builds [V]: NegroniMetal 21 MB, m2vtest 17 MB, metalprobe, vkprobe |
| import check vs the 20H392 cache | `scripts/metal/check-imports.py DSC BIN...` | PASS/MISSING list | PASS, 0 missing [V]; negative test finds an iOS 17.4 symbol [V] |
| host shader check (metal2vulkan CLI, QuartzCore metallib, vk12-floor profile) | `scripts/metal/host-translate.sh` | `out/metal/translate/` | see metal-plan.md |
| install into a root | `METAL=1 scripts/metal/root-add-metal.sh ROOT` | bundle, probes, `/var/db/negronimetal` | written; not run on a real root yet |
| phone tests over SSH | `scripts/metal/phone-test.sh push|0|1|2|3|log` | `logs/metal-phone-*.log` | written; no phone yet |
| QuartzCore selectors vs the frontend (static) | `scripts/metal/selector-gap.py [--all] [--client NAME]` | stdout | 222 named, 0 missing after patch flame/0001 [V] |
| plugin logic on the Mac (MoltenVK as loader, host bridge) | `scripts/metal/build-bridge.sh host`, then `scripts/metal/host-plugin-test.sh` | stdout | 7 cases PASS [V] |
| estimated A730 Vulkan profile for the host check | `scripts/metal/a730-profile.py FLOOR.json OUT.json` | `out/metal/profiles/` | estimate [I] |

Linux: the same scripts with an iPhoneOS SDK copied from a Mac in `SDK=`, clang/lld, `cmake`, `ninja`,
`llvm-as`, Rust 1.98.0 with `aarch64-apple-ios`; `ldid` replaces `codesign` (build.sh falls back to it).

### Versions (change only together with `scripts/metal/env.sh`)

| Component | Pin | License |
|---|---|---|
| metal2vulkan | f6a96b7d (master, 2026-10-26; UniXNU and flame use 720ef1ce) + `userland/metal/patches/m2v-flame` (UniXNU 0001-0004 and flame 0100, 0101 rebased; 0005 is upstream) + `userland/metal/patches/m2v` 0001-0003 | GPL-2.0-or-later OR LGPL-3.0-or-later |
| frontend + bridge | ios-flame 745c434 `phone/metal2` (UniXNU NativeMetal ff0c70d, patched for iOS 16) | MIT |
| Rust | 1.98.0 | - |
| Turnip | from the GPU user-space build (Mesa 25.0.7 today; flame/UniXNU use 85fda3b3 + UniXNU patches) | MIT |

License note [I]: the bundle links metal2vulkan statically. Under LGPL-3.0 we must let users relink it: keep the
bridge sources and the build scripts available with any binary we hand out (the repo is private; ask the owner
before any public release), or move the bridge into its own dylib.

## 6. What is ours, what is reused

| File | Origin |
|---|---|
| `userland/metal/plugin/NegroniMetal.mm` | ours (design of flame `SweetMetal2.mm`: device swap, CA prefs, XR10 rule, `sys_dcache_flush`); gate, dead-man, paths new |
| `userland/metal/probes/{vkprobe.c,metalprobe.m}`, `userland/metal/tests/host-plugin-test.mm` | ours |
| `userland/metal/patches/flame/0001-negroni-surface-hook-qc-selectors.patch` | ours: IOSurface hook for Turnip's `redwood_drm_note_surface`, QuartzCore selectors the frontend lacked |
| `userland/metal/CMakeLists.txt`, `cmake/ios-arm64.cmake`, `plugin/Info.plist.in` | ours |
| `scripts/metal/*` | ours (bridge recipe from flame `tools/build-m2v-bridge.sh`, MIT) |
| frontend, bridge, m2vtest | fetched from `external/ios-flame` at 745c434 (not copied into git); our changes go in `userland/metal/patches/flame/` |
| metal2vulkan | fetched; our changes go in `userland/metal/patches/m2v/` |
