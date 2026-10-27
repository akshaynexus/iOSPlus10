# GPU kernel patches 0230-0234 (Adreno 730: RedwoodGPU, imports, per-client tables, present, zero-copy scanout)

Status (2026-10-25): written, syntax-checked, host-tested (the 2D command stream). **No CI build,
no boot yet.** Base: branch `base` of `out/kernel/xnu` (xnu-8796.141.3 + dxb + slop 0001-0124).
Worktree `out/kernel/wt-gpu-kernel`, branch `gpu-kernel`, commits `0230` then `0231`
(`git diff base HEAD~1` = 0230, `git diff HEAD~1 HEAD` = 0231). Apply 0230 before 0231.

| Patch | Files | What |
|---|---|---|
| 0230-negroni-gpu-surface-import | `iokit/Kernel/arm/NegroniGPU.cpp`, `bsd/dev/negroni_adreno.c`, `iokit/Kernel/arm/NegroniSurface.{h,cpp}` | RedwoodGPU lifetime and memory fixes, IOSurface import, both user-client ABIs (scalar 10-16 and msm), userspace GPU addresses, write-combined pool, GPU page-table fixes |
| 0231-negroni-gpu-present | `bsd/dev/negroni_gpu_blit.{c,h}` (new), `iokit/Kernel/arm/NegroniGPU.{h,cpp}`, `iokit/Kernel/arm/NegroniFramebuffer.cpp`, `bsd/conf/files` | GPU present: the A730's 2D engine copies GPU-rendered swapped surfaces into the panel memory; surfaces held in use until the copy is done |
| 0232-negroni-gpu-host-import | `iokit/Kernel/arm/NegroniGPU.cpp` | msm selector 0x49 (`struct redwood_drm_userptr`): the caller's own pages as a GEM buffer (VK_EXT_external_memory_host) |
| 0233-negroni-gpu-per-client-va | `bsd/dev/negroni_adreno.c`, `iokit/Kernel/arm/NegroniGPU.cpp` | boot-arg `negronigpu_pt=1`: own GPU translation tables per client, CPU-switched TTBR0 (section 8) |
| 0234-negroni-fb-zero-copy | `iokit/Kernel/arm/NegroniFramebuffer.cpp`, `NegroniSurface.{h,cpp}`, `NegroniGPU.cpp`, `NegroniPlatformExpert.cpp` | read-only display-engine probe at boot; boot-arg `negronifb_zerocopy=1`: backboardd's framebuffers in splash-region slots, shown by the display engine directly (section 9) |

Round 2 (2026-10-25): 0232-0234 written in `out/kernel/tree-gpu2` (branch `patched`, commits
`0232-...`, `0233-...`, `0234-...` on top of the 0231 commit; `git diff 0231-commit 0232-commit` = 0232,
and so on). They apply after 0231 and before 0240-0260 (0240, 0250, 0251, 0260 checked to apply on
top). Full local build: section 10.

The user-client ABI is in [`docs/gpu-abi.md`](../../docs/gpu-abi.md). Host test of the 2D
stream: [`tests/gpu-blit-ib-test.c`](tests/gpu-blit-ib-test.c).

## 1. The RedwoodGPU panic (slop 0119-0124) and the lifetime fix

Observations [V] (external/slop NOTES.md, 2026-10-23):

- 0119 boot (GPU kept + USB): panic after unlock, `phystokv_range` illegal PA 0xc7a24000 (low
  DRAM, not managed by XNU), caller shown as `ml_static_vtop.cold.1`.
- 0121 (watcher): GPU state constant, panic between 60 and 70 s; the panic-time log flush did
  not get the text out.
- 0122 (`negroniadreno_service=0`, GPU kept): no panic.
- 0123 (trace): no "opened by" line in the log.
- The boot image had `gl_test` installed as a launchd job that **starts 60 s after boot** and
  opens RedwoodGPU (slop `install-gl-test.sh`).

Inference [I], not proven: the panic comes from the first `GEM_NEW`, not from the service's
existence. slop 0118 made each buffer an `IOBufferMemoryDescriptor` with
`kIOMapWriteCombineCache`. That gives the pages of a kernel allocation (memory XNU manages,
also mapped cacheable in the physical aperture) a write-combined memory entry and mapping:
the mismatched-alias case that froze ios-sailfish (0150a) and lost data on ios-flame, and that
makes the pmap rewrite cache attributes through `phystokv`. The timing fits gl_test (60 s,
panic before 70 s). The persistent log is flushed every 10 s and the panic flush failed, so the
"opened by" and request lines of the last seconds are expected to be missing from the 0123 log.
0122 had no service, so gl_test fell back to softpipe.

What 0230 changes, whatever the cause:

1. **No write-combined view of XNU memory anywhere.** Own buffers are cached
   (`IOBufferMemoryDescriptor`, default cache mode, kernel and user mappings the same); the
   kernel does the cache maintenance (clean of CPU-written pages at submit, invalidate at
   CPU_PREP), as ios-sailfish 0151/0182. Write-combined memory only from a pool of RAM XNU does
   not manage (boot-arg `negronigpu_pool`, off by default), as ios-flame 0115.
2. The service holds nothing until a program opens it: `start()` only makes the lock (race-free,
   before `registerService`) and reads the pool boot-args. No memory, mapping, thread or
   register access. The 0124 IOResources personality on `NegroniGPUKept` stays.
3. User client: state is created in `initWithTask`, `start()` refuses a wrong provider or a GPU
   that is not kept; `clientClose` (also on process death) frees everything; `free()` does it
   again if close never ran; a closing client refuses new requests.
4. Fence waits: a fence that no submission has had yet is EINVAL. Before, a wait of 1 s or more
   on such a fence declared the GPU hung for good (any client could stop the GPU). Hang
   detection is now "the completed fence did not move for 2 s while waiting". Fence 0 is done.
   GEM_CPU_PREP waits for the buffer's own fence (before: for all work).
5. GPU page tables (`negroni_adreno.c`): unmapping wrote entry `0x3` (a valid page at physical
   address 0, attribute 0) instead of 0, and created tables for addresses that were never
   mapped; at most 256 tables (500 MB of GPU memory) with a linear search per page; every map
   call flushed all tables. Now: unmap writes 0 and creates nothing, 8192 tables, tables found
   through the physical aperture, each written entry is flushed at once.

## 2. IOSurface import (0230)

Scalar selector 12 (ios-sailfish semantics) and msm selector 0x7e (`struct
redwood_drm_surface`, HackiOS redwood-drm layout). The buffer is the surface's own pages
(`NegroniSurface::memory`, whole 16 KiB pages), retained and prepared while the handle lives,
cleaned and invalidated in the CPU's caches at import, mapped at a kernel GPU address (or a
SET_IOVA one). Each submission that lists it sets `NegroniSurface::gpuFence`; that is what the
present path keys on. Mesa renders straight into CoreAnimation's surfaces.

## 3. GPU present (0231)

- `NegroniFramebuffer.cpp` `swap()`: a frame whose enabled layers are all GPU-written surfaces
  (`gpuFence != 0`) is a GPU frame. Its surfaces are retained and held in use
  (`IOSurfaceIsInUse`: u64 at +0x18 of the state page, `negroni_surface_hold`, as ios-topaz
  0099 / bergamota 0097). A frame replaced before it was shown gives its holds back at once.
- At the vsync tick (`negronifb_gpuhz`, default 60 for GPU frames; CPU frames keep
  `negronifb_hz`, default 10), `present()` calls `NegroniGPUPresent()` for each such layer:
  `bsd/dev/negroni_gpu_blit.c` builds an A730 2D-engine copy (Mesa 25.0.7 fd6/turnip r2d
  sequence, A7XX register offsets from `a6xx.xml`) into one of two kernel command buffers; it
  goes on the ring behind the render, so nothing waits. The holds end when the copy's fence is
  done (checked every tick). **The source side is double-buffered:** CoreAnimation renders frame
  N+1 into another surface of its swap chain while N is copied.
- The panel side is **not** double-buffered: ABL's display engine keeps scanning its one
  buffer at `fPhys` (0xB8000000, 1080x2412, 4320-byte rows). A copy of 10 MB takes well under
  1 ms on the GPU [I] against a 16.7 ms scan, so a tear line is possible but short-lived. A real
  flip needs the DPU (SM8450 DPU 8.1: SSPP `SRC0_ADDR`/`YSTRIDE0` + CTL flush, as bergamota 0096
  / 0127 did on SDM845) and is not done here: no register of the negroni DPU has been read on
  the hardware yet. Next step: a read-only probe that finds the SSPP whose `SRC0_ADDR` is
  0xB8000000 (Linux `dpu_8_1_sm8450.h`: VIG0-3 at MDP+0x4000..0xa000, DMA0-3 at
  +0x24000..0x2a000, CTL0 at +0x15000; MDP at 0x0ae01000), then two panel buffers and a flip.
- The 4320-byte rows are not a 2D-engine pitch (64-byte units). The copy is two blits: even rows
  and odd rows, each an image of pitch 8640 (135 x 64); an odd row starts 32 bytes into a
  64-byte line, so its blit starts at that line and 8 pixels further right. The source pitch is
  doubled too (a multiple of 128, which A7XX's `SP_PS_2D_SRC_PITCH` wants). The host test
  checks every destination pixel against this model for the real case (1125x2436 surface with
  4544-byte rows, centred crop 22,12 onto the panel) and others.
- Fallbacks to the CPU copy, per layer: GPU not ready/stopped, `negronifb_gpu=0`, surface not
  BGRA or offset/row bytes not 64-byte multiples, mapping failure, both command buffers still
  in flight, four surfaces mapped with copies in flight. A CPU copy over a GPU-written surface
  first waits for its fence (at most 50 ms) and drops the CPU's lines over it; a CPU layer above
  a GPU layer of the same frame waits for that copy. Badges and the clock shift are drawn after
  the GPU copy. Display off waits for the last copy before the fade.
- Up to 4 swap surfaces stay mapped (read-only) in the GPU and retained; the oldest whose copy
  is done makes room. The panel memory is mapped once.

## 4. Integration notes

- **Patch order:** 0230, 0231 apply alone on `base` and in the full name order with every
  patch in `patches/xnu` (0200-0260) using plain `git apply` (checked 2026-10-25). The
  `bsd/conf/files` line and the `NegroniFramebuffer.cpp` defines sit outside the contexts of
  0210/0240 and 0250/0251.
- **IOAcceleratorES (0201):** keep the empty `IOAcceleratorES` with the GPU on. ios-sailfish
  publishes it **with** its working GPU (0166: "no MetalPluginName, so Metal passes over it and
  CA still picks GLES"); without it QuartzCore polls 30 s per process again. 0230/0231 do not
  define that class. If the later Metal path (Turnip + Metal-to-Vulkan) needs a real
  accelerator service instead, the integrator can make `NegroniAccel.cpp` step aside with the
  boot-arg predicate from 0230 (callable at `AppleCLCD` match time, before the GPU ladder):

  ```cpp
  extern "C" bool negroni_gpu_expected(void);   /* bsd/dev/negroni_adreno.c (0230) */
  /* in IOAcceleratorES::start(), first line, only once a real accelerator exists: */
  if (negroni_gpu_expected() && negroni_metal_accelerator_present) { return false; }
  ```

  `negroni_gpu_expected()` is true for `negroniadreno>=22 negroniadreno_keep=1` and
  `negroniadreno_service` not 0. No such hook is needed for the GL path.
- **User space:** `userland/negronigl` (`ngl_abi.h`) matches both ABIs. Use the scalar ABI for
  freedreno GL, the msm ABI for Turnip, and boot with `negronigpu_pool=512` for Turnip
  (HOST_COHERENT memory, `docs/gpu-abi.md` section 6).
- **Boot-args to add to the GPU image** (`config/negroni-ne2211.toml` is the integrator's):
  `negroniadreno=22 negroniadreno_keep=1` (+ `negronigpu_pool=512` for Vulkan tests). Keep
  `negronifb_hz` as it is: GPU frames use `negronifb_gpuhz` (60).
- Not touched: `docs/gpu-plan.md`, `docs/plan.md` (integrator).

## 5. Verification done

- Every changed file syntax-checked (`clang -fsyntax-only`, local Apple clang 21) against the CI
  build tree (`out/kernel/buildtree`, the recorded `.CFLAGS`/`.CXXFLAGS` and CONFIG_DEFINES),
  alone on `base` and with the whole patch set applied: 0 errors. New warnings: none in the new
  lines (the remaining ones are the `IONew`/`OSDefineMetaClassAndStructors` designator warnings
  every IOKit file gets with this clang, and old lines of `negroni_adreno.c`). Script:
  `out/kernel/cc-gpu-kernel/cc.sh <tree> <file>` (iokit and bsd files).
- `tests/gpu-blit-ib-test.c` (host, `cc -std=c11 -Wall -Wextra`): decodes the PM4 stream
  (packet parity), models the 2D engine's addressing and checks every destination pixel, the
  untouched pixels around the rectangle, the A7XX alignment rules and the refused cases. All
  good.
- Register offsets and values were taken from Mesa 25.0.7 (`a6xx.xml`, `adreno_pm4.xml`,
  `fd6_blitter.cc`, `tu_clear_blit.cc`, `freedreno_devices.py` A730 entries) and Linux
  `msm_drm.h`; Turnip's kernel use from `tu_knl_drm_msm.cc` (25.0.7).
- Not done: CI build (xnu-8796 needs Xcode 15), boot, any GPU command beyond the boot ladder.
  The 2D copy, the user submit path and the fence path have never run on the A730.

## 6. Hardware test plan (in this order)

1. GPU image without gl_test or Mesa: `negroniadreno=22 negroniadreno_keep=1`. Expect
   `NEGRONI GPU: the 3D core stays on`, `RedwoodGPU: registered`, no panic for 10 min, the UI
   as before (no GPU-rendered surfaces exist, so every frame takes the CPU path).
2. Same + gl_test (slop's job) or a negronigl test program. Expect `RedwoodGPU: opened by ...`,
   `submission 1: ...`, no panic at 60-70 s. If it still panics: the inference in section 1 is
   wrong; boot once with the program but `negroniadreno_service=0` again, and compare.
3. sweetgl/negronigl in backboardd (GL). Expect `RedwoodGPU: panel memory 0xb8000000 ... at GPU
   address ...`, `RedwoodGPU: present 1: surface N ...` and later `NEGRONI FB: ... frames by the
   GPU, ... by the CPU` with most frames by the GPU. Black or shifted picture: boot with
   `negronifb_gpu=0` (CPU present, same GL rendering) to separate render from present. Odd rows
   wrong or a 32-byte shift on every second row: the odd-row trick (section 3).
   `NEGRONI GPU: no answer for 2 s` or `the ring stays full`: the copy hung the CP; boot with
   `negronifb_gpu=0`.
4. Turnip: add `negronigpu_pool=512`. Expect `RedwoodGPU: write-combined pool 0x980000000..` when
   the service starts. A reset right after the first pool buffer: the range is not usable (Gunyah
   stage 2 or firmware use); try `negronigpu_poolbase=0x9c0000000` once, else run without pool.

## 7. Risks

- The panic cause in section 1 is an inference. If the service's existence alone panics, the
  next bisect step is a RedwoodGPU with `setProperty(kIOUserClientClassKey)` removed.
- 2D engine state left by Mesa's binned (GMEM) rendering: the copy resets the window offsets
  and the CCU to the sysmem layout (A730: color cache at 1 MiB), as Mesa does before its own
  sysmem blits. Other state could still matter; the user submission that follows re-emits its
  own state (Mesa never relies on state across submissions).
- The GPU writes ABL's panel memory through the SMMU with our page tables; the hypervisor
  (Gunyah) stage 2 must allow that range for the GPU's streams [I: it is HLOS display memory].
- The pool range 0x980000000+ is System RAM for Linux and outside Mu's and XNU's maps [V
  device-facts.md, Mu MemoryMapLib], but untested as GPU/CPU write-combined memory under XNU.
- One SMMU context for all clients (no isolation between processes). No GPU reset or recovery
  after a hang.
- `pmap_clear_modify` / `pmap_is_modified` per page at each submit costs CPU time with many
  large cached buffers (Turnip lists every buffer in every submit): another reason for the pool.

## 8. Per-client GPU tables (0233, `negronigpu_pt=1`, default 0)

- Why the CPU switches the tables [I]: Linux (a6xx_set_pagetable) has the CP write TTBR0 with
  `CP_SMMU_TABLE_UPDATE` from the ring. That needs (1) the CP's SMMU aperture on the GPU's context
  bank: a TrustZone call (`qcom_scm_set_gpu_smmu_aperture`, SCM service 0x0c command 0x1b) or a
  firmware default, and Linux's adreno-smmu gives the GPU context bank 0 for it; (2) the hypervisor
  (Gunyah) to let the CP's writes through. Our 3D core runs in context 2 [V: slop NOTES boot 0113,
  "3D core context 2"], context 0 is skipped by `space_pick`, and none of this was tried on the phone.
  The ladder already writes TTBR0 of context 2 from the CPU and reads it back (step 19) [V], so the
  CPU switch uses only proven register access.
- Layout: root entries 0..3 (0..4 GiB) of every client's root point to the kernel's level-2
  tables, made at `gpu_keep` so they never change: ring 0x01000000, SQE, scratch, and the kernel's
  own addresses 0x2000_0000..0x1_0000_0000 (present mappings, present IBs, panel memory). Clients:
  window 0x1_0000_0000 + 16 GiB (SET_IOVA), kernel-chosen 0x10_0000_0000..0x40_0000_0000.
- Switch (`negroni_gpu_vm_switch`, gGPULock held): every fence done (the submitter waits with
  `gpuWait`, which lets the lock go), the ring read to its end (rptr == wptr, 2 ms), then TTBR0 =
  root | context << 48, TLBIASID + TLBSYNC; the next submission starts with `CACHE_INVALIDATE7`
  (UCHE caches by GPU address). One ASID for all tables, so the TLB is flushed at each switch; a
  client's map/unmap flushes it only when its tables are the current ones. The kernel's present IBs
  run under any client's tables (no switch, no wait).
- A TTBR0 that does not read back, or a ring that does not drain after the fences: the GPU is
  declared stopped (no more submissions). A client whose buffers the GPU did not finish keeps its
  tables allocated for good (same rule as the buffers).
- Cost [I]: serialisation at client changes (backboardd + one app: at most a few switches per frame,
  each after the GPU is idle). Default stays 0 until a phone test (section 11) shows it works.

## 9. Zero-copy scanout (0234, `negronifb_zerocopy=1`, default 0)

- Reference: ios-s9 0096 (SDM845 SDE, VIG0/VIG1, slots in the splash region, SwapWait) [V on S9:
  "frames shown zero-copy"], same idea as bergamota 0127/0211.
- SM8450 SDE facts used [V out/live.dts `qcom,mdss_mdp@ae00000`]: MDSS 0x0ae00000 (len 0x84000);
  SSPP VIG0-3 +0x5000/0x7000/0x9000/0xb000, DMA0-3 +0x25000..0x2b000; CTL0-5 +0x16000..0x1b000;
  INTF 1 = DSI; splash region 0xb8000000 size 0x2b00000; apps-SMMU hands off the display stream
  (`qcom,handoff-smrs = <0x2800 0x402>`). Register layout and CTL_FLUSH bits (VIG0 0, VIG1 1, VIG2 2,
  VIG3 18, DMA0 11, DMA1 12, DMA2 24, DMA3 25, CTL 17) from sde_hw_sspp.c / sde_hw_ctl.c [I: from
  memory of the Qualcomm/Linux sources, not from a local copy].
- Boot (always, read only, `negronifb_dpuprobe=0` skips): one log line per SSPP (`NEGRONI FB: DPU
  VIG0 addr ... size ... xy ... stride ...`) and per CTL; the pipe(s) whose SRC0_ADDR is the panel
  memory are ABL's. Expected: one pipe 1080x2412 (or two of 540) at row 0, stride 4320.
- Slots [V log 2026-10-24: backboardd makes two 1125x2436 BGRA framebuffers, bpr 4608, 11239424
  bytes, and swaps them in turn]: 3 slots of 0xb04000 after the panel memory (0xb89f0000..). The
  surfaces are mapped cached in the kernel and in backboardd (RAM XNU does not manage, so no
  alias with the physical aperture).
- Flip: SRC0_ADDR = slot, YSTRIDE0 = 4608, SRC_XY = ABL's + (22,12), then CTL_FLUSH; taken at the
  next frame start (the panel's 120 Hz autorefresh). If the engine does not take a flush within
  100 ms, zero-copy turns itself off and the pipes go back to the panel memory.
- Frames that are not one full-canvas slot layer (several layers, other processes' surfaces) take
  the 0231 GPU copy or the CPU copy; the pipes go back to the panel memory after that copy. Display
  off and a panic (`negroni_fb_panic` from kPEPanicBegin) do the same, so the fade and the panic text
  stay visible.

## 10. Build (round 2)

See the status in `docs/gpu-status.md` and the handoff in `docs/notes.md` (kernel path, patch report).

## 11. Hardware test plan, round 2 (after section 6)

1. Same image, no new boot-args: look for the `NEGRONI FB: DPU ...` lines and `NEGRONI FB: zero-copy
   off (boot-arg ...)`. Check that one or two pipes show `addr 0xb8000000`. Send the lines to the
   kernel agent; if the layout check failed, the line says why.
2. `negronifb_zerocopy=1` (keep `negronifb_noconsole=1`): expect `NEGRONI SURF: 3 display slots`,
   `backboardd create ... slot 0` / `slot 1`, `flip N: slot ... taken after ... us` (< 8400 us). The UI
   must look as before (clock shift included), with no tearing; scroll and check smoothness. Black or
   frozen picture: reboot, boot with `negronifb_zerocopy=0`, report the flip lines.
3. With the GPU (GL) path on as well: `flip N: ... (GPU, ...)` lines; no CPU copies (`frames by the
   CPU` stays low).
4. `negronigpu_pt=1` with the GPU path and a Turnip probe running beside backboardd: expect `the 3D
   core's tables are now a client's` lines, no `SMMU FAULT`, no `table switch failed`. A fault with FAR
   below 0x1_0000_0000: the kernel's part is missing in a client root.
5. Turnip host import: a probe that imports a malloc'd 16 KiB-aligned buffer (0x49), lets the GPU
   write it, CPU_PREP, and checks the bytes.

## 12. Per-second display stats (0252) and the GPU clock vote (0235)

- 0252 (`negronifb_stats`, default 1; `negronifb_stats=0` turns it off): once a second the vsync
  timer (work loop) logs one line and starts all counters again:
  `NEGRONI FB STAT: swaps/s N presents/s N (cpu N gpu N zc N) copy avg/max us N/N late ticks N
  swapwait calls N waited us avg/max N/N timeouts N`.
  - swaps: SwapEnd records from backboardd. presents: frames that got to the panel in that second;
    cpu = `present()` with no GPU copy, gpu = `present()` with a GPU copy (0231), zc = flips (0234).
  - copy avg/max: time of the `present()` call (the CPU memcpy, or the GPU submit and the waits in it).
  - late ticks: vsync timer calls that came more than 1.5 x 8333 us after the call before (the timer
    is re-armed at the end of the handler, so a slow copy makes the next tick late).
  - swapwait: selector 6 calls (`swapWait()`, 0234), the time each one waited, and the calls that
    stopped at the 50 ms limit (`NEGRONI_ZC_WAIT_MS`).
  - The window is the first tick at or after 1 s, so the numbers are per ~1.00 s, not scaled.
- 0235 (`negronigpu_level=N`, default 0): N = 0 keeps the step-17 vote `{0, 1, 1, 3}` (GX level 1 =
  220 MHz, bw level 3). N > 0 (clamped to 12) sends `{0, 1, N, 11}`: GX level N of the perf table
  (0, 220, 285, 317, 350, 421, 492, 545, 599, 640, 734, 791, 818 MHz) and the top bw level of the
  12-level BW table (`bw_level_num - 1` = 11). Same HFI message (id 30, 4 words). Log:
  `NEGRONI ADRENO: GX level N (M MHz), bw level 11`, then the usual `17 HFI GX_BW_PERF_VOTE ack, error 0`.
  [I] Nothing votes again later, so the level stays for the whole boot.

### Test recipe (120 Hz), in this order

Start from the current config args (`config/negroni-ne2211.toml`: `negronifb_noconsole=1
negronifb_hz=120 negronifb_clockshift=100 negroniadreno=22 negroniadreno_keep=1 ...`). Do not change
the config: build a boot image variant with `BOOTARGS_ADD` (scripts/ios16/build.sh).

(a) current args + `negronifb_zerocopy=1`:
    `scripts/bg.sh ios16-zc env IOS16_OUT=out/ios16-zc BOOTARGS_ADD="negronifb_zerocopy=1" scripts/ios16/build.sh`
    Proof (section 9 and 11): `NEGRONI SURF: 3 display slots`, `flip N: slot ... taken after ... us`
    (< 8400 us), `NEGRONI FB: N frames shown zero-copy` every 1000 flips. In the STAT line: `zc` near
    the swaps/s, `cpu` near 0 while the UI is idle or scrolling, `late ticks 0`, swapwait `timeouts 0`
    and waited max < 8.4 ms. `zero-copy off (...)` means the layout check failed: report the line.
(b) (a) + `negronigpu_level=12`:
    `scripts/bg.sh ios16-zc12 env IOS16_OUT=out/ios16-zc12 BOOTARGS_ADD="negronifb_zerocopy=1 negronigpu_level=12" scripts/ios16/build.sh`
    Proof: `NEGRONI ADRENO: GX level 12 (818 MHz), bw level 11` and `17 HFI GX_BW_PERF_VOTE ack,
    error 0`, ladder 22/22 as before. With the GPU (GL/Metal) path on: `gpu`/`zc` rates in the STAT
    line go up toward 120 and copy avg goes down against (a). A GMU error or no ack: boot (a) again.

(c) the CoreAnimation heartbeat (CA ran on 1/60 s quanta: no `IOMFBDisplayRefresh` property; docs/notes.md
    section 15). Try in this order:
    1. env lever on the current kernel, no new image: `scripts/metal/phone-heartbeat.sh on` (backboardd
       `CA_HEARTBEAT_RATE=120` in /System/Library/xpc/launchd.plist), then `scripts/net/ssh-phone.sh reboot`.
       Back: `scripts/metal/phone-heartbeat.sh off` + reboot.
    2. kernel with 0253 (`negronifb_carefresh`, default 1; `=0` for the A/B test): boot line
       `NEGRONI FB: IOMFBDisplayRefresh step N ticks (8333 us)` (N = 8333 us in mach ticks: ~159993 if the timer runs at 19.2 MHz [I]),
       and the vsync notification's interval = the same N.
    Proof for both: the backboardd log line `CoreAnimation: GetDisplayInfo returned ...` (`scripts/net/phone-log.sh -g GetDisplayInfo backboardd`;
    kernel log: make usblog) and the STAT line `swaps/s` going from ~60 toward 120.

Goal: `presents/s` 120 (or equal to `swaps/s` when iOS sends fewer) with `late ticks 0`.

### 0253 (`negronifb_carefresh`, default 1)

`AppleCLCD::start` sets `IOMFBDisplayRefresh` = { `displayRefreshStepMachTime` (OSNumber 64-bit) =
`nanoseconds_to_absolutetime(8333 * 1000)`, `displayMinRefreshInterval` (OSNumber 32-bit) = 1 } beside
`external` and `DisplayPipePlaneBaseAlignment`, before `registerService()`. `vsyncFired` sends
values[4..5] = the same tick count (low, high half) instead of 0. `negronifb_carefresh=0`: no property,
interval 0 (the old behaviour). [I] displayMinRefreshInterval units are unclear (scale 2^-32); CA reads
the step first, so the value 1 matters only if the step is rejected.

### 0254 (fixed-deadline vsync, no GPU wait on the tick, SwapWait without wait)

File name `0254-negroni-fb-present-thread.patch` (the present thread itself is not in it, see the end).
Touches NegroniFramebuffer.cpp, and NegroniGPU.cpp/.h for two read-only questions
(`NegroniGPUFenceCompleted()`, `NegroniGPUClientCloses()`; the GPU's fence bookkeeping is not changed).

Measured before 0254 (phone, 2026-10-25, kernel local-20261025-170531 with 0252) [V]:
- CPU-only boot (no GPU client): `present()` 2.5-3.7 ms avg, 6 ms max per frame; swaps/s up to 81,
  presents/s 37, late ticks 11-13 per second.
- After a Metal client (backboardd) crashed with GPU work pending (`RedwoodGPU: the GPU is not done
  with a buffer ...` for 15+ s), every `present()` took 51 ms (= `NEGRONI_FB_GPU_WAIT_MS` 50 ms + copy),
  sometimes 650-1073 ms; the UI fell to ~1 fps. Cause: `present()` runs in the vsync timer handler
  (`vsyncFired`) and called `NegroniGPUFenceWait(written | fence, 50 ms)` for surfaces with `gpuFence` set;
  the vsync thread blocked, and the timer was re-armed only at the end of the handler.
- `SwapWait` (selector 6) returned at once in the copy modes: CA ran free (81 swaps/s for 37 presents).
- Plugin telemetry (backboardd on Metal, GPU at the 220 MHz vote): commit-to-callback 89 ms .. 14 s per
  command buffer; 13 buffers committed within 200 ms completed one every ~60 ms; RBBM busy all the time.
  So the fences do complete: the GPU is slow, not dead.

CoreAnimation facts [V: disassembly, QuartzCore 20H392, unslid]:
- `CA::WindowServer::IOMFBDisplay::can_update_` (0x1882be944) and `swap_wait_timeout` (0x18853c088):
  SwapWait = selector 6, scalars {swap_id, flags, 0}. Return 0 releases the surface on CA's side (CA
  refcount); any non-zero return keeps it held, and CA retries with usleep(100) for up to 1 ms, or skips
  the frame and tries again at the next heartbeat. It never hangs.
- CA keeps 3 surfaces (1 shown + up to 2 pending, ids in order). CA does not read the IOSurface kernel
  in-use state in the display path: only SwapWait gates it.
- Vsync notification: value 1 = host timestamp (mach ticks), value 2 = interval in mach ticks (0253).
  TimingElements/SyncRate are read only for external displays (not added).

What 0254 does:
1. Fixed-deadline vsync: start() arms `wakeAtTime(now + 8333 us)`; each tick re-arms at the previous
   deadline + 8333 us (`rearm()`), so the period does not depend on the handler's work. A deadline that has
   already passed is skipped to the next future one; each skipped deadline counts as a late tick. A tick
   that starts more than half a period (4167 us) after its deadline also counts (`late ticks` is no longer
   "1.5 periods after the tick before").
2. No GPU wait on the tick: swap() keeps the newest `gpuFence` of the frame's surfaces (`fPendFence`).
   The tick shows the frame only when that fence is done (`NegroniGPUFenceDone`, only asks); if not, the
   record stays pending (`fDirty` set, nothing copied or flipped) and the tick counts a `gpu-wait skip`.
   A GPU copy (0231) is now queued only after the render is done, so the waits left on the tick are for the
   frame's own 2D copy (clock shift, badges, a CPU layer over it, the switch back from zero-copy), at most
   `NEGRONI_FB_GPU_COPY_WAIT_MS` (8 ms). The fade at display off keeps its 50 ms wait.
   Swap-time fences (0254 amendment, 2026-10-25): swap() records each layer's `gpuFence` at SwapEnd
   (`fPendFences`), and present() uses that one, not `s->gpuFence` at copy time. No fence wait is left in
   present() for the CPU copy; `NegroniGPUSurfaceForCPU` (the cache drop) still runs before the memcpy.
   Reason [V phone, first 0254 image]: `cpu 5`/s at 51-54 ms each, because Turnip lists every buffer of the
   device in every submission, so each surface's `gpuFence` always names the newest in-flight work. The
   swap-time fence is enough: CA renders into a surface again only after SwapWait returned 0 for its swap,
   i.e. after we copied it. The 0231 2D copy cannot be queued "behind the swap-time fence" only: the ring is
   in order, so a copy waits behind every newer submission. So a layer whose `s->gpuFence` has moved on and
   is not done goes the CPU way (no GPU copy); with Turnip that is nearly every GPU-written layer [I].
3. Latest wins, without starvation: a newer SwapEnd replaces the pending record, but the first record that
   waits for its fence is kept as the "older" one (`fOld`, copy frames only, not zero-copy). The tick shows
   the newest record whose fence passed: the pending one (the older one is then dropped), else the older
   one (the pending one stays). So a GPU slower than CA (60 ms per frame) still puts frames on screen; the
   lag is the GPU's backlog, not more. Dropped records count as presented once a later id is shown.
4. Give-up (stale fences): the GPU declared stopped (`gGPUStopped`) already answers every fence as done.
   Else a fence is given up only (a) when the oldest fence the tick waits for has been pending for more
   than `NEGRONI_FB_GPU_GIVEUP_MS` (500 ms) since the tick first saw it AND a RedwoodGPU client closed since
   then (`RedwoodGPU: ... closes`), or (b) when the GPU wrote no fence for `NEGRONI_FB_GPU_STUCK_MS`
   (2000 ms, the same as RedwoodGPU's own stop rule) while the tick waited. A slow but alive GPU is waited
   for. A given-up fence covers itself and every older fence (one ring, in order) until the GPU passes it.
   The frame is then copied by the CPU (no GPU copy behind a dead ring), and the log says once per
   surface id: `NEGRONI FB: gave up on fence N of surface M`. Held surfaces whose GPU copy has a given-up
   fence go back to CA too.
5. SwapWait (all modes, not only zero-copy): one non-blocking check, no delay loop. Returns 0 when id is 0,
   the display is off, id > the last SwapEnd id, or `fPresentedID >= id` (that record or a later one was
   copied into the panel memory, or flipped and taken by the engine). Else `kIOReturnBusy` (0xe00002d5) at
   once. The copy path now also moves the id forward when the pipes go back to the panel memory (it waits
   for the engine to take that flush, as zero-copy ids do). The STAT field `timeouts` now counts the busy
   answers, and `waited us` is the time in the call.
6. STAT line: `... timeouts N gpu-wait skips N gave-up N` (the two new fields at the end; the rest
   unchanged). gave-up = frames shown with a given-up fence.

Expected on the phone [I, not booted]: CPU-only boot: `late ticks` near 0 (a slow copy no longer moves
the next deadline), `swaps/s` near `presents/s` (SwapWait now gates CA). Metal client: `gpu-wait skips`
high when the GPU is slow, `present()` copy avg back to the CPU-copy time, no 51 ms presents. A crashed
client: `gave up on fence ...` lines about 0.5 s after the crash only if the GPU stops making progress or
a client closed; never on a slow GPU without a close.

Build (2026-10-25): first version: kernel `out/kernel/local-20261025-173319` (sha256 ee9ac20f...), image
`out/ios16-present` (boot_a af5d91e4...). Amended (swap-time fences): kernel `out/kernel/local-20261025-175017`
(sha256 e51e7339..., 0236 and 0254 applied, 0262 the known skip), image `out/ios16-0254b` (boot_a sha256
20a82fb6..., the config's cmdline, no extra args).
[V] `scripts/bg.sh` does not pass variables set before it into tmux: `IOS16_OUT=x scripts/bg.sh NAME build.sh`
writes into out/ios16. Use `scripts/bg.sh NAME env IOS16_OUT=x BOOTARGS_ADD=... scripts/ios16/build.sh` (the recipe
above is fixed).

Present thread (item 4 of the brief): not done. What it needs: a `thread_call` (or IOWorkLoop of its own)
woken by the tick, which runs present(), keepBusy() and the switch back from zero-copy. Hazards: fBusy,
fLastGPUFence, the 0254 wait state and all zeroCopy* state are "work loop only" today; with a second
thread, the tick's releaseBusy/zeroCopyRetire/flip/fade would race with it, so all of them must move to
that thread or get a lock of their own (not fLock: swap() and SwapWait take fLock and must not wait behind
a 3 ms copy). With 0254 the tick no longer waits for a render, so the copy (2.5-3.7 ms measured) is the
only long work left on the tick, and fixed deadlines keep the period. Do it only if `late ticks` stays
high after 0254.

### 0256 (clock shift after the GPU copy, status-bar rows only; 2026-10-26, display agent)

Symptom (owner's photos, 2026-10-26): fragments of digits left of the lock screen's big clock ("12" twice,
shifted), the date line garbled, top-left of the screen. Boot-arg `negronifb_clockshift=100` is in the
config (slop 0112/0114 `negroni_shift_clock`: the left half of the top rows moved 100 px right, so the
status bar's clock clears the camera hole).

Cause [V code, out/kernel/local tree after 0254]:
1. Since 0231/0254 every frame is a GPU 2D copy into the panel memory (STAT `gpu 40..61`, `cpu 0`, `zc 0`).
   `present()` queued the copy, waited `NegroniGPUFenceWait(fence, 8 ms)` and then ran
   `negroni_shift_clock()` on the panel memory *without looking at the wait's result*. When the copy was
   not done in 8 ms (the ring is in order: Metal's own work from backboardd sits before it), the CPU
   shifted the rows that were still there (the previous frame, already shifted) a second time, and the 2D
   engine then wrote the new frame's rows unshifted over or between them: digits shifted by 100 and 200 px
   next to each other, rows mixed. The panel memory is write-combine (`negroni_surface_create_physical`,
   `kIOMapWriteCombineCache`), so this is not a CPU-cache effect.
2. The strip was 150 panel rows. Panel 1080x2412, logical 1125x2436 at 3x, `fOffY` 12: panel row 150 =
   logical row 162 = 54 pt. The status bar is 44 pt (logical row 132 = panel row 120). Rows 44..54 pt on
   the lock screen hold the top of the date line [I: the date's exact y is not measured], so the shift cut
   and moved it even when the race in (1) did not happen. The lock screen's status bar shows no clock, so
   nothing in the 44 pt strip needs the shift there, and nothing is lost by the smaller strip.

What 0256 does (`0256-negroni-fb-clock-shift-after-gpu.patch`, NegroniFramebuffer.cpp only):
- `NEGRONI_FB_CLOCK_ROWS` 120 (boot-arg `negronifb_clockrows=N`, 1..300, default 120) replaces the
  hard-coded 150 in `negroni_shift_clock`, both `topRedrawn` tests and the zero-copy save/restore
  (`NEGRONI_ZC_CLOCK_ROWS` is gone; `negroni_clock_rows()`).
- `present()`: the shift on a GPU-copied frame runs only when the copy's fence passed inside the 8 ms
  wait. Otherwise the shift is kept (`fShiftFence`, `fShiftPending`) and `shiftTick()` (every vsync tick,
  work loop, after `zeroCopyRetire`) does it once the fence is done. A newer frame that rewrites the top
  (`topRedrawn`) replaces or clears the pending shift (its copy overwrites the strip anyway). CPU-copied
  frames shift at once, as before.
- `negroni_clock_shift_px()` parses `negronifb_clockshift` once, also before the first shift (the old
  code's `negroni_clock_shift > 0` test was false until the first `negroni_shift_clock()` call).
- Log (first 8): `NEGRONI FB: clock shift after fence N (deferred D, done late L)`: D = shifts put off
  because the 8 ms wait timed out, L = shifts done by a later tick. No line at all = every copy passed
  inside the wait (the race of cause 1 never happened in that run, the row cut of cause 2 still did).

Measurement order: (a) `out/ios16-noshift` (kernel local-20261025-214340, `BOOTARGS_DROP="negronifb_clockshift="`):
no shift at all; the fragments must be gone and the status bar's clock sits under the camera hole.
(b) `out/ios16-0256` (kernel with 0256, config args): fragments gone, clock clear of the hole, date whole.
If (b) still shows fragments with no `clock shift after fence` lines, the cause is not the shift race:
look at the 2D copy itself (0231) or at the renderer.

Build (2026-10-26 03:22): kernel `out/kernel/local-20261025-215209` (sha256 449a5d18..., 0256 applied, the 4
usual dxb skips), image `out/ios16-0256` (boot_a sha256 57c6cc5a..., config cmdline). Control image `out/ios16-noshift`
(boot_a a3d456cf..., kernel local-20261025-214340, no `negronifb_clockshift`). Not flashed: the phone was in a
brownout reboot loop (empty battery) when they were built.

### 0257: IOSurface wrap of client memory (selectors 6 and 7)

Cause (docs/notes.md 15a, 2026-10-25 23:46): CoreAnimation's GL renderer wraps a page-aligned CPU
image with `IOSurfaceWrapClientImage` (`CA::Render::Image::retain_iosurface`). IOSurface.framework
calls IOSurfaceRoot selector 6 (WrapClientImage) or 7 (WrapClientMemory) and expects the lock result
(0xa68 bytes, the same struct selectors 0/4/34 answer). The slop 0046 user client sent 6 and 7 to its
default case: success with a zeroed struct. The framework then built a client with id 0, size 0 and
a NULL state page, and `IOSurfaceClientGetBulkAttachments` crashed backboardd (far 0x30).

Input layouts [V, out/gpu/re/IOSurface.s `_IOSurfaceClientWrapClientImage` 0x1a3986580 and
`_IOSurfaceClientWrapClientMemory` 0x1a3986834, 20H392]:
- Selector 6: struct input of 0x20 bytes, no scalars: `+0 u64 address` (x5), `+8 u32 width` (w0),
  `+0xc u32 height` (w1), `+0x10 u32 pixel format` (w2), `+0x14 u32 bytes per element` (w8: the framework
  derives it from the format by a table: 1, 2, 4, 8 or 16; 'BGRA' = 4 [V], 'RGfA' = 16 [I]), `+0x18 u32 bytes
  per row` (w3), `+0x1c u32` (w4, passed through; unused here). Output: lock result, 0xa68 bytes.
- Selector 7: two scalars `address, size`, no struct input. Output: lock result, 0xa68 bytes.
- On a non-zero return the framework returns NULL at once (no trap, no client). On success it builds
  the client (`_ioSurfaceClientCreateWithLockResult`); if that fails it calls trap 5 (release failed)
  with the id at lock result +0x18.
Same layouts in bergamota `0120-topaz-sweetsurface-client-memory.patch` (ios-spes NOTES.md "unhandled
IOSurface selector 6").

What 0257 does (`0257-negroni-iosurface-wrap-client-memory.patch`, NegroniSurface.cpp/.h):
- `wrapClient()` parses the input as above, requires address != 0 and page-aligned, size (bpr x height
  for 6) 1..256 MiB, width/height 1..16384, bpe 1..64, bpr >= width x bpe. The range is wrapped like the
  GPU host import of 0232: `IOMemoryDescriptor::withAddressRange(address, round_page(size), InOut, task)`
  + `prepare()` (wired for the surface's life; a second try with `kIODirectionOut` for read-only pages),
  `complete()`d in `NegroniSurface::free()` (`wrapped`). The surface is published with a new id, geometry
  from the input (sel 7: width = size, height 1, bpe 1, bpr = size, format 0), offset 0, no planes, and
  answered with `returnSurface()`: the same lock result as a created surface (pixels mapped into the
  task at a new address, state page, id, seed).
- Cache: `mapCache` = default (cached) and `kernelMapCache` = copyback like backboardd's slot surfaces:
  the CPU wrote the pixels; the framebuffer and the GPU paths clean cached surfaces before a read.
  Not counted in `negroni_surface_wired` (the pages belong to the task).
- Input the driver cannot use returns `kIOReturnUnsupported` (bad size/count, geometry, address, alignment),
  `kIOReturnVMError` when the range cannot be wired, `kIOReturnNoMemory` / `kIOReturnNoResources` for the
  surface object / id: never success with a zeroed struct. The framework then returns NULL and
  `retain_iosurface` keeps the image without an IOSurface (the path the eagl.c guard forced).
- The default case is unchanged (other unknown selectors still get a zeroed success).
- Log: once per selector `NEGRONI SURF: wrap client memory sel N: WxH bpr B fmt F -> id I (proc, bytes)`,
  once per failure kind `NEGRONI SURF: wrap client memory sel N refused: WHY (proc, in X bytes, Y scalars)
  -> 0x...`, plus the usual `NEGRONI SURF: proc sel 6`.

Build (2026-10-26 06:16, full patch set, the 4 usual dxb skips): kernel `out/kernel/local-20261026-061605`
(sha256 1e3bff08aa9d2483d0d7c39785c1af38502e383b0cc582070d1b52c0b942f023, 0257 applied), image `out/ios16-0257`
(boot_a 315fe41507b22b47fbe6b7a98fe85761c054bf8608dc51df3021e56d693ad7e8, same cmdline as `out/ios16-0256`).
Not flashed: the phone was off (flat battery).

Test (GL path, phone on): `scripts/gpu/phone-gl.sh backboardd`, `on`, `restart`. Pass: a `wrap client memory
sel 6` line, no `negronigl: IOSurface wrap of client memory refused` line (userland/negronigl/eagl.c, the
guard stays in as a fallback) and no backboardd crash with far 0x30.

### 0289: the IOSurface CPU lock waits for the surface's GPU fence (`RedwoodWaitsForGPU`)

Gap (docs/audit/2026-10-26-metal-gl.md section 2.3, notes.md 15a): a CPU reader of a GPU-written surface
(`IOSurfaceLock` + read: a snapshot, CoreAnimation's CPU fallback, a CPU-composited backboardd sampling an
app's surface) got the lock at once and could read stale pixels: 0230 marks the surface with the submission's
fence and 0254 waits on it for the present path only; the lock trap answered without a wait, and the CPU's
cached lines of a cached mapping were not dropped (`NegroniGPUSurfaceForCPU` ran for the present copy only).
The GL library therefore defaulted to `glFlush` on trust alone, with `phone-gl.sh finish on` as the safe setting.

What 0289 does (`0289-negroni-iosurface-lock-gpu-wait.patch`; NegroniSurface.cpp/.h, NegroniGPU.cpp/.h):
- `negroni_surface_wait_gpu()` before `trapLock` answers: when the surface's `gpuFence` is not 0 and differs from
  `cpuSeenFence` (new field: the fence the lock last handled), `NegroniGPUFenceWait(fence, ms)` with
  `ms = NegroniGPUSurfaceWaitMS()` (boot-arg `negronisurf_gpuwait`, default `NEGRONI_SURFACE_GPU_WAIT_MS` = 50 like
  the framebuffer's bound, capped at 2000; 0 = the lock never waits). `gpuWait` gives up at once when `gGPUStopped`
  (and marks the GPU stopped itself after 2 s without progress), so a dead GPU costs one bounded wait, not a hang.
  A wait that runs out is logged 8 times (`NEGRONI SURF: <proc> lock of surface N: the GPU (fence F) is not done
  after 50 ms: answered anyway`) and the lock is answered anyway (never a failure: IOSurface.framework treats a
  non-zero return as a broken surface).
- Then `NegroniGPUSurfaceForCPU(s, 0, allocSize)` when `mapCache != kIOMapWriteCombineCache` (slot, wrapped and
  physical surfaces: cached user mappings; the created surfaces are write-combined, so nothing to drop), and
  `cpuSeenFence = fence`: a Metal process's seed-bump locks after every completed command buffer (flame/0002) cost
  one fence compare each, not a page walk.
- `RedwoodGPU::start` publishes `RedwoodWaitsForGPU` (kOSBooleanTrue unless the boot-arg is 0) and logs
  `RedwoodGPU: registered (the IOSurface lock waits up to 50 ms for the GPU)`. User space: `userland/negronigl/view.c`
  reads it once per process (`ngl_drm_kernel_waits_for_gpu`, negroni_drm.c) and uses `glFinish` without it.
- The unlock trap is unchanged (the CPU wrote; the GPU side cleans before it reads, 0232/0257).

Build (2026-10-26 12:31, full patch set, 197 applied, the 4 usual dxb skips): kernel `out/kernel/local-20261026-123128`
(sha256 151428d32eeacf2f9c66930009d637796427acf11abc6bde3769513a16d80513), image `out/ios16-gl2` (boot_a sha256
78c2325993709739bc92c4cdb1be9dd334f34676888c7e0f739e8d857f1cc4b2, esp 851a6735..., vendor_boot c29329ee...; config
boot-args + `negronipanic=30 negronipanicreason=2`; `scripts/gpu/build-test-image.sh`). Not booted (the phone runs Android).

Test (phone on `out/ios16-gl2`): `make usblog` must show `RedwoodGPU: registered (the IOSurface lock waits up to 50 ms
for the GPU)`; `ioreg -l | grep RedwoodWaitsForGPU` over SSH shows `Yes`; with the 2026-10-26 GL stage pushed,
`scripts/gpu/phone-gl.sh test` logs `negronigl: flush = glFlush + kernel fence (default: RedwoodWaitsForGPU)`. A
`NEGRONI SURF: ... not done after 50 ms` line names a CPU reader that locks a surface while the GPU is still on it
(expected rarely: a screenshot during a long frame). `negronisurf_gpuwait=0` is the A/B switch (property false,
the GL library falls back to glFinish).

## 13. ios-spes deltas (kernel work the GL path needs; plan only, nothing built here)

Reference: `external/ios-spes` (SM6225, A610, same 20H392 root). Its UI runs on GL at a frame median of
10.8 ms (all12) after these kernel changes. We have the equivalents of some of them (0231 GPU present,
0234 zero-copy flip, 0235 clock vote); the rest is listed for the kernel agent, with the spes file:line.

1. **Swap backpressure + per-surface fence before present** (spes 0102 `0102-spes-gpu-queued-submissions.patch`:
   SweetFramebuffer.cpp hunks at `swap()` and `present()`, SweetSurface.h `drawn` field + `SweetSurfaceDrawn()`).
   `swap()` holds the client while the last frame is not shown yet (1 s limit, then the frame is replaced);
   `present()` checks every layer's `drawn` fence (500 ms), keeps the swap pending when the GPU is not done
   and gives up after 10 misses. The surface gets `drawn` = the fence of the last submission that names it
   (RedwoodGPU.cpp submit path). Ours: 0231 holds presented surfaces until `gpuFence` (keepBusy) but
   `present()` does not wait for the client's own render fence; the user-space shim does `glFinish` on every
   flush instead (eagl.c ngl_h_Flush). Delta: record the submit fence per imported surface (import 0x7e), wait
   on it in `present()` (NegroniFramebuffer.cpp, the 0254 file: coordinate with that agent), and set the
   property `RedwoodWaitsForGPU = true` on AppleCLCD (spes 0102 line "setProperty(\"RedwoodWaitsForGPU\"") so
   the shim can drop the `glFinish` (HackiOS eagl.c `display_waits()`; our eagl.c must read it).
2. **Queued submissions: the caller waits for ring space, not for the GPU** (spes 0102, RedwoodGPU.cpp part;
   README "0100/0102"). Submit returns after the ring write; completion is a fence the CPU reads. Our scalar
   ABI already returns a fence sequence (docs/gpu-abi.md); check that `submit` does not wait for idle, and
   that `wait` has a bounded timeout and logs `newest/completed/rptr/tail` like spes's
   "GPU not done with surface %u after 500 ms: fence %u, newest %u, completed %u, rptr %u, tail %u".
3. **Presenter thread with frame backpressure** (spes 0105 `0105-spes-retained-frame-presenter.patch`:
   `presenterMain`/`presenter()`, `fPendingSurfaces[]` retained through presentation, `kernel_thread_start` in
   `start()`). Frames are copied/flipped on their own thread, not on the vsync timer; the pending swap's
   surfaces stay retained until shown. Ours copies in the work-loop vsync handler (0252 "late ticks" shows
   the cost). Delta: move `present()` to a thread; keep the STAT counters.
4. **Direct MDP scanout, spes form** (spes 0109 `0109-spes-mdp-direct-scanout.patch`: `SWEET_MDP_VIG0`,
   `SWEET_MDP_CTL0`, `SRC0_ADDR` +0x14, `YSTRIDE0` +0x24, `CTL_FLUSH` +0x18 = 0x20001 (VIG0 + CTL); gate
   "VIG0 was found scanning our boot framebuffer"; `sweetfb_direct=0`; 0116 `0116-spes-scanout-pool.patch`:
   fixed pool 12 x 16 MB slots, slot 11 = black frame; 0124: a frame that copied nothing leaves the pipe;
   0112: display off = flip to the black slot). Ours (0234) is the same idea on SM8450 (VIG0 +0x5000 from
   MDSS 0x0ae00000, CTL0 +0x16000, 3 slots after the panel memory, `negronifb_zerocopy=1`, untested). Deltas
   to take from spes: (a) the pool with a black slot for display off and panic, (b) "a copied frame that
   copied nothing leaves the pipe where it is" (0124), (c) only `SRC0_ADDR` + `YSTRIDE0` + `CTL_FLUSH` are
   written, no `SRC_XY` change (we add (22,12): keep ours, the clock shift needs it), (d) the 100 ms
   "flush not taken" self-disable we already have; spes has none.
5. **GPU clock** (spes 0097 `spes_gpu_power_probe` read-only inventory of GPUCC 0x05990000; 0107: GFX RCG
   `cfg = 0x503` = GPLL0 source 5, divider /2, nominal 300 MHz, GCC vote bit 15 at 0x79004, boot-arg
   `spesgpu_mhz=19|300`; 0120/0127 cpufreq max/step). A610 has no GMU; ours votes through the GMU/HFI (0235
   `negronigpu_level=N`, 220..818 MHz). No delta: test 0235 at level 12 first (section 12 (b)). spes's lesson
   that applies: log the selected clock as a config value "not a frequency measurement".
6. **GPU VA size** (spes NOTES all11: `RedwoodGPU: no addresses left` -> `glFlush: error 0x505`; fixed by 512
   MiB VA with 2048 slots). Check our per-client VA window (0233) is >= 512 MiB and that a full window logs a
   clear line, not a silent GL_OUT_OF_MEMORY.
7. **IOSurface release semantics** (spes 0108: trap 4 detaches, trap 5 releases; 0118: zombies drop their
   surface; app icons appeared after 0108). Ours: 0230 import by ID; check that a client's exit releases
   imported GEMs and that detach does not free a surface another process still shows (the "surface leak,
   0xe00002bd x1872" freeze in spes all4).
8. **Not GL, summary only** (no port planned here): 0113 `0113-spes-wifi-en0-apple80211.patch` (2326 lines):
   en0 + Apple80211 for wifid from Topaz 0900 / HackiOS darwin-redwood (`bsd/dev/redwood_apple80211.c`,
   `redwood_net.c`, `redwood_sta.c`, `spes_sta.c` glue onto the `spes_wlan_*` radio API), AKS key wrap in
   SweetKeyStore.cpp for keychain items, per-phone MAC from boot-arg `wlan_mac`. Our Wi-Fi work (notes
   section 16, QCA6490 over MHI) would reuse the Apple80211/en0 half once a radio API exists. 0114
   `0114-spes-vibrator-probe.patch` (97 lines): `spesvib=1` raises the vibrator enable GPIO (TLMM 36) for
   300 ms from `bsd/dev/spes_vib.c` to learn whether the PMIC LPG PWM is needed; a first-look probe, not a
   driver.

## 14. GPU clock (0236, `negronigpu_clkdump` / `_gxclk` / `_timetest` / `_revote`)

### Facts before 0236
- [V phone 2026-10-25] One CoreAnimation frame through Turnip costs the GPU ~60 ms at GX level 1
  (220 MHz, bw 3) and at level 12 (818 MHz, bw 11, `17 HFI GX_BW_PERF_VOTE ack, error 0`). Throughput per
  command buffer is ~45-100 Mpx/s, near what an A730 at the 19.2 MHz XO would do.
- [V code] The GPU WATCH words `CX` / `GX` are GDSC power registers (`GPUCC_CX_GDSCR` gpucc+0x9108,
  `GPUCC_GX_GDSCR` gpucc+0x905c), not clocks. Before 0236 the driver never read a GX clock or PLL.
- [V code] Perf table: GX `{vote = (rpmh level << 16) | (mx index << 8) | gfx index, acd 0xffffffff, MHz}`
  for 0, 220, 285, 317, 350, 421, 492, 545, 599, 640, 734, 791, 818 MHz; GMU 200/500 MHz.
- [V code] The cmd-db level arrays were 16 u16 (32 bytes). "gfx top 0" in the step-17 line is padding.
- [V code] Step 17 sends GX_BW_PERF_VOTE (HFI 30) BEFORE the OOB GPU_SET of step 18, and never again.
- [V code] The driver programs only the GMU and HUB RCGs (gpucc 0x9318, 0x93ec). It never touches a
  GFX3D RCG or a GPU PLL. gpucc (0x03d90000, 0xa000) is mapped.
- [V code] Every submit ends with CCU invalidates + CACHE_CLEAN fences + CP_WAIT_TIMESTAMP (0231).
- Reference [V apollo, external/ios-apollo/NOTES.md:33]: A650 printed `pll0 mode 0xd9000005 L 0x1f`
  (0x1f x 19.2 = 595 MHz) from gpucc PLL0.

### What 0236 prints
1. `negronigpu_clkdump` (default 1). At the end of step 17, after the step-18 OOB GPU_SET ack, and after a
   revote (3):
   - `NEGRONI ADRENO: N clock dump <when>: GX GDSC %x, PLL0 mode %x L %x alpha %x, PLL1 mode %x L %x alpha %x`
   - `NEGRONI ADRENO: gpucc[0x0] = ...`, `gpucc[0x20]` (PLL0 +0x0..0x40), `gpucc[0x1000]`, `gpucc[0x1020]`
     (PLL1), `gpucc[0x9000]` .. `gpucc[0x90e0]` (GX branch/RCG area), 8 dwords per line.
   - `NEGRONI ADRENO: N GMU log head: <16 dwords>` (the watch reads dword 0 only).
   - Step 17 also prints `17 cmd-db gfx.lvl raw B bytes, N levels: ...` (same for mx.lvl, cx.lvl): the raw
     aux length and every level. The arrays now hold 32 entries; the votes still use the first 16, so the
     vote math is the same as before.
2. `negronigpu_gxclk` (default 1). CP perf counter 0 = `PERF_CP_ALWAYS_COUNT` (counts every CP clock),
   `RBBM_PERFCTR_CNTL` = 1, programmed after the OOB ack (step 18) and again after CP_ME_INIT (step 20).
   Each measurement is 10 ms of CPU delay:
   `NEGRONI ADRENO: 18 gxclk N MHz after the OOB GPU_SET ack (CP cycles +C in AO ticks +T, SEL0 .., PERFCTR_CNTL ..)`,
   the same `after the revote` and `20 gxclk N MHz with the CP running`. The watch line ends with
   `| gxclk N MHz`: CP cycles / GMU AO ticks x 19.2 since the last printed line (0 = GX off, first line, or
   the counter went back). Every read is behind the GX GDSC PWR_ON check.
   Registers (mesa `src/freedreno/registers/adreno/a6xx.xml`): `CP_PERFCTR_CP_SEL[0]` 0x08d0,
   `RBBM_PERFCTR_CP[0]` 0x0300/0x0301 (A7XX-; A6XX uses 0x0400), `RBBM_PERFCTR_CNTL` 0x0500,
   `CP_ALWAYS_ON_COUNTER` 0x0980 (reg64), `A7XX_PERF_CP_ALWAYS_COUNT` 0; GMU AO `GMU_ALWAYS_ON_COUNTER_L/H`
   (a6xx_gmu.xml 0x5088/0x5089 = GPU dword 0x1f888/0x1f889). [I] Linux a6xx_hw_init selects CP0 =
   ALWAYS_COUNT and a7xx_submit samples `RBBM_PERFCTR_CP(0)` + `CP_ALWAYS_ON_COUNTER` the same way; [I] the
   CP clock is the GX core clock; [I] both AO counters run at 19.2 MHz.
3. `negronigpu_revote` (default 1 when `negronigpu_level` > 0, else 0). After the OOB GPU_SET ack: the same
   `{0, 1, level, bw}` again:
   `NEGRONI ADRENO: 18 GX_BW_PERF_VOTE again after GPU_SET: level L (M MHz), bw level B`,
   `17 HFI send GX_BW_PERF_VOTE ...`, `17 HFI GX_BW_PERF_VOTE ack, error E`, `18 revote acked, error 0` (or
   `NOT ACKED or error (going on)`: the ladder goes on), then dump (1) and a measurement (2) again.
   Step 17's vote is unchanged.
4. `negronigpu_timetest` (default 1). Step 22 brackets its 1080x2400 three-band fill with CP_REG_TO_MEM
   (opcode 0x3e, CNT 2, 64B) of `CP_ALWAYS_ON_COUNTER` and `RBBM_PERFCTR_CP[0]` into the scratch page
   (+0x300..+0x320):
   `NEGRONI ADRENO: 22 blit 2.5 Mpx in N us (AO ticks M), CP cycles C (F MHz); raw AO ..`.
   (2.592 Mpx; the integer print says 2.5.) Expect ~1.5 ms at 220 MHz, ~0.4 ms at 818 MHz, ~17 ms at 19.2 MHz.

5. Late copy from the watch (once, at the first watch second >= 5; the USB console attaches only at step 21,
   so the step-17/18 lines above are not on USB). Behind `negronigpu_clkdump`: the clock dump again
   (`22 clock dump from the watch (late copy): ...`, `gpucc[..]`, `GMU log head`), `late 17 cmd-db <name> ...`
   (cached), `late 17 vote {0, 1, L, B} (negronigpu_level N, M MHz): <ack>; 18 revote (on|off): <ack>`,
   `late HFI queue 0..2: status .. size .. read .. write .. dropped ..`, `late HFI debug queue[0..] = <8 dwords>`
   (up to 32 dwords below its write index), `late HFI F2H messages read: N`, and `late F2H i: id I hdr ..` (the
   last 16 F2H messages hfi_send read; id 100 = F2H_MSG_ERROR). Behind `negronigpu_revote`: `late
   GX_BW_PERF_VOTE a third time (CP running): ...`, `late third vote acked, error 0`, then after 100 ms
   `22 gxclk N MHz 100 ms after the third vote (...)` and `22 clock dump after the third vote: ...`.

### Phone result, first boot of 0236 (2026-10-25, `out/ios16-clk`, level 12 + revote)
- [V] `20 gxclk 5 MHz with the CP running (CP cycles +57413 in AO ticks +211648)`; `22 blit 2.5 Mpx in 31943 us
  ... (5 MHz)`; the watch says `gxclk 5 MHz` every 10 s. The GX core clock is near 5 MHz; the vote does not get
  to it. The step-17/18 lines were lost (USB log starts at step 21): item 5 repeats them.
- [I] 5 MHz is below XO (19.2 MHz): the GX clock is a divided source, or PERF_CP_ALWAYS_COUNT counts a
  slower clock than the core clock. The blit time (32 ms) agrees with a slow clock, not with a counter error.

### How to read them
- PLL L value x 19.2 MHz (+ alpha/65536 x 19.2) = the PLL output [I Lucid EVO layout: +0 MODE (bit 31 lock
  det, bit 0 output enable), +4 L, +8 ALPHA]. PLL0 L 0 or mode bit 0 clear = the GX PLL does not run.
- `gxclk` near 19 MHz with a level-12 vote = the GX clock stays on XO: the vote does not reach the clock.
  `gxclk` near the voted MHz but a slow blit = the clock is right and the cost is elsewhere (the fences and
  the cache cleans of each submit, memory bandwidth, Turnip).
- Compare `18 gxclk ... after the OOB GPU_SET ack` with `... after the revote`: if only the revote raises it,
  the vote order (step 17 before GPU_SET) is the bug. Keep `negronigpu_revote=1` then.
- `22 blit` gives the GPU-side time without the CPU poll loop of `ring_run`. Its `F MHz` must agree with
  `gxclk`; if it does not, one of the counters is not what the [I] items above say.
- `gpucc[0x9000..]` before / after GPU_SET: an RCG CFG word that changes source bits [10:8] shows the
  GMU switching the GX source. No change at all = the GMU does not program the GX RCG.

### Fallback (not in 0236): CPU-side GX clock
If `gxclk` stays at ~19 MHz after the revote: program the GX clock from the CPU, as spes 0107 does on A610
(no GMU there). Needed: (a) PLL0 configure + enable: L, ALPHA, USER_CTL, CONFIG_CTL(_U/_U1), TEST_CTL, then
MODE (reset/bypass/output bits, wait LOCK_DET bit 31) (Linux `clk_lucid_evo_pll_configure`, gpucc-sm8450.c
`gpu_cc_pll0_config`); (b) the GX GFX3D RCG: CFG source = PLL0 out, divider, then CMD_RCGR UPDATE; (c) the GX
GFX3D branch CBCR enable; (d) the matching RPMh gfx/mx corner (else the clock outruns the rail voltage).
[I] Offsets for (b)/(c) on SM8450 are not known yet: the 0236 dump of gpucc 0x9000..0x9100 is the first
place to find them. Conflict: on GMU parts (A6xx non-legacy, A7xx) the GMU firmware owns GX power and clock
(GDSC through OOB GPU_SET, DCVS through HFI). A CPU write races the GMU: the GMU can reprogram or gate GX on
IFPC/slumber, and a frequency the GMU does not know breaks its ACD and its RPMh votes. So the CPU path is
only a test (fixed level, IFPC off), not a driver.

### 0237: PERF_TABLE frequencies in kHz

The GMU takes the GX and CX frequencies of the HFI PERF_TABLE in kHz (Linux `a6xx_hfi_send_perf_table`:
`gpu_freqs[i] / 1000` from Hz). Before 0237 the table held MHz (`gpu_khz[i] / 1000`), so every vote asked for
a sub-MHz clock: the 0236 probe measured `gxclk 5 MHz`, PLL0 L 13 at levels 1 and 12, a 2.5 Mpx blit in 32 ms.
Proof after 0237 (`make usblog`): `20 gxclk N MHz with the CP running` near the voted level, `22 blit 2.5 Mpx in`
about 1500 us at 220 MHz / 400 us at 818 MHz, and the clock dump's PLL0 L field (= MHz / 19.2).

## 15. GPU DCVS (0281) and thermal caps (0280)

See `README-thermal.md`. 0281 turns the fixed level-12 vote into a busy-based governor on the watch
thread (idle 500 ms -> level 4, busy 200 ms -> one level up, max `negronigpu_level`, thermal cap from
0280). `negronigpu_dcvs=0` restores the 0235 behaviour.

## 16. GPU power: IFPC and slumber (0285, `negronigpu_ifpc` / `negronigpu_slumber`)

Symptom (owner, 2026-10-26): with Metal on, the GPU runs hot and drains the battery.
Cause [V code, after 0281]: the GMU starts once; OOB GPU_SET is set at step 18 and never cleared
(`negroniadreno_keep=1`); 0281 only lowers the GX clock to level 4 (350 MHz) after 500 ms idle. So the GX
rail and GDSC stay on for the whole boot: no IFPC, no slumber, no GX collapse.

### What KGSL does (out/src/op-kernel/drivers/gpu/msm, the OnePlus gen7 driver) [V]
- IFPC on gen7 is an HFI feature, not a register: `gen7_hfi_send_ifpc_feature_ctrl` sends
  `FEATURE_CTRL {HFI_FEATURE_IFPC 9, enable 1, data 0x1680}` (adreno_gen7_hfi.c:563-570), in `gen7_hfi_start`
  after the perf/bw tables and ACD/BCL, before CORE_FW_START (adreno_gen7_hfi.c:573-620). `gen7_gmu_power_config`
  writes no `PWR_COL_INTER_FRAME_CTRL/_HYST` (adreno_gen7_gmu.c:224-232; the offsets 0x1f8c0/0x1f8c1 exist in
  gen7_reg.h:1112-1113 but only the a6xx driver writes them). H2F ids: FEATURE_CTRL 11, PREPARE_SLUMBER 33
  (adreno_hfi.h:416, 423); `hfi_feature_ctrl_cmd {hdr, feature, enable, data}`, `hfi_prep_slumber_cmd {hdr, bw,
  freq}` (adreno_hfi.h:540-545, 646-650). HFI minor >= 5 acks with result in word 2 and `gmu_ret_type` in word 3
  (adreno_gen7_hfi.c:383-414).
- The CP needs the power-up register list for IFPC: `gen7_cp_init_cmds` sets ME_INIT mask BIT(8) and gives the
  list address and BIT(31) (dynamic triplets) (adreno_gen7.c:101-147); `gen7_patch_pwrup_reglist` fills it with
  the current values of `gen7_ifpc_pwrup_reglist` and `gen7_pwrup_reglist` plus the triplet
  `{PIPE_NONE, RBBM_PERFCTR_CNTL, 1}` (adreno_gen7.c:23-88, 302-350); header `struct cpu_gpu_lock`
  (kgsl_util.h:37-52).
- OOB: `set = BIT(30 - 2 req)`, `ack = BIT(31 - req)`, `clear = BIT(31 - 2 req)`; oob_gpu 0, oob_perfcntr 1
  (adreno_gen7_gmu.c:532-589, kgsl_gmu_core.h:55-61). `gen7_gpu_boot` sets oob_gpu, starts the GPU and CLEARS it
  at its end (adreno_gen7_gmu.c:2589-2650): with IFPC the GMU then collapses GX by itself.
- Per submission: no OOB. The ring brackets the work with `CP_SET_MARKER 0x101` / `0x100` (IFPC disable/enable,
  adreno_gen7_ringbuffer.c:282-283, 408-409) and writes CP_RB_WPTR with `gen7_fenced_write`: write, read
  `GMU_AHB_FENCE_STATUS` (0x23b13) bit 0 (write dropped), 10 us, write again, up to 200 times
  (adreno_gen7_ringbuffer.c:177-181, adreno_gen7.c:150-196, kgsl_gmu_core.h:82-93).
- Slumber: `gen7_power_off` = oob_gpu set, ..., oob_gpu clear (adreno_gen7_gmu.c:2795-2833), then
  `gen7_gmu_power_off` = wait for the lowest idle level, RPMh votes done, `gen7_gmu_notify_slumber`
  (PREPARE_SLUMBER, fence to ALLOW), `gen7_gmu_wait_for_idle` (`GPU_CX_BUSY_STATUS` 0x23b0c bit 30 = 0),
  `gen7_rscc_sleep_sequence` (CM3_SYSRESET 1, RSCC_CONTROL_REQ bit 0, RSC_STATUS0 bit 16, REQ 0), GBIF halt, HFI
  stop, clocks and CX off (adreno_gen7_gmu.c:2513-2560, 1424-1448, 779-800, 365-400).
- Wake from slumber is a warm boot, not an OOB: `gen7_gmu_boot` = CX/clocks, `gen7_rscc_wakeup_sequence`
  (RSCC_CONTROL_REQ bit 1, ACK bit 1, SEQ_BUSY 0), firmware load, register config, CM3 start, HFI start with the
  tables again (adreno_gen7_gmu.c:1871-1925, 330-361; adreno_gen7_hfi.c:573-640); then `gen7_gpu_boot` = oob_gpu,
  H2F START, `gen7_start` (all GX registers), `gen7_rb_start` (RB, SQE, ME_INIT, CP_SET_SECURE_MODE 0; the zap
  shader is loaded only once) (adreno_gen7.c:718-805). The brief's "OOB GPU_SET + wait GX on" alone cannot wake
  it: after the RSC sleep the CM3 is in reset and does not answer an OOB.
- Idle levels: `GPU_GMU_CX_GMU_RPMH_POWER_STATE` (0x1f8ec) 0 active, 3 IFPC, 0xf slumber (kgsl_gmu_core.h:72-74);
  `GMU_GFX_PWR_CLK_STATUS` (0x1f8d0) bit 0 GX GDSC off, bit 1 GX clock off (adreno_gen7_gmu.c:673-683).

### What 0285 does (`0285-negroni-gpu-power-collapse.patch`, negroni_adreno.c only)
1. `negronigpu_ifpc` (default 1). Step 17 sends FEATURE_CTRL IFPC (0x1680 = 5760 XO ticks = 300 us) after
   BW_TABLE, before CORE_FW_START. Accepted = acked with word 2 = 0 and (when the ack has 4 words) word 3 = 0.
   Step 20 then builds the power-up list in the scratch page at +0x400 (53 IFPC pairs + 17 pairs + 1 triplet,
   588 bytes, values read back after step 20's writes) and sends ME_INIT with BIT(8), the list address and
   BIT(31). Refused: ME_INIT as before (no list).
2. After step 22 (`gpu_keep` -> `pm_start`): IFPC accepted -> mode `ifpc`: OOB GPU_SET is cleared (as
   gen7_gpu_boot). From then on the CPU never reads a collapsed GX:
   - CP_RB_WPTR: the KGSL fenced write (200 x 10 us). Still dropped: OOB GPU_SET set, write, clear; still lost:
     submit returns 0 (RedwoodGPU stops, see risks).
   - Ring room: from the newest fence the core wrote (`fence_pos[fence & 255]` = ring position after that
     fence's write), not from CP_RB_RPTR.
   - Table switch (`negronigpu_pt=1`), `negroni_gpu_report`, the WATCH line's GX words and the 5 s late clock
     report: GX GDSC off = ring read to its end, no read; GX on = held with OOB PERFCNTR (set bit 28, ack bit 30,
     clear bit 29) for the reads.
   - DCVS busy = a fence not yet written (no RBBM_STATUS read); votes go to the GMU also while GX is collapsed.
3. IFPC refused or `negronigpu_ifpc=0`, `negronigpu_slumber=1` (default) -> mode `slumber`: OOB GPU_SET stays
   held while awake. The watch thread, 2000 ms after the last submission with every fence done, the ring read to
   its end and RBBM idle: OOB GPU_SET clear, PREPARE_SLUMBER `{0, 0, 0}` (as gpu_stop), fence ALLOW, wait GMU
   idle (bit 30) and GX GDSC off (100 ms each), GMU interrupts masked, RSC sleep. CX, the GMU clocks, the SMMU
   and the zap shader stay. The next `negroni_gpu_submit` wakes it under the lock: RSC wake, steps 14-18 again
   (firmware into the TCMs, GMU start without the RSC/PDC set-up and without new io maps, HFI, tables + vote,
   OOB GPU_SET), the ring back to word 0, step 20 (registers, SQE after 1 ms, ME_INIT), CP_SET_SECURE_MODE 0.
   The first wake logs every step; later wakes are quiet (printf is dropped on the waking thread). The clock
   probe (10 ms per measure) and the clock dumps are skipped on a wake.
4. IFPC accepted but GX GDSC never off in 10 s of idle: OOB GPU_SET set again and mode `slumber` (with
   `negronigpu_slumber=1`).
5. `negronigpu_ifpc=0 negronigpu_slumber=0`: mode `off` = the 0281 behaviour (GX powered, OOB held).
   `negronigpu_dcvs=0` still gives the fixed vote; the watch then ticks only for the power samples.
6. Watch thread: ticks of 100 ms while a fence is pending or for 500 ms after the last submission, 250 ms when
   idle (a submission wakes it), 1000 ms with neither DCVS nor power management. With power management it reads
   only CX-side words per tick (gpucc GX GDSCR, GMU GFX_PWR_CLK_STATUS); a line is printed on a CX-side change
   or every 10 s, and only then GX is read (held). One mutex orders submissions, HFI votes, sleep and wake.

### Log lines (first boot, expected)
- Step 17 (before USB attaches, also in the persistent log): `NEGRONI ADRENO: 17 HFI send FEATURE_CTRL IFPC (id 11,
  4 dwords, seq N)`, `17 HFI FEATURE_CTRL IFPC ack, error 0`, `NEGRONI GPU PM: 17 FEATURE_CTRL IFPC ACCEPTED (ack 4
  words: ...)` or `REFUSED`.
- Step 20: `NEGRONI GPU PM: 20 power-up list at scratch +0x400: 53 IFPC + 17 IFPC/preemption pairs, 1 triplet, 588
  bytes` (only when accepted), then `20 THE 3D CORE TAKES COMMANDS` as before.
- After step 22: `NEGRONI GPU PM: IFPC on: OOB GPU_SET released, ...; GX GDSC %#x, power state %#x` or `NEGRONI GPU PM:
  IFPC refused by the GMU: slumber after 2000 ms idle, warm GMU restart on the next submission` or `NEGRONI GPU PM: off`.
- WATCH line, a field after `dcvs L busy N%`, before the thermal and cpufreq (0284) fields:
  `| pm ifpc GX collapsed N% gmu N% pwr 0x3 fenced N max Nus fail N |` or
  `| pm slumber GX collapsed N% sleeps N wakes N last Nus max Nus |` (N% = share of the watch samples since
  the last line with the GX GDSC off).
- IFPC: `NEGRONI GPU PM: WPTR write dropped N times (GX collapsed), taken after N us` (first 8).
- Slumber: `NEGRONI GPU PM: slumber N in N us: GMU idle, GX off (GDSC ...), RSC asleep (...)`, `NEGRONI GPU PM:
  first wake: steps 14-21 again ...`, `NEGRONI GPU PM: wake N in N us (asleep N ms), GX GDSC ...` (first 8, then
  every 100th).
- Failure lines: `OOB PERFCNTR NOT ACKED`, `WPTR write still dropped after N us ...`, `PREPARE_SLUMBER not acked`,
  `IFPC acked, but GX never collapsed in N ms of idle ...`, `WAKE FAILED after N us ...: the GPU stays off`.

### Proof on the phone
`GX collapsed` near 100 % with the UI still, falling while scrolling; `pwr 0x3` on an idle line; the WATCH
`THERMAL gpu` temperature and the battery current lower than `out/ios16-pwr` under the same use; no `gave up on
fence` lines and no `RedwoodGPU: ... no answer for 2 s`. Back: `negronigpu_ifpc=0 negronigpu_slumber=0`.

### Risks
- [I] Not booted. The GMU may refuse FEATURE_CTRL IFPC or accept it and never collapse (then: slumber).
- [I] KGSL restores only the listed registers after IFPC; the rest of step 20 (RB/SQE base, RB_CNTL, APRIV, QoS,
  SECVID, HANG_INT, CMDQ, NC_MODE of RBBM) are not in KGSL's lists either, so the GMU/CP must keep them. If not,
  the first submission after a collapse hangs.
- GPU does not wake (IFPC exit fails or a slumber wake fails): the fenced write gives up after 2 ms + one OOB try ->
  submit returns 0 -> RedwoodGPU logs `the ring stays full` and sets gGPUStopped; a failed wake sets `pm_dead` (every
  later submit returns 0). A wake that writes WPTR but the CP never runs: no fence moves, RedwoodGPU's 2 s rule
  (`no answer for 2 s`, GPU_HUNG_MS) sets gGPUStopped. In both cases every fence then reads done, and 0254's
  give-up (gGPUStopped, or no fence for NEGRONI_FB_GPU_STUCK_MS 2000 ms) puts the display on CPU copies. The
  system watchdog is off in the config (`wdt=-1`), so nothing reboots; the UI goes on without GPU work.
- A slumber wake takes the SQE start + ME_INIT + HFI round trips, under gGPULock: the frame that wakes the GPU is
  late by that time (the log gives it).
- `negroni_gpu_report` and the table switch now wait for the power lock (at most one wake).

Build (2026-10-26): see docs/notes.md section 17 end.

## 17. TE-locked vsync and idle refresh switching (0259, `negronifb_te` / `negronifb_vrr`, default off)

Report: `docs/display-refresh-plan.md` (Android's TE/auto-refresh/ADFR path, the DCS sets with live.dts
line numbers, the DPU registers). Files: NegroniFramebuffer.cpp (`teInit/teTick/teLog`, `vrrTick/
vrrWakeLocked/vrrWork/vrrSetRate`, hooks in `vsyncFired`, `rearm`, `swap`, RequestPowerChange, `statTick`),
NegroniBacklight.cpp (`negroni_dsi_dcs_set`, `negroni_backlight_panel_ready`, NDSI_MAX_PAYLOAD 60).

- `negronifb_te=1`: INTF_1 (0x0AE36000, mapped through fMdss when 0234's probe mapped the DPU, else its own
  page) INT_COUNT_VAL (0x298) = TE count << 16 | lines since the TE. Each tick: phase of the tick's deadline
  after the TE = (line - VSYNC_INIT_VAL) x vsync_count / 19.2 MHz; error against the target
  (`negronifb_te_off`, us after the TE, negative = before the next; default -800); the next deadline moves by
  -error/2, at most a quarter period. TE period = frames per second from the count; the tick period follows it
  when within 15 % of nominal. `=2` also sets INTF_VSYNC_TIMESTAMP_CTRL and logs the stamp.
  Boot: `NEGRONI FB TE: INTF_1 tear_en 1 sync_cfg 0x... (te pin 1, counter 1, vsync_count 66 = 3437 ns/line)
  height 65520 init 2412 start 2412 ... autorefresh 0x80000001 ...` (expected values), `NEGRONI FB TE: lock on,
  target 800 us before the TE`. Per second (after the STAT line): `NEGRONI FB TE: te/s 120 period us 8333 tick
  us 8333 phase us P target T err avg/max us A/M adj us D locked L/S ticks (no sample N) count 0x... autorefresh
  0x...`. Locked = |err| <= 500 us; expect L/S near 120/120 after a few seconds. `no TE for 120 ticks` = the
  counter does not move (display off or no TE pin): no lock.
- `negronifb_vrr=1|2|3`, `negronifb_vrr_fps` (default 10), `negronifb_vrr_ms` (3000), `negronifb_vrr_hs=1`
  (HS DCS). State machine under fLock (active, going idle, idle, waking); the DCS runs on a thread call
  (`vrrWork`), never on the vsync work loop or backboardd's thread; `swap()` and RequestPowerChange call
  `vrrWakeLocked` (modes 1/3 write AUTOREFRESH_CONFIG = 0x80000001 at once). Mode 1: `BD[0x14] = 120/fps - 1`
  then divider = 120/fps; wake: divider 1 then `BD[0x14] = 0`. Mode 2: the 60 or 90 Hz set, then `vrrSetRate`
  (tick period, vsync interval value, `IOMFBDisplayRefresh`); wake: the 120 Hz set. Mode 3: divider only.
  Modes 1/3 refuse to start when AUTOREFRESH_CONFIG != 0x80000001. A failed switch logs
  `idle switch failed (rc after N packets): VRR off` and the VRR stays off for the boot (a retry every idle
  period would reach 0250's 3-failure DSI shutdown and kill the brightness and the 0258 sleep DCS); a
  best-effort `F0 A5 A5` closes the Samsung key after a set that failed midway. The power-off fade (step 6)
  waits while `fVrrBusy` (at most 60 ticks = 500 ms, then `display off ... VRR set still running`) so the 0258
  sleep DCS never lands inside a set. DCS mode: HS for mode 2 (Android's dsi_hs_mode), LP for mode 1;
  `negronifb_vrr_hs=1|0` overrides. The per-second TE/VRR lines come from statTick (`negronifb_stats != 0`,
  default 1). The late-tick threshold (fStatLateAbs) follows the rate in mode 2.
  Lines: `NEGRONI FB VRR: mode 1, idle 10 Hz (hold 0x0b, autorefresh 1/12) after 3000 ms without a swap, DCS LP`,
  `NEGRONI FB VRR: idle 10 Hz (hold 0x0b, autorefresh 1/12, 5 DCS packets, N ms)`, `NEGRONI FB VRR: active
  120 Hz after N ms idle (5 DCS packets, N ms)`, per second `NEGRONI FB VRR: active|idle (idle 10 Hz), N idle
  periods, idle N ms in all, DCS errors N`.
- Risks: a timing switch the panel rejects can blank it (`negronifb_vrr=0` recovers; the config args do not
  carry the flag); the hold with frames still arriving every N+1 TEs is not what Android does [I]; the 60 Hz
  timing leaves the tearcheck vsync_count at the 120 Hz value [I, start_pos = init so the transfer starts
  at the TE either way]. Build: kernel local-20261026-075816 (a39f24e5...), image out/ios16-vrr (config args +
  `negronifb_te=1 negronifb_vrr=1`). Not booted.

## 18. 120 Hz pipeline: vsync after the frame, clock shift inside the copy, GPU UI floor (0267, 0286)

Owner report (2026-10-26 13:25, kernel local-20261026-074105, config args + `negronibatt=5 negronipanic=30
negronipanicreason=2`): "not 120 Hz, still laggy; the top-left glitching still exists".

### Measurements [V]

- `logs/usblog.log` 13:18-13:31 (FB STAT, 365 seconds with presents > 20): swaps/s mean 49 (40-81), presents/s mean
  43.5 (28-70, max 105), cpu 0-8, gpu 24-62, zc 0; copy avg 2.0-2.6 ms, max 6-8 ms; SwapWait busy answers mean
  173/s (60-960); gpu-wait skips mean 22/s; late ticks 0 outside the screen-off seconds (those are the 0251 fade,
  0265 by the wake agent).
- GPU DCVS (0281) under that load: level 4-5 (350-421 MHz) most of the time, short steps to 6-9, `busy` 20-50 %,
  thermal cap 12 -> 4 when the CPU reached 79 C.
- Metal telemetry (backboardd, `/var/db/negronimetal/metal.log`): 9368 command buffers, commit-to-complete mean
  15.6 ms, max 170 ms; scheduling wait total 2.3 s (0.25 ms per buffer). Last 3000 `K` rows: ctc mean 15.7 ms, 33 %
  under 10 ms, 38 % over 16.7 ms; 7 render passes and ~6.2 M pixels (2.2 screens) per buffer.
- The older log with the fixed 818 MHz vote (`logs/usblog-20261025-223827.txt`, 2036 seconds with presents > 20):
  swaps/s 69, presents/s 57.7, gpu-wait skips 9/s. So the clock alone is worth about +30 % presents/s.

### Where the 8.3 ms goes [V code, I = inferred]

1. The tick order (0252-0256 code): `vsyncFired` sent the vsync notification first, then (if the frame's render
   fence passed) queued the 2D copy, then `present()` waited for the copy's fence (2.4 ms avg, up to 8 ms: the
   ring is in order, so the copy also waits for CA's next render) because `negronifb_clockshift` must shift after
   the copy, and only then published the swap id (`fPresentedID`). CoreAnimation wakes on the notification and
   calls SwapWait for that id: busy; it retries with usleep(100) for 1 ms, then skips the heartbeat [V QuartzCore
   20H392 disassembly, section 12 "0254"]. [I] That is most of the 60-960 busy answers per second and the gap
   between 120 and the swaps/s.
2. The render: 10-24 ms commit-to-complete per CA frame at 350-492 MHz with the bandwidth vote tied to the GX
   level (bw 3-5) [V telemetry + DCVS lines]; a frame not done at a tick waits for the next one (gpu-wait skips).
   [I] The 0281 busy rule needs two 100 ms samples in a row with a fence pending; a 40-60 % duty cycle rarely gives
   that, so the GPU stays near the floor exactly when the UI needs short frames.
3. The copy: 2D copy of 1080x2412 (10.4 MB read + write) on the GPU, ~2 ms at 421 MHz [I from copy avg minus the
   submit]; the CPU copy (cpu 2-8/s) takes 2.4 ms of a core.

### Top-left glitch [V code + 0265's measurement, I for the visual]

`negroni_shift_clock()` shifted the strip (120 rows x 540 px) in place with `memmove` in the panel memory. The
panel memory is mapped write-combined (`negroni_surface_create_physical`, kIOMapWriteCombineCache): every read is
an uncached bus read (0265 measured a full read-modify-write pass at ~1 s, i.e. ~10 MB/s), so the shift of 259 KB
takes several ms. During that time, and between the copy's completion and the shift, the display engine (auto-
refresh, one scan per TE, not synchronised with our tick) scans the strip unshifted or half-shifted. With 40-70
frames per second the strip flickers between the shifted and the unshifted clock and shows torn rows: the "top-left
glitching". The 0256 deferred path (`clock shift after fence N`, seen at 13:20:26 and 13:20:35) leaves the strip
unshifted for one more tick. The single scanned buffer is the root; the in-place CPU read is what makes the window
long.

### 0267 (`0267-negroni-fb-vsync-after-frame-clock-copy.patch`; NegroniFramebuffer.cpp, NegroniGPU.cpp/.h)

- `negronifb_notifylate=1` (default): with the display on, the tick queues its frame (GPU copy submitted or CPU copy
  done), publishes the swap id, then sends the vsync notification. The CPU drawing over a GPU copy (`presentFinish`:
  the 0256 shift when the copy did not shift, the badges) runs after the notification. With the display off the
  order is the old one (0258/0265 untouched). `=0`: the old order. With notifylate the swap id counts as on screen
  when the GPU copy is submitted, not when its fence is done (0254/0256 waited for the fence only through the clock
  shift); the source surface stays held (keepBusy) until that fence. The ring is in order, so CoreAnimation's next
  render into that surface runs after the copy has read it.
- `negronifb_clockcopy=1` (default): a frame of one layer that covers the strip is copied with the strip already
  shifted. GPU: `NegroniGPUPresentRects` puts 4 rectangles in one IB with one fence (rows below the strip; the
  strip's left half to x + n; the n pixels pushed out at the middle to x 0..n; the strip's right half), 98 words
  each (392 of the 4096-word IB page) [V host run of negroni_gpu_copy_ib]. CPU: 3 memcpys per strip row. The n
  columns at the left edge now get the pixels from the middle of the canvas (logical x 462..562, the notch area:
  no status bar item there) instead of the edge pixel of each row; zero-copy (0234) uses the same fill. No read of
  the panel memory, no change of the strip after the copy, no fence wait on the tick. `=0`: the 0256 behaviour.
  Frames with more than one layer keep the 0256 path.
- Order: made on 0259 (13:25 version); 0275 (display off fast, wake agent) applies after it unchanged (the notify
  loop keeps its text, only its condition gets `!notifyLate`) [V git apply chain 0267, 0286, 0274, 0275].
- Host test: `patches/xnu/tests/fb-clock-copy-test.c` (rectangles and CPU rows against "copy, then rotate the left
  half by n", n = 1, 100, 200, 539): PASS.
- Log: `NEGRONI FB: 0267 vsync notification after the frame is queued (negronifb_notifylate=1), clock shift inside
  the copy (negronifb_clockcopy=1)` at start; the first 4 frames `NEGRONI FB: clock shift inside the copy (GPU, 4
  rectangles), N GPU + N CPU frames so far`; `RedwoodGPU: present N: ... 4 rect(s), 392 words`.

### 0286 (`0286-negroni-gpu-dcvs-ui-floor.patch`; negroni_adreno.c, one line in NegroniFramebuffer.cpp swap())

- Numbered 0286, not 0268: it changes the 0281/0285 DCVS code, which the build applies after 0268 (patches go in name
  order). [V] a first build with the name 0268 skipped it (`patch failed: bsd/dev/negroni_adreno.c:3476`).

- swap() counts SwapEnds (`negroni_gpu_ui_swaps`); the DCVS tick makes a rate over >= 100 ms. At
  `negronigpu_uifps` (default 30) swaps/s or more, the level is at least `negronigpu_uifloor` (default 9 = 640 MHz,
  bw level 8) for `negronigpu_uihold` ms (default 1000) after the last such window; one busy tick (100 ms) moves one
  level up while the floor is on. The 0280 thermal cap still wins. `negronigpu_uifloor=0` or `negronigpu_uihold=0`:
  floor off (0281 as before). There is no line per floor event; the per-second DCVS line shows `ui N swaps/s floor on`.
- Log: `NEGRONI GPU DCVS: UI floor level 9 (640 MHz) at 30 swaps/s or more, held 1000 ms (0286)`; the per-second
  line gets `, ui N swaps/s floor on (N boosts)`.

### Expected [I, not booted] and proof lines

- Scrolling (copy avg/max now includes presentFinish, i.e. the badge or 0256 fence wait; the numbers are for
  badges off): `NEGRONI FB STAT: swaps/s 100-120 presents/s 100-120 (cpu 0-5 gpu ...) copy avg/max us <300/<1500
  ... timeouts` well under 100, `gpu-wait skips` under 10; `NEGRONI GPU DCVS: level 4 -> 9 (640 MHz, ...) ... ui
  110 swaps/s floor on`. If presents/s stays at 60-80 with `timeouts` low and `gpu-wait skips` high, the render
  (ctc) is the limit: try `negronigpu_uifloor=12`; if `timeouts` stays high, CA waits for something else (report).
- Top-left: the clock stays still while the screen moves; `negronifb_clockcopy=0` brings the 0256 path back for an
  A/B, `out/ios16-perf-noshift` has no shift at all (the clock under the camera hole, nothing drawn by the kernel).

### Build (2026-10-26 13:56)

Job `perf-kernel` (`scripts/display/build-perf.sh`, lock out/kernel/.lock held across kernel + images): kernel
`out/kernel/local-20261026-082629` (sha256 92f50f3ab2a29b4702f0c86d3ea890accf94866f83edfbb1e158c74e6bff2a20; all 64
patches/xnu applied incl. 0267, 0275, 0285, 0286; the 4 usual dxb skips). Images (config args + `negronifb_notifylate=1
negronifb_clockcopy=1 negronigpu_uifloor=9 negronibatt=5 negronipanic=30 negronipanicreason=2`):
`out/ios16-perf` boot_a sha256 2583f0abb9b84288274ea9a7a010529fff71c09c78b04daf1a0a0014a2418894;
`out/ios16-perf-noshift` (no `negronifb_clockshift`) boot_a 50d09e1b4e5e4f199be4695bdf085774622249f3b342f940bbff903cf4e4c967;
vendor_boot_a c29329ee... (copied from out/ios16). Not flashed.

### Not done here (next candidates, by expected gain)

- Panel double buffer: a second panel-size buffer in the splash region (0xb89f0000, free when zero-copy is off) and
  a DPU base flip (SSPP SRC0_ADDR + CTL_FLUSH, the 0234 `flip()`/`zeroCopyLatched()` code with the panel memory as
  slot) once the copy's fence passed: no tearing, the copy no longer races the scan. Needs the 0234 DPU probe lines
  from a boot (never captured: the USB log starts after them; `ioreg` exists on the phone, so a registry property
  with the probe result would make them readable).
- A CPU copy (cpu 2-8/s) can write the single panel buffer while an earlier GPU copy is still in flight; the double
  buffer above fixes it.
- The GPU path does not check sy + h against the source surface height (pre-existing, 0231).
- Zero-copy (`negronifb_zerocopy=1`, 0234, never booted): no copy at all; try it as an image variant after this.
- Present on render completion instead of the next tick (saves 0-8.3 ms latency per frame) with a TE-locked tick
  (0259 `negronifb_te=1`).

## 19. Panel wake with the full on-command and the PPS (0268, `negronifb_wake`, default 2)

Files: NegroniBacklight.cpp (`negroni_dsi_packet`, `negroni_dsi_dcs_set_ex`, `negroni_dsi_long_packet`,
`AppleARMBacklight::wakePanel`), NegroniFramebuffer.cpp (`negroni_fb_autorefresh_pause/resume`, `negroni_fb_te_check`),
scripts/display/panel-dts-dump.py `--on` (the arrays). Details: README-brightness.md "0268".

- Problem [V phone log 13:24-13:30, kernel 074105, `negronifb_sleep=1`]: every wake logged `display on (sleep-out 133 ms,
  DCS ok, panel DBV 356)`, the panel stayed black with a purple strip. 0258 sent 0x11, 133 ms, 0x29 only.
- Android [V display-drivers]: `dsi_display_enable` (dsi_display.c:9147-9170) sends `DSI_CMD_SET_ON` (`dsi_panel_enable`
  dsi_panel.c:5708-5760), then `dsi_panel_update_pps` (dsi_panel.c:5119-5188) on every display on; before both, the panel
  is powered and reset (`dsi_panel_power_on`, reset `<1 10 0 5 1 10>` live.dts 35616). Both sets LP (no
  `on-command-state` in live.dts: dsi_panel.c:2678-2680 default; PPS set LP at :2721). Commands longer than the 64-byte
  FIFO go from a memory buffer (`dsi_ctrl_validate_and_set_cmd`/`dsi_message_tx` dsi_ctrl.c:1701-1731,
  `dsi_ctrl_hw_cmn_kickoff_command` dsi_ctrl_hw_cmn.c:870-919; FIFO limit dsi_ctrl.c:1320-1325).
- The PPS [V]: the on-command's first packet is `39 9E` + 89 bytes (the PPS, version 0x11, Samsung's own write, 90 bytes:
  too long for the FIFO); the UEFI XML's first packet is the same PPS with version 0x12 and 128 bytes (identical bytes
  otherwise, `panel-dts-dump.py` compared them). The MIPI PPS packet (0x0A) Android sends after the on-command carries
  the DSC 1.2 PPS (version byte = qcom,mdss-dsc-version 0x12) = the UEFI's 128 bytes, i.e. the PPS the DPU's DSC
  encoders were programmed with. So: re-send both, as Android does.
- DSI controller [V code, I effect]: the panel's sleep-in does not touch the host controller (clocks, command engine,
  PHY stay as the UEFI left them; Android re-inits it only after its own clock/power off, and skips it with continuous
  splash, dsi_display.c:9110-9134). No controller re-init. DPU side: the auto-refresh is paused during the set
  (INTF_TEAR_AUTOREFRESH_CONFIG bit 31 off, `_sde_encoder_autorefresh_disable_seq1` sde_encoder_phys_cmd.c:2015-2042,
  then wait for the DSI MDP-busy bit) and re-armed after (the saved value, 0x80000001; `sde_hw_intf_setup_autorefresh_config`
  sde_hw_intf.c:668-686); then 50 ms of the TE count (INT_COUNT_VAL[31:16]), INTF_FRAME_COUNT and the tear interrupt
  status (+0x804 bits 0 AUTOREFRESH_DONE, 1 WR_PTR); TE without any frame sign: the auto-refresh is switched off and
  on once more (`re-armed`).
- Sequence (`negronifb_wake=2`): pause, the 94 packets (each with its DT type; post-waits 12 ms after 0x11, 121 ms after
  the B9 block), 0x0A PPS (memory DMA), resume, TE check, DBV. `=1`: the same without the two packets that need the
  memory DMA (9E, 0x0A); `=0`: the 0258 sleep-out. The command buffer: the last 16 KiB of the splash region (0xbaafc000,
  after the 0234 slots) mapped write-combined; the DSI DMA reads it through the display SMMU context as the pipes read
  the panel memory [I: the UEFI sent its 129-byte 9E packet by memory DMA too, so the path works under the UEFI's
  SMMU setup; not tested under XNU]. A memory DMA that does not finish in 25 ms turns the memory path off for the boot.
- VRR (0259): the on-command ends in the 120 Hz state (`60 00`, `BD[0x14]=00`, B9[0x38]/[0x3A] 02), so an idle state
  before the sleep is reset by the panel; `vrrWakeLocked` (RequestPowerChange) still sends its exit set from the thread
  call; the new set lock serialises it with the on-command (before or after, both end at 120 Hz).
- Log (expected): boot `NEGRONI BL: DSI0 command buffer for long packets mapped at 0xbaafc000 (fifo_ctrl 0x... dma_offset
  0x...)`, `NEGRONI BL: wake mode 2 (...)`; wake `NEGRONI FB: display on (on-command 94 packets, PPS ok, TE on: 6 TE 6
  frames tear 0x.. in 50 ms, autorefresh 0x80000001 paused+resumed; sleep-out ~450 ms, DCS ok, panel DBV N)`.
  `TE MISSING` = no TE after the set (panel not out of sleep). `PPS failed` / a `DSI packet 0x39 cmd 0x9e (90 bytes, from
  memory) failed -3` line = the memory DMA does not work: boot with `negronifb_wake=1`.
  `PPS not sent (set incomplete)` = the on-command stopped before its end (a short packet failed), so no 0x0A PPS went.
- Not changed: the panic wake (0x11/0x29, no lock: a memory DMA is not safe there); the off-command (0x28/0x10).
- Risks: a memory DMA that faults in the SMMU can stop the DSI command engine (no more DCS until reboot: brightness
  stuck, no sleep): `negronifb_wake=1`. The on-command with the panel not reset is not what Android does [I: the DDIC
  accepts every write in sleep-in; the order is the reset one]. If the wake stays black with `TE on`, the pipe/DSC side
  is the cause (report the line); `negronifb_sleep=0` brings back the working 0275 black-only screen-off.

## 20. Panel double buffering with a DPU base flip (0269, `negronifb_dbuf=1`, default 0)

Files: NegroniFramebuffer.cpp (`dbufInit/dbufTarget/dbufQueued/dbufTick/dbufFlip/dbufPark/dbufOff`, hooks in
`vsyncFired`, `zeroCopyStop`, `zeroCopyInit` (`fZCLayoutOk`), `statTick`, `negroni_fb_panic`, the GPU copy destination
`fDrawPhys`), NegroniGPU.cpp (one GPU mapping per panel buffer).

- Why [V code, audit 2.1]: the auto-refresh fetches the panel memory on every TE while the 2D copy or the CPU copy
  writes it at a free phase: tearing, and a CPU copy (GPU ring full) can overlap a GPU copy still queued.
- Android [V]: three framebuffers, a commit sets SSPP_SRC0_ADDR (`sde_hw_sspp_setup_sourceaddress` sde_hw_sspp.c:925-948)
  and CTL_FLUSH (`sde_hw_ctl_trigger_flush_v1` sde_hw_ctl.c:685-711, pipe bits `sspp_tbl` :78-79: VIG0 0, VIG1 1, VIG2 2,
  VIG3 18, DMA0 11, DMA1 12, DMA2 24, DMA3 25; CTL 17); the engine takes them at the frame start. Under auto-refresh no
  CTL_START (sde_encoder_phys_cmd.c:2169-2175): the auto-refresh trigger is the frame start [I: whether a flush alone
  latches under auto-refresh is not in the source; the first 4 flips log `taken after N us`, a flip not taken in 1 s
  turns 0269 off].
- Which pipe/CTL [V code, I values]: 0234's boot probe (`negronifb_dpuprobe`, default 1, read only) logs every SSPP and
  CTL (`NEGRONI FB: DPU VIG0 addr ...`, `NEGRONI FB: DPU CTL2 ... intf 0x2 ...`) and keeps the pipe(s) whose SRC0_ADDR is
  the panel memory and the CTL whose INTF_ACTIVE has INTF_1 (`negronifb_ctl=N` overrides). These lines were never
  captured (the USB log starts later): `ioreg`/the boot console have them on the next boot.
- Buffers: the panel memory 0xb8000000 (ABL's, the console's, the panic's) + `negronifb_dbufn - 1` more (default 3 in
  all) at 0xb89f0000 and 0xb93e0000 (0x9f0000 each = round_page(4320 x 2412)); end before the 0268 DSI command buffer.
  Each is a physical NegroniSurface (kernel mapping write-combined, as the panel memory).
- Flow: `dbufTarget` (tick, before the frame is taken): a one-layer full-panel frame -> a free buffer; none free -> the
  frame stays pending (`waits`); other frames -> wait until nothing is pending/flipped, then the shown buffer
  (`in-place`). `present()` writes `fPixels`/`fDrawPhys` (= that buffer); `dbufQueued` marks it pending with the frame's
  fence (0 = CPU, done). `dbufTick` (tick start and end): flush bits clear -> the flipped buffer is shown, the one before
  is free; the newest pending buffer whose copy is done (fence, and no presentFinish/0256 shift left on it) -> SRC0_ADDR
  + CTL_FLUSH. One flip outstanding at a time. Older pending buffers are freed when their fence is done.
- Two vs three buffers: with two, a GPU frame flips one tick after its copy and the buffer shown before is free one tick
  after the flip: 60 frames/s at most. Three: 120. CPU frames flip in the same tick (dsb, then the registers).
- Display off: `zeroCopyStop(true)` (0275 tick 0) parks: the last flip taken, other buffers free, the black goes into the
  shown buffer (no flip, no stale frame). Panic: `zeroCopyRestore()` (ABL's values = the panel memory) so the panic text
  shows. The 0268 wake pauses the auto-refresh: no flip latches then, the 1 s timeout does not count.
- Off: zero-copy on (same splash space), no probe, an unexpected pipe layout (line `0269 double buffering off: ...`).
- Logs: `NEGRONI FB: 0269 double buffering on: 3 panel buffers of 0x9f0000 at 0xb8000000 0xb89f0000 0xb93e0000, pipe(s)
  VIG0, CTL at +0x18000, flush bits 0x20001` (pipe/CTL as probed), the first 4 flips `NEGRONI FB: 0269 flip N: buffer B at
  0x... (fence F), taken after N us, CTL_FLUSH 0x0`, per second `NEGRONI FB DBUF: flips/s N waits N in-place N latch max us
  N (buffer B shown, -1 flipped, N flips)`. Expected [I]: flips/s = presents/s, latch max <= 8400 us, in-place 0.
- Risks: a wrong SSPP address or flush blanks or freezes the panel: `negronifb_dbuf=0` (default; the config args do not
  carry it). A flip that latches mid-frame would tear like before (no worse). A frame drawn by CA with a source smaller
  than the panel (never seen: CA sends 1125x2436) would leave old rows in the back buffer.

## 21. GPU hang detection and recovery (0287, `negronigpu_recover`, default 1)

Symptom: a lost WPTR write (IFPC), a full ring or 2 s without a fence set `gGPUStopped` for the rest of the boot. Every
fence then read done, the present path fell back to CPU copies, Turnip saw `MSM_PARAM_FAULTS` 1 (device lost) on every
new device: "black-outs" until a reboot.

### What KGSL does (out/src/op-kernel/drivers/gpu/msm) [V code]
- The phone's A730 is `gen7_0_1` (chipid 0x07030001, adreno-gpulist.h:2079-2110; `gen7_0_0` at 2045-2073 is the
  same driver) with the non-hwsched dispatcher: `.gpudev = &adreno_gen7_gmu_gpudev.base`; its
  `.reset = gen7_gmu_reset` (adreno_gen7.c:1507-1517).
- Detection: drawobj timeout 2000 ms (adreno_dispatch.c:50, `_adreno_dispatch_check_timeout` :2315-2344), the soft-fault
  timer 200 ms (:53, `fault_detect_read` :162-182); RBBM interrupts MISHANGDETECT (23, `adreno_hang_int_callback`
  adreno.c:368-376), CP_HW_ERROR (9), GPC_ERR (7, adreno_gen7.c:1096-1109), UCHE OOB (24) (table adreno_gen7.c:1123-1156);
  hang-detect counter `RBBM_INTERFACE_HANG_INT_CNTL = BIT(30) | 0xcfffff` (adreno_gen7.c:508-510, gpulist `hang_detect_cycles`);
  GMU AO interrupts (adreno_gen7_gmu.c:1693-1725: bit 0 watchdog bite -> NMI, bit 3 fence error, bit 5 AHB error).
- Fault handling: `dispatcher_do_fault` (adreno_dispatch.c:1964-2148): GMU interrupts masked, RBBM_STATUS3 bit 24 check
  (SMMU stalled), CP halted, CP_RB_BASE / CP_IB1_BASE read, snapshot, fences of the hung ring written as retired
  (:2109-2121), `adreno_reset`, the queues replayed or skipped; throttle 3 faults per 3000 ms per context (:34-35).
- Reset: `gen7_gmu_reset` (adreno_gen7_gmu.c:3127-3146) = GPU and GMU interrupts off, HFI stop, `gen7_gmu_suspend` ->
  `gen7_gmu_pwrctrl_suspend` (:1354-1410: AHB fence ALLOW, `CM3_SYSRESET` 1, GBIF GX halt (if GX on), GBIF CX halt,
  `RBBM_SW_RESET_CMD` 1, 100 us, GX GDSC off from the CPU), clocks and CX off, then `gen7_boot` (warm boot).

### What 0287 does (`0287-negroni-gpu-hang-recovery.patch`; negroni_adreno.c, NegroniGPU.cpp)
- Detection (no GPU interrupt in this port: polled):
  - RedwoodGPU `gpuWait`: the completed fence did not move for 2 s with this fence outstanding (as before);
  - `negroni_gpu_submit` returned 0 (ring full, or the IFPC-fenced WPTR write lost) in a client submit or the present copy;
  - the watch thread, once a watch second: no fence for 2 s with work queued, an SMMU fault in the 3D core's context,
    CP_HW_FAULT != 0 (only when GX is held for the line), a new GMU watchdog bite (AO_HOST_INTERRUPT_STATUS bit 0) or new
    FW_INIT_RESULT bits 9-11 (GMU firmware fault; KGSL's NMI rule). It calls `NegroniGPUWatchFault`, which takes gGPULock
    and recovers only if no fence was written meanwhile. `negronigpu_recover_watch=0` turns this part off.
- Log (`NEGRONI GPU RECOVERY: N: ...`): fences (BR and BV words, last, wptr), pm mode, GX GDSC, GMU power state, AO
  interrupt status, FW_INIT_RESULT; with GX held: RBBM_STATUS/STATUS3/INT_0, CP rptr/HW_FAULT/INT/PROTECT_STATUS,
  IB1/IB2 base and remaining size (0x928-0x92d, gen7_reg.h:104-109), CP_SCRATCH_REG2; SMMU SGFSR and both contexts'
  FSR/FAR/FSYNR0 (the 0233 registers); the GMU log head (16 dwords).
- Reset (gpu_pm_lock held): GMU interrupt mask, AO interrupt clear, AHB fence status clear + ALLOW, CM3 in reset; then
  (only while the GX GDSC is on; with the CM3 in reset nothing collapses GX) GBIF GX halt + ack, GBIF CX halt + ack,
  RBBM SW reset (1, read back, 100 us, 0); `negronigpu_recover=2` also collapses the GX GDSC from the CPU (SW_COLLAPSE,
  KGSL's regulator disable); the halts are released (the GMU boots through the same bus; step 20 writes them 0 again);
  RSC sleep (as 0285 slumber); both SMMU contexts' FSR cleared (W1C; the contexts terminate, nothing to resume). CX and
  the GMU clocks stay on.
- Restart: `gpu_warm_boot` (the 0285 wake, now shared): RSC wake, steps 14-18 (firmware into the TCMs, GMU start, HFI,
  tables, the step-17 vote, FEATURE_CTRL IFPC again when it was accepted at boot, OOB GPU_SET), ring at word 0, step 20
  (registers, SQE, ME_INIT with the power-up list), CP_SET_SECURE_MODE 0. The first two recoveries log every step.
  Then: IFPC mode releases OOB GPU_SET again (or falls back to slumber/off when the GMU now refuses IFPC); DCVS re-votes
  (pm_revote); the next submission invalidates the UCHE.
- Fences: the BR/BV fence words take the newest fence (KGSL writes the hung ring's timestamps as retired): every waiter
  sees done. The range (completed + 1 .. newest) is recorded (last 16 recoveries): `negroni_gpu_fence_failed()`.
  Client waits (msm WAIT_FENCE, scalar wait, GEM_CPU_PREP) on such a fence answer `kIOReturnError`;
  `MSM_PARAM_FAULTS` = stopped + recoveries (msm's global count: Turnip's `msm_device_check_status`,
  tu_knl_drm_msm.cc:234-243, sets the device lost; the Metal plugin's dead-man then handles the process);
  `MSM_SUBMITQUEUE_PARAM_FAULTS` counts only recoveries that cut off this client's own work. A client submit that hit
  the full ring is sent once more after the reset. Internal waits (buffer free, table switch, present) take the failed
  fence as done, so the buffers are freed instead of leaked.
- Bound: `negronigpu_recover_max` (default 3, 1..16) recoveries in 60 s; one more, a failed restart, `pm_dead` or
  `negronigpu_recover=0`: `no recovery (...)`, gGPUStopped as before 0287. The badge reads `GPU RESET N`.

### Boot-args (0287, and 0298 for the same GPU path)
| Boot-arg | Default | Meaning |
|---|---|---|
| `negronigpu_recover` | 1 | 0 = no recovery (gGPUStopped for good, as before 0287); 1 = CM3 reset + GBIF halts + RBBM SW reset + warm boot; 2 = 1 + GX GDSC collapse from the CPU |
| `negronigpu_recover_max` | 3 | recoveries allowed in 60 s (1..16); one more stops the GPU for good |
| `negronigpu_recover_watch` | 1 | 0 = only waiters and submits detect a hang, not the watch thread |
| `negronigpu_hwcg` | 1 | 0298: HWCG registers at step 20 |
| `negronigpu_protect` | 1 | 0298: CP_PROTECT_CNTL + 45 ranges |
| `negronigpu_chicken` | 1 | 0298: CP_CHICKEN_DBG x3 = 1 |
| `negronigpu_dms` | 1 | 0298: ME_INIT BIT(11) (DMS off) |
| `negronigpu_rptr_shadow` | 1 | 0298: RB_CNTL without BIT(27), IFPC ring room from the CP's rptr shadow |
| `negronigpu_busy_pct` | 50 | 0298: DCVS busy threshold on the GMU busy counter; 0 = the fence rule |
| `negronigpu_ifpc_slumber` | 2000 | 0298: ms idle in IFPC mode before slumber; 0 = never |
| `negronigpu_hfi_ms` | 100 | 0298: HFI ack timeout after the boot ladder (10..1000) |
| `negronigpu_guard` | 1 | 0298: guard page after kernel-placed GPU buffers |
| `negronigpu_bwcalc` | 1 | 0298: DDR bus votes from cmd-db; 0 = the Linux constants |
| `negronigpu_cnoc` | 1 | 0298: CNOC CN0 vote |
| `negronigpu_bwdt` | 1 | 0298: DCVS bw index = DT bus-freq; 0 = the 0281 ramp |

### Expected lines [I, not booted]
`NEGRONI GPU RECOVERY: 1: no answer for 2 s: fence ...`, `... reset in N us: CM3 in reset, GX GBIF halt acked, CX GBIF halt
acked, RBBM SW reset done, GX on (GDSC ...), RSC asleep`, the step 14-20 lines, `... done in N us: fences A..B failed (N),
ring at N, pm ifpc, ...`, `RedwoodGPU: GPU reset after "...": recovery 1, the work in flight failed`, `RedwoodGPU: fence N was
cut off by GPU reset 1: the wait fails`. Afterwards the FB STAT line goes back to `gpu` presents (not only `cpu`).

### Risks
- [I] The warm boot after a CM3 reset with CX on was designed for slumber (0285) and was never run on the phone (the booted
  0285 image ran in IFPC mode). If step 14-18 fails after the reset, the GPU stays stopped (as before).
- [I] With `negronigpu_recover=1` the GX core is reset by RBBM_SW_RESET_CMD only, not power-cycled. A hang the soft reset does
  not clear shows as a second recovery within seconds; then try `negronigpu_recover=2` (GX GDSC collapse; risk: if the GMU
  does not clear SW_COLLAPSE on its next GX power-up, step 18 fails and the GPU stays stopped).
- A legit GPU job over 2 s is reset (KGSL's timeout is the same 2000 ms).
- Every Turnip device sees the fault count change: backboardd's Metal device is lost on any recovery (msm semantics).

### Build
2026-10-26 18:21, job `gpur-kernel` (`scripts/gpu/build-gpur.sh`, lock held over kernel + image, every patches/xnu patch up to
0291 applied incl. 0287/0288, the 4 usual dxb skips): kernel `out/kernel/local-20261026-125146` (sha256
8f1af35996a7ca6347fbd582630db17369831de58b1af736265884b527c0e9b2, 18 `NEGRONI GPU RECOVERY`/`NEGRONI CPUIDLE` strings),
image `out/ios16-gpur` (config args + `negronigpu_recover=1 negronicpuidle=1 negronipanic=30 negronipanicreason=2`;
boot_a 02718ef216f7607d1f84ecd1b1d3bc4009b9428b5f8247e99bc7fae09e485323, esp 0ce4598df2420230f1254003f73516962d5d5ad759fa22d80a326bd5a075781f).
Not booted. The 0298 build replaced this image (section 27).

### First-boot proof list (sections 19 and 20; review 2026-10-26: approve with fixes)

1. Boot: `NEGRONI BL: DSI0 command buffer for long packets mapped at 0xbaafc000 (fifo_ctrl 0x... dma_offset 0x...)`:
   record the dma_offset the UEFI left (the address its own memory DMA used; it tells which IOVA space the DSI DMA reads).
2. Boot: the `NEGRONI FB: DPU ...` probe lines (pipes, CTL) and `NEGRONI FB: 0269 double buffering on: ...`.
3. First frames: `NEGRONI FB: 0269 flip 1: buffer 1 at 0xb89f0000 (fence F), taken after N us` (N <= ~8400); `NOT taken`
   or `0269 double buffering off: the display engine does not take flips` = a flush alone does not latch under auto-refresh.
4. Lock and unlock: `NEGRONI FB: display on (on-command 94 packets, PPS ok, TE on: ...)` AND a correct picture (no black,
   no purple strip). `TE on` without a picture: report the line (DPU/DSC side).

Review fixes applied: 0234's slot size and its display-surface bound end at NEGRONI_DB_END (splash end - 16 KiB, 0269), so
they never reach the 0268 DSI buffer on another page/row size; the wake line says `PPS not sent (set incomplete)` when the
on-command broke off.

### Build (2026-10-26 18:30, sections 19 and 20)

Job `dpu-kernel` (`scripts/display/build-dpu.sh`, lock out/kernel/.lock held across kernel + image): kernel
`out/kernel/local-20261026-125636` (sha256 dc55e5fd063e2a2e03ba31ea3a120c0607427c80faae9b46af652b63d860707b; 215 patches
applied incl. 0268, 0269, 0275, 0351; skipped: the 4 usual dxb ones and the uncommitted 0292-0296 of another agent, which
fail on their own context). Image `out/ios16-dpu` (config args + `negronifb_sleep=1 negronifb_dbuf=1 negronipanic=30
negronipanicreason=2`): boot_a sha256 fa73ea8835307b583256870bc9c0ef29f012552f4f4ec781a4fa243f6dc9c35b, esp 906860a5...,
vendor_boot_a c29329ee... (copied from out/ios16). Patch chain check: 0267 -> 0268 -> 0269 -> 0275 -> 0286 -> 0351 (and
every other committed patch up to 0353) applies with `git apply` in order. Not flashed, not booted.

## 22. DSI command sets by memory DMA, batched like Android (0292, `negronifb_dsidma`, default 0)

Files: new `bsd/dev/negroni_dsi.c`; hooks in NegroniBacklight.cpp (after 0268: `negroni_dsi_dcs_set_ex`,
`negroni_dsi_dcs_write`, accessors `negroni_dsi_base/enter/leave/in_panic/cmdbuf/cmdbuf_failed`); NegroniFramebuffer.cpp
(0259 mode 1 HS default). Audit items 2.3 and 2.4 (docs/audit/2026-10-26-display.md).

- Android [V display-drivers]: `dsi_display_set_cmd_tx_ctrl_flags` dsi_display.c:820-858 (FETCH_MEMORY by default; LAST
  for a packet without `MIPI_DSI_MSG_BATCH_COMMAND` = DT flags byte 0x40), `dsi_message_tx` dsi_ctrl.c:1615-1752 (copy and pad
  into the 4 KiB uncached buffer, :1245-1290 header byte order {data0, data1, DI, flags}, flags bit 7 last, bit 6 long, bit 5
  BTA), `dsi_ctrl_hw_cmn_kickoff_command` dsi_ctrl_hw_cmn.c:870-918 (DMA_CTRL 31/30/26/28/24/29, DMA_FIFO_CTRL |= bit 20 |
  bit 16, DMA_CMD_OFFSET 0x48, DMA_CMD_LENGTH 0x4c, SW trigger 0x90), CMD_DMA_DONE INT_CTRL bit 0 (dsi_ctrl.c:390, 200 ms),
  then `reset_cmd_fifo` (:990-997). No MDP-idle wait per command (only dsi_display.c:8959, the dynamic-clock path).
- Ours: `negronifb_dsidma=1`: every set through `negroni_dsi_dcs_set_ex` (the 0259 VRR sets, the 0268 on-command) is sent
  inside 0268's set lock as batches: packets up to one without the 0x40 flag, one with a wait (the wait follows the batch),
  or the 4 KiB limit; one MDP-busy wait (20 ms max) per set, not per packet. Buffer: 0268's command buffer at 0xbaafc000
  (last 16 KiB of the splash region, write-combined; 0268 chose it because the display SMMU context passes the splash
  region for the pipes [I]), first 4 KiB. `=2`: single DCS writes (brightness, sleep) too. `=0`: 0250/0268 path.
- Failure: a DMA without CMD_DMA_DONE in 50 ms turns the memory DMA off for the boot (0268's long packets too) and the
  rest of the set goes packet by packet from the failed batch (`NEGRONI DSI: memory DMA of N bytes (N packets) not done
  ...`). It does not count toward 0250's 3-failure DSI shutdown.
- 0259 mode 1 (min-fps `BD[0x14]`) now defaults to HS like the DT state (live.dts 35650); `negronifb_vrr_hs=0` = LP.
- Lines: `NEGRONI DSI: memory DMA (negronifb_dsidma=1): command sets from 0xbaafc000 (0268's buffer), up to 4096 bytes per
  DMA`, the first 6 sets: `NEGRONI DSI: set of 721 bytes: 62 packets in N memory DMAs (N bytes), HS, N us, rc 0`.
  Expected [I]: a 0259 switch in a few ms instead of 100-300 ms; the 0268 wake set in its waits only (12 + 121 ms).
- Not changed: the fingerprint HBM sets of 0351 (`negroni_fp_send_set`) still go packet by packet (later patch).

## 23. DSI reads, ESD check and panel ID (0293, `negronifb_esd`, default 0)

Files: `bsd/dev/negroni_dsi.c` (read path, ESD thread call), NegroniBacklight.cpp (`negroni_backlight_reinit`,
`reinitPanel`), NegroniFramebuffer.cpp (`negroni_dsi_esd_start()` in `AppleCLCD::start`).

- Android [V]: `dsi_set_max_return_size` dsi_ctrl.c:1754-1777 (0x37, batched before the read), `dsi_message_rx`
  :1820-1965 (passes of 10, then 14 bytes; CRC removed; type at `buff[header_offset]`), `clear_rdbk_reg`
  dsi_ctrl_hw_cmn.c:1037-1043 (RDBK_DATA_CTRL 0x1d4 = 1 then 0), `get_cmd_read_data` :1045-1119 (RDBK_DATA_CTRL >> 16 =
  bytes, RDBK_DATA3..0 0x78..0x6c big-endian), BTA bit for reads (:1279-1285). ESD (live.dts 35594-35599): DCS read 0x0a,
  1 byte, LP, expected 0x9d or 0x9f, every 5 s (sde_kms.h:143). Serial: oplus reg 0xa1, 11 bytes, date at index 4
  (live.dts 35558-35561, oplus_display_private_api.c:754-806).
- Ours: `negroni_dsi_dcs_read(cmd, out, len, lp)` = a port of the two functions (memory DMA when 0292 is on: 0x37 + 0x06
  in one DMA; else two FIFO DMAs), then a BTA_DONE poll (INT_CTRL bit 20, 10 ms). `negronifb_esd=1`: 5 s after start
  (display on) the panel ID once, then 0x0a every 5 s while the display is on. A wrong value twice in a row queues
  `negroni_backlight_reinit`: the off-command (0x28, 21 ms, 0x10, 101 ms), 0268's wake (on-command + PPS, auto-refresh
  paused/resumed), the DBV again. `negronifb_wake=0` = no re-init (log only). At most 3 re-inits per boot: the next
  wrong pair logs `still 0x.. after 3 re-inits: ESD check off for this boot`. 3 failed reads in a row stop the check
  (a broken read path must never cause a re-init loop). A read takes 0268's set lock first (`negroni_dsi_set_enter/
  leave`), so it never lands between the batches of a 0259 VRR set or the packets of the 0268 wake. A read whose display went off meanwhile is ignored. `=2`: ID only.
- Lines: `NEGRONI DSI ESD: negronifb_esd=1: panel ID once, DCS 0x0a every 5 s while the display is on; re-init
  registered`, `NEGRONI DSI: panel ID da/db/dc .. .. .. (rc 1 1 1), power mode 0a 9c|9d|9f (rc 1), signal 0e .. (rc 1), a1 x
  11 rc 11: made YYYY-MM-DD hh:mm:ss (reads via memory DMA|FIFO)`, `NEGRONI DSI ESD: power mode 0x9d ok (expect
  0x9d/0x9f), check every 5000 ms`, every 60 checks `NEGRONI DSI ESD: N checks, ok N, wrong N, read errors N, re-inits N,
  last 0x..`. The serial bytes stay in the phone log (not in git).

## 24. Tearcheck vsync_count on a rate switch (0294, with `negronifb_vrr=2`; `negronifb_tcfg=0` = off)

File: new `bsd/dev/negroni_dpu.c` (`negroni_dpu_te_rate`), one hunk in 0259's `vrrSetRate`.
Android [V]: `sde_encoder_phys_cmd_tearcheck_config` sde_encoder_phys_cmd.c:1240-1259 `vsync_count = vsync_clk / (vtotal x
vrefresh)`; vtotal 2424 in the 120/90/60 FHD timings (live.dts v-front 2, back 8, pulse 2, height 0x96c) -> 66 / 88 / 132.
Ours: INTF_TEAR_SYNC_CONFIG_VSYNC [18:0] replaced, written with the counter off (bit 19), then on (sde_hw_intf.c:646-658), bit 20 TE pin kept; 0259's
line time `fTeLineNs` follows, so the TE-lock phase stays right at 60/90 Hz. Line: `NEGRONI DPU: tearcheck vsync_count 66
-> 132 for 60 Hz (sync_cfg 0x... -> 0x...)`. Back to 66 on the 120 Hz set.

## 25. The TE as an interrupt (0295, `negronifb_teirq=1`, default 0)

Files: `pexpert/arm/pe_fiq.c` (`negroni_spi_register/enable/dispatch`: the first SPI support of this port; GICD IGROUPR,
IPRIORITYR 0xa0, ICFGR level, IROUTER = the calling CPU, ISENABLER), `osfmk/arm64/sleh.c` (the dispatch before
`cdp->interrupt_handler`), `bsd/dev/negroni_dpu.c`, NegroniFramebuffer.cpp (`negroni_dpu_start` in start,
`negroni_dpu_tick` after 0259's teTick in vsyncFired, `negroni_dpu_te_since` in teTick).

- Path [V]: INTF_1 tear interrupt block MDSS + 0x36800 (EN +0, STATUS +4, CLEAR +8; bit 2 RD_PTR), sde_hw_interrupts.c:24-26,
  184-188 and live.dts `qcom,sde-intf-tear-irq-off`; MDSS HW_INTR_STATUS MDSS + 0x10 (bit 4 = DSI0, live.dts dsi_ctrl0
  `interrupts <4>`); MDSS line = GIC SPI 0x53 (83) = INTID 115, level (live.dts mdss_mdp `interrupts <0 0x53 4>`).
- Setup (Android `sde_core_irq_preinstall` + tearcheck_config): MDP top INTR_EN 0x1010 / INTR2_EN 0x1008 / INTF_1
  INTR_EN 0x361c0 = 0, statuses cleared, RD_PTR_IRQ = VSYNC_INIT_VAL + 1 (Android: vdisplay + 1), tear EN = RD_PTR. DSI0
  INT_CTRL enables are not touched (0250 polls the status bits); an interrupt with no tear status masks the SPI until the
  next vsync tick. More than 1000 interrupts in a second: off for the boot.
- Use: the handler stamps the TE (now minus (line - init) x line time) and 0259's `teTick` takes `sinceTeNs` from that
  stamp (fresh = less than 25 ms old) instead of the counter sample. The vsync tick stays the 0254 timer (an interrupt
  handler cannot use an IOTimerEventSource); its deadline moves by the lock as before. So `negronifb_teirq=1` needs
  `negronifb_te=1` to change the tick phase; alone it only logs.
- Lines: `NEGRONI DPU TE IRQ: before: mdss intr 0x.. top en ../.. status ../.. intf1 en .. status .., tear en .. status ..,
  rd_ptr_irq N init 2412 vsync_count 66, dsi0 int_ctrl 0x..`, `NEGRONI DPU TE IRQ: on: INTID 115 (SPI 83, level), INTF_1
  tear rd_ptr at line 2413 (was N), 3437 ns/line`, per second `NEGRONI DPU TE IRQ: irqs/s 120 rd_ptr 120 foreign 0 (masked 0)
  TE-to-handler us avg/max N/N`. Expected [I]: irqs/s = rd_ptr = te/s of 0259; `foreign` > 0 only during DCS writes if the
  UEFI left a DSI interrupt enable on.
- Risks [I]: first SPI on this port (Gunyah owns the GIC grouping; a write the hypervisor drops = no interrupt, the timer
  path is unchanged); 0288's PSCI CPU idle must wake the routed CPU (GICv3 wake on a pending SPI):
  `negronicpuidle=1` + `negronifb_teirq=1` are untested together (test them apart first).

## 26. DPU/DSI power: what the UEFI leaves on, and the no-transfer idle (0296, `negronifb_pwrprobe`, `negronifb_idle=2`)

File: `bsd/dev/negroni_dpu.c`. Android [V]: `sde_core_perf_crtc_update` sde_core_perf.c:984 (per-frame core clock + BW
votes), `dsi_ctrl_transfer_prepare` dsi_ctrl.c:3560-3605 (DSI clocks + command engine per command), `_sde_encoder_rc_idle`
sde_encoder.c:2207-2262 after 58 ms (sde_encoder.h:55): IRQs off, DSI clocks off, MDSS GDSC put, BW released
(sde_core_perf.c:786); ULPS on idle (`qcom,ulps-enabled` live.dts 35554).

What the display needs and what the UEFI leaves [V = DT/driver source; values on the phone: the probe lines, not seen yet]:

| Item | Register (DISP_CC 0x0af00000, GCC 0x00100000) | Source | Needed with auto-refresh on | May drop with `idle=2` and no frame |
|---|---|---|---|---|
| MDSS GDSC | DISP_CC 0x9000 (gdsc@af09000), int2 0xb000 | live.dts 1030-1055 | yes | no (register state, panel memory in DDR stays; Android collapses it only with a full restore path) |
| AHB (iface) | disp_cc_mdss_ahb 0x80a4, gcc_disp_ahb 0x37004 | mdss_mdp clocks | yes | no (every register access) |
| AXI (bus) | gcc_disp_hf_axi 0x3700c, sf_axi 0x37014 + RPMh BW votes (MM0/SH0, live.dts interconnects) | mdss_mdp clocks/interconnects | yes (fetch) | yes [I] (no fetch) |
| MDP core | disp_cc_mdss_mdp 0x800c, RCG 0x80ec; lut 0x801c; rot 0x8014 | mdss_mdp clocks | yes | yes [I] (no frame, no kick) |
| vsync | disp_cc_mdss_vsync 0x8024, RCG 0x811c (19.2 MHz) | mdss_mdp vsync_clk | yes (tearcheck counter) | no (TE lock and the next kick) |
| DSI byte/intf/pixel | byte0 0x8028, byte0_intf 0x802c, pclk0 0x8004 (RCGs 0x8134, 0x80bc; PLL = DSI PHY) | dsi_ctrl0 clocks | yes (HS link) | yes [I] with ULPS; on before a DCS or a kick |
| DSI escape | esc0 0x8038 (RCG 0x816c) | dsi_ctrl0 clocks | yes (LP DCS) | yes [I] between DCS |
| DSI PHY / vdda-1p2 | PHY regs, RPMh LDO | dsi_ctrl0 supply | yes | only with ULPS (not done) |

- Nothing collapses while the auto-refresh scans: every TE the DPU fetches 10.4 MB and the DSI sends it, so every row
  above stays "yes". This is why 0296 first implements the no-transfer idle; clock gating is the next step (not done:
  turning a branch off with the CBCR enable bit 0 and back needs the PLL/RCG state the probe shows first).
- `negronifb_pwrprobe=1` (read-only, maps DISP_CC 64 KiB and the GCC page 0x134000 with `ml_io_map_unmappable`, unmapped
  after): `NEGRONI DPU PWR: GDSC mdss 0x.. (on|OFF, hw_ctrl N, sw_collapse N) mdss_int2 ...`, `NEGRONI DPU PWR: DISP_CC
  branches ahb 0x.. ON mdp ... esc1 0x.. off`, `NEGRONI DPU PWR: DISP_CC RCGs (cmd/cfg) mdp 0x../0x.. (on src N div N.N)
  ...`, `NEGRONI DPU PWR: GCC disp_ahb ... disp_xo ...`, `NEGRONI DPU PWR: DSI0 ctrl .. status .. clk_ctrl .. clk_status ..
  lane_status .. lane_ctrl .. int_ctrl ..`, `NEGRONI DPU PWR: INTF_1 autorefresh 0x80000001 sync_cfg .., CTL 0x.. flush ..`.
  The BW votes are not readable here [I: XBL's display driver votes them and they stay].
- `negronifb_idle=2`: after `negronifb_idle_ms` (default 58) without a swap: Android's `_sde_encoder_autorefresh_disable_seq1`
  (sde_encoder_phys_cmd.c:2015-2046: TE disconnect = SYNC_CONFIG_VSYNC bit 20 off, AUTOREFRESH_CONFIG bit 31 off, poll until
  INTF_TEAR_LINE_COUNT is not between 1 and 2411 (`is_ongoing_pptx` :798-830), TE back on). Then each new frame (swap id
  written to the panel memory, its GPU copy done) gets one CTL_START (CTL + 0x1c of the CTL 0234 found on INTF_1;
  `trigger_start` :2161-2182, sde_hw_ctl.c:327-334) at the next vsync tick; the next kick waits for that transfer ("pp
  done": one TE since the kick, more than 200 lines past it, no wr_ptr transfer; at most 50 ms). No frame = nothing on the
  link, no fetch: the panel shows its RAM (Android's idle). Display off: auto-refresh back on (the 0275 black frame and the
  0258 sleep need it); after the wake the idle delay starts again. Android's sequence 2
  (`_sde_encoder_autorefresh_disable_seq2` :2051-2127: the MDP-top debug-bus autorefresh status re-check and the
  tearcheck write-count reset) is not ported: only sequence 1 runs. Guards: refused with `negronifb_vrr=1|3`,
  `negronifb_dbuf=1` (0269), `negronifb_zerocopy=1` (0234) or without the 0234 probe; if the INTF frame counter moves under
  the auto-refresh at start but does not move after 3 kicks in a row, the auto-refresh goes back on for the boot ("3 kicks
  sent no frame"); if something else turns the auto-refresh on (0268 re-init), the mode goes back to its auto state.
- Lines: `NEGRONI DPU IDLE: mode 2: after 58 ms without a swap ... INTF frame count A -> B in 30 ms (kicks are checked)`,
  `NEGRONI DPU IDLE: auto-refresh off (0x80000001 -> 0x00000001), transfer over after N us (entry N)`, per second
  `NEGRONI DPU IDLE: no auto-refresh (kick per frame), kicks/s N (busy N, timeouts N), N kicks, N idle entries,
  auto-refresh 0x00000001`, `NEGRONI DPU IDLE: display off: auto-refresh on again (0x80000001)`.
- Proof = the battery current (0270 lines) on a static screen, `negronifb_idle=0` vs `=2`, same brightness, 60 s each.
- Risk [I]: the copy into the single panel buffer can still meet the fetch of the previous kick (as with the auto-refresh
  today); the writer starts before and is faster than the reader, so the panel gets the newer frame whole, not a torn one.
  0269's double buffer removes it but is refused together with `idle=2` until the flip is kicked too.

### Boot-args of 0292-0296 (all default off except `negronifb_tcfg`)

| Boot-arg | Values | Patch | Effect |
|---|---|---|---|
| `negronifb_dsidma` | 0 (default), 1, 2 | 0292 | 1: command sets by batched memory DMA; 2: also single DCS writes |
| `negronifb_vrr_hs` | -1 (default = HS), 0, 1 | 0292 (0259) | DCS mode of the VRR sets; mode 1 is now HS by default |
| `negronifb_esd` | 0 (default), 1, 2 | 0293 | 1: panel ID once + 0x0a check every 5 s with re-init; 2: panel ID only |
| `negronifb_tcfg` | 1 (default), 0 | 0294 | tearcheck vsync_count on a `negronifb_vrr=2` switch |
| `negronifb_teirq` | 0 (default), 1 | 0295 | TE rd_ptr interrupt stamps for the 0259 lock (with `negronifb_te=1`) |
| `negronifb_teirq_intid` | 115 (default) | 0295 | GIC INTID of the MDSS line |
| `negronifb_pwrprobe` | 0 (default), 1 | 0296 | read-only clock/GDSC/DSI dump at start |
| `negronifb_idle` | 0 (default), 2 | 0296 | no-transfer idle (auto-refresh off, CTL_START per frame) |
| `negronifb_idle_ms` | 58 (default, min 20) | 0296 | swap-free time before the auto-refresh goes off |

First phone test (suggested): config args + `negronifb_dsidma=1 negronifb_esd=1 negronifb_pwrprobe=1`; then
`negronifb_te=1 negronifb_teirq=1`; then `negronifb_idle=2` (power A/B with `=0`). Fallback: drop the arg.

### Build (sections 22-26)
Job `dsi-kernel` (`scripts/display/build-dsi.sh`, lock out/kernel/.lock; kernel only, owner rule 2026-10-26): kernel
`out/kernel/local-20261026-174206` sha256 a0b050bf05d91e0878af954bc4a4033899f5977aa734198a24df76d0efb26d3c (after the review fixes: ESD re-init cap 3, read under the set lock, 0294 counter off/on); 233 patches applied incl. 0268, 0269, 0292-0296; skipped: only the 4
usual dxb ones. Not booted. Notes: docs/notes.md section 15 (end); status: docs/plan.md "Display DSI/DPU status".

## 27. KGSL parity from the GPU audit (0298, `0298-negroni-gpu-kgsl-parity.patch`)

Source: `docs/audit/2026-10-26-gpu.md` section 3 (items 2, 3, 4, 6, 8, 9, 10, 11; item 1 = 0287). Files: negroni_adreno.c,
NegroniGPU.cpp. Every item has a boot-arg (1 = on, the default, unless noted). Not booted.

| Item | What 0298 does | KGSL reference [V] | Boot-arg |
|---|---|---|---|
| HWCG | step 20: GMU AO CGC MODE 0x20000 / DELAY 0x10111 / HYST 0x5555, the 53 registers of `gen7_0_0_hwcg_regs` (the gen7_0_1 entry uses that list), RBBM_CLOCK_CNTL 0x8aa8aa82 | adreno_gen7.c:265-300, 557; adreno-gpulist.h gen7_0_0_hwcg_regs, 2079-2110 | `negronigpu_hwcg` |
| Slumber from IFPC | after `negronigpu_ifpc_slumber` ms (2000) with no work in IFPC mode: OOB GPU_SET, then pm_sleep (idle check, PREPARE_SLUMBER, CX_BUSY, RSC sleep) + `gen7_halt_gbif` (client halt, ARB halt, de-assert); the next submit wakes (warm boot), IFPC asked again, OOB released | gmu_idle_check adreno_gen7_gmu.c:2870-2913, gen7_power_off 2795-2868, gen7_gmu_power_off 2513-2560, gen7_halt_gbif 2492-2511 | `negronigpu_ifpc_slumber` (0 = never) |
| TLB flush + FSR on wake | every warm boot (slumber wake, 0287 recovery): both SMMU contexts' FSR printed and cleared, TLBIASID + TLBSYNC | adreno_gen7_gmu.c:1887-1892 (`kgsl_mmu_flush_tlb`) | - |
| DCVS busy counter | step 20 enables GMU power counter 0 (AO CX_BUSY_MASK 0xff000000, SELECT_0 low byte 0x20, ENABLE 1); each DCVS tick: busy = XOCLK_0 delta / AO delta >= `negronigpu_busy_pct` (50 %); no movement for 50 ticks with work queued -> the fence rule (logged once). The pm part of the WATCH line ends with `busy N%` (IFPC mode) | adreno_gen7.c:521-523, gen7_power_stats 1392-1405 | `negronigpu_busy_pct` (0 = fence rule) |
| CP_PROTECT | CP_PROTECT_CNTL BIT(0,1,3), 45 ranges of `gen7_0_0_protected_regs` | adreno_gen7.c:225-258 | `negronigpu_protect` |
| CHICKEN_DBG | CP_CHICKEN_DBG, CP_BV_CHICKEN_DBG, CP_LPAC_CHICKEN_DBG = 1 (icache prefetch off on gen7_0_x) | adreno_gen7.c:544-549 | `negronigpu_chicken` |
| ME_INIT BIT(11) | DMS off (gen7_0_1 has no ADRENO_DMS) | adreno_gen7.c:124-126 | `negronigpu_dms` |
| rptr shadow | RB_CNTL without BIT(27): the CP writes its read pointer to scratch +0x80; IFPC ring room from it (not from the 256-entry fence estimate) | adreno_gen7.h:186-188, adreno_ringbuffer.c:67-104 | `negronigpu_rptr_shadow` |
| HFI timeout | 100 ms per ack after the boot ladder (`pm_start`); the ladder keeps 1000 ms (proven) | adreno_hfi.h:404 (HFI_RSP_TIMEOUT) | `negronigpu_hfi_ms` (10..1000) |
| Guard page | one shared writable page mapped for PAGE_SIZE after every buffer at a kernel-chosen GPU address (GL path); client addresses (SET_IOVA, Turnip) get none | audit 1.5 (bergamota lesson, gpu-status.md) | `negronigpu_guard` |
| Bus votes | the 12 DDR rows computed from cmd-db SH0 (bus width 16), MC0 (4), ACV (fixed) aux data {unit, width, vcd} and the DT `bus-table-ddr` (KBps); wait mask from the vcds; CNOC CN0 (width 4) for `bus-table-cnoc <0 100>`; a BCM missing from cmd-db keeps the Linux constants. Log: the 3 sample rows next to the old constants and how many words differ | adreno_gen7_rpmh.c:121-260 (tcs_cmd_data, build_rpmh_bw_votes), 415-497 (build_bw_table); DT out/live.dts:21078-21079 | `negronigpu_bwcalc`, `negronigpu_cnoc` |
| DCVS bw index | the DT `bus-freq` of each level (818/791 -> 11, 734/640 -> 10, 599/545 -> 8, 492/421 -> 6, 350 -> 3, 317/285/220 -> 2) instead of the 0281 linear ramp | DT 21096-21205; kgsl_pwrctrl.c:207-287 | `negronigpu_bwdt` |

Left out (document only):
- **ACD** (audit item 5): KGSL sends an ACD table from the DT `qcom,acd-level` values and FEATURE_CTRL ACD, and before that an
  AOP QMP mailbox message `{class: gpu, res: acd, val: 1}` (adreno_gen7_gmu.c:1729-1751, 2104-2146; adreno_gen7_hfi.c:540-561).
  Nothing in the tree talks QMP; a wrong ACD table can under-volt the GPU. Next step when QMP exists.
- **Preemption** (audit 1.6, item 12): one ring, one priority; iOS has one GPU client that matters (backboardd).
- **Completion interrupt** (audit item 7): not in the brief; polling stays.

Expected lines [I, not booted]:
- step 17: `17 BCM cmd-db: SH0 unit U width W vcd V, MC0 ..., ACV vcd V (complete)`, `17 bw level 11 (13085937 KBps): SH0 ... (Linux
  constants 0x600030ae 0x60003fe5 0x60000008)`, `17 bw table: computed from cmd-db; N of 36 words differ ...`, `17 CNOC CN0 ...: votes ...`;
  N = 0 means our constants were already this phone's.
- step 20: `20 KGSL settings (0298): busy counter on, CP_PROTECT on (45 ranges), CHICKEN_DBG 1, HWCG on (53 registers, RBBM_CLOCK_CNTL
  0x8aa8aa82), rptr shadow on, ME_INIT DMS off (BIT(11))`, then `20 THE 3D CORE TAKES COMMANDS` as before.
- `NEGRONI GPU PM: IFPC mode slumbers after 2000 ms idle ...; HFI timeout 100 ms`; WATCH `| pm ifpc GX collapsed N% ... slumbers N wakes N
  busy N% |`; `NEGRONI GPU PM: slumber N in N us ...`, `first wake ...`, `wake N in N us`.
- `RedwoodGPU: guard page 0x... after every kernel-placed buffer (0298 ...)` at the first GL buffer.

Risks [I]:
- HWCG, CP_PROTECT, CHICKEN_DBG and DMS change GPU behaviour that the booted images never had. A step-20 or first-submit failure, a
  `CP_HW_FAULT` (protect violation) or a hang right after boot: bisect with `negronigpu_protect=0`, then `negronigpu_hwcg=0`,
  `negronigpu_chicken=0 negronigpu_dms=0`. A protect fault from a user IB is now caught by 0287 (recovery) instead of a stop.
- The slumber wake was never run on the phone (the booted 0285 image stayed in IFPC); a failed wake = `pm_dead` (GPU stopped, as
  before). `negronigpu_ifpc_slumber=0` keeps IFPC only.
- The computed bus votes may differ from the constants; a wrong vote can starve or overfeed DDR. `negronigpu_bwcalc=0` restores the
  constants, `negronigpu_cnoc=0` drops the CNOC vote.
- 100 ms HFI timeout: a slow but alive GMU now fails a vote in 100 ms (logged; DCVS retries at the next tick).

Build 2026-10-26 18:47 (job `gpur2-kernel`, all patches up to 0298, the 4 usual dxb skips; compile-one 0 errors): kernel
`out/kernel/local-20261026-131716` (sha256 7804fca89c4e08e9a1a75f9bc3ba70e3be9171442c6e09d50072afa5ce80332a); `out/ios16-gpur` rebuilt
with it (boot_a 526eba93e7e6b7a20e56ba767ea26fc2c011fde4e7cd22a46a4d28b491b3d066; args: config + `negronigpu_recover=1 negronicpuidle=1
negronipanic=30 negronipanicreason=2`, so the 0298 defaults are on). Not booted.
Review fix F3 (a computed DDR vote below the Linux constant keeps the constant, logged `... constant kept`): kernel
`out/kernel/local-20261026-174403` (sha256 dfa9a8a550ecc79d89b7478f1c3217850b55efb9c8cacd124893cf26346e887e), no image.
Proof build after the review fixes (kernel only, no image: owner rule): `out/kernel/local-20261026-131404` (sha256
3bae1cc92b09479557481b9115b92b7e460c00fb21bf8c0da76265d9ca930b83). `out/ios16-dpu` still holds the first kernel
(dc55e5fd...); the fixes change only a log text and a bound that today's geometry already met.

## 28. GPU governor, fence interrupt, slumber fix (0384, `0384-negroni-gpu-governor-irq.patch`)

Owner (2026-10-27): "GPU acceleration is iffy", the phone runs hot. Files: negroni_adreno.c, NegroniGPU.cpp (1 call),
NegroniFramebuffer.cpp (2 calls). Config: `negronigpu_level=12` removed from config/negroni-ne2211.toml.

### What the logs show (before 0384)
- [V] IFPC is accepted and turned on at boot (bootlog-13.txt:578 `FEATURE_CTRL IFPC ACCEPTED`, :784 `IFPC on: OOB GPU_SET
  released`). About 1 s later the 0298 IFPC-mode slumber tries 3 times and fails: `17 HFI PREPARE_SLUMBER ack, error 1002`,
  `PREPARE_SLUMBER not acked (1..3); GX held again`, `slumber off for this boot` (bootlog-13.txt:1693-1758; the same in
  bootlog-3/6/11 and usblog-20261027-060101.txt:732-797, usblog-20261027-121304.txt:3255-3306).
- [V code] The third failure sets `pm_mode = PM_OFF` with OOB GPU_SET held. From then on the GMU never collapses GX: every
  WATCH line says `pm off` and `GX 0xf8222800` (GDSC bit 31 PWR_ON = 1): bootlog-12.txt 3819 of 3819 WATCH lines over a
  7.1 h boot; usblog-20261027-121304.txt all 400. This is the main idle cost: GX powered for the whole boot.
- [V] The 0285 build without 0298 (usblog-20261026-131747.txt) ran IFPC: `GX collapsed 100%` (:1030), 40-75 % while in use,
  WPTR writes `dropped 9..13 times (GX collapsed), taken after 262..326 us` (:1436-1508).
- [V] The level follows the vote: `gxclk 349 MHz` at level 4 (100 lines), `639 MHz` at level 9 (86 lines),
  usblog-20261027-121304.txt. With `negronigpu_level=12` the 0281 DCVS used 12 as its max, not as a fixed level.
- [V] The 0286 UI floor holds level 9 (640 MHz) and the DT bus vote 10 while the UI swaps 30/s or more: bootlog-12.txt has
  level 9 in 3482 of 3819 WATCH lines, and the GMU busy share was 0 % in 3768 of them (the DCVS `busy` value).
- [V] Frames wait for the GPU even at 640 MHz: usblog-20261027-121304.txt, 445 STAT seconds: swaps 6510, presents 6218,
  `gpu-wait skips` 3112 (a vsync tick where the frame's fence was not written yet: the frame waits one more tick), swapwait
  `timeouts` 4013 (CA's non-blocking check found the frame not on screen yet), `gave up on fence` once (:11315), swaps/s
  max 59 (no 120 Hz content). [I] At busy 0 % the cause is the fence latency of the polled path and the submit time in the
  frame, not the clock.
- [V] No `GPU RECOVERY`, no `no answer for 2 s`, no `RedwoodGPU ... stops` in any 2026-10-27 log: no hangs.
- [V] Metal client crashes are userland: AegirPoster starts 74 times in usblog-20261027-121304.txt; the first run ends with
  `NMTL[298 AegirPoster]: uncaught exception CAMetalLayerInvalid: unsupported extended range format` (:111) and SIGABRT; after
  4 strikes the dead-man gives it no Metal device and it still aborts (`CRASH AegirPoster ... sig 6`, 73 times). Also
  MusicWidgets SIGSEGV (6), assetsd SIGABRT (9). Not in this patch (external/metal2vulkan; CAMetalLayer pixel format).
- [I] Screen off: no log has a long display-off period (usblog-20261027-121304.txt:5423 brightness 0 for 1 s only). With
  `pm off` GX stays on with the screen off too, by the code.

### KGSL facts used [V code, out/src/op-kernel/drivers/gpu/msm]
- `gen7_gmu_notify_slumber` (adreno_gen7_gmu.c:1424-1450): GMU power counter OFF first ("so that the GMU is not busy"), then
  PREPARE_SLUMBER `{freq = gpu_level_num - default_pwrlevel - 1, bw = bus-freq of default_pwrlevel}`; fence to ALLOW.
  DT `qcom,initial-pwrlevel = <0x0a>` (285 MHz, bus-freq 2) -> freq index 2, bw 2. 0298 sent `{0, 0}` with the counter on.
- `gen7_gmu_power_off` (:2513-2560) waits for the lowest idle level first (`gen7_gmu_wait_for_lowest_idle` :696-760: power state
  3 = IFPC and the GX clock or GDSC off, 100 ms); `gen7_power_off` (:2795-2833) masks interrupts and clears OOB first.
- Fence interrupt: ring end `CP_EVENT_WRITE CACHE_CLEAN | BIT(31) | BIT(27)` (adreno_gen7_ringbuffer.c:372-379);
  `GEN7_INT_MASK` includes RB_DONE_TS (17) and CACHE_CLEAN_TS (20) (adreno_gen7.h:193-206, gen7_reg.h:24-25);
  RBBM_INT_0_MASK 0x38 / CLEAR_CMD 0x37 (gen7_reg.h:607-608), written once per GPU boot (adreno_gen7_gmu.c:2578);
  `gen7_irq_handler` (adreno_gen7.c:1194-1222): PWR_COL_KEEPALIVE (0x1f8c3) 1, AHB fence ALLOW poll (100 x 1 us,
  `gen7_irq_poll_fence` :1153-1190), read INT_0_STATUS, write CLEAR_CMD, keepalive 0. DT: `interrupts = <0 0x12c 4>`
  `kgsl_3d0_irq` (out/live.dts:21063) = SPI 300 = INTID 332, level.
- DT OPPs (out/live.dts:21087-21210): 12 levels 818..220 MHz with `qcom,bus-freq` 11, 11, 10, 10, 8, 8, 6, 6, 3, 2, 2, 2
  (our perf levels 12..1; 0298 `dcvs_bw_for` already maps them).

### What 0384 does
1. Slumber fix (default on). IFPC mode never goes to `PM_OFF` on a slumber failure: after 3 failures only the IFPC-mode
   slumber stops (`IFPC-mode slumber off for this boot; IFPC stays on`) and OOB GPU_SET goes back to the GMU, so IFPC
   collapses GX again. `pm_sleep` follows KGSL: IRQ off, OOB clear, wait for the lowest idle (IFPC: power state 3 and
   GFX_PWR_CLK_STATUS bit 0 or 1; else no slumber now, after 3 such misses it sends anyway), GMU power counter off,
   PREPARE_SLUMBER `{bw 2, freq 2}`. A failure turns the counter on again and logs the ack word.
2. Slumber only with the display off (`negronigpu_dispoff_slumber=1`, default): the FB's power request (backboardd, 0258)
   calls `negroni_gpu_display()`. The IFPC-mode slumber runs after `negronigpu_ifpc_slumber` ms (2000) of no work while
   the display is off. Display on: IFPC only (GX collapses 300 us after each submission; no warm boot per frame).
3. Slumber wake retry: a failed warm boot gets the 0287 reset (CM3 reset, GBIF halts, RSC sleep) and one more warm boot
   (up to 8 per boot) before `pm_dead`.
4. Governor (`negronigpu_gov=1`, default): Linux simple_ondemand (governor_simpleondemand.c) on the GMU busy counter of each
   watch tick (100 ms while busy, 250 ms idle): busy > up (90 %) -> the top allowed level; > up - down (85 %) -> stay; else
   the lowest DT level >= cur MHz x busy / (up - down/2). Levels 1..12 (220..818 MHz), bus vote = the level's DT bus-freq.
   No work -> busy 0 -> level 1 (220 MHz, bus 2). Display off -> level 1 at once. A frame the display held for the GPU
   (FB `gpu-wait skips`) in a tick with busy >= 10 % -> one level up. Thermal cap (0280) still wins. No UI floor unless
   `negronigpu_uifloor=N` is given. Without the busy counter, a tick with work queued is 100 % (the fence rule). A tick with
   the counter on but no sample (the first after a wake or a recovery) keeps the level (review fix: no jump to 818 MHz).
   `negronigpu_level=N` is now a fixed level: the governor is off (`NEGRONI GPU DCVS: off: fixed level N`).
5. Fence interrupt (`negronigpu_irq=1`, default): GIC SPI 300 through `negroni_spi_register` (0295's slot table; the DPU TE
   IRQ uses one of 4 slots); RBBM_INT_0_MASK = bits 17 and 20, written at `pm_start` and at the end of every warm boot (GX
   held); the last fence write of each submission has the IRQ bit. The handler is KGSL's (keepalive, fence poll, status,
   clear) and wakes all fence waiters. RedwoodGPU's `gpuWait` (every client wait, the present, the FB waits) sleeps on the
   event instead of `delay_for_interval(200 us)`; with the interrupt live it still looks every `negronigpu_irq_poll_us`
   (1000 us) as the polled fallback. Not armed while GX is in a transition: disarmed (and masked at the GIC) in
   `pm_sleep`, `rec_reset` and `gpu_warm_boot`, armed at their end; the handler masks the line when GX is off or the AHB
   fence holds, and the watch unmasks it each second. More than 20000 interrupts in a second: off for the boot.

### Boot-args (0384)
| Boot-arg | Default | Meaning |
|---|---|---|
| `negronigpu_gov` | 1 | 1 = simple_ondemand; 0 = the 0281/0286 step rule (floor 4, UI floor 9) |
| `negronigpu_up` / `negronigpu_down` | 90 / 5 | simple_ondemand upthreshold / downdifferential (%) |
| `negronigpu_minlevel` / `negronigpu_maxlevel` | 1 / 12 | governor range (220..818 MHz) |
| `negronigpu_late_pct` | 10 | late-frame step at this busy share or more; 0 = off |
| `negronigpu_uifloor` | 0 with gov 1 | 0286 UI floor level (old default 9) |
| `negronigpu_level` | unset | N = fixed level, governor off |
| `negronigpu_irq` | 1 | 0 = polled fences only (200 us) |
| `negronigpu_irq_poll_us` | 1000 | fallback look of a waiter while the interrupt is live (100..20000) |
| `negronigpu_irq_intid` | 332 | GIC INTID of kgsl_3d0_irq |
| `negronigpu_dispoff_slumber` | 1 | 0 = IFPC-mode slumber also with the display on (0298 behaviour) |

### Expected lines [I, not booted]
- `NEGRONI GPU IRQ: on: INTID 332 (SPI 300, level), RBBM_INT_0_MASK 0x120000 ...` after `IFPC mode slumbers after 2000 ms idle
  with the display off ...` and `IFPC on: OOB GPU_SET released ...`.
- `NEGRONI GPU DCVS: on (0384 simple_ondemand): start level 1 (220 MHz), levels 1..12 (220..818 MHz), up 90% down 5% ...`.
- Per second with changes: `NEGRONI GPU DCVS: level A -> B (M MHz, bw W), N changes this second, busy P% (GMU counter, last
  tick Q%), cap 12, display on, late frames L (S steps), top jumps T, ui U swaps/s`.
- WATCH: `... | dcvs L busy N% gov P% | pm ifpc GX collapsed N% gmu N% pwr 0x3 ... slumbers N wakes N busy N% | ...` (not
  `pm off`), then `NEGRONI GPU IRQ: irq live N/s fence N/s woke N missed N | all ... gx-off ... held ... unarmed ... bits 0x...`.
- Display off for > 2 s: `NEGRONI GPU PM: slumber N in N us: GMU idle, GX off ...`; display on: `first wake: steps 14-21 again`,
  `wake N in N us (asleep N ms)`. A refused slumber: `PREPARE_SLUMBER not acked (n; lowest idle reached, ack word 2 = E)`, at 3:
  `IFPC-mode slumber off for this boot; IFPC stays on` (WATCH keeps `pm ifpc`).

### Phone test plan (in this order)
1. Boot the image. Proof: the lines above; WATCH `pm ifpc` (never `pm off`); `GX collapsed` > 50 % with the UI still.
2. UI still for 10 s: DCVS goes to level 1 (`-> 1 (220 MHz, bw 2)`), `gov 0..5%`. Scroll a list for 10 s: the level rises
   (busy > 85 % -> 12), and falls again 1-2 s after; FB STAT `gpu-wait skips` per second at or below the old 0-40.
3. IRQ: `NEGRONI GPU IRQ: irq live` with `fence N/s` near the submissions, `woke` high, `missed` near 0. `irq armed` with
   `fence 0/s` while the UI moves = no interrupt arrives (check `bits`, `gx-off`, `held`); waiters then poll (no harm).
4. Screen off (power key) for 30 s, then on: `display off` in the DCVS line and level 1; `slumber 1 in N us`; WATCH
   `ifpc (asleep)`; on screen-on `first wake: steps 14-21 again` then `wake 1 in N us`, the UI draws. Repeat 5 times.
5. Compare THERMAL `gpu` and battery current with the 0298 image under the same use (expected lower).
Back-out: `negronigpu_irq=0` (polled), `negronigpu_dispoff_slumber=1 negronigpu_ifpc_slumber=0` (IFPC only, no slumber),
`negronigpu_gov=0` (old step rule), `negronigpu_level=12` (fixed 818 MHz;
not as before: the 0281 DCVS used 12 as its max; a fixed level has no DCVS, so the 0280 thermal cap does not act).

### Risks [I]
- The wake from slumber never ran on the phone. A failed wake + failed retry = `pm_dead`: the GPU stays off, the UI goes on
  with CPU copies (0254 give-up). Back-out: `negronigpu_ifpc_slumber=0`.
- PREPARE_SLUMBER may still be refused (error 1002 has no name in KGSL). Then the slumber stops after 3 tries and IFPC stays:
  the idle cost is still far below `pm off`.
- The interrupt line may not assert (wrong INTID, or the GIC group setting): then `irq armed`, `fence 0/s`, waiters poll every
  200 us as before. A level storm: off after 1 s (> 20000).
- simple_ondemand jumps to 818 MHz at busy > 90 %: short bursts at the top level. `negronigpu_maxlevel` limits it.
- 220 MHz at low load: frames that are short but late (submitted near the tick) may wait one more tick; the late-frame step
  lifts the level only when busy >= 10 %.

### Build
2026-10-27 16:38, job `gpudcvs-kernel` (scripts/kernel/build-local.sh, all patches/xnu up to 0384, the 4 usual dxb skips, 0 compile
errors, no new warnings in the 3 files against the unpatched tree): kernel `out/kernel/local-20261027-110800`
(sha256 cee20b34f7e6e935d98021c656795df5a09b7d6e50a74f798a31829bf3825dbc). No image (owner rule: one image at the end). Not booted.

## 29. Frame pacing for 120 Hz: GPU pacing floor, GPU copy behind newer work, TE lock on the interrupt (0389, `0389-negroni-gpu-frame-pace.patch`)

Owner goal: smooth 120 Hz. Files: negroni_adreno.c (governor: TZ port, pacing floor, input boost), NegroniFramebuffer.cpp (present, teTick), negroni_dpu.c
(TE count), negroni_touch.c (1 call). Analysis tool: `scripts/display/fbstat-report.py LOG [--from T --to T]`.

### What the log shows [V logs/usblog-20261027-171256.txt 17:12:56-19:14:00, config args with negronifb_te=1 vrr=1 dbuf=1 teirq=1]
- 5503 FB STAT seconds, 2653 active (swaps/s >= 10). Active means: swaps 19.3, presents 18.7, gpu-wait skips 11.0,
  swapwait busy 8.1, late ticks 1.2. Totals: 29143 skips for 49620 presents (59 %), 0.42 busy answers per swap.
- The 242 seconds with >= 40 swaps/s (scrolling, app switches), by presents/s:
  - 40-60 (n 123): skips 16.0/s, busy answers 43.5/s, late ticks 3.2/s, copy max 6971 us, DCVS 9.2 changes/s, 378 MHz.
  - 60-80 (n 25): skips 11.6, late 0.6, copy max 2661 us, 289 MHz.
  - 80-100 (n 24): skips 1.7, copy max 842 us.
  - 100-130 (n 37): skips 0.1, late 0.1, copy max 537 us (example 18:39:35-47: 99-119 presents/s at 220 MHz, 0 skips).
  - corr(skips, presents/s) = -0.72; corr(swapwait busy, presents/s) = -0.31.
- GPU clock: in the 1160 active seconds with >= 10 skips the DCVS line changed the level 8.2 times a second (the 0384
  late-frame step goes up, the busy rule comes down at the next tick: GMU busy 20-30 % because the GPU idles between
  frames), end level 363 MHz mean; 841 of 1238 DCVS lines in active seconds end at level <= 3 (<= 317 MHz). Example
  19:08:22-34: levels 1 -> 9 -> 3 -> 1 -> 7 -> 1 -> 6 -> 1 in 12 s, 8-46 skips/s, 8-78 presents/s.
- CPU copies: in the seconds with >= 40 swaps, cpu 3.5 frames/s at 4-7 ms each on the vsync tick (copy max 4711 us mean)
  and late ticks 2.4/s. Cause [V code]: a GPU-rendered layer whose surface is listed in newer in-flight work (Turnip lists
  every BO in every submit) is "behind" (0254) and goes the CPU way; the tick sends CA's vsync notification after it (0267).
- TE lock: in 3175 seconds with autorefresh 0x80000001 (120 Hz) the 0259 lock had 7196 samples and 371186 "no sample"
  ticks: `te/s 0 ... locked 0/0 ticks (no sample 121)`. The INT_COUNT_VAL frame field does not move while the auto-refresh
  sends every frame, and teTick returned before it used the 0295 stamp. Same seconds: `DPU TE IRQ: irqs/s 120 rd_ptr 120`.
  So the 120 Hz tick ran free against the panel TE (the flip of 0269 is taken at the next TE after the tick).
- VRR wake: presents/s in the wake second and the next two: 11.2, 15.2, 14.6 (the first frames run at level 1).
- Not a limit: DBUF waits 0.1/s; gave-up 0; zc 0.
- [I] Long 10-19 swaps/s stretches (69 % of active seconds; 19:09-19:28 almost only those) with one skip per frame: a
  low-rate animation, not the UI at its limit (GMU busy 10 %). 0389 leaves it alone (below the 2-of-12 rule).

### What 0389 does
1. Frame-pacing floor in the 0384 governor (negroni_adreno.c `pace_tick`). Per governor tick (100 ms while busy): if the UI
   swapped and the FB held a frame for the GPU in >= 2 of the 12 vsync ticks (`negroni_gpu_late_frames`), the floor =
   max(floor, level) + 1 (+ 2 at >= 6). No late tick for 500 ms: floor - 1, then - 1 every 200 ms until a tick is late
   again; a step down that was late makes the next step down wait 2000 ms. No swap for 300 ms: floor 0 (simple_ondemand
   alone, level 1 when idle), the level is remembered; the next burst starts one level under it (forgotten after 10 s
   idle). Display off: floor 0. The thermal cap (0280) and `negronigpu_maxlevel` still win. The late-frame counter is read
   once per tick (before: only inside gov_want).
2. GPU copy behind newer work (NegroniFramebuffer.cpp present): with 0269 on, a "behind" layer whose swap-time fence is done
   is copied by the 2D engine into a back buffer (not the shown or the flipped one); the copy waits behind the newer work on
   the in-order ring and dbufTick flips the buffer only after its fence: no 4-7 ms CPU copy on the tick, no tear. Not with
   badges or the fingerprint highlight (presentFinish would wait for that copy). STAT gets ` gpu-behind N` at the end.
3. TE lock on the interrupt (teTick, negroni_dpu.c `negroni_dpu_te_count`): with the 0295 rd_ptr interrupt live and its stamp
   fresh (< 25 ms), the TE count and the last TE stamp come from the interrupt (seqlock against the handler); the TE period
   is measured between stamps over >= 1 s and sets the tick period (within 15 % of nominal); the phase is the stamp's age
   at the deadline. Without the interrupt, or with a stale stamp (VRR idle), the 0259 counter path as before.

4. Input boost (negroni_adreno.c `negroni_input_boost`, called by negroni_touch.c `touch_report` on each finger-down or
   move report): while the pacing floor is on and the display is on, the governor level is at least 6 (492 MHz, bus 6) for
   200 ms after the last report; the watch is woken at once from its 250 ms idle tick. The pacing floor can still go higher.
   This is the one input-boost hook: the CPU side (owned by the CPU-scheduler agent) may add its own call inside it.

5. GPU governor = msm_adreno_tz (the Android governor of this phone), ported (`negronigpu_tz=0` = off; then the 0384
   simple_ondemand decides). Sources pinned by `scripts/setup/fetch-gpu-governor-sources.sh`: OnePlusOSS
   android_kernel_oneplus_sm8450, branch oneplus/sm8450_b_16.0_oneplus_10_pro, commit e9da592 (QCOM
   AU_LINUX_KERNEL.PLATFORM.1.0.R1.00.00.00.000.130), GPL-2.0-only. The level decision runs in TrustZone (SCM service
   DCVS 0x0d), as on Android; our kernel does what governor_msm_adreno_tz.c and kgsl_pwrscale.c do around it.
   Self-check: is-call-available for DCVS INIT/UPDATE/RESET, then DCVS_INIT_V2 must answer 0 and version 0; else one
   `NEGRONI GPU TZ: off: <reason>` line and simple_ondemand. Three failed DCVS_UPDATE_V2 in a row: the same at runtime.
   The pacing floor (1) and the input boost (4) stay on top of the TZ level (Android does input/frame boosts in userspace).

### Android -> our function (0389 governor)
| Android (commit e9da592) | Ours (negroni_adreno.c) | Notes |
|---|---|---|
| governor_msm_adreno_tz.c `tz_start` + `tz_init` (qcom_scm_dcvs_core_available, qcom_scm_dcvs_init_v2) | `tz_start()` | table `{n, freq_table[] in Hz}`, pwrlevel 0 = 818 MHz .. 11 = 220 MHz (live.dts qcom,gpu-pwrlevel@0..11); buffer page cleaned from the cache (dma_sync_single_for_device); no shmbridge: if TZ refuses the plain page, TZ is off |
| `tz_get_target_freq` (FLOOR 5000 us, MIN_BUSY 1000 us, CEILING 50000 us, mod_percent 100, bin) | `tz_want()` | same constants and order; `val = -level` burst to the top; level clamped to 0..max_state-1, then to our min/max/thermal cap |
| `__secure_tz_update_entry3` -> qcom_scm_dcvs_update_v2 (svc 0x0d cmd 0x0a, 3 values) | `scm_quiet(... TZ_DCVS_UPDATE_V2 ...)` | result[0] = the level step |
| `tz_suspend` -> qcom_scm_dcvs_reset (cmd 0x07) | `tz_reset()` | at display off (the GPU's lowest level, KGSL: GPU suspend) |
| context-aware DCVS (`tz_init_ca`, `qcom,enable-ca-jump`) | not ported | not in live.dts |
| kgsl_pwrscale.c `polling_ms = 10`, KGSL_GOVERNOR_CALL_INTERVAL 10000 us | watch tick `TZ_POLL_MS` 10 ms while the GPU works | 100 ms (DCVS_TICK_MS) without TZ |
| adreno_gen7.c `gen7_power_stats`: busy = GMU POWER_COUNTER_XOCLK_0 x 10 / 192 | `busy_counter_pct()` -> `busy_tick_xo/ao` | total = GMU always-on counter delta (19.2 MHz), the same unit |
| adreno_gen7_gmu.c `gen7_gmu_dcvs_set` (HFI H2F_MSG_GX_BW_PERF_VOTE, ack block, freq = gpu_level_num - pwrlevel - 1, bw = the level's bus index) | `dcvs_tick()` -> `hfi_send("GX_BW_PERF_VOTE")` (0281/0298) | unchanged; bus = DT qcom,bus-freq of the level (`dcvs_bw_for`, 0298) |
| governor_gpubw_mon.c (bus level between qcom,bus-min/max from GBIF RAM time/wait) | not ported | needs the GBIF RAM counters (gen7_read_bus_stats); the default per-level bus-freq is KGSL's vote without it |
| userspace input boost (Android PowerHAL / perf HAL GPU min freq on touch) | `negroni_input_boost()` (item 4) | kernel hook from negroni_touch.c |

### Coordinator questions (2026-10-27) [V same log]
- Under-used GPU: yes. In the 1160 active seconds with >= 10 skips the GMU busy share was 23 % mean and the level changed
  8.2 times a second (ping-pong 1 <-> 9 in places); frames are late while the GPU is mostly idle: latency, not throughput.
  0389 items 1 and 4.
- Fence interrupt: live, not the limit. `GPU IRQ: irq live N/s fence N/s woke W missed 0` in all 3651 lines: 1-80 fence
  interrupts a second, missed 0, `woke` small because few kernel threads sleep on a fence (the FB tick never waits: it asks
  NegroniGPUFenceDone at each tick; RedwoodGPU gpuWait sleeps on the interrupt with the 1000 us look as fallback). The 0-8.3 ms
  tick quantization is the cost, not the fence path.
- CPU clusters (owned by the CPU agent, not changed here): in the 135 seconds with >= 40 swaps and a CPUFREQ line, the slow
  ones (presents < 60, n 82) had d1 1985 MHz (busy 55 %, LMH 1721) and d2 1728 MHz (busy 39 %, LMH 2183); the fast ones
  (presents >= 100, n 20) had d1 926 / d2 898 MHz. So the big clusters do ramp in heavy seconds; d1 sat at its LMH limit in
  124 of 135 seconds and d0 (little) was 74-79 % busy at 1775 MHz. [I] Thread placement of backboardd's render thread is unknown.

### Boot-args (kill switches only)
| Boot-arg | Default | Meaning |
|---|---|---|
| `negronigpu_pace` | 1 | 0 = no pacing floor (0384 as before). Off by itself with `negronigpu_level=N`, `negronigpu_gov=0`, `negronigpu_dcvs=0` |
| `negronigpu_inputboost` | 1 | 0 = no level floor at touch. Off by itself when the pacing floor is off |
| `negronigpu_tz` | 1 | 0 = no TrustZone DCVS (simple_ondemand 0384). Off by itself when TZ has no DCVS service or refuses the init |
| `negronifb_gpubehind` | 1 | 0 = behind layers go the CPU way (0254). Off by itself without 0269 (`negronifb_dbuf=1`) |
| `negronifb_te` | 0 (config 1) | the TE lock (0259); 0389 changes only its TE source |

### Log lines
- Start: `NEGRONI GPU PACE: on (0389): ...` or `NEGRONI GPU PACE: off: <reason>`; `NEGRONI FB: 0389 GPU copy behind newer GPU
  work on (into a back buffer)` or `off: ...`; `NEGRONI FB TE: 0389 lock on the rd_ptr interrupt's TE count and stamp ...`
  once at the first interrupt sample.
- Start: `NEGRONI GPU PACE: input boost on: level 6 (492 MHz) or more for 200 ms after each touch report ...` or `off ...`.
  The per-second PACE line has `input ticks N (reports N)`.
- Start: `NEGRONI GPU TZ: on (0389, msm_adreno_tz port): 12 levels 220..818 MHz to TrustZone (DCVS_INIT_V2 version 0), poll
  10 ms, ...` or `NEGRONI GPU TZ: off: <reason>`. Per second with TZ calls: `NEGRONI GPU TZ: N updates (U up, D down, B busy
  bursts to the top), level L (M MHz)`.
- Per second while the floor is on or moved: `NEGRONI GPU PACE: floor F (max M this second), level L (N MHz), held frames H,
  swaps S, raises R decays D resumes U, cap C`. Once: `NEGRONI GPU PACE: at the top allowed level ... for N ms and frames still
  wait: the render time, not the clock, limits the frame rate now`.
- First 4 behind copies: `NEGRONI FB: 0389 frame N: GPU copy of surface S behind newer GPU work (fence F, surface now at G) into
  panel buffer B, no CPU copy`.

### Expected on the phone [I, not booted]
- Scroll Settings for 10 s: `FB STAT` presents/s >= 100 in most seconds where the old kernel showed 40-80; `gpu-wait skips`
  < 5/s; `cpu` 0 and `gpu-behind` 1-5/s instead; `late ticks` 0; `copy max` < 1000 us. `GPU PACE` floor 5-9 while the
  content is heavy, then down; DCVS changes per second 1-3 instead of 8-10.
- `FB TE: te/s 120 period us 8333 ... locked >= 110/120 ticks (no sample ~0)` with autorefresh 0x80000001.
- `DBUF latch max us` <= 8400 (one TE) instead of up to 16756.
- Heat: the floor holds a higher GPU level only while frames are late; idle and low-rate animation stay at level 1.
- `scripts/display/fbstat-report.py logs/usblog.log --from HH:MM:SS` gives the same tables for the new boot.

### Risks [I]
- More GPU power while the UI is heavy (up to 818 MHz for seconds). The thermal cap limits it; `negronigpu_pace=0` = 0384.
- The pacing floor follows only the FB's held frames: a Metal app that renders off-screen without swaps gets no floor.
- A behind copy shows its frame later (after the newer work); the newest done buffer is flipped, so a frame can be skipped
  instead of shown late. With 3 panel buffers a second behind copy can find no free buffer (`DBUF waits`): the frame then
  stays pending one tick.
- The TE lock now moves the tick by up to a quarter period per tick while it locks (the first second): a few late ticks.
  `negronifb_te=0` = free-running tick.

### Verification
- TZ part: compile-one OK; [I] not run: whether TrustZone accepts DCVS_INIT_V2 from a plain page (Linux uses the shm bridge
  on this SoC) is seen only at boot (`NEGRONI GPU TZ: on|off`).
- Host test `patches/xnu/tests/gpu-pace-test.c` (pace_tick, same code): light UI no floor; heavy UI (needs level 7) reached in
  300 ms, then levels 6-7, late in 8 of 100 ticks; lighter content down to <= 3 in 1.9 s; pause -> floor 0, next burst at 6+;
  thermal max wins; display off; 10 fps animation with 1 held tick per 100 ms -> no floor: PASS.
- Compile: `scripts/kernel/compile-one.sh` on a STAGE=0 scratch tree with all patches/xnu up to 0388 + 0389: negroni_adreno.c,
  negroni_dpu.c, negroni_touch.c, NegroniFramebuffer.cpp OK, no new warning in the four files (negroni_adreno.c keeps its 3 old ones).
  0390 (NegroniSurface.cpp) applies after 0389. No full kernel, no image (owner rule: one image at the end). Not booted.
- Opus review (2026-10-27), fixes in 0389: (a) `tz_want` ran also on ticks without a counter sample (busy counter given up,
  or `negronigpu_busy_pct=0`) and sent the stale last bin to TrustZone again each tick: TZ now runs only with this tick's
  sample; TZ is off with one line when the busy counter is given up, and does not start with `negronigpu_busy_pct=0`.
  (b) The 0298 give-up "busy counter did not move" counted 50 ticks; with the 10 ms TZ poll that was 0.5 s instead of
  5 s: it now counts 5 s of always-on time. (c) TZ gets only pwrlevels 0..11 (guard on our level 1..12). (d) A
  DCVS_UPDATE_V2 answer WAITQ_SLEEP/WAKE (2/3; live.dts qcom_scm has the wait-queue IRQ 0x3a2) turns TZ off at once with
  one line (WAITQ_RESUME is not ported; the parked TZ context holds one of qcom,max-queues = 2). Boot risk of the TZ
  calls [I]: is-call-available is the same fast call as step 1; INIT_V2 reads a 68-byte table from a normal DRAM page
  (TZ may read non-secure memory; with the shm bridge enforced, TZ answers an error, then TZ off); UPDATE_V2/RESET take
  values only. All run in the watch thread (gpu_pm_lock is a mutex, interrupts on), as Linux runs them from the devfreq
  work. THIRD_PARTY_NOTICES.md section 10 (GPL-2.0-only).

## 30. IOMFB layers kept across swaps and composed: Maps black (0398, `0398-negroni-fb-layers.patch`)

Symptom (owner photo 2026-10-27 20:01): Apple Maps open. On the panel the map area is black; only the status-bar band
(blurred map), the map/locate buttons, the location dot and the search sheet show. A render-server picture at the same
time (`logs/shots/maps4.png`, negroni-shot = `CARenderServerRenderDisplay`) shows the full map. So Metal draws the map;
it is lost between backboardd's display path and the panel.

### Cause [V unless marked]
- IOMobileFramebuffer 20H392 `kern_SwapSetLayer` (dyld cache, `ipsw dyld disass --symbol _kern_SwapSetLayer`): the swap
  record is zeroed at SwapBegin; SetLayer(layer, surface) puts the id at +0x54+4*layer, sets bit `layer` in +0x104 and
  clears it in +0x108; SetLayer(layer, NULL) sets the bit in **both** +0x104 and +0x108. So +0x104 = the layers this swap
  changes, +0x108 = those of them turned off. A layer not in +0x104 keeps what it showed (a "turn off" mask would make no
  sense otherwise).
- QuartzCore 20H392 `IOMFBDisplay::finish_update` (0x1882d1540..) and `detach_layer` (0x18830ef38): while CA
  "detaches" a layer (here Maps' full-screen opaque VectorKit CAMetalLayer, `kCADetachReasonCode*`), the app's drawable
  goes on layer `[+0x611]` (default 0, `str wzr,[sp,#0x7c]`), backboardd's framebuffer on layer `[+0x610]` = 1 (with a
  clear hole over the map; the status-bar backdrop is drawn into it, hence the blurred map band), and the third layer is
  set to NULL (`w1 = (idx == 0) << 1`). `delete_detached_layer` puts the framebuffer back on `[+0x612]` (0) and sets flag
  0x80, after which finish_update sets layers 1 and 2 to NULL. CA swaps a layer only when its surface changed (it keeps
  the last id per layer at +0x884).
- Our FB (0231..0389) treated each swap as the whole picture: only the layers in +0x104, copied in index order with no
  blending. A swap of layer 1 alone (UI changed, map not) copied the framebuffer with its clear hole: black map (the
  photo). A swap of layer 0 alone showed the map without the UI; both together: the hole (0x00000000) copied over the map.
- Live check 2026-10-27 20:07 (no reboot; `uiopen maps://...`, usblog): `DBUF in-place` (0269: frames of several layers
  or part of the panel) is 0 all day except while Maps draws (19:49: 84 in 23 s; 19:55-19:57; 20:04; 20:07:16-18 after
  opening Maps 5/4/4 per second; 20:07:50-52 during a pan 3/7/3), while most Maps frames are single-layer flips.
- No userland way out [V]: `CA_DISABLE_DETACHED` is a CA debug option; `init_debug` reads options only when
  `CADeviceHasInternalBuild`, and `_XSetDebugOption` (CARenderServerSetDebugOption) needs an audit-token bit our client
  does not get (a test client with `com.apple.QuartzCore.debug` read 0 -> 0 on the live server).
  `IOMFBDisplay::supports_multiple_layers()` returns 1 unconditionally. The FB must implement the layer contract.

### What 0398 does (NegroniFramebuffer.cpp only)
1. `layersMerge()` (in `swap()`, before everything else): applies the swap to a per-layer state (`fLyrId`, rects,
   swap-time fence, and the surface retained + held in use while the layer shows it, as a display holds a scanned-out
   surface: the app cannot render into the map drawable on screen). The rest of swap() and the tick see the merged
   record: every layer that shows something, +0x108 cleared. A layer the swap did not change keeps the GPU fence it was
   set with (its `gpuFence` names newer work by then, 0254). The layers belong to the client that swaps them
   (`layersOwner`): its close, or a swap from another client (a new backboardd while another process keeps the
   framebuffer open), turns every layer off first (review fix: "last client closes" left a dead render server's
   layers and surfaces on the panel when any other client kept the framebuffer open).
2. `compose()` (present(), when the merged frame has 2+ layers and none is the panel memory): row by row through one
   cached panel-row buffer: layer 0 at the bottom (copied; premultiplied over black = itself), each higher layer
   premultiplied source-over (`negroni_over`: alpha 255 = copy, pixel 0 = skip, else per channel, saturated), nearest
   scaling when the source and display rects differ, black where no layer is. The CPU reads only the surfaces (cache
   lines of GPU-written ones dropped first, `NegroniGPUSurfaceForCPU`) and writes each panel row once; the 0267/0391
   clock shift is done on the band rows on the way. Such a frame counts as "full" for 0269 (`dbufTarget`), so it goes
   into a free back buffer and flips (before: drawn in place over the shown buffer). Every panel row is written, also
   when no layer can be read (black; review fix: the old copy loop then wrote only part of a stale back buffer).
   GPU row runs (review, for the Maps lag): two unscaled full-panel layers whose GPU copies present()'s loop would
   allow (held, swap-time fence passed, behind newer GPU work only into a 0269 back buffer): each panel row is classed
   by the upper layer (all clear / all opaque / mixed, 8 pixels per step); runs of 8+ clear rows are GPU 2D copies of
   the lower layer, runs of opaque rows GPU copies of the upper one (`NegroniGPUPresentRects`, 6 rects per submission,
   8 submissions per frame at most); the CPU composes only the mixed rows and the clock band (and any rows of a refused
   submission). Output is the same pixels (clear = lower, opaque = upper). The lower layer's cache lines are dropped
   only for the CPU rows. The buffer flips after the copies' fence; the surfaces stay held until then (keepBusy).
3. Self-check / refusals: start needs one panel row of memory (`NEGRONI FB: 0398 IOMFB layers on|off: ...`). A layer
   that is not 32-bit single-plane BGRA (or fmt 0), whose source rect is outside the surface or memory, or without a
   kernel mapping is left out with one line per configuration (8 at most):
   `NEGRONI FB: 0398 layer L not composed: <why> (surface ...)`. No layer readable -> a black frame (every row written).
   Frames of one layer, the panel-memory layer (GetLayerDefaultSurface) and zero-copy are unchanged.
4. Kill switch `negronifb_layers=0`: each swap's own layers copied in order, as before 0398.

### Log lines
- Boot: `NEGRONI FB: 0398 IOMFB layers on (kept across swaps, several composed: mixed rows by the CPU, clear or opaque
  runs by the GPU)`.
- First composed frame, then every 1000: `NEGRONI FB: 0398 N frames composed from several layers, M with GPU row copies
  (this one: layers 0x3 of 0x3, 2, R of 2400 rows by the GPU)`.

### Cost and risks [I]
- An all-CPU composed frame is work on the vsync tick: read 2 x 10 MB, write 10 MB (the 10 MB CPU copy measured
  2.5-3.7 ms, so about 5-9 ms, over the 8.3 ms tick at 120 Hz). With the GPU row runs the CPU reads the upper layer
  once (the class scan) and composes only the mixed rows. Host model (M-series, cached output, Maps-like layout: bands
  opaque, hole clear, 278 mixed rows of 2400): all-CPU 2.3-2.8 ms, row scan + mixed rows 0.5-0.6 ms (4-5x less). [I]
  Phone: not measured; STAT `copy avg/max us` and the 0398 line (rows by the GPU) show it. The CPU path stays for
  scaled / partial layers and refused submissions.
- Z order = layer index (0 bottom) is read from CA's layout (detached on 0 under the framebuffer on 1); a detached layer
  above the framebuffer (index 2) is composed on top, as CA intends.
- A layer whose surface is not BGRA (a 10-bit 'w30r' map, a YUV video) is left out (black under the UI, as before) with
  its one line; that would be the next format to add.
- The held-in-use count of a layer surface stays +1 while it is on a layer (balanced on replace / off / last close).

### Verification
- Compile: `scripts/kernel/compile-one.sh` on a STAGE=0 scratch tree with every patches/xnu patch through 0396 (0389,
  0390, 0391, 0395, 0396 included): NegroniFramebuffer.cpp OK, no warning from the file. `git apply --check` of 0398 on
  that tree: OK (it must apply after 0389/0391). Not booted.
- Host test `patches/xnu/tests/fb-layers-test.c` (merge with CA's detach swap sequence, source-over math): PASS.
- Phone: open Maps; the panel must match `scripts/screenshot/phone-shot.sh` (map visible under the UI, also after a
  pan and with the sheet moved). Log: the `0398 ... composed` line, `DBUF in-place 0` while Maps draws, no
  `0398 layer ... not composed` line for Maps. Then other apps: unchanged (single-layer frames).

## 31. Wired memory guard for surfaces and GPU buffers (0399, `0399-negroni-wired-guard.patch`)

### Problem
- Two whole-userland freezes in `logs/usblog-20261027-171256.txt` (Safari video, camera session just before each):
  20:25:36-20:26:36 `VM_compressor` 80 %, `VM_pageout_scan` 64-73 %, `VM_pageout_external_iothread` 37-45 %; from
  20:27:36 every user process 0.0-0.1 % until the reboot at 20:32-20:34. Second boot: 20:37:42 `VM_pageout_scan` 81 %,
  all user processes under 6 %, then the phone interface went away at 20:38:19. Thread counts stay normal
  (950-1388). No jetsam kill (`CRASH ... sig 9`) in either freeze.
- Kernel-allocated IOSurfaces (IOBufferMemoryDescriptor, cap 1536 MiB), RedwoodGPU buffers of a client's own
  (1024 MiB per client, 10+ clients) and host imports / client-memory wraps (prepare() of the task's pages) are wired.
  XNU cannot compress or page out wired pages.

### What 0399 does
- `NegroniWiredAllow(bytes, who, what)` (NegroniSurface.cpp, declared in NegroniGPU.h): refuses when
  `vm_page_wire_count * PAGE_SIZE + bytes` is above 55 % of `max_mem` (1689 MiB of 3072 MiB). backboardd and
  SpringBoard get 65 % (1996 MiB): a refusal there is a black screen or a respring loop.
- Callers (answer `kIOReturnNoMemory`): surface create (kernel buffer only; display slots are not RAM XNU
  manages and are not checked), client-memory wrap sel 6/7, RedwoodGPU `makeBuffer` own buffer (not the
  write-combined pool, which is outside XNU RAM), host import 0x49. `importSurface` is not checked (the pages are
  already wired).
- Lines: one start line `NEGRONI WIRED: guard on: ...` (or `off: <reason>`), one `near the limit` line per boot
  at 90 % of the limit, `refused ...` lines (the first 8, then every 256th). Kill switch `negroniwiredguard=0`.

### Counter facts (xnu-8796 source)
- `vm_page_wire_count` starts as all pages XNU does not hand to the free list (kernelcache, early allocations:
  `vm_page_wire_count_initial`) and then counts every wired page.
- Compressor pages are not in it: `kernel_memory_populate_object_and_unlock` subtracts KMA_COMPRESSOR pages
  ("the compressor wired pages don't really count as wired").
- The GPU write-combined pool (512 MiB at 0x980000000) and the display slots are outside `max_mem`.
- Baseline: `NEGRONI KMEM: before root mount` shows 5508 wired pages of 16 KiB = 86 MiB, 2980 MiB free.

### Review (2026-10-27, Opus)
- [I] The diagnosis is not proven by the log: it has no wired, free or compressed count at runtime. The
  compressor at 80 % also fits a working set of anonymous memory that is too large. The `near the limit` and
  `refused` lines give the first runtime numbers.
- Per-task charging (Apple charges IOSurface memory to the owner with `setOwnership` / ledger tags) is not
  modest here: `vm_object_ownership_change` refuses a non-purgeable object that already has resident pages, and our
  buffers are wired at allocation. Host imports and wraps are the task's own anonymous pages and are already in its
  `phys_footprint`.
- Fixes: UI reserve for backboardd/SpringBoard, the near-limit line, wrap refusal kind 8 (kind 7 was also
  "no free surface id", so one of the two lines was never logged).

### Verification
- Compile: STAGE=0 scratch tree with all patches/xnu through 0399, `scripts/kernel/compile-one.sh`:
  NegroniSurface.cpp, NegroniGPU.cpp, NegroniFramebuffer.cpp OK, no new warning. `git apply --check` on the tree
  before 0399: OK. Not booted.
- Phone: Safari video for 10 min. Expect the start line, then either no `refused` line or `refused` lines for
  WebKit only, and no freeze. If backboardd or SpringBoard shows in a `refused` line, raise the UI percent.
