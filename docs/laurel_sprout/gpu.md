# Mi A3 (laurel_sprout) GPU: Adreno 610 behind CoreAnimation's OpenGL ES renderer

Status 2026-11-01 05:10: review fixes on top of laurel-int-1 (areas A, C, H); built on Linux (kernel, Mesa, userland,
firmware extract, UEFI image). **NOT BOOTED.**
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

Toolchain: host clang (23 on CachyOS) `-target arm64-apple-ios16.0 -mcpu=cortex-a53` + the theos cctools `ld64`/`ldid`
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

## Log lines to check (first boot)

1. `TopazGPU: kernel RAM 0xe1004000+0xcc000000, GPU pool 0xc0000000+0x20000000 (ADT laurel-ram-reserved)`
2. `TopazGPU: powered: RBBM_STATUS ...`, `TopazGPU: zap: metadata at 0xc...`, `zap: init_image and mem_setup ok`,
   `TopazGPU: zap auth_and_reset: 0/0`
3. `TopazGPU: SMMU TTBR0 ... (identity)`, `TopazGPU: cp: SQE 32304 bytes (own, version 01001f0b)`, `CP up (ME_INIT, SET_SECURE_MODE 0), core 300 MHz`,
   `TopazGPU: fence test ok in N us`
4. **`LAUREL GPU: on: Adreno 610 chip 0x06010000, core 300 MHz, zap PAS 13 at 0x57515000 (own a610_zap, 6860+2096 bytes), SQE own 01001f0b, SMMU pass-through, pool 0xc0000000+0x20000000; RedwoodGPU published`**
   or `LAUREL GPU: off: <step> failed: <reason>` (steps: MMIO map, power (GDSC/clocks), zap shader, SMMU, CP start).
5. `/var/tmp/laurel-bbd.log` and syslog: `LAUREL BBD: on: /topaz/lib/libtopaz-inject.dylib inserted` (or `off: <reason>`),
   then `topaz: /topaz/lib/libtopaz-gl.dylib loaded`, kernel `RedwoodGPU: client backboardd (open 1)` and
   **`LAUREL GPU: GL: backboardd opened the GPU: its screen surfaces from the GPU pool, direct scanout off`**.
6. `SWEET SURF: backboardd create ... 720x1560` from the pool; `SWEET FPS: N frames in 10xxx ms, ...` every 10 s.

If the zap step fails with `TrustZone refused the zap shader: init_image ...`: the mdt is not this phone's (check
`SHA256SUMS` against the vendor image) or the PAS id differs; `mem_setup`: the carve-out address is wrong (read the
live FDT `gpu_zap` region).

## Recovery (no UI after the GPU root)

1. Boot with `gl=0` (backboardd without the loader, software renderer) or `gpu=0` (no GPU at all, no loader). Add the
   boot-arg to the UniXNU/DarwinBoot command line (`scripts/laurel/uefi-image.sh` boot-args) and `fastboot boot` the image.
2. The wrapper turns the loader off by itself after 2 backboardd starts within 30 s of each other in one boot
   (`/var/tmp/laurel-bbd.state`, line `LAUREL BBD: off: backboardd exited N times ...`).
3. If the wrapper itself fails to exec the real binary, it tries `/usr/libexec/backboardd.real`, then waits 10 s (launchd
   does not spin). root-add-gpu.sh refuses to install a wrapper that is not a signed thin arm64 executable naming
   `/usr/libexec/real/backboardd`; Apple's backboardd then stays in place.
4. Last resort, on the host with the root image (or userdata from fastbootd): mount it and
   `mv usr/libexec/real/backboardd usr/libexec/backboardd`; optional `rm -rf topaz usr/share/firmware/laurel`.

## Risks [I]

- CX rail / bus bandwidth: no RPM votes (as topaz). 300 MHz is inside the lowest CX level; BIMC bandwidth not voted.
- Pool region 0xC0000000-0xE0000000: reserved in Mu 0101 ("Pool RAM") and the ADT (area A); not measured on the phone.
- SMMU pass-through: see "SMMU pass-through risk"; only backboardd may use the GPU.
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
