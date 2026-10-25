# Review: Bergamota + Chlorophyll (Metal on the Adreno 630) against our GPU stack, 2026-10-25

Scope: what iOSPlus10 (iOS 16.7.16 20H392, OnePlus 10 Pro, SM8450, Adreno 730) can port, copy or learn from
Bergamota (iOS 18 on the Poco F1) and its Metal driver Chlorophyll, and from the other reference repos on this Mac.
This is research only. No code of ours changed. Nothing ran on the phone.

Marks: **[V]** read in the source, log or binary named. **[I]** inference.

Sources read:

| Repo | Where | Commit | Licence |
|---|---|---|---|
| Bergamota (ry-diffusion/Bergamota, `develop`) | `out/research/Bergamota` (clone `--depth 50 --no-single-branch`, 25 MB) | 1965b5f (2026-10-24 23:25 -0300); `origin/ios26` fb82624, `origin/metal` | **none at the top level** [V: no LICENSE file, `git ls-files`]. Userland files carry `SPDX-License-Identifier: MIT` [V: `gpu/eagl/launch/bgl-launch.c:2`, `gpu/eagl/src/eagl.m`, `gpu/freedreno-sweet/sweet_drm.c`]. Kernel patches carry no licence line [V] |
| Chlorophyll (ry-diffusion/Chlorophyll) | `external/Chlorophyll` | 787338f (`main`, up to date 2026-10-25); `ios26` branch d0680df read through `gh api` | MIT [V: `README.md` "Licence", SPDX MIT in every file]; `air/` and the `air-*`/`ir3-*` Mesa patches are hackios-xnu-userland, MIT, (c) OOSEX GANG [V: `NOTICE.md`, `LICENSE.hackios-userland`] |
| external/bergamota (old pin) | `external/bergamota` | 0826e48 (2026-10-24 11:34) | same as Bergamota; older than the clone, do not use for this review |
| UniXNU-pong (Nothing Phone 2, SM8475, **A730**, iPadOS 16.6.1 20G81) | `/private/tmp/ios26-stack-research/Chengdong-Yu_UniXNU-pong` | ab74f07 | BSD-2-Clause-Patent; `drivers/PongMetal` MIT [V LICENSE files] |
| Droid-VM (iPadOS 17.7.11 guest in crosvm on Gunyah, paravirtual Adreno) | `/private/tmp/ios26-stack-research/Droid-VM_UniXNU-droidvm` | dc123d8 | BSD-2-Clause-Patent [V] |
| UniXNU, UniXNU-ios26, zeta, slop, UniXNU-negroni, mu-negroni, xnu12377 | `/private/tmp/ios26-stack-research/*` | see the sub-survey below | UniXNU family BSD-2-Clause-Patent; slop and UniXNU-negroni: none at the top level [V] |
| ios-flame copies | `/private/tmp/flame-pristine.Xydl{,.patched}`, `/private/tmp/flame-verify` | `phone/metal2` only | `.Xydl` = ios-flame 745c434 `phone/` [V diff -rq]; `.patched` = our flame/0001; `flame-verify` = + our flame/0002 (`dc civac`) |
| ios-s9 (Galaxy S9, SDM845, iOS 16.7.16) | `external/ios-s9` | 7b72f7c | MIT [V] |
| `/private/tmp/iosport-research` | empty [V] | - | - |

Licence rule used in section 3: MIT/BSD code can be copied with its notice. Files without a licence are for
learning only: we read them and write our own code. Bergamota's kernel patches are in that group.

## 1. How Bergamota and Chlorophyll do Metal

### 1.1 Architecture: Metal -> AIR -> NIR -> ir3 over Gallium freedreno (no Vulkan)

- [V] Chlorophyll translates AIR (the LLVM bitcode inside `.metallib`) directly to Mesa NIR and compiles it with ir3 for the A630.
  It implements the Metal object model over the Gallium **freedreno** driver, not over Vulkan (`external/Chlorophyll/README.md:3-7`).
- [V] Parts:
  - `air/` holds the AIR -> NIR front end and the runtime `libbgair.dylib` (`air/air_metal.c`, 7826 lines). Both come from
    hackios `userland` (MIT).
  - `src/bgmtl.m` (2045 lines) holds the Metal classes. `BGMTLDevice` is a subclass of `_MTLDevice`, with `MTLDeviceSPI` added
    through `class_addProtocol` (`src/bgmtl.m:4-8, 263, 414`).
  - The libdrm stand-in is Bergamota's `gpu/freedreno-sweet/sweet_drm.c` over the msm-shaped kernel client `SweetAdreno630`.
- [V] Command buffers commit asynchronously. A serial completion queue waits for the fence, then runs the completion work: surface
  sync, presents and completed handlers (`src/bgmtl.m:1216-1270`). The "scheduled" handlers run at submit.
  `BGMTL_DEFER_SCHEDULED=1` restores the old behaviour (`src/bgmtl.m:1220-1237`).
- [V] Shader coverage on iOS 18.7.8 (22H352):
  - QuartzCore `default.metallib`: 165 of 178 entry points translate and compile. All 119 fragment and all 41 vertex functions
    pass. Only 5 of the 18 kernels pass: the 13 tile kernels (`air.imageblock`) fail
    (`results/quartzcore-22H352-a630-fcfold.json`, summary).
  - All system metallibs: 8364 of 20508 functions pass (`results/all-system-metallibs-summary.txt:1`).
  - The CoreImage stitchable libraries (`ci_filters`, `ci_stdlib*`, `extern`/`visible` functions) translate **0**
    (`results/all-system-metallibs-summary.txt:60-65`). `air.visible` library functions are refused as entry points
    (`air/air_metal.c:3245-3280`).
- [V] Framebuffer fetch works natively: draws whose fragment shader reads `[[color(n)]]` render in sysmem (`docs/FIXES.md:76-84`).
  Raster order groups are not required by any QuartzCore function they run.

### 1.2 How the device gets into processes: plugin for all, injection for backboardd

- [V] **System plugin, same discovery as ours.** Kernel patch 0232 sets `MetalPluginName = "Chlorophyll"` and
  `MetalPluginClassName = "CHLDevice"` on the IOAcceleratorES stub, only with boot-arg `chlorophyll=1`
  (`xnu/patches-11215/0232-beryllium-chlorophyll-metal-plugin.patch`). This is our patch 0205.
- [V] `CHLDevice` refuses in `+allocWithZone:`, before any object exists. The reason (`plugin/chlorophyll_plugin.m:91-111`):
  an object released before `-[_MTLDevice init]` ran crashed in `-dealloc` (backboardd crash loop).
- [V] Its gates fail closed (`plugin/chlorophyll_plugin.m:74-89`):
  - `chlorophyll.off`;
  - the `chlorophyll.deny` list, and the `chlorophyll.allow` list when it exists;
  - the inject is already loaded;
  - backboardd never gets a device from the plugin;
  - the kernel reports the GPU not ready.
- [V] The control files live **inside the bundle**: sandboxed apps cannot read `/private/var/tmp`, and an unreadable kill switch
  would fail open (`plugin/chlorophyll_plugin.m:21-23`).
- [V] The plugin also makes two environment changes in every process that gets a device (`plugin/chlorophyll_plugin.m:123-137`):
  - `CI_USE_MTL_DAG_FOR_CIKL_SRC=0`: CoreImage's CIKL->Metal kernel graph wrote through NULL (SBRendererService).
  - `CA_USE_CGTEXTUREDATA=0`: QuartzCore's Apple-tiled compressed-image path read past the file (SpringBoard crash loop).
- [V] **backboardd by injection.** The launchd job runs `bgl-launch` (`gpu/eagl/launch/bgl-launch.c:1-28`). That wrapper sets
  `DYLD_INSERT_LIBRARIES=/usr/local/lib/bgmtl/bgmtl-inject.dylib` and `BGMTL_BB=1` itself, then `execv`s the real backboardd
  (`:277-288`).
  - It does this only when `bgmtl-bb.arm` exists, `bgmtl-bb.off` does not, and the previous Metal launch of this boot became healthy.
  - In the constructor, the inject sets the CA preferences, then calls `MTLCopyAllDevices()` (that call makes Metal's device array)
    and `MTLAddDevice()` before QuartzCore creates its render server (`inject/bgmtl_inject.m:293-352`). The preferences are
    `CAEnableFramebufferCompression`, `CAEnableIOSurfaceCompression` and `CAEnableDeepFramebuffer`, all false, plus
    `CA_DISABLE_FRAMEBUFFER_COMPRESSION=1`.
  - A watchdog writes `bgmtl-bb.off` and calls `_exit(0)` on any of these (`:219-245`). launchd then restarts backboardd on the
    CPU renderer.
    - The kernel reports the GPU lost.
    - 3 command buffers fail.
    - No command buffer completes within 60 s of the first commit.
- [V] Why backboardd does not use the plugin: a plugin device composited without the compositor profile, and static areas showed
  the zoomed wallpaper (`plugin/chlorophyll_plugin.m:83-86`, commit a353345). In the compositor, the profile skips the cache
  clean and the seed bump (`src/bgmtl.m:1283-1290`).
- [V] The MercuryPoster wallpaper extension gets the inject as an extra `LC_LOAD_DYLIB` (`inject/bgmtl_inject.m:1-15`).

### 1.3 IOSurfaces, drawables, present

- [V] **CAMetalLayer drawables.** CoreAnimation makes the IOSurface and calls `newTextureWithDescriptor:iosurface:plane:`. The
  texture is that memory (`src/bgmtl.m:1617-1619`).
- [V] The kernel's `SURFACE_BO` call (idempotent) answers the handle, size, offset and pitch (`air/air_metal.c:256-261, 1632`).
  Imports are cached per surface ID, with 24 entries. 128 entries pinned enough memory that full-screen allocations were refused
  (`air/air_metal.c:1644-1662`; commit 5657441).
- [V] **After the GPU writes an IOSurface** (only outside the compositor, `src/bgmtl.m:1278-1306`):
  - The plugin cleans and invalidates the surface through the kernel (`rwa_texture_flush_surface`, i.e. `BO_SYNC`).
  - It does a write lock and unlock to bump the IOSurface seed. Consumers cache by seed, so Mercury's drawables otherwise showed a
    frame one cycle old (Bergamota `NOTES.md:16`).
- [V] Sampled IOSurfaces that another process drew with the CPU (status bar, volume HUD) are cleaned once their seed moved
  (`src/bgmtl.m:1655-1665`).
- [V] **Compositor present.** backboardd renders into its IOMobileFramebuffer surfaces. The kernel then does the following:
  - 0229 holds a swap until the newest submitted fence passed.
  - 0235 copies every frame into one of three framebuffer-owned scan-out buffers.
  - 0240 does that copy with one CP_BLIT on the 2D engine.
  - 0241 completes the swap as soon as the blit is queued behind the frame's GPU work, and scans the buffer when the blit fence
    passes.
  - 0247 waits up to 1 s, not 100 ms, for that fence.

  Sources: `docs/FIXES_KERNEL_SYSTEM.md:31-60`, `xnu/patches-11215/0241-*.patch` header, `0247-*.patch:1-3`.
- [V] Why the copy is needed: CoreAnimation's IOMFBFlipBook keeps one swap in flight and reuses the surface of swap N-1 as soon as
  swap N completes (`docs/FIXES_KERNEL_SYSTEM.md:87-95`).
  - Scanning CA's surfaces in place either waits for the latch on every frame (swapdepth 1, ~25 fps) or tears (swapdepth 2).
  - Their direct (zero-copy) scanout patches 0211/0216/0220 ended with `0221-beryllium-fb-direct-safety-off`.
- [V] Measured: swipe test 20.8 fps (sync) -> 28.4 (async + GPU copy) -> 38.6 (0241) (`FIXES_KERNEL_SYSTEM.md:42`). With the
  texture pool it reached ~41 fps, with backboardd at 93-98 % of a core (`docs/FIXES.md:137-147`).
- [V] The phone runs async commits with full redraws. Dirty regions still break drawing (`FIXES_KERNEL_SYSTEM.md:58-60`,
  `NOTES.md:17`).

### 1.4 Versions and GPU

- [V] iOS 18.7.8 (22H352), iPhone XR userland (iPhone11,8), arm64e with PAC rewritten to plain code by Renegade. Kernel xnu-11215.
  GPU: Adreno 630, chip 0x06030001 (`README.md:9-12, 48-57`).
- [V] The README status table still says "CPU rendering, no GPU yet" (`README.md:52, 59`). It is older than the Chlorophyll logs:
  - The first live backboardd run on Chlorophyll was commit 0925016.
  - Control Center renders correctly (commit d1d04a6).
- [V] iOS 26: the branch `ios26` (iOS 26.6.2 23G90, xnu-12377) is built but not booted. Its image has no Chlorophyll payload
  (Bergamota `origin/ios26:docs/IOS26_PORT.md:21-28`).
  - Chlorophyll `ios26` (d0680df) reads the 18.7.8 -> 26.6.2 Metal SPI change statically, with `tools/dsc-objc-gap.py`: `_MTLDevice`
    598 -> 672 methods.
  - BGMTLDevice declines Metal 4, tensors and residency in its factories (`IOS26.md` on that branch).
  - Plugin discovery is unchanged on 26.

### 1.5 What is missing or buggy in their port

- [V] The 13 QuartzCore tile kernels are not translated. CA uses them only when the device reports tile shaders
  (Bergamota `docs/METAL_ADRENO630.md:386-391`).
- [V] Stitchable and `visible` functions are not linked, so CoreImage's stitchable libraries give 0 functions. ImageIO kernels:
  0 of 17 (`results/all-system-metallibs-summary.txt:60-66`).
- [V] Fixed so far: linear sampled textures, after one revert (`docs/FIXES.md:32-34, 149-158`). Still open: "dirty regions"
  (partial updates), the brightness slider, and a 1 fps cap when the backlight service is published (0243, now off by 0246).
- [V] GPU kernel limits (`docs/GPU_KERNEL.md:154-161`): one address space (2 GiB), one ring, no isolation between clients.
  The recovery path of 0186 is "built, never run on hardware" (`GPU_KERNEL.md:185`).
- [V] Frame rate is CPU bound: about 2/3 of backboardd's CPU time goes to CoreAnimation itself (`docs/FIXES.md:27-31`).

## 2. Layer by layer: keep, replace or merge

| Layer | Ours | Theirs | Verdict |
|---|---|---|---|
| GPU bring-up, ring, fences, VA (kernel) | slop A730 ladder + 0230/0233 (RedwoodGPU, msm ABI, per-client tables opt-in) | A630 `sweet_a630.c` + `SweetAdreno630` (A6xx gen 1, different registers) | **Keep ours.** Their code is A630-specific and has no licence. Learn 4 items (section 4): tile-tail page, recovery, MMIO accessors, table/VA counters. |
| IOSurface import (kernel) | 0230 by ID (0x7e) + 0232 USERPTR (0x49) | `SURFACE_BO` by ID, idempotent; client-memory surfaces read-only in the GPU; writable alias (0214/0217); `BO_SYNC` | **Keep ours.** Add the tile-tail mapping. Answer repeated imports of one surface ID with the same BO (if 0230 does not do that yet [I]). |
| Present / scanout (kernel) | 0231 GPU copy into the one ABL panel buffer; 0234 zero-copy DPU flips with SwapWait (opt-in) | three own scan-out buffers + kernel CP_BLIT queued behind the frame + async swap completion (0235/0240/0241/0247); direct scanout turned off | **Merge.** Keep 0231's A7XX 2D sequence and 0234's DPU flip, and change the target to 3 kernel-owned buffers in the splash region, flipped by the DPU: their best-measured design. Keep 0234's zero-copy as an A/B, because Bergamota measured its limits. |
| User GPU driver | Turnip (Vulkan) for Metal; freedreno (GL) in negronigl | freedreno Gallium only | **Keep Turnip** (flame and UniXNU proved metal2vulkan + Turnip on 20H392 and iPadOS 17). Port 2 ir3 fixes, which Turnip shares (section 3). |
| Shader front end | metal2vulkan (AIR -> SPIR-V), GPL/LGPL | AIR -> NIR (hackios + Chlorophyll fixes), MIT | **Keep metal2vulkan.** Keep Chlorophyll's `air/` as the MIT fallback study and the A/B oracle (its corpus tools), not linked in. |
| Metal runtime / frontend | UniXNU/flame NativeMetal frontend (MIT) + metal2vulkan runtime | `bgmtl.m` + `air_metal.c` over Gallium | **Keep ours. Merge their behavioural fixes** (section 3, item 1). It is a list of what CoreAnimation needs, and most of it is independent of the back end. |
| Plugin and loading | NegroniMetal.bundle via 0205; clients file, dead-man, `/var/db/negronimetal/*` | Chlorophyll.bundle via 0232 (same SPI); backboardd by an injecting launcher | **Keep the plugin route for backboardd** (CA prefs set in-process, XR10 withheld: `NegroniMetal.mm:423-427, 507-515`). Merge: refusal before alloc, control files readable in the sandbox, a GPU-lost watchdog, the CI/CA env switches, the health marker. |
| OpenGL ES | NegroniGL (GLD plugin over Mesa, GLI part not written) | bgl-launch + EAGL shim over Mesa; now "deprecated, explicit only" (`bgl-launch.c:7-10`) | **Freeze** (section 5). |
| Tests | vkprobe, metalprobe, m2vtest, host-translate, host plugin test | CARenderer harness vs `renderInContext:`, CAMetalLayer probe, quad probe (provoking vertex), all-metallib corpus sweep | **Merge:** copy the harness ideas (MIT) into `userland/metal/probes`. |

## 3. What to port or copy, in priority order

Each item gives its source, licence and target. "Copy" means MIT code with its notice. "Learn" means we write our own code.

1. **Plugin and frontend fixes for CoreAnimation (Chlorophyll, MIT, copy or learn). Small; do before the first stage-4 run.**
   1. `CA_USE_CGTEXTUREDATA=0` in every Metal process (`chlorophyll_plugin.m:132-137`). [V] The name is in the 20H392 cache
      (`dyld_shared_cache_arm64.03`; `CI_USE_MTL_DAG_FOR_CIKL_SRC` is not, so skip that one). [V] Pong withdraws the same
      ASTC/compressed-image path on 20G81 (`drivers/PongMetal/PongQuartzCorePolicy.h:11-22`).
   2. Answer `targetDeviceInfo` (`{0, 0, "Chlorophyll"}`: NULL crashed Metal's library loader, commit 9728eb7). Also answer
      `dedicatedMemorySize` and `sharedMemorySize`: without them every CIContext creation threw (UniXNU NativeMetal
      `NativeBridgeMetalFrontend.mm:1269-1272`). [V] Both selectors exist in the 20H392 cache. [V] The flame frontend has
      neither (grep of `out/metal/src/flame/phone/metal2/NativeBridgeMetalFrontend.mm`).
   3. Bump the IOSurface seed (write lock + unlock) after the GPU wrote a surface, outside backboardd (`src/bgmtl.m:1300-1306`).
      [V] The flame frontend has no `IOSurfaceLock` call.
   4. `DontCare` colour attachments of private textures start cleared to zero. CA blends rounded-corner masks into them
      (`docs/FIXES.md:83-84`, 198d8c3). [I] The same black-wedge risk exists with Turnip GMEM and `LOAD_OP_DONT_CARE`.
   5. Skip a refused draw or clear and log it, but do not fail the command buffer: one refusal left the whole frame undrawn
      (`docs/FIXES.md:101-106`). Clears and draws skip colour slots that have no texture. That is legal in Metal.
   6. Refuse in `+allocWithZone:` instead of after `[super init]`. Ours inits and then drops the object
      (`NegroniMetal.mm:374-379`): that is safe but leaks one `_MTLDevice` per refused process [I].
   7. Put `off`, `clients` and the deny list where a sandboxed app can read them, e.g. in the bundle (`chlorophyll_plugin.m:21-23`).
      [I] Ours are in `/var/db/negronimetal`. An app that cannot read `off` fails open, and an app that cannot write `strikes/`
      loses the dead-man (`NegroniMetal.mm:155-175`).
   8. A 1 Hz watchdog thread in backboardd. When the kernel reports the GPU lost, or 3 command buffers fail, it writes `off` and
      calls `_exit(0)`. The 60 s first-completion timer counts from the first commit, not from launch (`bgmtl_inject.m:219-245`;
      `docs/FIXES.md:108-112`). Our dead-man counts only crashes.
2. **Kernel: tile-tail page for surface BOs (Bergamota 0234, learn).** The Adreno writes render targets in whole tiles, so it writes
   up to one tile of rows past the end of a surface whose height is not a tile multiple. It ran into the next BO or faulted on the
   guard page. Three faults lost the GPU (`docs/FIXES_KERNEL_SYSTEM.md:97-102`). Their fix maps the tail to one shared, zeroed,
   writable page. [V] Ours maps whole 16 KiB pages of the surface and nothing after them (`README-gpu-kernel.md` section 2). The
   1125x2436 framebuffers are not a multiple of any bin height [I], so our 0230/0232 need the same tail. Target: 0230 follow-up.
3. **Kernel: scan-out into own buffers (Bergamota 0235/0240/0241/0247, learn).** Section 2, "Present". Our 0231 already has the
   A7XX blit. What changes is the target: 3 slots after the panel memory (0234 already places slots at `0xb89f0000..`), the DPU flips
   between them, and the swap completes once the blit is queued. Fall back to the CPU copy after 3 failed blits for 120 frames,
   then try the GPU again. Wait up to 1 s for the blit fence before scanning. This removes the tear risk in
   `README-gpu-kernel.md` section 3 ("panel side is not double-buffered").
4. **ir3 fixes that Turnip also runs (Chlorophyll `patches/`, MIT, copy after a check).**
   - `ir3-round-default.patch`: `create_cov` leaves int->float rounding at ROUND_ZERO when the shader declares no float controls.
   - `ir3-shift-split.patch`: `(C + x) >> s` is wrong for a negative C in `ir3_nir_lower_io_offsets.c`, which puts SSBO element
     offsets 2^30 past the end.

   [I] Both are in `src/freedreno/ir3`, which Turnip uses. Whether metal2vulkan's SPIR-V declares a rounding mode is not checked.
   Test: an `m2vtest` kernel with `(float)int` of 0.5-ulp values and `buf[i - 1]`. The third patch, `ir3-ssbo-subdword`, is
   Gallium only: its own text says that Turnip writes one descriptor per width. Target: `userland/turnip/mesa-patches/0002-*`.
5. **Turnip heap and allocation pressure (UniXNU-pong, BSD-2-Clause-Patent, copy with notice).**
   - `patches/mesa/0001-pong-scoped-gpu-heap.patch`: clamp `heap.size` to the connection's VA window. CA caches outgrew a
     170 MiB window.
   - `0002-pong-allocation-pressure-reclaim.patch`.

   [I] With `negronigpu_pt=1` (16 GiB window) this is less urgent. Without it, the shared space is the risk. Target: our Turnip
   patch, after the first stage-2 run.
6. **Test harnesses (Chlorophyll `test/`, `tools/`, MIT, copy).**
   - `bgmtl_carenderer_probe.m`: six CARenderer scenes on the device, compared with `-[CALayer renderInContext:]`.
   - `bgmtl_layer_probe.m`: `CAMetalLayer nextDrawable` -> IOSurface -> CPU readback.
   - `bgmtl_quad_probe.m`: provoking vertex.
   - `tools/corpus.py` + `extract-metallibs.sh`: all-metallib sweep. Our `metal-plan.md` lists this sweep as the next host step.

   Target: `userland/metal/probes`, `scripts/metal/`.
7. **iOS 26 SPI gap tool (Chlorophyll `ios26` branch, MIT, copy).** `tools/dsc-objc-gap.py OLD NEW` compares class dumps with the
   frontend. Their 18 -> 26 result is a ready list: Metal 4 factories nil, `supportsMTL4*` NO, residency sets, shared events by Mach
   port. Target: `scripts/metal/`, for the iOS 26 phase (CLAUDE.md goal).
8. **backboardd launch wrapper ideas (Bergamota `bgl-launch.c`, SPDX MIT, learn or copy).**
   - State tied to `kern.bootsessionuuid`, a "healthy" marker, 3 strikes per boot.
   - It sets `DYLD_INSERT_LIBRARIES` itself before `execv`. That avoids launchd's filter, which drops `DYLD_*` for `com.apple.*`
     labels (`docs/notes.md:376-377`).

   [I] We need this only if a probe, or `root-add-negronigl.sh`, must inject into backboardd. AMFI patches 0220-0223 must be in the
   kernel for `DYLD_*` to work at all (`docs/notes.md:379`).
9. **Mesa freedreno BO-cache patches (Chlorophyll `fd-bo-*`, MIT).** These are for NegroniGL only, so they wait for section 5.
   [V] The 4096-handle refusal in their kernel does not apply: ours grows to 16384 handles (`0230` `GPU_BUFFERS_MAX`).

Not to copy: Bergamota kernel patches (no licence, A630 registers). The `air/` runtime as a second Metal device: two devices in
one process break `MTLCreateSystemDefaultDevice` (`chlorophyll_plugin.m:17-19`).

## 4. Their kernel side against our open items and risks

| Our item (gpu-status.md "Open items", README-gpu-kernel.md section 7) | What Bergamota found / did | Action for us |
|---|---|---|
| Cache maintenance after GPU writes into an imported IOSurface; EL0 `dc civac` needs SCTLR_EL1.UCI, else SIGILL | [V] They do it in the kernel (`BO_SYNC`: clean+invalidate through the kernel alias, `src/bgmtl.m:1287-1296`). The compositor skips it, because GPU writes and display reads are both DRAM (`DISPLAY_HW.md:210-217`). Their hazard is a dirty CPU line evicted over a GPU frame, so they clean once at allocation (0212). | Keep our EL0 path. Add a kernel sync selector fallback (msm CPU_PREP/CPU_FINI already exist for GL), used when a guarded `dc civac` probe at plugin start traps [I]. Skip the per-frame clean in backboardd, as they do, once the first run shows correct frames. |
| Turnip "device lost" with `negronigpu_pt=1` EBUSY; VA exhaustion | [V] 0237: full-screen targets were refused late in each boot, because table pages are taken on first touch and never returned. Control Center lost its backdrop (`FIXES_KERNEL_SYSTEM.md:62-76`). | [V] Our 0230 already has 8192 tables. Add `gvm_tables=used/total` and free-range counters to a sysctl, as they did, and watch them in long runs. Pong's heap clamp (section 3, item 5). |
| Panel side single-buffered, tear possible (README section 3) | [V] 3 own scan-out buffers + blit + async (0235/0240/0241/0247). Direct scanout tore or flickered and was turned off (0220/0221). | Section 3, item 3. |
| No GPU reset or recovery after a hang (README section 7) | [V] 0186 design: halt the SQE, power GX down through the GMU, reset the GMU, wake again. Earlier fences count as complete (output is garbage), clients see an epoch change (`WAIT_FENCE` -> IO error), at most `sweetgpurecover=N` resets. Built, never run (`GPU_KERNEL.md:185-201`). | Learn the contract (epoch, IO error, reset cap) for 0230. The A730 sequence differs (GMU/HFI of gen 7); Pong's README has the SM8475 order (`drivers/PongAdreno/README.md:11-45`). |
| Hypervisor (Gunyah) stage 2 / trapped MMIO | [V] 0236: clang 21 turned a volatile MMIO loop into post-indexed `ldr w, [x], #4` (no ISV syndrome). The trapping hypervisor cannot emulate that, so the GPU never came up with locally built kernels (`FIXES_KERNEL_SYSTEM.md:78-85`). | [I] Our SMMU/GPU accesses may trap under Gunyah too. Scan our kernel's disassembly of `negroni_adreno.c` for write-back addressing near MMIO, or use single-instruction asm accessors. This costs little and matters before the first CI kernel with a new clang. |
| Half-drawn frames with async command buffers | [V] 0229 holds a swap until the newest fence passes. 0241 replaces the hold with "blit queued behind the work". | [V] Our 0231/0234 key on each surface's `gpuFence` and flip only after it is done (`0234` patch:180). No change. Check that the frontend reports "scheduled" at submit, not at completion; otherwise encode and GPU do not overlap (their 28.4 -> 29.4 -> 38.6 fps). |
| One SMMU context for all clients | [V] Same for them (`GPU_KERNEL.md:159`). | No help there. Our 0233 is ahead. |
| Stale frame on wake | [V] 0227/0233: the first empty swap after display-on scans black, once per wake. | [I] Check 0231/0234 for the same case on the first phone run. |
| Not GPU, but it limits frame rate | [V] 0245 RTC: without `IORTC`, coreduetd ran at ~75 % of a core (521 -> 849 frames in the swipe test). 0243: publishing a `backlight-control` service capped iOS at 1 fps. | [I] Check that our 0200/0203 time fix gives coreduetd a real clock. Do not publish a backlight service without a frame-rate test. |

Pong (same GPU family, SM8475 A730v3, iOS 16.6.1) adds A730 facts our kernel may need [V `drivers/PongAdreno/README.md:11-45`]:

- The LPAC stream SID1/0x401 is next to SID0/0x400, and BR/BV/LPAC wait on THREAD_SYNC before PM4.
- The ZAP comes before the nonsecure switch.
- The QSMMU-500 ACTLR is 0x32b.
- The vendor's terminal restore triplet must be included.

[I] Compare these with slop's 22-step ladder when the first user submit hangs.

## 5. Do we still need OpenGL ES (NegroniGL)?

- [V] Our own disassembly: `-[CIContext initWithOptions:]` tries Metal first (`CIMetalCopyDefaultDevice` =
  `MTLCreateSystemDefaultDevice`). It builds a GL context only when there is no Metal device (`docs/notes.md:369-370`). The Bold Text
  crash is the GL context in a process without a GL driver (`docs/boldtext-crash.md`). So **a process with a working Metal device
  does not reach `CI::GLContext`** [I, from that code path].
- [V] Bergamota: SpringBoard-side processes get a Chlorophyll device from the plugin; only backboardd is denied.
  - CoreImage then runs on Metal: SBRendererService crashed **inside CoreImage's Metal path** and was fixed with an environment
    switch, not with GL (`docs/FIXES.md:114-121`). The plugin comment says CoreImage "still renders on this device (its
    stitchable metallibs load and run)" (`chlorophyll_plugin.m:124-129`).
  - The ES path is now "deprecated, explicit only" (`bgl-launch.c:7-10`).
  - No Bold Text test is reported [V: grep of both repos].
  - [I] iOS 18 differs from iOS 16 here: there, QuartzCore's render server does not use GL without a hook (Bergamota `NOTES.md:618`).
- [V] Droid-VM publishes `IOGLESBundleName = "AppleMetalGLRenderer"`, Apple's GLES-on-Metal renderer, the same value as the stock
  AGX accelerator (`package/DroidVMGpu.cpp:953-957`).
  - It also gives `iconservicesagent` and WidgetRenderer a Metal device, because their CoreImage contexts otherwise "fall back to
    OpenGL ES and crash in CI::GLContext" (`board.toml:194-208`).
  - [V] `AppleMetalGLRenderer.bundle` is in our 20H392 root, and its code is in the shared cache: `gldGetVersion` = (4, 1, 0x10,
    0x7f00) (`docs/notes.md:472`).
  - [I] Nobody shows a GL-on-Metal run on a non-Apple GPU. It may call AGX-only SPI.
- [V] Pong (iPadOS 16.6.1) still draws MobileIcons' Lanczos scaler on the CPU in Preferences. That CoreImage EAGL context jumped to
  address 0 (`userland/icons_cpu.c:2-5`), so not every process had a device there.

Conclusion:

1. **Stop new GPU work on NegroniGL.** The GLI part that is not written (`docs/notes.md:484-487`) is the most expensive item left,
   and the Metal route makes it unnecessary.
2. **Fix Bold Text with Metal.** After stage 4, extend `/var/db/negronimetal/clients` to SpringBoard, then to every UIKit process
   (`*` minus the known-bad ones), as Chlorophyll's deny-list model does. Watch for the CoreImage selectors in section 3, item 1.2.
3. **For EAGL users** (apps with GLKit/CAEAGLLayer, CoreImage in processes without a device), test Apple's own renderer: a boot-arg
   value of 0205 (for example `negronigl=2`) that publishes `IOGLESBundleName = "AppleMetalGLRenderer"` instead of `NegroniGL`.
   Test it with `ngl_test` in a process that has a NegroniMetal device. This needs no Mesa GL at all [I: to verify on the phone].
4. **Until the GPU works**, the no-GPU Bold Text fix stays the CoreImage fallback in `userland/cifix/` plus the Bold Text root
   default. Keep NegroniGL softpipe only if cifix fails.

## Top 5 actions

1. Plugin/frontend: add the CoreAnimation fixes of section 3, item 1. Most important: `CA_USE_CGTEXTUREDATA=0`, `targetDeviceInfo`,
   `dedicatedMemorySize`/`sharedMemorySize`, the IOSurface seed bump, DontCare -> clear, and skip-not-fail for refused draws. Also
   move the control files to where sandboxed apps can read them, and add a GPU-lost watchdog in backboardd.
2. Kernel 0230 follow-up: map a shared zero page after each surface BO (tile tail). Add GPU table/VA counters. Check for
   write-back MMIO addressing (0236 lesson).
3. Present: change 0231 to copy into 3 kernel-owned scan-out slots, with a DPU flip and the swap completing at blit queue (the
   0235/0240/0241/0247 design). Keep 0234's zero-copy as an A/B.
4. GL: freeze NegroniGL GPU work. Fix Bold Text by giving SpringBoard and the UIKit processes a Metal device after stage 4. Test
   `IOGLESBundleName = AppleMetalGLRenderer` behind a boot-arg.
5. Turnip: test, then port, `ir3-round-default` and `ir3-shift-split` (MIT) and Pong's heap clamp. Copy Chlorophyll's CARenderer
   and CAMetalLayer probes and the all-metallib corpus sweep. Copy `dsc-objc-gap.py` for the iOS 26 phase.

## Sub-survey of the other repos (one line each)

- UniXNU (bd127c0): `patches/mesa/turnip-darwin-kmd.patch` has host import, an 8-fence limit and the sandbox grant (zzw).
  `turnip-host-import-images.patch` drops the dedicated-allocation need for host-pointer images. Cold boot: 77-103 pipelines in about
  40 s (`docs/drivers/native-adreno.md:94`) [V via sub-agent].
- UniXNU-ios26 (68c5134) and zeta (318b2ea): iOS 26 kernel bring-up only, no GPU [V via sub-agent].
- UniXNU-pong (ab74f07): the closest twin (A730, iOS 16).
  - Metal on 20G81 is claimed in the Chinese README, but "unconfirmed" in `drivers/PongMetal/README.md:6`.
  - metal2vulkan patch 0008 adds an `IOS16_6_1` Metal level, and 0009 IOSurface row padding. Compare them with our flame/m2v
    patches for 20H392.
  - It disables CA's `sw_renderer` entry in backboardd (`UPSTREAM-PORT.md:20`) [V].
- Droid-VM (dc123d8): paravirtual KGSL. The clients list and the `AppleMetalGLRenderer` choice are section 5. The present path waits
  for the producer fence before each swap [V via sub-agent].
- ios-s9 (7b72f7c): CPU rendering only. 0096 zero-copy with SwapWait is the base of our 0234 [V via sub-agent].
- flame copies in `/private/tmp`: our own patched trees, no new upstream content [V].
