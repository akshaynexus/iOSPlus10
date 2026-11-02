# Mi A3 (laurel_sprout) GPU: Adreno 610 behind CoreAnimation's OpenGL ES renderer

Status 2026-11-03: 2961 all stock levels to 950 MHz (section "All stock levels"); built on Linux, **NOT BOOTED**. 2892 (300 <-> 600 MHz) ran on the phone since boot 2026-11-01, and it is the fallback of 2961.
Status 2026-11-01 16:30 (t3/laurel-metal-everywhere: 2160, 2161, 2851, section "Kernel changes for Metal clients"); 08:30 (branch t3/laurel-gpu-zero-copy): 2158 zero-copy surfaces + cache push per CPU write, 2159 measured GPU busy/clock, eagl 0002, Metal client gate; built on Linux, **NOT BOOTED** (section "Zero copy, cache upkeep, GPU time").
Status 2026-11-01 06:45: the 06:12/06:17 "GL stall" is lsd's first LaunchServices seed (ADT without /chosen MACs), not the GPU; mkadt.py fix + 2155 GPU watchdog, built, NOT BOOTED (section "GL stall"). Status 2026-11-01 06:10: first boot with the zap files (05:52) hung in the zap SCM calls; 2153 fixes it (section "Zap hang").
Status 2026-11-01 05:10: review fixes on top of laurel-int-1 (areas A, C, H); built on Linux (kernel, Mesa, userland,
firmware extract, UEFI image). **NOT BOOTED.**
Update 2026-11-01 06:40 (branch t3/laurel-gpu-upstream-opt): **2154 stage-1 SMMU tables** (on by default, fallback =
pass-through), compiled-target flags + full ARMv8.0 check + dSYMs, eagl still-surface patch, upstream check
([upstream-2026-11-01.md](upstream-2026-11-01.md)). Built on Linux, **NOT BOOTED**.

Status 2026-11-01 06:10: first boot with the zap files (05:52) hung in the zap SCM calls; 2153 fixes it (section "Zap hang").
2153 is built on Linux, **NOT BOOTED**. Before: 05:10 review fixes on top of laurel-int-1 (areas A, C, H).
Labels: [V] read in source or measured on the host, [I] inference, [U] unknown.

## What runs where

Same design as ios-topaz (Redmi Note 12 4G, SM6225 "khaje", the same Adreno 610), which draws its lock screen,
home screen and Settings on the GPU this way (topaz README "Roadmap" 3). Kernel side: topaz patches 0901-0947
(TopazAdreno.cpp = TopazGpuW recipe, RedwoodGPU.cpp = msm DRM user client from darwin-redwood/HackiOS, GPU pool,
SMMU pass-through) are already in our kernel (kernel-linux.sh applies every topaz patch); laurel 2150-2152 port them
to SM6125 "trinket".

```
backboardd (CoreAnimation render server, EAGLServer)
  /usr/libexec/backboardd = our wrapper (userland/laurel/gpu/bbd_wrap.c): DYLD_INSERT_LIBRARIES=/topaz/lib/libtopaz-inject.dylib
      unless gpu=0 / gl=0 / 2 fast exits in this boot, then exec /usr/libexec/real/backboardd
  libtopaz-inject: waits up to 5 s for the RedwoodGPU service, then dlopen /topaz/lib/libtopaz-gl.dylib
  libtopaz-gl (eagl.c + gl_osmesa.c): EAGLContext's OpenGL ES = Mesa OSMesa (ES profile) on freedreno
  libOSMesa.8.dylib (Mesa 25.0.7 freedreno + softpipe; src/redwood-drm = libdrm stand-in -> IOKit "RedwoodGPU")
kernel
  RedwoodGPU user client (msm DRM ioctls as IOConnect calls) -> TopazAdreno (power, zap, SMMU, CP ring, fences)
  RedwoodGPU accepts only backboardd (SMMU pass-through); backboardd's open = "GL loaded" (topaz_gpu_gl_active)
  SweetSurface: while GL is loaded, backboardd's screen surfaces from the write-combined GPU pool; MDP scans them
```

## Trinket values (2150) [V source: external/laurel-kernel-los]

| Item | Mi A3 (trinket) | topaz (khaje) | Source |
| --- | --- | --- | --- |
| GPU / GPUCC / GPU SMMU | 0x5900000 / 0x5990000 / 0x59a0000 (qsmmu-v500, SID 0 mask 1 = gfx3d_user, SID 2 secure) | same | trinket-gpu.dtsi, msm-arm-smmu-trinket.dtsi |
| kgsl chip id | **0x06010000** | 0x06010001 | trinket-gpu.dtsi `qcom,chipid` |
| highest bank bit | **14** (RB/TPL1/SP_NC_MODE_CNTL 0xb, UCHE_MODE_CNTL bit 21) | 13 (0x9) | trinket-gpu.dtsi, adreno_a6xx.c a6xx_start |
| Zap shader | `a610_zap`, PAS 13, carve-out **0x57515000** (0x2000) | 0x55B15000 | trinket-gpu.dtsi; address from `xiaomi/laurel_sprout/laurel_sprout-trinket-memory.dtsi:34` (`qcom/trinket.dtsi` has 0x57115000: overridden, do not use) |
| GX GDSC | 0x100c, **no** sw-reset 0x1008 / domain clamp 0x1508 (no GMU) | with both | trinket-gdsc.dtsi |
| CX GDSC | 0x106c, status 0x1540 | same | trinket-gdsc.dtsi |
| gfx3d RCG | 0x101c; src 2 = PLL0_OUT_AUX2, 4 = PLL1_OUT_AUX2, 5 = GPLL0 | src 1 = Zonda PLL0 | gpucc-trinket.c |
| GPU PLLs | 2x "default" alpha PLL (PLL0 +0x0, PLL1 +0x100), 40-bit alpha, CONFIG_CTL 0x4001055b, AUX2 out = gfx3d x2 | 1 Zonda PLL | gpucc-trinket.c, clk-alpha-pll.c |
| OPPs | 320 (PLL1 640) 465 (PLL1 930) 600 745 820 900 950 MHz (PLL0 1200-1900) | 320-1260 | trinket-gpu.dtsi pwrlevels |
| GCC branches | bimc_gpu_axi 0x71154, memnoc_gfx 0x3600c, snoc_dvm_gfx 0x36018, cfg_ahb 0x36004, sys_noc_compute_sf_axi 0x1050c, GPLL0 to GPU 0x79004 bit 15 | same offsets (no cfg_ahb/sf_axi) | gcc-trinket.c, kgsl clocks |
| GPUCC 0x1060 | no clock there (topaz wrote "gpucc_gx_cxo"): not touched | — | gpucc-trinket.c, mainline gpucc-sm6125.c |
| GPU clock used | 300 MHz at start (GPLL0 / 2, as topaz); then by demand: section "All stock levels" | 300 | — |

The boot clock is 300 MHz from GPLL0. Levels, PLL values, votes: section "All stock levels" and `laurel_gpu_opp.h` (2961). The numbers of an older table here were rounded down (ALPHA 0xaaaaaaaa); `alpha_pll_round_rate` rounds up.

## Firmware (never in git)

`scripts/laurel/gpu-firmware.sh` (`VENDOR=` image or directory) reads the stock vendor image
`~/laurel-backup/stock/images/vendor.img` (sparse -> simg2img -> debugfs): `/firmware/a610_zap.{mdt,b00,b01,b02,elf}` and
`/firmware/a630_sqe.fw` [V 2026-11-01]. Facts [V]: our `a610_zap.b02` (2096 bytes, the code segment) is byte-identical to
topaz's embedded blob; our `a610_zap.mdt` (6860 bytes) differs in 788 bytes (hash table + signature chain: signed for
this phone's SoC/OEM, so topaz's mdt cannot pass TrustZone auth here [I]). mdt layout: 3 program headers, the only
PT_LOAD is #2 (paddr 0x5000, 0x830 bytes, relocatable) = `.b02`. Our `a630_sqe.fw` is 32304 bytes (dword[1]
0x01001f0b), topaz's built-in one 32504 bytes. The kernel loads `/usr/share/firmware/laurel/a610_zap.mdt` + the `.bNN` of
the loadable segment and `a630_sqe.fw` from the root; the SQE falls back to topaz's built-in one, the zap shader has
no fallback.
Since laurel 2775 the zap TrustZone steps (is_supported, init_image, mem_setup, copy, auth_and_reset, shutdown after a
failure) are the shared PAS loader `bsd/dev/topaz_pas.c` (also used by the IPA firmware, PAS 15): same order and the
same `TopazGPU: zap` lines; only three error reason texts changed wording [V code, NOT BOOTED].

## Kernel patches

- **2150** `laurel-gpu-trinket`: TopazAdreno.cpp trinket values (table above); on by default (`gpu=0` = kill switch);
  firmware from the root; zap metadata in a contiguous pool buffer (TOPAZ_4K: 6860 bytes span two 4 KB pages, topaz's
  "fits one page" test would refuse it); GPU pool from the ADT (below); self-check = one CP fence write (CP -> UCHE ->
  SMMU -> DDR) after ME_INIT, then the last seqno is written back; one line `LAUREL GPU: on|off: ...`.
  RedwoodGPU.cpp: **only backboardd may open the GPU** while the SMMU passes addresses through; backboardd's open marks
  "GL loaded" (`topaz_gpu_gl_active()`); a surface goes to the GPU only below 4 GiB and never from a cached scanout slot.
- **2151** `laurel-gpu-surfaces` (on area A's 2101): order in `create()`: (1) backboardd's screen-sized (>= 700x1500) BGRA
  surfaces from the GPU pool, only while GL is loaded; (2) the scanout path (cached slots, LAUREL SPOOL) only while GL is
  not loaded; both asked per create (GL loads after the first surfaces); (3) other surfaces: the topaz reserve for
  screen-sized ones while GL is loaded, then LAUREL SURF wired pages, then contiguous below 4 GiB (mask 0xFFFFC000) only
  while the GPU is wanted, then ordinary memory. Trade-off [I]: wired-page surfaces are not shared with the GPU (not
  contiguous); eagl copies them into textures (topaz measured 3 ms of an 8 ms frame for glBindTexture copies).
- **2153** `laurel-gpu-zap-scm-lock` (fix of the 05:52 zap hang, section "Zap hang" below): every GPU SCM call goes
  through `topaz_scm()` (the one TrustZone lock of 2404, resume loop and EBUSY retry inside it); `PAS_IS_SUPPORTED(13)`
  first (a failed call = GPU off at once); no `PAS_SHUTDOWN` before `init_image` (only after a failure that follows a good
  `init_image`); metadata in the TopazModem pool (0xE0000000+, where TZ read the ADSP and modem metadata), the GPU pool only
  when that pool is off; each SCM step logs its time.
- **2155** `laurel-gpu-watchdog`: GPU hang watchdog (no fence progress for 3 s with work pending while backboardd has GL)
  -> `LAUREL GPU: off: GPU hang: ...`, GPU off, GL backboardd killed, wrapper restarts it without GL; sysctl
  `kern.laurel_gpu` (section "GL stall"). Kill switch `gpuwd=0`.
- **2156** `laurel-gpu-pool-lock` (fix of the 06:50:38 pool panic, section "Pool panic" below): the GPU pool bookkeeping
  (`laurel_gpu_pool_core.h`, host test `scripts/laurel/gpu-pool-test.sh`) under one mutex; no buffer across a 64 MiB
  chunk (checked on every allocation); a free must be exactly a buffer that is out, else refused and counted; gemNew
  zeroes through `topaz_gpu_pool_clear` (the chunk map that covers the whole buffer).
- **2104** `laurel-fb-console-handoff` (fix of the 07:20:52 console flash, section "Console flash" below): a swap of
  surface 1 (boot framebuffer, GL draws into it) is scanned directly instead of flipping to a back buffer with a boot
  console frame; 0x5c000000 cleared of boot text at start; at the first iOS frame `LAUREL FB HANDOFF:` and the console
  stays off the panel (panic excepted). Kill switch `fbhandoff=0`.
- **2870** `laurel-fb-scanout-owner` (fix of the 07:45 "kernel log over the UI", section "Kernel log over the UI" below):
  the fbcon (the kernel console with serial=3) moves from the boot framebuffer (surface 1) into the console shadow at
  AppleCLCD start; every write of the pipe's scanout address says what the buffer holds, and after the first iOS frame a
  buffer with kernel text is refused (`LAUREL FB OWNER: refused: ...`, once per caller; a panic is let through); the
  console shadow and both flip buffers are cleared to black once the first iOS frame is on the panel. Kill switch
  `fbowner=0` (no refusal, no clear; the fbcon move stays). Numbered after 2850: it must apply after every patch that
  changes SweetFramebuffer.cpp.
- **2158** `laurel-gpu-zero-copy` and **2159** `laurel-gpu-time-clock`: section "Zero copy, cache upkeep, GPU time" below
  (scratch guard page, cache push per CPU write, request 0x7d, per-buffer CPU_PREP, measured GPU busy/clock). Kill switch
  `gpuseed=0` (2158's push rule).
- **2152** `laurel-fps-line`: `SWEET FPS:` is part of the GPU report: only while GL is loaded, 6 lines every second, then
  one every 10 s while frames come; `sweetfps=0` turns it off.

### GPU pool (merge order 3 of the review)

2150 reads ADT `/chosen laurel-ram-reserved` and `laurel-ram-banks` (mkadt.py, area A). It takes the largest reserved range
that is >= 128 MiB, 64 MiB aligned, below 4 GiB, inside one bank, outside the kernel's RAM (boot_args physBase/memSize)
and outside TopazModem's pool (0xE0000000 + 16 MiB). Area A's map (`uefi-boot.md` "Memory map"): **0xC0000000 + 512 MiB**,
kernel window 0xE1004000-0x1AD004000. No such range (old ADT): `gpu_midmem`, GPU memory from the kernel below 4 GiB (495 MiB
there), line `TopazGPU: kernel RAM ...; no GPU pool (<reason>): GPU memory from the kernel below 4 GiB (midmem)`.

### SMMU pass-through risk (review M1)

With `gpu_identity=1` (the default, topaz G1) the SMMU does not translate: a GPU address is a physical address. A bad
command stream (a Mesa bug, a hostile client) can write any DRAM, kernel memory included; a write into a TrustZone
carve-out can raise an access fault that resets the SoC. Topaz accepted this behind `gpu=1`. Here the GPU is on by default,
so RedwoodGPU accepts **only backboardd** (`proc_selfname`), with the line `LAUREL GPU: client X refused: SMMU pass-through
(GPU VA = PA), only backboardd may open the GPU`. Other GPU clients (WebKit GPU process, Metal, area J) need the stage-1
tables (`gpu_identity=0` path, untested on the Mi A3) before this check can go.

## Build (Linux x86_64, no Mac)

| Step | Command (tmux) | Output |
| --- | --- | --- |
| firmware | `scripts/bg.sh laurel-gpufw scripts/laurel/gpu-firmware.sh` | `out/laurel/gpu/firmware/` |
| Mesa | `scripts/bg.sh laurel-mesa scripts/laurel/mesa-linux.sh` | `out/laurel/gpu/mesa/out/libOSMesa.8.dylib` |
| userland | `scripts/bg.sh laurel-gpu-user scripts/laurel/gpu-userland.sh` (runs mesa-linux.sh when Mesa is missing/stale) | `out/laurel/gpu/root/` |
| root | `scripts/bg.sh laurel-root sudo scripts/laurel/root.sh` (calls `scripts/laurel/root-add-gpu.sh`) | root image |
| kernel | `scripts/bg.sh laurel-kernel scripts/laurel/kernel-linux.sh` | 2150-2152 in the patch set |

Toolchain: host clang (23 on CachyOS) `-target arm64-apple-ios16.0 -mcpu=cortex-a53 -mfix-cortex-a53-835769` + the theos cctools `ld64`/`ldid`
from `out/laurel-kernel/theos` (kernel-linux.sh fetches and checks it) + `iPhoneOS16.5.sdk` (theos/sdks, sparse clone
at a pinned commit; a user-given `SDK=` is used as it is, nothing is linked outside out/). Mesa: host meson + ninja +
bison/flex; Mako, MarkupSafe, PyYAML, packaging pinned with the sha256 of every PyPI file in
`scripts/laurel/gpu-requirements.txt` (`pip --require-hashes --only-binary :all:`).
Fix found [V]: clang warns "argument unused: --ld-path" on compile-only lines and meson's checks use
`-Werror=unused-command-line-argument`, so every feature check failed (`struct timespec: NO` -> `redefinition of 'timespec'`);
the wrapper `out/laurel/gpu/bin/ios-clang` passes `--ld-path` only on link lines.
**macOS:** not supported yet (the pinned theos toolchain is Linux x86_64; same as `scripts/laurel/kernel-linux.sh` and
`mu-build.sh`). Hashing is portable (`gpu_sha256`); a macOS path needs Xcode clang/ld/codesign in gpu-env.sh. Exception
written in docs/plan.md for the owner to decide.

Measured 2026-11-01 06:14 (gpu-upstream-opt, `-mfix-cortex-a53-835769`, `-O3 -g`) [V logs/gpuopt-gl.log]: Mesa 57 s,
libOSMesa 17 119 120 bytes stripped (dSYM 77 MB), 0 instructions newer than ARMv8.0 in all 4 Mach-O; kernel with 2154:
242 patches, 0 LSE/RCpc, 59 s.
Measured 2026-11-01 (20 cores) [V]: Mesa configure + build 47 s (18 s with a configured tree), 17 102 608 bytes, 1296 gl*
functions, links only libSystem, libc++, libz, IOKit; userland 3 binaries in a few s (mkeagl.py: 409 entries, 356 passed
on, 30 by hand, 23 without a function); 0 ARMv8.1+ instructions in every Mach-O (`gpu_check_v80`: cas*, swp*,
ld/st{add,set,clr,eor,smax,smin,umax,umin}*, ldapr*, ldapur*, stlur*).

### Mesa's highest bank bit (review m9) [V source, Mesa 25.0.7]

`freedreno_devices.py` gives A610 `highest_bank_bit = 13`; the hardware runs with 14 (2150, as kgsl). The static value is
read only by `fdl6_memcpy_*` (`src/freedreno/fdl/fd6_tiled_memcpy.cc`), and only Turnip calls those
(`grep -rn "fdl6_memcpy\|highest_bank_bit" src/gallium src/freedreno` outside `src/freedreno/vulkan`: no caller in gallium).
freedreno GL never uses it; the UBWC bank swizzle is the GPU's own (NC_MODE_CNTL, set by the kernel). Turnip takes the
value from `MSM_PARAM_HIGHEST_BANK_BIT` (14, `tu_knl_drm_msm.cc`). So no Mesa patch for the GL path.

## Lessons from negroni (OnePlus 10 Pro, Adreno 730) and what this port does

Sources: docs/gpu-comparison-2026-10-27.md, docs/gpu-status.md, notes.md sections 17, 67 and the Metal sections.

| Negroni mistake [V there] | Applies to the A610? | What this port does |
|---|---|---|
| Features behind default-off boot-args were never tested: per-client tables (0233, `negronigpu_pt=1`), zero-copy scanout (0234) stayed "written, not run" | yes: topaz's stage-1 path (`gpu_identity=0`) was the same | 2154 is **on by default**, checks itself at bring-up and falls back to pass-through with one line; `gpu_smmu=0` is only a kill switch |
| GPU clock wrong for days (kHz vs MHz: the A730 ran at ~5 MHz, 0237); nothing measured the real clock | partly: no GMU, the RCG is set directly (GPLL0 / 2 = 300 MHz) | [I] the fence self-check time and `SWEET FPS` are the first clues. Open: a CP perf-counter clock in the `LAUREL GPU` line (like negroni `gxclk`) and the CX/MX RPM vote before clocks above 300 MHz |
| GX powered for the whole boot (IFPC refused, `pm off`): hot phone | yes: topaz never collapses GX | open (no change here): GX/CX power collapse when idle is the next kernel item |
| Frames waited on fences while the GPU was 12-26 % busy: the frame cost was CPU (frontend + metal2vulkan encode, copies, cache upkeep) | yes, more: A73/A53 cores | user space built for the A53 (measured, below), metal2vulkan 219f013 (native arithmetic: fewer emulated ALU ops), eagl still surfaces summed every 8th frame, no TLBIALL per buffer made |
| IOSurface shadow copies and host-import cache upkeep (22.9 MB invalidated per command buffer; eagl texture copies 3 of 8 ms) | yes | with 2154 the GPU maps scattered pages: wired-page surfaces (LAUREL SURF) and kernel surfaces go to the GPU as they are, no eagl copy; GEM buffers from the write-combined pool first (no cache upkeep) |
| A Metal device with the wrong floor (metal2vulkan refuses a device below Vulkan 1.2) would show only as "no device" | **yes, found now**: Turnip 25.0.7 reports Vulkan 1.0 for the A610 | Turnip 0102 (Vulkan 1.3 on Darwin for parts without HW multiview); `metal-build.sh check` checks the patched tree |
| Per-process memory (widgets killed at 30-64 MiB jetsam; Turnip + metal2vulkan 15-20 MiB each) | yes: 4-6 GB phone | metal2vulkan's shader-cache memo capped at 32 MiB per process (default 256 MiB), disk at 1 GiB (flame/0018 + metal-env.sh) |
| Debug Turnip: 58 pipelines in 68 s (UniXNU/flame) | yes | release `-O3 -DNDEBUG` + ThinLTO; debug info only in dSYMs |
| Polled fences (200 us) before the fence IRQ (0384) | yes: RedwoodGPU still polls every 200 us | open: CACHE_FLUSH_TS interrupt for the A610 (GIC SPI from the trinket DT) |
| Metal on backboardd before the path was measured froze the UI | yes | backboardd keeps the GL path (topaz/HakiOS: 56-58 fps class); Metal clients stepwise (metal.md section 6); with 2154 the kernel no longer refuses non-backboardd clients |

## SMMU stage 1 (2154)

Design [V source of the patch; hardware behaviour I until the phone runs it]:

- **Bring-up order.** 2150's path is unchanged up to the CP fence test in pass-through (`SCTLR = 0xE0`, GPU VA = PA). Then,
  with the CP idle, `smmu_stage1()`:
  1. maps the CP's own buffers (ring, SQE, fence page) at **VA = PA** in topaz's tables (they are contiguous pool memory
     below 4 GiB), so CP_RB_BASE, CP_SQE_INSTR_BASE and the fence address stay valid across the switch;
  2. programs context bank 0: CBA2R0 AArch64, CBAR0 type 1 (S1, S2 bypass), TTBR0 = root table, TCR = T0SZ 32
     (4 GiB, 3-level LPAE, 4 KiB), non-cacheable walks, EPD1, TCR2 PASize 36 bit, MAIR0 attr0 = Normal NC;
     TLBIALL; `SCTLR = M | TRE | AFE | CFRE | HUPCF` (no fault interrupt: nothing handles it; faults terminate, no stall);
  3. self-check: read-back of SCTLR.M, TTBR0, CBAR0 type, S2CR0 (translate, CB 0), SMR0 valid; one CP fence through the
     tables at VA = PA; one CP fence into an ordinary kernel page (above 4 GiB with area A's map) at a VA that is not its
     PA (proves translation and the 36-bit output). That VA is a pool unit reserved for the test (the allocator's when
     there is no pool): a write that bypassed the tables lands in reserved RAM, never in MMIO, and fails the check
     (`the fence for VA .. landed at PA ..: the tables are bypassed`); FSR = 0;
  4. any failure: `SCTLR` back to pass-through, one more fence checks the CP, 2150's backboardd-only rule stays.
     2157 changes steps 2-4 (stall during the check, recovery, logs): see "Stage-1 check failure" below.
- **GPU VA layout** (one address space for all clients, kernel-managed addresses; Turnip/Mesa use GET_IOVA):
  `0x01000000-0x7fffffff` allocator (64 KiB granule, first fit): scattered buffers, IOSurfaces; `0x80000000-0xffffffff`
  VA = PA for contiguous memory below 4 GiB (CP buffers, GPU-pool GEM buffers), so the pool's bookkeeping (address =
  physical, `pool_give_back`) is the same in both modes. A pool outside that window turns stage 1 off (reason in the line).
- **RedwoodGPU with the tables**: GEM_NEW takes the pool first (write-combined, nobody else maps it: no cache upkeep, no
  cacheable alias), entered at VA = PA; pool full or a buffer above one pool chunk: ordinary pages, scattered, cached, with
  the existing per-submit cache push (darwin-redwood design). Surfaces: page by page at allocator VAs, the 64 guard rows
  required (SweetSurface now gives every surface the guard rows and asks for no contiguous memory while the tables run).
  Pool buffers and pool surfaces are mapped write-combined in user space. `RedwoodMaxBuffer` = 256 MiB (pass-through:
  64 MiB - 64 KiB), property `LaurelGPUSMMU` = `stage 1` / `pass-through`. **The backboardd-only rule is off** (it
  checks `redwood_gpu_identity()`): every process may open RedwoodGPU (Metal clients, WebKit GPU process).
- **TLB**: new entries are written only over invalid ones, and an SMMU caches no invalid entry: no TLBIALL on map, only a
  barrier (HakiOS does the same); unmap keeps TLBIALL + TLBSYNC.
- **Faults**: with HUPCF and no stall a refused access is terminated; RedwoodGPU's 5 s statistics call
  `redwood_gpu_worked()`, which logs `LAUREL GPU SMMU: fault FSR .. FAR .. FSYNR0 ..` (16 at most) and clears FSR.
- Not done (open): per-process tables (one context bank per client, or TTBR0 switches at submit: CP_SMMU_TABLE_UPDATE
  needs the GPU in a context that TrustZone allows, negroni found the same); the 32-bit GPU VA is shared by all clients
  (about 1.9 GiB for scattered buffers). A client can still write another client's GPU buffers, but no kernel or
  TrustZone memory.

Kill switch: `gpu_smmu=0` (pass-through, 2150 behaviour). `gpu_identity` is no longer parsed: it is the result of the check.

## Stage-1 check failure (boot 2026-11-01 07:19, fixed by 2157)

Observed [V logs/usblog-20261101-001446.txt of the main checkout, kernel of that boot = 2154 + 2156]:

- `07:19:32 LAUREL GPU POOL: free of 0x1000000+0xef000000 refused (1 so far): the pool has given nothing out; caller
  0xfffffff007ae30f8` (= topaz_adreno_thread + 0x178, hw_start inlined). [V source] hw_start seeded the GPU VA
  allocator with `redwood_gpu_address_free(VA_USER_START, VA_KERNEL - VA_USER_START)`; with `gpu_identity = 1` that call
  is the pool's free, which 2156 now checks and refuses. 2154 and 2156 were written in parallel. Harmless (nothing
  freed), but a wrong line and a wrong seed.
- Zap ok, `SMMU TTBR0 c0000000 ... (identity)`, SQE at 0xc0010000, ring at 0xc0020000, CP up, fence test ok (356 us).
- `07:19:35 TopazGPU: ring stuck: rptr 17 wptr 21 RBBM_STATUS 00800005 CP_HW_FAULT 00000000` and
  `[ring] SMMU gfsr 00000000 CB0 FSR 00000400 FAR 00000000c0020040 FSYNR0 00040000`, then `THE GPU IS NOT STARTED`,
  `LAUREL GPU: off: pass-through after the stage-1 check failed`, `LAUREL METAL: off`.
- `07:21:10` same kernel with `gpu_smmu=0`: GPU on in pass-through, RedwoodGPU published, backlight on GPU renderer.

Analysis:

- [V source] The "ring stuck" line comes from the fallback in hw_start (`ring_idle` before its fence), after `back:`
  had written FSR = 0xFFFFFFFF. So FSR 0x400 is only what the clear leaves: FORMAT (bits 10:9) = 2; the fault type
  bits (TF/AFF/PF/EF/ASF) were lost. FAR survives a FSR clear: the fault was a CP read at 0xc0020040 = ring + 0x40,
  dword 16 = the first dword of the check's first fence packet (wptr 16 -> 21). So the CP's first ring fetch through
  the tables faulted; the check stopped at step 4 (the register read-back had passed, else no fence is sent).
- [V source] `SCTLR_STAGE1` has no CFCFG: the faulting fetch was terminated. A terminated CP fetch leaves the CP hung
  (rptr stays at 17, RBBM_STATUS busy); going back to pass-through does not wake it. The fallback then only checked
  `ring_idle`, so the GPU went off instead of staying in pass-through (design said: GPU stays on).
- [V source, CPU side] The table builder looks right on paper: T0SZ 32 + 4 KiB granule = walk from level 1 (4 entries),
  l1[3] -> l2[3], l2[3][0] -> one l3 table for 0xc0000000-0xc01fffff, l3[0x20..0x27] = ring pages, PTE = PA | 0x643
  (valid, page, AP[1], SH outer, AF, AttrIndx 0). TCR 0x00800020 = T0SZ 32, TG0 4 KiB, NC NSH walks, EPD1. The
  differences from Linux arm_smmu_write_context_bank were: CBAR BPSHCFG 0 (reserved; Linux NSH = 3), VMID 0, TCR2
  without AS / SEP (the 07:19 read-back of TCR2 was 0x61), and TCR before TCR2. [I] FORMAT 2 may mean an AArch32
  long-descriptor walk (CBA2R0.VA64 not taken); IDR0 4c017e04 (S1TS, no ATOS: ATOSNS = 1, so no address translation
  operation can test the tables without the GPU) and IDR2 00005511 (IAS/OAS 36 bit, AArch64 4 KiB granule supported).
  The real fault type is unknown until the next boot: 2157 logs it before anything clears it.

2157 (patch `2157-laurel-gpu-smmu-check-recover.patch`):

1. `va_seed()`: the allocator's one range 0x01000000-0x7fffffff is set directly when the tables come up. Pass-through
   uses no allocator: no seed in hw_start, no refused free line.
2. The check logs each step: `check 1` CPU-side walk of every page of ring/SQE/fence to VA = PA (each table link must
   hold the next table's PA); `check 2` the context bank as held (now with CBA2R0) and whether stall-on-fault took;
   `check 3` CP fence at VA = PA; `check 4` CP fence to a kernel page at VA != PA. Linux's values and order (CBA2R, CBAR
   0x0001f301, TCR2 0x00038011, TCR, TTBR0, MAIR0, SCTLR last).
3. During the check, `SCTLR = M | TRE | AFE | CFRE | CFCFG | HUPCF`: a fault stalls the access. The fault is decoded
   (`FSR .. (TF ... stalled format N) FAR .. FSYNR0 .. (level L, read|write[, table walk]) walk: entry .. at level N`)
   before anything clears it. On failure `smmu_back()`: SCTLR pass-through, TLBIALL, FSR clear, and a stalled access to
   our own memory (CP buffers or GPU pool, VA = PA) is retried (CB_RESUME TnR 0): it completes as a physical access
   and the CP goes on. Any other stalled access is terminated (TnR 1). After a passed check: SCTLR without CFCFG
   (terminate; a stall would block the GPU), as in 2154.
4. `cp_recover()`: CP idle: one fence (`pass-through: the CP goes on`). CP hung: GPU power collapse (`power_up`, which
   cycles GX and CX), zap resume (SCM SVC_BOOT 0x0a, state 0, id 0 = Linux `qcom_scm_set_remote_state(0, 0)`), SMMU
   pass-through again (the SMMU is in the CX domain), `cp_start` with its fence test. No RBBM_SW_RESET: Linux
   `a6xx_gpu_sw_reset` skips it on A610 ("11nm chips ... have hw issues with the reset line"). `cp_start` now keeps the
   CP buffers on a second start (the old test `md == NULL` is always true for pool buffers).
5. Page tables: 16 per 64 KiB pool unit (2154 took one pool unit per PAGE_SIZE chunk).

Expected lines (next boot, default boot-args):
`LAUREL GPU SMMU: check 1: tables at 0xc0000000: ring 0xc0020000+0x8000, ...`, `check 2: SCTLR 000001a7 ... CBA2R0
00000001 ...; stall on fault yes`, then either `check 3`/`check 4`/`on: stage 1, ...` or
`check failed: no fence write through the tables at VA = PA <fence page>: FSR ........ (...) FAR 0xc0020040 ...; context
bank 0 back to pass-through, the stalled access retried there`, `pass-through: the CP goes on, fence at ...` (or the
power-cycle lines), `TopazGPU: Adreno 610 ready`, `LAUREL GPU SMMU: off: <why>: pass-through ...`, `LAUREL GPU: on: ...
SMMU pass-through`. The FSR/FSYNR0/walk text of the failure line is the input for the next fix of the tables.

## Compiled target (Kryo 260: A73 + A53, ARMv8.0)

| Part | Flags | Check |
|---|---|---|
| Mesa GL (libOSMesa) | `-mcpu=cortex-a53 -mfix-cortex-a53-835769`, `-O3 -DNDEBUG`, `-g` -> dSYM in `out/laurel/gpu/dsym/`, installed copy `strip -x`; no LTO (theos ld64 cannot read clang 23 bitcode [I]) | `scripts/laurel/armv80-check.py` |
| libtopaz-gl, libtopaz-inject, backboardd wrapper | same CPU flags, `-O2 -g` -> dSYM, stripped | same |
| Turnip, plug-in, probes, bridge | `scripts/laurel/metal-env.sh` (metal.md "Compiled target") | same, in `metal-build.sh check` |

Tuning measured [llvm-mca estimate, `scripts/laurel/cpu-tune-mca.sh`, kernels in `userland/laurel/gpu/tune/mca-kernels.c`,
cycles per 100 runs of each block]:

| Block | -mtune=a53: A53 / A73 model | -mtune=a73: A53 / A73 | generic: A53 / A73 |
|---|---|---|---|
| float RGBA -> BGRA8 pack (16 px) | 13801 / 6070 | 27202 / 6078 | 11801 / 6067 |
| tiled copy (8 x 64 B) | 14501 / 7818 | 31601 / 7628 | 15502 / 8115 |
| PM4 emit with parity (8 packets) | 20202 / 3679 | 20402 / 3646 | 20402 / 3679 |
| premultiply (16 px) | 7302 / 3366 | 16202 / 3372 | 8001 / 3518 |

A73 tuning makes the A53 blocks 1.9-2.2x slower and the A73 ones at most 2.4 % faster; so `-mcpu=cortex-a53` (A53
scheduling) is the measured best, not `-mtune=cortex-a73`. (The hash kernel is left out: the A53 tuning unrolls its loop,
so the blocks are not the same work.) `-mfix-cortex-a53-835769` puts a NOP between a load/store and a 64-bit
multiply-accumulate, as Android's arm64 toolchains do [I: Kryo 260 Silver = A53 r0p4 derivative].

`scripts/laurel/armv80-check.py` (self-test: `--self-test`) counts every instruction newer than ARMv8.0 + CRC + AES/SHA:
LSE, RCpc, RDM, FP16 arithmetic/conversion, FHM, dot product, SHA3/SM, JSCVT/FCMA, non-hint PAuth, FlagM, FRINTTS, MTE,
BF16/I8MM, SVE. Hint-space PAC/BTI are NOPs on ARMv8.0 and not counted. Used by `gpu_check_v80` (GL) and `metal-build.sh
check`. (On the kernel it finds 21 "instructions" in the K256 SHA table data in __text: the kernel keeps its own check.)

## Log lines to check (first boot)

1. `TopazGPU: kernel RAM 0xe1004000+0xcc000000, GPU pool 0xc0000000+0x20000000 (ADT laurel-ram-reserved)`
2. `TopazGPU: powered: RBBM_STATUS ...`,
   `TopazGPU: zap: PAS 13 is_supported 0/<x1> (0 ms), metadata 6860 bytes at 0xe00xx000 (modem pool)`,
   `TopazGPU: zap: init_image and mem_setup ok (N ms), copying the segment`, `TopazGPU: zap auth_and_reset: 0/0 (N ms)`
   (2153; without the modem pool: `... at 0xc0000000 (GPU pool: modem pool off)`)
3. `TopazGPU: SMMU TTBR0 ... (identity)`, `TopazGPU: cp: SQE 32304 bytes (own, version 01001f0b)`, `CP up (ME_INIT, SET_SECURE_MODE 0), core 300 MHz`,
   `TopazGPU: fence test ok in N us`
4. **`LAUREL GPU: on: Adreno 610 chip 0x06010000, core 300 MHz, zap PAS 13 at 0x57515000 (own a610_zap, 6860+2096 bytes), SQE own 01001f0b, SMMU stage 1, pool 0xc0000000+0x20000000; RedwoodGPU published`**
   or `LAUREL GPU: off: <step> failed: <reason>` (steps: MMIO map, power (GDSC/clocks), zap shader, SMMU, CP start,
   pass-through after the stage-1 check).
4a. (2154) **`LAUREL GPU SMMU: on: stage 1, context bank 0, 32-bit GPU VA, fence at VA = PA 0xc00xxxxx in N us, kernel page PA 0x1xxxxxxxx (above 4 GiB) at VA 0x1000000 in N us; any process may open the GPU`**
   or `LAUREL GPU SMMU: off: <reason>: pass-through (GPU VA = PA), only backboardd may open the GPU` (reasons: `boot-arg
   gpu_smmu=0`, `registers do not hold: SCTLR .. TTBR0 .. CBAR0 .. S2CR0 .. SMR0 ..`, `no fence write through the tables
   at VA = PA ..`, `no fence write to kernel page PA .. at VA ..`, `fault FSR .. during the checks`, `GPU pool .. outside
   the VA = PA window`). During use: `LAUREL GPU SMMU: fault FSR .. FAR .. FSYNR0 ..` only when a GPU access was refused.
   With stage 1, the RedwoodGPU client lines show other processes too (`RedwoodGPU: client SpringBoard (open N)`), and
   no `client X refused` line.
5. `/var/tmp/laurel-bbd.log` and syslog: `LAUREL BBD: on: /topaz/lib/libtopaz-inject.dylib inserted` (or `off: <reason>`),
   then `topaz: /topaz/lib/libtopaz-gl.dylib loaded`, kernel `RedwoodGPU: client backboardd (open 1)` and
   **`LAUREL GPU: GL: backboardd opened the GPU: its screen surfaces from the GPU pool, direct scanout off`**.
6. `SWEET SURF: backboardd create ... 720x1560` from the pool; `SWEET FPS: N frames in 10xxx ms, ...` every 10 s.

If the zap step fails with `TrustZone refused the zap shader: init_image ...`: the mdt is not this phone's (check
`SHA256SUMS` against the vendor image) or the PAS id differs; `mem_setup`: the carve-out address is wrong (read the
live FDT `gpu_zap` region).

## Zap hang (boot 2026-11-01 05:52, fixed by 2153)

Observed [V `logs/usblog-20261101-001446.txt`, the first boot with the zap files]:
- 05:52:41 `TopazGPU: powered: RBBM_STATUS 00000001`, `TopazGPU: zap: metadata at 0xc0000000`, then no TopazGPU / LAUREL GPU
  line until the log ends at 05:57:25. The next line in 2150 after the SCM calls is `zap: init_image and mem_setup ok` (or a
  refusal line): so one of `PIL_SHUTDOWN`, `PIL_INIT_IMAGE`, `PIL_MEM_SETUP` (PAS 13) did not return.
- Same second: ADSP PAS (TopazAudio) init_image ok (meta at 0xe0000000), mem_setup ok, auth_and_reset ok in 165 ms; modem PAS
  init_image (meta at 0xe0003000) and mem_setup ok, `TopazModem: segments loaded` printed **one line after** the GPU's metadata
  line, then the modem's `auth_and_reset: ret=0 res=0 resumes=35`. So the GPU's SCM calls went in while the modem's long
  auth_and_reset was running and coming back to the normal world 35 times (INTERRUPTED, resumed with the session in x6).
- Later SCM calls from other CPUs worked: `SCM assign e000e000+300000` (05:52:41), `53300000+4000`, `53304000+1fc000` (05:52:43).
- `LAUREL THERMAL` after the hang: silver busy 0-3 %, gold 3-13 % (busiest core, HOST_CPU_LOAD_INFO ticks). A thread that spins in
  the normal world (the old resume loop, max 100000 SMCs) shows as one 100 % core. None did.
- backboardd fell back to the CPU renderer; first frame 68 s after boot (29 s in the 05:29 boot without zap files).

Source [V]:
- TopazAdreno.cpp (topaz 0901 + 2150) had its own `smc()`/`scm()` with **no lock**. 2404 put one lock over every TrustZone call
  of TopazModem (`scm_call()`: the call + its resume loop, EBUSY retry) and TopazAudio uses it through `topaz_scm()`; TopazAdreno
  was not changed. The only other `smc #0` users are PSCI (SweetCPU.cpp) and the reboot path (laurel_reboot.c).
- Downstream 4.14 (`external/laurel-kernel-los/drivers/soc/qcom/scm.c`): `scm_call2` holds `scm_lock` (one global mutex) over
  `__scm_call_armv8_64`, whose `do { smc } while (r0 == SCM_INTERRUPTED)` resume loop runs inside the lock; SCM_V2_EBUSY (-12) is
  retried 30 ms later. Mainline `qcom_scm-smc.c` does the same with `qcom_scm_lock`.
- Downstream zap load (`adreno_a6xx.c` -> `subsystem_get("a610_zap")` -> `subsys-pil-tz.c`, `qcom,pil-tz-generic`, pas-id 13):
  init_image (metadata in a fresh DMA buffer, arginfo 2 args VAL+RW) -> mem_setup -> segments -> auth_and_reset. No
  PAS_SHUTDOWN before init_image; PAS_SHUTDOWN only in `deinit_image` after a failure or at `subsystem_put`. It votes the crypto
  bus bandwidth (`scm_pas_enable_bw`) around init/auth; the ADSP and modem PAS on this phone worked without that vote.
  kgsl loads the zap only when the SMMU has a secure context bank (`mmu.secured`; trinket has one, SID 2), so the zap is needed.

Cause: two CPUs in the TrustZone PIL service at the same time [V: the timing and the missing lock; I: what TZ does inside].
The CPU with the GPU's call stayed in the secure world [I: the zero-busy thermal lines; a stuck CPU gets no normal-world timer
ticks]: the GPU thread never returned, one of the 8 CPUs was lost (slower boot), and `op10tool ctl ping` got no pong after
05:52:41 [I: ctl work queued on that CPU or waiting for an IPI to it; not measured]. The metadata at 0xC0000000 is not shown to be
a cause (TZ answered nothing about it); 2153 moves it to the pool TZ read in the same boot anyway.

Fix (2153, zap path only): see "Kernel patches". The lock does not abort a call that TZ never ends (no SMC can be aborted); it
removes the parallel entry that started it. Residual risk [I]: if PAS 13 alone ever hangs inside TZ, the lock stays held and the
modem/ADSP SCM calls after it wait too; the log then ends at `zap: PAS 13 is_supported` or `init_image` with no time printed.
PAS sequences of different peripherals may interleave call by call (the ADSP auth_and_reset ran between the modem's
init_image and auth_and_reset in this boot and both worked [V]), as Linux boots PIL peripherals in parallel; so 2153 does not wait
for the modem or ADSP.

## GL stall (boots 2026-11-01 06:12 and 06:17): not the GPU; lsd's first seed (ADT MACs) + 2155 GPU watchdog

Report: after `LAUREL GPU: on` and `GL: backboardd opened the GPU`, redwood-gl frames 1-3 and RedwoodGPU submissions 1-3,
then nothing from redwood-gl / RedwoodGPU / SWEET FB for minutes; the panel keeps the Apple logo.

Observed [V `logs/usblog-20261101-001446.txt`, decoded with `scripts/debug/smp-symbolize.sh` and the 20H392 cache]:
- Frames 1-3 are backboardd's own boot scene: 4 draws, one 720x1560 IOSurface + one 129x158 (the Apple logo) texture.
  `redwood-gl` logs frames 1-40 one by one: frame 4 never ended. No `SWEET FPS` line (2152 needs a 1 s window of swaps).
- backboardd at 06:18:36 (all 19 threads): main thread `CFRunLoopRunSpecific` in `mach_msg2_trap` (idle);
  `CA::Render::Server::server_thread` and `CA::WindowServer::IOMFBServer::thread_body` idle in mach_msg; 5 Mesa threads
  idle in `pthread_cond_wait` (not in the cache: libOSMesa); CoreBrightness idle. Two threads wait: t12
  `_xpc_connection_send_message_with_reply_sync` <- `__LAUNCH_SERVICES_IS_RESEEDING_ITS_DATABASE_AND_MAY_BLOCK__` <-
  `_LSCopyServerStore` <- `LaunchServices::URLPropertyProvider::prepareIsPackageValue`, and t10 `dispatch_group_wait`
  (backboardd main + 0x18a78). Same picture at 06:14:15 (boot 06:12).
- SpringBoard at 06:18:36: t1 the same sync XPC to lsd (`_LSCopyServerStore` <- `_LSDBEnumeratorGetNextObject`); t0 (main)
  waits for the os_unfair_lock of that LS context: `-[LSApplicationRecord initWithBundleIdentifier:...]` <-
  `-[CCSModuleRepository _queue_filterModuleMetadataByAssociatedBundleAvailability:]` (Control Center modules). Its last
  IOKit line is `IOK SpringBoard: path IODeviceTree:/buttons`; in the 05:29 boot the next ones came in the same second.
- **The same SpringBoard stack at 05:54:10 and 05:56:10 (boot 05:52), where the GPU hung in the zap (no RedwoodGPU, no
  GL, CPU renderer)**, and SpringBoard also stops at `/buttons` in the 06:07 boot (zap hang again, CPU renderer). Later
  GL boots (06:29, 06:36) stop the same way. So the stall is not the GL path.
- 05:29 (old root, LaunchServices database already built in earlier boots): `SWEET AMFI: user client selector 6 from
  lsd` 1 s after lsd starts (ExtensionKit's signed extension cache, read while LS registers), SpringBoard through, lock
  screen. Every boot of the root of 05:41 (new image, fresh /var, no LS database): no AMFI call from lsd, nothing
  after `/buttons`.
- The ADT (scripts/laurel/mkadt.py, from topaz's) has no `/chosen mac-address-wifi0/-bluetooth0/-ethernet0`, and
  topaz's RedwoodWLAN publishes an `IO80211Controller` (an IOService), not an `IONetworkController`; the firmware MAC is
  `00:00:00:00:00:00`.
- GPU side [V source]: RedwoodGPU has no GPU interrupt (fences are polled every 200 us; no GIC SPI / RBBM_INT in use).
  The display does not wait on GL: direct swaps go to the presenter thread (SwapEnd returns at once); `present()` waits
  at most 100 ms per surface (`topaz_surface_drawn`); vsync notifications come from a timer. Waits of >= 1 s that time
  out print `TopazGPU: no answer: ...`; none in these boots. No backboardd thread is in a RedwoodGPU call.

Cause [I, strong]: lsd's first LaunchServices seed on the new root. MobileGestalt answers WifiAddress (and the old-style
UniqueDeviceID) from `/chosen mac-address-*`; without them each answer waits 5 s for an IONetworkController that never
comes, once per bundle (ios-flame tools/mkadt.py, ios-redfin HANDOFF 590, negroni 1697e28 "LaunchServices/installd stall":
15+ min of Apple logo on the first boot). Every client of LS (SpringBoard, backboardd) waits for lsd meanwhile. The owner
rebooted each try after 3-4 min, so the seed never finished. Not measured: lsd's own stack (the sampler only samples
SpringBoard and backboardd by default).

Fix: `scripts/laurel/mkadt.py` writes `/chosen mac-address-wifi0 = 02:4c:41:33:57:46`, `mac-address-bluetooth0 =
02:4c:41:33:42:54` (the /arm-io/bluetooth fallback), `mac-address-ethernet0 = 02:4c:41:33:45:4e` (locally administered,
not the phone's). New ADT = new boot image (uefi-image.sh); no root change. The half-built seed in /var needs nothing:
lsd builds the database again. Check on the next boot: `SWEET AMFI: user client selector 6 from lsd` about 1 s after
`exec lsd`, then SpringBoard lines after `/buttons` (`privilege 1007`, `/product`), redwood-gl frames past 3, `SWEET FPS`.
If it still stops: boot once with `sweetsample=SpringBoard,backboardd,lsd` (the existing topaz sampler) and run
`scripts/debug/smp-symbolize.sh LOG lsd`.

### 2155 `laurel-gpu-watchdog` (a real GPU hang never freezes the UI)

A frame-count watchdog would fire on every still screen (no change = no frame, as in this log). 2155 watches the GPU
work instead (TopazAdreno.cpp, the GPU thread after `LAUREL GPU: on`): every 250 ms while backboardd has GL, if the last
submission is not written back and the written-back number has not moved for 3 s, it is a hang. Then, once:
`TopazGPU: watchdog: GPU hang: fence .. done .. rptr .. RBBM_STATUS ..` (registers + SMMU fault state),
**`LAUREL GPU: off: GPU hang: submissions A-B not done, no progress for N ms; GL off, backboardd PID restarts on the CPU
renderer`**, CP stopped and `ready = false` (RedwoodGPU refuses every call and new opens; `topaz_gpu_gl_active()` false:
screen surfaces from ordinary memory, the display does not wait for the GPU), SIGKILL to the GL backboardd. launchd starts
the wrapper again; it reads the new sysctl **`kern.laurel_gpu`** (`on`, `off: <reason>` for gpu=0, a failed bring-up step
or the hang, empty while the GPU starts) and execs backboardd without the GL loader:
`LAUREL BBD: off: the kernel turned the GPU off (off: GPU hang: ...): no GL loader, software renderer`
(`/var/tmp/laurel-bbd.log`, syslog). The wrapper also skips the loader (and its 5 s RedwoodGPU wait) after a failed
bring-up. Kill switch `gpuwd=0` (`LAUREL GPU WATCHDOG: off: boot-arg gpuwd=0`). [I] Risk: after the SIGKILL the dying
backboardd's buffers are freed while the stopped CP may still hold their addresses (pass-through SMMU); CP_SQE_CNTL = 0
stops new fetches. 2155 applies with and without the stage-1 patch 2154 (checked: 244/244 with 2154).

Build 2026-11-01 06:38 [V]: kernel-linux.sh 243/243 patches, 0 LSE, `kernel.development.sweet.4k` sha256 a5dffb27...;
gpu-userland.sh: backboardd.wrap 0 LSE (root files changed: `/usr/libexec/backboardd` only).

## Pool panic (boot 2026-11-01 06:48, fixed by 2156)

First boot where the GL UI reached the lock screen. At 06:50:38 (touch, Spotlight starts) the kernel panicked:
`Kernel data abort` at `_bzero+0x44` (`dc zva`), lr `RedwoodGPUUserClient::gemNew+0x53c`, esr 0x96000047 (write,
translation fault), far = x3 = x0 + 0xC0000. Log `logs/usblog-20261101-001446.txt` line 46702; kernel
`out/laurel-kernel/out/kernel.development.sweet.4k` of the main checkout (KASLR off: the pc is the `llvm-nm -n` address).

Observations [V registers + disassembly of that kernel]:
- x23 = pa = 0xc3f40000 (pool + 0x3f40000), x19 = size 0x140000, so the buffer ends at pool + 0x4080000. The fault is at
  pool + 0x4000000: the end of chunk 0. `topaz_gpu_pool_alloc` maps the pool in 64 MiB chunks; `va` is chunk 0's map + offset,
  and chunk 0's map ends there.
- bzero uses only x0-x4, so x9-x14 are still those of the inlined `range_alloc`: x12 = -0x8000 + 0x60 -> entry 6;
  x11 = 7 -> 14 entries; x14 = 0x20000 = size left after 0x140000 -> the entry was **pool + 0x3f40000, size 0x160000**
  (end pool + 0x40a0000); x13 = 0xc4080000 = its new start. That free range covered chunk 0's guard unit (0x3ff0000) and
  ran into chunk 1. The seeding (one range per chunk, a unit short) cannot make such a range; only a bad free or a torn
  update can.
- [V source] Nothing serialized `pool_free[]`/`pool_free_count`/`gpu_chunk_va[]`. Callers: gemNew (no lock: it drops
  gGPULock before the pool), SweetSurface create (no lock), SweetSurface::free (no lock; it also runs on the framebuffer's
  presenter thread, which releases the shown frames, `sweet_hold_set` -> `release()`), RedwoodGPU frees (freeBuffer, reap,
  dropKept, the gemNew error path) under gGPULock only. Eight CPUs.
- [V source] All free sizes match their allocations (gemNew/kept: same `size`; surfaces: `poolSize` = `take`; both
  rounded the same way); surface buffers are never given back by RedwoodGPU in pass-through; 2155 only stops the GPU.
  So no wrong-size or double free was found in the code.
- [V host test] `scripts/laurel/gpu-pool-test.sh` part 2a: the compiled loop loads `f[i].size` (ldr x14, [x8, #8]), compares,
  and only then loads `f[i].start` (ldr x0, [x8]). A `range_free` on another CPU between the two loads that inserts a range
  in front of i shifts the table: A takes the start of the range before it and stores (that start + size, the other
  range's size - size). Example: W = pool + 0x3e00000 (128 KiB free), X = chunk 1: A gets pool + 0x3e00000 + 0x140000
  (over used memory) and the table keeps **pool + 0x3f40000** size 0x3eb0000 across the chunk end; the next 0x140000
  is the panic's buffer. Part 2b: 4 threads on the old code give two buffers on one unit after 50-300 operations.
- [I] Cause: a torn free range from two CPUs in the pool at once. The exact interleaving on the phone is not known (the
  panic shows only its result); the double allocation that comes with it also explains earlier garbage, if any is seen.

Fix 2156 (TopazAdreno.cpp + RedwoodGPU.cpp + new `iokit/Kernel/arm/laurel_gpu_pool_core.h`):
- One mutex `laurel_gpu_pool_lock` (LCK_MTX_DECLARE, ready at startup) over the free list, the per-unit length table and
  the chunk maps. Nothing else is taken inside it; it is taken under gGPULock and hw_lock (never the other way).
- `lgp_alloc`: first fit, but a buffer is only given if `lgp_fits` (unit aligned, in the pool, inside one chunk, off the
  guard unit) and no buffer starts there; a range that fails is passed over and counted (`bad ranges passed over`).
- `lgp_free`: only a buffer that is out, with the exact start and size (a uint16 length per start unit, 32 KiB): given back
  twice, wrong size, unaligned, outside the pool, guard unit, across a chunk, inside a buffer, over free memory = refused,
  counted, free list unchanged. A full free list (2048 ranges) loses the free, counted as `lost`.
- Ranges merge only inside one chunk. gemNew zeroes through `topaz_gpu_pool_clear(pa, size)`: under the lock it checks that
  the buffer is out and takes its chunk's map; else no write, the buffer goes back, gemNew fails with one line.
- With 2154 (stage-1 SMMU, branch t3/laurel-gpu-upstream-opt): 2156 applies after it (checked: whole series + 2154 + 2156).
  2154's VA = PA frees (`redwood_gpu_address_free`, address >= 0x80000000) go through the same checked `pool_give_back`; its
  self-test unit (alloc + give back GPU_POOL_UNIT) is a valid buffer; its gemNew `goto scattered` (pool full) is before the
  clear. A VA = PA free that is not a pool buffer is refused and counted, not merged.

Lines to expect:
- every 5 s with GL frames: `RedwoodGPU: buffers: N made in U us each, K kept ones given again (M MB kept); GPU pool F of 512
  MB free in R ranges, 0 frees refused, 0 lost, 0 bad ranges passed over`.
- only on a bad free (at most 8): `LAUREL GPU POOL: free of PA+SIZE refused (N so far): REASON; caller ADDR`
  (ADDR = the caller of topaz_gpu_pool_free / redwood_gpu_address_free; `llvm-nm -n` the kernel).
- only if gemNew gets a buffer it cannot clear (should never show): `RedwoodGPU: pool buffer PA+SIZE has no kernel map
  that covers it: not used`.

## Console flash (boot 2026-11-01 07:20:52, fixed by 2104)

Owner report: GL works; when the UI is idle (no new GL frame) the panel shows kernel log text; the next frame covers it.
Log: `logs/usblog-20261101-001446.txt` (main checkout), boot from line ~50948.

Facts [V]:
- AppleCLCD's `fSurface` (surface 1) is the boot framebuffer 0x5c000000 (`SWEET FB: AppleCLCD 720x1560 stride 2880 at
  0x5c000000, default surface 1`). backboardd gets it from IOMFB (selector 4) and its GL draws frames into it:
  `RedwoodGPU: surface 1 (720x1560 fmt 0x42475241 bpr 2880, 4505600 bytes) shared at 0x5c000000`.
- backboardd presents surface 1 between GPU-pool frames: `SWEET FB: swap 6/8/10/32/34/38/40/42/50/52/64..70 layer 0
  surface 1` (07:22:59-07:27:02). Every GL boot since 06:12 has these swaps; the CPU boot 05:29 has one (swap 7).
- A swap of surface 1 is not GPU-pool, so it took the copy path. The copy path skipped `fSurface` ("already on the
  panel": true only before the flip buffers), then `flipBack()` showed the back buffer.
- With GL the GPU-pool frames are scanned directly (`scanFrom(pa)`), they never write the flip buffers. So both flip
  buffers still held console frames from boot (`sweet_console_copy_dirty` while `fConsShown`). Every surface-1 frame
  showed that old kernel log; the next GPU-pool frame covered it. Without GL the direct frames go through
  `flipFrom()`, so the back buffer holds a recent UI frame and nothing is seen.
- The video console itself does not draw into 0x5c000000 after `sweet_console_retarget()` (AppleCLCD start): it
  draws into the cached shadow `fCons`, which only `sweet_cons_show()` (panic) scans. kprintf goes only to the ring
  (2014). The early console (`sweet_early.c`) is off after arm_init.
- [I] The boot text that the console drew into 0x5c000000 before the retarget stayed there; a surface-1 frame
  scanned directly would show it where GL had not drawn yet. 2104 clears it.

Correction (2870, [V source]): with `serial=3` the kernel console is the fbcon, which drew into 0x5c000000 itself; the
video console below gets no text. See "Kernel log over the UI".

Fix 2104 `laurel-fb-console-handoff` (SweetFramebuffer.cpp, video_console.c):
1. A single-layer swap of surface 1 is direct (presenter thread, like GPU-pool frames): the MDP scans 0x5c000000 itself.
2. AppleCLCD start: after the MDP has latched the first console flip, the boot text in 0x5c000000 is cleared to black
   (the console text is in the shadow).
3. Copy path: surface 1 is copied into the back buffer like any surface (skipped only when the copy path composes into
   0x5c000000 itself, no flip buffers); a flip buffer that still holds a boot console frame is cleared before its first
   iOS frame.
4. First iOS frame: one line `LAUREL FB HANDOFF:`. Self-check: the console draws into its shadow
   (`sweet_console_on_shadow()`: shadow set, `vinfo.v_baseaddr` = shadow, paint hook in place). If not (no shadow, or
   `initialize_screen()` put it back on the boot framebuffer), the console stops drawing (`sweet_console_muted`; text
   still in the USB log; a panic draws).
5. Panic screen unchanged: `_cnputs` draws when `panic_active()`, `sweet_flush_rows` cleans the rows and
   `sweet_cons_show()` points the MDP at the shadow.
6. Boot-time text before the UI stays (the console frames until the first iOS frame): it is the only screen output
   when the boot stops before SpringBoard.
Kill switch `fbhandoff=0`: no direct scan of surface 1, no clear, no self-check (the copy-path fix stays).

Expected log lines (GL boot):
- `SWEET FB: console double buffered (shadow 0x...)` (start, as before)
- `LAUREL FB HANDOFF: on: first iOS frame owns the panel; kernel console only in its shadow 0x... (not scanned, shown
  again only by a panic); surface 1 = boot framebuffer 0x5c000000, scanned directly`
- `LAUREL FB HANDOFF: swap N shows surface 1 (boot framebuffer 0x5c000000) by scanning it directly` (once, at the first
  surface-1 frame)
- No `SWEET FB: swap N layer 0 surface 1 ...` lines any more (that line is logged only by the copy path).
- Fallback: `LAUREL FB HANDOFF: on: ...; no console shadow (...): console text off the panel (...)`;
  kill switch: `LAUREL FB HANDOFF: off: fbhandoff=0 ...`.
Test: GL boot, leave the UI idle for 1 min, then scroll and stop: no kernel text at any time.

## Kernel log over the UI (boot 2026-11-01 07:45, fixed by 2870)

Owner report (GL on, SMMU stage 1, 2104 in): "the kernel log / white text on black background is still an issue";
"when you move or do anything, the kernel log flashes ABOVE the iOS UI". Log `logs/usblog-20261101-001446.txt` (main
checkout) from line ~59950 (07:45:11), also `logs/laurel-boot-20261101-074445.log`.

Facts [V]:
- 2104 was active: `LAUREL FB HANDOFF: on: ... shadow 0xe6ae0000 ...` (07:45:24) and `LAUREL FB HANDOFF: swap 2 shows
  surface 1 (boot framebuffer 0x5c000000) by scanning it directly` (the line is glued to the end of a redwood-gl line).
  No `SWEET FB: swap N layer` line: no swap took the copy path, every swap was direct (`SWEET FB: 1000 swaps (direct)`).
- backboardd's frames alternate: 67 frames `1 picture copied out` (GL renders into a texture, `glReadPixels` into surface 1
  = 0x5c000000, 47-62 ms "copying out") and 65 frames `1 drawn in place` (the GPU draws into a GPU-pool surface, id 2).
  The MDP scans the one presented: one frame in two is 0x5c000000 itself.
- The boot-args (`scripts/laurel/uefi-image.sh`, `shim.sh`) have `serial=3`; the ADT has `/sweet-fbcon` with reg
  0x5c000000, 720x1560, stride 2880 (mkadt via topaz). `arm_init`: serialmode output + a serial device (the fbcon) ->
  `switch_to_serial_console()`, so `cons_ops_index` = serial. Older logs show `Serial keyboard started` (serialmode input).
- So every printf / IOLog character goes `_cnputs` -> `_cnputc` -> `serial_putc_options` -> `uart_putc` ->
  `fbcon_transmit_data` (pexpert/arm/pe_serial.c): white 0xffffffff on black 0xff000000, 2x glyphs, 2 rows cleared per
  newline, written straight into 0x5c000000. The video console (`vcputc`, 2104's shadow) gets no text at all with serial=3.
- Result: each kernel line during the UI was drawn into the surface-1 frame on the panel (text over the UI) until the next
  surface-1 copy-out overwrote it. Activity = more kernel lines (SWEET FPS, redwood-gl, SMMU fault, IOK) = more text.
- 2104's self-check (`sweet_console_on_shadow`) looked only at the video console, so it passed.
- Checked, no other path [V source]: the only writer of the pipe address is `AppleCLCD::scanFrom` (VIG0/DMA0/DMA1, one pipe;
  no other code maps 0x5e05000/0x5e25000/0x5e27000); callers: start (console flip), vsync (console copy while
  `fConsShown`, power-off black frame / fade), panic (`sweet_cons_show`), direct frames, copy path. No wake or "redraw"
  path scans a kernel buffer; display on only sends DCS. `sweet_early` is off after arm_init when a serial device
  exists. kprintf is ring-only (2014). No `initialize_screen` call after start. GPU-pool and scanout-slot surfaces are
  zeroed at creation; 0x5c000000 is cleared at AppleCLCD start (2104), so no UEFI/DarwinBoot text stays in it.
- [I] Before 2104 the same fbcon text was in 0x5c000000 too; the copy path then showed stale flip buffers instead, so the
  07:20 flash was both causes. After AppleCLCD start the boot screen did not follow the log (the shadow got no text with
  serial=3); 2870 makes it live again.

Fix 2870 `laurel-fb-scanout-owner` (SweetFramebuffer.cpp, pe_serial.c):
1. fbcon move: at AppleCLCD start, after the shadow got a copy of 0x5c000000, `laurel_fbcon_retarget()` points the fbcon at
   the shadow (cached; same 720x1560 geometry). Line `LAUREL FBCON: on: the fbcon (the kernel console, serial=3) draws into
   the console shadow 0x...`. The vsync copies the shadow into the boot console frame when the fbcon drew
   (`laurel_fbcon_take_dirty`, at the sweetfb_hz pace). At the first iOS frame a fbcon that is still on 0x5c000000 (no
   shadow) is muted (`LAUREL FBCON: on: the fbcon is still on the boot framebuffer ... stops drawing`).
2. Panic: the fbcon always draws; in a panic it cleans the drawn rows and calls `laurel_fbcon_show_hook` ->
   `laurel_fb_panic_show()` (MMIO only): the MDP scans the shadow (or 0x5c000000 if the fbcon did not move).
3. Scanout owner: `scanFrom(pa, stride, holds, who)` is told what the buffer holds (iOS frame, black, kernel text, panic).
   The console shadow is always kernel text; a flip buffer holds what it was last filled with (`fFlipHolds`). After the
   first iOS frame kernel text is refused: the panel keeps its frame; one line per caller
   `LAUREL FB OWNER: refused: <who> (caller 0x...) asked the panel to show <buffer> 0x... (kernel text) after the iOS
   handoff; the panel keeps <buffer> 0x... (iOS frame); N refused so far`. A panic is let through.
4. Clear: when the second iOS frame comes (the first is latched), the console shadow and the flip buffers that are not on
   the panel are filled with black and cleaned: `LAUREL FB OWNER: on: after the first iOS frame only iOS frames reach the
   panel (kernel text only in a panic); cleared to black: console shadow 0x..., 2 flip buffer(s); panel on ...`. The copy
   path also clears a back buffer that still holds kernel text before it composes.
Kill switch `fbowner=0`: no refusal, no clear (`LAUREL FB OWNER: off: fbowner=0 ...`); the fbcon move stays.

Expected log lines (GL boot, serial=3):
- `SWEET FB: console double buffered (shadow 0x...)`
- `LAUREL FBCON: on: the fbcon (the kernel console, serial=3) draws into the console shadow 0x..., no longer into the
  boot framebuffer 0x5c000000 (surface 1, iOS frames)`
- `LAUREL FB HANDOFF: on: first iOS frame owns the panel; kernel console only in its shadow 0x... (console = fbcon, in
  the shadow; not scanned, shown again only by a panic); surface 1 = boot framebuffer 0x5c000000, scanned directly`
- `LAUREL FB OWNER: on: after the first iOS frame only iOS frames reach the panel ...; cleared to black: console shadow
  0x..., 2 flip buffer(s); panel on an iOS surface 0x... (iOS frame)`
- No `LAUREL FB OWNER: refused:` line. If one comes, it names the caller (a bug to fix there; the panel kept the iOS frame).
Test: GL boot; the boot log must still move on the panel until the lock screen; then scroll, open apps, leave idle 1 min:
no white text at any time. A panic must still show its text (not tested yet).
## Zero copy, cache upkeep, GPU time (boot 2026-11-01 07:45, fixed by 2158 + 2159; Metal gate)

Owner report: "GPU acceleration ... is still CPU rendered". Log `logs/usblog-20261101-001446.txt` (main checkout) from 07:45:11
(kernel 2154 + 2156 + 2157 + 2104, stage 1 on).

Observed [V log]:
- `LAUREL GPU SMMU: on: stage 1 ...`, `LAUREL GPU: on ... SMMU stage 1`, `LAUREL METAL: on: Turnip a610 ...`.
- Frames alternate between surface 2 (backboardd, GPU pool: `0 pictures copied out, 1 drawn in place`, 7-17 ms) and
  surface 1 (`-attachImage: texture 4 is IOSurface 1 ('BGRA' 720 x 1560, 2880 bytes a row): a copy`; `1 picture copied out`,
  31-62 ms "copying out"). Frame 1020: 59196 us, 31083 copying out; frame 1060: 70588 us, 27966 handing on, 35335 copying out.
- Every 5 s line: `13400-16648 KB out of the cache in 5283-15897 us a submission`, 100-400 submissions in 5 s. Examples:
  07:49:14 299 x 6216 us = 1.86 s of 5 s; 07:50:49 400 x 5419 us = 2.17 s of 5 s (43 %).
- `the GPU worked 0 us on each of 0` in every line; `core 300 MHz` is the programmed value, not a measured one.
- `LAUREL GPU SMMU: fault FSR 00000400 FAR 0001126404822902 FSYNR0 00040021` every 5 s, always the same values.
- `SWEET FPS: 201 frames in 10045 ms, ... 159 late; a frame: 9626 us in present + latch`.

Causes [V source unless marked]:
1. **Surface 1 copied out.** With the tables, `surfaceBuffer()` took only surfaces whose IOBufferMemoryDescriptor holds the
   64 guard rows (2154). Surface 1 is the boot framebuffer (`sweet_surface_create_physical`, a physical descriptor, no rows
   after it): refused, so eagl.c read every surface-1 frame back with glReadPixels. In pass-through it was shared
   (`RedwoodGPU: surface 1 ... shared at 0x5c000000`, earlier boots). "copying out" = glReadPixels (eagl `target_to_surface`).
2. **"handing on" = the kernel's cache push in GEM_SUBMIT.** "handing on" is the time in glFlush (eagl `my_glFlush`), and
   glFlush ends in GEM_SUBMIT. (a) RedwoodGPUStart sets `gpu_cached = 1` when the SMMU translates (for scattered buffers), and
   submit() pushes every own buffer that Mesa has mapped (`b->seen`) when gpu_cached is 1: command streams, upload and
   staging buffers, nearly all from the write-combined GPU pool, at **every** submission. (b) Surfaces: the "again after
   4 ms" rule; the push itself takes longer than 4 ms, so every next submission pushed them again. [I] (a) is most of the
   13-16 MB: early frames (07:45:24-31) had no CPU-memory surface imported and still pushed 16 MB per submission.
   "waiting" (5-13 ms on in-place frames) is eagl's fence-sync flush: one more GEM_SUBMIT with the same push.
3. The fault line: FSR bits 10:9 are FORMAT (read-only, 2 = AArch64 with the tables); no fault bit is set. False alarm.
4. A wrapped picture (`SWEET SURF: wrap image ... at +0x40`, BGRA, 64-byte rows) was given to the GPU from its page start in
   stage 1: its texture is 0x40 bytes off [V source; not seen on the screen].
5. CPU_PREP waited for the last submission of all, not of the buffer.

Fix, kernel **2158** `laurel-gpu-zero-copy` (RedwoodGPU.cpp, TopazAdreno.cpp, SweetSurface.{h,cpp}):
- `redwood_gpu_map_scratch()`: one GPU-owned page entered at every page after a stage-1 surface that has no guard rows of
  its own (64 rows rounded to pages, plus the rest of the 64 KiB VA granule). So every BGRA surface with 64-byte rows goes to
  the GPU as it is: the boot framebuffer, pool surfaces, wrapped pictures (offset = wrapDelta + offset, 64-byte aligned or
  refused). Bergamota's "zero page after each surface BO" (docs/gpu-status.md review), done with one page for all.
- Cache push: never for a VA = PA buffer (GPU pool) or a surface whose maps are all write-combined (`SweetSurface::noCache`,
  the physical framebuffer); a kernel surface when its seed moved (a CPU write lock let go) or after 250 ms (writers that do
  not lock); wrapped client memory at most every 16 ms; times from the end of the push.
- Request **0x7d `kRedwoodDrawn`**: "the GPU drew this surface": the seed moves (whoever watches it sees the new picture) and the
  buffer counts as pushed at the new seed when nothing else moved it. Before, eagl.c did a write lock + unlock for that, which
  made the next submission push the surface again.
- CPU_PREP waits for the buffer's own last submission (Linux `msm_gem_cpu_prep`).
- SMMU fault line only with a fault bit (`FSR_FAULTS`).
- Kill switch `gpuseed=0`: the old push rule (4 ms, gpu_cached buffers, write-combined surfaces too). Pass-through: unchanged.

Fix, kernel **2159** `laurel-gpu-time-clock` (TopazAdreno.cpp, RedwoodGPU.cpp): every submission is framed by CP time stamps of
the always-on counter (CP_REG_TO_MEM of CP_ALWAYS_ON_COUNTER 0x980 before the IBs, CP_EVENT_WRITE RB_DONE_TS with the
timestamp bit after them, as Mesa's fd6 time queries; 128 slots at fence page + 0x400). Done submissions are added up (union of
[start, end]) into the existing "the GPU worked N us on each of M (histogram)" fields; CP perf counter 0 (ALWAYS_COUNT, already
selected by hw_init_regs) over the busy time gives the measured core clock. +10 ring dwords per submission. A stamp that is not
written is not counted (`some submissions not timed`); the GPU work is unchanged.

User space (scripts/laurel/gpu-userland.sh, mesa-linux.sh):
- `userland/laurel/gpu/mesa-patches/0001-redwood-drm-surface-drawn.patch`: Mesa's redwood-drm exports
  `redwood_drm_surface_drawn(surface, &seed)` (request 0x7d). mesa-linux.sh applies it and checks the export.
- `userland/laurel/gpu/patches/0002-eagl-gpu-drawn-seed-frame-times.patch`: eagl.c moves the seed of a GPU-drawn target with
  it (one `LAUREL GL DRAWN: on|off:` line; off = the lock as before), and logs frame times every 10 s.
- The display path [V source]: GPU-pool frames and (2104) surface-1 frames are scanned directly by the MDP (`scanFrom`); no CPU
  copy into the scanout. With 2158 surface 1 is drawn by the GPU (eagl's GPU blit into its mirror texture) like surface 2.

Expected effect [I, from the 07:45 numbers]: no "copying out" frames (was 31-62 ms on every 2nd frame); "handing on" and
"waiting" down to Mesa's own flush time (frames 3-13 of 07:45: 0.1-0.8 ms handing on before the pushes grew), i.e. the
5.3-15.9 ms push per submission gone (24-43 % of backboardd's wall time in the 5 s windows above). The GPU busy % from 2159
then says whether the 300 MHz clock limits anything.

Expected lines (next GL boot):
- `|backboardd| LAUREL GL DRAWN: on: surfaces the GPU drew get their new seed from the kernel (request 0x7d), no cache push for them`
- `redwood-gl: -attachImage: texture N is IOSurface 1 ('BGRA' 720 x 1560, 2880 bytes a row): a texture, copied into its memory by the GPU`
- frame lines with `0 pictures copied out, 1 drawn in place` for every frame.
- every 10 s: `redwood-gl: N frames in T ms (F a second); a frame A ms on average, the longest L ms, X over 16.7 ms, Y over
  33.3 ms; on average H us handing on, W waiting, C copying out; 0 frames with a picture copied out; ...`
- every 5 s: `RedwoodGPU: N submissions ... K KB out of the cache in U us a submission; the GPU worked G us on each of M (...);
  ...; P surface pushes, Q passed over (no CPU write since the last, or write-combined); GPU busy B %, core C MHz while busy,
  W MHz over the window`. K should be near 0 while nothing CPU-draws; C should read about 300.
- no `LAUREL GPU SMMU: fault` line unless a real fault.
- Metal gate (metal.md 6.1; launchd job as root since 2026-11-01 16:30, the wrapper no longer starts it): `LAUREL METAL CLIENTS: on: ...` or `off: <reason>` (console = USB log, syslog, /var/tmp/laurel-metal-gate.log).
If `RedwoodGPU: N submissions` shows `(some submissions not timed)` and `the GPU worked 0 us`: RB_DONE_TS does not write the
counter on the A610 [U]; the rest of 2158/2159 is not affected.

### GPU clock (owner item 4): not raised in this round (done later by 2892: section "GPU clock by demand")

Facts [V]: kgsl trinket OPPs 320-950 MHz (table above); gfx3d votes vdd_cx (`gpucc-trinket.c` rate_max: LOWER 320, LOW 465,
LOW_L1 600, NOMINAL 745, NOMINAL_L1 820, HIGH 900, HIGH_L1 950); the GX GDSC hangs off the same CX corner; TopazRpm has
`topaz_rpm_write()`, but no TopazRpm line in the 07:45 boot (its link state is not known [U]) and nothing reads the RPM's
present CX corner. Why not now [I]: an AP vote replaces the AP's earlier CX vote (ABL/UEFI may have voted higher for the
display or storage clocks); voting a lower corner than that can brown out other AP blocks, and a GPU clock above 320 MHz
without a confirmed CX corner can fail silently (negroni lesson: wrong clocks went unseen for days). Also the 07:45 frames
were CPU/copy bound (above), not GPU bound. Next step: boot 2158 + 2159, read `GPU busy B %` and `core C MHz`; when B stays
above ~60 % during scrolling, add GPU DCVS 300/600 MHz (600 = GPLL0 / 1, no PLL) behind a self-check: RPM link up, CX vote
LOW_L1 (192) acked, measured clock within 10 % after the switch, TSENS sensor 15 (LAUREL THERMAL `gpu`) below 85 C, back to
300 at 95 C. Kill switch `gpudcvs=0`.

## Kernel changes for Metal clients (2026-11-01 16:30; built, NOT BOOTED; metal.md 6.1-6.2)

- 2160: request 0x49, the caller's pages as a GPU buffer, stage 1 only. Line `LAUREL GPU HOST PAGES: on|off`; kill switch `gpu_hostimport=0`. No change for GL (it never asks).
- 2161: `redwood_gpu_submit` starts each submission with PC_CCU_INVALIDATE_DEPTH + COLOR (Linux `a6xx_submit`; Turnip assumes it). 4 more ring dwords; also for GL. If GL frames get slower or
  wrong after this boot, this is the first suspect [I]: the GL numbers of the 15:27 boot are the reference (frames 8-13 ms).
- 2851: `LAUREL METAL` line prints the real RedwoodMaxBuffer. 2154 already set 256 MiB with the tables; Turnip 0101 reads it [V source].
- 2155's watchdog (3 s with work pending and no fence move) now also sees Metal work while GL runs: one Metal submission above 3 s on this 300 MHz GPU turns the GPU off for the boot (GL -> software renderer, Metal -> nil) [I, by design; not seen].

## First boot with Metal on the GPU (18:40; metal.md section 11; built, NOT BOOTED)

- 0x7e (`surfaceBuffer`) keeps its GL rule (one plane, 4 bytes, rows of 64 unless GPU pool): 173 Metal imports failed on it [V log + source]. Turnip's stand-in now takes the caller's pages (0x49) for those. Kernel unchanged there; kill switch `gpu_hostimport=0`.
- GL: `redwood-gl: a new kind of surface shown: ...` per pixel format; `-attachImage ... not done` once per format (eagl patch 0003).
- 2162: a SIGBUS names its file: `CRASH <name> file <path> size N, offset 0xO`. Only a log line.
- GL frames 10-16 ms, 26-38 fps in this boot, 8-13 ms in the 15:27 reference [V]. The load differs (Metal clients, widgets, first boot at 100 % CPU); what part 2161 (CCU invalidate) has is [U].

## GPU clock by demand (2892; built, NOT BOOTED)

### What the logs say [V logs/laurel-boot-1934.txt]

- **The core clock was never measured.** One kernel log line ends after 255 bytes: every long line in the boot stops at 264 characters of the USB log (9 of time stamp + 255). The 2159 line has `GPU busy B %, core C MHz while busy` at its end, so this text is in no log (`grep -c "GPU busy"` = 0 in every log of the main checkout). 2892 prints three short lines. So `300 MHz` in `LAUREL GPU: on` and `LAUREL METAL` is the programmed value, not a measurement.
- The first fields of the line do reach the log. Busy % = N us x M submissions / window:

| Time | Submissions / window | us each | Busy at 300 MHz |
| --- | --- | --- | --- |
| 19:41:32 | 493 / 5005 ms | 3997 | 39 % |
| 19:41:43 | 834 / 5007 ms | 3637 | 61 % |
| 19:42:03 | 957 / 5000 ms | 3598 | 69 % |
| 19:42:29 | 714 / 5000 ms | 5734 | 83 % |
| 19:43:08 | 343 / 5000 ms | 7745 | 53 % |
| 19:43:14 | 249 / 5309 ms | 10190 | 48 % |

  Other active windows 19-54 %. So the zero-copy agent's condition ("B above 60 % while the UI moves") is met in part. These numbers include the Metal clients' submissions, not only GL. The same boot, scrolling windows: GL frames 36-46 a second, a frame 7-13 ms on the CPU side, of which 2.4-5.7 ms "handing on", 0.5-0.9 ms "waiting" (the CPU rarely waits for the GPU) [V 10 s lines].

### Source facts [V external/laurel-kernel-los]

| Item | Value | File |
| --- | --- | --- |
| GPLL0 at the GPU's input | 600 MHz (`gcc_gpu_gpll0_clk_src` parent `gpll0_out_early`, `F(100000000, P_GPLL0_OUT_EARLY, 6)`) | gcc-trinket.c |
| Levels | 320 465 600 745 820 900 950 MHz, bus level 4 7 8 9 10 11 11 (451 768 1017 1353 1555 1804 1804 MHz) | trinket-gpu.dtsi |
| CX for gfx3d | 320 LOW_SVS 64, 465 SVS 128, 600 SVS_PLUS 192, 745 NOM 256, 820 NOM_PLUS 320, 900 TURBO 384, 950 TURBO_NO_CPR 416 | gpucc-trinket.c, vdd-level-trinket.h |
| MX | PLL VCO up to 2 GHz: NOM (stock 600 MHz runs from PLL0) | gpucc-trinket.c |
| RPM resources | CX = `rwcx` id 0, MX = `rwmx` id 0, key `vlvl` | pm6125-rpm-regulator.dtsi, rpm-smd-regulator.c |
| Other AP clocks that XNU keeps as ABL set them | UFS AXI 200, ICE 300, UniPro 150, USB master 200 MHz: NOM; MDP up to 384 MHz: NOM; camera VFE 403-576 MHz: SVS_PLUS to TURBO | gcc-trinket.c, dispcc-trinket.c |
| Read of the clocks | GCC clock counter (mux 0xDD + GPUCC mux 0xB, post divider 2); DDR: MCCC period register 0x447d220 (ps) | debugcc-trinket.c, clk-debug.c |
| DDR vote | RPM `clk2` id 0 `KHz`; bus level MHz x 1000 kHz (8136000 KBps / 8 = 1017000) | clk-smd-rpm.c, trinket-bus.dtsi |
| Linux at start | votes BIMC to INT_MAX, then `clk0` id 2 `Enab` = 1 in both sets (`clk_smd_rpm_enable_scaling`) | clk-smd-rpm.c |

### Why the rail vote is safe now

The zero-copy agent's two fears: nothing reads the CX vote, and a lower vote can brown out other blocks.
- [V boot 19:34] `TopazRpm: rpm_requests open`: TopazRpm opens the link only if both FIFOs are unused since boot. So no AP code sent an RPM vote before TopazRpm in this boot; no AP vote exists that ours could replace. The RPM takes the maximum over its masters [I, its design].
- [I] What the rail holds now is still unknown (no rail statistics in the trinket DT: no `rpm-rail-stats`). So the vote must not be able to lower the rail below what the AP needs: **NOM on CX and MX, once, before the first raise, held for the boot.** NOM is what the AP's running clocks need in the Linux tables (row above). 300 and 600 MHz both sit at or below NOM, so no rail moves between the levels. The order the owner asked for holds: rails up before the clock, clock down first, and the rails never go down.
- Cost [I]: if the rail is below NOM today, idle power rises by the difference (not measured; no reader). The camera's VFE above 480 MHz still has no vote of its own (as today).
- A later corner above NOM (820+ MHz) would be the first vote that goes up and down.

### What 2892 does

`iokit/Kernel/arm/LaurelGpuDcvs.cpp` + `laurel_gpu_clock_read.h`, a few hooks in TopazAdreno.cpp, the split line in RedwoodGPU.cpp. Own thread, started after `LAUREL GPU: on`.
1. Self-check: GPU temperature from LAUREL THERMAL (30 s at most), clock read at 300 (10 % window), RPM MX then CX NOM acked, GPLL0 / 1, clock read at 600, one CP fence if the ring is idle, back to 300 and read again. The GCC counter is the check; the CP counter of 2159 is logged next to it and is the check only if the GCC counter does not count.
2. Demand (50 ms tick): busy (2159 stamps) >= 50 % over a tick or a touch in the last 300 ms -> 600, with a read of the clock at each raise; below 20 % (of 600, = 40 % of 300) for 500 ms -> 300.
3. Thermal: sensor 15; no 600 from 90 C until below 80 C; no reading counts as hot. (Linux trip `gpu-step` 95 C.)
4. The GPU watchdog (2155): no fence progress for 1500 ms at 600 -> 300 MHz, the feature off, the 3 s count starts again. Only a hang that also stays at 300 turns the GPU off.
5. Time per level a minute. Kill switch `gpudcvs=0`. Any failure: 300 MHz, one line, GPU on. Votes already sent stay (they only raise).
`core_mhz` stays 300 for MSM_PARAM_MAX_FREQ and the `LAUREL GPU` / `LAUREL METAL` lines (the programmed base clock).

Levels above 600 MHz: section "All stock levels" (2961). Items 2, 3 and the thermal limits above are the 2892 rules; 2961 replaces them.

### DDR: held low? [U, the next boot says]

- [V source] No XNU code votes BIMC: no `qcom,gpubw`, no CPU bwmon/memlat (Linux has them, battery-power.md), no `clk0` `Enab`. Only `ipa` KHz (2780), LDOs (`ldoa`).
- [I] Linux enables RPM clock scaling at start; without that message the RPM may keep its bus clocks at the boot rates, and may ignore a vote. So DDR may be low or high, fixed. The `LAUREL DDR` line reads it (MCCC period, no write).
- 2892: DDR >= 1017 MHz: no vote. Lower: one vote of 1017 MHz, read again. It follows: 1017 with GPU 600 or Gold >= 1400 MHz, else max(boot clock, 451), down only after 500 ms. It does not follow: `off`, no more votes. **`Enab` is not sent:** it could let the RPM lower SNOC, CNOC, MMRT and others that nobody votes for (display underrun, UFS) [I]. If the line says DDR is low and does not follow, the next step is `Enab` with votes for those clocks at their measured rates: an owner decision after that boot.

### Expected lines

```
RedwoodGPU: 834 submissions in 5007 ms: 2890 command buffers and 32797 buffers named, 36 KB out of the cache in 23 us a submission; GPU busy 31.2 %, core 590 MHz while busy, 410 MHz over the window
RedwoodGPU: the GPU worked 1820 us on each of 834 (...; 1518 ms in all)
RedwoodGPU: 12 waits of 300 us, 3 over before they began; ...
LAUREL DDR: on: 1353 MHz measured, not lower than the GPU's bus level (1017 MHz at 600 MHz): no vote needed       (or a vote line, or off: ...)
LAUREL GPU CLOCK: on: GPLL0 300/600 MHz, measured GCC 300/600 CP 300/600 MHz, CP fence at 600 in 80 us; MX+CX NOM held; raise at 50 % busy or touch, lower below 20 % for 500 ms; no 600 from 90 C to 80 C
LAUREL GPU CLOCK: on: last minute 300 MHz 41 s, 600 MHz 19 s, 37 raises, 0 hot refusals; busy 22 % of the time, gpu 48.1 C, DDR 1353 MHz
```
(Numbers are examples, not results.) Failures: `LAUREL GPU CLOCK: off: the clock at 300 does not measure 300 (a, b MHz); 300 MHz stays` (that line alone is news: the real clock, as in negroni's lesson), `RPM refused the MX/CX vote`, `no CP fence at 600 MHz`, `no GPU progress for 1500 ms at 600 MHz`.

### Test

1. Boot. Read `LAUREL GPU CLOCK: on` and `LAUREL DDR`: real clocks for the first time.
2. Scroll Settings, open Safari, Control Center for 1 min. Compare the `GPU busy` and `SWEET FPS` lines with this table and with `gpudcvs=0` (kill switch boot) if the result is not clear.
3. No hang, no panic, no `GPU hang` line. A long game-like load: `gpu N C` in the minute line, a refusal above 90 C.
4. Reboot, a crash or a frozen panel right after the first scroll: `gpudcvs=0` and report it. That is the one failure the self-check cannot turn off: a clock that passes the check and later breaks a block.

## All stock levels to 950 MHz (2961; built, NOT BOOTED)

Owner decision 2026-11-03. `iokit/Kernel/arm/laurel_gpu_opp.h` (table + rules, no hardware access), `LaurelGpuDcvs.cpp` (the operations and the thread), `laurel_gpu_clock_read.h` (DDR), two hooks in `TopazAdreno.cpp`. Both kernels: `patches/laurel/xnu/2961-laurel-gpu-opp.patch`. Edit in `src/xnu`, then `scripts/laurel/gpu-opp-patch.sh`.

### Table [V]

Sources: `trinket-gpu.dtsi`, the phone's DTB (`boot.img`, TRINKET msm-id 0x18a; 3 DTBs of the SoC have the same levels; no `qcom,gpu-speed-bin`; `dtbo.img` has no GPU levels), `gpucc-trinket.c`, `vdd-level-trinket.h`, `clk-alpha-pll.c`, `adreno-gpulist.h`. `scripts/laurel/test-gpu-opp.sh` checks the table against all of them.

| MHz | Source | RCG src / div | VCO MHz | L | ALPHA_U | ALPHA | VCO range | Stock CX corner | Vote on CX | Bus level, DDR MHz (min-max level) | iPeak |
|---:|---|---|---:|---:|---|---|---|---|---|---|---|
| 300 | GPLL0 / 2, **not stock**, fallback | 5 / 2 | | | | | | LOW_SVS 64 | NOM 256 (held) | 451 | no |
| 320 | PLL1 AUX2 / 2 | 4 / 2 | 640 | 33 | 0x55 | 0x55555600 | 2 | LOW_SVS 64 | NOM 256 (held) | 4, 451 (3-5) | no |
| 465 | PLL1 AUX2 / 2 | 4 / 2 | 930 | 48 | 0x70 | 0 | 2 | SVS 128 | NOM 256 (held) | 7, 768 (5-8) | no |
| 600 | GPLL0 / 1 (stock: PLL0 at 1200) | 5 / 1 | | | | | | SVS_PLUS 192 | NOM 256 (held) | 8, 1017 (7-9) | no |
| 745 | PLL0 AUX2 / 2 | 2 / 2 | 1490 | 77 | 0x9a | 0xaaaaab00 | 0 | NOM 256 | NOM 256 | 9, 1353 (8-10) | no |
| 820 | PLL0 AUX2 / 2 | 2 / 2 | 1640 | 85 | 0x6a | 0xaaaaab00 | 0 | NOM_PLUS 320 | 320 | 10, 1555 (9-11) | no |
| 900 | PLL0 AUX2 / 2 | 2 / 2 | 1800 | 93 | 0xc0 | 0 | 0 | TURBO 384 | 384 | 11, 1804 (9-11) | **yes** |
| 950 | PLL0 AUX2 / 2 | 2 / 2 | 1900 | 98 | 0xf5 | 0x55555600 | 0 | TURBO_NO_CPR 416 | 416 | 11, 1804 (10-11) | **yes** |

- PLL: CONFIG_CTL 0x4001055b; USER_CTL bit 2 (AUX2), bit 24 (alpha), bits 20-21 (VCO); MODE bit 23; TEST_CTL_U bit 0 = 0. Start: BYPASSNL, 5 us, RESET_N, LOCK bit 31 (stock: 100 reads, here 200), OUTCTRL.
- MX: NOM for a VCO to 2 GHz, held for the boot (2892). All levels are inside it.
- **The CX vote for 300 to 600 MHz is above the GPU's own corner.** It is the NOM of 2892, held for the other AP blocks, not a GPU need. From 745 MHz the vote is the stock corner. The vote never goes above the stock corner of the level; after a lower it falls back to NOM.
- 600 MHz stays on GPLL0 / 1: the same frequency, read on the phone, and no PLL to keep running.
- `qcom,gpu-gaming-bin` is a fuse that only answers a userspace query (`adreno.c`). It limits no level [V].

### CX iPeak [V], not in the earlier notes

`adreno-gpulist.h`: A610 `cx_ipeak_gpu_freq = 900000000`. `kgsl_pwrctrl.c`: before the clock crosses 900 MHz it votes `cx_ipeak_update(true)` ("Hardware damage is possible at peak current if mitigation not done to limit peak power"); if the vote times out, the clock stays. After a lower below 900 MHz it withdraws. `cx_ipeak.c` v2, `cx_ipeak_lm` = TCSR 0x3ed000, client 5: vote at +0x6000 bit 0, wait up to 50 ms for +0x24 (danger) = 0; feature at +0x10; bypass at +0x6004 bit 0. No feature or a bypassed client: stock sends no vote, and neither does 2961. So 900 and 950 MHz are not "just a corner".

### Order [V host test]

| Change | Steps |
|---|---|
| Raise | iPeak (from 900), DDR, CX, PLL + lock, RCG, clock read |
| Lower | PLL + lock, RCG, iPeak off, CX. DDR falls 500 ms later |
| Level on the same PLL | RCG first to GPLL0 (600 or 300, never above the old clock), PLL stop, program, lock, RCG. A running PLL is never changed: no dynamic update, and no glitch |

Failure: a refused vote or no lock: the clock stays, one line, that level goes out of the table. When a level on the same PLL fails, the old rate comes back; when that also fails, the clock stays on GPLL0.

### Self-check, at start

Temperature, read at 300, MX + CX NOM, 600 (read, CP fence), back to 300 (read): the fallback of 2892; a failure here gives `off`. Then 320, 465 (PLL1), 745, 820, 900, 950 (PLL0), each with lock, read (GCC, else CP; 3 %), CP fence. A level that fails goes out; a PLL0 level above it is not tried. Lowest level after that: 320 when it passed, else 300.

Read tolerance 3 %, not 10 %: 900 and 950 are 5.5 % apart. Boot 11 reads: 298/300, 598/600.

### Governor (50 ms tick)

- Busy >= 90 %: the top level. Busy >= 50 %: the level where the same work takes 45 %, one level at least.
- Touch in the last 300 ms: 745 MHz at least (no rail above what is held, no iPeak; not the top, so a tap does not vote DDR and TURBO).
- Lower: when the same work takes 45 % or less on a lower level, for 500 ms without a break. 45 < 50: no ping-pong (host test: each steady load settles).

### Thermal [V trinket-thermal.dtsi, phone's DTB]

Sensor 15. **95 C** (`gpu-step`, no hysteresis): a raise is refused, and one level down per tick. Below 95 C: one level up per tick. **100 C** (`gpu-cx-mon`, hysteresis 5 C): the lowest level until below 95 C. No reading counts as 100 C. Vendor `thermal-engine*.conf` has no GPU rule (only `TEMP_CPU0` for cpu2 and a monitor) [V]. The 90/80 C of 2892 were ours, not stock. `gpu-usr` 110-125 C are reset monitors.

### DDR

Stock vote: `msm_bus` path 26 -> 512, ib of the level, /8 = the DDR clock. Here: RPM `clk2` id 0 `KHz`, at the `bus-freq` of the level. Stock also scales in `bus-min`..`bus-max` by the `bw_vbif` governor; here only `bus-freq`. So at 900 and 950 MHz the vote is **1804 MHz, the stock one** [V].

**What the phone does with it: [U].** All boots read `DDR 1355 MHz` [V], and 2892 sent no vote, because 1355 >= 1017. The RPM has never had a DDR vote from XNU on this phone, and XNU sends no `clk0` `Enab` (`clk_smd_rpm_enable_scaling`), so it may ignore it. `ddr_start` votes 1804 once at start and reads the period register:
- A rise of 10 % or more: votes per level, never below the boot clock (snapped to the level, 1353).
- No rise: `LAUREL DDR: off: ...`, the vote goes back to the boot clock, and 820+ MHz run with DDR at 1353. `Enab` stays an owner decision (section "DDR: held low?"); it could also let the RPM lower SNOC and CNOC.

### Lines

```
LAUREL DDR: on: 1355 MHz at boot, a vote of 1804 gave 1804 MHz, 1353 MHz now; stock bus level of each GPU level, never below 1353 MHz
LAUREL DDR: off: 1355 MHz at boot, 1355 MHz after a vote of 1804 MHz: the RPM does not follow (no scaling enable); 820+ MHz run on the boot clock
LAUREL GPU CLOCK: on: MHz=GCC/CP 320=320/320 465=464/465 600=598/600 745=744/745 820=820/820 900=900/900 950=950/950; fence 90 us; iPeak; raise 50 % or touch; hot 95 C
LAUREL GPU CLOCK: on: MHz=GCC/CP 320=... 820=820/820; fence 90 us; iPeak; out 900 950: 900: RPM refused the CX vote 0/0; raise 50 % or touch; hot 95 C
LAUREL GPU CLOCK: on: 950 MHz out: the clock read is wrong (read 817/820); now 900 MHz
LAUREL GPU CLOCK: on: no GPU progress for 1500 ms at 950 MHz; PLL levels out, 300/600 MHz goes on
LAUREL GPU CLOCK: on: last minute 320 MHz 12 s, 600 MHz 3 s, 950 MHz 44 s, 17 raises, 0 hot refusals; busy 41 % of the time, gpu 61.0 C, DDR 1804 MHz
```
(Numbers are examples.) Kill switches: `gpudcvs=0` (300 MHz only, no vote), `gpupll=0` (the 300/600 path of 2892: no PLL, no iPeak register, no DDR vote above what 2892 sent).

### Not proved on the host

Only the phone tells: PLL lock, the reads, the fence at 950 MHz, the RPM's answer to CX 320/384/416 and DDR 1804, the TCSR read, heat. Long load: `gpu N C` in the minute line. Reboot or frozen panel right after the first scroll: `gpupll=0`, and report it.

## IOSurface formats and blank layers (boot 2026-11-01 20:02; built, NOT BOOTED; widget trace: metal.md section 12)

**Rule: GL in backboardd does not leave a surface blank.** CoreAnimation (QuartzCore 20H392 `CA::OGL::GLESContext::attach_surface_texture`, 0x1884088e4 [V]) has a GL form of its own for BGRA, RGBA, A008, L008, L565, L555, RGhA, RGfA and the 420/422/444 pairs: these go to `-texImageIOSurface:`, its shaders convert YCbCr. Every other OSType goes to `-attachImage:toCoreSurface:invertedRender:`, and the answer is not read (0x188409048-0x18840904c [V]): a refused attach is an empty texture.

`userland/laurel/gpu/surface_formats.c` (host test: `scripts/laurel/gpu-surface-test.sh`, gpu-userland.sh runs it) turns every layout into 8-bit blue-first pixels. Sources of the layouts:

| OSType | Metal format | Layout | Source |
|---|---|---|---|
| `_RB4` | 542 RGB8_444_2P | plane 0 green bytes (w x h), plane 1 (blue, red) byte pairs (w x h), no alpha. Codes as they are, no conversion | [V] RenderBox table 0x1e6945af0, plane sizes `RB::create_iosurface` 0x1e68b47d4 (1 + 2 bytes); [V m2v ycbcr_write.rs, measured on Apple GPUs] channels. **Not** 4 + 1 bytes (flame/0016's comment reads 550's case). The kernel's top-level bpe 4, bpr 1152 are its default: RenderBox gives no top-level value |
| `w30r`, `w30R` | 554, 555 BGR10_XR(_sRGB) | bits 31-30 unused (Metal writes ones), red 29-20, green 19-10, blue 9-0; value = (code - 384) / 510 | [V] m2v extended_range.rs; RenderBox table 0x1e69456f0 |
| `w40a`, `w40p` | 552, 553 BGRA10_XR | 16-bit fields B G R A, code in the top 10 bits | same |
| `b3a8` | 550, 551 RGB10A8_2P_XR10 | plane 0 as 554 (top bits zero), plane 1 alpha bytes | m2v surface_two_planes.rs. The kernel still keeps it as one-plane BGRA, m2v refuses 550 there: [U] does anybody ask for it. The `kind:` line tells |
| `l10r` / `R10k` | 94 / 90 | alpha 31-30, then 10-bit fields: blue low / red low | RenderBox table + m2v |
| `RGhA`, `RGfA`, `L00h`, `2C0h`, `L00f`, `2C0f` | | half or float channels, clipped; sRGB-encoded when the surface's colour space says Linear | |
| `L565 L555 4444 L008 A008 LA08 2C08 L016` | | as named | |
| `420f/v 422f/v 444f/v`, `xf20 x420 xf22 x422 xf44 x444`, `pf20 p420 pf22 p422 pf44 p444`, `xf4p`, `yuvs yuvf 2vuy 2vuf` | | BT.601/709/2020 by `IOSurfaceYCbCrMatrix`, range by OSType, chroma nearest | m2v ycbcr.rs. In the normal path CA samples the planes itself; this is for `-attachImage:` and refused forms |
| any other | | by layout: one plane 4/8/16/2/1 bytes, or planes 1+2, 2+4, 4+1; one line `THIS OSTYPE IS NOT KNOWN, best effort` | |

**GPU or CPU.** (2913 + eagl 0005: also `_RB4` and A008, L008, LA08 by the GPU, section "Frame budget".) Before them the kernel imported only one plane of 4-byte pixels with rows of 64 (`surfaceBuffer`). So: 32-bit word formats go as bytes through the existing zero-copy import, `xr_pass()` rebuilds the word in a shader and writes the texture CoreAnimation reads, once per frame in which the texture is bound (corrected in "Black layers": a Metal client's write does move the seed). Self-check: import or framebuffer fails = one line, CPU from then on. All else (`_RB4` included): CPU, on seed change or a changed sum of all planes; `sys_dcache_flush` first, because another process's GPU wrote the memory. Widgets change rarely; the sum follows the still-surface rule (every 8th frame after 120 equal looks).

**What the kernel hides.** SweetSurface keeps `w30r`, `l10r`, `w30R`, `b3a8` as BGRA, for CPU clients (HackiOS): they read that back. So the OSType cannot say what a Metal client draws. flame/0020 writes the texture's pixel format into the surface value `LaurelMetalFormat`; `surface_drawn_as()` reads it. No heuristic: BGR10_XR's top bits are ones, a word reads as an opaque BGRA pixel.

**Crash of 20:16:15 (backboardd sig 11).** Not a write to a read-only mapping: the signal address is 0x18, the `far` in the CRASH line is stale. [V dSYM] pc = `fd_bo_mark_for_dump(NULL)` <- `fd_bo_heap_alloc` <- `fd_bo_new_ring` <- `fd_submit_sp_new_ringbuffer` <- `build_prog_fb_rast` <- `fd6_draw_vbos` <- `tc_flush` <- `my_glFlush`. One line before it: `RedwoodGPU: a buffer of 4194304 bytes cannot be entered into the GPU's address space`. Chain [V source + log]: posters filled the 512 MiB pool (20:15:31: 14 MB free, 20:15:36: 0) -> `gemNew` falls to scattered pages -> a new L3 table is needed -> `table_alloc` -> `kbuf_alloc_low` takes 64 KiB from the same empty pool -> `mmu_map` false. Also the 17 lines of 8-9.7 MiB at 20:15:33-34 and Pride's `texture: OutOfMemory(Device)`.

Fixes: kernel 2895: all page tables at once (8256 KiB at first use, 2048 L3 + 4 L2 + L1); the last 64 MiB of the pool only for backboardd. Mesa `mesa-tree-patches/0001`: no NULL block in the heap; on no memory cached buffers go back and the call waits (20 ms x 10, commands x 100); a command buffer that stays impossible ends the process with one line. Recovery as before: launchd restarts backboardd in the same second ([V] 20:16:15), the kernel takes its buffers back ([V] pool 12 -> 381 MB), 2 fast exits = software renderer (bbd_wrap).

## Frame budget (boot 2026-11-01 22:08; patches 2913, 2914, eagl 0005, Mesa 0002, plug-in; built + host test, NOT BOOTED)

Owner: "20 fps on average, high touch lag; Astronomy lags when switching, purple in parts; widgets intermittent". Log: `logs/laurel-boot-2208.txt`. **No line below proves a frame rate: a host build cannot.** `[V]` = read in the log or the code. `[I]` = inference.

### The numbers that were wrong

| Line | Said | Truth | Fix |
|---|---|---|---|
| `SWEET FPS ... 40446 us in present + latch` | 40 ms a frame | [V arithmetic] 356 x 40.4 ms = 14.4 s of one thread's waits in a 10 s window. A pause over 500 ms reset `frames`, not the sums. The honest window: idle, 100 frames, 15458 us (fence 988 us, latch about 14 ms) | 2913: the sums restart with the window |
| `came 26063 us after the tick` | 26 ms | Same sum; ticks are 17.5 ms apart | 2913 |
| `core 16300 MHz while busy` | | [V] CP_0 counts every core clock, busy or idle: 300 MHz / 1.8 % busy = 16300. No such number exists from this counter | 2913: `clock N MHz over the window`; the level comes from `LAUREL GPU CLOCK` |
| `profile: 4612 us a frame in GL calls, 8046 outside` | CoreAnimation is the larger part | [V] glFlush was not counted: `frame_end` ends the frame before the call ends. Real: GL 10.5 ms, outside 2.15 ms | eagl 0005 |
| `contents: ... 'A008' ... 0 of 0 samples = BLANK` | 41 of 61 BLANK lines (A008 26, 420f 12, LA08 3) | [V] 1-byte surfaces are not sampled: nothing was known | eagl 0005 |
| `N frames in 10 s (F a second)` | "20 fps" | Mixes movement and pauses in one window | 2913: `moving: F frames/s for T ms of W` |

### Budget of one frame in a scroll, boot 22:08

21 of 28 redwood-gl windows had movement: 7003 frames, 32.9 a second, 19 % over 16.7 ms, 4 % over 33.3 ms [V].

| Stage | Before | Evidence | Change | Line that proves it |
|---|---|---|---|---|
| Finger to HID event | Read each 12 ms (10 ms sleep + 2 ms sleep in the read); 8.4 ms late on average | [I from code]; 400 kHz [V], 63 bytes = 1.4 ms | 2914: latch each 2 ms, read on an edge, 16 bytes for one finger: at most 2.4 ms | `LAUREL TOUCH RATE`, `touch to next flip` |
| HID to SpringBoard commit | SpringBoard 21.5 s a minute = 10 ms a frame at 35 a second | [V CPU TOP, I per frame]. Commit time: no line | None | [U] |
| Wait for the tick | 17.5 ms period, 57 a second, against 60 panel frames: the phase runs through the panel 3 times a second | [V] 300 ticks in 5.25 s, 315 INTF1 frames | 2913: tick = panel frame + 0.3 ms | `LAUREL FRAME: on`, `N ticks of 16.7xx us` |
| Render thread, CA | 2.15 ms | [V profile, corrected] | None | `redwood-gl: profile` |
| glFlush | 5.9 ms (5.3 in the moving windows) | [V] 43.7 s of 7400 frames. [V dSYM 20:16:15] draw emission runs here (`fd6_draw_vbos <- tc_flush <- my_glFlush`) | Mesa 0002: no tiles (host: -10 % of Mesa); worker threads interactive | `LAUREL GL FLUSH`, `RedwoodGPU: a submission` |
| glDrawElements | 1.53 ms, 68 draws | [V]. `image_of` went through up to 512 images per draw | eagl 0005: hash | `glDrawElements` in `profile` |
| glTexImage2D | 1.31 ms; about 10 ms a frame in a poster change | [V] +1.75 s between 22:12:39 and 22:12:51 | eagl 0005: A008, L008, LA08 of 32 KiB or more are textures of their own memory | `glTexImage2D` in `profile` |
| glBindTexture | 0.98 ms (20.7 us a bind) | [V]: scan + memory sums | eagl 0005: hash; 2913: a client's GPU write moves the seed, no sums for GPU conversions | `glBindTexture` in `profile` |
| GPU | 2.05 ms a submission, 2.9 submissions a frame, 22 % busy at 300/600 | [V]: not the limit, but it is latency in front of the latch | Mesa 0002: A610 GMEM is 132 KiB [V], so 36 tiles for the screen [I from code] | `the GPU worked N us` |
| Fence + latch | Latch: 100 us looks over up to one panel frame | [V code]. kernel_task 17.2 s a minute in use, 8.0 quiet | 2913: one sleep to the frame's start, priority 92 | `after SwapEnd: A us to the presenter, B fence, C latch`, kernel_task in `CPU TOP` |
| Scanout | 16.7 ms top to bottom | panel | None | |

Checked and not the limit [V]: buffers named (43 a submission, 21863 in 5 s) and cache upkeep (81 us a submission, 252 KB); the render thread's core (`frames ended on big cores 7357, little 43`); the GPU clock (`300 MHz 17 s, 600 MHz 42 s; busy 22 %`). Its priority is not known yet: `LAUREL GL THREAD` says it; nothing is raised before that line (a real-time thread can land on a Silver core under the Edge scheduler [I]).

Touch to light before: about 8.4 + commit + 8.8 (tick) + 13.1 + fence + 8 (latch) + 8.3 = 60 to 75 ms without a missed frame [I].

Host measure of Mesa alone: `scripts/laurel/mesa-host-bench.sh` (Mesa 25.0.7 on drm-shim, `FD_GPU_ID=610`, GMEM 132 KiB, no GPU, 8 programs, client arrays, 80 draws): 3 runs each, no threaded context: tiles 0.128-0.139 ms a frame, direct 0.117-0.123 ms. [V host] So direct rendering saves about 10 % of Mesa's CPU, not more. [I] The rule is for GPU time and DDR, which the host cannot show. On the phone a draw costs 25-87 us in glFlush against 1.6 us on the host: that factor is not explained yet ([I] A73 at 2 GHz, write-combined command buffers, cold caches, kernel calls). `LAUREL GL FLUSH` and `RedwoodGPU: a submission` split it at the next boot.

Expected render thread after these changes: about 9-10 ms from 13.1 [I, sum of the rows above, not measured]. Frames of 200 draws or more (22:15:34: 229 draws, 23 ms) stay over 16.7 ms on this CPU [I].

Not changed, and in the way of 60 frames: extension work on the same Gold cores (`CPU TOP`: WeatherWidget 44 s, CalendarWidgetEx 33 s, StocksWidget 21 s a minute at the worst); SpringBoard's own frame; the threaded context (kept: batches that overflow run in parallel; [V host] no clear gain or loss).

### Widgets

[V] `NMTL[100 chronod]: refused: render pipeline 'primitive_image' ... color0 fmt 542, depth fmt 260 ... Unsupported(Format at Color(0))`, also `primitive_gradient`; `FitnessWidget: draw skipped ... after a refused render pipeline`. **A widget that draws an image or a gradient loses those draws; a widget that draws text only is complete. That fits "intermittent" [I].**

[V RenderBox 20H392] `RB::Device` ctor 0x1e6919634 keeps the highest `supportsFamily:` Apple1..7 at +0x111. Family > 2 is its `hasYCbCrFormats` and `hasXR10Formats` (0x1e691bd78, 0x1e691bd9c, names in its description). With them an opaque layer gets 542, `_RB4` (0x1e68c94a8). Plug-in (`NegroniMetal.mm`): on a 610, RenderBox's own calls get NO from Apple3 on. Layers stay plain BGRA, the path layers with alpha take already [V owner's photo, metal.md 12]. `NEGRONIMETAL_RB_FAMILY=0` in NMTL_DIR/env is the kill switch. Risk [I]: RenderBox on family 2 uses other shader variants; a new refusal line says so.

Second cause, smaller [V]: 4 of the 24 `_RB4` surfaces were black at their first draw and full one frame later (surfaces 432, 916, 953, 1356: `fill 2, now drawn`): a flash of black. [I] The CPU conversion read the surface while the client's GPU could still write it; with no later frame the widget would stay as read. `_RB4` by the GPU runs in ring order after the client's work, and the seed brings the next pass.

`_RB4` by the GPU, for what still arrives as `_RB4`: 2913 request 0x7c + `kRedwoodAnyLayout`, Mesa bits 32-39 of the image, eagl `rb4_setup`: green plane R8, blue-red plane RG8, a shader writes the texture CoreAnimation reads. A pass is a batch of its own: only when the seed moved (2913: a submission of a client that names the surface moves its seed; `gpuclientseed=0` turns that off), and once in 64 bound frames. Fallback: the CPU path, as before.

Self-check: one read-back per element size: 64 texels by GPU and CPU must be equal, else `LAUREL GL PLANES: off: ...` and CPU copies.

### Astronomy

Switch lag, from the log [V]: `device ... in 197 ms`, `pipelines 6 compiled in 1052 ms, 0 from cache` (first use after a new root; `mediaserverd` at its second start: `1 from cache`, so the cache works), a `720 x 1560 A008` attached again every few frames, each a CPU copy (`surface 610`: textures 918, 1208, 1211, 1223, 1226, 1239 ... in 150 frames) and a new texture for each BGR10_XR surface, under pool pressure (`under 64 MiB free`, 81 of 512 MiB free). Fixed: the A008 copies; they also leave the pool. Not fixed: the first compile, one device per poster process.

Purple: **cause [U]**. Checked: the debug colour of the variable blur is off by default [V eagl: `vblur_on == 2`]; `AegirPoster` has no refused pipeline [V]; the XR formula equals m2v's [V]. New: the `contents` line gives `mean R G B` of what the surface holds. Mean with R and B high and G low on the poster's surface = Metal drew it (m2v, Turnip). Normal mean, purple on the panel = composition (next step `gltrace_place` on that place).

### The steady 10.0 frames a second

[V] 100 ms apart, while ticks are 17.5 ms apart (6 ticks = 105 ms), and on average 8.6 ms after a tick: not tick-driven in the kernel, no kernel timer feeds it. 16-17 draws, 2 submissions, no Metal client. It started at 22:16:14; at 22:14:58-22:15:22 the same phone drew 0.5 a second. [I] A client's fixed-rate animation (Wi-Fi scan cycles run in the same time: a spinner in Settings). New: `a frame changes X,Y WxH of the screen` in `LAUREL GL FLUSH` names the place.

### Lines at the next boot

```
LAUREL FRAME: on: the tick follows the panel: 16xxx us a frame, 1584 lines (kill switch sweetfb_lock=0); the presenter sleeps to the latch
LAUREL FRAME: 600 ticks of 16xxx us, worst N; moving: F frames/s for T ms of W; gaps <20 ms A, <36 B, <52 C, longer D
LAUREL FRAME: after SwapEnd, N flips: A us to the presenter, B us GPU fence, C us flush to latch, M past one panel frame; touch to next flip T us (K)
RedwoodGPU: 512 submissions in 5079 ms: ... GPU busy 20.6 %, clock 495 MHz over the window
RedwoodGPU: a submission: A us before the lock, B us with it; the window server: N requests, T us here in all
LAUREL GL THREAD: CoreAnimation draws on a thread of priority P, policy X, QoS Q, real time or not; Mesa's own threads are user-interactive
LAUREL GL PLANES: on: surfaces of 1 and 2 bytes a pixel and the planes of '_RB4' are textures of their own memory, 64 texels read back equal; other clients' GPU writes move the seed: yes
LAUREL GL FLUSH: N frames: A batches in tiles (B tiles), C straight into memory, D with no draw; E us a frame in the batch code; a frame changes X,Y WxH of the screen
LAUREL TOUCH: finger down: latch every 2 ms, read on an edge, one finger 16 bytes of 400 kHz I2C; register 0x88 reads N (stock driver never sets a rate)
LAUREL TOUCH RATE: finger M ms: E edges (R a second), K reads of U us; a report reaches iOS at most 2 ms + the read after its edge
NMTL[.. chronod]: RenderBox asks for GPU family Apple3: NO, from 3 on (...): opaque layers stay BGRA, no '_RB4'
```

Reading: `moving` near 60 and few `<36` gaps = smooth. `M past one panel frame` high = frames come after the latch. `R` tells the controller's real rate [U until then: the stock driver sets none; 0x88 is only read]. `LAUREL GL FLUSH` E + kernel `T` against `handing on`: the rest of glFlush is Mesa outside the batch code or waiting. No more `refused: render pipeline 'primitive_*' ... fmt 542`.

### Kill switches

`sweetfb_lock=0` (plain timer), `gpuclientseed=0`, `glenv=FD_MESA_DEBUG=gmem` (tiles), `NEGRONIMETAL_RB_FAMILY=0`. A planes failure turns itself off with one line. Touch: `sweettouchirq=0` as before.

## The 24 fps windows are the boot-UI spinner (boot 2026-11-03 00:49; patches 2917, post/9008; built, NOT BOOTED)

**Result.** `SWEET FPS: 239 frames in 10008 ms ... 239 late` is not a cap. It is the pace of one animation in backboardd.

| Label | Fact | Evidence |
|---|---|---|
| [V] | `-[BKDisplayRenderOverlaySpinny _startAnimating]`: `CAKeyframeAnimation` on `contents`, `kCAAnimationDiscrete`, duration 1.0 s, repeat 2^31. `_spinnyImageSequence`: `imageCount:24` | `/usr/libexec/backboardd`, code 0x100028404 and 0x100028018. The phone's file has the same two instructions at file offsets 164060 and 165016 (`od`) |
| [V] | `-[BKBootUIOverlayVendor currentOverlayWithLevel:]`: `isFirstBoot` gives the Apple logo; all else gives "Current bootUI is the spinny". `-[BKBootUIPresenter _queue_updateOverlayForReason:]` removes it when the screen owner finished startup | 0x10009fcbc, 0x1000a4308 |
| [V] | All 24 fps windows follow a backboardd restart: pid 395, 500, 1339. The first start of a boot (pid 66) has 7 to 16 frames/s and no such window | `logs/usblog-20261103-000638.txt` |
| [V] | Tick correct: 600 ticks of 16666 us; `SWEET INTF1: 300 frames in 5 s` each 5.0 s on the host clock; `hw.tbfrequency` 19200000. So no 19.2/24 MHz error in the tick | log, `ksysctl` |
| [V] | Gaps: `<36 120, <52 120, longer 0`, 240 flips (00:08:03). `frame-pace.py --test`: a 1/24 s timer on 1/60 s ticks gives exactly this. A fixed cost per frame gives one gap size, so no load gives a 2 + 3 mix | `scripts/laurel/frame-pace.py` |
| [V] | Same number with no Metal device and CPUs 96 % busy, and on Metal with CPUs 26 % busy. CA can go faster: 00:49:08 has 15 gaps under 20 ms | log |
| [V] | Screen black in the window: `0 of 64 samples lit` at 5 s, the next screen line at 140 s; 400 KB out of the cache in each 5 s line. Lit UI after: backboardd 0.0 to 0.2 % CPU, 3317 to 3386 command buffers in 30 s | log, `ps` |
| [I] | The spinner is what ran in these windows. No log line names it: the os_log lines did not reach the USB log | To prove at the next restart: `oslogstream` lines `Current bootUI is the spinny`, `updateOverlay: Dismissing overlay` |
| [U] | Why the screen owner took 135 s in boot 12 and about 25 s in the restart of 00:07:42. The spinner ended near 00:51:21, with `display off` and the owner's key presses in the same seconds | |

**Meaning of the line.** `late` is every gap over 20 ms, so a 24 Hz animation is 100 % late with no missed deadline: `0 past one panel frame` in the same window. `came N us after the tick` is tick to SwapEnd. A window ends with a line only after 10 s with no pause over 500 ms, so the real UI, with pauses, printed nothing. Boot 12 has no line after 00:51:12, with Preferences open: the GPU line has 12 to 56 submissions per 5 s there. **Before 2917 no 23F84 log has a frame rate of real use.**

**2917** (both kernels): at a pause over 500 ms, a motion of 10 frames or more prints `LAUREL FRAME: motion ended: N frames in M ms` and the two LAUREL FRAME lines.

**Second defect, real, not the 24: post/9008** (12377 only). [V] `IOMobileFramebufferVsyncNotifyFunc` gives the three numbers of the message to `IOMFBServer::vsync_callback(fb, a1, a2, a3, refcon)`. a1 goes only to kdebug. a2 is this refresh, `add x22, x20, x21` makes a2 + a3 the next one. That time is the one `render_for_time` gets and the one compared with the next update; a3 is also `videoRefreshPeriod`. Our order was (refresh, refresh, **counter**). At 19.2 MHz the "period" is 3.1 us per tick: 3.75 ms after 20 min, right only after 89 min, 135 ms after 12 h. Now (counter, refresh, period), kill switch `sweetfb_period=0`. This answers K8 of `ios26-metal.md`. IOS-26-Hot 0121: 15.8 to 21 fps on a Home swipe for the same slot [their log, not verified]. [V model] A due time inside a tick renders one tick later with the old value (`frame-pace.py`). [I] Expected: the spinner stays at 24; UI motion loses up to one tick of delay. With 16 ms of GPU a frame (the GPU line in these windows) + 6 ms flush to latch, a full-screen redraw has 2 ticks: about 30 fps until the GPU cost falls. iOS 16 stays as it was: its QuartzCore was not read here [U].

Tools: `scripts/ios26/objc-methods.py BINARY [CLASS]`, `scripts/ios26/objc-stub-sel.py BINARY VADDR...`, `scripts/laurel/dsc-image.py CACHE fn QuartzCore __ZN2CA12WindowServer11IOMFBServer14vsync_callbackEP21__IOMobileFramebufferyyyPv`.

## Black layers (boot 2026-11-01 23:28; patches 2916, eagl 0006, Mesa 0003; built + host test, NOT BOOTED)

Owner: "Maps shows a map, but all in black. Widgets are failing to render again." Kernel 4ec4584, root 21:57 (3fba60e). Logs: `logs/laurel-boot-maps.txt` (ends 23:31:36), `logs/phone/metal.log` (pulled 23:31), good boot `logs/laurel-boot-2208.txt`. **No line below proves a map on the screen: a host build cannot.** [V] log, source or binary. [I] inference. [U] unknown.

### First fact: Maps is in no log

[V] No `exec Maps`, no `NMTL[n Maps]` in the USB log up to 23:31:36 or in metal.log. The stream stops at 23:31:36, the interface goes at 23:41:42: the Maps test is in those 10 minutes. The maps that are in the log: FindMy (pid 293, 23:30:21) and the location prompt (pid 294, 23:30:24), both MapKit.

### Cause that is proven: the wired guard refuses surfaces

[V] `LAUREL WIRED: refused`: 1800 MiB wired of 1795 at 23:31:25, 1827 at 23:31:28, 51-54 MiB free. 246 lines `create ... -> 0xe00002bd`: 7 of size 0x0 (PosterBoard, as in earlier boots), 239 of a real size: PosterBoard 172, Pride 31, Aegir 20, Collections 12, **chronod 4 (271x109, 23:31:32-36)**. They go on to the last line of the log. Boot 22:08: 0. Same guard, same limit; near the limit there too (1619 MiB at 22:15:34), and no refusal. Gallery open in this boot: AegirPoster 23:30:57 and 23:31:19, PridePoster, CollectionsPoster.

- Widgets: **a refused chronod surface is a widget that does not render.** [V] 4 lines. [I] that is what the owner saw: the log ends 4 s later.
- Maps: [V QuartzCore 20H392] `get_unused_drawable` 0x188385c80 `create_iosurface_with_pixel_format`, `cbz x0` at 0x188385c84: no surface, no drawable. `nextDrawable` then waits and answers nil. The Metal layer is black while the rest of the app draws. [I] Maps ran under this: it started after 23:31:36, the refusals were running then, nothing in the log says the wired pages came back.
- [U] who holds 1800 MiB. Surfaces and scattered GPU buffers count, and kernel memory of about 300 tasks. New line `LAUREL WIRED: who:` says it.

### The path, hop by hop

| Hop | Evidence | Verdict |
|---|---|---|
| Metal client to Turnip | [V] FindMy and the prompt: device open, first command buffer completed, `0 failed`, no `refused`, no `draw skipped`. `pipelines 5`, `6`. No `primitive_*` line in this boot's USB log | no break seen |
| A map can draw in this boot | [V] surfaces 574, 573 (540x360) at 23:30:27, 3 s after the prompt's device: 4824 of 4824 lit, 4501 unlike. [I] that is the prompt's map: 270x180 points at 2x; no line links the surface to the process | fits: VectorKit draws when it gets surfaces |
| Into the surface: import | [V] BGRA with rows of 64 by ID (0x7e); others by USERPTR (0x49), `errno 78` = refused layout, 3 lines, not a failure | as designed |
| Cache: GPU write against CPU lines | [V source] the kernel zeroes a surface through a cached map, so dirty lines can exist. They go: 0x49 at import, 0x7e at the first submission (`pushed` 0), flame `flushSurfaces` (`dc civac`) at commit and at completion. Nothing dirties them after that. So no write-back over GPU pixels | no break by source. Run time: `LAUREL BLANK` |
| Seed | [V flame `-finish`] every client but backboardd: write lock + unlock of each written surface **before** `present`. So a Metal client's write moves the seed, by ID or USERPTR. [V 2915] the kernel also moves it at submission, by ID only. 0x7d: eagl only. **Correction: "a Metal client's GPU writes move no seed" (above, GPU or CPU) is wrong while the seed bump is on** | no break |
| Present | [V flame] `present` runs in `-finish`, after the GPU's completion. So a drawable is not shown before it is drawn | no break |
| backboardd's texture: old eagl, new kernel | [V] `_RB4` 14 lines lit, 0 black; `converted by the GPU` lit (1080, 1135); 0x7c and 0x7b are new requests, the others did not change. The lag agent's statement holds | no break |
| `contents` itself | [V eagl 0004, on the phone] `sys_dcache_flush` before the sample: not a stale CPU view. **42 of the 62 BLANK lines are `0 of 0`: A008 36, 420f 6: not looked at** (eagl 0005 fixes the text). 20 lines remain: 19 BGRA surfaces, 9 lit later. For 10 no later line: the follow-up needs the surface bound in every 128th frame, so they prove nothing | the line is weak: 0006 |
| Format, MSAA, memoryless | [V] BGRA8 and sRGB are plain; `resolveTexture` and store actions reach m2v; memoryless = transient attachment. [U] run with VectorKit on the A610 | no evidence either way |
| RenderBox family answer | [V] not on the phone: the root is older. Not the cause | excluded |
| GPU pool | [V] 26-135 MiB free; no `cannot be entered`, no `OutOfMemory`, 0 frees refused. Under the floor buffers go to scattered pages: they work, and they count as wired. **[I] that is the link: pool full -> scattered -> wired -> surfaces refused.** Kept buffers (81 MB in one client's line, up to 160 MiB a client, 60 s) lie in the pool meanwhile | no silent failure; fuel for the guard |

### Changes

Kernel **2916** `laurel-wired-screen-first`:
1. Before a refusal, and before a buffer goes to scattered pages: the kept buffers of all clients but backboardd go back (at most twice a second). `LAUREL GPU KEPT: gave back N MiB ...`. Costs only time.
2. Two limits. 55 % as before. 70 % (2284 MiB) for the app on the screen (role foreground or jetsam band >= foreground) and chronod. A name with `Poster` stays at 55 %: posters ask again and again and hold the most. Kill switch `laurelwiredshown=0`. [I] 70 % leaves 979 MiB for pageable memory; negroni's freeze has no measured floor.
3. `LAUREL WIRED: who:` at most every 10 s while over the limit.
4. Request 0x7b: who created a surface.
5. A seed move from a client's GPU write is no CPU write: `gpuMoves` leaves it out of the push rule. [V] 2019 KB out of the cache a submission on average, 34089 at the worst, against 534 and 7719 in boot 22:08. [I] the share of this cause; the two boots did different work.

eagl **0006**, Mesa **0003**: `LAUREL BLANK`, at most one line in 5 s, for surfaces black at a first draw and not lit 2 s later: process, format, size, id, memory sample, 64 texels read **through the GPU**.

Not changed: the guard's 55 % for others; kernel memory; any Metal path (no evidence of a fault).

Build [V, cea447a]: kernel-linux.sh 308/308 patches, 0 failed, 0 LSE, printf-arg-check OK, kernel sha256 37beb26901de0f20..., series 0ce006e70a229e13; armv80-check on the kernel: 21 (SVE words in data, the same count as earlier kernels), 0 LSE. gpu-userland.sh + Mesa: libtopaz-gl b1cd72f0449f97ed, libOSMesa 29b469806232969a, exports `redwood_drm_surface_who`, armv80-check 0 on both. Host: gpu-surface-test.sh PASS (with the LAUREL BLANK list). metal-build.sh not run: no Metal source changed. Not run: root build, any boot.

### Lines at the next boot

```
LAUREL WIRED: on: buffer surfaces refused above 1795 MiB wired = 55% of max_mem 3264 MiB (the 2100 window), above 2284 MiB for the app on the screen and chronod; ...
LAUREL WIRED: who: W MiB wired: surfaces S MiB (PosterBoard A MiB in N, AegirPoster ...); C GPU clients: buffers B MiB (with surfaces they name), of which their own pages H MiB; kept K MiB
LAUREL GPU KEPT: gave back N MiB of kept buffers of M clients: memory is short (call T)
LAUREL WIRED: above the limit for what is on the screen: surface of 4688 KiB for Maps (role R, band B): ...
LAUREL WIRED: refused surface of 4688 KiB for PosterBoard (role R, band B): ...
LAUREL WIRED: REFUSED, A LAYER STAYS BLACK: surface of 4688 KiB for Maps (role R, band B): ...
|backboardd| LAUREL BLANK: N surfaces stay black: Maps 'BGRA' 720x1560 id I: memory L of 4225, GPU G of 64; ...; since the last line X black at a first draw, Y filled, on average in Z ms
```

Reading, for Maps:

| Lines | Meaning | Next step |
|---|---|---|
| `REFUSED, A LAYER STAYS BLACK ... Maps` | still short at 70 %: the `who:` line names the holder | reduce that holder |
| `refused ... Maps (role R, band B)`, no `above the limit` | role and band do not mark Maps as on the screen | use what R and B say |
| `LAUREL BLANK: Maps ...: memory 0, GPU 0`, no refusal | Maps got its surface and drew black or nothing: the Metal path | VectorKit: pipelines, MSAA, textures |
| `memory 0, GPU lit` | a stale CPU view; the screen should be right | the sampler |
| `memory lit, GPU 0` | import or texture in backboardd | eagl |
| no line, black on the panel | CoreAnimation draws it another way | `gltrace_place` |

### USB log stream

[V source] The live log is a kernel UDP socket through the normal stack (`ud_log_thread`, `sock_send`). A failed send has no line, it tries again in 100 ms. [V] It stopped right after `exec usbnetcfg` at 23:10:29 and 23:31:36; the jobs at boot (`up`) did not stop it. `down` removes the ue0 keys from configd's state. [I] configd then takes the route or the address of ue0, so every send fails. Not fixed here (root and net: other agents). Do not run `usbnetcfg down` while the log is needed.

## Recovery (no UI after the GPU root)

1. Boot with `gl=0` (backboardd without the loader, software renderer) or `gpu=0` (no GPU at all, no loader), or
   `gpu_smmu=0` (GPU on, stage-1 tables off: 2150's pass-through and backboardd-only rule), or `gpuseed=0` (2158: the old
   cache push rule; for pictures that look stale). Add the
   boot-arg to the UniXNU/DarwinBoot command line (`scripts/laurel/uefi-image.sh` boot-args) and `fastboot boot` the image.
2. The wrapper turns the loader off by itself after 2 backboardd starts within 30 s of each other in one boot
   (`/var/tmp/laurel-bbd.state`, line `LAUREL BBD: off: backboardd exited N times ...`), and when `kern.laurel_gpu`
   says `off: ...` (2155: gpu=0, failed bring-up, GPU watchdog).
3. If the wrapper itself fails to exec the real binary, it tries `/usr/libexec/backboardd.real`, then waits 10 s (launchd
   does not spin). root-add-gpu.sh refuses to install a wrapper that is not a signed thin arm64 executable naming
   `/usr/libexec/real/backboardd`; Apple's backboardd then stays in place.
4. Last resort, on the host with the root image (or userdata from fastbootd): mount it and
   `mv usr/libexec/real/backboardd usr/libexec/backboardd`; optional `rm -rf topaz usr/share/firmware/laurel`.

## Risks [I]

- CX rail / bus bandwidth: 2892 votes MX + CX NOM for the boot and DDR by the rule in "GPU clock by demand"; with `gpudcvs=0` no RPM votes (as topaz).
- Pool region 0xC0000000-0xE0000000: reserved in Mu 0101 ("Pool RAM") and the ADT (area A); not measured on the phone.
- SMMU pass-through: see "SMMU pass-through risk"; only backboardd may use the GPU. With 2154 on (default) this is the
  fallback only; the remaining risk is one shared GPU address space for all clients (no per-process tables).
- Area J (Metal) uses `RedwoodGPU`, `redwood_gpu_ready`, `redwood_gpu_parameter`, `topaz_root_mounted` and the 0138
  block: kept unchanged by 2150-2152. Its clients other than backboardd are refused while the SMMU passes through.
- `eagl_slots.txt` offsets are hackios-scion's (iOS 16.5 OpenGLES dispatch table) used with the 16.7.16 root, as topaz
  does; `topaz_inject.c` checks each cache address before it patches (it leaves a slot alone when it does not match).
- Silver cores: GPU work runs on any core; nothing GPU-specific in the user space needs more than ARMv8.0.

## Later: Metal (Turnip + metal2vulkan)

- ios-redfin (Pixel 5, Adreno 620, a6xx gen1) runs Metal on Mesa Turnip through metal2vulkan: backboardd, SpringBoard
  and apps render on the GPU (its README; `METAL-NEXT.md`: Metal frontend (ObjC) -> metal2vulkan runtime (Rust,
  AIR -> SPIR-V) -> Turnip built for iOS with a "darwin" kernel backend -> kernel user client).
- negroni (this repo, Adreno 730): `userland/turnip` (Turnip-on-Darwin patch), `userland/metal` + `docs/metal-design.md`,
  `scripts/gpu/turnip-build.sh`.
- Adreno 610 in Mesa 25.0.7 [V source]: `GPUId(610)` in the a6xx gen1 "low" group (`freedreno_devices.py`: 1 CCU,
  no HW multiview, no sampler min/max, no GMEM fast clear); Turnip takes the bank bit from `MSM_PARAM_HIGHEST_BANK_BIT`
  (our 14), freedreno GL uses the static table (13) only for CPU tiled copies.
- Steps for the Mi A3: (1) GL path above on the phone first; (2) Turnip for iOS with the RedwoodGPU ioctls (the same
  msm DRM ABI that redwood-drm already maps; needs per-process GPU VA or the identity map kept); (3) metal2vulkan
  bundle as in ios-redfin/negroni; (4) CX (and MX for PLL rates) vote through RPM before clocks above 300 MHz. [I] A610 is a low-end gen1
  part: Vulkan 1.1 class, enough for CoreAnimation; heavy apps will be slow.
