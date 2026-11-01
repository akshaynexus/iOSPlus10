# Metal on the Mi A3 (Adreno 610): decision, interfaces, Linux build

Status 2026-11-01 (AREA J); 08:30: Metal client gate; 16:30: gate fixed, Metal for all of iOS (sections 6.1-6.5, 10). Labels: [V] seen in source, a binary or a log; [I] inference; [U] unknown.
Built on Linux (CachyOS, 20 cores) [V]. **Turnip has not run on the phone yet** (no m2vtest in any boot): the coordinator tests (section 8).

## 1. Decision: metal2vulkan + Turnip (negroni's NegroniMetal stack), unchanged

| Path | What it is | Fit for the A610 | Verdict |
|---|---|---|---|
| (a) metal2vulkan + Mesa Turnip (negroni `userland/metal` + `userland/turnip`, ios-flame frontend + bridge) | Metal.framework loads a plug-in bundle; its `_MTLDevice` subclass forwards to metal2vulkan (Rust: AIR -> SPIR-V, Metal objects on Vulkan 1.2); Turnip runs the Vulkan on the Adreno | Mesa 25.0.7 has the A610 (`GPUId(610)`, chip id `0x060100ff`, matches B's `0x06010000` and topaz's `0x06010001`) with an A6xx gen1 "low" property set [V `metal-a610.py`]. The Turnip msm KMD talks to the topaz RedwoodGPU user client through negroni's libdrm stand-in with **no new kernel ABI** (section 4) [V source] | **chosen** |
| (a') same, UniXNU `tu_knl_darwin` KMD (ios-redfin A620, ios-flame A640, UniXNU A740) | Turnip with a Darwin backend over a `NativeAdreno`/`SweetAccelerator v2` user client | Needs that kernel ABI; topaz has the msm one | rejected (second GPU ABI in the kernel) |
| (b) HackiOS-scion `tools/gfxstream` | gfxstream GLES/Vulkan **encoder** that sends the calls through `/dev/vgpu3d` to a host GPU (Pixel 10 PowerVR under AVF/crosvm) [V `tools/gfxstream/STATUS.md`, `VULKAN.md`] | No host: the Mi A3 runs XNU on the metal | does not apply |
| (b') HackiOS `tools/mk-mesa.sh` `AIR=1` (`libhakiosair`, AIR -> NIR -> ir3 on gallium freedreno) | Shader front end only; HackiOS itself says "a shader compiler, no Metal" (docs/gpu-comparison-2026-10-27.md) | No Metal runtime for CoreAnimation | rejected (fallback shader path only) |
| (b'') HackiOS `tools/metal/mk-metal2vulkan.sh` | metal2vulkan 720ef1ce + UniXNU AdrenoMetal bridge as `libmetal2vulkan.dylib` | Same idea as (a); its build is macOS-only (`xcrun metal`, Xcode strip) | (a) already has it, with the negroni fixes |

Why (a): it is the stack that draws the iOS 16.7.16 20H392 home screen on a Pixel 4 (A640, ios-flame) and that runs in
negroni (A730) [V their logs, docs/metal-design.md]; the A610 is in the same Mesa A6xx driver; it reuses the code already in
this repository (no fork). ios-redfin (A620) shows the same stack at ~60 fps home-screen swipes [V its README, claimed].

## 2. Stack on the Mi A3

```
CoreAnimation (backboardd, SpringBoard, apps)
  Metal.framework  _MTLRegisterDevices: IOAcceleratorES -> MetalPluginName -> /System/Library/Extensions/NegroniMetal.bundle
  NegroniMetal.bundle (userland/metal/plugin/NegroniMetal.mm + ios-flame NativeBridgeMetalFrontend.mm + bridge .a)
    metal2vulkan 219f013 + userland/metal/patches (Rust, static)         AIR -> SPIR-V, Metal objects on Vulkan
    libvulkan_freedreno.dylib  Turnip, Mesa 25.0.7 + HackiOS + userland/turnip patches, msm KMD
      src/redwood-drm = userland/negronigl/drm/negroni_drm.c (libdrm + msm stand-in, syncobjs in user space)
  kernel: IOAcceleratorES (topaz 0138, names set by laurel 2850) + RedwoodGPU user client (topaz 0901, AREA B's driver)
    -> TopazAdreno (A610: GPUCC, GX GDSC, SMMU pass-through, zap, SQE, ring) -> SweetFramebuffer present
```

## 3. Adreno 610 facts used here

| Fact | Value | Source |
|---|---|---|
| Mesa table entry | `GPUId(610)` = chip `0x060100ff` (patch id wildcard) in the group 605/608/610/612, props `[a6xx_base, a6xx_gen1_low]` | Mesa 25.0.7 `src/freedreno/common/freedreno_devices.py` [V] |
| Kernel chip id | `0x06010000` (MSM_PARAM_CHIP_ID, kgsl value of the Mi A3), GPU_ID 610; base topaz answered `0x06010001` | B 2150 [V], topaz TopazAdreno.cpp [V] |
| Matching rule | table patch id `0xff` + same core/major/minor | `freedreno_dev_info.c` [V] |
| GMEM | `0x21000` (128 KiB + 4 KiB), base `0x100000` | TopazAdreno.cpp `GMEM_SIZE`, `GMEM_BASE` [V] |
| CCU / tiles | `num_ccu 1`, tile align 32x16, 16 VSC pipes, cs shared mem 16 KiB | Mesa table [V] |
| UBWC | kernel: highest_bank_bit **14** (B 2150), swizzle 7, macrotile 0. Turnip uses the kernel's HBB (`tu_knl_drm_msm.cc` MSM_PARAM_HIGHEST_BANK_BIT); the table's 13 is only the fallback | B 2150, Mesa [V] |
| a6xx_gen1_low | reg_size_vec4 48, no GMEM fast clear, no HW multiview, **no sampler min/max**, no FS tex prefetch, no double thread size, 16 VS inputs | Mesa table [V] |
| GMU | no GMU firmware on the A610 (Linux drives it with the "GMU wrapper"; topaz brings it up without one); negroni's A730 GMU/IFPC work does not apply | topaz TopazAdreno.cpp [V], Linux [I from memory] |
| GPU addresses | SMMU pass-through by default (`gpu_identity=1`): GPU VA = PA, 36 bit; every buffer must be physically contiguous | TopazAdreno.cpp:300, RedwoodGPU.cpp `newBuffer` [V] |
| Turnip with no `MSM_PARAM_VA_START` | `has_set_iova = false`: kernel-chosen addresses (`GET_IOVA`) | `tu_knl_drm_msm.cc` [V] |

metal2vulkan enables what the device lists; its floor is Vulkan 1.2 + `timelineSemaphore` + `hostQueryReset`
(`metal2vulkan-runtime/src/enables.rs`) [V]. The A610 gaps above degrade single features (min/max samplers, multiview)
[I: to confirm with `vkprobe` on the phone].

## 4. Kernel interface (what Turnip needs, what the kernel has)

The topaz RedwoodGPU user client (`iokit/Kernel/arm/RedwoodGPU.cpp`, topaz 0901, HackiOS darwin-redwood design) is the
same msm-struct ABI that negroni's RedwoodGPU has (docs/gpu-abi.md section 4): selector = Linux request number, the
Linux structure in and out. negroni's stand-in (`negroni_drm.c`) detects it (`probe_msm`). So **AREA B's driver hosts
Turnip as it is**, if it keeps this table:

| Need of Turnip / the stand-in | topaz RedwoodGPU | Status |
|---|---|---|
| service `RedwoodGPU`, user client type 0, `IOConnectMapMemory64(handle)` = mmap | yes | OK |
| 0x40 GET_PARAM: GPU_ID, CHIP_ID, GMEM_SIZE, GMEM_BASE, MAX_FREQ, TIMESTAMP, PRIORITIES, FAULTS, SUSPENDS, HIGHEST_BANK_BIT, UBWC_SWIZZLE, MACROTILE_MODE | all (VA_START/VA_SIZE: EINVAL on purpose) | OK |
| 0x42 GEM_NEW (WC/CACHED flags) | WC pool memory, contiguous, kept buffers reused | OK; one buffer < 64 MiB (`GPU_POOL_CHUNK - GPU_POOL_UNIT`), told to Turnip as `RedwoodMaxBuffer` (4.1) |
| 0x43 GEM_INFO GET_IOVA/GET_OFFSET/GET_FLAGS/SET_NAME | yes; SET_IOVA no | OK (Turnip uses GET_IOVA) |
| 0x44 CPU_PREP, 0x47 WAIT_FENCE (absolute timeout), 0x45/0x48/0x4b stubs | yes (polled every 200 us) | OK |
| 0x46 GEM_SUBMIT: CMD_BUF cmds, bo list, SYNCOBJ flags ignored | 1..128 cmds, <= 8192 bos | OK; the stand-in answers 0-cmd submits and the syncobjs itself [V negroni_drm.c:717-756] |
| 0x4a SUBMITQUEUE_NEW, 0x4c QUERY (FAULTS) | yes | OK |
| 0x7e IOSurface import by ID (CA's render targets) | yes, physically contiguous surfaces only (identity mode) | OK for topaz 0937-0940 surfaces (BGRA, 64-byte rows, <= 16 MB) |
| 0x49 host-page import (`VK_EXT_external_memory_host` of plain memory, `newBufferWithBytesNoCopy:`) | **laurel 2160** (stage 1 only, section 6.2) | Built, not run. `NegroniGPUABI` names "userptr" with the tables on; pass-through: noted IOSurfaces only |
| **IOAcceleratorES with `MetalPluginName` / `MetalPluginClassName`** | topaz 0138: empty service | **laurel 2850** (below) |

### Patch 2850 `laurel-metal-registration` (range 2850-2899)

- New `iokit/Kernel/arm/LaurelMetal.cpp` (whole file under `ARM64_BOARD_CONFIG_SWEET`; other boards get a stub that
  returns false) and one line in `iokit/conf/files.arm64`. In `AppleCLCD::start` (topaz 0138) the attached IOAcceleratorES
  goes to `laurel_metal_publish()`, which registers it later (false = kill switch: 0138 registers it at once).
- The check thread, in this order (review M1, 2026-11-01):
  1. root mounted (100 ms poll, <= 60 s);
  2. at once: `NegroniMetal.bundle/{NegroniMetal,libvulkan_freedreno.dylib,Info.plist}` are regular files (`vnode_lookup`);
     a root without the Metal stage ends here, with no GPU wait;
  3. every 100 ms: stop at once when `!topaz_gpu_wanted() || topaz_gpu_failed()` (gpu=0, or the bring-up failed); go on
     when `redwood_gpu_ready()` and the `RedwoodGPU` service is in the registry (`copyMatchingService`, no blocking wait,
     the matching dictionary released); give up 20 s after the root mount only if the bring-up neither ends nor fails;
  4. CHIP_ID `(chip >> 8) == 0x060100` (B's 0x06010000 and topaz's 0x06010001 both pass), GMEM size != 0.
- On: `MetalPluginName = NegroniMetal`, `MetalPluginClassName = NegroniMTLDevice`, `IOGLBundleName = NegroniMetal`, and
  `RedwoodMaxBuffer` = 64 MiB - 64 KiB on RedwoodGPU if the GPU driver has not set it (section 4.1; 2154 sets it first: 256 MiB
  with the tables, so Turnip's limit is 256 MiB there [V source]; the "buffers < 64 MiB" text of the boot line was wrong, laurel
  2851 prints the property). Then the service is registered. Any failure: registered empty.
- Kill switch `laurelmetal=0`. The plug-in has its own (`negronimetal=0`, `/var/db/negronimetal/off`, clients list,
  dead-man strikes: docs/metal-management.md).
- Log, one line: `LAUREL METAL: on: Turnip a610 (chip 0x6010000, GMEM 132 KiB, N MHz, buffers up to 256 MiB), metal2vulkan
  plug-in NegroniMetal.bundle class NegroniMTLDevice on IOAcceleratorES, GPU up N ms after the root`, or
  `LAUREL METAL: off: <reason>`: `laurelmetal=0`, `root file system not mounted`, `<file> missing (errno N): root without
  scripts/laurel/root-add-metal.sh`, `the GPU is off (boot-arg gpu=0, or its bring-up failed)`, `the GPU bring-up failed
  (LAUREL GPU line above)`, `no RedwoodGPU 20 s after the root mount (the Adreno 610 neither started nor failed)`,
  `GPU chip id ... is not an Adreno 610`, `GPU reports no GMEM size`, `no thread for the check`.
- Why the hold-back [V TopazAdreno.cpp `topaz_adreno_thread`]: the GPU starts only after the root mount (+0.5 s + hw
  start). Metal registers its devices once per process. CoreAnimation polls for IOAcceleratorES (300 x 100 ms, topaz 0138
  comment), so backboardd finds the service with the names. A GPU that is off or fails costs CA nothing (the check stops
  at once); only a hung bring-up costs up to 20 s once [I].

### 4.1 Interface with AREA B (GPU driver) and A (memory)

| Symbol / property | Owner | Use here | Without the owner |
|---|---|---|---|
| `redwood_gpu_ready()`, `redwood_gpu_parameter()`, `topaz_root_mounted()`, service `RedwoodGPU`, 0138 block in `SweetFramebuffer.cpp` | topaz (B keeps them) | check, chip, GMEM | - |
| `extern "C" bool topaz_gpu_wanted(void)` | B 2150 (TopazAdreno.cpp: not killed by `gpu=0` and not failed) | stop the wait at once | weak stand-in in LaurelMetal.cpp: the topaz rule (`gpu=1` boot-arg) |
| `extern "C" bool topaz_gpu_failed(void)` | B (to add: return the `failed` flag) | stop the wait at once | weak stand-in: false (B's `topaz_gpu_wanted` already covers `failed`) |
| RedwoodGPU property `RedwoodMaxBuffer` (OSNumber, 64 bit, bytes) | B should set it from its pool chunk / midmem limit | Turnip 0101 caps `maxMemoryAllocationSize`, `maxBufferSize`, so Metal `maxBufferLength` | 2850 sets 0x3FF0000 (topaz `GPU_POOL_CHUNK - GPU_POOL_UNIT`) when it is absent |

[V] Link test 2026-11-01: 2850 + B's 2150 (origin/t3/laurel-adreno-610-gpu 5e93823) links with B's strong
`topaz_gpu_wanted` (external) and our weak `topaz_gpu_failed`; 229 patches, 0 LSE. B's 2151 does not apply on
laurel-int-1 (SweetSurface.cpp, A's 2101): B rebases it.

## 5. Build on Linux

`scripts/bg.sh laurel-metal scripts/laurel/metal-build.sh` (steps `fetch turnip bridge plugin check`; Turnip and the bridge
build at the same time, all host cores). Products: `out/gpu/turnip/libvulkan_freedreno.dylib`,
`out/metal/bridge/ios/libnative_metal_bridge.a`, `out/metal/stage/` (the layout the root gets).

| macOS part (negroni scripts) | Linux replacement | Where |
|---|---|---|
| Xcode iPhoneOS SDK | theos/sdks `iPhoneOS16.5.sdk` at `0222fd54` (sparse clone; its SDKSettings says 16.4) | `metal-env.sh` `SDK_*` |
| Apple clang + ld64 | host clang 23 `-target arm64-apple-ios16.0` + `ld64.lld` (chained fixups by default) | meson `c_ld = 'lld'` (`scripts/gpu/turnip-build.sh`), `userland/laurel/metal/cmake/ios-arm64-linux.cmake` |
| `lipo`, `otool`, `install_name_tool`, `nm -m` | `llvm-lipo` (trailing blank trimmed), `llvm-otool`, `llvm-install-name-tool`, `llvm-nm` | `out/laurel-metal/bin` (made by `metal-env.sh`) |
| `codesign -s -` | theos `ldid -S` | same |
| `xcrun` for cc-rs (sha2 asm) | `SDKROOT=$SDK`, `CC_aarch64_apple_ios=clang` | `metal-env.sh`, `metal-build.sh bridge` |
| Rust | rustup 1.98.0 + `aarch64-apple-ios` (staticlib: no Apple linker needed) | `scripts/metal/fetch-sources.sh` |
| 20H392 dyld cache for `check-imports.py` | the IPSW SystemOS image `087-86593-047.dmg` mounted read-only with apfs-fuse (user space) + blacktop `ipsw` 3.1.741 (SHA-256 pinned) | `metal-build.sh plugin` |
| `xcrun metal` (layerprobe.metallib) | none: skipped with a NOTE (layerprobe takes a metallib argument) | |

macOS: `metal-build.sh` runs the negroni scripts as they are (`fetch-sources.sh`, `turnip-build.sh`, `build-bridge.sh`,
`build.sh`: Xcode SDK, Apple clang/ld64, codesign); only this port's Turnip patch list (`TU_EXTRA_PATCHES`) is added.
Linux host floor: clang and ld64.lld major >= 18 (`LLVM_MIN`, checked in `laurel_metal_tools`) [I: older lld may not emit
chained fixups by default]; meson 1.7.2 is pinned in the venv; ldid comes from the pinned theos toolchain; apfs-fuse is
only for the import check.

Turnip patches of this port: `userland/laurel/metal/turnip-patches/0101-turnip-darwin-max-buffer.patch` (applied after
`userland/turnip/mesa-patches` through `TU_EXTRA_PATCHES`; new `tu_darwin_limits.c` reads `RedwoodMaxBuffer`, override
`TU_DARWIN_MAX_BO=N`, no property = no cap, so negroni kernels are unchanged).

Fixes to shared scripts that the Linux route needed (they keep macOS as it was):
`scripts/gpu/turnip-build.sh` (lld through meson `c_ld`, not in the compiler command: there it made every meson
`-Werror=unused-command-line-argument` check fail and the build broke on `struct timespec`; the `dyld_stub_binder` check
reads the chained-fixup import table on Linux, because every ld64.lld output keeps an unused undefined `dyld_stub_binder` in
its symbol table; GNU `stat -f` printed file-system data), `scripts/metal/build.sh` (`NMTL_CMAKE_TOOLCHAIN`),
`userland/metal/probes/metalprobe.m` (`recommendedMaxWorkingSetSize` through KVC: the 16.5 SDK marks it unavailable on iOS),
`turnip-build.sh` `TU_EXTRA_PATCHES` and a failing `llvm-objdump --chained-fixups` fails the check (review m3).
The LSE check (review m2) matches every LSE/RCpc form: `(casp?|ld(add|clr|eor|set|[su]m(ax|in))|st(add|clr|eor|set|[su]m(ax|in))|swp)(a|l|al)?(b|h)?|ldapu?r(b|h)?`
(tested: it finds ldaddalb, casb, swph, stsmaxl, ldapur, caspal, ldaprb; it does not match ldxr, ldr, stlr, ldar).

Measured (2026-11-01, CachyOS, 20 cores) [V]: section 9.

## 6. Root

`scripts/laurel/root.sh` calls `scripts/laurel/root-add-metal.sh` after the tweaks and after AREA B's
`root-add-gpu.sh` (B's line goes before ours: the clients rule looks for B's backboardd wrapper). On by default, `METAL=0`
skips; no stage = one `metal: off` line, the root build goes on. It installs the bundle, the probes and
`/var/db/negronimetal/{clients,env,cache,strikes,metal.log,build.txt}` through `scripts/metal/root-add-metal.sh`.

Clients: the root's default list is the probes only, marked as the gate's. At boot the gate (6.1) makes it `* -backboardd`: every
process of iOS but the GL window server. `METAL_CLIENTS="..."` at root build makes it the owner's list: the gate leaves it alone.
When B's GL wrapper is in the root (`/usr/libexec/real/backboardd`), a list with `*` gets `-backboardd` unless it names backboardd.
`METAL_ENV=` adds env lines.

### 6.1 Metal client gate: why it did nothing in the 15:27 boot, what it is now

Boot 2026-11-01 15:27-15:31 (`logs/usblog-20261101-001446.txt`, kernel + root with `LAUREL GPU SMMU: on`, `LAUREL METAL: on`, GL frames
8-13 ms) [V]: `exec laurel-metal-gate` at 15:27:18, no `exec m2vtest` in the whole log, no list change, 16 `NMTL ... not listed` lines
(AegirPoster 10, PosterBoard 2, SpringBoard, chronod, PridePosterExtension, backboardd), then `CRASH AegirPoster sig 6` x9 and PosterBoard x1.
Causes, in the order they bite (each alone stops the gate):

| # | Cause | Evidence | Fix |
|---|---|---|---|
| 1 | The gate ran as user **mobile**: the backboardd job has `UserName mobile`, and the wrapper execs it from there. `/var/db/negronimetal` is root's 755, so `posix_spawn` with the log `gate-m2vtest.log` there fails (EACCES, m2vtest never starts) and no list can be written | launchd cache and plist of the 15:16 root [V]; no `exec m2vtest` [V] | own launchd job `com.laurel.metal-gate` (root, RunAtLoad, once), `scripts/laurel/metal-gate-job.py`; wrapper no longer starts it |
| 2 | The gate's lines went to syslog and files; the USB log has the console only | no `LAUREL METAL CLIENTS` and no `LAUREL BBD` in any USB log [V] | gate and wrapper also write `/dev/console` (the plug-in's NMTL lines already do) |
| 3 | m2vtest could never pass on this kernel: step 0x6505 imports host pages (`newBufferWithBytesNoCopy`), and the laurel RedwoodGPU had no request 0x49 | `NativeMetalBridge.rs import()`, RedwoodGPU.cpp [V] | laurel 2160, section 6.2 |
| 4 | Turnip and the stand-in took 16 KiB pages for granted; this kernel has 4 KiB (`PAGES=4k`): 3 of 4 `mmap` results refused | `tu_device.cc` 16383, `ngl_abi.h` NGL_PAGE [V]; effect [I] | Turnip 0103, `NGL_PAGE` = page size of the process |
| 5 | The kernel ring has no CCU invalidate at the start of a submission; Turnip assumes it (Linux `a6xx_submit`). GL never needed it | `redwood_gpu_submit` [V]; ios-redfin METAL-NEXT.md section 4 [V] | laurel 2161 |
| 6 | A fail was final for the build: a reboot during the test (the owner rebooted 4.6 min after the boot) or 240 s under boot load, and no Metal until a new build | old gate source [V]; QuartzCore on these cores takes minutes [I] | 3 tries per build, quick test decides, long test later |
| 7 | A `strikes/gpu-lost` of an earlier boot stopped the gate (the plug-in treats it as stale) | source [V] | same rule as the plug-in |

The gate now [V source, not run]: in order: `kern.laurel_gpu` = `on`; RedwoodGPU `LaurelGPUSMMU` = `stage 1`; IOAcceleratorES `MetalPluginName` =
`NegroniMetal`; no GPU-lost mark of this boot; the clients file is the gate's (first line `# laurel-metal-gate`); m2vtest **without a metallib**
(compute, render, host pages: seconds) exits 0 with `compute bad 0/1000, render bad 0/64, import bad 0/4096` within 300 s, and the GPU is still on.
Pass: `/var/db/negronimetal/clients` = `* -backboardd` + probes, and `NegroniMetal.bundle/clients.local` = `* -backboardd` (a sandboxed process
reads only the bundle; the root is mounted read-write: `/dev/ufsroot0 on / (hfs, local, journaled, noatime)` [V 15:27:15]). Then m2vtest again with
QuartzCore's metallib at nice 20 (limit 1500 s): numbers in the log; only a crash takes the list back. Results per build (kernel version + size and time of
the plug-in and Turnip) in `/var/db/negronimetal/gate` (`<state> <tries> <full> <key>`); `rm` it to test again. Undo: write your own list (any first line
other than the mark), or `METAL_CLIENTS=...` at root build; kill switches: `laurelmetal=0`, `negronimetal=0`, `gpu_hostimport=0`, `BUNDLE/off`.

Lines (console = USB log, syslog, `/var/db/negronimetal/metal.log`, `/var/tmp/laurel-metal-gate.log`; test output `gate-m2vtest.log`):
`LAUREL METAL CLIENTS: testing: m2vtest (compute, render, host pages), try 1 of 3 on this build`,
`LAUREL METAL CLIENTS: on: m2vtest passed: compute bad 0/1000, render bad 0/64, import bad 0/4096; GPU on, SMMU stage 1, plug-in registered: clients "* -backboardd" for every process that starts from now on`,
`LAUREL METAL CLIENTS: QuartzCore shaders: m2vtest passed: QuartzCore: N functions, kernels ...`,
`LAUREL METAL CLIENTS: off: <reason>: clients stay the probes (...)`.

### 6.2 Host pages (laurel 2160) [V build, not run]

Request 0x49, port of negroni 0232 to the topaz RedwoodGPU, only with the stage-1 tables: `IOMemoryDescriptor::withAddressRange` over the caller's
pages + `prepare` (wired while the handle lives; read-only pages with `kUserptrReadOnly`), `newBuffer` enters them into the GPU's address space,
`kIOMemoryIncoherentIOFlush` at import, `kIOMemoryIncoherentIOStore` at each submission that names a writable import. Never kept, no map through the
connection, 1 GiB a client. Line `LAUREL GPU HOST PAGES: on: ...` or `off: SMMU pass-through | boot-arg gpu_hostimport=0: no-copy Metal buffers fail or copy`.
Users: m2vtest, `newBufferWithBytesNoCopy:` (CoreImage, MPS, asset catalogs, Photos), `newTextureWithBytesNoCopy`. Without it those fail or copy.

### 6.3 Memory limits [V 20H392 plist, change not run]

`com.apple.posterkit.provider`: ActiveSoft 15, InactiveHard 15, Rendering Nominal 30 MiB. The device costs 15-20 MiB (negroni measure), so a poster with Metal
dies when inactive, and the plug-in's memory rule (limit < 40 MiB: no device) would give it nil, which it aborts on. `root-add-metal.sh` now raises each *MemoryLimit
of every extension point to at least 64 MiB (`METAL_EXT_MB`), of posters to 128 (`METAL_POSTER_MB`), of assetsd and the Photos conversion services to 64; -1 stays; 117
values on D22. The plug-in's memory rule skips extension point `com.apple.posterkit.provider`. The system memory pressure kill stays as it is.

### 6.4 A client with no device must not crash-loop

iOS has no Metal-less path in AegirPoster and the other posters (`object cannot be nil` in `-[NUNIAegirRenderer ...]`, notes 2026-10-25): abort on a nil device. PosterBoard restarts
them every 8 s (15:31 [V]). The plug-in (`refused_pause`, posters only) counts refusals in a row per process name, in the strikes directory: the 2nd waits 2 s, then 4, 8 ... 60 s, before the nil.
10 minutes with none resets it. A check-in timeout that kills the waiting process is no crash. So: Metal off = one slow retry per minute at most, wallpaper chooser shows no live preview for
those posters, no CRASH flood, and the first start after the gate's pass finds the device (at most 60 s later). Other processes get nil at once (SpringBoard's main thread must not wait; they have CPU paths).
Metal off in this boot's SpringBoard: `CUIShapeEffectStack` etc. keep the CPU path (userland/cifix).

### 6.5 Can backboardd itself go from GL to Metal?

Not now, and not by default [I]. It stays `-backboardd`. Reasons: Turnip has not drawn one frame on the A610; a Metal window server that half works draws nothing, and the fallback today is the software
renderer, not GL (the wrapper inserts the GL loader or not at exec; CA takes its renderer when it starts). What it needs: (1) gate pass and the QuartzCore numbers on the phone; (2) `carenderprobe`, `layerprobe` frame
times against GL's 8-13 ms; (3) the wrapper chooses: flag file `/var/db/negronimetal/backboardd-metal` + gate pass = no loader, `backboardd` in the list; 2 fast exits or `strikes/gpu-lost` = flag ignored, GL loader for this boot
(its crash guard exists; only the order is new); (4) kernel: `topaz_gpu_gl_opened`, the 2155 watchdog and "screen surfaces from the GPU pool, direct scanout off" key on the GL client: they must key on backboardd's Metal client too;
(5) the present path over IOSurface import 0x7e (negroni 0231 role; topaz has no Metal present). By hand today, without a GL fallback: `gl=0` boot-arg + `METAL_CLIENTS="*"`.

## 5a. Compiled target and caches (2026-11-01, gpu-upstream-opt)

`scripts/laurel/metal-env.sh` sets, for this port only (negroni's scripts read none of it unless metal-env.sh is sourced):

| Part | Setting | Why |
|---|---|---|
| Turnip C/C++ | `TU_CPU_FLAGS = -mcpu=cortex-a53 -mfix-cortex-a53-835769` (meson cross file c_args/cpp_args) | ARMv8.0 floor; A53 tuning measured best (gpu.md "Compiled target"); before: Apple's default `apple-a7` tuning |
| Turnip build | `TU_MESON_ARGS = -Db_lto=true -Db_lto_mode=thin -Ddebug=true` (+ the existing `--buildtype=release -Db_ndebug=true`) | ThinLTO through ld64.lld; dSYM `out/gpu/turnip/libvulkan_freedreno.dylib.dSYM`, the bundle copy is stripped |
| Plug-in, probes (CMake) | `NMTL_CPU_FLAGS` -> `CMAKE_<LANG>_FLAGS_INIT` in `ios-arm64-linux.cmake` (a flags change makes a new build directory) | same CPU floor; plug-in dSYM `out/metal/NegroniMetal.dSYM` (build.sh) |
| Rust bridge + metal2vulkan | `CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS = -C target-cpu=cortex-a53 -C target-feature=+fix-cortex-a53-835769`, `CARGO_PROFILE_RELEASE_LTO=thin`, `CODEGEN_UNITS=4` | Rust's default for aarch64-apple-ios is `apple-a7`; `-Z tune-cpu` is nightly only. (`-C llvm-args=-aarch64-fix-cortex-a53-835769` does not exist in Rust 1.98's LLVM: the target feature does) |
| metal2vulkan shader cache | `NMB_SHADER_MEMO_MB=32`, `NMB_SHADER_DISK_MB=1024` (cargo-time, `flame/0018`) | defaults are a 256 MiB memo per process and a 25 GiB directory; every Metal process has its own device |
| Check | `metal-build.sh check`: Mesa A610 entry, 0102 in the Turnip tree, every staged Mach-O minos 16.0 and 0 instructions newer than ARMv8.0 (`scripts/laurel/armv80-check.py`) | |

Caching that exists already [V metal2vulkan `shader_cache/mod.rs`]: translated functions, compute/render pipelines and the
driver's `VkPipelineCache` data (Turnip's compiled ir3 binaries) on disk per process in `/var/db/negronimetal/cache/<proc>`,
written off the creating thread; a memo in memory first. 219f013 adds: the directory no longer hashes the runtime's own
source (8c09b7c: our patches no longer start it cold) and warm render creations decode no AIR. Turnip's own disk cache
stays off (`-Dshader-cache=disabled`): metal2vulkan keeps the VkPipelineCache data. Not wired yet: 6e88d18 (warm a device
from an earlier process's pipeline records at open).

Turnip patch 0102 (`0102-turnip-darwin-a6xx-gen1-vulkan13.patch`) [V source]: Mesa 25.0.7 `tu_device.cc` reports
`apiVersion` 1.0 when `has_hw_multiview` is false (A605/A608/A610/A612) unless `TU_DEBUG=noconform`; metal2vulkan refuses
devices below 1.2 (`device/create.rs`). On Darwin 0102 reports what noconform reports for the API level and multiview
(Vulkan 1.3, KHR_multiview, EXT_shader_viewport_index_layer, maxMultiviewViewCount, maxViewports), nothing else; parts
with HW multiview are unchanged. Kill switch `TU_DARWIN_API=0`; line `TU DARWIN API: on: Vulkan 1.3 on FD610 ...`.

## 7. Open items and risks

1. [U] Nothing ran on the A610 yet. First failure points: Turnip device creation (chip, GMEM 132 KiB), first submit
   (topaz's ring framing for Turnip's IBs: Turnip expects the kernel's `a6xx_submit` wrapper, CCU invalidate at the start,
   CACHE_FLUSH_TS fence; flame's first submits failed without it, docs/metal-design.md 4.3 item 4).
2. (Lifted by 2154 when `LAUREL GPU SMMU: on`: GEM_NEW up to 256 MiB from scattered pages, surfaces from wired pages,
   `RedwoodMaxBuffer` 256 MiB. The text below is the pass-through fallback.)
   Contiguous memory: every GEM_NEW and every imported surface must be physically contiguous (pass-through SMMU); one
   buffer < 64 MiB (pool chunk). Turnip 0101 reports that limit (`maxMemoryAllocationSize`, `maxBufferSize` =
   `RedwoodMaxBuffer`), so Metal's `maxBufferLength` is < 64 MiB and too-large buffers are refused at creation. A texture
   of 64 MiB or more (4096x4096 RGBA8) still fails at allocation [I]. metal2vulkan heaps (8 MB blocks, flame 0100) fit.
   AREA A (contiguous surface pool) owns the pool; `gpu_identity=0` (SMMU tables) would lift it and allow 0x49.
3. Host pages (0x49): laurel 2160 with the stage-1 tables; in pass-through `newBufferWithBytesNoCopy:` and non-IOSurface host imports fail or copy [I].
4. One shared GPU address space, no per-client isolation, polled fences (200 us), at most 128 IBs per submit.
5. GL path (AREA B, GL wrapper/injection into backboardd) and Metal both want backboardd. Which one CA takes in a
   process with both is not known [U]. So backboardd is not a client by default (section 6).
6. RAM: 6 GB phone; Turnip + metal2vulkan cost 15-20 MiB per process (docs/metal-widgets-2026-10-27.md); the plug-in's
   memory rule skips jetsam-limited processes.
7. CA framebuffers are 720x1560 BGRA (4.5 MB): topaz 0939 keeps surfaces up to 16 MB contiguous.

## 8. Phone test plan (coordinator)

1. Kernel with 2850 + AREA B's GPU driver; root with `root-add-metal.sh`. Boot; read the USB log for `LAUREL METAL:`.
2. Over SSH: `vkprobe` (Turnip: instance, device "FD610", features), `m2vtest` (bridge self-test: compute, render,
   IOSurface import), `metalprobe` (Metal device through the plug-in), then `metalprobe --compute`.
   (`scripts/metal/phone-test.sh push|0|1|2|3|log` has the sequence; `logs/metal-phone-*.log`.)
3. Clients: the gate does it (6.1). Read `LAUREL METAL CLIENTS:` in the USB log. To test by hand before the gate: `METAL_CLIENTS=...` at root build,
   or over SSH `rm /var/db/negronimetal/gate` + `launchctl kickstart system/com.laurel.metal-gate` (it runs once per boot: also `rm /var/tmp/laurel-metal-gate.boot`).
4. Expected: `NMTL[pid AegirPoster]: device Turnip Adreno (TM) 610 opened ...`, no `CRASH AegirPoster`, wallpaper chooser shows the posters; section 10 table.

## 9. Versions and measurements

| Component | Pin |
|---|---|
| Mesa | 25.0.7 (SHA-256 `592272df...`), HackiOS b4c5513 patches, `userland/turnip/mesa-patches` 0001-0002, `userland/laurel/metal/turnip-patches` 0101-0103 |
| metal2vulkan | 219f013 + `userland/metal/patches/m2v-flame` + `m2v` (rollback f6a96b7d: `m2v-flame-f6a96b7d`, `m2v-f6a96b7d`) |
| ios-flame frontend/bridge | 745c434 + `userland/metal/patches/flame` (0017 needs m2v 219f013, 0018 cache caps) |
| Rust | 1.98.0 |
| SDK | theos/sdks 0222fd54 `iPhoneOS16.5.sdk` (Version 16.4) |
| ipsw | 3.1.741 linux x86_64 |

Measured 2026-11-01 (CachyOS, clang 23.1.4, LLD 23.1.4, 20 cores) [V logs/laurel-*.log]:

| Step | Result | Time |
|---|---|---|
| fetch (SDK sparse clone, rustup 1.98.0 + aarch64-apple-ios, sources, ipsw) | all present | 68 s cold, 25 s again |
| Turnip (meson + ninja, 614 steps) | `libvulkan_freedreno.dylib` 11.6 MB (11.1 MB stripped in the bundle): arm64, minos 16.0, chained fixups, no `LC_DYLD_INFO`; exports `vk_icdGetInstanceProcAddr`, `vkGetInstanceProcAddr`, `redwood_drm_note_surface`; 4222 optional weak entry-point slots | ~2 min cold [I from tmux times] |
| bridge (cargo, staticlib) | `libnative_metal_bridge.a` 364 MB (debug info) | 5 min 28 s cold (parallel with Turnip), 4 s again |
| plug-in + probes (CMake + Ninja, ld64.lld) | NegroniMetal 26.8 MB, m2vtest 22.5 MB, metalprobe, mslprobe, vkprobe, carenderprobe, layerprobe; ldid ad-hoc signatures | 11 s |
| import check vs the 20H392 dyld cache (apfs-fuse mount + ipsw) | `check-imports: PASS (0 missing)`: 557 imports in 11 libraries | ~1 min first, cached after |
| check | Mesa A610 entry PASS; all staged binaries minos 16.0, 0 LSE/RCpc instructions (the check finds a test `ldaddal`) | 8 s |
| whole `all` again, nothing changed | exit 0 | 15 s |
| kernel `scripts/laurel/kernel-linux.sh` with 2850 | 220 patches apply (19 laurel), 0 LSE/RCpc, both `LAUREL METAL:` strings and `laurel_metal_publish` in the kernel | 42-77 s |
| review fixes, base laurel-int-1 (1e793cb), `all` with the Turnip rebuild (0101) | exit 0, import check PASS, check PASS | 113 s |
| kernel with 2850 on laurel-int-1 | 228 patches, 0 LSE/RCpc; weak `topaz_gpu_wanted`/`topaz_gpu_failed` | 97 s |
| kernel with 2850 + B's 2150 (link test, not committed) | 229 patches, 0 LSE; B's strong `topaz_gpu_wanted` taken | ~90 s |

Measured 2026-11-01 06:30 (gpu-upstream-opt: metal2vulkan 219f013, Turnip 0101+0102, metal-env.sh flags) [V logs/gpuopt-*.log]:

| Item | Before (f6a96b7d, default flags; main checkout build) | After | Note |
|---|---|---|---|
| Turnip build (615 steps, -O3, ThinLTO, -g) | ~2 min | 42 s (20 cores, alone) | lto objects kept for the dSYM |
| Turnip dylib unstripped / in the bundle (stripped) | 11 636 592 / 11 072 128 bytes | 12 060 864 / 10 906 080 bytes | dSYM 50 MB beside it |
| weak symbols looked up at load | 4222 | 3312 | fewer dyld lookups per process start |
| bridge staticlib (thin LTO, 4 CGUs, target-cpu cortex-a53) | 364 MB | 293 MB | 129 s rebuild |
| NegroniMetal (stripped, in the bundle) | 26 834 768 bytes | 22 878 464 bytes | -15 %; dSYM `out/metal/NegroniMetal.dSYM` 206 MB |
| m2vtest | 22 467 280 bytes | 21 498 656 bytes | |
| metal2vulkan A/B, QuartzCore default.metallib (141 functions, vk12-floor profile, `scripts/metal/m2v-ab.sh`) | f6a96b7d: 117 translated (kernel 3/7, vertex 39/39, fragment 75/95), SPIR-V 1 906 384 bytes, 4.4 s | 219f013: 117 translated (same split), SPIR-V **788 556 bytes (-58.6 %)**, 4.2 s | same coverage, far less code for ir3 to compile and run [I: per-pixel cost follows the instruction count] |
| check | PASS | PASS: 0102 in the tree; 8 Mach-O, minos 16.0, 0 instructions newer than ARMv8.0; import check vs 20H392 PASS (0 missing) | |

## 10. Metal for all of iOS: who gets it, what was checked (2026-11-01 17:30)

**Nothing below ran through Turnip on the phone.** Log = boot 15:27, before the fix. "Host" = AIR -> SPIR-V + spirv-val with `scripts/laurel/a610-profile.py` (an estimate from `tu_device.cc`, no capture); it does not cover Turnip's ir3, the GPU, or the picture. Every "expected" is [I] until the gate passes.

| User | Log at 15:27 [V] | Host shaders [V host] | Expected after the gate passes [I] |
|---|---|---|---|
| backboardd (CoreAnimation window server) | GL path, frames 8-13 ms, Metal refused on purpose (`not listed`) | QuartzCore 139/141 | stays on GL (`-backboardd`, 6.5) |
| QuartzCore in a process: CAMetalLayer, CARenderer, CAWindowServer offscreen | no device | QuartzCore 139/141; the 2 left are `inplace_copy_*` (raster order groups, no Turnip feature) | Metal in the process; pictures reach backboardd as IOSurfaces (eagl: seed, else the memory's sum each frame) |
| SpringBoard | `not listed` at 15:29:30 | RenderBox 47/47, CoreUI, QuartzCore | device from the boot after the first pass (it starts before the first test ends); cold device open on its main thread, a slow first start is the risk |
| PosterBoard | `not listed` x2, sig 6 x1 | as QuartzCore | device, no abort |
| AegirPoster | `not listed` x10, sig 6 x9 | NanoUniverse 27/27, ClockKitUI 3/4 (the 4th is a host list artefact) | device, no abort. [U] XR10: it needs `supportsExtendedXR10Formats` YES and draws BGR10_XR; whether GL CoreAnimation in backboardd can show such a surface is not known: wallpaper may be wrong or black |
| PridePosterExtension | `not listed` x1 | PridePoster 8/8 | device. Same XR10 question: no (only Aegir is known to set it) [I] |
| Collections, Gradient, Unity, Emoji, Photos, Extragalactic posters | started, no NMTL line, so no device asked before the end of the log (CollectionsPoster sig 9 once: check-in timeout) | no own metallib seen except via frameworks | device on demand; limit raised to 128 MiB (6.3) |
| UIKit | no own use seen | ColorPicker 2/2 | device where it asks |
| CoreImage | no NMTL line | default 58/59; `ci_*` stitchable libraries are linked at run time, counted, not compiled | Metal CIContext where it asks; userland/cifix CPU path stays when no device |
| Photos / assetsd | assetsd sig 6 x7, **no NMTL: not Metal** (after `SWEET AKS: assetsd sel 7`; negroni had it too) | PhotosUICore 4/4, MediaAnalysis 2/3, Vision 17/18 | PhotosUICore fine; the assetsd crash stays, not this work; host pages (2160) needed by no-copy paths |
| Maps (MapKit, VectorKit) | not started | VectorKit 309/309, AlloyCommon 13/13 | device; heavy on this GPU |
| WebKit GPU process (WebGL, canvas) | not started | ANGLE compiles MSL at run time: not in the corpus | device, with negroni's flame/0014 + 0015. Footprint on negroni 396 MiB against 300 MiB fatal limit: watch for jetsam |
| Camera | not started | CameraUI 2/2, CameraEffectsKit 6/6, CameraColorProcessing 12/13 | camera has its own open work (no iOS frames yet) |
| Widgets (chronod, WidgetKit extensions) | chronod `not listed`; 5 widgets sig 9: check-in timeout, they never loaded Metal | RenderBox 47/47, VFX 257/257 | device; check-in timeouts remain at boot load |
| Third-party Metal apps and games | none in this boot | SceneKit 329/341, SpriteKit 19/19, MetalFX 31/31 | device; 300 MHz low-end GPU, simple games only; no tessellation function pipelines in metal2vulkan yet (`NotImplemented`) |
| OpenGL ES apps (non-backboardd) | none | - | **no GL**: the GL loader goes only into backboardd (bbd_wrap). `EAGLContext` gets nil there. Not in this round; negroni's NegroniGL "apps" gate is the design |
| Simple daemons (syncdefaultsd sig 6 x9) | no NMTL: not Metal (no network) | - | no change |

Host numbers, all 142 system metallibs (`scripts/laurel/metal-corpus.sh all`, `userland/metal/tests/shader-corpus-a610-all.tsv`): 8130 of 9455 translated in that run; AvatarKit was 124/910 there because of floor limits in the profile, and is **910/910** with Turnip's real tessellation and interface limits [V rerun], so about **8916 of 9455** (the TSV has the old AvatarKit rows). UI set of 30 (`shader-corpus-a610-ui.tsv`): **2900 of 2927**. Largest real gaps: MPSNeuralNetwork 625/869 (`Lowering(Sampler) NotImplemented` in metal2vulkan: CNN kernels; Vision and Photos analysis lose those pipelines [I]), MTLReplayer (developer tool), tessellation vertex functions (`NotImplemented`). Host-side gaps, not client gaps [I]: MPSNDArray 60/149 (`LinkedFunction` inputs the host loop cannot supply), PencilKit 6 (stand-in for function constants). The `0/1` rows (`ci_stdlib` etc.) are libraries with no compiled entry, plus one empty list row per library (host artefact).

"24 of 141 QuartzCore failed" (A/B, section 9) was metal2vulkan's vk12-floor profile, not the A610: 20 FramebufferFetch (no rasterization-order access in the floor; Turnip answers it for every part) + 4 storage-texture stand-ins [V rerun].

A610 gaps against what clients ask [V source]: no storage_16bit, storage_8bit, sampler min/max (translation passes without them), no HW multiview (0102 reports the extension; a real multiview client does not exist in iOS UI [I]), 16 vertex inputs (Metal allows 31; UI shaders pass [V host]), reg_size_vec4 48 [U: only ir3 on the phone can say], GPU VA 2 GiB for scattered buffers of ALL clients (`0x01000000-0x80000000`; 15-20 MiB + work per process: no problem until about 40 busy clients [I]), 512 MiB pool then scattered pages, one ring: a Metal submission above 3 s stops the GPU (2155).
