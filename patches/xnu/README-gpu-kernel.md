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
