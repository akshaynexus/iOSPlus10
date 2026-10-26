# Metal plan: full Metal on the Adreno 730 through Turnip (iOS 16.7.16 20H392)

Owner priority (2026-10-24): full Metal acceleration, Metal translated to Vulkan on Mesa Turnip.
Architecture, interfaces and build: [metal-design.md](metal-design.md). Marks: **[V]** seen, **[I]** inference.
Status 2026-10-26: backboardd and SpringBoard ran on the GPU through this stack (150 s and 160 s without a crash,
notes.md section 16); three crash classes stay open (docs/audit/2026-10-26-metal-gl.md section 1.1).

## Answers to the key questions

### 1. How Metal.framework finds its driver

[V, 20H392 shared cache, disassembly in `out/metal/spi/`; details in metal-design.md section 2]
`IOServiceMatching("IOAcceleratorES")` -> property `MetalPluginName` -> `/System/Library/Extensions/<name>.bundle`
-> property `MetalPluginClassName` (else the principal class) -> must subclass `_MTLDevice` ->
`-initWithAcceleratorPort:` (nil is skipped) -> `MTLAddDevice` (asserts `MTLDevice` + `MTLDeviceSPI`, calls
`-initLimits`, `-initFeatureQueries`). Apple's AGXMetalA11 builds on IOGPU.framework (`IOGPUMetalDevice :
_MTLDevice`). We do not use IOGPU: our device is a runtime subclass of `_MTLDevice` with its own NSObject classes
for everything else (UniXNU/flame frontend). `_MTLDevice` is 528 bytes on 20H392.

Private SPI the plugin implements: `MTLDeviceSPI` (added with `class_addProtocol`), the four `init*` hooks,
`-initWithAcceleratorPort:`, `MTLTextureImplementation` on textures (Metal NSLogs "texture is not a
MTLTextureImplementation" otherwise, flame), `newTextureLayoutWithDescriptor:isHeapOrBufferBacked:`,
`newPipelineLibraryWithFilePath:error:` (-> nil), `supportsExtendedXR10Formats`. Full dumps:
`out/metal/spi/{Metal,AGXMetalA11,IOGPU,QuartzCore,MetalKit}.classdump.txt` and `headers/` (regenerate with
`scripts/metal/spi-dump.sh ROOT`).

### 2. Shaders

QuartzCore/backboardd use precompiled AIR (QuartzCore `default.metallib`: 141 functions, AIR 2.5) plus function
constants; apps add MSL source, which Apple's MTLCompilerService turns into AIR on the device [V for the files,
I for the run]. Route: AIR -> **metal2vulkan** -> SPIR-V -> Turnip (NIR -> ir3 -> A730). Exists: metal2vulkan
(reads iOS 16.7 AIR, flame [V]); UniXNU/flame bridge and frontend; hackios `air_to_nir` (MIT, iOS 16.5 AIR 2.5,
321/456 modules) as a fallback front end. To write: nothing for the first light; later fixes per refusal
(tile kernels, RenderBox vector constants, pointer stores), recorded per stage.

### 3. Feature coverage

| Consumer | Needs | Covered by metal2vulkan + frontend |
|---|---|---|
| CoreAnimation (backboardd) | render pipelines from `default.metallib` + function constants, blending, IOSurface-backed textures (`newTextureWithDescriptor:iosurface:plane:`), samplers, memoryless attachments, compute (blur, APL), shared events, `newBufferWithBytesNoCopy`, `newTextureLayoutWithDescriptor:isHeapOrBufferBacked:` | yes in flame's runs (home screen, Control Center, Settings) [V flame]; tile kernels not reported |
| SpringBoard, posters, widgets (RenderBox/chronod) | MRT, depth/stencil, RG16F accumulation | partly: chronod widgets white with a device in flame, kept on CPU (`-chronod`) [V flame] |
| Apps: MetalKit (`MTKView`, CAMetalLayer drawables) | drawables from CA, present | frontend has no drawable class: CAMetalLayer makes them [I]; to test |
| SpriteKit, SceneKit, games | depth, MSAA resolve, argument buffers, ICBs, heaps | runtime has them; the frontend has heaps (upstream `newHeapWithDescriptor:`) and argument buffers (flame/0011); indirect command buffers are refused cleanly (nil + one log line): the bridge has no ICB entry points (audit 2026-10-26 section 1) |
| CoreImage, Photos, MPS | stitchable functions (AIR linking), MPS kernels written for Apple GPUs | open; MPS reports failures (error mode set to NSLog) |

### 4. Stages, effort, SSH tests

Effort: one developer, after the kernel GPU user client works. Every stage has a test in
`scripts/metal/phone-test.sh STAGE` (output `logs/metal-phone-*.log`, words PASS/FAIL).

| Stage | Goal | Test (over SSH, root@192.168.7.2) | Pass condition | Depends on | Effort |
|---|---|---|---|---|---|
| host | AIR of 20H392 translates; binaries link for iOS 16 | `scripts/metal/host-translate.sh`, `scripts/metal/check-imports.py` | see "Host results" | nothing | done / ongoing |
| 0 | Turnip runs on the phone | `phone-test.sh 0`: `vkprobe` then `vkprobe --clear` | device "Turnip Adreno (TM) 730", requirements PASS, `PASS clear` | kernel user client (GEM, submit, fence, VA); Turnip build for iOS | 1-2 weeks after the kernel ABI (flame: 1 day on a working ABI) |
| 1 | Metal.framework returns our device | `phone-test.sh 1`: `metalprobe --bundle` (no kernel change), then `metalprobe` with `MetalPluginName` published | `PASS device`, name of the Turnip device, families listed | stage 0; for the second test: kernel properties on IOAcceleratorES | 2-4 days |
| 2 | command buffers, clear, IOSurface | `phone-test.sh 2` | `PASS clear`, `PASS iosurface` | host-page import (`VK_EXT_external_memory_host`) in Turnip + kernel | 1-2 weeks |
| 3 | translated shaders run | `phone-test.sh 3`: compute + render from MSL, all QuartzCore pipelines, `m2vtest` | `PASS compute`, `PASS render`, metallib kernels/fragments all built, m2vtest OK | stage 2; MTLCompilerService runs | 1-3 weeks |
| 3b | every system metallib translates on the phone | `phone-test.sh 3b`: `metallib-sweep.sh` (one `metalprobe --metallib` process per library of the 143 in the 20H392 root; table `/var/tmp/metallib-sweep.tsv`) | no `crashed` or `nodevice` lines; refusals listed per function | stage 3 | hours (one run) |
| 4a | CoreAnimation draws through our device in a test process | `phone-test.sh 4a`: `layerprobe` (CAMetalLayer drawable -> IOSurface -> CPU readback), `carenderprobe` (7 CARenderer scenes vs `renderInContext:`, PPMs in `/var/tmp/carender`) | `PASS layer`, `PASS` on every scene, small mean diffs | stage 3 | days |
| 4 | QuartzCore on Metal (backboardd, SpringBoard) | add `backboardd SpringBoard` to `/var/db/negronimetal/clients`, `killall backboardd` (or reboot); photo of the panel; `phone-test.sh log` | home screen drawn, no dead-man strikes; compare fps with the GL path (negronigl) on the same build | stage 3; persistent pipeline cache | 2-4 weeks |
| 5 | apps | clients `*` minus known-bad (`-chronod`); test apps: a MetalKit triangle app, SpriteKit/SceneKit samples, Safari | each app draws; refusals listed in metal.log `MISSING` lines | stage 4 | open-ended |

Kill switches at every stage: `touch /System/Library/Extensions/NegroniMetal.bundle/off` (no device in any process at
its next start, sandboxed apps included; `/var/db/negronimetal/off` still works for processes that can read /var/db),
boot-arg `negronimetal=0` (kernel publishes no `MetalPluginName`, proposal), the dead-man (two crashes in 30 s
disable a process), the GPU watchdog in backboardd (pending command buffers and no completion for `NEGRONIMETAL_WATCHDOG_S` s, default 60 in backboardd and 30 elsewhere: it writes
`/var/db/negronimetal/strikes/gpu-lost`, and no process gets a device until that file is removed).

### 5. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| A device that registers but cannot draw makes CA draw nothing (Metal before GL in CA's renderer choice) | high | clients allow-list (default: probes only), dead-man, nil on any failure (bergamota METAL_ADRENO630 (a), (h)) |
| Code signing: the plugin is a normal bundle outside the shared cache, dlopened by every Metal process | medium | ad-hoc signing; our AMFI stand-in (patch 0221, slop AMFI) accepts ad-hoc code [I]; UniXNU needed an owner trust cache; flame installs ad-hoc signed bundles with its AMFI patch 0114 [V flame tools/flame-metal2-install.sh, xnu/patches/0114] |
| Private SPI churn | low for iOS 16 (one build, 20H392); high for iOS 26 | frontend is pinned to 20H392 facts (528-byte `_MTLDevice`, selectors); `scripts/metal/spi-dump.sh` regenerates the dumps for a new build; iOS 26 needs a new audit (the frontend already exists for iPadOS 17) |
| IOAcceleratorES stub (patch 0201) has no `MetalPluginName` | blocker for stage 1 system-wide only | stage 1 works without it (`metalprobe --bundle`); then a kernel patch (0230-0239 range, GPU agent) adds the two properties behind `negronimetal=1` |
| Turnip without `VK_EXT_external_memory_host` (Mesa 25.0.7) | blocker for stage 2 | take UniXNU's host-import code from `turnip-darwin-kmd.patch` (MIT) into the GPU agent's Turnip, or use Mesa 85fda3b3 + UniXNU patches as flame did |
| WC mappings of managed RAM are mismatched aliases (no PPL physmap) | high (silent corruption) | GPU pool outside XNU's DRAM (0x900000000+) (metal-design.md 4.3 item 3) |
| Cold pipeline compiles: UniXNU 103 pipelines in 40 s on SM8550; flame ~270 pipelines 3-30 ms each on SD855 | medium (first boot) | persistent cache in `/var/db/negronimetal/cache`; later a host pre-fill (UniXNU "compiler peer") |
| Memory: 60-130 MB GPU pool per process (flame) | medium | 8 MB runtime blocks (flame patch 0100, applied); per-process caps in the kernel |
| License: metal2vulkan is GPL/LGPL, statically linked | medium for distribution | private repo now; for a release keep the bridge relinkable (own dylib) |
| CTR_EL0 read at EL0 raises SIGILL on Darwin | high (crashes host process) | Turnip patch (UniXNU) |

## Host results (2026-10-25)

- Bridge, plugin, probes and m2vtest build for arm64-apple-ios16.0 [V]. All imports exist in the 20H392 cache [V].
- metal2vulkan 720ef1ce (+7 patches) translation of the 20H392 QuartzCore `default.metallib` on the Mac
  (`scripts/metal/host-translate.sh`, profile `vk12-floor` = a bare Vulkan 1.2 device, not the A730's) [V]:
  kernels 3 of 7, vertex 35 of 39, fragment 73 of 95 (each fragment paired with a translated vertex function).
  Refusals: 20 FramebufferFetch (the profile has no rasterization-order attachment access; Turnip 25.0.7 lists
  `EXT/ARM_rasterization_order_attachment_access`, so these are expected to pass on the phone [I]); 4 tile kernels
  (need a tile pipeline: CA uses them only with tile-shader support); 6 functions need their function constants
  (CA supplies them at run time). Vertex descriptors are host stand-ins (16-byte slots), so this checks the
  shader bodies, not CA's layouts. Output: `out/metal/translate/QuartzCore_default/{summary.txt,results.tsv}`.
- Round 2 (2026-10-25): `host-translate.sh` now answers every pipeline input the compile asks for (vertex attributes,
  function constants: first accepted type with value zero/false, attachment formats). vk12-floor: kernels 7/7, vertex 39/39,
  fragment 75/95 (20 FramebufferFetch). Estimated A730 profile (`scripts/metal/a730-profile.py`: vk12-floor limits + the
  Mesa 25.0.7 tu_device.cc features/extensions for FD730) [I]: kernels 7/7, vertex 39/39, **fragment 93/95**; the 2 left
  (`inplace_copy_lpf/lph`) need `fragmentShaderPixelInterlock`, which Turnip 25.0.7 lacks. Output:
  `out/metal/translate/QuartzCore_{floor,a730}/`. Review: `docs/reviews/gpu-turnip-metal-2026-10-25.md`.
- Next host step: a real A730 Turnip profile (`vulkaninfo --json` from Turnip on Linux with drm-shim, FD_GPU_ID=730,
  as flame did for the A640, or from vkprobe on the phone), then rerun the sweep over all 134 system metallibs.

## CoreAnimation fixes from Chlorophyll (2026-10-25)

Ported from the review [reviews/bergamota-chlorophyll-2026-10-25.md](reviews/bergamota-chlorophyll-2026-10-25.md)
(section 3 item 1, and the probes of item 6). Code: frontend patch `userland/metal/patches/flame/0002-*`, plugin
`userland/metal/plugin/NegroniMetal.mm`, probes `userland/metal/probes/` (Chlorophyll MIT notice in `LICENSE.Chlorophyll`).
The fixes (flame/0002 + plugin) ran in every phone session since 2026-10-25 (backboardd and SpringBoard on the GPU);
the probes `layerprobe` and `carenderprobe` never ran on the phone (2026-10-26).

| Fix | Where | Host result |
|---|---|---|
| `CA_USE_CGTEXTUREDATA=0` in every process that gets the device. [V] QuartzCore 20H392 `CA::Render::create_image` reads it with `getenv` once, at its first image (unset = on). [I] An image made before the device opens keeps CA's value | plugin | env set (host test `device`) |
| `targetDeviceInfo` = {0, 0, device name}. [V] `-[_MTLDevice targetDeviceInfo]` answers NULL on 20H392, and `MTLPipelineLibraryBuilder::newLibraryWithFile` reads +0x10 of the answer without a check; when the device does not respond, Metal builds the same {0, 0, name} | flame/0002 | PASS |
| `dedicatedMemorySize` 0, `sharedMemorySize` = RAM (UniXNU's answers), `recommendedMaxWorkingSetSize` = RAM / 2 [I]. [V] `_MTLDevice` has none of them on 20H392 | flame/0002 | PASS |
| IOSurface seed bump (write lock + unlock) after a completed command buffer wrote the surface (render attachments, blit destinations, shader-write textures); not in backboardd; `NEGRONIMETAL_SEED_BUMP=0/1` | flame/0002 | PASS (seed 0 -> 1) |
| DontCare colour attachments that are not IOSurfaces start cleared to zero | flame/0002 | PASS (all texels 0) |
| A nil or refused render pipeline and a refused draw are skipped and logged once; the command buffer completes. Telemetry row `N skipped draws=... refused pipelines=...` | flame/0002 | PASS (status Completed) |
| Control files readable in the sandbox: `BUNDLE/off`, `BUNDLE/clients` (the test tools, staged), `BUNDLE/clients.local` (the owner's, kept by a push), plus `/var/db/negronimetal/{off,clients}`. Fail closed when `BUNDLE/off` cannot be checked. Strikes fall back to the process's cache directory; no writable strikes directory = no device | plugin, build.sh | PASS (`bundleoff`, `blocked`, `device` listed only in clients.local) |
| GPU watchdog in backboardd: 1 Hz; pending command buffers and no completion for `NEGRONIMETAL_WATCHDOG_S` s (default 60 in backboardd, 30 in other processes; NegroniMetal.mm): log, `strikes/gpu-lost`, no device from then on; no crash (`NEGRONIMETAL_WATCHDOG_EXIT=1` adds `_exit(0)`) | plugin + `native_bridge_metal_progress` (flame/0002) | PASS (`watchdog`, `lost`) |
| Probes: `carenderprobe`, `layerprobe` (+ `layerprobe.metallib`), `metallib-sweep.sh` | probes, phone-test 3b/4a | build + import check PASS; never run on the phone |

Not ported (not asked in this round): refusal in `+allocWithZone:` (review item 1.6). `CI_USE_MTL_DAG_FOR_CIKL_SRC=0` is set
(three places in NegroniMetal.mm: the constructor, the open path, before the device is returned) although the string is not
in the 20H392 cache [V]: it changes nothing on this build and stays for a CoreImage that reads it.

## Needs from the other agents

GPU kernel agent (docs/gpu-abi.md): the eight properties of metal-design.md 4.3 (host-page import, per-connection
VA windows or client IOVAs, WC memory outside the physmap, msm-style submit wrapper, ns fence waits, device info,
cache maintenance at EL0, sandbox-openable user client), plus `MetalPluginName = "NegroniMetal"` and
`MetalPluginClassName = "NegroniMTLDevice"` on an `IOAcceleratorES` service behind `negronimetal=1`.

GPU user-space agent (docs/gpu-userland.md): a Turnip `libvulkan_freedreno.dylib` for arm64-apple-ios16.0, release,
with `VK_EXT_external_memory_host`, an exported `vkGetInstanceProcAddr` (or `vk_icdGetInstanceProcAddr`), no EL0
`CTR_EL0` read, no iOS-16-missing imports (`scripts/metal/check-imports.py` checks), at
`out/gpu/turnip/libvulkan_freedreno.dylib` (`scripts/gpu/turnip-build.sh`, the only script that stages it) or a path in `TURNIP_DYLIB`.

Integrator: `scripts/metal/build.sh` then `METAL=1 scripts/metal/root-add-metal.sh ROOT` (after the SSH step).
