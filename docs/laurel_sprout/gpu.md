# Mi A3 (laurel_sprout) GPU: Adreno 610 behind CoreAnimation's OpenGL ES renderer

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
| GPU clock used | **300 MHz** (GPLL0 / 2, as topaz) | 300 | — |

The core clock is fixed at 300 MHz from GPLL0. gfx3d votes the **CX** rail (gpucc-trinket.c: vdd_cx levels); nothing here votes
it, and 300 MHz is below the lowest level's 320 MHz limit; the PLLs (VCO above 1 GHz) also need MX nominal. topaz's
`gpu_mhz` knob is removed (a tuning boot-arg is against the boot-arg rule). For the later CX/MX vote (RPM), the PLL
values (checked by the review against `clk-alpha-pll.c`): f(PLL) = 19.2 MHz x (L + alpha / 2^40), gfx3d = AUX2 / 2
(RCG source 2 = PLL0, 4 = PLL1, divider value 3), CONFIG_CTL 0x4001055b, USER_CTL AUX2 = bit 2, ALPHA_EN bit 24, VCO bits
20-21 (0 = 1-2 GHz, 2 = 0.5-1 GHz), TEST_CTL_U (+0x20) bit 0 = 0; enable: BYPASSNL, 5 us, RESET_N, LOCK (bit 31), OUTCTRL.

| gfx3d MHz | PLL | L | ALPHA_U | ALPHA | VCO |
| --- | --- | --- | --- | --- | --- |
| 320 | 1 (+0x100) | 33 | 0x55 | 0x55555555 | 2 |
| 465 | 1 | 48 | 0x70 | 0 | 2 |
| 600 | GPLL0 / 1 | — | — | — | — |
| 745 | 0 (+0x0) | 77 | 0x9a | 0xaaaaaaaa | 0 |
| 820 | 0 | 85 | 0x6a | 0xaaaaaaaa | 0 |
| 900 | 0 | 93 | 0xc0 | 0 | 0 |
| 950 | 0 | 98 | 0xf5 | 0x55555555 | 0 |

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

## Recovery (no UI after the GPU root)

1. Boot with `gl=0` (backboardd without the loader, software renderer) or `gpu=0` (no GPU at all, no loader), or
   `gpu_smmu=0` (GPU on, stage-1 tables off: 2150's pass-through and backboardd-only rule). Add the
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

- CX rail / bus bandwidth: no RPM votes (as topaz). 300 MHz is inside the lowest CX level; BIMC bandwidth not voted.
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
