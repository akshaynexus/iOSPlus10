# Mi A3 iOS 26 kernel: xnu-12377.121.6, plain arm64, native Linux build

Date: 2026-11-02. **Compile and link only. This kernel has never run.** No flash, no reboot and no write on the phone were done. Labels: [V] measured
here, [I] inference, [U] unknown.

Series method and work flow: [`patches/laurel/xnu-12377/README.md`](../../patches/laurel/xnu-12377/README.md). One result line per patch:
[`ios26-kernel-series.txt`](ios26-kernel-series.txt). Build: `scripts/bg.sh ios26-kernel scripts/laurel/kernel-ios26-linux.sh`
(`make laurel-ios26-kernel`). Work tree: `out/laurel-kernel-ios26/`. The iOS 16 build (`kernel-linux.sh`, `out/laurel-kernel/`) stays as it was.

## 1. Result

| Item | Value [V] |
|---|---|
| Output | `out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k` (+ `.unstripped`, `.stamp`, `SHA256SUMS`, `series-report.txt`) |
| `file` | `Mach-O 64-bit arm64 executable, flags:<NOUNDEFS\|PIE>` |
| Size | 20,157,632 bytes (unstripped 25,402,832), at commit 7d428f2 |
| SHA-256 | `5b4698bbcee921f4c0b2d7a16117bdb639651cee61e82cbb107f696f817c9723` at commit 7d428f2 (the stamp holds the commit, so each commit gives a new hash) |
| Link base | `0xfffffff007004000`, plain arm64, 0 chained rebases (`mkdarwinboot.py`) |
| Stamp | `LAUREL BUILD: 7d428f2f03 316 patches, series 754cb97ce57373ad, ios26_4k` (309 + 7: base, post and stage files of `patches/laurel/xnu-12377`) |
| Clean run | 66 s, 20 cores, clang 23.1.4; `build.log`: 0 `linker command failed` |
| LSE/RCpc check (`kernel-linux.sh` regex) | `LSE/RCpc instructions in the kernel: 0` |
| `armv80-check.py` | `0 instructions newer than ARMv8.0` (with `--data-syms`: 22 data words decode as instructions, under K256, lz4 and panic strings; the iOS 16 kernel has 21 under the same symbols) |
| `printf-arg-check.py` | `OK (limit 22 values)` |
| Boot image | `out/laurel-ios26/uefi/laurel-uefi-boot.img`, 52,862,976 bytes, SHA-256 `c0574e291739526500f7c7f34ba8506c0217b7ab947d6ab2edc68e52126ddfb5`, ADT donor N104AP. Not written anywhere |

## 2. Series totals

309 patch files (201 topaz + 108 laurel), 309 result lines [V]: **210 applied, 83 applied+rules, 11 base, 5 skipped, 0 errors**. (That count is of commit 7d428f2. At the commit of laurel 2960: 315 patch files; summary line: 212 applied, 86 applied+rules, 11 base, 8 skipped (2 of them the stage lines), 0 errors; `ios26-kernel-series.txt`; 2960 is skipped: `ios16-lse.md`.) The 3 stage
scripts: BearSSL (topaz) ran; libpthread and HFS were replaced by their 12377 pairs (2 lines `skipped: replaced`, 2 lines `ran`).

| Skip | Reason |
|---|---|
| `0002` UIO_STACKBUF | upstream: 12377 has it |
| `0005` non-PAC fix | upstream: 12377 names the field `reserved11` |
| `0007` stub headers | not needed: base 0001 guards `sart.h`, `uat.h`, `tunables.s`; 12377 `task.c` has no `t_kpc` |
| `0013` kmem RNG | in base 0005: 12377 moved this random to `vm_map_store.c`; the SplitMix64 code is ported there |
| `2011` boot line 1024 | upstream: 12377 `BOOT_LINE_LENGTH` is 1024 |

Parts of patches that a rule drops, with the reason in `scripts/laurel/ios26-series.py`: `0008` (`pmap.c`: in base 0001; `amcc_rorgn_*`: built only with
`apple_amcc`; `kpc.c`: 12377 has it) and `0014` (`entropy.c`: 12377 hashes with `SHA512_*`, BearSSL gives them with no kext).

10 patches have a section that is merged three-way (`3way FILE`), not applied as text: 0004, 0010, 0012, 0019, 0043, 0065, 0140, 0920, 2014, 2302.
They compile; a merge can still be wrong in meaning.

## 3. What was closed

| Item | Result |
|---|---|
| Linux toolchain [V] | as `kernel-linux.sh`: `ios-sweet-linux` scripts, stock clang 23, theos cctools ld64-609. New: MacOSX 26.1 SDK, KDK 25F84 headers (`kdk-headers.py --dmg`), the versions of macOS 26.5 `release.json` (AvailabilityVersions-157.2, libdispatch-1542.100.32, libplatform-375.120.2), the Python `iig` of `xnu-linux-toolchain`, fixed by `ios26-iig-fix.py` |
| Machine layer [V compile] | base 0003: `start.s` (PSCI entry, Gold hand-off 2016, 4K bootstrap), `arm_vm_init.c`, `cpu.c`, `sleh.c`, `arm_init.c`, `caches_asm.s`. `pe_fiq.c`, `machine_routines.c`: as series text or three-way. Compared against the negroni 12377 base: the differences are device features only |
| 4K pages, AMP [V compile] | `TOPAZ_4K=1`, Gold = P, Silver = E. 12377 needs a 16-byte CAS in Edge stir-the-pot (`#error` on LL/SC): base 0005 uses 64 bits (8 CPUs x 2 bits) and the LL/SC loop |
| ARMv8.0 [V] | `-mcpu=cortex-a53`; `libfirehose_kernel.a` for cortex-a53; checks in section 1 |
| Crypto, RNG [V compile] | 12377 builds its early DRBG from `osfmk/corecrypto`. `sweet_prng` (0014) ported to the 12377 `register_and_init_prng`. BearSSL stage and hashes as in the series. `vm_map_store.c` uses SplitMix64: on this kernel `g_crypto_funcs` stays NULL. Source corecrypto of UniXNU is not needed |
| pthread [V compile] | libpthread-539.100.4 (`stage/0019-stage-libpthread-539.sh`), series patches unchanged, `sizeof(ksyn_waitq_element) == 56` still holds |
| HFS [V compile] | hfs-715.120.4 (`stage/0026-stage-hfs-715.sh`), series patches unchanged |
| AMFI, CoreEntitlements V2 [V compile] | built-in AMFI of the series, on 12377. **New: `LAUREL CE`**: DER entitlements to OSDictionary, for signatures with no XML blob. The closed table `libCoreEntitlements` is read only under `CODE_SIGNING_MONITOR` and `PMAP_CS`, both off; `sweet_amfi.c` now has `#error` if that changes. So no `CEKernelAPI_t` table is registered: nothing would read it |
| Trust cache [V compile] | off, as iOS 16: no Image4 and no libTrustCache. Line `SWEET: trust caches unavailable`. `query_trust_cache` gives not found; `shared_region_map_and_slide` goes on with its root check. Every binary on the root is a platform binary (`sweet_amfi`) |
| Crash fault region (negroni open item) [V compile] | `exception.c`: ported to range locks |
| RAM classes, **found by review** [V code] | 12377 `pmap_construct_pte` maps `VM_WIMG_WCOMB` outside `/chosen dram-base + dram-size` as Device-GRE. The screen (0x5c000000) and the GPU pool are outside the window. Device memory faults on an unaligned access and on `DC ZVA`. So the N104AP ADT gives `dram-base` 0x40000000, `dram-size` 0x180000000. The iOS 16 ADT is unchanged |

## 4. For the lowered arm64e userland

The two tracks are joined: `ios26-userland.md` sections 7.1-7.4 (state per item, truth test, what was found), 8.2 (user-client ABI, IOS-26-Hot table) and 8.3 (Apple80211 of 23F84). Root: `ios26-root.md`. This table is what the kernel does now:

| Need | Kernel |
|---|---|
| Accept the userland | `ml_grade_binary`: `CPU_SUBTYPE_ARM64E` has grade 8 on this V8 host, below arm64 (10, 9). All `ptrauth_calls` exec gates compile out |
| Shared region slide | **Bug fixed**: 12377 v3 and v5 wrote an auth rebase only inside `#if ptrauth_calls`, so a plain kernel left the raw value in the page. Now it writes the plain pointer (base 0005) |
| Slide info v5 | **`shared_region_pager_data_request` handles 16 KiB slide pages on 4 KiB VM pages** (a copy of the whole slide page). The 12377 code copied 16 KiB into a 4 KiB page |
| Undefined instruction hook | **`LAUREL EMU`** `osfmk/arm64/laurel_abi.c` + `laurel_a64emu.c`, from `handle_uncategorized` and `handle_msr_trap`: PAC, LSE, CASP, RCpc, RCpc2, FP16, FCMA, DotProd, JSCVT, FHM, SHA3, SHA512, RDM, DIT, SB. Kill switches `laurelemu=0` (the 0081 path stays), `laurelpacemu=0`. This replaces the `LAUREL PACEMU` of the first version, which turned itself off at first use (ios26-userland.md 7.3) |
| Copyio recovery | `copyio_recover_table_end` moved to the end of `machine_routines_asm.s`: the 0081 ranges were outside the table |
| dyld flags, commpage | `LAUREL DYLD`, `LAUREL CPUID` |
| User clients | IOSurface, IOMFB of 23F84: ios26-userland.md 8.2. **This kernel no longer answers an iOS 16 userland on these clients: the doc's section 8 line "the kernel reaches launchd of iOS 16" stops at the first surface** |

## 4.1 Debug without a picture

Patch `2951-laurel-boot-state.patch` (both kernels): USB commands `state`, `ps`, `logall`; lines `LAUREL STATE`, `LAUREL SSH`. `ios26-first-boot.md`, `usb-debug.md`. Host test of its table: `scripts/laurel/state-test.sh`.

## 5. Donor: N104AP (owner decision 2026-11-02)

Values read from `DeviceTree.n104ap.im4p` of the 23F84 IPSW (`scripts/bg.sh ios26-donor scripts/laurel/ios26-donor.sh`; sha256 of `n104ap.adt`
`ab9fa326...`) [V]. `scripts/laurel/mkadt.py --donor n104ap`; default `d22ap`, so the iOS 16 ADT is the same as before.

| Property | N104AP | D22AP (iOS 16) |
|---|---|---|
| `compatible`, `model`, `target-type`, `target-sub-type` | N104AP + iPhone12,1, iPhone12,1, N104, N104AP | D22AP + iPhone10,3, iPhone10,3, D22, D22AP |
| `artwork-device-subtype` | **0x700** (1792) | 0x984 (2436) |
| `artwork-scale-factor` | 2 | 3 |
| `artwork-display-gamut` | P3; `mkadt` writes sRGB as on iOS 16 | P3 |
| `compatible-device-fallback` | iPhone11,8 | iPhone9,2 |
| `graphics-featureset-class` | APPLE6 | APPLE4 |
| `app-macho-architecture` | arm64e | not present |
| `device-perf-memory-class` | 3 | 4 |
| `thin-bezel`, `large-format-phone` | 1, 1 | 1, not present |
| `oled-display` | not present | 1 |
| `wifi-chipset`, `baseband-chipset` | 4378, ice19 | 4357, mav17 |
| `display-corner-radius` (`/product`, 8 bytes) | 0x53, 2 | not present |

Panel: 720x1560 at scale 2 (360x780 points), in `/chosen display-scale`. Checked for code keyed to the iPhone X [V grep]:
- Kernel: no code reads 0x984. The 1125x2436 canvas is only the fallback of `sweetfb_native=0` (`SweetFramebuffer.cpp`, `SweetHID.cpp`). The default is the native canvas (2103). That fallback is wrong for N104AP; it stays a kill switch. `SWEET_FB_DOT_PITCH` is 458 (iPhone X; iPhone 11 is 326 [I]).
- Userland, to check in the userland port: `scripts/laurel/root-statusbar.py` (layout class for iPhone10,3, `CORNER_IPHONEX`), `userland/laurel/notch`, `userland/camera`, `userland/audio`, `root-hevc.sh`.
- 360x780 points matches no iPhone 11 layout (414x896 points) [I]: the status bar work of iOS 16 must be done again for N104AP.

## 6. Not real code, on purpose

| Item | State |
|---|---|
| DriverKit RPC | does not work, the same as the iOS 16 Linux kernel. `*_Invoke` of the Python iig give unsupported; `IOUserClient::CreateActionKernelCompletion` gives `kIOReturnUnsupported`. No dext runs on this port |
| `make` exit code | always 2: `kextsymboltool` lists DriverKit names in `check_all_exports`. As iOS 16: the kernel check is `build-stamp.py kernel-verify` |
| Test dext | `TestDextRematch` removed from `iokit/conf/files`: it needs a class only Apple's iig generates |
| PGO | `pgo` off. `__llvm_profile_*_internal` give 0 and -1 |
| `__cxa_atexit` | returns 0: a kernel never runs static destructors |
| kalloc types | stock clang has no `__builtin_xnu_type_*`: every type goes to the data heap, as on iOS 16 Linux. Weaker isolation, same function |
| Warnings | `xnu-clang` passes `-w`, as on iOS 16 Linux. Only errors stop the build, so a wrong pointer type in old driver code stays quiet |

## 7. What will likely fail first at boot [I]

In boot order:
1. **`start.s`, 4K tables, `arm_vm_init`**: no 12377 kernel has run with 4 KiB pages here. Sign: no white band, or it stops at an early mark. `T1SZ_BOOT` and the 16-page bootstrap table are from 8796 reasoning.
2. **kalloc and zalloc startup with stock clang**: only the two 8796 asserts are ported. 12377 has more type code.
3. **`pmap_bootstrap`, `ml_parse_cpu_topology`, AMP with `MAX_CPU_CLUSTERS 2`**: Edge scheduler state in 12377 differs. Secondary CPUs on the 12377 reset path (no `sysreg_restore`).
4. **Timer and GIC** (`sleh_irq`, `pe_fiq.c`): same code as iOS 16, new `ml_interrupt_masked_debug` calls.
5. **IOKit start**: `SweetPlatformExpert`, `SweetCPU`, `AppleCLCD`. API changes that `-w` hid.
6. **Root mount**: hfs-715 on the new VFS; `rd=ufsroot0`.
7. **launchd and later**: the root exists (`ios26-root.md`), never run. What to read at each stage: `ios26-first-boot.md`. Then dyld on a lowered cache, 83 subcaches, the first `LAUREL EMU` words, and the user-client ABIs, read from the frameworks (ios26-userland.md 8.2) but never run. Sandbox: not traced.

## 8. T1 test plan (only when the owner asks for a flash; not now)

Image: `scripts/bg.sh ios26-image scripts/laurel/ios26-image.sh`, output `out/laurel-ios26/uefi/laurel-uefi-boot.img`. The script writes nothing to the phone.

1. Owner gives the go and puts the phone in fastboot (Power + VolDown). Back up nothing new: `boot_b` restore is `BOOTIMG=~/laurel-backup/stock/images/boot.img scripts/laurel/flash-boot.sh`. The LineageOS dual boot state must be checked first: this image replaces the boot slot in use.
2. This ABL refused `fastboot boot` in `uefi-boot.md`; `cellular.md` section 8 uses it. Try `fastboot boot` first. Only if refused, ask again before a `boot_b` flash.
3. Pass marks, photo of each: (a) UniXNU menu, then `DARWINBOOT: ARM64 va=0xfffffff007004000 pa=0xe1004000`; (b) white band; (c) kernel console: `Darwin Kernel Version 25.5.0`, `LAUREL BUILD: <commit> 315 patches, series ..., ios26_4k`, `LAUREL CPU: boot cpu mpidr=0x100`, `LAUREL RAM: on`; (d) `SWEET PRNG: HMAC-SHA256 registered`, `SWEET AMFI: built-in interface registered`, `SWEET pthread: libpthread-539.100.4 registered`; (e) USB ECM on the host and `op10tool ctl ping`, `logs/laurel-boot-*.log`; (f) bsd_init banner and the HFS root mount.
4. Stop at the first panic. It is the result of T1. Copy the screen text to `docs/notes.md`, fix, rebuild, ask again.
5. No root work in T1. With `rd=ufsroot0` the iOS 16 root on userdata may start, and the kernel reaches launchd of iOS 16: that is a kernel test, not the goal. Since the 23F84 ABI port, IOSurface and IOMFB of that root fail: the test ends before the UI. If the root must stay untouched, boot without `ufsrw=1 rootrw=1`.
