# Mi A3 iOS 26: icons, widgets and glass on boot 16

Date: 2026-11-03. Branch `t3/ios26-gpu-render-effects`. Evidence: `logs/usblog-20261103-000638.txt` (main checkout), the owner's photo of Home, read-only SSH copies of `pipelines.log` and of the icon store (`out/ios26/phone-b16`, git-ignored). **Host tests and read-only reads only. No flash, no restart, no write on the phone.** Marks: [V] measured or read here, [I] inference, [U] unknown.

## 1. Causes, against the six observations of the photo

| Obs | What the owner sees | Cause | Mark | Fix | Host test |
|---|---|---|---|---|---|
| 1, 2 | Icons with no picture; icons with background only (FaceTime, Mail, App Store, Maps, Settings, dock) | **Old entries of iconservicesagent's store.** `com.apple.IconsCache/*/*.isdata` is keyed only by `ProductBuildVersion` and `language`. Boots before the `specializedName` fix drew icons with no effect pipeline, and the store keeps those for ever | [V] section 2 | `LAUREL ICONS` empties the store once per generation | `scripts/ios26/test-icon-store.sh`, `scripts/ios26/isdata-dump.py` on the phone's files |
| 3 | Calendar, Clock, Games right | Calendar and Clock are drawn live by SpringBoard [I]; Games' entry has one image layer and lost little [V montage] | [I] | | `isdata-dump.py` |
| 5 | Dock and Search: rim only, no body | **Our own default:** `LAUREL GLASS` in SpringBoard returned `isEnabled` NO, so `-[CABackdropLayer _copyRenderLayer:...]` sends a disabled layer [V 23F84: it calls `isEnabled`]: no capture, no glass body. The rim is another layer. On a black wallpaper a body is dark too | [V] code, [I] picture | Live glass is the default; bypass only as a kill switch | Glass shaders with real keys: `scripts/ios26/test-real-pipelines.sh` |
| 4 | Both widgets white, label `Waiting...` | **Not shown to be the GPU.** In boot 16 no widget extension runs: `exec` lines have chronod and WidgetRenderer_Default only. All 4 snapshots in `com.apple.chrono/snapshot-cache` are `.private-exception.snapshot` of 3458 bytes: a layer tree with a plain hosting view [V]. WidgetRenderer_Default had a device in 3 earlier boots with 0 failed pipelines [V metal.log], and the old reason to deny it (`_RB4`) went with the `RB_FAMILY` answer [V plug-in] | [V] facts, [U] why extensions do not run | `-WidgetRenderer_Default` out of the list. `Waiting…` has a LaunchServices cause: `ios26-wallpaper-widgets.md` section 2 | none: needs the phone |
| 4 | Wallpaper black | PosterBoard never asks Metal: 0 poster lines in all of `metal.log` [V]; its store `PRBPosterExtensionDataStore` is 4 empty items [V]. The denial is not the cause. IOS-26-Hot turns off the `Autobahn` flags and stages `HomeBackground.cpbitmap` (self-reported on 23F84); we took its client list without that part [V] | [V] | Done: `ios26-wallpaper-widgets.md`, hook `wallpaper` | hook self-test |
| 6 | rdar bar | Owner checks it | - | - | - |

Others in the boot log:

| Line | Finding | Mark | State |
|---|---|---|---|
| `draw skipped ... ThreadgroupMemorySize ... required: 20480, available: 16384` | `CA::OGL::MetalContext::compute_surface_apl_dimming_factor`: threadExecutionWidth 32 x (maxTotal 1024 / 32), `setThreadgroupMemoryLength:` 16 bytes a thread, 16 KiB + the 4 KiB arena. The A610 has 16 KiB. The APL dimming factor of that frame is lost | [V] disassembly, host gives the same refusal to the byte | Fixed: answer 512: `scripts/ios26/test-ca-compute.sh` |
| `newTextureWithBytesNoCopy refused (ADDR 0 ...)` | RenderBox, `TextureCache::prepare_from_texture_data`. `CGImageTextureDataGetDataWithBlock` gives length 0 when the provider names none. A nil costs no picture: `prepare` goes to `CGImageProviderCopyIOSurface`, then to CPU decode [V 0x1969e2540, 0x1969e26a8]. IOS-26-Hot's length repair needs `!deallocator`, and RenderBox passes a deallocator, so it does not apply. The memory may be in Apple's tiled layout (see the plug-in's CA_USE_CGTEXTUREDATA note): reading it as linear could give garbage. So: stays refused, one line, a counter | [V] | Quiet + count |
| `first heap texture refused` | RenderBox goes to the next heap [V earlier]. CoreAnimation: `create_surface_with_properties` appends `_heap-miss` and makes a texture of its own [V 0x18414c6c8 ff]. No picture lost. The accounting is not too strict: 722x1562 BGRA is 4.5 MB and 4.3 MB were free | [V] | Counter |
| `custom_fn` effects, `sdfFill_v1`, `glassHighlight_v1` | Boot 16: `0 failed` in every process, no `render pipeline` refusal [V]. Host: 175 of 175 real RenderBox keys made for FD610 [V]. Pixels on the phone: the montage's icons of 02:06 to 02:52 are right [V] | [V] | Done before this work |
| `first texture of another format over a BGRA surface` | Not in boot 16; only cameracaptured in older boots [V metal.log] | [V] | Nothing |
| MessagesBlastDoorService sig 5, 18 times in the boot | Not the GPU. `BlastDoor/Sandbox.swift`: Correction: the fatal of boot 16 is "BlastDoor cannot run unsandboxed." [V host] | [V] | Done: kernel post/9010, `ios26-wallpaper-widgets.md` section 3 |
| Spotlight sig 11 | pc 0 after `_cacheRenditionProperties` in `-[CUINamedLookup initWithName:...]`, from `defaultIconLayerStack`, recursive layer stacks. Cause: objc method cache race [I] | [V] site | Done: `a64-lower`, `ios26-wallpaper-widgets.md` section 4 |
| half-float derivatives (hakios-dada `air_intrinsics.c`: ir3 gives `dsx` TYPE_F32 on any register; self-reported on an A830) | Checked: 0 half, 468 full derivative instructions in the real keys for FD610 [V] | [V] | Not a cause here |

## 2. The icon store

`.isdata`: 48 bytes of header, RGBA 16-bit float rows, then the rendition's layers. Tool: `scripts/ios26/isdata-dump.py DIR OUT.png`.

| Drawn at (IST, file time) | Entries | Mean coverage | Empty (coverage under 5 %) |
|---|---:|---:|---:|
| 22:xx, 00:xx: before the plug-in with `specializedName` (bundle on the phone 01:52) | 537 | 0.47 to 0.55 | **242** |
| 01:00 to 02:52 | 13 | 0.95 | **0** |

The montage shows old entries with plain or washed plates; the entries of 02:06 and later have full glyphs (Settings gear, rocket). Same files, same effects, drawn after the fix. So the fix works on the real GPU [V], and what the owner sees is the store.

Rule: `userland/metal/plugin/icon_store_rule.h`. In iconservicesagent at the device open: another generation in `.laurel-generation`: every `.isdata` goes, the stamp is written, the process ends once. Line: `LAUREL ICONS: on: N icons of older stacks taken out of the store`. Kill switch `NEGRONIMETAL_ICON_STORE=0`. Cost [I]: one new draw of what is on screen; about 40 icons on Home; pipelines from the shader cache.

## 3. Live glass: numbers

Default now: live capture, Apple's shaders. `LAUREL GLASS: on: live CABackdropLayer capture ...`. Kill switch `NEGRONIMETAL_GLASS=0` or file `no-live-glass`; the old file `live-glass` means nothing now. Real keys for FD610 [V host, `test-real-pipelines.sh`]:

| Shader | Instructions |
|---|---:|
| `glass_background_sdf_no_bleed_lph` | 1,585 |
| `glass_background_no_bleed_lph` | 719 |
| `glass_foreground_sdf_lph` | 686 |
| `fixed_frag_lph_cph`, worst real key | 638 |

No shader feature is missing: the glass pipelines build, with no feature refused [V host]. Pixels with a live capture on this GPU: [U]. **Every** one of the 827 CA specializations on the phone has `fc_framebuffer_fetch` on [V pipelines.log]. In sysmem mode Turnip's fetch flushes per overlap (`sysmem_single_prim_mode`) [V code]: a cost to bench, not to guess. Mode: `tumode`.

Owner's window, RedwoodGPU's lines of boot 16, live glass on:

| Time | Made | us each | Kept given | MB kept | Pool free MB | Submissions | **KB out of the cache a submission** | us of that | GPU us each | Busy % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 02:54:30 | 283 | 62 | 18 | 39 | 50 | 29 | 4,104 | 1,705 | 125,953 | 69.8 |
| 02:54:35 | 650 | 680 | 22 | 30 | 17 | 35 | 28,053 | 11,006 | 84,434 | 53.6 |
| 02:54:41 | 683 | 1,385 | 24 | 26 | 8 | 41 | 39,192 | 18,505 | 79,432 | 54.6 |
| 02:54:49 | 187 | 236 | 11 | 91 | 0 | 6 | 71,237 | 26,475 | 429,818 | 23.4 |
| 02:54:54 | 183 | 65 | 9 | 94 | 0 | 7 | 72,907 | 28,363 | 304,468 | 37.9 |
| 02:55:00 | 13 | 97 | 0 | 119 | 0 | 3 | 68,650 | 28,045 | 121,074 | 6.1 |
| 02:55:16 | 242 | 796 | 13 | 113 | 14 | 21 | 126,828 | 52,120 | 129,111 | 16.2 |

**Correction:** the log's "KB out of the cache" is per submission: `flushed >> 10 / submissions` [V `RedwoodGPU.cpp` 1603]. So 28 to 127 **MB a submission**, not per window: at 02:55:16 about 530 MB/s. Rate 0.4 ms per MB [V]. Glass off, at rest (02:33 to 02:36): 60 submissions in 5 s, 1,537 buffers named, 1.2 MB, 25 to 28 ms a submission: there the time does not follow the bytes; `kIOMemoryIncoherentIOStore` per host buffer [I].

### Which buffers go out of the cache, and why [V `RedwoodGPU.cpp` 1453-1504]

| Kind | Rule | With live glass |
|---|---|---|
| Pool buffer | write-combined: never | no cost |
| Surface from the pool | never | no cost |
| Host pages (no-copy, surfaces by USERPTR) | **every submission, no check of a write** | named in each submission |
| Other surface | when the seed moved, or each 250 ms / 16 ms | `surface pushes` |
| **Scattered buffer the CPU mapped** (pool full) | **every submission, no check** | [I] the 70 to 127 MB: 8 MB blocks of metal2vulkan's pools |

Turnip names every buffer of the device in every submission (521 to 1,537 here), so a scattered mapped block is pushed each time whether it changed or not. It follows the pool: 4 MB a submission at 50 MB free, 72 MB at 0. Under `gGPULock`: `a submission: ... 50010 us with it`. Everything else in the kernel waits behind it. Kernel steps, not done here (the owner has the pool): push a scattered buffer only after a CPU map or write; push outside the lock.

### Why buffers are not reused [V code]

1. **Kernel keep:** `keep()` takes 256 KiB and up, same size and flags. Under 64 MiB free, each `gemNew` of a client that is not the window server first gives back **all kept buffers of all clients** (`RedwoodGPU.cpp` 1022). So when memory is short, the kept list empties at each ask, and the next frame makes them again: given again 0 to 24 in 13 to 683 made.
2. **Command streams:** Turnip's `tu_cs_reset` frees all BOs but the last of each of 7 streams per command buffer; 16 KiB and growing, under the keep limit. With 8 to 14 command buffers per submission that fits about 130 made a second [I]. Fix: `0104-turnip-keep-cs-bos-over-reset.patch`: 8 per array are kept.
3. **CoreAnimation's targets:** `create_surface_with_properties` tries the transient heap, then, `_heap-miss`, a new texture; surfaces go when their pass is done [V for the heap path, I for the rate]. Full-screen 722x1562 BGRA is 4.6 MB; capture and blur at RGBA16F 896x320 is 2.3 MB; RenderBox makes 8 MB heaps. Fix: frontend pool, below.
4. **Pool share:** metal2vulkan keeps 2 empty 8 MB blocks a memory class a process for 1 s or more. 9 Metal processes: up to 16 MB x classes each [I]. Per-client figures: not in the log [U]; `redwood_gpu_held` has them.

`LAUREL TEXTURE POOL` (flame-ios26/0004; idea from IOS-26-Hot `canPoolTextureDesc`, MIT, self-reported "Liquid Glass blur pyramids zero-alloc" on an A640): private 2D render targets with no ShaderWrite go back at dealloc, and the next same descriptor takes one. backboardd 96 MiB, SpringBoard 32 MiB (Hot's 192 and 64, x 0.4 for pixels, rounded up), 32 slots, **2 s** at most, then back to the GPU pool; a refused allocation empties it first. It changes no pixel: Metal promises no contents in a new texture, and every CA and RB target is cleared or loaded with dont-care by the caller [I]. Rule test: `scripts/ios26/test-texture-pool.sh`: 100 frames of 2 targets make 2. Count on the phone: `LAUREL METAL COUNT: ... textures made N (M MiB), taken from the pool K`.

Not done, and why:

- Downscaled capture (`-[CABackdropLayer scale]`, read in `_copyRenderLayer` [V]; `reducesCaptureBitDepth`): **changes the look**: owner decision.
- Render-pass merging: IOS-26-Hot 0009 to 0014 do not apply to 219f013 [V earlier]. Port is real work; no number says encode time rules here.
- Memoryless: CA asks for it where the device says so; `supportsMemorylessRenderTargets` on Turnip is the runtime's answer; backdrop targets are read later as textures, so they cannot be memoryless [I].
- Tile mode: `tumode`, phone bench only.

### What is still [U]

Why 3 to 7 submissions in 5 s with the GPU busy 6 to 38 %: `the window server: N requests, M us here in all` is 2.5 to 4.2 s of 5 s [V], at 1.6 to 2 ms a request, and which requests is not in the log. The lock is not it: `0 us before the lock`. A per-selector time is the next kernel line to add.

## 4. Expected result [I]

| Item | Picture | GPU, memory, CPU |
|---|---|---|
| Icon store emptied | Icons with glyphs (obs 1, 2) | One new draw; no per-frame cost |
| Live glass default | Glass body on dock, pills, folders, with a real wallpaper. On black the body stays dark | As the table above before the pool fixes: 7 to 8 fps, 3 at worst [V]. **Do not expect 30 fps from these fixes** |
| Texture pool + CS BOs | None | Fewer `made`; pool free up; so fewer scattered buffers and less push. Size: [U] until the next boot. Up to 128 MiB more held while moving, gone in 2 s |
| Threadgroup answer | APL factor on each frame | About 2 x the dispatches of that kernel, each smaller: no real change |
| WidgetRenderer_Default on Metal | Maybe nothing (obs 4) | 15 to 20 MB of device [V older] |

## 5. Files for the phone

| File | Way |
|---|---|
| `System/Library/Extensions/NegroniMetal.bundle/NegroniMetal`, `libvulkan_freedreno.dylib`, `clients.local` | `scripts/laurel/ios26-live-update.sh` (SSH copy) or a new root |
| `powermenu-helper`, XNUtils (`liveglass` meaning) | new root (setuid), or XNUtils's update |
| `rm /var/db/negronimetal/live-glass` | no effect now; harmless |
