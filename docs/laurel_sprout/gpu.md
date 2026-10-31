# Mi A3 (laurel_sprout) GPU: Adreno 610 behind CoreAnimation's OpenGL ES renderer

Status 2026-11-01 05:00: built on Linux (kernel, Mesa, userland, firmware extract). **NOT BOOTED.**
Labels: [V] read in source or measured on the host, [I] inference, [U] unknown.

## What runs where

Same design as ios-topaz (Redmi Note 12 4G, SM6225 "khaje", the same Adreno 610), which draws its lock screen,
home screen and Settings on the GPU this way (topaz README "Roadmap" 3). Kernel side: topaz patches 0901-0947
(TopazAdreno.cpp = TopazGpuW recipe, RedwoodGPU.cpp = msm DRM user client from darwin-redwood/HackiOS, GPU pool,
SMMU pass-through) are already in our kernel (kernel-linux.sh applies every topaz patch); laurel 2150-2152 port them
to SM6125 "trinket".

```
backboardd (CoreAnimation render server, EAGLServer)
  /usr/libexec/backboardd = bbd_wrap: DYLD_INSERT_LIBRARIES=/topaz/lib/libtopaz-inject.dylib, exec /usr/libexec/real/backboardd
  libtopaz-inject: waits up to 5 s for the RedwoodGPU service, then dlopen /topaz/lib/libtopaz-gl.dylib
  libtopaz-gl (eagl.c + gl_osmesa.c): EAGLContext's OpenGL ES = Mesa OSMesa (ES profile) on freedreno
  libOSMesa.8.dylib (Mesa 25.0.7 freedreno + softpipe; src/redwood-drm = libdrm stand-in -> IOKit "RedwoodGPU")
kernel
  RedwoodGPU user client (msm DRM ioctls as IOConnect calls) -> TopazAdreno (power, zap, SMMU, CP ring, fences)
  SweetSurface: backboardd's screen surfaces from the write-combined GPU pool (contiguous, < 4 GiB); MDP scans them
```

## Trinket values (2150) [V source: external/laurel-kernel-los]

| Item | Mi A3 (trinket) | topaz (khaje) | Source |
| --- | --- | --- | --- |
| GPU / GPUCC / GPU SMMU | 0x5900000 / 0x5990000 / 0x59a0000 (qsmmu-v500, SID 0 mask 1 = gfx3d_user, SID 2 secure) | same | trinket-gpu.dtsi, msm-arm-smmu-trinket.dtsi |
| kgsl chip id | **0x06010000** | 0x06010001 | trinket-gpu.dtsi `qcom,chipid` |
| highest bank bit | **14** (RB/TPL1/SP_NC_MODE_CNTL 0xb, UCHE_MODE_CNTL bit 21) | 13 (0x9) | trinket-gpu.dtsi, adreno_a6xx.c a6xx_start |
| Zap shader | `a610_zap`, PAS 13, carve-out **0x57515000** (0x2000) | 0x55B15000 | trinket-gpu.dtsi, trinket.dtsi |
| GX GDSC | 0x100c, **no** sw-reset 0x1008 / domain clamp 0x1508 (no GMU) | with both | trinket-gdsc.dtsi |
| CX GDSC | 0x106c, status 0x1540 | same | trinket-gdsc.dtsi |
| gfx3d RCG | 0x101c; src 2 = PLL0_OUT_AUX2, 4 = PLL1_OUT_AUX2, 5 = GPLL0 | src 1 = Zonda PLL0 | gpucc-trinket.c |
| GPU PLLs | 2x "default" alpha PLL (PLL0 +0x0, PLL1 +0x100), 40-bit alpha, CONFIG_CTL 0x4001055b, AUX2 out = gfx3d x2 | 1 Zonda PLL | gpucc-trinket.c, clk-alpha-pll.c |
| OPPs | 320 (PLL1 640) 465 (PLL1 930) 600 745 820 900 950 MHz (PLL0 1200-1900) | 320-1260 | trinket-gpu.dtsi pwrlevels |
| GCC branches | bimc_gpu_axi 0x71154, memnoc_gfx 0x3600c, snoc_dvm_gfx 0x36018, cfg_ahb 0x36004, sys_noc_compute_sf_axi 0x1050c, GPLL0 to GPU 0x79004 bit 15 | same offsets (no cfg_ahb/sf_axi) | gcc-trinket.c, kgsl clocks |
| GPU clock used | **300 MHz** (GPLL0 / 2, as topaz; no GX corner vote) | 300 | — |

Default core clock stays 300 MHz from GPLL0: the GX rail corner is not voted through RPM (TopazRpm has no GX vote yet),
so a PLL rate can hang the GPU [I]. `gpu_mhz=N` (topaz's existing knob) selects a stock OPP through the trinket PLL code.

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
  "fits one page" test would refuse it); GPU pool placed at run time: `[align64M(max(kernel end, 0xC0000000)), 0xE0000000)`,
  at most 1 GB (TopazModem's own pool starts at 0xE0000000), else kernel memory below 4 GiB (`gpu_midmem`); self-check
  = one CP fence write (CP -> UCHE -> SMMU -> DDR) after ME_INIT; one line `LAUREL GPU: on|off: ...`.
- **2151** `laurel-gpu-surfaces`: SweetSurface asks the GPU state instead of boot-arg `gpu=1`: no cached scanout slots
  while the GPU is wanted; contiguous below-4-GiB surfaces while wanted; backboardd's screen-sized surfaces (now from
  700x1500, the Mi A3 is 720x1560) from the GPU pool once RedwoodGPU is up (asked per create, not cached).
- **2152** `laurel-fps-line`: `SWEET FPS:` on by default (6 lines every second, then one every 10 s while frames come;
  `sweetfps=0` off, `sweetfps=1` every second).

With the current ADT (`--dram 0x81000000:0x30000000`, kernel end 0xB1000000) the pool is 0xC0000000 + 0x20000000 (512 MB).
[I] Mu maps 0xC0000000-0x1C0000000 as RAM; DarwinBoot places kernel + ADT in its window at 0x81004000; UEFI runtime
regions are expected in the initial DXE heap, not at 0xC0000000. If area A moves the kernel RAM over 0xC0000000-0xE0000000,
2150 switches to `gpu_midmem` by itself (line `TopazGPU: kernel RAM ..., GPU memory from the kernel (midmem)`).

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
at a pinned commit). Mesa: host meson + ninja + bison/flex, Mako/PyYAML in `out/laurel/gpu/deps/venv`.
Fix found [V]: clang warns "argument unused: --ld-path" on compile-only lines and meson's checks use
`-Werror=unused-command-line-argument`, so every feature check failed (`struct timespec: NO` -> `redefinition of 'timespec'`);
the wrapper `out/laurel/gpu/bin/ios-clang` passes `--ld-path` only on link lines.

Measured 2026-11-01 (20 cores) [V]: Mesa configure + build 47 s, 17 102 608 bytes, 1296 gl* functions, links only
libSystem, libc++, libz, IOKit; userland 3 binaries in a few s (mkeagl.py: 409 entries, 356 passed on, 30 by hand,
23 without a function); 0 LSE/RCpc instructions in every Mach-O (gpu_check_v80).

### Versions

| Part | Pin |
| --- | --- |
| Mesa | 25.0.7, sha256 592272df...f8a6 (= topaz mk-mesa-mac.sh, hackios-scion mk-mesa.sh) |
| Mesa patches, redwood-drm, eagl/gl_osmesa/topaz_inject/bbd_wrap | external/ios-topaz (get-references.sh pin) |
| mkeagl.py + eagl_slots.txt | external/hackios-scion (get-references.sh pin) |
| iPhoneOS16.5.sdk | github.com/theos/sdks 0222fd5413cf4b9af096f37b4621afa2688572f7 |
| ld64 / ldid | theos 6e7b8c4 + L1ghtmann iOSToolchain test-210562a (kernel-linux.sh) |

## Log lines to check (first boot)

1. `TopazGPU: kernel RAM 0x81000000+0x30000000, GPU pool 0xc0000000+0x20000000`
2. `TopazGPU: powered: RBBM_STATUS ...`, `TopazGPU: zap: metadata at 0xc...`, `zap: init_image and mem_setup ok`,
   `TopazGPU: zap auth_and_reset: 0/0`
3. `TopazGPU: SMMU TTBR0 ... (identity)`, `TopazGPU: cp: SQE 32304 bytes (own, version 01001f0b)`, `CP up (ME_INIT, SET_SECURE_MODE 0), core 300 MHz`,
   `TopazGPU: fence test ok in N us`
4. **`LAUREL GPU: on: Adreno 610 chip 0x06010000, core 300 MHz, zap PAS 13 at 0x57515000 (own a610_zap, 6860+2096 bytes), SQE own 01001f0b, SMMU pass-through, pool 0xc0000000+0x20000000; RedwoodGPU published`**
   or `LAUREL GPU: off: <step> failed: <reason>` (steps: MMIO map, power (GDSC/clocks), zap shader, SMMU, CP start).
5. backboardd: `topaz: /topaz/lib/libtopaz-gl.dylib loaded` (syslog), `RedwoodGPU:` client lines, `SWEET SURF: backboardd ...` from the pool.
6. `SWEET FPS: N frames in 10xxx ms, ...` every 10 s while frames come.

If the zap step fails with `TrustZone refused the zap shader: init_image ...`: the mdt is not this phone's (check
`SHA256SUMS` against the vendor image) or the PAS id differs; `mem_setup`: the carve-out address is wrong (read the
live FDT `gpu_zap` region).

## Risks [I]

- GX rail / bus bandwidth: no RPM votes (as topaz). 300 MHz on the bootloader's corner; BIMC bandwidth not voted.
- Pool region 0xC0000000-0xE0000000 is assumed free (not given to XNU, not used by Mu runtime). A collision shows as
  corruption, not as a clean failure.
- 2151 changes surface placement for every process while the GPU is wanted (contiguous memory first); area A's
  surface-pool work touches the same SweetSurface code: merge order matters (2151 must apply after it).
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
  bundle as in ios-redfin/negroni; (4) GX corner vote (RPM) before clocks above 300 MHz. [I] A610 is a low-end gen1
  part: Vulkan 1.1 class, enough for CoreAnimation; heavy apps will be slow.
