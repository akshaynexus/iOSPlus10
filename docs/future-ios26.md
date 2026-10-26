# Future: iOS 26 on negroni (donor device, kernel source, patch port)

Date: 2026-10-27. Research only. No phone write, no kernel build, no change in `external/`.

Marks: **[V]** verified (command output, file, source line, IPSW content). **[I]** inference or
guess. **[U]** unknown. Each [V] names its evidence.

## 1. Summary

- **Donor: iPhone 11 Pro, `iPhone12,3` (D421AP, A13 T8030), iOS 26.5.2 `23F84`.** The IPSW is
  `iPhone12,3,iPhone12,5_26.5.2_23F84_Restore.ipsw` (section 3). It has the same 1125x2436 @3x screen
  (`artwork-device-subtype` 0x984) as the iPhone X identity of our iOS 16 port. So our display path stays
  the same. [V]
- **A13 is the best SoC generation for us.** It is the oldest iOS 26 SoC. Its IPSW has no DCP firmware, no
  SPTM and no TXM firmware. The A13 kernelcache uses the on-AP display driver `AppleMobileDispH12P`. With no
  SPTM firmware, A13 stays on the PPL model. A14 adds DCP. A15 adds DCP, SPTM and TXM. [V] (IPSW file lists, section 2.2)
- **iOS 26 QuartzCore still has its OpenGL ES and software renderers.** The 23F84 shared cache has
  `CA::OGL::GLESContext` (48 symbols), `CA::OGL::SWContext` (37), `CA::OGL::SW` (338) next to
  `CA::OGL::MetalContext` (289), and `OpenGLES.framework` with `GLEngine.bundle`. So the earlier "QuartzCore
  needs Metal" blocker is smaller: our GL path (Mesa freedreno + EAGL shim) has a target in iOS 26. [V]
  Whether backboardd selects GLES or SW on a Metal-less device is not tested yet. [U]
- **Kernel source exists.** `xnu-12377.121.6` is the newest open-source tag (macOS 26.5). The donor
  kernel is `xnu-12377.122.8`. Our darwin-xnu-build pin `663906528d1c` already knows `MACOS_VERSION=26.5`. [V]
- **No SPTM/TXM is needed.** xnu-12377 still has the PPL-era pmap (`osfmk/arm/pmap/pmap.c`) and
  `config_pmap_ppl`. SPTM is an option (`CONFIG_SPTM`, kernel config `SPTM`). UniXNU-ios26 builds
  xnu-12377 with "the PPL-era pmap ... doconf is never given -sptm or -exclaves". [V]
- **The largest new work is arm64e / PAC.** The kernel must be arm64e with native PAC key writes. Open
  source has only the paravirtual (VMAPPLE `hvc`) key path. Nobody has run arm64e iOS userland on a
  non-Apple PAC CPU yet. [V] for the source state, [I] for the effort.
- **About 74 % of our added patch lines are new drivers** (`bsd/dev/negroni_*`,
  `iokit/Kernel/arm/Negroni*`). They port with small API fixes. The core hooks (AMFI, sandbox, AKS,
  pthread, crypto, trust cache, pmap, IOSurface/IOMFB user-client ABI) need rework. [V] for the count,
  [I] for the effort.
- **iOS 27 exists** (27.2 `24B119`, signed) and still supports A13 (`iPhone12,1` lists 27.x on ipsw.me).
  No xnu-13xxx source is published yet. So iOS 26.5 stays the best target for now. [V]

## 2. Donor ranking

### 2.1 Constraints [V]

- iOS 26 supports iPhone 11 and later and iPhone SE (2nd gen) and later. It drops the iPhone XS, XS Max
  and XR (A12). So the SoC range is A13 to A19. All are arm64e (A12+). [V] web sources 1-3, ipsw.me.
- negroni: Cortex-X2/A710/A510, ARMv9.0, PAC capable (Android reports `paca pacg`). No Apple AMX, no Apple
  GPU, no SEP, no AOP, no ANE, no DCP. Adreno 730. 1440x3216 LTPO 120 Hz OLED (the port now uses a
  1080x2412 framebuffer). 12 GB RAM. In-display fingerprint sensor. Modem not used. [V] docs/device-facts.md,
  docs/research-report.md.

### 2.2 What each SoC generation brings (iOS 26.5.2 23F84 IPSWs) [V]

Evidence: `scripts/ios26/ipsw-ls.py` on the three IPSWs (range reads only).

| Item | A13 (iPhone12,3/12,5) | A14 (iPhone13,4) | A15 (iPhone14,3) |
|---|---|---|---|
| kernelcache | `kernelcache.release.iphone12` 20.6 MB | `kernelcache.release.iphone13` | `kernelcache.release.iphone14` |
| DCP firmware | none | `Firmware/dcp/iphone13dcp.im4p` | `Firmware/dcp/iphone14d6xdcp.im4p` |
| SPTM / TXM firmware | none | none | `Firmware/sptm.t8110.release.im4p`, `Firmware/txm.iphoneos.release.im4p` |
| GPU firmware (AGX gen) | `Firmware/agx/armfw_g12p.im4p` | `armfw_g13p.im4p` | `armfw_g14p.im4p` |
| ANE firmware | `h12_ane_fw_metis.im4p` | `h13_ane_fw_styx_d5x.im4p` | `h14_ane_fw_bia_d6x.im4p` |
| AOP firmware | `aopfw-iphone12aop` | `aopfw-iphone13aop` | `aopfw-iphone14aop` |
| OS / SystemOS images | `094-55352-108.dmg.aea` 7.4 GB / `094-55541-109.dmg.aea` 2.0 GB | 7.7 GB / 2.0 GB | 7.7 GB / 2.0 GB |

Notes:
- Apple says SPTM needs A15/M2 or later and replaces PPL there (web source 4). The open-source makefile
  agrees for Macs: `SPTM_ENABLED_SOCS_MacOSX = t6000 t8112 ...` has no t8103 (M1, A14 class). [V]
- DCP: the display driver moved into a coprocessor with A14/M1 (web sources 5, 6). The A13 kernelcache has
  `com.apple.driver.AppleMobileDispH12P` + `AppleSynopsysMIPIDSI` + `IOMobileGraphicsFamily (343.0.0)`:
  the old on-AP IOMFB, like the iPhone X that our kernel already imitates. [V] `ipsw kernel kexts`.
- GPU family [I, from Apple's Metal feature table]: A13 = Apple6, A14 = Apple7, A15/A16 = Apple8,
  A17 Pro/A18 = Apple9. A lower family asks less of metal2vulkan (no Apple7 features like
  SIMD-scoped reductions on all types, no Apple8 mesh shaders as baseline).
- Exclaves: the A13 kernelcache already has `com.apple.driver.ExclavesAudioKext (340.22)`. [V] It is not used
  by us (our kernel has no Apple kexts). Real exclaves need SPTM (A15+ class) [I, web source 7].

### 2.3 Ranked short list

| Rank | Device | Why | Cost |
|---|---|---|---|
| **1** | **iPhone 11 Pro, `iPhone12,3`, D421AP, A13, 4 GB** | Same 1125x2436 @3x as our iPhone X identity (`artwork-device-subtype` 0x984 in both ADTs [V]): fb geometry, `TimingElements` (0364), backboardd buffers, touch scale and status-bar offsets stay. No DCP, no SPTM/TXM [V]. Lowest GPU family (Apple6). Face ID gestures (like iPhone X). `device-perf-memory-class` 3 [V] (jetsam class of a 4 GB phone) | 60 Hz identity (no ProMotion keys). The `0364` 120 Hz timing trick must work again [I]. Smaller logical screen (375x812 pt) than the 6.7" panel |
| 2 | iPhone 11 Pro Max, `iPhone12,5`, D431AP, A13, 4 GB | Same IPSW and kernelcache as rank 1. Larger logical screen 414x896 pt (1242x2688 @3x, `artwork-device-subtype` 0xa80 [V]), closer to the 6.7" panel | New fb geometry: 1242x2688 does not fit the 1080x2412 framebuffer 1:1. It needs a scaled output or the native 1440x3216 panel mode [I] |
| 3 | iPhone 13 Pro Max, `iPhone14,3`, D64AP, A15, 6 GB | Native ProMotion 120 Hz identity, 6 GB jetsam profiles, 1284x2778 @3x | DCP userland path (IOMFB through DCP), Apple8 GPU family, SPTM/TXM-era userland. Only a fallback if A13 userland fails, or when a later iOS drops A13 |

Considered, not in the top 3:
- `iPhone12,8` (SE 2nd gen, A13, 3 GB, Touch ID, 750x1334 @2x). Touch ID suits our fingerprint sensor, but the
  home-button UI and the 2x 16:9 screen fit the panel badly. [I]
- `iPhone12,1` (11, A13, LCD 828x1792 @2x). Lower scale than the panel. [I]
- `iPhone13,x` (12 series, A14). DCP without ProMotion: all the cost of rank 3 with less gain. [I]
- A16-A19 (14 Pro to 17 Pro). DCP + SPTM/TXM + exclaves-era userland (A18/A19). zeta uses `iPhone18,2`
  (A19 Pro) on SM8350 and is stuck at launchd PAC faults (UniXNU-zeta README). [V] for zeta state.
- No iPhone has a cellular-less variant. All iPhones expect a baseband (`baseband-chipset: "ice19"` in
  D431AP). We already run the iPhone X identity without a modem (CommCenter fails, `root-tweaks-extra.py`
  removes the looping jobs). iPads have Wi-Fi-only models, but the userland is iPadOS. [V]/[I]

### 2.4 Exact IPSW

| Field | Value |
|---|---|
| Devices | `iPhone12,3` (D421AP) and `iPhone12,5` (D431AP), one IPSW |
| Build | iOS 26.5.2 `23F84`, kernel `Darwin Kernel Version 25.5.0 ... root:xnu-12377.122.8~1/RELEASE_ARM64_T8030` [V] |
| URL | `https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25381/6ABE5EEB-511D-4DF4-AB43-FE86D0A7718A/iPhone12,3,iPhone12,5_26.5.2_23F84_Restore.ipsw` |
| Size | 9,941,341,315 bytes |
| SHA-256 (ipsw.me) | `49714db41d2e590e7b1fda55c090a53af5fc9d3293352449e879a664f8c0602b` |
| SHA-1 (ipsw.me) | `9b2b5102462e6d81ce57cbb2f6d1008577216ebb` |
| OS image | `094-55352-108.dmg.aea` (7,381,975,040 bytes, AEA encrypted) |
| SystemOS cryptex | `094-55541-109.dmg.aea` (2,013,265,920 bytes, AEA encrypted) |
| AppOS cryptex | `094-54871-112.dmg` (14,680,064 bytes, plain) |
| Restore ramdisks | `094-54872-112.dmg`, `094-54865-112.dmg` |

Why 26.5.2 and not 26.6.x: the newest open-source xnu is `xnu-12377.121.6` (macOS 26.5). 26.5.2 has
`xnu-12377.122.8`, the nearest kernel to the source. 26.6.2 (`23G90`) is newer but further from the source.
UniXNU-zeta chose 26.5.2 23F84 for the same reason (`board.toml`). [V]

Same build, other devices (for later): `iPhone13,4` 23F84
`.../140-27058/37C9DAC6-C49F-46DE-AB48-C6966B0287C4/iPhone13,4_26.5.2_23F84_Restore.ipsw`,
`iPhone14,3` 23F84 `.../140-25184/43D89CA6-CD25-494D-AB68-F3C099B7E231/iPhone14,3_26.5.2_23F84_Restore.ipsw`
(prefix `https://updates.cdn-apple.com/2026SpringFCS/fullrestores`).

## 3. What we pulled and how

No full IPSW was downloaded (9.3 GiB; the Mac has about 16 GiB free). Only range reads.

| Script | What it does |
|---|---|
| `scripts/ios26/ipsw-ls.py URL [REGEX]` | Lists the members of a remote IPSW (ZIP64 central directory, HTTP range reads, standard library only) |
| `scripts/ios26/fetch-donor.sh` | `op10tool ipsw-get` of the kernelcache, `DeviceTree.$DEV.im4p`, the AGX firmware, `BuildManifest.plist`, `Restore.plist`; `op10tool im4p` unpack; SHA-256 list. About 25 MB. Run with `scripts/bg.sh` |
| `scripts/ios26/fetch-sysos.sh` | Downloads the SystemOS cryptex (2.0 GB), gets the AEA key with `ipsw fw aea --key` (the header has `com.apple.wkms.fcs-key-url`), decrypts it (5.2 GB APFS image). Needs 13 GiB free. Run with `scripts/bg.sh` |

Commands used (2026-10-27):

```sh
scripts/bg.sh ios26-donor env OUTDIR=/tmp/ios26-ipsw/23F84-d431ap scripts/ios26/fetch-donor.sh
out/bin/op10tool ipsw-get -j 2 "$URL" /tmp/ios26-ipsw/23F84-d421ap DeviceTree.d421ap.im4p
out/bin/op10tool im4p /tmp/ios26-ipsw/23F84-d421ap/DeviceTree.d421ap.im4p /tmp/ios26-ipsw/23F84-d421ap/d421ap.adt
ipsw kernel version kernelcache.release.iphone12.macho
ipsw kernel kexts   kernelcache.release.iphone12.macho
ipsw dtree d431ap.adt
```

Results [V]:

| File | Size | SHA-256 |
|---|---|---|
| `kernelcache.release.iphone12` (im4p) | 20,612,352 | `4f2bff7b5b4a02f655b5b2dafc927dd0a5a7ffc58545d82f25c748fdd4375566` |
| `kernelcache.release.iphone12.macho` (Mach-O 64-bit arm64e, FILESET, 257 kexts) | 62,881,792 | `c1524f1f14e5c02f1fb146cb269ea1644873bca5704c7d8357e870e9dae2ac30` |
| `d431ap.adt` | 239,580 | `f32315275cfd4442d4c29f3f7fa9104c8a6b29559b3221a4ba4a70a4998cc6ab` |
| `d421ap.adt` | 236,552 | `91549f0756621cd623a3ebd29e55ddfefc498c95a044dba31c3b904f7c0e765c` |

SystemOS cryptex (dyld shared cache), 2026-10-27 [V]:

```sh
scripts/bg.sh ios26-sysos out/bin/op10tool ipsw-get -j 16 "$URL" /tmp/ios26-ipsw/23F84-d431ap 094-55541-109.dmg.aea
scripts/bg.sh ios26-aea env OUTDIR=/tmp/ios26-ipsw/23F84-d431ap scripts/ios26/fetch-sysos.sh
hdiutil attach -readonly -nobrowse -mountpoint /tmp/ios26-ipsw/sysos 094-55541-109.dmg
C=/tmp/ios26-ipsw/sysos/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e
ipsw dyld info $C;  ipsw dyld info --dylibs $C;  ipsw dyld macho $C QuartzCore --symbols
```

| Fact | Value |
|---|---|
| AEA key | `ipsw fw aea --key` got it from `https://wkms-public.apple.com/fcs-keys/...` (the header's `com.apple.wkms.fcs-key-url`). No private key needed |
| Decrypted SystemOS | `094-55541-109.dmg`, 5,221,908,480 bytes, APFS, SHA-256 `961c42e6152280fc9739c9c65f0d5a0eb04179899da9e4739f5ce17e5f5416c1` |
| Shared cache | `dyld_shared_cache_arm64e` + 83 subcaches, magic `dyld_v1  arm64e`, iOS 26.5, 4301 images, shared region 5 GB at 0x180000000, slide info **v5**, max slide 0x20000000 |
| GPU userland | `/System/Library/Extensions/AGXMetalA13.bundle` (iOS 16: `AGXMetalA11.bundle`), `AGXCompilerCoreG9G12.framework`, `AGXCompilerCore-S2A8.framework`, `Metal.framework`, `MetalTools.framework` |
| GL userland | `OpenGLES.framework` with `GLEngine.bundle`, `libGLImage`, `libGFXShared`, `libGLProgrammability`, `libGLVMPlugin`, `libCoreVMClient` |
| QuartzCore renderers | `CA::OGL::MetalContext` 289 symbols, `CA::OGL::Context` 210, `CA::OGL::GLESContext` 48, `CA::OGL::GLContext` 43, `CA::OGL::SWContext` 37, `CA::OGL::SW` 338, `CA::OGL::NullContext` 29, `CA::OGL::GlassBackgroundFilter` 12 |
| Display / AKS / IOSurface userland | `IOMobileFramebuffer.framework`, `AppleKeyStore.framework`, `IOSurface.framework` present (selectors not traced yet) |
| AMX | `libBLAS` / `libBNNS` export no AMX-named symbols; the cache is stripped, so this proves nothing. [U] |

What is kept (git-ignored, `~/op10-apple/ios26/`, not in git):

| Folder | Files |
|---|---|
| `23F84-d431ap/` | `kernelcache.release.iphone12` (+ `.macho`), `DeviceTree.d431ap.im4p`, `d431ap.adt`, `d431ap-adt.txt`, `armfw_g12p.im4p`, `BuildManifest.plist`, `Restore.plist`, `ipsw-files.txt`, `kexts-ipsw-tool.txt`, `dyld-dylibs.txt`, `QuartzCore-symbols.txt`, `094-55541-109.dmg.aea.key`, `SHA256SUMS` |
| `23F84-d421ap/` | `DeviceTree.d421ap.im4p`, `d421ap.adt`, `adt.txt`, `SHA256SUMS` |

The 2.0 GB `.aea` and the 5.2 GB decrypted SystemOS image were deleted after the audit (disk). `/tmp/ios26-ipsw`
was removed. `scripts/ios26/fetch-sysos.sh` makes the image again (about 5 minutes, needs 13 GiB free).
The full IPSW (9.3 GiB) was never downloaded.

### 3.1 ADT shape [V]

- D431AP top nodes: `chosen`, `cpus` (6 CPUs: `apple,thunder` x4, `apple,lightning` x2), `arm-io` (`aic`, `pmgr`,
  `aop`, `sep`, `ans`, `mipi-dsim`, `disp0` = `"disp0,t8030"`, `dart-disp0`, `ane`, `sgx`, `gfx-asc`, `isp`, ...),
  `product`, `filesystems`, `defaults`, `pmap-io-ranges`.
- This is the same shape as D22AP (iPhone X: `disp0` = `"disp0,t8015"`, `sgx`). Our ADT builder (mkadt) already
  copies `/product` and the identity from the donor ADT. So the identity swap is a new input file, not new code [I].
- `/product` of D421AP: `product-name "iPhone 11 Pro"`, `artwork-device-subtype` 0x984,
  `device-perf-memory-class` 3, `compatible-device-fallback "iPhone11,2"`. D22AP: 0x984, class 4,
  fallback `"iPhone9,2"`.

## 4. Kernel source plan

### 4.1 Source state [V]

| Fact | Evidence |
|---|---|
| Newest open-source xnu: `xnu-12377.121.6` (also .1.9, .41.6, .61.12, .81.4, .101.15). No xnu-13xxx (iOS 27) | `git ls-remote --tags github.com/apple-oss-distributions/xnu` |
| `config/MASTER.arm64.iPhoneOS` keeps `ARM_EXTRAS_BASE = [ config_pmap_ppl ]`; `SPTM` is a separate kernel config | raw file at tag `xnu-12377.121.6` |
| Both pmaps are in the source: `osfmk/arm/pmap/pmap.c` and `osfmk/arm64/sptm/pmap/pmap.c` | HTTP 200 for both paths at the tag |
| Code signing: `bsd/kern/kern_codesigning.c` has `#if CONFIG_SPTM` (TXM) and `#elif PMAP_CS_PPL_MONITOR` paths | same |
| PAC keys only for paravirt: `osfmk/arm64/pac_asm.h` `#if HAS_PARAVIRTUALIZED_PAC` + `hvc #0` | same |
| `VMAPPLE.h`: `NO_MONITOR`, `CPU_HAS_APPLE_PAC`, `HAS_PARAVIRTUALIZED_PAC`, `HAS_GIC_V3`, `HAS_ARM_FEAT_SME/SME2/PAN3/SSBS2`, `__ARM_16K_PG__` | same |
| darwin-xnu-build at our pin `663906528d1c` supports `MACOS_VERSION=26.0..26.5`, KDK 26.5 `25F71`, patch dir `patches/26.0` (incl. `guard_sptm_user_pointer_ops_with_pac.patch`, `disable_bti_vmapple.patch`, `00_setup_coreentitlements.sh`) | `out/kernel/local/dxb/build.sh` lines 208-470 |
| xnu-12377 takes headers from a KDK (CoreEntitlements V2, TrustCache, CodeSignature, TrustedExecutionMonitor) and links `machine_routines_nos.o` from KDK `KernelSupport/lib<SoC>.os.<config>.a` | UniXNU-ios26 `scripts/kdk-headers.py`, `patches/xnu-12377/01-kernel-support-source.patch` |
| UniXNU-ios26 (`68c5134`) builds `xnu-12377.121.6` DEVELOPMENT for a non-Apple SoC (BCM2837 config), plain arm64, with 21 patches; zeta reaches `arm_init`, BSD pthread init, APFS mount, launchd | `external/UniXNU-ios26/scripts/build-xnu-12377.sh`, `external/UniXNU-zeta/README.md` |

### 4.2 Recipe changes (`scripts/kernel/build-local.sh`) [I]

1. `XNU_TAG=xnu-12377.121.6`, `MACOS_VERSION=26.5` (dxb takes the tag from `distribution-macOS/macos-265/release.json`).
2. Xcode 26.x instead of Xcode 15.4 (`APP=/Applications/Xcode.app` is already present). Keep Xcode 15.4 for iOS 16.
3. A real KDK root instead of `kdk-empty`: KDK 26.5 (`25F71`) or the headers-only KDKROOT that
   UniXNU-ios26 `scripts/kdk-headers.py` makes from KDK 26.5.2 `25F84`. NEGRONI must not link a SoC
   `KernelSupport` archive; take `machine_routines_nos.c` (UniXNU `01-kernel-support-source.patch`) instead.
4. Keep the NEGRONI config on `MASTER.arm64.MacOSX` + `config_pmap_ppl` + `nos_arm_asm nos_arm_pmap`
   (slop 0006 does this today), never `-sptm`, never `-exclaves`.
5. **arm64e:** drop the `ARCHS="... arm64"` sed (libfirehose stays arm64e) and build the kernel for arm64e with
   `CPU_HAS_APPLE_PAC`, but with native key writes. Board header: start from `VMAPPLE.h` and clear
   `HAS_PARAVIRTUALIZED_PAC`, `HAS_PARAVIRTUALIZED_CTRR`, `APPLEVIRTUALPLATFORM`, `HAS_ARM_FEAT_SME/SME2`,
   `HAS_ARM_FEAT_PAN3` (check SSBS2 on the X2/A710/A510).
6. Port the UniXNU-ios26 12377 helpers we need: source pthread (`e0742df`, "XNU 12377 callback ABI"), source
   corecrypto (`build-corecrypto-14.py --xnu-12377`, `native-source-crypto.patch`), `native-trust-cache-runtime`,
   `zzx-pmap-sync-64bit-pa` (= our slop 0126), `architectural-timer-entry`, `native-virtual-timer-only`.
7. New tree: `out/kernel/local-ios26/` so the iOS 16 build is not touched; same lock file.

### 4.3 arm64e and PAC [V]/[I]

- [V] `cpuid.c` reports ARMv8E only with `HAS_APPLE_PAC`; a plain arm64 kernel refuses arm64e binaries in
  `ml_grade_binary`. zeta got `EBADARCH` and then rewrote 29.6 M PAC words in the shared cache instead.
- [I] We do not need the zeta rewrite: our CPUs have PAC. The kernel must:
  - write `APIAKey`, `APIBKey`, `APDAKey`, `APDBKey`, `APGAKey` `{Lo,Hi}_EL1` natively where VMAPPLE does `hvc`
    (`SET_JOP/ROP_KEY_REGISTERS`, `ml_enable_user_jop_key`, `PAC_INIT_KEY_STATE` in `start.s`);
  - first: one global key set (no switch per process), later per-process B keys;
  - sign the shared-cache auth rebases while it slides the shared region (`vm_shared_region` slide info v3/v5);
  - keep `SCTLR_EL1.EnIA/EnIB/EnDA/EnDB` on at EL0 and EL1. Gunyah must not trap these (Android has `paca pacg`).
- [I] Apple PAC uses an Apple algorithm and `APCTL_EL1`; Cortex uses the architected or IMP DEF algorithm. This does
  not matter: all signatures are made at run time on the same CPU. No PAC value is stored in the IPSW files.
- [U] AMX: Apple A13+ has the AMX matrix unit. If Accelerate/BNNS select AMX code by `hw.cpufamily`
  (`CPUFAMILY_ARM_LIGHTNING_THUNDER` = A13), they hit undefined instructions on Cortex. Our kernel must report a
  family without AMX, or 0. iPhone X (A11) had no AMX, so iOS 16 never saw this. Check the shared cache (step 5).

### 4.4 SPTM / TXM / exclaves [V]/[I]

- [V] Not needed for the A13 donor: the A13 IPSW ships no `sptm.*` and no `txm.*`, and the source keeps PPL.
- [V] Our NEGRONI config already uses `config_pmap_ppl` with `NO_MONITOR`-style open-source pmap (slop 0006), so the
  "PPL" is only the pmap code; there is no monitor at a higher level. The same works in 12377 (UniXNU-ios26).
- [I] An open-source kernel cannot run with Apple's SPTM/TXM anyway (signed Apple firmware for Apple SoCs).
  For an A15+ donor, our kernel would still use the PPL pmap; only the userland would differ.

## 5. Patch portability

Counts [V]: `patches/xnu/` has 140 `.patch` files (0200-0379), `external/slop/negroni-ios/xnu/patches/` 128 patches +
3 stage scripts (0001-0127). Added lines over both sets: 67,498 in negroni driver files, 23,175 in other files
(most are the HID headers and the builtin pthread/HFS/BearSSL copies), 277 in build files (`conf/files*`,
`Makefile*`, `KernelConfigTables.cpp`). Most-touched core files: `bsd/conf/files` (40 patches),
`iokit/conf/files.arm64` (14), `iokit/KernelConfigTables.cpp` (13), `osfmk/arm64/sleh.c` (9),
`osfmk/kern/exception.c` (6), `pexpert/arm/pe_fiq.c` (5), `osfmk/arm64/start.s` (5), `bsd/kern/bsd_init.c` (5).

| Family | Patches (examples) | Verdict | Evidence / reason |
|---|---|---|---|
| SoC drivers in `bsd/dev/negroni_*.c`: UFS, keys, touch, USB/ECM, ADSP/audio, Wi-Fi, BT, battery/charger, thermal, cpufreq/cpuidle, camera, haptics, fingerprint, DSI/DPU, Adreno kernel | slop 0028-0034, 0060, 0065, 0072-0125; ours 0210-0214, 0240-0249, 0260-0379 | **ports as is** (small API fixes) | Plain C on SoC MMIO, SPMI, GPIO and DMA. Only kernel KPIs: `ml_io_map`, `kmem_alloc`, `thread_call`, `IOLock`. Watch: `kmem_*`/`kalloc` flag changes in 12377, `0290 io-submap` (IO_MAP_SIZE in `osfmk/arm/io_map.c`) |
| Build glue: `bsd/conf/files`, `iokit/conf/files.arm64`, `KernelConfigTables.cpp`, `makedefs` | many | **needs rework (mechanical)** | Hunks re-made by hand on new context. One "files" patch per driver set would cut the churn |
| Machine layer: NEGRONI board header, DT platform expert, GIC, timer, SMP/PSCI, `start.s`, `sleh.c`, `pe_fiq.c` | slop 0003-0012, 0016-0018, 0065, 0078, 0082-0083; ours 0288, 0295 | **needs rework** | `start.s` and `sleh.c` change between 8796 and 12377 (PAC, SME, exception paths). UniXNU-ios26 has the 12377 versions (`native-smp-secondary`, `architectural-timer-entry`, `native-virtual-timer-only`, `native-arm-pan`) |
| pmap / VM | slop 0006, 0011, 0126; ours 0290, 0362 | **needs rework** | `config_pmap_ppl` still exists [V]. 0126 = UniXNU `zzx-pmap-sync-64bit-pa` (already in the 12377 series) |
| PAC | slop 0005 (`non-pac-build-fixes`) | **replace** | arm64e build: native key writes (section 4.3). New work, not a port |
| Crypto / RNG | slop 0013, 0014, 0020, 0023, 0027, 0032, 0033 (BearSSL, HMAC PRNG) | **needs rework** | 12377 uses corecrypto KPI v14 and an early crypto init (`2aced86` "initialize source crypto before platform defaults on 12377") |
| pthread | slop 0019 + `0019-stage-libpthread.sh` | **needs rework** | 12377 has a new pthread callback ABI (UniXNU-ios26 `e0742df`) |
| Root FS: mockfs ramdisk, UFS root by GPT name, HFS builtin, unsealed root | slop 0021-0031, `0026-stage-hfs.sh`, ours 0204 | **needs rework** | HFS still ships with iOS 26 (`com.apple.filesystems.hfs.kext (715.120.4)` in the A13 kernelcache [V]), so an HFS+ root stays possible [I]. The hfs source tag must match 12377 |
| AMFI / code signing / trust cache | slop 0015, 0025, 0035, 0036; ours 0221-amfi-policy | **needs rework (large)** | `kern_codesigning.c` and `kern_trustcache.c` changed (CoreEntitlements V2, TrustCache v2 headers from KDK). MAC policy op numbers (0x5a, 0x60 in our README) must be re-checked against 12377 `security/mac_policy.h` |
| Sandbox | slop 0050; ours 0222, 0223 | **needs rework** | The `__mac_syscall("Sandbox", op, ...)` op numbers and privilege numbers (1002, 1007, 12000) are libsystem_sandbox ABI of iOS 16; they change per release [I] |
| AppleKeyStore emulation | slop 0038, 0055; ours 0220, 0221-aks-passcode | **needs rework** | User-client selectors (7, 10, 11, 17, 23, 31, 40, 100-103, 115) are AppleSEPKeyStore ABI of iOS 16. iOS 26 keybag code (`AppleKeyStore` userland) must be re-traced. The "HKwr" wrap format is ours and stays |
| Identity / sysctl | slop 0059, 0061, 0088; ours 0363, 0378 | **ports as is** | `hw.machine`/`hw.model` from the ADT; swap D22AP for D421AP |
| IOSurface / IOMFB / AppleCLCD stand-ins, HID event services | slop 0046, 0056, 0058, 0068; ours 0201, 0205, 0230-0237, 0250-0259, 0267-0269, 0289, 0364 | **needs rework (large)** | These answer the user-client ABI of IOSurface (iOS 16) and IOMobileFramebuffer (IOMobileGraphicsFamily of iOS 16). iOS 26: IOSurface 393.5.7, IOMobileGraphicsFamily 343.0.0 [V]. Selectors and struct sizes must be re-traced. A13 keeps the on-AP IOMFB model, so the design stays [I] |
| GPU kernel (RedwoodGPU / Adreno, IOAccelerator) | ours 0230-0237, 0281, 0285-0287, 0298 | **hardware part ports; user-client part reworks** | Hardware code is ours. The IOAccelerator/IOGPU user-client shape belongs to the Metal/GL userland of each release |
| Debug / USB command server / bootlog / panic USB | ours 0210, 0360, 0361, 0366, 0367, 0371 | **ports as is** | Hooks at `panic`/`debug.c` move a little; the USB side is our driver |

Userland side:

| Piece | iOS 26 change | Verdict |
|---|---|---|
| Root build `scripts/ios16/root-*.sh` (HFS+, cryptex copy to `/private/preboot/Cryptexes/{OS,App}`, dyld cache hard links) | OS and SystemOS are now `.dmg.aea`: add `ipsw fw aea` decrypt [V]. The cryptex layout is the same idea as iOS 16 [I] | needs rework (small) |
| `root-tweaks-extra.py`, `jetsam_widgets.py`, launchd job removals | Job names and plists change; jetsam plist is per device (`com.apple.jetsamproperties.D421.plist` [I]) | needs rework (audit) |
| AKS emulation | kernel side above; the userland expects the iOS 26 selector set | needs rework |
| GL path (Mesa freedreno + EAGL shim, CoreAnimation OpenGL renderer) | iOS 26 QuartzCore still has `CA::OGL::GLESContext` and `OpenGLES.framework` [V]. The EAGL/GLEngine SPI that our shim answers must be re-checked for 26.5. Rebuild for arm64e | needs rework (medium) |
| Metal layer (metal2vulkan, NativeMetal, AGXMetal bundle stand-in) | The private Metal SPI of iOS 26 differs from 20H392 and from iPadOS 17.7.11. Apple6 family is the smallest target | needs rework (large) |
| Mesa/Turnip builds | Rebuild with `-target arm64e-apple-ios26.0`; arm64e ABI for any dylib loaded into arm64e processes | needs rework (build flags) |

## 6. Blockers, most severe first

1. **arm64e PAC in our own kernel on Cortex** [I, large, high risk]: never done on non-Apple PAC hardware.
2. **QuartzCore without Metal** [U, now smaller]: the GLES and SW renderers exist in 23F84 [V]. Open: does
   backboardd pick GLES or SW when no Metal device exists, and does Liquid Glass need Metal-only filters.
3. **AMFI / trust cache / CoreEntitlements V2** [I, large]: our stand-ins must answer the 12377 code-signing calls.
4. **IOSurface / IOMFB / AKS / Sandbox user-client ABI** [I, large]: re-trace each selector for iOS 26.
5. **AMX via cpufamily** [U]: Accelerate may run AMX instructions on an A13 identity.
6. **Disk**: iOS 26 OS image 7.4 GB + SystemOS 2.0 GB, encrypted; the Mac has about 16 GiB free [V].
7. **No xnu-12377.122.8 source**: we build 12377.121.6 for a 12377.122.8 userland. The kernel ABI to
   userland is stable inside one train [I]. UniXNU-zeta does the same.

## 7. Next steps (ordered)

1. Owner decision: confirm the donor `iPhone12,3` 23F84.
2. The small parts are in `~/op10-apple/ios26/23F84-d431ap` and `23F84-d421ap` (section 3). To get them again:
   `scripts/bg.sh ios26-donor scripts/ios26/fetch-donor.sh` (default `DEV=d421ap`).
3. Shared-cache audit, part 2 (part 1 done: renderers, AGX bundle, slide info v5): rebuild the SystemOS image with
   `scripts/ios26/fetch-sysos.sh`, then trace the `IOMobileFramebuffer`, `IOSurface` and `AppleKeyStore` selectors
   and the EAGL/GLEngine SPI, and look for AMX opcodes (`(insn & 0xfffffc00) == 0x00201000`) in libBLAS/libBNNS.
   At the first iOS 26 boot, log which `CA::OGL` context backboardd makes. Write the result into this file and delete the image.
4. Kernel: new `scripts/kernel/build-ios26.sh` (copy of `build-local.sh`, section 4.2), plain arm64 first,
   machine layer only (no negroni drivers), until `arm_init` + console on the phone with `fastboot boot`.
5. arm64e: native PAC keys (one global key set), `ml_grade_binary` accepts arm64e; test launchd from the
   donor root.
6. Port the patch families in this order: build glue, machine layer, UFS + HFS root, USB console/command server,
   AMFI/trust cache, pthread, AKS, sandbox, HID/touch, IOSurface/IOMFB, then the rest of the drivers.
7. Root: `scripts/ios26/root-*.sh` from the iOS 16 scripts plus AEA decrypt; D421AP ADT for mkadt.
8. GPU: Metal SPI audit for iOS 26 (Apple6), then metal2vulkan port.

## 8. Sources

1. iOS 26 device list: https://www.techradar.com/phones/ios/ios-26-compatibility-does-your-iphone-support-it-heres-the-full-list-of-supported-devices
2. https://us.smartprix.com/bytes/full-list-of-iphone-models-compatible-with-ios-26-update
3. ipsw.me API (firmware lists, URLs, SHA-256): https://api.ipsw.me/v4/device/iPhone12,3?type=ipsw
4. Apple Platform Security, SPTM/TXM (A15/M2 and later): https://support.apple.com/guide/security/operating-system-integrity-sec8b776536b/web
5. DCP introduced with A14/M1: https://theapplewiki.com/wiki/Display_Coprocessor
6. IOMobileFramebuffer and DCP: https://theapplewiki.com/wiki/IOMobileFramebuffer
7. SPTM and exclaves analysis: https://arxiv.org/pdf/2510.09272v1
8. xnu source: https://github.com/apple-oss-distributions/xnu/tree/xnu-12377.121.6
9. darwin-xnu-build: https://github.com/blacktop/darwin-xnu-build (pin `663906528d1c`)
10. UniXNU ios26 branch: https://github.com/none24smu/UniXNU/tree/ios26 (local `external/UniXNU-ios26`, `68c5134`)
11. UniXNU-zeta (iOS 26 on SM8350): https://github.com/none24smu/UniXNU-zeta (local `external/UniXNU-zeta`)
12. ipsw tool (AEA keys, kernel/dtree parsing): https://github.com/blacktop/ipsw
13. iOS 27 firmware list (A13 still supported): https://api.ipsw.me/v4/device/iPhone12,1?type=ipsw
