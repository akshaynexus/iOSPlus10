# GPU kernel patches 0230, 0231 (Adreno 730: RedwoodGPU, IOSurface import, GPU present)

Status (2026-10-25): written, syntax-checked, host-tested (the 2D command stream). **No CI build,
no boot yet.** Base: branch `base` of `out/kernel/xnu` (xnu-8796.141.3 + dxb + slop 0001-0124).
Worktree `out/kernel/wt-gpu-kernel`, branch `gpu-kernel`, commits `0230` then `0231`
(`git diff base HEAD~1` = 0230, `git diff HEAD~1 HEAD` = 0231). Apply 0230 before 0231.

| Patch | Files | What |
|---|---|---|
| 0230-negroni-gpu-surface-import | `iokit/Kernel/arm/NegroniGPU.cpp`, `bsd/dev/negroni_adreno.c`, `iokit/Kernel/arm/NegroniSurface.{h,cpp}` | RedwoodGPU lifetime and memory fixes, IOSurface import, both user-client ABIs (scalar 10-16 and msm), userspace GPU addresses, write-combined pool, GPU page-table fixes |
| 0231-negroni-gpu-present | `bsd/dev/negroni_gpu_blit.{c,h}` (new), `iokit/Kernel/arm/NegroniGPU.{h,cpp}`, `iokit/Kernel/arm/NegroniFramebuffer.cpp`, `bsd/conf/files` | GPU present: the A730's 2D engine copies GPU-rendered swapped surfaces into the panel memory; surfaces held in use until the copy is done |

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
