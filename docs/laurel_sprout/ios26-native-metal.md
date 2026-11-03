# Mi A3 iOS 26: the `native` Metal stack on the Adreno 610 (third option)

Date: 2026-11-03. Branch `t3/native-adreno-metal-driver`, base 4818e4c. Owner's request of 2026-11-03.
**State 2026-11-03: the scene tool ran on the real GPU, section 11: it draws, blits and dispatches. The compositor never ran on this stack. No frame time exists.** Sections 1 to 9 are the host work, as written then.
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

## 11. First runs on the real GPU (2026-11-03, branch `t3/native-metal-scene-hang-fix`)

Mi A3, iOS 26 23F84, kernel ee30323a57. Scene tool only. **No compositor.**

### 11.1 The first hang: cause

| Fact | Mark |
|---|---|
| `LAUREL GPU SMMU: fault FSR 00000402 FAR 0000001970460000 FSYNR0 00040010`: a write, outside the 32-bit GPU VA | [V] log |
| The phone's IB1 was 270 words; the host's stream of the same scene is 270 words | [V] log, `pm4/plain.rd` |
| Words in that stream: `70460001 0000001d` (`CP_EVENT_WRITE` with one dword, `PC_CCU_FLUSH_COLOR_TS`), then `70460001 00000019` (the next `CP_EVENT_WRITE`, `PC_CCU_INVALIDATE_COLOR`) | [V] cffdump |
| `PC_CCU_FLUSH_COLOR_TS` writes a time stamp. The CP took the next two words as its address: low `0x70460001`, high `0x19`. That is the FAR, with the low bits dropped | [V] the numbers; [I] the dropped bits |
| Turnip gives these events 4 dwords (address + value): `tu_emit_raw_event_write`, Mesa `fd_gpu_events<A6XX>` `needs_seqno` | [V] source, capture |
| The hang followed the fault; with the fix there is no fault and no hang | [V] logs; [I] that the stall caused the watchdog |

**So the address came from no reloc and no shift: it was two packet words.** The register comparison could not see it: it compares state at a draw, and an event is not state.

### 11.2 What else the host proof found before the next run

| Defect | Effect on the GPU | Fix | Mark |
|---|---|---|---|
| A draw called its program's state from an IB2: RB -> IB1 -> IB2 -> "IB3" | a6xx has `CP_IB1`, `CP_IB2`, `CP_SDS` and no third level; Turnip never goes deeper: 217 calls in the largest capture, all level 2 | The draw stream runs as IB1s of the submission (`nw_cs_append_ibs`) | [V] register file and captures; [U] what this CP does with it: it never ran |
| Compute called its program a second time, after its constants and sets: `HLSQ_INVALIDATE_CMD` undid them | Wrong constants in the shader | `nmn_cmd_dispatch` has no call | [V] code, register at the dispatch |
| A pass ended with a CCU flush only | A later pass or blit in the same command buffer can read old lines | Full barrier at the end of a pass, as Turnip for an external dependency | [I] no run shows it |
| Cache invalidate missing after a 2D write | A read through the texture cache of what a 2D blit wrote | In `flush_color` | [I] |
| Fill and copy pitches not as Turnip; `HLSQ_CS_KERNEL_GROUP` written, Turnip's packet sets it; the instrlen workaround of `tu_dispatch` was absent | | As Turnip | [V] code |

### 11.3 The gate: a bad address cannot reach the GPU

`winsys/nw_check.c`, in `nw_submit_go`, on by default; `NMN_STREAM_CHECK=0` is the kill switch. Before the kernel sees a submission:

- parity and length of each packet, and **a rule for each opcode; no rule, no submission**;
- a time stamp event must have its address (`CACHE_FLUSH_TS`, `WT_DONE_TS`, `RB_DONE_TS`, `PC_CCU_RESOLVE_TS`, `PC_CCU_FLUSH_DEPTH_TS`, `PC_CCU_FLUSH_COLOR_TS`);
- no call from an IB2;
- each address in a packet, and each of the 131 address registers of Mesa's a6xx file (`scripts/laurel/native/addr-regs.py` -> `winsys/nw_addr_regs.h`; `test.sh` checks that they agree), lies in a live buffer of this device or is 0;
- a descriptor's address is checked where it is written (`check_descriptor_address`): it has no packet around it.

A refusal is `EFAULT`: one line `LAUREL METAL NATIVE: stream check: a submission refused: ...`, that frame is lost, the GPU stays on. A program's state is read once at bake, not at each draw.

Cost [V phone]: 111 to 117 us for 3 submissions, 1,340 to 1,372 dwords, about 510 packets. [U] on a real frame.

Limit [V code]: it does not read shaders. A shader that computes a wild address still faults.

If a future stream hangs anyway: `mark_gpu_off`: on `ENODEV` from a fence, backboardd writes `stack/failed`, so the next start takes the default and stays on it until the setting is written again. Before this, a stack that hung **after** the screen was lit had its count cleared by that lit screen, and it would hang at each boot [V `option_rule.h`].

### 11.4 Host proof

`scripts/laurel/native/pm4-compare.sh` exits 1 on any of these:

| Check | Result [V host] |
|---|---|
| `test.sh`: `winsys` under ASan and UBSan, with the first hang's stream word for word; `option` | PASS |
| `stream-check.py`: a second decoder with no code in common with `nw_check.c` | Old stream: reports `PC_CCU_FLUSH_COLOR_TS has no address ... writes to 0x1970460001` at `0x808922e4`, and `a call ... from level 2`. New stream: 0 errors |
| The same decoder on Turnip's captures | 0 errors, deepest call level 2: **the rules hold on a driver that draws on this GPU** |
| `pm4-diff.py`: registers at the draw | plain: 153 same, 0 unexpected. Real CA key: 157 same, 0 unexpected |
| `pm4-actions.py`: the clear, copies, 6 mips, readback, dispatch | 161 same, 27 explained, 0 unexpected. New: before this, blits and compute had no comparison |
| Descriptors of the draw against Turnip's | Equal but for addresses. Read once by hand; **not a script** |

### 11.5 Runs on the phone

Limit 8. **4 ran.** No hang. Logs: `logs/nmn-scene-2.txt` to `-5.txt`.

| Run | Time | Stream | Output | What it proves |
|---|---|---|---|---|
| 1 | 05:53 | Plain scene, as the first hang | `scene: wait 0 status 4 error ''`; pixels `ff000000`; `copied byte 5a`; `scene: compute: PASS` | IOKit transport, clear, fill, copy, mips, readback, a dispatch that ends, with no fault |
| 2 | 05:57 | Identity matrix | `ff000000`: the draw showed nothing | The scene's fault: it bound the wrong slots: the planner gave a zero buffer |
| 3 | 06:05 | CA's slots: vertex 2, 3; fragment 1; texture 3 | `ff000000` | `luma_boost_lph` reads only the target, so black stays black: correct, and no proof |
| 4 | 06:06 | Real CA key, `fixed_vert_lph_spc` + `fixed_frag_lph_cph`, white vertices | **`ffffffff` at (0,0), (360,780), (719,1559); `the draw wrote: yes`** | **First pixels: the vertex stage, the rasterizer, the fragment stage and the target** |

Attempt 5 (row 26, `narrow_blur_15`: a texture read) did not start: SSH timed out. The phone was in a panic from 06:15:41 on another kernel (`-348-g5f85e63`, rebooted at 06:07). No `nmn-scene` ran in that boot [V log]. Cause of that panic: [U]; not read here.

**Not proven on the phone [V: no run]: a texture read, a blur, framebuffer fetch that shows, a compute that writes a checked value, an IOSurface target, depth and stencil, more than one pass in a command buffer.**

To run next: `scripts/net/phone-run.sh -s -f out/ios26/native/plans/ca-real.txt out/ios26/metal-native/nmn-scene none /var/tmp/nmn-cache /System/Library/Frameworks/QuartzCore.framework/default.metallib ca-real.txt 26`. Rows that read a texture [V host scan of 0 to 31]: 1, 2, 3, 5 to 31.

### 11.6 What the compositor will hit first, and the plan

The order is [I]. `refused` lines lead (`native-metal: refused`).

| What | State | Why it matters | Plan | Mark |
|---|---|---|---|---|
| IOSurface render target, plane offsets | Written, no test | Every CA frame | The scene with a surface through `nw_bo_import_surface`; the surface must be named in the submission for the display's wait | [V] no test |
| Argument buffers | Refused | `MTLArgumentEncoder`: QuartzCore 11 sites `setBuffer`, 11 `setTexture`; CoreImage, RenderBox | Plain words in a buffer in m2v's argument layout (`bind/heap.rs`); set 1 of the bindless model points at it; each address through `check_descriptor_address` | [V] census |
| Indirect draws and dispatches | Refused | Not in CA's fast path list; CoreImage and apps [I] | `CP_DRAW_INDIRECT` and `CP_EXEC_CS_INDIRECT` as Turnip, with a rule in `nw_check.c` first; the indirect buffer's address through the gate | [I] |
| Planar YUV | Refused when a format is taken whole | Video, camera layers | One texture per plane (`nmb_texture_new_on_surface_plane` exists); Metal's 4:2:2 formats only over linear memory | [V] code, [I] use |
| Formats outside the table, `BGR10_XR` and others | Refused | Wide colour targets | `metal.md` table; add a row only with a Turnip capture of it | [V] |
| Pipeline variants a plan asks for | Refused | Real keys with other bound shapes | A variant is one more ir3 compile, keyed by the plan | [V] |
| Compute descriptor with options | Refused | CoreImage [I] | Map the options the frontend passes | [I] |
| Depth + stencil | Written, no test; the stencil clear is not written | CA's path rendering | A scene row with a depth target, with Turnip's capture | [V] code |
| Framebuffer fetch | Texture read + flush mode; never shown on the GPU | 78 of 218 real keys | Row with a non-black clear: the first real check of the flush mode | [U] |
| Shader events | The CPU waits at most 100 ms | Order of frames | A real wait once the frame path works | [I] |
| A long frame | One thread per command buffer; 1,024 IB limit: a pass costs up to 3 IBs | Live glass made 144 command buffers | The limit is checked before the kernel; a worker for the fences | [I] |
| Hang in a shader | The gate does not read shaders | One hang = the GPU off until a reboot | `mark_gpu_off` returns to the default stack at the next start | [V] code |

### 11.7 Making `native` the default: the owner's step

**Do not change `NMTL_OPTION_DEFAULT`: it is where the fallback goes.** The default is a setting: the file `/private/var/db/negronimetal/option`, plus `NegroniMetal.bundle/option.local` for sandboxed processes. The bundle: `scripts/laurel/ios26-metal-options.sh` -> `out/ios26/metal-all/stage`.

Build, after the merge, in the main checkout:

```
scripts/bg.sh ios26-metal-native scripts/laurel/ios26-metal-native-build.sh
scripts/bg.sh ios26-metal-all scripts/laurel/ios26-metal-options.sh
```

Route A, a new root (the root is mounted at `R`):

```
METAL_STAGE=out/ios26/metal-all/stage sudo scripts/laurel/root-add-metal-ios26.sh "$R"
echo native | sudo tee "$R/private/var/db/negronimetal/option" "$R/System/Library/Extensions/NegroniMetal.bundle/option.local"
sudo chmod 644 "$R/private/var/db/negronimetal/option" "$R/System/Library/Extensions/NegroniMetal.bundle/option.local"
```

Route B, a running rw root, no flash. Order: the stacks first, the selector last, because the selector needs `options/default`:

```
S=out/ios26/metal-all/stage/System/Library/Extensions/NegroniMetal.bundle; B=/System/Library/Extensions/NegroniMetal.bundle
scp -r "$S/options" root@192.168.7.2:"$B/"
scp "$S/Info.plist" root@192.168.7.2:"$B/Info.plist"
scp "$S/NegroniMetal" root@192.168.7.2:"$B/NegroniMetal.new"
ssh root@192.168.7.2 "mv $B/NegroniMetal.new $B/NegroniMetal; echo native > /private/var/db/negronimetal/option; echo native > $B/option.local; rm -f /private/var/db/negronimetal/stack/state"
```

Then Restart UI (XNUtils), or a reboot. XNUtils `metaloption native` writes the same two files and clears the state, when XNUtils from this stage is on the root (`out/ios26/xnutils/root`).

| Line in the log | Meaning |
|---|---|
| `LAUREL METAL: on: stack native (setting native)` | The selector took it |
| `LAUREL METAL26: on: stack native: the screen is lit 60 s after the first frame` | It holds |
| `LAUREL METAL NATIVE: off: <reason>: restart on stack default` | No frame in 240 s, a black surface for 30 s, or no device: the next start is the default stack |
| `LAUREL METAL NATIVE: off: option native failed in 2 starts of the compositor: build UUID stays off until a new build or an owner's reset: stack default` | The start that writes the mark: 2 starts with no lit screen, or a reported failure |
| `LAUREL METAL NATIVE: off: build UUID failed (reason): a new build or an owner's reset tries it again: stack default` | Each later start, also after a reboot |
| `LAUREL METAL NATIVE: new build UUID: the failed mark of build UUID is gone` | A new build: it gets a new try |
| `LAUREL METAL NATIVE: off: the selector cannot write stack/state (errno N): remove that file as root: stack default` | No count on the disk: the stack is not taken |
| `LAUREL METAL NATIVE: off: the kernel turned the GPU off: the next start takes stack default` | A hang. Reboot: the GPU stays off until then |

The way back: `echo default` into both files, or XNUtils.

**The failed mark holds across reboots (section 12).** Setting `default` and then `native` does not clear it. To try the same build again: XNUtils `metaloption`, or `RESET_FAILED=1 scripts/laurel/ios26-metal-install-options.sh native`. A new build needs no reset.

A sandboxed client that cannot read the stack folder takes `default`, not `native`: it cannot see a failed mark, and its stream could turn the GPU off for all. [U] on the phone: which clients these are. So on a healthy `native` such apps run on the default stack. That is the owner's to change when `native` has proved itself.

## 12. The compositor's first hang, and the fallback that did not hold (2026-11-03, branch `t3/native-metal-ca-features`)

### 12.1 The fallback: why `native` came back at each boot

| Fact | Mark |
|---|---|
| 06:49:17 after a CTL reboot: `LAUREL METAL: on: stack native`, hang, then the same 3 starts as at 06:47 | [V] log |
| `stack/state` on the phone: `root wheel`, 0 bytes, the time of the last change of the setting; `active` and `ok`: `mobile` | [V] `ls -la` over SSH |
| `ios26-metal-install-options.sh` ran `: > stack/state` as root. backboardd runs as `mobile`. The folder is sticky. `fopen(STATE, "w")` failed, and the selector ignored that | [V] script, code, `ps` |
| So the count never reached the disk. Each start read 0. The start of pid 868 fell back only because of `stack/failed`, and that file is gone after it is read | [V] code |
| SpringBoard at 06:47:36 took `native` after the fallback: the same empty state | [V] log |
| `mark_gpu_off` wrote no line at either hang: the kernel kills backboardd first | [V] log |
| `LAUREL CTL: reboot` is a reset after 500 ms, with no sync | [V] log, code |

Fix, `userland/laurel/metal/option/option_store.h` (plain C: the phone and the host test run the same code):

- Each write of the selector and of the stacks' marks: a temporary file, `F_FULLFSYNC`, rename, sync of the folder.
- The count goes to the disk **before** the stack loads.
- `failed-OPTION` holds `build reason`. Build = LC_UUID of `options/OPTION/NegroniMetal`: a hash of the linked image, so a new signature is the same build.
- A state that cannot be written: the compositor takes the default, one line. This fails closed.
- A report of failure wins over a lit screen. The default stack's lit screen clears nothing.
- Root scripts remove the files in `stack/`, never create them. `option-rule-test.sh` greps for that.

Bound: **at most 2 hangs for a build** (a hang, a reset before the next start, a second hang). In the usual order 1: the next start gets no device, and that marks the build.

Host proof `scripts/laurel/option-rule-test.sh` [V host]: the log's order, 5 reboots, a power loss that brings back only what was synced; the owner's `default`, then `native`; a new build; the owner's reset; a state that cannot be written; a sandboxed client. Mutants: no sync 27 failures, no mark 13, no fail-closed 2. **Not run on the phone.**

### 12.2 The hang: `FAR 0x1008000` and `0x1068000`

| Fact | Mark |
|---|---|
| Both FARs are a 64 KiB start of the kernel's allocator (`0x01000000` on, `redwood_gpu_address`) + `0x8000`: not a pool address. A surface or host pages | [V] code, log |
| `FSYNR0 00040013`: a write, a missing leaf entry (level 3): the tables go that far, the page is not mapped | [V] bits; [I] reading of `ARM SMMU` FSYNR0 |
| `IB1 83db042c rem 0`, the first IB of 2 had 267 words: 2 IBs = a pass with no draw. The first IB holds init + pass begin, so the only memory write in it (but the scratch word) is the clear | [V] code, log |
| `pass.width = d.renderTargetWidth` in the frontend. Metal's default is 0: the attachments' size. `metal2vulkan` handles that. The native bridge took it as it was: `w - 1` & 0x3fff = 16383 | [V] code |
| So a clear of 16384 x 16384 over a small surface: it runs past the surface's pages | [I] the size 0: no log has the pass's numbers. It fits each fact above |
| `nw_check` let it pass: it read the base address only | [V] code |
| A shader did not cause it: no draw in that submission | [I] from the IB count |

Fix: the pass's size comes from its attachments when the descriptor says 0, and never exceeds them. A view's level and slice count from the view's first ones.

New rule of the gate, `nw_check.c`: what a `CP_BLIT` or a draw writes must fit its buffer, rows x pitch, from the registers of this submission. Same rule in `stream-check.py`, with no code in common. Descriptors: a texture's reach and a buffer's range, not only the base.

A second defect found on this way [V code]: the kernel gives one handle per surface and client, and GEM_CLOSE drops the buffer. Two imports of one surface were two objects; the first free unmapped the surface under the other. Now one counted object. The frontend's `NSMapTable` hid this for the same key only.

Also: `nw_bo_import_surface` asks with `kRedwoodAnyLayout` (laurel 2913): without it the kernel refuses any surface that is not 4 bytes an element.

New scene part, `tests/scene.c` `scene_surfaces`: a real IOSurface (`scene_surface_ios.c`), 32 x 32, size 0, clear, no draw: the compositor's first frame; then 720 x 1560, size 0, the row's draw.

## 13. Rounds of the compositor on the phone (2026-11-03)

Tool: `scripts/laurel/native/compositor-round.sh`, under `phone-lock.sh`: reboot if the GPU is off, install this tree's stage, wait, screenshot, read the lines, write `default` again. Measure: `scripts/laurel/ios26-autotest.sh` (branch merged on laurel-sprout).

| Time | Build's change | Result [V logs] |
|---|---|---|
| 07:22 | Pass size from the attachments; surface handle counted | No hang at the first frame. 3 min of compile, first submission, then 110 to 130 submissions per 5 s with **about 4 names each** (Turnip at that time: 7,300). Screenshot: the boot spinner on black, drawn by the native stack |
| 07:25 | | A kernel panic in the stackshot path: not this stack: fixed in the kernel (post/9013) |
| 07:38 | Disk cache | Check: `the screen surface stayed black for 30 s`: the samples miss the spinner in a cold start. Limit for native now 240 s |
| 08:03 | Depth32Float_Stencil8; Turnip's format table | Hang after 73 s: `FAR 0x124404820902`, a read |
| 08:24 | Tables and holes refused | First frame 5 s after the device opened. The same hang |
| 08:39 | Flight recorder; host pages inside a page; rows of 64 | The same hang. The recorder: first failed submission has all 5 line draws of the ring |
| 08:54 | `SP_FS_BINDLESS_PREFETCH_CMD` | The same hang: `FAR 0x126404820902`. That fix was real, and not the cause |
| 09:05 | Lines as Turnip's | **Not read yet: the phone did not return to iOS after the reboot** |

| 10:32 | Full ir3 variant unless the pipeline's constants pass the limit; lit rule | Lock Screen correct on the screen (`logs/round-104142/*-awake.png`). No hang only because the display slept 10 s after the first lit frame |
| 10:44 | The same, with unlock + Home swipe | Hang 75 s after start, at the first submission after the unlock. The CP is 1840 dwords into a 2222-dword IB; with the safe variant it stopped at 860 to 1004 dwords, at the generic draws. So the variant moved the hang [V]; it did not cure it |

**Correction [V]: the rows above that name a FAR read too much.** All these hangs have `FSR 00000400`: FSR.FORMAT, no fault bit, `gfsr 0`, `CP_HW_FAULT 0`. There was no bad read: FAR is a stale value. The GPU stays busy: `RBBM_STATUS 00e714e5` = SP, HLSQ, UCHE, VPC, PC_DCALL, LRZ, RB, RAS, TSE, CP busy; TPL1, VBIF, CCU, VFD idle. (`00e594e5` at 10:44: VFD busy, UCHE idle.) The line register and the prefetch register were real fixes and not the cause.

The recorder now names the draw: each draw has an id, the stream writes it at `RB_DONE_TS` (no wait), a thread keeps the last id in the ring's head, `flight-read.py FILE --stuck` prints the first unfinished draw.

Cold pipeline compile [V `pipelines.log`]: 100 to 560 ms per CA pipeline, 17.9 s for the generic one. With the disk cache: no compile.

What the stack refuses now, each with a line: argument buffers, indirect draws, visibility results, a draw's descriptor tables, root tables and address holes, a pass before a draw, planar YUV taken whole, formats outside the table, a copy of a Depth32Float_Stencil8 texture.
