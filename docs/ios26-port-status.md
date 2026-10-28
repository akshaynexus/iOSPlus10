# iOS 26 port status (kernel xnu-12377.121.6, donor userland iOS 26.5.2 23F84 iPhone12,3)

Date: 2026-10-27. Branch `ios26-prep` (draft PR #1). No phone access in this work: every result here is a host
result. Background and donor choice: [future-ios26.md](future-ios26.md). Boot test order for later:
[ios26-boot-plan.md](ios26-boot-plan.md).

Marks: **[V]** verified here (command output, file, build log). **[I]** inference. **[U]** unknown.

## 1. Summary

- **Toolchain** [V]: Xcode 27.1 (27A9275, `/Applications/Xcode.app`), MacOSX27.0 SDK, darwin-xnu-build (dxb) at the
  iOS 16 pin `663906528d1c` with `MACOS_VERSION=26.5` (xnu tag from `distribution-macOS/macos-265`). No new Xcode and
  no full KDK download.
- **KDK** [V]: xnu-12377 needs CoreEntitlements V2 / TrustCache / CodeSignature / TrustedExecutionMonitor headers
  that are only in a Kernel Debug Kit. `scripts/ios26/kdk-headers.py` attaches the KDK 26.5.2 (25F84) disk image
  **over HTTP** and takes the 28 headers of the 140 KB `KDK_SDK.pkg` payload, plus our own
  `KernelSupport/CoreEntitlements/V2/Kernel.h` (`CEKernelAPI_t`, 43 members from the V2 prototypes).
- **Same series as iOS 16** [V]: the iOS 26 kernel applies the slop patches and `patches/xnu/*.patch` unchanged, in
  the iOS 16 order, on a small 12377 base (`patches/xnu-12377/0001-0005`). The 12377 differences are data rules in
  `scripts/ios26/patch-rules.py` and one skip list. A driver fix lands once in `patches/xnu/`; both kernels get it.
  Rule and layout: [../patches/xnu-12377/README.md](../patches/xnu-12377/README.md). The old 0006/0007 snapshots of
  the iOS 16 tree (3.6 MB) are gone.
- **Series result** [V] (`series-report.txt` of the last build): 154 applied as is, 96 applied with rules, 0 replaced,
  39 skipped (24 in the 12377 base, 1 upstream, 4 not needed, 10 open), 0 errors; slop stage script 0020 (BearSSL)
  runs. Rules used: 57 build-list (glue), 29 `vm_kern_xnu.h` include, 21 base-owned file drops, 10 `sub`, 1 each of
  `rename_file`, `drop_file`, `insert_after`, and 1 port part (0395 scheduler).
- **Build** [V]: stage 1 (plain arm64) NEGRONI DEVELOPMENT links from a clean tree with the whole series, including
  the new main patches 0347, 0387-0391, 0395, 0396: `kernel.development.negroni`, Mach-O arm64, 22,547,872 bytes,
  SHA-256 `bdfa185fb3fde380a7e007fefe962b5c711865a151164ea782ccc2bb122461aa`, "Darwin Kernel Version 25.5.0".
  Compile and link only: never run on the phone.
- **Stage 2 (arm64e)** [V, earlier]: with base 0001-0005 only, `ARCH_STRING=arm64e` linked (22,274,768 bytes,
  SHA-256 `ff1de42c0789906980f496965ca982d9824fbf89412a8b5a465eefab90c78869`). Not rebuilt with the full series yet.
- **PAC** [I]: patch 0005 makes an arm64e kernel with natively written keys (one global key set); off by default.

## 2. Scripts (`scripts/ios26/`)

| Script | What it does | State |
|---|---|---|
| `build-kernel.sh` | dxb build of xnu-12377.121.6 NEGRONI DEVELOPMENT with Xcode 27.1, own tree `out/kernel/local-ios26/`; a hook in dxb's `patches()` runs `apply-series.py` after dxb's 26.0 patches and stops the build on any unexpected result; `STAGE=prepare` stops after patching; `ARCH_STRING=arm64e` = stage 2 | [V] runs |
| `apply-series.py` | applies base + slop stage scripts + the series (slop + `patches/xnu`) with the 12377 rules; one result line per patch | [V] 0 errors |
| `patch-rules.py` | the 12377 rules (data): `RULES`, `BASE_OWNED`, `GLUE_FILES`; reads `patches/xnu-12377/skip.txt` | [V] |
| `series-tree.sh` | developer tree `out/kernel/local-ios26/work` (12377 + dxb 26.0 + series, one git commit per step); `--dev` applies a failing patch with `--reject` and names the rejected files | [V] |
| `kernel-make.sh` | developer loop: copy changed files from the work tree, `make -k` in the dxb tree, error list | [V] runs |
| `port-table.py` | section 6 table from `series-report.txt` | [V] |
| `kdk-headers.py` | headers-only KDKROOT from the remote KDK 26.5.2 (HTTP disk image), own `Kernel.h` | [V] 28 + 1 headers |
| `ios16-ref-tree.sh`, `port-file.sh` | xnu-8796 reference trees; carry one file's iOS 16 change to a 12377 tree (for base patch work) | [V] |
| `fetch-os.sh` | OS (7.4 GB AEA), SystemOS (2.0 GB AEA), AppOS cryptex + trust caches + root hashes, AEA decrypt | written, not run (needs 30 GiB free) |
| `root-macos.sh` | iOS 26 HFS+ root in the iOS 16 layout (cryptexes under `/private/preboot/Cryptexes`) | stub, refuses to run without `IOS26_ROOT_STUB_OK=1` |
| `root-tweaks.py` | iOS 16 root tweaks with their iOS 26 state (`--report`) | stub |
| `fetch-donor.sh`, `fetch-sysos.sh`, `ipsw-ls.py` | (from the research step) donor kernelcache/ADT, SystemOS cryptex, remote IPSW list | [V] earlier |

Work flow for an iOS 16 patch that fails on 12377: `scripts/ios26/series-tree.sh --dev`, read its result line and
the reject, write the smallest rule in `patch-rules.py` (or a skip line with a reason), run `series-tree.sh` until
`0 errors`, then `scripts/ios26/kernel-make.sh` (incremental) or a clean
`scripts/bg.sh ios26-kernel scripts/ios26/build-kernel.sh`. Details: `patches/xnu-12377/README.md`.

## 3. Kernel build

Command: `scripts/bg.sh ios26-kernel scripts/ios26/build-kernel.sh` (then `scripts/ios26/kernel-make.sh` for fixes).

| Step | Result |
|---|---|
| dxb helpers with Xcode 27.1 (bootstrap_cmds/mig, dtrace ctf tools, AvailabilityVersions, Libsystem + libsyscall headers, libplatform, libfirehose_kernel x86_64/arm64e/arm64) | [V] all built |
| dxb 26.0 patches on 12377.121.6 | [V] all apply except `link_kdk.patch` (our 0001 replaces it) and `remove_applefeatures_include.patch` (not needed) |
| negroni series (`apply-series.py`) | [V] 0 errors (section 6) |
| compile errors met and fixed by rules | `vm_shared_region_xnu.h` / `vm_map_internal.h` in exception.c (0043); 0066 skipped (12377 VM map range locks) |
| link / kernel.development.negroni | see 3.1 |

### 3.1 Last build result (2026-10-27 21:13, clean tree, base 0001-0005 + full series)

| Item | Value |
|---|---|
| Output | `out/kernel/local-ios26-20261027-154351/kernel.development.negroni`, link `out/kernel/kernel-ios26.macho` |
| File | Mach-O 64-bit executable arm64, 22,547,872 bytes |
| SHA-256 | `bdfa185fb3fde380a7e007fefe962b5c711865a151164ea782ccc2bb122461aa` |
| Version | `Darwin Kernel Version 25.5.0 ... xnu-12377.121.6` |
| New main patches in it | 0347 AWDL (glue), 0387 flash/torch (glue, base 0004 for NegroniPlatformExpert), 0388-0391 as is, 0395 CPU perf (glue + scheduler port part), 0396 as is [V] (`series-report.txt`; symbols `negroni_sched_placement`, `negroni_cpuperf*`, `negroni_awdl*`) |
| Reports | `patch-report.txt` (dxb), `series-report.txt` (ours) next to the kernel |
| DarwinBoot acceptance | [U] |

## 4. The 12377 base `patches/xnu-12377/` and the rules

| Patch | Contents | Source |
|---|---|---|
| `0001-non-apple-soc-base` | `machine_routines_nos.c` (functions only in KDK archives), KDK archive link only if it exists, `apple_amcc` option, Apple tunables only on Apple SoCs, no monitor/SART/UAT without `XNU_MONITOR`, 64-bit `pmap_sync_page_attributes_phys`, `-v` text console, DT panic region checks | UniXNU-ios26 (BSD-2-Clause-Patent), commit `68c5134` |
| `0002-negroni-machine-config` | NEGRONI machine config, `MASTER.arm64.negroni` (12377 MacOSX master + `nos_arm_asm nos_arm_pmap`, PPL pmap only, no CPU counters), `NEGRONI.h` for SM8450, stage 1 arm64 / stage 2 arm64e switch | slop 0004, 0006 reworked |
| `0003-negroni-machine-layer` | GICv3 Group 1 IRQs, SPI dispatch, start.s (PSCI entry, early marks), SMP/cluster ids, no CNTP write, PoC cleans for secondaries, CPU idle, MMIO try accessors | slop 0004/0010/0017/0065/0078/0082-0086, ours 0288/0295/0297/0382/0383 |
| `0004-negroni-platform-console` | NegroniPlatformExpert, NegroniCPU, framebuffer console, console tee/mute, panic hooks, no IORTC wait, no kernelmanagerd hold, NEGRONI TOP, weak default driver hooks | slop 0003/0016/0018/0043/0047/0067/0088, ours 0200/0360/0367/0382 |
| `0005-negroni-native-pac` | stage 2: arm64e kernel, `HAS_NATIVE_ARM_PAC` key writes in `PAC_INIT_KEY_STATE`, one global key set | new (replaces slop 0005) |
| `skip.txt` | 39 lines, one reason each | |
| `parts/0395-negroni-cpuperf.patch` | 12377 scheduler port of 0395 (`choose_processor` idle choice from `idle_map`, hint check, realtime choice in `sched_rt.c`) | port of patches/xnu/0395 |

The base owns the files it ports (`BASE_OWNED` in `patch-rules.py`, 35 files: machine layer, console,
NegroniPlatformExpert/NegroniCPU, master config). A series patch that changes one of them and is not listed there
is an error, so a new iOS 16 change to those files cannot be lost silently: it must be ported into the base patch.

## 5. Port state per family

Compile level only [V]; nothing ran on the phone. Effort marks are [I].

| Family | iOS 26 state | Next work |
|---|---|---|
| Build glue (`*/conf/files*`, `KernelConfigTables.cpp`) | applied by the glue rule / as text | none |
| Machine layer, console, PAC | base 0001-0005 | boot test T1 |
| SoC drivers (UFS, keys, touch, USB/ECM, ADSP/audio, Wi-Fi, BT, battery/charger, thermal, cpufreq, camera, haptics, fingerprint, DSI/DPU, Adreno, flash, AWDL) | iOS 16 patches as is (+ `vm_kern_xnu.h`), compile + link [V] | phone runs |
| IOKit drivers (Framebuffer, Surface, GPU, HID, Battery, Vibrator, WLAN, Watchdog, KeyStore) | iOS 16 patches as is, compile + link [V] | user-client ABIs of the iOS 26 userland (IOSurface 393.5.7, IOMobileGraphicsFamily 343.0.0, AKS) |
| Core hooks (exec/exit/crash logging, sysctl identity, sandbox, AMFI, trust cache, mockfs, UFS root) | applied (some with context rules), compile + link [V] | AMFI needs a CoreEntitlements V2 table for 12377 `ubc_subr.c`; behaviour untested |
| Crypto (BearSSL 0020/0023/0027/0032/0033) | applied + BearSSL stage, compile [V] | 0013/0014 open (12377 corecrypto KPI v14; UniXNU source corecrypto) |
| pthread (0019 + stage) | open | UniXNU `build-pthread-12377.py` + libpthread-539 |
| HFS (0026 + stage, 0041, 0204; HFS hunks of 0031/0362) | open | stage the HFS tag of macOS 26.5 |
| Scheduler (0395) | port part [V compile] | placement test on the phone |
| Diagnostics 0066 (crash fault region), 0362 (KMEM report) | open | rewrite for 12377 VM range locks / kmem ranges |

## 6. Per-patch table (negroni series on xnu-12377.121.6)

Regenerate: `scripts/ios26/port-table.py out/kernel/local-ios26-<UTC>/series-report.txt`. `applied+rules(N)` lists the
rule kinds: `glue` (build lists), `vm_kern_xnu.h`, `base 000N` (hunks for a base-owned file dropped), `sub`,
`rename_file`, `drop_file`, `insert_after`, `port`.

Result: series: 154 applied, 96 applied+rules, 0 replaced, 39 skipped, 0 errors

| Patch | 12377 result | Rules / reason |
|---|---|---|
| `0001-non-apple-soc-base.patch` | base |  |
| `0002-negroni-machine-config.patch` | base |  |
| `0003-negroni-machine-layer.patch` | base |  |
| `0004-negroni-platform-console.patch` | base |  |
| `0005-negroni-native-pac.patch` | base |  |
| `0019-stage-libpthread.sh` | skipped | open: libpthread-514 is the xnu-8796 pair; 12377 needs libpthread-539 and its callback ABI |
| `0020-stage-bearssl.sh` | ran |  |
| `0026-stage-hfs.sh` | skipped | open: hfs-627 is the xnu-8796 pair; the hfs tag of macos-265 must be staged |
| `0001-new-clang-drop-removed-auto-var-init-flag.patch` | skipped | upstream: 12377 makedefs no longer pass the removed auto-var-init flag |
| `0002-new-clang-backport-UIO_STACKBUF.patch` | skipped | not needed: 12377 + dxb 26.0 build with Xcode 27.1 without it |
| `0003-negroni-framebuffer-serial-console.patch` | skipped | in 12377 base 0003/0004 (pe_serial.c fbcon outside PL011_UART, protos.h) |
| `0004-negroni-machine-config.patch` | skipped | in 12377 base 0002/0003 (machine config, GIC, start.s, sleh.c, pe_fiq.c) |
| `0005-non-pac-build-fixes.patch` | skipped | not needed: 12377 base 0005 builds PAC natively (stage 2) or plain arm64 (stage 1) |
| `0006-negroni-master-config-open-source-asm-pmap.patch` | skipped | in 12377 base 0002 (MASTER.arm64.negroni from the 12377 MacOSX master) |
| `0007-negroni-stub-apple-internal-headers.patch` | skipped | not needed: 12377 + base 0001 (UniXNU) build without the stub headers; 12377 task.c has no t_kpc |
| `0008-negroni-fill-closed-lib-gaps-kpc-stub.patch` | skipped | in 12377 base 0001 (machine_routines_nos.c; 12377 has kpc.c, amcc via apple_amcc) |
| `0009-negroni-drop-apple-soc-only-exports.patch` | skipped | in 12377 base 0002 (12377 export lists) |
| `0010-negroni-early-framebuffer-debug.patch` | skipped | in 12377 base 0003 (start.s band, negroni_early.c, arm_vm_init.c) |
| `0011-negroni-physmap-alignment-padding.patch` | skipped | in 12377 base 0003 (arm_vm_init.c) |
| `0012-negroni-keep-debug-console-after-ttbr0.patch` | skipped | in 12377 base 0003/0004 (negroni_early.c, pe_serial.c) |
| `0013-negroni-kmem-rng-without-corecrypto.patch` | skipped | open: 12377 crypto init differs (corecrypto KPI v14); port UniXNU source corecrypto instead |
| `0014-negroni-kernel-hmac-prng.patch` | skipped | open: same as 0013 (12377 entropy.c/prng_random.c) |
| `0015-negroni-unavailable-trust-cache-runtime.patch` | applied+rules(1) | sub |
| `0016-negroni-device-tree-platform-expert.patch` | skipped | in 12377 base 0004 (NegroniPlatformExpert) |
| `0017-negroni-device-tree-virtual-timer-irq.patch` | skipped | in 12377 base 0003 (pe_fiq.c vtimer INTID from the ADT) |
| `0018-negroni-boot-cpu-driver.patch` | skipped | in 12377 base 0004 (NegroniCPU) |
| `0019-negroni-builtin-pthread.patch` | skipped | open: needs the 12377 pthread stage (see 0019-stage-libpthread.sh) |
| `0020-negroni-portable-aes-cbc.patch` | applied+rules(1) | glue |
| `0021-negroni-mockfs-ramdisk-root.patch` | applied+rules(1) | base 0004 |
| `0022-negroni-ramdisk-root-without-iomedia.patch` | skipped | in 12377 base 0004 (IOService.cpp) |
| `0023-negroni-builtin-sha256-for-libkern.patch` | applied |  |
| `0024-negroni-mockfs-virtual-ramdisk-io.patch` | applied |  |
| `0025-negroni-builtin-amfi-no-entitlements.patch` | applied+rules(1) | glue |
| `0026-negroni-builtin-hfs.patch` | skipped | open: needs the 12377 HFS stage (see 0026-stage-hfs.sh) |
| `0027-negroni-bearssl-md5.patch` | applied+rules(1) | glue |
| `0028-negroni-ufs-root-device.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0029-negroni-unsealed-root-volume.patch` | applied |  |
| `0030-negroni-ufs-writes.patch` | applied |  |
| `0031-negroni-read-write-root.patch` | applied+rules(1) | drop_file |
| `0032-negroni-bearssl-sha1.patch` | applied+rules(1) | glue |
| `0033-negroni-bearssl-sha384-sha512.patch` | applied+rules(1) | glue |
| `0034-negroni-ufs-dma-above-4g.patch` | applied |  |
| `0035-negroni-amfi-entitlements-platform-binaries.patch` | applied+rules(2) | glue, sub |
| `0036-negroni-amfi-cs-signed.patch` | applied |  |
| `0037-negroni-config-bindfs.patch` | applied+rules(1) | sub |
| `0038-negroni-applekeystore.patch` | applied+rules(1) | glue |
| `0039-negroni-coredump-default-off.patch` | applied+rules(1) | sub |
| `0040-negroni-iowatchdog.patch` | applied+rules(1) | glue |
| `0041-negroni-hfs-link-notes.patch` | skipped | open: HFS only (bsd/negroni_hfs); waits for the 12377 HFS stage |
| `0042-negroni-short-exec-log.patch` | applied |  |
| `0043-negroni-console-crash-log.patch` | applied+rules(3) | insert_after, sub |
| `0044-negroni-crash-log-reason.patch` | applied |  |
| `0045-negroni-iowatchdog-pmu-primary.patch` | applied |  |
| `0046-negroni-iosurface-iomfb.patch` | applied+rules(2) | base 0004, glue |
| `0047-negroni-persistent-console-log.patch` | applied+rules(1) | base 0004 |
| `0048-negroni-devnull-tee.patch` | applied |  |
| `0049-negroni-iokit-trace.patch` | applied |  |
| `0050-negroni-sandbox-policy.patch` | applied |  |
| `0051-negroni-crash-heap-strings.patch` | applied |  |
| `0052-negroni-hfs-rename-swap.patch` | applied |  |
| `0053-negroni-crash-scan-springboard.patch` | applied |  |
| `0054-negroni-process-sampler.patch` | applied+rules(1) | glue |
| `0055-negroni-aks-ext-state-sampler-depth.patch` | applied |  |
| `0056-negroni-fb-throttled-present.patch` | applied |  |
| `0057-negroni-no-ext-resolver.patch` | applied+rules(1) | sub |
| `0058-negroni-hid-event-services.patch` | applied+rules(1) | glue |
| `0059-negroni-iphone-identity.patch` | applied+rules(1) | base 0004 |
| `0060-negroni-keys-touch-drivers.patch` | applied+rules(1) | glue |
| `0061-negroni-iphone-x-display-size.patch` | applied |  |
| `0062-negroni-touch-power-battery.patch` | applied+rules(1) | glue |
| `0063-negroni-goodix-geni-packing.patch` | applied |  |
| `0064-negroni-priv-work-interval.patch` | applied |  |
| `0065-negroni-smp-psci.patch` | skipped | in 12377 base 0003/0004 (start.s PSCI entry, NegroniCPU) |
| `0066-negroni-crash-fault-region.patch` | skipped | open: 12377 VM map uses range locks (no vm_map_lock_read/vm_map_lookup_entry); the fault-region crash line needs a rewrite |
| `0067-negroni-console-mute.patch` | applied+rules(1) | base 0004 |
| `0068-negroni-surface-lookup-cached.patch` | applied |  |
| `0069-negroni-ufs-faster.patch` | applied |  |
| `0070-negroni-pid-hibernate.patch` | applied+rules(2) | rename_file, sub |
| `0071-negroni-touch-edge.patch` | applied |  |
| `0072-negroni-usb-probe.patch` | applied+rules(1) | glue |
| `0073-negroni-usb-device-ep0.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0074-negroni-usb-vbus-override.patch` | applied |  |
| `0075-negroni-usb-ecm.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0076-negroni-usb-rx-mbuf.patch` | applied |  |
| `0077-negroni-usb-live-log.patch` | applied |  |
| `0078-negroni-smp-8-cores.patch` | skipped | in 12377 base 0003/0004 (8 cores) |
| `0079-negroni-display-power.patch` | applied |  |
| `0080-negroni-net-trace.patch` | applied+rules(1) | sub |
| `0081-negroni-usb-link-state.patch` | applied |  |
| `0082-negroni-gicr-stride-from-adt.patch` | skipped | in 12377 base 0003 (pe_fiq.c) |
| `0083-negroni-no-physical-timer-write.patch` | skipped | in 12377 base 0003 (machine_routines.c) |
| `0084-negroni-irq-trace.patch` | skipped | in 12377 base 0003 (sleh.c) |
| `0085-negroni-kernel-thread-backtraces.patch` | skipped | in 12377 base 0003 (sleh.c) |
| `0086-negroni-bt-short-lines.patch` | skipped | in 12377 base 0003 (sleh.c) |
| `0087-negroni-sm8450-keys.patch` | applied |  |
| `0088-negroni-framebuffer-1080x2412.patch` | applied+rules(3) | base 0003 |
| `0089-negroni-ufs-power-no-battery.patch` | applied |  |
| `0090-negroni-ufs-sense-start-unit.patch` | applied |  |
| `0091-negroni-quiet-keys-cpu-probe.patch` | applied+rules(1) | base 0004 |
| `0092-negroni-ufs-wlun-active.patch` | applied |  |
| `0093-negroni-s3908-touch-gpio-i2c.patch` | applied |  |
| `0094-negroni-trace-boot-arg.patch` | skipped | in 12377 base 0003 (sleh.c) |
| `0095-negroni-hid-touch-log-boot-arg.patch` | applied |  |
| `0096-negroni-cpufreq-epss.patch` | applied+rules(1) | glue |
| `0097-negroni-adreno-ladder-read.patch` | applied+rules(1) | glue |
| `0098-negroni-cpufreq-never-lower.patch` | applied |  |
| `0099-negroni-adreno-cx-power-clocks.patch` | applied |  |
| `0100-negroni-gpu-status-badge.patch` | applied |  |
| `0101-negroni-adreno-rscc-smmu-read.patch` | applied |  |
| `0102-negroni-adreno-gmu-memory-trustzone.patch` | applied |  |
| `0103-negroni-firmware-area.patch` | applied |  |
| `0104-negroni-adreno-zap-signature.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0105-negroni-adreno-gmu-space-firmware.patch` | applied |  |
| `0106-negroni-wifi-survey.patch` | applied+rules(1) | glue |
| `0107-negroni-fb-shift-probe-menu.patch` | applied |  |
| `0108-negroni-adreno-gmu-start-hfi.patch` | applied |  |
| `0109-negroni-wifi-cmd-db-direct.patch` | applied |  |
| `0110-negroni-adreno-hfi-messages.patch` | applied |  |
| `0111-negroni-adreno-to-first-frame.patch` | applied+rules(1) | sub |
| `0112-negroni-fb-clock-shift.patch` | applied |  |
| `0113-negroni-adreno-initial-perf-vote.patch` | applied |  |
| `0114-negroni-fb-clock-shift-fill.patch` | applied |  |
| `0115-negroni-adreno-zap-segments.patch` | applied |  |
| `0116-negroni-badge-opt-in.patch` | applied |  |
| `0117-negroni-adreno-stop.patch` | applied |  |
| `0118-negroni-gpu-service.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0119-negroni-usb-sm8450.patch` | applied |  |
| `0120-negroni-wifi-pcie-link.patch` | applied |  |
| `0121-negroni-gpu-watch-panic-log.patch` | applied+rules(2) | base 0003, vm_kern_xnu.h |
| `0122-negroni-gpu-service-optional.patch` | applied |  |
| `0122-negroni-wifi-supply-votes.patch` | applied |  |
| `0123-negroni-gpu-service-trace.patch` | applied |  |
| `0124-negroni-gpu-service-personality.patch` | applied |  |
| `0125-negroni-wifi-rails-xo-slave.patch` | applied |  |
| `0126-negroni-pmap-sync-page-64bit.patch` | skipped | in 12377 base 0001 (UniXNU pmap sync 64-bit PA) |
| `0200-negroni-no-rtc-wait.patch` | skipped | in 12377 base 0004 (IOStartIOKit.cpp) |
| `0201-negroni-empty-ioacceleratores.patch` | applied+rules(1) | glue |
| `0202-negroni-iokit-quiet.patch` | skipped | in 12377 base 0004 (IOService.cpp, IOStartIOKit.cpp) |
| `0203-negroni-calendar.patch` | applied+rules(3) | base 0004, glue |
| `0204-negroni-hfs-clonefile.patch` | skipped | open: HFS only (bsd/negroni_hfs); waits for the 12377 HFS stage |
| `0205-negroni-accel-plugins.patch` | applied |  |
| `0210-negroni-usb-command-server.patch` | applied+rules(1) | glue |
| `0211-negroni-power-off.patch` | applied+rules(1) | base 0004 |
| `0212-negroni-usb-settime.patch` | applied |  |
| `0213-negroni-reboot-mode.patch` | applied+rules(1) | base 0004 |
| `0214-negroni-pon-ps-hold-type.patch` | applied |  |
| `0220-negroni-aks-no-passcode.patch` | applied |  |
| `0221-negroni-aks-passcode.patch` | applied |  |
| `0221-negroni-amfi-policy.patch` | applied+rules(1) | glue |
| `0222-negroni-sandbox-privileges.patch` | applied |  |
| `0223-negroni-sandbox-appex-container.patch` | applied |  |
| `0230-negroni-gpu-surface-import.patch` | applied |  |
| `0231-negroni-gpu-present.patch` | applied+rules(1) | glue |
| `0232-negroni-gpu-host-import.patch` | applied |  |
| `0233-negroni-gpu-per-client-va.patch` | applied |  |
| `0234-negroni-fb-zero-copy.patch` | applied+rules(1) | base 0004 |
| `0235-negroni-gpu-level.patch` | applied |  |
| `0236-negroni-gpu-clock-probe.patch` | applied |  |
| `0237-negroni-gpu-perf-table-khz.patch` | applied |  |
| `0240-negroni-adsp-boot.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0241-negroni-adsp-pas-supported-note.patch` | applied |  |
| `0242-negroni-adsp-glink.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0243-negroni-audio-stage-b.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0244-negroni-audio-amp-tfa9874.patch` | applied+rules(3) | base 0004, glue, vm_kern_xnu.h |
| `0245-negroni-audio-test-tone.patch` | applied |  |
| `0246-negroni-audio-earpiece-route.patch` | applied |  |
| `0247-negroni-audio-graph-mainline.patch` | applied |  |
| `0248-negroni-adsp-crash-watch.patch` | applied |  |
| `0249-negroni-audio-smmu-s1.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0250-negroni-panel-brightness.patch` | applied+rules(1) | glue |
| `0251-negroni-display-sleep.patch` | applied |  |
| `0252-negroni-fb-stats.patch` | applied |  |
| `0253-negroni-fb-display-refresh.patch` | applied |  |
| `0254-negroni-fb-present-thread.patch` | applied |  |
| `0255-negroni-mmio-accessors.patch` | applied |  |
| `0256-negroni-fb-clock-shift-after-gpu.patch` | applied |  |
| `0257-negroni-iosurface-wrap-client-memory.patch` | applied |  |
| `0258-negroni-display-sleep-sequence.patch` | applied |  |
| `0259-negroni-display-te-vrr.patch` | applied |  |
| `0260-negroni-wlan-pcie-inventory.patch` | applied |  |
| `0261-negroni-wlan-mhi-fw.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0262-negroni-wlan-power-up.patch` | applied |  |
| `0263-negroni-wlan-stages.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0264-negroni-wlan-ipcr-rings.patch` | applied |  |
| `0265-negroni-wlan-qrtr.patch` | applied+rules(1) | glue |
| `0266-negroni-wlan-qmi-wlfw.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0267-negroni-fb-vsync-after-frame-clock-copy.patch` | applied |  |
| `0268-negroni-panel-wake-on-command.patch` | applied |  |
| `0269-negroni-fb-double-buffer.patch` | applied |  |
| `0270-negroni-battery-spmi-v7.patch` | applied |  |
| `0271-negroni-battery-service.patch` | applied |  |
| `0272-negroni-battery-charger-input.patch` | applied |  |
| `0273-negroni-charger-debug-arbiter.patch` | applied |  |
| `0274-negroni-charger-glink.patch` | applied+rules(1) | glue |
| `0275-negroni-display-off-fast.patch` | applied |  |
| `0276-negroni-battery-soc-source.patch` | applied |  |
| `0277-negroni-charger-loop.patch` | applied |  |
| `0278-negroni-battery-persist-temp.patch` | applied+rules(1) | glue |
| `0280-negroni-thermal-tsens.patch` | applied+rules(1) | glue |
| `0281-negroni-gpu-dcvs.patch` | applied |  |
| `0282-negroni-usb-reset-reconfigure.patch` | applied |  |
| `0283-negroni-thermal-trips.patch` | applied |  |
| `0284-negroni-cpufreq-governor.patch` | applied |  |
| `0285-negroni-gpu-power-collapse.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0286-negroni-gpu-dcvs-ui-floor.patch` | applied |  |
| `0287-negroni-gpu-hang-recovery.patch` | applied |  |
| `0288-negroni-cpu-idle-psci.patch` | skipped | in 12377 base 0003 (negroni_cpuidle.c, cpu.c, sleh.c, pe_fiq.c) |
| `0289-negroni-iosurface-lock-gpu-wait.patch` | applied |  |
| `0290-negroni-io-submap.patch` | applied |  |
| `0291-negroni-cpufreq-floor-lut.patch` | applied |  |
| `0292-negroni-dsi-cmd-dma-batch.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0293-negroni-dsi-read-esd.patch` | applied |  |
| `0294-negroni-te-rate-tearcheck.patch` | applied+rules(1) | glue |
| `0295-negroni-te-irq.patch` | applied+rules(2) | base 0003 |
| `0296-negroni-dpu-idle-power.patch` | applied |  |
| `0297-negroni-mmio-try.patch` | applied+rules(1) | base 0003 |
| `0298-negroni-gpu-kgsl-parity.patch` | applied |  |
| `0300-negroni-haptic-direct-play.patch` | applied+rules(1) | glue |
| `0301-negroni-vibrator-service.patch` | applied+rules(1) | glue |
| `0302-negroni-haptic-ui-actuator.patch` | applied+rules(1) | glue |
| `0303-negroni-haptic-brake-hboost-wait.patch` | applied |  |
| `0310-negroni-cam-camcc-cci.patch` | applied+rules(1) | glue |
| `0311-negroni-cam-imx789-chip-id.patch` | applied |  |
| `0312-negroni-cam-cpas-smmu-votes.patch` | applied |  |
| `0313-negroni-cam-clocks-csiphy.patch` | applied |  |
| `0314-negroni-cam-imx789-stream.patch` | applied |  |
| `0315-negroni-cam-csid-ife-rdi.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0316-negroni-cam-icp-pas-hfi.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0317-negroni-cam-smmu-s1.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0318-negroni-cam-ios-stream.patch` | applied |  |
| `0320-negroni-wlan-cfg-mode.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0321-negroni-wlan-ce.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0322-negroni-wlan-htc-wmi.patch` | applied+rules(1) | glue |
| `0323-negroni-wlan-scan.patch` | applied |  |
| `0324-negroni-wlan-smmu.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0325-negroni-wlan-smmu3-default.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0326-negroni-wlan-api.patch` | applied+rules(1) | glue |
| `0327-negroni-wlan-join-open.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0328-negroni-wlan-htt-dp.patch` | applied |  |
| `0329-negroni-wlan-wpa2-psk.patch` | applied+rules(1) | glue |
| `0330-negroni-bt-uart-power.patch` | applied+rules(1) | glue |
| `0331-negroni-bt-hci.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0332-negroni-bt-h4-transport.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0333-negroni-bt-hci-shim.patch` | applied |  |
| `0334-negroni-bt-qup-clocks.patch` | applied |  |
| `0335-negroni-bt-power-follows-client.patch` | applied |  |
| `0336-negroni-bt-init-fixes.patch` | applied |  |
| `0337-negroni-bt-vendor-answers.patch` | applied |  |
| `0338-negroni-bt-le-legacy-to-extended.patch` | applied |  |
| `0339-negroni-wlan-sbl-boot-dump.patch` | applied |  |
| `0340-negroni-wlan-ios-iface.patch` | applied+rules(1) | glue |
| `0341-negroni-apple80211.patch` | applied+rules(1) | glue |
| `0342-negroni-wlan-ath11k-sw-reset.patch` | applied |  |
| `0343-negroni-wlan-boot-dump-pcie.patch` | applied |  |
| `0344-negroni-wlan-msi-mailbox.patch` | applied |  |
| `0345-negroni-apple80211-scan-join.patch` | applied |  |
| `0347-negroni-awdl.patch` | applied+rules(1) | glue |
| `0350-negroni-fingerprint-stage-a.patch` | applied+rules(1) | glue |
| `0351-negroni-fingerprint-highlight.patch` | applied |  |
| `0352-negroni-fingerprint-mcu-frames.patch` | applied |  |
| `0353-negroni-fingerprint-capture.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0354-negroni-fp-qup-clocks-highlight.patch` | applied+rules(1) | vm_kern_xnu.h |
| `0360-negroni-panic-usb.patch` | applied+rules(1) | base 0004 |
| `0361-negroni-usb-throughput.patch` | applied |  |
| `0362-negroni-kmem-report.patch` | skipped | open: 12377 kmem ranges differ (no kmem_large_ranges/sprayqtn split; kalloc_large reworked); the KMEM report needs a rewrite |
| `0363-negroni-boot-line-1024.patch` | skipped | not needed: 12377 BOOT_LINE_LENGTH is already 1024 |
| `0364-negroni-fb-timing-modes.patch` | applied |  |
| `0365-negroni-battery-charging-ui.patch` | applied |  |
| `0366-negroni-usb-reconnect.patch` | applied |  |
| `0367-negroni-bootlog.patch` | applied+rules(1) | base 0004 |
| `0368-negroni-usb-adsp-phy.patch` | applied |  |
| `0369-negroni-charger-vooc.patch` | applied |  |
| `0370-negroni-charger-write-bisect.patch` | applied |  |
| `0371-negroni-usb-lost-reboot.patch` | applied |  |
| `0372-negroni-usb-phy-rails.patch` | applied |  |
| `0373-negroni-charger-ulog.patch` | applied |  |
| `0374-negroni-typec-sink.patch` | applied |  |
| `0375-negroni-usb-idle-reboot.patch` | applied |  |
| `0376-negroni-slpi-start.patch` | applied+rules(2) | glue, vm_kern_xnu.h |
| `0377-negroni-charge-mode.patch` | applied+rules(2) | glue, sub |
| `0378-negroni-bootargs-truncate.patch` | applied |  |
| `0379-negroni-smmu-s1-readback-fields.patch` | applied |  |
| `0381-negroni-usb-datafix.patch` | applied |  |
| `0382-negroni-power-idle.patch` | applied+rules(3) | base 0003, base 0004 |
| `0383-negroni-cpuidle-cluster-rpmh-sleep.patch` | applied+rules(1) | base 0003 |
| `0384-negroni-gpu-governor-irq.patch` | applied |  |
| `0385-negroni-usb-phy-gate.patch` | applied |  |
| `0386-negroni-sandbox-extensions.patch` | applied |  |
| `0387-negroni-flash-torch.patch` | applied+rules(2) | base 0004, glue |
| `0388-negroni-fb-display-pipe-dicts.patch` | applied |  |
| `0389-negroni-gpu-frame-pace.patch` | applied |  |
| `0390-negroni-iosurface-plane-bpr.patch` | applied |  |
| `0391-negroni-fb-clock-band.patch` | applied |  |
| `0395-negroni-cpuperf.patch` | applied+rules(2) | glue, port |
| `0396-negroni-wlan-scan-joined.patch` | applied |  |

## 7. PAC / arm64e plan

- [V] The open-source xnu has PAC key code only for the paravirtual VMAPPLE (`hvc`); Apple SoCs set their keys in the
  closed KernelSupport archives. So the arm64e kernel needs our own key code: patch 0005.
- [I] One global key set (EL0 = EL1 keys) first: `SET_JOP/ROP_KEY_REGISTERS` stay empty like every non-paravirtual
  open-source config. Per-process B keys later (save/restore on context switch, like Linux `ptrauth_keys_install_user`).
- [U] Gunyah must let EL1 write `AP*Key*_EL1` (HCR_EL2.APK) and execute PAC instructions (HCR_EL2.API). Android shows
  `paca pacg` in `/proc/cpuinfo`, and Linux at EL1 writes the keys, so this is expected to work [I].
- [U] The shared region: 12377 rebases auth pointers in `vm_shared_region` slide (slide info v5) with the kernel's
  `ptrauth` helpers; with global keys these signatures are valid in every process [I].
- [V] AMX: 12377 `osfmk/arm/cpuid.c` gives `CPUFAMILY_UNKNOWN` for ARM Ltd. parts it does not list (X2/A710/A510
  are not listed), so `hw.cpufamily` does not say "A13". [U] whether Accelerate also looks at the ADT/MobileGestalt
  identity (iPhone12,3) to pick AMX code.

## 8. Userland plan

| Item | iOS 16 port | iOS 26 plan | State |
|---|---|---|---|
| Donor | iPhone X D22AP, 20H392 | iPhone 11 Pro D421AP (`iPhone12,3`), 26.5.2 23F84, IPSW `iPhone12,3,iPhone12,5_26.5.2_23F84_Restore.ipsw` | [V] future-ios26.md |
| OS image | `087-86698-044.dmg` UDIF | `094-55352-108.dmg.aea` 7.4 GB (AEA, key from Apple's public key service) | `fetch-os.sh` written [V] member names from BuildManifest |
| SystemOS cryptex | raw APFS | `094-55541-109.dmg.aea` 2.0 GB, decrypted 5.2 GB [V] | `fetch-sysos.sh` [V] |
| AppOS cryptex | raw APFS | `094-54871-112.dmg` 14 MB, plain [V] | `fetch-os.sh` |
| Trust caches | static + cryptex | `StaticTrustCache` 83 KB, `Cryptex1,SystemTrustCache`, `Cryptex1,AppTrustCache` [V] | loaded by DarwinBoot/ADT as today [I]; or our AMFI accepts everything (iOS 16 model) |
| Root layout | HFS+ on userdata, cryptexes in `/private/preboot/Cryptexes` | same [I] | `root-macos.sh` stub |
| dyld shared cache | arm64e cache on iOS 16 already (A11 iPhone X used arm64) | `dyld_shared_cache_arm64e` + 83 subcaches, slide info v5 [V]: **needs the arm64e kernel** (stage 2) | blocked on 0005 test |
| Root tweaks | `root-tweaks-extra.py` (9 launchd removals, prefs, jetsam, InterfaceNamer) | each item re-checked on 26 (`root-tweaks.py --report`) | stub |
| AMFI | slop builtin AMFI: every binary allowed | same policy; 12377 also wants a CoreEntitlements V2 implementation (`CEKernelAPI_t`) for entitlement queries (`ubc_subr.c`) | not started |
| AKS emulation | `NegroniKeyStore.cpp` (selectors 7, 10, 11, 17, 23, 31, 40, 100-103, 115) | re-trace the iOS 26 `AppleKeyStore` userland calls | not started |
| GL / Metal | Mesa freedreno + EAGL shim; metal2vulkan | QuartzCore 26 still has GLES/SW renderers [V]; all our dylibs must be rebuilt for arm64e | not started |

A RAM-disk root (mockfs, slop 0021-0024) is the way to test the iOS 26 userland without writing userdata: the
iOS 16 root stays on userdata (section "Boot plan").

## 9. Blockers (most severe first)

1. **arm64e on Cortex under Gunyah** [U]: patch 0005 compiles only in stage 2; never run.
2. **CoreEntitlements V2 implementation** [I]: 12377 calls `libCoreEntitlements->...` from `ubc_subr.c` and the PPL
   `pmap.c`; Apple's implementation is in the closed AMFI kext. Our AMFI must give one (a DER entitlement parser), or
   those paths must be cut. iOS 16 had no such table.
3. **Crypto and pthread** [I]: the iOS 16 BearSSL/HMAC-PRNG and libpthread-514 patches do not fit 12377; UniXNU-ios26
   has working 12377 versions (source corecrypto, libpthread-539) to port.
4. **User-client ABIs** (IOSurface, IOMFB, AKS, Sandbox) [U]: re-trace against the 23F84 shared cache (needs the
   SystemOS image again: 13 GiB free, the Mac has 12-13 GiB).
5. **Disk** [V]: 12-13 GiB free; the OS image (7.4 GB AEA, larger decrypted) cannot be fetched on this Mac now.

## 10. Next steps

1. Boot-image wrapper (`KERNEL=` override for `scripts/ios16/build.sh` into `out/ios26-t1`) for test T1.
2. First phone test (T1, RAM boot) with the USB live log (`negroni_usb.c`, now from the series as on iOS 16).
3. Stage 2 compile with the full series (`ARCH_STRING=arm64e scripts/ios26/build-kernel.sh`).
4. The 10 open skips: crypto 0013/0014 and pthread 0019 from UniXNU-ios26; HFS with the HFS tag of macOS 26.5;
   0066/0362 diagnostics for the 12377 VM.
5. AMFI with a CoreEntitlements V2 table.
6. User-client ABI families against the 23F84 shared cache.

## Licenses

`patches/xnu-12377/0001-non-apple-soc-base.patch` and `scripts/ios26/kdk-headers.py` contain code from UniXNU-ios26,
Copyright (c) 2026, UniXNU contributors, BSD-2-Clause-Patent. The full license text is in
[../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) section 1. xnu changes are under the APSL 2.0 like the iOS 16
patches. No Apple file (KDK headers, IPSW parts, kernelcache) is in git: they stay in `out/` and `~/op10-apple/`.
