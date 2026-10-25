# Metal plan: full Metal on the Adreno 730 through Turnip (iOS 16.7.16 20H392)

Owner priority (2026-10-24): full Metal acceleration, Metal translated to Vulkan on Mesa Turnip.
Architecture, interfaces and build: [metal-design.md](metal-design.md). Marks: **[V]** seen, **[I]** inference.
Nothing in this plan ran on the phone yet: kernel builds wait for Xcode 15 (notes.md section 5).

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
| SpriteKit, SceneKit, games | depth, MSAA resolve, argument buffers, ICBs, heaps | runtime has them; the frontend lacks heaps/argument buffers/ICBs (NativeBridgeMetalFrontend.mm:8) |
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
| 4 | QuartzCore on Metal (backboardd, SpringBoard) | add `backboardd SpringBoard` to `/var/db/negronimetal/clients`, `killall backboardd` (or reboot); photo of the panel; `phone-test.sh log` | home screen drawn, no dead-man strikes; compare fps with the GL path (negronigl) on the same build | stage 3; persistent pipeline cache | 2-4 weeks |
| 5 | apps | clients `*` minus known-bad (`-chronod`); test apps: a MetalKit triangle app, SpriteKit/SceneKit samples, Safari | each app draws; refusals listed in metal.log `MISSING` lines | stage 4 | open-ended |

Kill switches at every stage: `touch /var/db/negronimetal/off` (no device in any process at its next start),
boot-arg `negronimetal=0` (kernel publishes no `MetalPluginName`, proposal), the dead-man (two crashes in 30 s
disable a process).

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
