# Mi A3 iOS 26: the `native` Metal stack on the Adreno 610 (third option)

Date: 2026-11-03. Branch `t3/native-adreno-metal-driver`, base 4818e4c. Owner's request of 2026-11-03.
**No phone was used. Nothing here ran on a GPU. No pixel and no frame time exists for this stack.**
Marks: **[V]** read or run here (file, command, log). **[I]** inference or estimate. **[U]** unknown.

## 1. Verdict

| Part | Decision | Why | Mark |
|---|---|---|---|
| Keep the Objective-C frontend (ios-flame + `flame-ios26` + `flame-bbd`) | **GO** | It already answers everything 23F84 sends (`selector-gap`: 0 required missing [V]). Below it are only 148 `nmb_*` calls + 9 `native_bridge_metal_*` calls [V `llvm-nm -u`]. That is the seam | [V] |
| Keep AIR -> SPIR-V (`metal2vulkan` crate, no `ash`, no Vulkan) | **GO** | Library API with plain data: SPIR-V words, layout, bind plans. 141 of 154 CA pipelines already pass with it | [V] |
| Direct AIR -> NIR translator | **NO-GO now** | It replaces `lower`, `memory`, `structurize`, `spirv`: 162,885 lines [V count]. It costs months, and it brings compile-time gain only: SPIR-V never reaches the GPU, and `spirv_to_nir` is in user space with no Vulkan object. Reopen it only if a phone number shows that compile time matters | [V] size, [I] rest |
| Mesa `spirv_to_nir`, NIR, ir3, fdl as static libraries | **GO** | MIT, the same patched tree as the phone's Turnip. The one part that must be right is proven on the phone: ir3 code ran in boot 11 | [V] |
| Drop `metal2vulkan-runtime`, `ash`, Turnip | **GO** | 261,371 + 44,090 lines leave the path at run time. This is where the per-submit lists and per-command-buffer state come from | [V] |
| Own PM4 + winsys on RedwoodGPU, no kernel change | **GO** | All needed requests exist. Section 4 | [V] |
| Name only what the kernel must act on | **GO, the largest sure gain** | Section 3 | [V] code, [I] size |
| `memoryless` on GMEM for screen-size targets | **NO-GO** | CA asks 720 x 1560 RGBA16Float memoryless = 8.98 MB [V]. GMEM is 132 KiB. On the default stack it makes 108 tiles, section 3.3 | [V] |
| `memoryless` on shared scratch memory | **GO** | One backing per size and format. The content is undefined between encoders by Metal's rule, so sharing is legal | [I] |
| GMEM tile passes | **Off at first, sysmem always** | 36 tiles at full screen, 108 with CA's second attachment [V capture]; a switch of CCU mode costs a WFI [V `tu_emit_cache_flush_ccu`]. GMEM can come back per pass if the bench shows a gain | [V] numbers, [I] choice |
| Render pass merging | **GO, small gain** | In sysmem, load and store are free. A merge saves only register setup and a flush. Glass and blur passes read the last target, so they cannot merge | [I] |
| Shared intermediates for `CABackdropLayer` | **NO-GO in the driver** | CA owns those textures. A driver cannot see their lifetime unless CA uses a heap and `makeAliasable`. A CA hook would be needed: another feature, and a look risk | [I] |
| GL ES on this winsys | **Stage 6, for apps only** | [V `ios26-userland.md`] On 23F84 the render server has no GL path. CoreAnimation is Metal only. GL is for apps | [V] |
| 60 fps with full live glass | **Not reachable by a driver** | The cost is pixels x instructions on 1 SP. Section 3.3 | [I] |

**Honest size.** Stages 2 and 3 are host work with strong tests. Stage 4 reached "the right registers on the host", not "the right pixels". Pixels need the phone. A first start on the phone will find faults that no host test finds. Section 8 lists what the phone test must show.

## 2. Call census of 23F84

Method [V]: `scripts/ios26/native-census.py`: every `objc_msgSend$` call site in the resolved listings of the cache (`scripts/ios26/metal-trace.sh`), against the 140 protocols of Metal's class dump. Output: [ios26-evidence/native-census.tsv](ios26-evidence/native-census.tsv), 184 selectors. A row says "an image sends this name". The `in_frontend` column only greps the name; many device answers go through a table, so `selector-gap.py` is the real gap check: **0 required missing** [V, run by `ios26-metal-build.sh`, its log in `out/ios26/metal/selector-gap.txt`].

| Image | Calls | Of them in Metal's protocols | Names |
|---|---:|---:|---:|
| QuartzCore (`lst`, call sites) | 8,318 | 561 | 113 |
| RenderBox (`lst`, call sites) | 1,916 | 205 | 78 |
| IconRendering (stubs) | 223 | 13 | 13 |
| CoreImage (stubs) | 2,089 | 104 | 104 |
| UIKitCore (stubs) | 61,936 | 19 | 19 |
| CoreUI, SwiftUICore, MaterialKit, IconServices (stubs) | | 12, 3, 3, 5 | |

What this says for the driver [V]:

- **The fast path is not in the call sites.** `MetalContext` gets its encoder calls with `methodForSelector:` (19 sites; QuartzCore 0x183f0136c on: `setVertexBuffer:offset:atIndex:`, `setFragmentBuffer:offset:atIndex:`, `setVertexBufferOffset:atIndex:`, `setFragmentBufferOffset:atIndex:`, `setFragmentTexture:atIndex:`, `drawIndexedPrimitives:...`, `drawPrimitives:...`) and calls the IMP. So a draw count cannot be read statically, and the frontend's methods must be plain IMPs. They are.
- **Metal 4:** 0 uses in QuartzCore, RenderBox, UIKitCore. None needed. [V]
- **Draws:** `renderCommandEncoderWithDescriptor:` 3 sites in CA, 3 in RenderBox; `computeCommandEncoder` 1; `blitCommandEncoder` 2 + 1. `dispatchThreadgroups:threadsPerThreadgroup:` 8. `copyFromTexture:` 5 + 1, `generateMipmapsForTexture:` 4 + 3.
- **Surfaces:** `newTextureWithDescriptor:iosurface:plane:` 9 + 2. `newTextureWithDescriptor:` 26 + 11. `newHeapWithDescriptor:` 2 + 1. `newBufferWithLength:options:` 5 + 2. `setPurgeableState:` 7.
- **Sync:** `encodeSignalEvent:value:` 3 + 1, `encodeWaitForEvent:value:` 3, `signaledValue` 24, `addCompletedHandler:` 8, `addScheduledHandler:` 3, `waitUntilScheduled` 3 + 2, `waitUntilCompleted` 1 + 1.
- **Apple features behind a gate:** `dispatchThreadsPerTile:` 6, `setTileBuffer:offset:atIndex:` 2, `setImageblockWidth:height:` 2. Gate: `supportsTileShaders` at QuartzCore 0x1841556bc sets bit 0x20000 of `+0xdc4`. FD610 answers 0 [V host, `ios26-evidence/metal-fd610-answers.txt`], so CA does not ask them [I]. Mapping in `native`: answer 0, as today. Tile functions and imageblocks are refused. Raster order groups: answer 0 (`inplace_copy_*` are the only users, `ios26-metal.md` 4.1).
- **Memoryless is on this path.** QuartzCore `new_metal_context` 0x184154b74: `supportsMemorylessRenderTargets` sets bit 3 of `+0x1088` unless the env `CA_ENABLE_MEMORYLESS=0`. `get_surface` then calls `add_memoryless_textures` 0x183f96404 for the framebuffer: a texture of the framebuffer's size, format 0x73 (RGBA16Float), usage 5, storage 3 (memoryless). `add_path_buffer_texture` 0x183f9652c does the same for path rendering. **On the default stack such a texture is real memory for each surface: 8.98 MB at 720 x 1560 [I: Vulkan has no lazy memory on Turnip here].** `native`: one shared backing. [V] code; [U] how often CA draws to it when tile shaders are off.
- **Residency sets:** `newResidencySetWithDescriptor:error:` 1 site. `native` keeps the frontend's plain answer: every buffer is always mapped, so a residency set has nothing to do.

Pipelines: 189 QuartzCore functions, 154 pipeline rows, 141 made on the default stack, 13 `tile_*` not used [V `metal-pipelines.tsv`]. Boot logs give the real `fixed_frag` keys: 218 rows [V plan of a sibling branch, `out/ios26/native/plans/ca-real.txt`].

## 3. Cost model

Numbers: `scripts/ios26/native-cost.py logs/usblog-20261103-000638.txt` -> [ios26-evidence/native-cost-boot11.txt](ios26-evidence/native-cost-boot11.txt) [V]. 560 windows of 5 s.

### 3.1 What the kernel pays on the default stack

**Correction of my first version:** the log's "KB out of the cache" is per **submission**: `flushed >> 10 / submissions` [V `RedwoodGPU.cpp` 1603; found by `t3/ios26-gpu-render-effects`].

| Window kind | Submissions per 5 s | Names per submission | Pushed per submission | Kernel time per submission | GPU per submission | Pool free |
|---|---:|---:|---:|---:|---:|---:|
| Steady, 02:24 to 02:52, UI on the screen, GPU busy 19-24 % | 61 | **1,537** | **72.6 MB** | **26-33 ms** | about 18 ms | 60 MB (p50 of all) |
| GPU busy >= 30 % (127 windows), p50 | 73 | 881 | 1.6 MB | 733 us | 33 ms | 134 MB |
| same, p90 | 127 | | 28 MB | 11 ms | 84 ms | |
| same, max | 218 | | 154.7 MB | 73 ms | 537 ms | 0 MB |

The first row is a steady cost, not a storm [V]: 61 x 26 ms = 1.6 s of each 5 s, with the GPU lock held [V `a submission: 0 us before the lock, 25761 us with it`], and about 885 MB/s of cache push. So **32 % of one core goes to pushing buffers out of the cache because Turnip names them, and every other client waits for that lock.**

Why [V code, `RedwoodGPU.cpp` `submit`]:

- A scattered buffer the CPU has mapped (the pool is full) is pushed at **every** submission that names it, with no check of a write. [I, `t3/ios26-gpu-render-effects`] that is most of the 72 MB: 8 MB blocks of metal2vulkan's pools.
- Every listed buffer with a `surface` goes through the push rule. Surface pushes per window: 32,717 of 92,220 names.
- Laurel 2913: a surface named by a client that is not the window server gets a new seed, because the kernel cannot tell a read from a write, so the window server pushes it again.
- Turnip lists every buffer of the device (`tu_knl_drm_msm.cc` 956: `.bos = device->submit_bo_list`, the device-wide table) [V]. Here that is hundreds of buffers and every imported surface.

### 3.2 What `native` changes, and how sure each line is

| Cost | Default stack | `native` | Mark |
|---|---|---|---|
| Names per submission | 881 to 1,537 | Command chunks (1-3) + surfaces this command buffer touches (0-20) | [V] kernel needs no more: a name only drives push, fence, display wait. [I] count |
| Kernel time per submission | 0.7 to 33 ms | about 0.1 to 0.3 ms: the low end of the log (185 us with the lock) | [V] floor, [I] that we reach it |
| Pushes caused by listing | up to 72.6 MB per submission | none for a buffer this submission did not use; a scattered buffer only after a CPU write | [I] |
| Lock wait for the others | up to the whole 26-33 ms | short | [I] |
| Buffers in the kernel | one or more per Metal object, m2v 8 MB blocks | 4 MB slabs + a list of freed large buffers | [V] code, host test; [U] pool use on the phone |
| Memoryless | real memory per surface | shared | [V] CA asks; [I] saving; [U] the pool number |
| Descriptor sets | Vulkan pools + updates per draw | words written to the upload ring | [I] |
| State per command buffer | Turnip runs `tu6_init_hw` at each primary VkCommandBuffer begin (`tu_cmd_buffer.cc` 2662): about 70 registers + WFI + cache invalidate [V]. How many VkCommandBuffers a submission holds: [U]; the log gives 11.6 IBs per submission, and one VkCommandBuffer can be several IBs | the same register list today (section 6.4), program state called. A stored init IB is the next step. The kernel's ring is shared with other processes, so one init per submission must stay | [V] code |
| CCU mode switch | per pass with autotune: flush, invalidate, WFI [V code] | none: always sysmem | [I] |
| Shader bounds checks | `DevicePolicy` containment on (m2v default) | The same: stage 3 measured no gain with them off | [V host] |

### 3.3 Where the GPU time goes on the default stack: found on the host

Method [V]: `scripts/laurel/native/ref-capture.sh`: the fixed scene `userland/laurel/metal-native/tests/scene.c` through the **real** default stack (metal2vulkan runtime, bridge, Turnip for FD610 on drm-shim), with a key the phone really asked (`ca-real.txt`, from `pipelines.log`), decoded by Mesa's `cffdump`. One full-screen pass with one quad:

| Mode | Attachments | Tile size | Tiles (`VSC_BIN_COUNT`) | Draw replays | Blits | Note |
|---|---|---|---:|---:|---:|---|
| Autotune, plain shader, BGRA8 only | 1 | 192 x 176 | 36 | 37 | | |
| **Autotune, real CA key (what the phone runs)** | BGRA8 + RGBA16F | **64 x 176** | **108** | **109** | **222** | Tile load/clear and store per tile |
| `TU_DEBUG=sysmem`, same key | same | none | 0 | 1 | | `SINGLE_PRIM_MODE = FLUSH_PER_OVERLAP_AND_OVERWRITE` |

Three causes, each in code or in the capture [V]:

1. **Every CA key has `fc_framebuffer_fetch` on:** 202 of 202 in this plan, 827 of 827 on the phone [V `pipelines.log`, `t3/ios26-gpu-render-effects`]. m2v turns that into input attachments. Turnip then sets `sysmem_single_prim_mode`, and `tu_autotune_use_bypass` (`tu_autotune.cc` 553) answers "not sysmem". **So each such pass goes to GMEM, whatever its size.**
2. **The memoryless RGBA16F attachment takes 2/3 of GMEM.** CA binds it as `colorAttachments[1]` (`80,115` in 189 of 202 rows). In this key the shader does not write it: `RB_RENDER_COMPONENTS: RT1 = 0` [V]. It costs: tile width 192 -> 64, so 36 -> 108 tiles [V], and 9.6 MB of real memory (`RB_MRT[1].BASE`, size 9,687,040) [V].
3. **The flush mode is set though this shader reads no destination:** its fragment code here is one `bary.f` [V capture]. The flag comes from the pipeline's fetch state, not from a read.

So one layer pass replays its draws 108 times on a 1-SP GPU, each with tile setup, and resolves per tile. **This can be a large share of the 121 to 304 ms.** The share is [U]: no timing exists on the host. The phone's `tumode sysmem` bench tells part of it.

What `native` does with this [I until stage 4]:

- Decide by what the compiled fragment shader does, not by the key: an attachment that no pipeline of the pass writes and whose store is don't-care is not bound. No memory, no GMEM, no bandwidth.
- Always sysmem. `FLUSH_PER_OVERLAP` only for a shader that really reads the destination. How many of the 827 keys read it: stage 3 counts it.

**Faster test for the default stack, with no new driver [I]; not done here, because other agents own that stack:** the env `CA_ENABLE_MEMORYLESS=0`, a switch in Apple's own code (QuartzCore 0x184154b80), should remove the second attachment, so tiles 108 -> 36 and 9.6 MB less per surface. `tumode sysmem` already exists. Whether CA looks the same then: [U]. Phone only.

### 3.4 What it does not change

The pixel work. Same AIR, same ir3, same 1 SP. `glass_background_lph` 837 instructions, `simple_rim_lph` 6,066, `narrow_blur_27` 150 with 14 texture reads per pass [V `ios26-metal.md` 4.2]. A faster driver does not shorten these.

Estimate, **all [I], no number exists**, with the owner's glass figure of 121 to 304 ms a submission:

| Case | Default | `native`, 600 MHz | `native`, 950 MHz if DDR follows (2961, not booted) |
|---|---:|---:|---:|
| CPU per submission in the kernel | 0.7-33 ms | 0.1-0.3 ms | same |
| backboardd CPU | 76 % of a core max in this log, 139 % by the owner's figure | about half [U split] | same |
| GPU per submission, no live glass | 25-86 ms | 20-75 ms: 10-25 % less | 15-55 ms |
| GPU per submission, live glass | 121-304 ms | 100-270 ms: 10-25 % less | 70-190 ms |
| Frames a second, live glass | | | **5 to 14** |

So the owner should expect: **a phone that feels less blocked (CPU, locks, memory), and a modest GPU gain.** Full glass stays slow until the pixel cost falls. If the first bench shows less than 10 % GPU gain, the driver still pays for its CPU and memory saving, but not for glass.

The table above predates section 3.3. If tile replay is a large share of GPU time, the 10-25 % is too low. I do not change the numbers, because no timing exists. [U]

The GPU split by pass is **not in the log** [U]. The first useful bench number is that split: section 8.

## 4. Design

```
Apple's frameworks
  -> frontend (unchanged sources: flame + flame-ios26 + flame-bbd)        class NegroniMTLDeviceImpl, in options/native/NegroniMetal
  -> libnmn_bridge (Rust): the 148 nmb_* + 9 native_bridge_metal_* calls   userland/laurel/metal-native/bridge
       metal2vulkan crate: AIR -> SPIR-V words, layout, bind plans          no ash, no Vulkan
  -> C/C++: userland/laurel/metal-native
       shader/  SPIR-V -> NIR -> our bindless lowering -> ir3 -> binary      Mesa libvtn, libnir, libfreedreno_ir3
       pm4/     a6xx registers, render pass, draw, blit, compute             Mesa's generated headers only
       winsys/  buffers, slabs, command chunks, submit, fences               RedwoodGPU, msm requests
```

Kernel requests used: 0x40 GET_PARAM, 0x42 GEM_NEW, 0x43 GEM_INFO, 0x44 CPU_PREP, 0x46 SUBMIT, 0x47 WAIT_FENCE, 0x09 CLOSE, 0x49 USERPTR, 0x7e SURFACE [V `docs/gpu-abi.md`]. Limits of the laurel kernel [V `RedwoodGPU.cpp`]: 128 IBs (`GPU_SUBMIT_CMDS`, not the 512 of the A730 doc), 8,192 names.

Facts this rests on [V `RedwoodGPU.cpp`, `TopazAdreno.cpp`]:

- A name is used for: the CPU push, `b->fence` (GEM_CLOSE, CPU_PREP), `surface->drawn` (the display's wait). **The GPU's page tables do not depend on the list.** A buffer stays mapped until GEM_CLOSE. So a buffer that is not named is safe if user space keeps it until the fence. The frontend already retains what a command buffer uses.
- The display's wait needs the render target surface named. So **every surface a command buffer writes is named.** Surfaces it reads are named too, so a client's later CPU read and the push rule stay right.
- Scattered buffers (pool full, address below `kSamePlaceBase`) are cached. They need a name when the CPU wrote them. `nw_bo.kind` holds this. Pool memory is write-combined: no push.
- Host pages (0x49): each name pushes the whole buffer. Name them only after a CPU write the frontend reports.
- The ring (`redwood_gpu_submit`): `CP_REG_TO_MEM` time stamp, CCU invalidate depth and color, the IBs, `RB_DONE_TS`, `CACHE_FLUSH_TS`. So each submission starts with an empty CCU and ends flushed. **Other processes run on the same ring between submissions, so no register state survives a submission.** Hence an init per submission.
- Deadline clock: `millisecondsUntil` reads `mach_continuous_time`: user space must use `CLOCK_MONOTONIC_RAW` (`ios26-gpu-lag.md` cause 2). `nw_now_ns` does.

Descriptors, the bindless model: m2v's layout is set 0 (dense, per command) and set 1 (heap arrays). Turnip's lowering (`tu_shader.cc`, MIT) turns each into `bindless_resource_ir3` with a 16-dword stride per element. `native` does the same in its own pass, and writes A6XX descriptors into the upload ring. `SP_BINDLESS_BASE` + `HLSQ_BINDLESS_BASE` point at it. No descriptor pool, no copy. Push constants: `CP_LOAD_STATE6` per stage.

Render passes: always sysmem at first (`RM6_DIRECT_RENDER`, `BUFFERS_IN_SYSMEM`). The CCU stays in bypass mode (`RB_CCU_CNTL` set once in the init IB).

## 5. What is reused, and licences

| Source | Used for | Licence | How |
|---|---|---|---|
| Mesa 25.0.7: NIR, vtn, ir3, fdl, `freedreno_devices.py`, generated `a6xx.xml.h` | compile, layouts, register names, device row | MIT | Linked, built by our script from the pinned tree |
| Mesa Turnip `tu_shader.cc`, `tu_cmd_buffer.cc`, `tu_pipeline.cc` | The order of registers and the values | MIT | Read; small passes ported with credit in the file. Not linked |
| ios-flame frontend + bridge C ABI | Metal objects, the `nmb_*` header | MIT | Built from the same exported tree as the default stack |
| metal2vulkan crates | AIR, SPIR-V, bind plans | GPL-2.0-or-later OR LGPL-3.0-or-later | Linked as Rust crates; the existing default stack has the same terms |
| RedwoodGPU, TopazAdreno (our kernel; topaz/sweet lineage) | ABI | as the repo | Read |
| kgsl (`external/laurel-kernel-los`, `laurel-kernel-oss`), laurel-mainline msm | a6xx bring-up facts | GPL-2.0 | Source of facts only; no code copied |

### Closed sources (owner decision 2026-11-03)

The owner allows the closed Adreno userland as a reference on this computer. Files: `scripts/laurel/native/closed-refs.sh` copies them from `~/laurel-backup/stock/images/vendor.img` to `out/ios26/native/closed/` (git-ignored): `libGLESv2_adreno.so`, `vulkan.adreno.so`, `libgsl.so`, `libllvm-glnext.so`, a610 zap, a630 SQE. No blob, no disassembly and no extract goes into git. Our code comes from facts, not from their machine code.

Items that came from closed sources, so far [V `strings`]:

| Fact | Source | Used for |
|---|---|---|
| The driver has per-bucket render modes and a "direct" (sysmem) path: `Per-Bucket RenderMode Setting`, `Hint invalid: Direct render forced from panel`, `Very low number of draws with a GMEM load` | `lib64/egl/libGLESv2_adreno.so` strings | Support for the choice of sysmem as a normal path: not a port |
| One named erratum: `Errata128AddWFIForVSwithUBWCTextureFetchInNonSinglePrimMode` | same | If `native` turns UBWC on for a texture read in a vertex shader: a WFI there. **Open: which chips, the file does not say by string alone** [U]. No UBWC in the first version |

No closed library was disassembled: `strings` only, and nothing in the driver came from them. So every closed-source item is the table above.

## 6. Stages and state

| Stage | State | Proof | Not proven |
|---|---|---|---|
| 1 This doc | Done | | |
| 2 Winsys + PM4 | **Done on the host** | 6.1, 6.2 [V host] | IOKit transport never ran. No GPU ran this stream |
| 3 Shader path | **Done on the host** | 6.3 [V host] | Pixels |
| 4 Metal objects | **Compositor set written; links and draws on the fake kernel** | 6.4 [V host] | The Objective-C frontend and the plug-in compiled and linked, and **never ran** on any host: they need iOS. No frame |
| 5 Third option | **Done on the host** | 6.5 [V host] | Selector never ran with this option. The full bundle was not assembled here: it needs the `default` and `hot` builds |
| 6 GL ES | **Not built.** Route found, no new code | 6.6 | Everything |

**This is not a working driver yet. It has never drawn a pixel.** It is a complete path from AIR to packets, with registers that agree with Turnip's in the tests below.

### 6.1 Winsys

`userland/laurel/metal-native/winsys/`. `scripts/laurel/native/test.sh winsys`: **PASS under ASan and UBSan** [V host], against `tests/fake_kernel.c`, which has the real kernel's submit rules (128 IBs, 8,192 names, an IB inside a named buffer, parity of each packet).

Checked: 4,000 small objects take at most 2 kernel buffers; no overlap; freed gaps join; a 9 MiB buffer comes back from the free list; 1,000 names of one buffer are one name; 300 IBs are refused before the kernel; a surface's CPU address is not unmapped.

### 6.2 PM4: the same draw, against Turnip

`scripts/laurel/native/ref-capture.sh` runs `tests/scene.c` through the **real** default stack on Mesa's drm-shim. `scripts/laurel/native/pm4-compare.sh` runs **the same file** on the native stack. Mesa's `cffdump` decodes both. `pm4-diff.py` compares every register at the draw, and it exits 1 on any unexplained difference. Results [V host]:

| Scene | Same | Addresses | From the shader's code | By design | **Unexpected** |
|---|---:|---:|---:|---:|---:|
| Plain pipeline (`std_vert1_lph` + `luma_boost_lph`), `TU_DEBUG=sysmem` | 155 | 7 | 7 | 4 | **0** |
| Real CA key of the phone (`fixed_frag_lph_cph`), `TU_DEBUG=sysmem` | 161 | 9 | 1 | 12 | **0** |

Differences by design, each in `DESIGN` of `pm4-diff.py`: push constants per stage, not shared; flush mode only when the code reads the framebuffer; an attachment no program writes is not bound; no UBWC yet.

The test found real bugs before any phone did [V]: a strict-aliasing error that zeroed the vertex output table at -O2 (Turnip's casts need `-fno-strict-aliasing`, which Mesa's build passes); the viewport's y sign; descriptor sets emitted before the program's state invalidate.

What the same scene costs [V host, counts only, one quad]:

| | Default, autotune (what the phone runs) | Default, sysmem | `native` |
|---|---:|---:|---:|
| Top-level command dwords | **7,166** | 481 | **279** (413 with the blit submission) |
| IBs in the submission | 3 | 2 | 1 |
| Buffers named | 18 | 14 | **2** |
| Bytes in named buffers | 49 MB | 48 MB | a few chunks |

Limit: **this compares state, not behaviour.** Equal registers at a draw do not prove the order of events, flushes or the blit paths. Packet order was read against Turnip, not compared. Compute and blits have no register comparison: they only pass the packet walk and decode with no unknown opcode.

### 6.3 Stage 3: the shader path, with no Vulkan

`scripts/laurel/native/ir3-native.sh` links the **same harness** as `ir3-check.sh` (`userland/laurel/metal/tests/ca-pipelines.c`) against `bridge/` + `shader/nmn_shader.c`. No Turnip, no drm-shim, no Vulkan loader. Output [ios26-evidence/native-ir3-fd610.txt](ios26-evidence/native-ir3-fd610.txt) [V host]:

| Set | Default stack | `native` |
|---|---:|---:|
| 154-row plan of `ir3-check.sh` | 141 made, 13 `tile_*` refused | **141 made, the same 13 refused** |
| 218 rows with the phone's real keys | 128 made, 90 refused | **218 made**: the 90 are the plan's own: it names a vertex function `fixed_vert_lph`, which the library does not have; `ir3-native.sh` gives those rows `fixed_vert_lph_spc`, so that the fragment keys count. Not a gain of the driver |
| Fragment instructions, median of 126 | 92 | **80** (21 smaller, 92 same, 13 larger) |

| Shader | Default | `native` |
|---|---:|---:|
| `glass_background_lph` | 837 | 841 |
| `glass_background_sdf_lph` | 1,703 | 1,707 |
| `glass_foreground_sdf_lph` | 686 | 686 |
| `narrow_blur_27_frag_lph` | 150 | 150 |
| `variable_blur_frag_lph` | 147 | 147 |
| `simple_rim_lph` | 6,066 | 6,570 |

What this says:

- **All the glass shaders compile for FD610 through this path** [V]. Code exists; the pixels are [U].
- **There is no shader gain to expect from this stack:** same ir3, same SPIR-V. Containment on or off gives the same counts for these shaders [V], so the stack keeps metal2vulkan's default policy, as the default stack does. `NMN_POLICY=unsafe` is a developer's switch at build test time only.
- `simple_rim_lph` is 8 % larger, cause not found [U]. [I] the default stack's number came with another build of the tables. A real fix only if CA asks that shader often.
- **Only 78 of the 218 real rows read the framebuffer** [V: `nir_lower_input_attachments` made progress]. Glass and blur do not read it. On the default stack all of them take the flush state and GMEM (section 3.3), because the decision is by the fetch state and not by the code. `native` decides per program.

What was reused [V]: `tu_shader.cc`'s order of passes, `build_bindless`, `gather_push_constants`, ported in `nmn_shader.c` with credit. Set 0 and set 1 of m2v map to bindless bases 0 and 1.

### 6.4 Stage 4: Metal objects

`bridge/src/`: all 148 `nmb_*` calls of the frontend link [V]. The frontend's sources are unchanged.

| Works on the fake kernel [V host] | Written, no test | **Refuses with a reason** |
|---|---|---|
| Device, library, functions, specialization, render + compute pipelines, buffers, textures, samplers, render encoder, blit encoder (copy, fill, texture, mips, readback), compute dispatch, commit, wait, completion | Heaps, views, IOSurface textures (`nmn_note_surface`), events, depth + stencil state, host-page buffers | Argument buffers, indirect draws and dispatches, visibility results, pipeline variants a plan asks for, compute descriptor options, planar YUV formats, formats outside the table (`BGR10_XR` and others) |

Mapping of Apple's features:

| Feature | `native` |
|---|---|
| Memoryless | One shared backing per size and format, and not bound when no program writes it [V code]. **No GMEM** |
| Tile shaders, imageblocks, raster order groups | Answers 0, as the default stack. Tile functions are refused |
| Framebuffer fetch | Texture read at the fragment's position + `FLUSH_PER_OVERLAP_AND_OVERWRITE`, only for a program that reads it. 78 of 218 real rows [V]. [U] on the phone: a read and a write of one target need the CCU flush this mode gives; the blob's and Turnip's choice, not tested here |
| Residency sets, `useResource`, `useHeap` | One address space: nothing to do |
| Device answers | The default stack's table on FD610: `bridge/src/answers.tsv`, made by `tests/dump-answers.c` [V]. So a framework takes the same path on both stacks |
| Shader events | Signal at completion. A wait blocks the commit for at most 100 ms: **[I] not a real GPU wait** |
| Store actions | Sysmem stores all. "Don't care" saves no bandwidth yet |
| UBWC | Off in the first version: fewer flushes to get right. One closed-source erratum to read first (section 5). Bandwidth gain left for later [I] |
| Timing | One thread per committed command buffer waits on the kernel's fence: simple, not free. A worker is a later step |

**Known risk to read first on the phone:** `nmn_cmd_init` runs per command buffer, not as one stored IB, and I did not build the "called, not copied" init of section 3.2. Program state is called. So the state gain per command buffer is smaller than that table says.

### 6.5 Stage 5: the third option

| Check | Result [V host] |
|---|---|
| `scripts/bg.sh ios26-metal-native scripts/laurel/ios26-metal-native-build.sh` | `out/ios26/metal-native/NegroniMetal`, 18.99 MB (default: 22.9 MB + Turnip 10.9 MB). It builds nothing of the other two stacks |
| `abi-check.py` | 3 Mach-O files, 0 failed |
| `armv80-check.py` | 0 instructions newer than ARMv8.0 in all 3 |
| `check-imports.py` against 23F84 | PASS, 0 missing |
| `option-rule-test.sh` | PASS, with new rows: `native` falls back at once on a reported failure, and stays on the default until written again |
| `xnutils-test.sh` | PASS: `metaloption native` |

- Bundle: `ios26-metal-options.sh` adds `options/native/NegroniMetal` when that file exists. **An option, never the default:** `NMTL_OPTION_DEFAULT` did not change.
- Failure: the selector's existing rules (no device, crash, no frame in 240 s, black screen), with the line `LAUREL METAL NATIVE: off: reason`.
- The default build: the plug-in changes are under `#ifdef NMTL_NATIVE`, the selector only changes its failure tag. `ios16-compat-run.sh` was **not** run on this branch: run it before a merge.

### 6.6 Stage 6: GL ES

**No new GL code.** The short way already exists, and it is not on this winsys's code, only on its kernel requests:

- The Mi A3 has a GL path on iOS 16 that ran on this GPU: Mesa freedreno, `libOSMesa.8.dylib` + `libtopaz-gl.dylib` (ios-topaz, `scripts/laurel/mesa-linux.sh`), 32.9 fps moving [V `gpu.md`].
- Those three files against the 23F84 cache: **0 missing imports** [V host, `check-imports.py`].
- 23F84 still has `OpenGLES.framework`, `GLEngine`, `libGFXShared`, 580 same symbols [V `images.txt`, `ios26-userland.md`].
- CoreAnimation on 23F84: Metal only. **GL here is for apps** [V].

Not done: a per-app gate on iOS 26, an inject route that 23F84 accepts, any run. A gallium winsys on `nw.c` gives nothing: Mesa's freedreno needs the libdrm shape, which `redwood-drm` already gives over the same requests. So I do not recommend writing one. [I]

## 7. Time [I]

| Work | Estimate |
|---|---|
| Stages 2 to 5 to this state on the host | Done in one session |
| Phone bring-up to a first correct frame | Unknown. Expect hangs. Days to weeks with the owner in the loop |
| Argument buffers, variants, YUV: what the frameworks refuse first | Days, led by `refused` lines |
| GL ES for apps | Days, after the Metal bench |

## 8. What the phone test must show first

**No phone was used. Nothing below has run.** I ask only through the owner, one step at a time.

### Step 1: the scene tool (asks for: SSH to a booted iOS 26 phone)

| Item | Value |
|---|---|
| Runs | `scripts/net/phone-run.sh -s out/ios26/metal-native/nmn-scene none /var/tmp/nmn-cache /System/Library/Frameworks/QuartzCore.framework/default.metallib` |
| Writes | The tool's copy in a temp folder, removed after the run. **No partition, no root change, no setting** |
| Should show | `scene: wait 0 status 4 error ''`; `pixel (0,0)` and `(360,780)` not 0; `copied byte 5a`; `scene: compute: PASS` |
| Risk | **A bad stream hangs the GPU. The kernel then stops it until a reboot (`docs/gpu-abi.md` section 3 item 7), for every stack.** The compositor stops too, and the owner must reboot the phone. Nothing is lost on disk |
| Answers | Does the IOKit transport work; does the GPU accept this stream; first pixels |

Known test limit: the tool has no `metallib` on its own: the path above must exist on that root, and QuartzCore's file is not plain AIR on every build [V `metal-libs.tsv` lists it with AIR]. A wrong path says so at once.

### Step 2, only after step 1 shows pixels: the compositor

| Item | Value |
|---|---|
| Needs | A root with the selector: the first-boot root has the default stack only (`ios26-metal.md` section 10) |
| Writes | `/System/Library/Extensions/NegroniMetal.bundle/options/native/NegroniMetal`; `/private/var/db/negronimetal/option` = `native` through XNUtils, then Restart UI. No partition write beyond what that root already needs |
| Should show | `LAUREL METAL: on: stack native`; then `LAUREL METAL26: on: stack native: the screen is lit 60 s after the first frame`; the kernel's windows with far fewer names |
| On failure | `LAUREL METAL NATIVE: off: reason`, back on the default stack |

### Step 3: the bench

`ios26-metal.md` 10.5, three stacks: `default`, `hot`, `native`. The numbers that decide: `present_p50/p95`, GPU us per submission, kernel us per submission, names per submission, pool free.

**The first thing the bench must answer:** how much of the GPU time was tile replay (section 3.3). A cheap early test with no new driver is `tumode sysmem` and `CA_ENABLE_MEMORYLESS=0` on the default stack [I]. It may give part of this gain sooner.

### Estimated gain, all [I], no timing exists

| Case | Today | `native` |
|---|---|---|
| Kernel time per submission | 0.7 to 33 ms | 0.1 to 0.3 ms |
| Names per submission | 881 to 1,537 | 2 to about 20 |
| Memory | 9.6 MB per screen surface for an unused target; m2v's blocks | Not bound; slabs |
| GPU per submission | 121 to 304 ms with live glass | **Unknown.** If tile replay is the main cost, large. If the shaders are, 10 to 25 % |

## 9. Files for the phone

| File | State |
|---|---|
| `out/ios26/metal-native/nmn-scene` | Built, ad-hoc signed, 18.97 MB. Git-ignored |
| `out/ios26/metal-native/NegroniMetal` -> `options/native/NegroniMetal` | Built, ad-hoc signed, 18.99 MB. Git-ignored |
| The selector and the bundle | `ios26-metal-options.sh`: not assembled here |
| XNUtils with `native` | `xnutils-build.sh`: host-tested, not rebuilt for the phone here |

Rebuild: `scripts/bg.sh ios26-metal-native scripts/laurel/ios26-metal-native-build.sh`. Tests: `scripts/laurel/native/test.sh`, `ref-capture.sh`, `pm4-compare.sh`, `ir3-native.sh`.
