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

**Honest size.** Stages 2 and 3 are host work with strong tests. Stage 4 can reach "the right registers on the host", not "the right pixels". Pixels need the phone. A first start on the phone will find faults that no host test finds. Section 8 lists what the phone test must show.

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
| State per submission | Turnip runs `tu6_init_hw` at each primary VkCommandBuffer begin (`tu_cmd_buffer.cc` 2662): about 70 registers + WFI + cache invalidate [V]. How many VkCommandBuffers a submission holds: [U]; the log gives 11.6 IBs per submission, and one VkCommandBuffer can be several IBs | one init IB per submission, called, not copied. The kernel's ring is shared with other processes, so one init per submission must stay | [I] |
| CCU mode switch | per pass with autotune: flush, invalidate, WFI [V code] | none: always sysmem | [I] |
| Shader bounds checks | `DevicePolicy` containment on (m2v default) | Off for the compositor: Apple's shaders are trusted. Stage 3 measures the instructions | [I] until stage 3 |

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
- The ring (`redwood_gpu_submit`): `CP_REG_TO_MEM` time stamp, CCU invalidate depth and color, the IBs, `RB_DONE_TS`, `CACHE_FLUSH_TS`. So each submission starts with an empty CCU and ends flushed. **Other processes run on the same ring between submissions, so no register state survives a submission.** Hence one init IB per submission.
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

No disassembly was needed yet. If a stage needs one, the doc will list file and offset.

## 6. Stages and state

| Stage | State |
|---|---|
| 1 This doc | Done |
| 2 Winsys + PM4 | In progress: see below |
| 3 Shader path | Not started |
| 4 Metal objects | Not started |
| 5 Third option | Not started |
| 6 GL ES | Not started |

## 7. Time [I]

| Stage | Work | Then |
|---|---|---|
| 2, 3 | About a day of agent time each | Host-proven |
| 4 | Several days for the compositor's set | Registers right on the host, pixels unproven |
| 5 | Hours | Option in the selector |
| Phone bring-up | Unknown. Expect faults and hangs. **Days to weeks with the owner in the loop** | First pixels |
| 6 | 1 to 2 days: NegroniGL's freedreno gallium already runs on iOS 16 through the same ABI | Apps only |

## 8. What the phone test must show first

Not asked yet. Stage reports will say exactly what runs and what it writes.

1. A tool over SSH, writes nothing but its own log: device open, GET_PARAM values, one submit of a `CP_MEM_WRITE`, fence.
2. A clear + one draw into a buffer, read back.
3. The compositor with the option, with the fallback armed. Lines: `LAUREL METAL NATIVE: on|off: ...`.
4. The bench of `ios26-metal.md` 10.5, three stacks. The numbers that decide: `present_p50/p95`, GPU per submission, kernel time per submission, pool free, names per submission.
