# Mi A3: the compositor on Metal for iOS 26.5.2 23F84 (metal2vulkan + Turnip on the Adreno 610)

Date: 2026-11-02. Branch `t3/laurel-ios26-metal`. Owner decision: on iOS 26 the compositor runs on Metal through metal2vulkan + Turnip on the A610.
**Host results only. Nothing here ran on the phone. No pixel exists, no frame time exists.**
Marks: **[V]** measured or read here (command, file, tool output). **[I]** inference or estimate. **[U]** unknown. Donor: iPhone12,1 N104AP, A13, `graphics-featureset-class` APPLE6.

## 1. Verdict

**The route is not dead on the host. It is not proven. Speed is the open risk, not shader support.**

| Question | Answer | Mark |
|---|---|---|
| Does the stack build for 23F84 on Linux? | Yes. All 8 Mach-O files: arm64 ALL, plain chained fixups, 0 instructions newer than ARMv8.0; imports against the 23F84 cache: 0 missing | [V] section 2 |
| Do Metal.framework and QuartzCore still find a third-party plug-in? | Yes. Same path as iOS 16: `IOAcceleratorES` -> `MetalPluginName` -> `/System/Library/Extensions/<name>.bundle` -> `MetalPluginClassName` | [V] section 3 |
| Do QuartzCore's 189 functions pass the compiler chain for FD610? | Yes, except 13 tile kernels and 2 `inplace_copy_*`, which CA does not ask on this device: FD610 answers `supportsTileShaders` 0, `supportsRasterOrderGroups` 0 [V host]. Liquid Glass compiles. CA's real `fixed_frag` specializations are **not** tested on the host: section 4.1 | [V host] |
| Does the A610 have a hard limit that stops the compositor? | None found. Sampler min/max, HW multiview and GMEM are not asked for by any QuartzCore pipeline that fails | [V host], [I] for use |
| Are pictures right? | **Unknown.** iOS 16 Metal has known black layers; zeta has black backgrounds. The host cannot say | [U] |
| Is there a second stack to compare? | Yes: IOS-26-Hot's older metal2vulkan + patch series, built as `hot`, chosen by one setting, with a bench in XNUtils. The default stays ours; no number exists yet. Section 10 | [V host] |
| Is it usable? | **Expect slow but real use with live glass off**: about 15 to 30 frames a second; live glass 4 to 10; section 8. IOS-26-Hot's self-reported 52.9 fps on an A640 on 23F84 moves this up from my first estimate; it does not prove it here | [I] |

Blockers with evidence: section 4.3. The iOS 16 test option can answer the main unknown before the iOS 26 boot: section 6.

## 2. The ABI of what we inject

The 23F84 userland is arm64e-derived and lowered to plain arm64 (`scripts/ios26/lower-userland.sh`, `ios26-userland.md` section 4). Every signer and checker is a NOP or a plain branch. So the rule for our files is simple: **plain arm64, no pointer signing at all.**

| Property | Value | Check |
|---|---|---|
| CPU | thin arm64, `CPU_SUBTYPE_ARM64_ALL`; no arm64e slice | `scripts/ios26/abi-check.py` [V] |
| Fixups | `DYLD_CHAINED_PTR_64`: plain rebases and binds, no auth | same [V] |
| Instructions | ARMv8.0 + CRC + AES/SHA: no LSE, RCpc, PAC, FP16, dot product. `-mcpu=cortex-a53`, Rust `target-cpu=cortex-a53`; no outlined atomics on Darwin | `scripts/laurel/armv80-check.py` [V] |
| minos, SDK | 16.0, iPhoneOS16.5.sdk: the only SDK on this host. The binary is an old app to dyld [I]. New SPI goes through selectors and KVC, not headers | `llvm-otool -l` [V] |
| Imports | every import exists in the 23F84 cache | `scripts/metal/check-imports.py`: `check-imports: PASS (0 missing)`, 491 imports [V] |
| Code signature | ad-hoc, `ldid -S`, 4 KiB pages. The kernel must accept this (section 7) | [V] format, [U] kernel |

C++, vtables, blocks, Objective-C [I, by design; the same state as a plain arm64 app on an arm64e cache]:

- A pointer our code stores (vtable, block `invoke`, IMP, C++ `type_info` vtable) is plain. Cache code that loads it runs `blraa` -> `blr`, `autda` -> NOP, `ldraa` -> `ldr` (lowered). Cache code that stores a pointer runs `pacia` -> NOP. So both sides see plain pointers.
- Struct layouts do not change: PAC only used pointer bits.
- Our libc++ and Rust use the cache's unwinder: frames of ours have no signed return addresses, and the hint-space `autib1716` of the unwinder is a NOP on ARMv8.0.
- No Swift in our files. Rust talks C ABI only.
- `objc_msgSend` has no LSE and its restartable range is unchanged (`ios26-userland.md` 3.5). Our classes come from `objc_allocateClassPair` and plain `__objc_classlist`.
- Named risk [U]: the cache's own `_MTLDevice`, `ISA` and `objc_class` code was built with `__ptrauth` fields: they are plain only because the lowering is complete. A word the tool could not prove (699 linear PAC words, section 5 of the userland report) would fault in a process with our plug-in as in any other.

Injected Mach-O files are loaded by Metal.framework with `+[NSBundle bundleWithPath:]`, not through `DYLD_INSERT_LIBRARIES`. No wrapper of backboardd is used on iOS 26.

## 3. The Metal SPI in 23F84

Trace method [V]: `scripts/ios26/metal-trace.sh` writes resolved listings of QuartzCore, Metal, IOGPU, IOSurface, IOMobileFramebuffer (`scripts/laurel/dsc-image.py lst`, now arm64e-aware), class dumps (`ipsw class-dump`) and selector-stub lists to `out/ios26/metal-spi/` (Apple text, git-ignored).

| Step | 23F84 | iOS 16 20H392 |
|---|---|---|
| `MTLCreateSystemDefaultDevice` | `MTLDeviceArrayInitialize` -> `MTLRegisterDevices` | same |
| Service match | `-[MTLIOAccelServiceGlobalContext init]`: `IOServiceGetMatchingServices(IOServiceMatching("IOAcceleratorES"))` | same match in `MTLRegisterDevices` |
| Plug-in class | `getMetalPluginClassForService`: `MetalPluginName` -> `/System/Library/Extensions/<name>.bundle` -> `MetalPluginClassName` -> `classNamed:`, else `principalClass`; must be a subclass of `_MTLDevice` | same |
| Device | `processPendingCreateIOAccelServiceRequests`: `[[cls alloc] initWithAcceleratorPort:]`, then `MTLAddDevice` | same selector |
| `MTLAddDevice` | conforms to `MTLDevice` and `MTLDeviceSPI`; `-initLimits`, `-initFeatureQueries`, **`-initWorkarounds`** (new), `-allowLibrariesFromOtherPlatforms` under `__CFMZEnabled` | frontend already overrides the first three |
| `_MTLDevice` size | 656 bytes (zeta's figure, the class dump agrees with a larger ivar list than 528) | 528 |
| A13's own bundle | `/System/Library/Extensions/AGXMetalA13.bundle` is in the cache; we do **not** replace it: the kernel's `IOAcceleratorES` names ours, nothing loads AGX | not relevant |
| IOGPU | Not used: `IOGPUMetal*` classes live in IOGPU.framework and we subclass `_MTLDevice`. The renumbered IOGPU selectors (33 functions) do not matter. QuartzCore has one internal mention, `IOGPUDeviceSetDisplayParamsFunc`, resolved at run time | same |
| Precompiled pipelines | `new_metal_context`: `supportsDestination:`, `newBinaryArchiveWithDescriptor:error:`; off "on unsupported hardware" | new |

GPU families [V]: `new_metal_context` asks `supportsFamily:` 1001 to 1005, 1007, 1009. `layer_private_set_device` asks 1006 (Apple6) before it makes a residency set for a `CAMetalLayer`; `allocate_iosurface` asks 1007. `graphics-featureset-class` is not a string QuartzCore reads. FD610 answers [V host, `ios26-evidence/metal-fd610-answers.txt`]: Apple1, 2, 3 yes; Apple4 and up no. So **APPLE6 is not claimed to Metal**: an honest low answer. An Apple family answer keeps CA on the `lph` shaders it ships (IOS-26-Hot, iOS 16 log: a non-Apple family makes CA ask for `fixed_frag_lpf_cpf`, absent on iOS). QuartzCore does not gate glass on the family (section 4.2). [U] whether another framework reads Gestalt's APPLE6 and then assumes an Apple6 Metal device; the plug-in's RenderBox rule (family <= 2) covers the case we know.

### 3.1 The frontend patch

`userland/metal/patches/flame-ios26/0001-ios26-23f84-spi-linked-functions.patch`, applied only in the iOS 26 tree. How the list was made [V]: every selector stub of QuartzCore, RenderBox, IconRendering, CoreImage, UIKitCore, SwiftUICore, MaterialKit (`scripts/ios26/selector-gap.py`) against Metal's protocols and the frontend, per object; and every method zeta's patches add that flame lacks (45). zeta's patches do not apply to flame's tree (25 tried, 1 applied), so this is a port by hand.

| Part | Why | Evidence |
|---|---|---|
| `newComputePipelineStateWithDescriptor:error:` + 6 asynchronous forms | `_MTLDevice` answers them through its compiler object, nil here. A nil compute pipeline is an abort: "Metal failed to build compute pipeline" | [V] disassembly of `-[_MTLDevice newComputePipelineStateWithDescriptor:error:]`; zeta hm1-v1 |
| Linked functions of render stages | RenderBox custom effects, Mercury wallpaper: `NeedsInput(LinkedFunction)` | zeta black wallpaper diagnosis; bridge + frontend |
| `setResponsibleProcess:`, `setResponsibleTaskIDs:count:`, residency set calls, `allocatedSize`, view descriptor, ranged texture copy, queue priorities | sent by QuartzCore or RenderBox; missing | [V] gap; zeta |
| `featureProfile`, `minimumTextureBufferAlignmentForPixelFormat:` | CoreImage, IconRendering abort without them | [V] gap; zeta |
| `newSharedEventWithMachPort:` | `discover_shared_event`: the base class would make an Apple event. Local event; waits on it are skipped (a client presents after its GPU work) | [V] caller, [I] that skipping is safe |
| Answers of "no": function tables, binary functions, imageblocks | The callers handle nil [I]; a `missing` line names any that does not | |
| **From IOS-26-Hot d249939 (MIT), each reported on 23F84:** `bitCodeHash`, `baseFunctionHash`, `libraryId` as real SHA-256 bytes | CoreImage and IconServices read 32 bytes through the pointer. My first patch answered nil: that was a guess, and wrong | Hot HANDOFF "Liquid Glass icon rendering" |
| `NBResidencySet`, `newResidencySetWithDescriptor:error:` | `_MTLDevice`'s form makes Apple's class. My first patch relied on it: guess removed | Hot frontend |
| Refusing encoder instead of nil | A nil encoder is an exception in the caller. Also in AdrenoMetal and hakios-dada (their Mac test: later calls do not crash, the command buffer ends with an error) | Hot, zeta ce5e19e3, dada 0202 |
| `newLibraryWithStitchedDescriptor*`, `newDynamicLibrary*` refused with an error | `_MTLDevice` schedules `MTLCompilerStitchingRequest`, which aborts in `-[NBFunction libraryData]` (iconservicesagent). `libraryData` stays out on purpose | Hot HANDOFF |
| Queue, command buffer, render encoder SPI with plain answers | sent on 23F84 | Hot frontend |

Not ported: zeta's move of every object onto Apple's private bases (`_MTLCommandBuffer` and others). IOS-26-Hot keeps plain `NBObject` classes and reports Home and Settings on 23F84, so this choice is no longer a guess of mine. If a framework sends another base-class selector, the frontend's `doesNotRecognizeSelector:` writes one `MISSING` line before it raises.

Result [V]: QuartzCore has **no object-level gap**. Left for other images, all optional paths: logged in `out/ios26/metal/selector-gap.txt`.

### 3.2 Build

```sh
scripts/bg.sh ios26-metal scripts/laurel/ios26-metal-build.sh all     # out/ios26/metal, out/ios26/gpu
```

It runs the steps of `metal-build.sh` with `METAL_OUT`, `GPU_OUT`, `METAL_EXTRA_FLAME`, `METAL_EXPORTS_CACHE`, `IOS_DSC`, `NMTL_EXTRA_FLAGS=-DNMTL_IOS26=1`. Unset, these change nothing (section 6.5).

## 4. What the compositor needs, and what the A610 gives

Full table, one row per function, with ir3's numbers: [ios26-evidence/metal-pipelines.tsv](ios26-evidence/metal-pipelines.tsv). Formats: [metal-formats.tsv](ios26-evidence/metal-formats.tsv). Device caps: [metal-fd610-vulkan.txt](ios26-evidence/metal-fd610-vulkan.txt), [metal-fd610-answers.txt](ios26-evidence/metal-fd610-answers.txt).

Method [V]: real Mesa 25.0.7 Turnip, same patched tree as the phone, built for Linux with Mesa's `drm-shim` and `FD_GPU_ID=610` (`scripts/ios26/turnip-host.sh`), the real metal2vulkan runtime + bridge (`userland/laurel/metal/tests/ca-pipelines.c`), one process per pipeline (`scripts/ios26/ir3-check.sh`). `vulkaninfo` on the same stack reports `Turnip Adreno (TM) 610`, API 1.3.305 with `TU_DEBUG=noconform` (0102's answer). A row marked "made" passed AIR -> SPIR-V -> NIR -> ir3 -> A610 code. **It does not say the pixels are right.** Vertex layouts for CA rows are CA's own table (`vertex_layout_info`, QuartzCore 0x184246d10: buffer 1, stride 48: float4@0, float2@16, float2@24, half4@32). Other rows use stand-in constants (zero).

| Group | Functions | Translate (m2v) | ir3 FD610 | Verdict |
|---|---|---|---|---|
| Vertex | 37 | 37 | compiled with their fragments | supported (host) |
| Fragment | 128 | 126 | 126 made | supported (host); 2 left below |
| Kernels | 24 | 24 | 11 made; 13 `tile_*` need tile attachments | 11 supported; 13 not used |
| `fixed_frag_lph_cph`, `_cpf`, generic (`fc_generic=1`) | 2 | pass | made, with and without `fc_framebuffer_fetch` | **63,688 instructions in the binary**, const 504 vec4, register limit reached; 4.6 s to compile on this host |

### 4.1 The two open shader items, with the new references

- **`inplace_copy_lpf`, `_lph`:** closed. They need raster order groups (pixel interlock), and Turnip FD610 has none. CA reads `supportsRasterOrderGroups` once and sets bit 0x800 of its limits [V QuartzCore `new_metal_context`]. FD610 answers 0 [V host]. So CA does not take that path [I, from the gate]. No reference needs them either.
- **Specialized `fixed_frag`:** **not tested on the host; I cannot make real keys here.** My grid of guessed `fc_*` values gave 1 to 5 instructions (no output or a flat color), so it proves nothing, and it is out of the plan. IOS-26-Hot's only figures are older: about 40 specializations in a home screen, and an icon pipeline of 59 instructions on iOS 16 [their log]. The first boot's `pipelines.log` gives the real keys; the harness then takes them as a plan. Until then the number that matters is unknown [U].

### 4.2 Liquid Glass and backdrop filters

CA draws glass on the server: `CA::OGL::GlassBackgroundFilter::render`, `GlassForegroundFilter::render`. `can_render` only checks a flag in `Gstate`, not the device or family [V]. So every iPhone gets the same glass, and so would this phone.

| Shader (FD610, largest variant) | Instructions | Texture ops | Registers (limit 48) | Fit |
|---|---:|---:|---:|---|
| `glass_background_sdf_lph` | 1,703 | 9 | 48 | compiles; very heavy per pixel |
| `glass_background_lph` | 837 | 11 | 24 | compiles; heavy |
| `glass_foreground_sdf_lph` | 686 | 11 | 48 | compiles; heavy |
| `narrow_blur_27_frag_lph` | 150 | 14 | 24 | fine per pass; many passes |
| `variable_blur_frag_lph` | 147 | 6 | 24 | fine per pass |
| `simple_rim_lph` | 6,066 | 261 | 12 | compiles; do not expect speed |
| median of all fragments | 91 | | | |

Consequence: **live glass is the cost to remove.** IOS-26-Hot's selective `CABackdropLayer` bypass does that, keeps pre-baked icons and pills, and is not Reduce Transparency. It reports 400 to 500 MB less transient memory on 1080x2400. In the iOS 26 plug-in now, on by default in backboardd and SpringBoard: line `LAUREL GLASS: on: ...`; file `/private/var/db/negronimetal/live-glass` brings live glass back within 5 s. Limit [I]: it goes in at this process's device open, not at exec, because we have no exec injection.

### 4.3 Blockers

| # | Item | Evidence | State |
|---|---|---|---|
| B1 | Compile time of the generic shader on this CPU, if CA asks for it | 4.6 s on a 12900H core [V]. iOS 16 phone: 6 pipelines in 1052 ms [V gpu.md]. So about 15 to 40 s [I] | A wait, not a stop. Persistent cache keeps it to the first boot. Whether CA asks it is [U]: the IOS-26-Hot and flame logs say pipelines were made at draw time and no generic was asked in their run |
| B2 | 32 of 258 metallibs have no AIR (AGX code only) | [V `metal-libs.tsv`]: AGXMetalA13's own, `MetalFilter.bundle`, `WeatherUI`, `PhotosUIPrivate`, `AV1SW`, the camera processors | Not the compositor. **Camera filters and Weather effects cannot run on Metal here.** They need a CPU path or fail |
| B3 | Unimplemented in the translator | [V `metal-corpus-all.txt`, 13,588 of 15,076]: ray tracing 519, MPS CNN sampler lowering 177, `air.global_bindings` 7 Mercury fragments, a few tessellation | Not the compositor. Mercury's custom effects are partly affected |
| B4 | Picture correctness | iOS 16 black layers; zeta black backgrounds. IOS-26-Hot reports correct Home and Settings on 23F84 with 720ef1ce + its patches, which differs from our 219f013 | **Open [U]**: section 10 |
| B5 | Kernel | section 7 | The kernel track |

### 4.4 Formats

[V] 8-bit, 16-bit float, 10-bit formats of CA's `image_parameters` sample, filter, blend and render on FD610. 4:2:2 video formats sample over linear memory only, which is what an IOSurface is. `BGR10_XR` has no Vulkan format: metal2vulkan emulates it; backboardd answers `supportsExtendedXR10Formats` NO, so its framebuffer stays `BGRA` (0x42475241, read in `framebuffer_pixel_format`). The other path there is `b38a` (universal compression): `CADeviceUseFramebufferCompression` must answer no. See section 5.

Compared with `a6xx_gen1_low`'s known limits [V]: no sampler min/max: no failing row names it. No HW multiview: CA does not use it. GMEM 132 KiB: 36 tiles for the screen [I gpu.md], no compile effect. `reg_size_vec4 48`: reached in the SDF glass and generic shaders; ir3 still makes them (no failure row).

## 5. Present path on 23F84

```
SpringBoard etc: CA commit -> backboardd render server
backboardd: CA::WindowServer::AccelServer::renderer -> CAMetalContextCreate -> new_metal_context
  IOMFBDisplay: allocate_buffer -> IOSurface ("CAWindowServerSurface"), format from framebuffer_pixel_format
  MetalContext::get_surface: MTLTextureDescriptor (framebufferOnly, rotation, usage) + newTextureWithDescriptor:iosurface:plane:   -> "com.apple.coreanimation.framebuffer-surface"
  MetalContext::flush: commit, then waitUntilScheduled (or commitAndWaitUntilSubmitted)
  IOMFBDisplay::finish_update: swap_wait, swap_begin, swap_set_layer -> _IOMobileFramebufferSwapSetLayer, _IOMobileFramebufferSwapEnd
  kern_SwapEnd: IOConnectCallStructMethod selector 5, 0x588 = 1416 bytes [V]
kernel stand-in: takes the surface, shows it
```

[V] from `QuartzCore.lst`, `IOMobileFramebuffer.lst`. `IOMFBDisplay::get_ctx` makes one more Metal context, for copies, in a `dispatch_once`.

**metal2vulkan's Vulkan WSI does nothing here.** No bridge or frontend file uses a swapchain [V: 0 matches]. Turnip has no surface path on iOS (`-Dplatforms=`), though its extension table still names it. The compositor renders into IOSurfaces, and `presentDrawable:` of a client calls `-[CAMetalDrawable present]` after the GPU work. No `vkQueuePresentKHR` exists in the path.

**Sync.** Apple's display waits on a surface's GPU work; ours shows it at once. So in backboardd the plug-in sets `NEGRONIMETAL_SYNC=1` (iOS 26, and the iOS 16 test option): `waitUntilScheduled` waits for completion. That costs one CPU stall per frame, and keeps half-drawn frames off the panel. The kernel's `topaz_surface_drawn` covers a surface named in a submission. Not more than one of these two should stay after the first numbers [U which].

**Zero copy.** On this kernel backboardd's screen surfaces come from the GPU pool and the MDP scans them directly: the patch key is the process name `backboardd` at `RedwoodGPU` open (2150), not GL [V], so Turnip in backboardd takes the same path. zeta and AdrenoMetal copy each frame with the GPU, and IOS-26-Hot blits it to fit the panel (`gpu_direct`, its panel has another size). Ours needs neither at 720x1560 **if the mode and the donor's scale agree** [U: root track; iPhone 11 is 828x1792 at 2x].

Framebuffer compression: Hot found that a first boot must already have it off: env `CA_DISABLE_FRAMEBUFFER_COMPRESSION=1` before `main()` and `CAEnable*=false` in the preference files, because CA reads them once. My plug-in sets them at the device open, which can be late [I]. So `root-add-metal-ios26.sh` also writes the preference files (section 7 has the launchd env part).

## 6. The iOS 16 test option: backboardd on Metal

**Purpose:** learn if the A610 can composite on Metal before the iOS 26 boot. **Never the default.** Default builds compile none of it (`#ifdef LAUREL_BBD_METAL`), and `root.sh` runs it only with `METAL_BACKBOARDD=1`.

```sh
scripts/bg.sh bbd-metal scripts/laurel/ios16-bbd-metal-build.sh     # out/metal-bbd: plug-in, wrapper. Uses the default bridge and Turnip
METAL_BACKBOARDD=1 sudo scripts/laurel/root.sh ...                  # or scripts/laurel/root-add-bbd-metal.sh MOUNTED_ROOT
```

No kernel change [V source]: `topaz_gpu_gl_opened` keys on the process name, so surfaces, watchdog and scanout follow Turnip in backboardd. This replaces item 4 of `metal.md` 6.5.

### 6.1 Why a failure does not end in black

iOS 16's `EAGLServer::renderer` [V 20H392]: `CAMetalContextCreate`, then `new_metal_context` if a device came; else `EAGLContext initWithAPI:` + `GLESContext`. The loader stays inserted by the wrapper in both cases. This answers `metal.md` 6.5 "which one CA takes": Metal first, GL when the device is nil.

| Failure | What happens | Next start |
|---|---|---|
| No flag file, gate not `pass`, or a mark of this boot | Plug-in gives nil at once | GL, same process, no restart |
| Device open fails, or self-test fails or hangs (20 s) | nil | GL, same process |
| Crash (abort "Metal failed to ...", Turnip, ir3) | launchd restarts; the wrapper sees a fast exit with Metal on, writes `strikes/backboardd-metal-off` and sets its counter to 0 | GL. The crash guard then counts from 0, so a failed test ends on GL, not on the software renderer |
| No frame on a screen surface in 240 s | plug-in: mark, `_exit(0)` | GL |
| Screen surface all black for 30 s after a frame (64 samples) | plug-in: mark, `_exit(0)` | GL |
| GPU lost (no completion for 60 s with work pending) | watchdog: mark, `_exit(0)` | GL, or software if the kernel turned the GPU off |
| Kernel watchdog (2155) | as today: `kern.laurel_gpu` off | Software renderer, as today |

The mark holds the boot session and a count: a new boot tries again; 3 boots with a failure end the test until `rm /private/var/db/negronimetal/strikes/backboardd-metal-off`. Undo with no new root: `rm /private/var/db/negronimetal/backboardd-metal`. A truly black wallpaper with nothing lit would read as a failure and take GL: a safe error [I].

Worst visible case [I]: up to about 4.5 minutes of a black or frozen screen in one start (240 s + restart), then GL. The USB log and SSH stay up during it.

### 6.2 The lines we read

Boot 1 (gate has no pass yet): `LAUREL BBD METAL: off: the Metal gate has not passed on this build (state new): ...: no Metal device, CoreAnimation takes GL`, then `LAUREL METAL CLIENTS: on: ...`. Boot 2:

```
NMTL[.. backboardd]: LAUREL BBD METAL: on: backboardd takes a Metal device; GL stays the fallback (...)
NMTL[.. backboardd]: device Turnip Adreno (TM) 610 in N ms, of which M ms loading Turnip
NMTL[.. backboardd]: pipelines N compiled in T ms, ... at the first completed frame, S ms after the device opened
NMTL[.. backboardd]: LAUREL BBD METAL: first frame on a screen surface (720 x 1560, format 0x42475241) S s after the device opened
NMTL[.. backboardd]: LAUREL BBD METAL: screen: L of 64 samples lit, ...
NMTL[.. backboardd]: LAUREL BBD METAL: on: 5 min without a failure: this start stays on Metal
SWEET FPS: ... (the kernel's line: frames, present + latch)
```

Read: pass = no `off:`, L > 0, owner sees the UI. `refused`, `MISSING` and `command buffer refused` lines name the first fix. Failure: `LAUREL BBD METAL: off: <reason>: GL from the next start (boot N of 3 with a failure)`, `LAUREL BBD: metal: off: ...`, `CRASH backboardd`.

What this test can learn: compositor pipelines on the real ir3 and GPU, frame time, black layers on CA's own draws. What it cannot: iOS 26's shaders, 23F84 SPI, glass.

### 6.3 Default build unchanged

`scripts/laurel/ios16-compat-run.sh BASE` builds the base and the head in this worktree, same paths, and compares raw and normalized (`macho-norm.py`) hashes. It now includes the default XNUtils. Result [V `logs/ios16-compat.log`, base 3d0be2f, head f1383db, which has the selector, bench and plug-in changes]:

```
ios16-compat: 20 same bytes, 0 with a byte difference
```

All 20: the default NegroniMetal and m2vtest, Turnip, the bridge `.a`, the probes, the list files, XNUtils.app, powermenu-helper, pmregister. NegroniMetal sha256 `ffe957362cffc0a4...` in both. Base and head are two real builds: the files have times 03:31:19 and 03:33:54.

An earlier run (base 037cd81, head 87e778d) gave `12 same bytes, 3 with a byte difference`, where NegroniMetal and m2vtest were `same code (differs in UUID and signature only)`. Today's run does not have that difference. Later commits after f1383db change only iOS 26 scripts (the `ios26-*`, `root-add-metal-ios26.sh` and the root spec), which the default iOS 16 build does not read.

## 7. Kernel needs (for the xnu-12377 track, branch `t3/laurel-ios26-needs`). No kernel patch here

| # | Need | Why | Evidence |
|---|---|---|---|
| K1 | Publish `IOAcceleratorES` with `MetalPluginName = NegroniMetal`, `MetalPluginClassName = NegroniMTLDevice` (port of laurel 2850) | Metal's match and CA's 300 x 100 ms poll are unchanged | [V] section 3 |
| K2 | `RedwoodGPU` user client with the same msm ABI: 0x40-0x4c, 0x49 host pages, 0x7e surface import, 0x7d drawn; laurel 2160, 2161 | Turnip's KMD stand-in | [V] `metal.md` section 4 |
| K3 | `topaz_gpu_gl_opened` stays keyed on process name `backboardd` | Pool surfaces, direct scanout off, watchdog follow Turnip with no change | [V] 2150, 2151, 2155 |
| K4 | `IOMobileFramebuffer` SwapEnd: selector 5, 0x588 bytes, layers +0x48 | IOS-26-Hot 0141 reports the shift. Its text says "selector 4"; its code and the 23F84 binary say 5 [V] | [V] `kern_SwapEnd`; Hot [their boot] |
| K5 | `IOSurfaceRootUserClient` sizes of 23F84: bulk attachments 132 bytes (struct 0x88 -> 0xa0), lookup results larger | Hot 0142 agrees with `ios26-userland.md` section 8 | both |
| K6 | Display waits for a surface's GPU work as `topaz_surface_drawn` does, for surfaces imported by Turnip | Section 5 | [V] source |
| K7 | Sleeping fence wait: short spin, then sleep woken by `CACHE_FLUSH_TS` IRQ | Hot 0151: 50 us + 250 us sleeps. Ours polls every 200 us. Fits the A610 better than the A640: a weak CPU pays more for polling [I] | Hot |
| K8 | Vsync notification carries the refresh period | Hot 0121: CA's frame deadlines were always in the past without it | [V] ours sent the tick counter in that slot: post/9008, `gpu.md` "The 24 fps windows" |
| K9 | Ad-hoc signatures with 4 KiB pages from `/System/Library/Extensions` and `/usr/local/bin` run in a platform process | Our files are `ldid -S`; the AMFI stand-in takes every signature on the root and has no library validation hook | [V code, 12377, not run]: `ios26-first-boot.md` section 2 |
| K10 | `launchd.plist` is signed (`launchd.plist.sig`) [V]. `launchd_cache_loader` of 23F84 skips the check with `launchd_unsecure_cache=` [V disassembly], which `uefi-image.sh` sets. So a job can go in: the SSH job does. `CA_DISABLE_FRAMEBUFFER_COMPRESSION=1` in the backboardd job is possible the same way | First-boot BGRA, as Hot. Preference files are the fallback already written | [V code, not run] |
| K11 | `work_interval` instance ops 6, 7, 8 | Hot, zeta: stripped ops that CA's work intervals call | Hot 0151 |

## 8. Performance estimate. All [I]; no measured frame exists on this path

Inputs [V Mesa table, kernel, logs]:

| GPU | SP cores | Clock | Pixels | Report |
|---|---:|---|---:|---|
| A610 (ours) | 1 | 300 MHz, 600 by demand (2892, not booted) | 720 x 1560 = 1.12 M | GL on iOS 16: 32.9 fps moving, 10.5 ms in GL calls [V] |
| A640 (IOS-26-Hot) | 2 | 675 MHz | 1125 x 2499 = 2.81 M | **52.9 fps Home swipe, 39.7 fps Settings scroll, live backdrop off** [their log, not verified] |
| A660 (zeta) | 3 | 491 MHz [their table] | 2754 x 1892 = 5.21 M | **55-83 ms per present**, live glass, a full-frame GPU copy [their log] |

Rule: GPU time per frame scales with pixels / (cores x clock). This ignores memory bandwidth, GMEM and shader mix, so it is a guide.

| Against | GPU time ratio at 300 MHz | at 600 MHz | CPU time ratio |
|---|---:|---:|---:|
| A640 | 0.40 x 4.5 = **1.8** | **0.9** | **about 2 to 2.5** (A76 2.4-2.8 GHz with LSE vs A73 2.0 GHz with trampolines) |
| A660 | 0.215 x 4.9 = **1.05** | **0.53** | **about 3 to 5** (X1; `ios26-userland.md`) |

| Case | Their frame | Ours, half GPU + half CPU | fps |
|---|---|---|---:|
| Home swipe, live glass off, from A640 | 18.9 ms | 30-45 ms | **22-33** |
| Settings scroll, live glass off, from A640 | 25.2 ms | 40-60 ms | **16-25** |
| Live glass on, from A660 | 55-83 ms | 110-250 ms | **4-9** |

So **zeta's 55-83 ms is not a floor for us**: its panel has 4.6 times our pixels and it copies each frame; our screen is scanned directly. But the shares GPU vs CPU are my assumption. If their frames are CPU-bound the numbers go down by up to 2 times. Other limits: our GMEM 132 KiB means 36 tiles against about 3 to 12 on theirs [I], so tiling is expensive here: sysmem may win, and framebuffer fetch on sysmem needs a flush per overlap (`sysmem_single_prim_mode`, 25.0.7) [V code]. Glass per pixel: 549 to 1703 instructions, at 1 core and 300 MHz about 8 instructions per clock [I] gives about 60 ms for a dock-sized region.

Cold start: first frame after a new root likely 30 to 120 s [I]: 139+ pipelines at about 175 ms each on this CPU [V iOS 16: 6 in 1052 ms]. Warm: much less, through the persistent cache. Hot's prime job reports 21 pipelines in 1.4 s on an A76, warm.

Memory: Hot reports a GPU pool of 416 to 593 of 944 MB with the bypass. At 0.4 of its pixels about 170 to 240 MB [I], inside our 512 MiB pool. With live glass add its 400-500 MB x 0.4: tight.

## 9. Enable on iOS 26: entry points for the root track

| Step | Command | Result |
|---|---|---|
| Build | `scripts/bg.sh ios26-metal scripts/laurel/ios26-metal-build.sh all` | `out/ios26/metal/stage`: the default stack. Class `NegroniMTLDevice`, as kernel need K1 names it. Checks: Mesa A610 entry, imports vs 23F84, abi-check, selector gap |
| Install | **`scripts/bg.sh ios26-root scripts/laurel/ios26-root.sh`**: `ios26-root-spec.py` function `metal()` runs `root-add-metal-ios26.sh` on a stage and takes what it leaves into the image | bundle, probes, clients, env, `stack/`, CAEnable* preferences, jetsam. Audit line `applied metal26` or `off metal26`. No selector, no second stack, no XNUtils in this image |
| Host chain | `scripts/ios26/metal-corpus.sh all`, `scripts/ios26/turnip-host.sh`, `scripts/ios26/ir3-check.sh` | evidence files |

No launchd job, no wrapper. Clients: `* -chronod -cameracaptured -WidgetRenderer_Default -PosterBoard`: Hot's list on 23F84; those have CPU paths, and `_RB4` render targets remain open there. `METAL_CLIENTS=` replaces it. Lines at boot:

```
LAUREL METAL: on: Turnip a610 ...                         (kernel K1)
NMTL[.. backboardd]: device Turnip Adreno (TM) 610 in N ms ...
NMTL[.. backboardd]: LAUREL METAL26: on: Metal device Turnip Adreno (TM) 610 for the compositor
NMTL[.. backboardd]: LAUREL GLASS: on: live CABackdropLayer capture off in backboardd (...)
NMTL[.. backboardd]: LAUREL METAL26: first frame on a screen surface (720 x 1560, format 0x42475241) S s after the device opened
NMTL[.. backboardd]: LAUREL METAL26: screen: L of 64 samples lit, ...
```

Failure on iOS 26 has **no fallback**: `LAUREL METAL26: off: ...: CA::WindowServer::AccelServer::renderer has no renderer, the screen stays as it is`. The USB log stays, and SSH stays (`ios26-first-boot.md`). There is no GL on 23F84 (`ios26-userland.md` 8.1).


## 10. Second Metal option, switch and bench

**Nothing here ran on the phone. No fps number exists for either option.** The host can say what differs and what compiles. Only the bench on the phone can choose the better option.

**State 2026-11-02, owner decision: first boot first. The first-boot root has the default stack only.** The second stack, selector, XNUtils screen and bench stay in the tree, built and host-tested, and are not in that root. Nothing more is added until after the first boot. To use them later: `scripts/bg.sh ios26-metal-all scripts/laurel/ios26-metal-options.sh` (it builds its own copy of the default stack in `out/ios26/metal-impl`, class `NegroniMTLDeviceImpl`), then `METAL_STAGE=$PWD/out/ios26/metal-all/stage scripts/laurel/ios26-root.sh`. XNUtils also needs a mounted root as root: `METAL26_XNUTILS=1 sudo scripts/laurel/root-add-metal-ios26.sh MOUNTED_ROOT`, because its helper is setuid.

### 10.1 Candidates

All candidates are metal2vulkan + Turnip. None was made for an A610.

| Candidate | What is really different | License | Builds for 23F84 | Fits the A610 | Verdict |
|---|---|---|---|---|---|
| Ours (`default`): `out/ios26/metal` | metal2vulkan 219f013 (the newer one), ios-flame frontend + our `flame-ios26` patch (which takes the Hot fixes of section 3.1) | ios-flame MIT, metal2vulkan GPL-2.0-or-later OR LGPL-3.0-or-later | Yes [V host] | 141 of 154 pipelines made, FD610 [V host] | **The default** |
| IOS-26-Hot `phone/metal2` (d249939): `out/ios26/metal-hot` | **Another translator:** metal2vulkan 720ef1ce (817 commits older than ours) + 19 own patches. Its frontend, same flame lineage, written for 23F84. The only one with a reported compositor run on 23F84 on a6xx (A640, their log) | MIT, metal2vulkan as above | Yes: all 19 patches apply, links with our plug-in + `hot-ios26` [V host]. We do not use its newer Mesa or `tu_knl_darwin` | 139 of 154 made, FD610 [V host] | **The real second option: `hot`** |
| AdrenoMetal (831a9dc) | Same frontend lineage. The difference is its NativeAdreno KMD for an A740, which we cannot use: our Turnip goes through the msm stand-in on RedwoodGPU | MIT | Not tried: nothing new above the KMD | KMD: no | Not an option |
| hakios-dada `gpu2/` (f1ae906) | metal2vulkan 720ef1c (the base of Hot), or 0dfdbcd + patches; Mesa 85fda3b; A830 | MIT, APSL | Not tried | Mesa + KMD aimed at A830: no | Not an option: same translator as Hot, no A610 path |
| metal2vulkan-inferno (f9832ce, `make references`) | July snapshot of upstream, translator only, already in our submodule history. No frontend, no plug-in | LGPL-3.0-or-later | Not a stack | No | Not an option |

Tested with `scripts/ios26/ir3-check.sh` on the real compile for FD610 (`IR3_OUT` per stack), compared by `scripts/ios26/stack-compare.py`. Output: `ios26-evidence/metal-stacks-summary.txt`, per pipeline `ios26-evidence/metal-stacks.tsv` [V host]:

| Result | default | hot |
|---|---:|---:|
| Pipelines made (of 154; all 13 tile kernels refused by both) | **141** | 139 |
| Refused only by this stack | none | `simple_rim_lpf`, `simple_rim_lph`: `TexelOffset` needs `Maintenance8` |
| Fragment instructions, median of 128 | **93.5** | 194.5 |
| Vertex instructions, median of 128 | **38** | 98 |
| Fragment shaders that are smaller in this stack | 110 | 4 |
| `ca_generic_lph_cph` fragment | 63,688 | **1,057** |
| `ca_generic_lph_cpf` fragment | 55,193 | **4,570** |
| `glass_background_lph` fragment | 837 | 937 |
| `glass_background_sdf_lph` fragment | 1,703 | 2,780 |
| `asg_frag_lph` fragment | 593 | 2,276 |

What this says, and what it does not:

- [V host] The two stacks differ in a large way. So a bench between them is a real comparison, not a label.
- [V host] `hot` has about 2 times the median instructions per shader. On the 4 `ca_generic` fragment shaders `default` has 12 to 60 times the instructions of `hot`. Those are the 4 that `hot` wins.
- [U] Which one wins on the phone. A static instruction count is not frame time. `ca_generic` uses function constants, and CA's real keys are not known on the host (section 4.1). If CA uses a key near my test key, `default` pays very much. If not, `hot` pays about 2 times on most layers. Cause of the difference on `ca_generic`: not found.
- [I] Why `default` stays the default: it makes more pipelines, it has fewer instructions on 110 of 128, and it is the translator of the iOS 16 build. Against it: `hot` has a reported compositor run on a6xx on 23F84, and `default` has none. If `hot` wins the bench, change one word in the selector: `NMTL_OPTION_DEFAULT`, and swap the folder names in `ios26-metal-options.sh`.
- [I] `simple_rim_*` is a Liquid Glass shader. With the bypass on (the default) CA should not ask it. With live glass on `hot`, expect a missing pipeline there.

### 10.2 The setting and the selector

| Item | Where |
|---|---|
| Bundle | `NegroniMetal.bundle/NegroniMetal` = the selector (`userland/laurel/metal/option/option_select.m`), class `NegroniMTLDevice`; the stacks are `options/default/NegroniMetal` and `options/hot/NegroniMetal`, class `NegroniMTLDeviceImpl`; Turnip is shared |
| Setting | `/private/var/db/negronimetal/option`, first word: `default` or `hot`. A sandboxed process reads `BUNDLE/option.local`. Read once, at the device open |
| State | `/private/var/db/negronimetal/stack/{state,ok,failed,active}` |
| Build | `scripts/bg.sh ios26-metal-all scripts/laurel/ios26-metal-options.sh`, output `out/ios26/metal-all/stage` + `out/ios26/xnutils/root` |
| Install | Not in the first-boot root. `METAL_STAGE` selects that stage (start of this section) |
| Rule, host test | `option_rule.h`, `present_stats.h`; `scripts/laurel/option-rule-test.sh` |

The two stacks are separate images because their Objective-C classes have the same names. One process never loads both. **So a change needs a process restart.** For the compositor: Restart UI, which XNUtils offers at each change. Without it, the old stack stays until the next start. A change causes no restart by itself.

A bad or missing setting is the default.

### 10.3 Failure goes back to the default

Only backboardd counts. Its lines:

```
NMTL[.. backboardd]: LAUREL METAL: on: stack hot (setting hot)
NMTL[.. backboardd]: LAUREL METAL26: on: stack hot: the screen is lit 60 s after the first frame
NMTL[.. backboardd]: LAUREL METAL: off: option hot failed in 2 starts of the compositor: stack default
NMTL[.. backboardd]: LAUREL METAL: off: stack hot: no frame in 240 s: restart on stack default
NMTL[.. backboardd]: LAUREL METAL: off: stack hot: the screen surface stayed black for 30 s after a frame: restart on stack default
NMTL[.. backboardd]: LAUREL METAL: off: stack hot gave no device: restart on stack default
NMTL[.. backboardd]: LAUREL METAL: off: option hot does not load: <dyld text>: stack default
NMTL[.. backboardd]: LAUREL METAL: off: option junk is not in this bundle: stack default
```

| Event | What happens | Time to the default |
|---|---|---|
| Setting missing, bad, or no such option | The default | At this start |
| The image of the option does not load | The default, in this process: nothing of the other stack came in | At this start |
| The option gives no device | `failed` mark, `_exit(0)`; launchd starts backboardd | Next start |
| No frame on a screen surface in 240 s; or black for 30 s after a frame | `failed` mark, `_exit(0)` | 240 s or 30 s, plus one start |
| Crash, a hang that the watchdog kills, or Restart UI before 60 s of lit screen | The next start counts one failure. **Two** failures: the default | Two starts |
| Lit for 60 s | `ok` mark: the count goes to 0. The screen check of this start ends, so a later display sleep is no failure | - |

The state stays until the setting is written again, so a loop cannot come back to the option by itself. To retry: choose the option again. XNUtils clears the counts.

**If the default itself fails, there is no other path:** 23F84 has no GL (section 9). The selector cannot help there. This is not "never black" for the whole route. It is "an option never makes it worse than the default".

Limits [I]:

- Two Restart UI within 60 s of a start each count as a failure of a good option. The bench screen shows the reason, and a new choice clears it.
- A sandboxed client cannot read the state. So when the compositor is back on the default, an app can still take the option through `option.local`. The app has its own strikes and does not affect the compositor.
- On a read-only system volume `option.local` stays as it was. The helper prints `OPTION_LOCAL=not written`.
- The lit check samples 64 pixels. A fully black start screen looks like a failure and goes to the default.

### 10.4 XNUtils

Build with `XNUTILS_IOS26=1` (`out/ios26/xnutils`). The default iOS 16 build has none of this: every part is under `XT_IOS26`.

Switches section -> **Metal options and bench** (`userland/laurel/xnutils/bench.m`):

| Row | Helper verb | Applies | Choices |
|---|---|---|---|
| Metal stack (shows the setting, what backboardd runs, and why) | `metaloption` | After Restart UI | `default`, `hot` |
| Turnip mode: the `TU_DEBUG` line of the env file; both flags exist in Mesa 25.0.7 `tu_util.cc` [V] | `tumode` | After Restart UI; only processes that can read `/var/db` | `auto`, `sysmem`, `gmem` |
| Glass: the bypass of section 4.2 | `liveglass` | Within 5 s | `off`, `on` |
| Restart UI | `restart-ui` | - | - |

Host test: `scripts/laurel/xnutils-test.sh`, the verbs on a folder as uid 0 of a user namespace.

### 10.5 Bench

**Run the bench**: 2 s warm-up, 12 s measured. One fixed scene: a gradient, 60 translucent cards moved by a fixed function of time, one blur bar. The app does not link Metal.

| Number | Source | Means |
|---|---|---|
| `client_fps`, `client_p50/p95/max_ms` | `CADisplayLink` intervals in the app | How well the app gets its callbacks. **It can stay high while the compositor is slow**, so it is not the main number |
| `present_fps`, `present_p50/p95/max_ms`, `presents` | backboardd: each command buffer that wrote a screen-size surface, ms from commit to GPU completion (frontend patches `0002`, both stacks; `NegroniMetal.mm` `bench_serve`) | **The main number** to compare |

Each run appends one tab-separated line to `Documents/xnutils-bench.tsv`: date, stack, setting, Turnip, glass, scene, then the numbers. The screen lists the runs, newest first. A tap copies all. If backboardd does not answer in 3 s, the present fields are `-`, never a made-up value.

Limits [I]: a frame that CA draws in more than one screen-size command buffer counts more than once, so compare `present_fps` between runs of this bench, not with other reports. Histogram bins are 1 ms; the last bin holds 127 ms and more. There is no panel number: `FPS (panel swaps)` in the report needs a kernel line that the iOS 26 kernel track does not promise. The compositor pays one `access()` each 500 ms, always.

To compare: `default` + bypass, then `hot` + bypass, then each + `sysmem`; each after Restart UI and 60 s of idle. Keep the option with the higher `present_fps` and the lower p95.

### 10.6 The tricks of the references, for the A610 (`a6xx_gen1_low`, 1 SP, GMEM 132 KiB)

| Trick (source) | Fits the A610? | State here |
|---|---|---|
| Selective `CABackdropLayer` bypass (Hot) | **Yes, more than on the A640:** GPU time per frame is about 1.8 times at 300 MHz [I section 8], so each capture pass costs more | Ported, on by default, off with `live-glass` (section 4.2) |
| Refusal of `MTLStitchedLibraryDescriptor` and dynamic libraries (Hot) | Yes: frontend matter, no GPU part | Ported (section 3.1) |
| Function and library SHA-256 hashes, `NBResidencySet`, refusing encoders (Hot) | Yes: frontend matter | Ported (section 3.1) |
| `SwapEnd` selector 5, 0x588 bytes; `IOSurface` sizes (Hot 0141, 0142) | Yes, same 23F84 | Kernel needs K4, K5; checked against the binary [V] |
| Fence sleep: 50 us spin + 250 us sleeps (Hot 0151) | Yes, and more useful: a weak CPU pays more for polling [I] | Kernel need K7, not done here: the kernel track owns it |
| Shader priming at boot (Hot) | With care: their 21 pipelines in 1.4 s were on an A76, warm. Ours are about 175 ms each cold [V iOS 16: 6 in 1052 ms], about 25 s for 139+ | Not ported. It needs a launchd job, and launchd.plist is signed (section 9). The persistent cache gives most of the gain after the first boot [I] |
| Texture pool (Hot) | Unknown: it trades memory for speed, and our pool is 512 MiB | Not ported. Add it only if the bench shows allocation cost |
| `nocb` debug flag (Hot) | Not in Mesa 25.0.7 [V] | Not usable |
| `TU_FETCH_GMEM_MIN_DRAWS` (Hot) | Not in Mesa 25.0.7 [V] | Not usable. `tumode sysmem` and `gmem` are the real switches here |
