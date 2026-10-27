# iOS 26 port status (kernel xnu-12377.121.6, donor userland iOS 26.5.2 23F84 iPhone12,3)

Date: 2026-10-27. Branch `ios26-prep` (local only). No phone access in this work: every result here is a host
result. Background and donor choice: [future-ios26.md](future-ios26.md). Boot test order for later:
[ios26-boot-plan.md](ios26-boot-plan.md).

Marks: **[V]** verified here (command output, file, build log). **[I]** inference. **[U]** unknown.

## 1. Summary

- **Toolchain** [V]: Xcode 27.1 (27A9275, `/Applications/Xcode.app`), MacOSX27.0 SDK, darwin-xnu-build (dxb) at the
  iOS 16 pin `663906528d1c` with `MACOS_VERSION=26.5` (xnu tag from `distribution-macOS/macos-265`). No new Xcode and
  no full KDK download.
- **KDK** [V]: xnu-12377 needs CoreEntitlements V2 / TrustCache / CodeSignature / TrustedExecutionMonitor headers
  that are only in a Kernel Debug Kit. The installed SDKs have none of them (only `libCoreEntitlements*.tbd` in the
  other platforms). `scripts/ios26/kdk-headers.py` attaches the KDK 26.5.2 (25F84) disk image **over HTTP**
  (`hdiutil attach https://...`, range reads) and takes the 28 headers of the 140 KB `KDK_SDK.pkg` payload. The last
  header, `KernelSupport/CoreEntitlements/V2/Kernel.h` (`CEKernelAPI_t`), is inside the 1.1 GB `KDK.pkg` payload; the
  script writes our own version from the V2 prototypes (43 members, `__typeof__` of each CE* function). That is
  enough because only our AMFI stand-in will fill the table (never Apple's AMFI kext).
- **Our series `patches/xnu-12377/`** [V]: 5 patches (0001-0005), applied by dxb after its own 26.0 patches.
- **Build** [V]: see section 3 (result of the last run).
- **iOS 16 stack on 12377** [V]: `scripts/ios26/patch-check.sh` puts all 283 iOS 16 kernel patches (slop 0001-0126
  + 3 stage scripts + ours 0200-0385) on 12377 in the iOS 16 order: 1 upstream, 240 apply as text, 33 partial,
  4 fail, 3 stage scripts. "Applies as text" does not mean "compiles": the core-hook families need rework (section 5).
- **PAC** [I]: patch 0005 makes an arm64e kernel with natively written keys (one global key set); off by default.

## 2. Scripts (all new, `scripts/ios26/`)

| Script | What it does | State |
|---|---|---|
| `build-kernel.sh` | dxb build of xnu-12377.121.6 NEGRONI DEVELOPMENT with Xcode 27.1, own tree `out/kernel/local-ios26/`, our series copied as `zz-*`; `STAGE=prepare` stops after patching; `ARCH_STRING=arm64e` = stage 2 | [V] runs |
| `kernel-make.sh` | developer loop: copy changed files from the work tree, `make -k` in the dxb tree, error list | [V] runs |
| `kdk-headers.py` | headers-only KDKROOT from the remote KDK 26.5.2 (HTTP disk image), own `Kernel.h` | [V] 28 + 1 headers. The HTTP mount hung twice when a stale `diskimages-helper` was left over from a killed run, and once inside tmux; a clean foreground run worked |
| `ios16-ref-tree.sh` | xnu-8796 pristine + negroni-only tree (slop stage scripts + slop patches + patches/xnu; no dxb patches) | [V] 278 applied, 0 skipped |
| `port-file.sh` | carries one file's iOS 16 change (8796 pristine -> negroni) to the 12377 work tree; copies new files | [V] |
| `patch-check.sh` | text check of the whole iOS 16 stack on 12377 (cumulative, best effort), `patch-check.tsv` | [V] |
| `port-table.py` | section 6 table from `patch-check.tsv` + the hand-kept state map | [V] |
| `fetch-os.sh` | OS (7.4 GB AEA), SystemOS (2.0 GB AEA), AppOS cryptex + trust caches + root hashes, AEA decrypt | written, not run (needs 30 GiB free) |
| `root-macos.sh` | iOS 26 HFS+ root in the iOS 16 layout (cryptexes under `/private/preboot/Cryptexes`) | stub, refuses to run without `IOS26_ROOT_STUB_OK=1` |
| `root-tweaks.py` | iOS 16 root tweaks with their iOS 26 state (`--report`) | stub |
| `fetch-donor.sh`, `fetch-sysos.sh`, `ipsw-ls.py` | (from the research step) donor kernelcache/ADT, SystemOS cryptex, remote IPSW list | [V] earlier |

Work flow for a new patch: `scripts/ios26/ios16-ref-tree.sh` (once), make the change in the git work tree
`out/kernel/local-ios26/work` (one commit per patch, `scripts/ios26/port-file.sh` for iOS 16 files), export the diff
to `patches/xnu-12377/NNNN-name.patch`, test with `scripts/ios26/kernel-make.sh FILE...`, then a clean
`scripts/bg.sh ios26-kernel scripts/ios26/build-kernel.sh`.

## 3. Kernel build

Command: `scripts/bg.sh ios26-kernel scripts/ios26/build-kernel.sh` (then `scripts/ios26/kernel-make.sh` for fixes).

| Step | Result |
|---|---|
| dxb helpers with Xcode 27.1 (bootstrap_cmds/mig, dtrace ctf tools, AvailabilityVersions, Libsystem + libsyscall headers, libplatform, libfirehose_kernel x86_64/arm64e/arm64) | [V] all built |
| dxb 26.0 patches on 12377.121.6 | [V] all apply except `link_kdk.patch` (our 0001 replaces it) and `remove_applefeatures_include.patch` (not needed: no error from `vm_resident.c`) |
| xnu headers, MIG, `MASTER.arm64.negroni` doconf | [V] |
| compile errors met and fixed | `CPMU_PMC_COUNT` (Apple CPU counters: `CPU_COUNTERS_BASE = [ ]` in our master config), `fbcon_probe` inside `#ifdef PL011_UART` in 12377's `pe_serial.c` layout (moved), `sysreg_restore` gone in 12377 (clean removed from the PSCI path) |
| link / kernel.development.negroni | see section 3.1 |

### 3.1 Last build result

(filled in at the end of this work session, see the commit log of `ios26-prep`)

## 4. The iOS 26 series `patches/xnu-12377/`

| Patch | Contents | Source |
|---|---|---|
| `0001-non-apple-soc-base` | `machine_routines_nos.c` (functions only in KDK archives), KDK archive link only if it exists, `apple_amcc` option, Apple tunables only on Apple SoCs, no monitor/SART/UAT without `XNU_MONITOR`, 64-bit `pmap_sync_page_attributes_phys`, `-v` text console, DT panic region checks | UniXNU-ios26 (BSD-2-Clause-Patent), commit `68c5134` |
| `0002-negroni-machine-config` | NEGRONI machine config, `MASTER.arm64.negroni` (12377 MacOSX master + `nos_arm_asm nos_arm_pmap`, PPL pmap only, no CPU counters), `NEGRONI.h` for SM8450, stage 1 arm64 / stage 2 arm64e switch | slop 0004, 0006 reworked |
| `0003-negroni-machine-layer` | GICv3 Group 1 IRQs, SPI dispatch, start.s (PSCI entry, early marks), SMP/cluster ids, no CNTP write, PoC cleans for secondaries, CPU idle, MMIO try accessors | slop 0004/0010/0017/0065/0078/0082-0086, ours 0288/0295/0297/0382/0383 |
| `0004-negroni-platform-console` | NegroniPlatformExpert, NegroniCPU, framebuffer console, console tee/mute, panic hooks, no IORTC wait, no kernelmanagerd hold, NEGRONI TOP, weak default driver hooks | slop 0003/0016/0018/0043/0047/0067/0088, ours 0200/0360/0367/0382 |
| `0005-negroni-native-pac` | stage 2: arm64e kernel, `HAS_NATIVE_ARM_PAC` key writes in `PAC_INIT_KEY_STATE`, one global key set | new (replaces slop 0005) |

New design point for 12377: `osfmk/arm64/negroni_weak_hooks.c` gives weak default definitions of every driver hook
that the machine layer, console and platform expert call. The drivers keep their strong definitions. So the series
links at each step, and the drivers can come one family at a time.

## 5. Port state per family

Text results come from `patch-check.tsv` (section 6). Effort marks are [I].

| Family | Text on 12377 | iOS 26 state | Next work |
|---|---|---|---|
| Build glue (`bsd/conf/files`, `iokit/conf/files.arm64`, `KernelConfigTables.cpp`) | mostly applies | rework per driver (each driver patch adds its own lines) | mechanical |
| Machine layer (board, GIC, timer, SMP/PSCI, start.s, sleh.c, pe_fiq.c, CPU idle) | 0004 partial 5/14, 0065 partial 3/14, rest applies | **ported** (0002-0004), compile-tested | boot test T1 |
| Console / framebuffer console / panic hooks | 0003 partial, 0047/0067 partial | **ported** (0004) | USB live log (`negroni_usb.c`) |
| PAC | n/a | **new** (0005), stage 2 | first arm64e compile; Gunyah key-register access test |
| Crypto / RNG (slop 0013, 0014, 0020, 0023, 0027, 0032, 0033) | 0013 fail, 0014 partial 7/9 | blocked on design | port UniXNU source corecrypto (`build-corecrypto-14.py --xnu-12377`, `native-source-crypto.patch`) instead of the BearSSL/HMAC-PRNG patches |
| pthread (slop 0019 + stage) | stage script pins libpthread-514 (8796 pair) | blocked on ABI | UniXNU `build-pthread-12377.py` + libpthread-539.100.4 |
| Storage / root (UFS 0028-0034, mockfs 0021-0024, HFS 0026 + stage, 0204) | UFS applies; 0041 fail, 0204 partial 5/6 | not started | HFS tag that matches 12377 (`hfs` in macos-265 release.json), then UFS driver as is |
| AMFI / code signing / trust cache (0015, 0025, 0035, 0036, 0221) | 0221 partial | not started; **largest core rework** | 12377 `kern_codesigning.c` + CoreEntitlements V2: our AMFI must register a `CEKernelAPI_t` (amfi_core_entitlements_register); `ubc_subr.c` and the PPL `pmap.c` call through it |
| Sandbox (0050, 0222, 0223) | applies as text | not started | op numbers and privileges of the iOS 26 libsystem_sandbox must be re-traced |
| AKS emulation (0038, 0055, 0220, 0221) | 0038 partial | not started | AppleKeyStore selector set of iOS 26 userland |
| IOSurface / IOMFB / HID (0046, 0056, 0058, 0068, 0230-0237, 0250-0259, 0289, 0364) | mostly applies (0046, 0058 partial) | not started | user-client ABI of IOSurface 393.5.7 / IOMobileGraphicsFamily 343.0.0 |
| SoC drivers (UFS, keys, touch, USB/ECM, ADSP/audio, Wi-Fi, BT, battery/charger, thermal, cpufreq, camera, haptics, fingerprint, DSI/DPU, Adreno) | almost all apply as text | not started | port as is, family by family, with `kernel-make.sh` |
| Identity (0059, 0061, 0088, 0363, 0378) | 0363 fail (obsolete) | 0363 obsolete | D421AP identity (`hw.machine iPhone12,3`), report a cpufamily without AMX |

## 6. Per-patch table (iOS 16 stack on xnu-12377.121.6)

Regenerate: `scripts/ios26/patch-check.sh` then `scripts/ios26/port-table.py out/kernel/local-ios26/patch-check.tsv`.
"Text" = `patch -F3` on the cumulative 12377 tree (Apple patch 2.0): upstream = already in 12377, clean = all hunks
apply (with or without offset), partial n/m = n of m hunks fail, fail = no hunk applies, stage = slop stage script
(downloads a pinned source tree). Text results are not compile results.

| Patch | Text on 12377 | Family | iOS 26 series state |
|---|---|---|---|
| `0001-new-clang-drop-removed-auto-var-init-flag.patch` | upstream | other | obsolete: flag removed upstream |
| `0002-new-clang-backport-UIO_STACKBUF.patch` | partial 1/37 failed | other | not started (dxb 26.0 + Xcode 27.1 build without it: [V] compile reached all of bsd/osfmk) |
| `0003-negroni-framebuffer-serial-console.patch` | partial 2/3 failed | display | reworked (0004: fbcon_probe before the 12377 phandle lookup, outside PL011_UART) |
| `0004-negroni-machine-config.patch` | partial 5/14 failed | machine | reworked (0002 config, 0003 GIC/IRQ/start.s) |
| `0005-non-pac-build-fixes.patch` | clean | other | replaced (0005 native PAC, stage 2) |
| `0006-negroni-master-config-open-source-asm-pmap.patch` | clean | machine | reworked (0002: 12377 MacOSX master + nos_arm_asm/nos_arm_pmap, no CPU counters) |
| `0007-negroni-stub-apple-internal-headers.patch` | partial 1/6 failed | other | not needed so far (12377 + UniXNU base, 0001) |
| `0008-negroni-fill-closed-lib-gaps-kpc-stub.patch` | partial 1/14 failed | other | reworked (0001 machine_routines_nos.c; 12377 has kpc.c; amcc via apple_amcc option) |
| `0009-negroni-drop-apple-soc-only-exports.patch` | partial 1/2 failed | other | not started |
| `0010-negroni-early-framebuffer-debug.patch` | partial 1/16 failed | display | ported (0003 start.s band, negroni_early.c) |
| `0011-negroni-physmap-alignment-padding.patch` | clean | machine | not started |
| `0012-negroni-keep-debug-console-after-ttbr0.patch` | clean | debug/USB | not started |
| `0013-negroni-kmem-rng-without-corecrypto.patch` | fail 2/2 | crypto/pthread | blocked: 12377 crypto init differs (corecrypto KPI v14); port UniXNU source corecrypto instead |
| `0014-negroni-kernel-hmac-prng.patch` | partial 7/9 failed | crypto/pthread | blocked: same as 0013 |
| `0015-negroni-unavailable-trust-cache-runtime.patch` | clean | codesign/sandbox | not started (UniXNU native-trust-cache-runtime is the 12377 model) |
| `0016-negroni-device-tree-platform-expert.patch` | clean | other | ported (0004 NegroniPlatformExpert) |
| `0017-negroni-device-tree-virtual-timer-irq.patch` | clean | machine | ported (0003 pe_fiq.c vtimer INTID from ADT) |
| `0018-negroni-boot-cpu-driver.patch` | partial 1/3 failed | machine | ported (0004 NegroniCPU) |
| `0019-negroni-builtin-pthread.patch` | clean | crypto/pthread | blocked: 12377 pthread callback ABI (UniXNU build-pthread-12377.py, libpthread-539) |
| `0019-stage-libpthread.sh` | stage | crypto/pthread | blocked: 12377 pthread callback ABI (UniXNU build-pthread-12377.py, libpthread-539) |
| `0020-negroni-portable-aes-cbc.patch` | clean | crypto/pthread | not started |
| `0020-stage-bearssl.sh` | stage | crypto/pthread | not started (BearSSL stage, crypto family) |
| `0021-negroni-mockfs-ramdisk-root.patch` | clean | storage/root | not started |
| `0022-negroni-ramdisk-root-without-iomedia.patch` | clean | storage/root | not started |
| `0023-negroni-builtin-sha256-for-libkern.patch` | clean | crypto/pthread | not started |
| `0024-negroni-mockfs-virtual-ramdisk-io.patch` | clean | storage/root | not started |
| `0025-negroni-builtin-amfi-no-entitlements.patch` | clean | codesign/sandbox | not started |
| `0026-negroni-builtin-hfs.patch` | clean | storage/root | not started |
| `0026-stage-hfs.sh` | stage | storage/root | not started (hfs-? tag that matches 12377 must be picked) |
| `0027-negroni-bearssl-md5.patch` | clean | crypto/pthread | not started |
| `0028-negroni-ufs-root-device.patch` | clean | storage/root | not started |
| `0029-negroni-unsealed-root-volume.patch` | clean | storage/root | not started |
| `0030-negroni-ufs-writes.patch` | clean | storage/root | not started |
| `0031-negroni-read-write-root.patch` | partial 1/2 failed | display | not started |
| `0032-negroni-bearssl-sha1.patch` | clean | crypto/pthread | not started |
| `0033-negroni-bearssl-sha384-sha512.patch` | clean | crypto/pthread | not started |
| `0034-negroni-ufs-dma-above-4g.patch` | clean | storage/root | not started |
| `0035-negroni-amfi-entitlements-platform-binaries.patch` | clean | codesign/sandbox | not started |
| `0036-negroni-amfi-cs-signed.patch` | clean | codesign/sandbox | not started |
| `0037-negroni-config-bindfs.patch` | clean | storage/root | not started |
| `0038-negroni-applekeystore.patch` | partial 1/3 failed | AKS | not started |
| `0039-negroni-coredump-default-off.patch` | clean | other | not started |
| `0040-negroni-iowatchdog.patch` | partial 1/3 failed | power/thermal | not started |
| `0041-negroni-hfs-link-notes.patch` | fail 3/3 | storage/root | not started |
| `0042-negroni-short-exec-log.patch` | clean | debug/USB | not started |
| `0043-negroni-console-crash-log.patch` | clean | debug/USB | not started |
| `0044-negroni-crash-log-reason.patch` | clean | debug/USB | not started |
| `0045-negroni-iowatchdog-pmu-primary.patch` | clean | power/thermal | not started |
| `0046-negroni-iosurface-iomfb.patch` | partial 1/6 failed | GPU/IOSurface | not started |
| `0047-negroni-persistent-console-log.patch` | partial 1/3 failed | debug/USB | not started |
| `0048-negroni-devnull-tee.patch` | clean | other | not started |
| `0049-negroni-iokit-trace.patch` | clean | debug/USB | not started |
| `0050-negroni-sandbox-policy.patch` | clean | codesign/sandbox | not started |
| `0051-negroni-crash-heap-strings.patch` | clean | debug/USB | not started |
| `0052-negroni-hfs-rename-swap.patch` | clean | storage/root | not started |
| `0053-negroni-crash-scan-springboard.patch` | clean | debug/USB | not started |
| `0054-negroni-process-sampler.patch` | clean | debug/USB | not started |
| `0055-negroni-aks-ext-state-sampler-depth.patch` | clean | display | not started |
| `0056-negroni-fb-throttled-present.patch` | clean | display | not started |
| `0057-negroni-no-ext-resolver.patch` | clean | other | not started |
| `0058-negroni-hid-event-services.patch` | partial 1/33 failed | input/haptics | not started |
| `0059-negroni-iphone-identity.patch` | clean | other | not started |
| `0060-negroni-keys-touch-drivers.patch` | clean | input/haptics | not started |
| `0061-negroni-iphone-x-display-size.patch` | clean | display | not started |
| `0062-negroni-touch-power-battery.patch` | partial 1/11 failed | power/thermal | not started |
| `0063-negroni-goodix-geni-packing.patch` | clean | other | not started |
| `0064-negroni-priv-work-interval.patch` | clean | other | not started |
| `0065-negroni-smp-psci.patch` | partial 3/14 failed | machine | ported (0003 start.s PSCI entry, 0004 NegroniCPU) |
| `0066-negroni-crash-fault-region.patch` | clean | debug/USB | not started |
| `0067-negroni-console-mute.patch` | partial 2/4 failed | debug/USB | ported (0004 console mute) |
| `0068-negroni-surface-lookup-cached.patch` | clean | GPU/IOSurface | not started |
| `0069-negroni-ufs-faster.patch` | clean | storage/root | not started |
| `0070-negroni-pid-hibernate.patch` | partial 2/3 failed | other | not started |
| `0071-negroni-touch-edge.patch` | clean | input/haptics | not started |
| `0072-negroni-usb-probe.patch` | clean | debug/USB | not started |
| `0073-negroni-usb-device-ep0.patch` | clean | debug/USB | not started |
| `0074-negroni-usb-vbus-override.patch` | clean | debug/USB | not started |
| `0075-negroni-usb-ecm.patch` | clean | debug/USB | not started |
| `0076-negroni-usb-rx-mbuf.patch` | clean | debug/USB | not started |
| `0077-negroni-usb-live-log.patch` | clean | debug/USB | not started |
| `0078-negroni-smp-8-cores.patch` | clean | machine | ported (0003 8 cores) |
| `0079-negroni-display-power.patch` | clean | display | not started |
| `0080-negroni-net-trace.patch` | partial 1/2 failed | debug/USB | not started |
| `0081-negroni-usb-link-state.patch` | clean | debug/USB | not started |
| `0082-negroni-gicr-stride-from-adt.patch` | clean | machine | ported (0003 redistributor stride) |
| `0083-negroni-no-physical-timer-write.patch` | clean | machine | ported (0003 no CNTP_CTL write) |
| `0084-negroni-irq-trace.patch` | clean | machine | ported (0003 IRQ trace) |
| `0085-negroni-kernel-thread-backtraces.patch` | clean | debug/USB | ported (0003 kernel thread backtraces) |
| `0086-negroni-bt-short-lines.patch` | clean | Bluetooth | ported (0003) |
| `0087-negroni-sm8450-keys.patch` | clean | input/haptics | not started |
| `0088-negroni-framebuffer-1080x2412.patch` | clean | display | not started |
| `0089-negroni-ufs-power-no-battery.patch` | clean | storage/root | not started |
| `0090-negroni-ufs-sense-start-unit.patch` | clean | storage/root | not started |
| `0091-negroni-quiet-keys-cpu-probe.patch` | clean | input/haptics | not started |
| `0092-negroni-ufs-wlun-active.patch` | clean | storage/root | not started |
| `0093-negroni-s3908-touch-gpio-i2c.patch` | clean | input/haptics | not started |
| `0094-negroni-trace-boot-arg.patch` | clean | debug/USB | not started |
| `0095-negroni-hid-touch-log-boot-arg.patch` | clean | debug/USB | not started |
| `0096-negroni-cpufreq-epss.patch` | clean | power/thermal | not started |
| `0097-negroni-adreno-ladder-read.patch` | clean | GPU/IOSurface | not started |
| `0098-negroni-cpufreq-never-lower.patch` | clean | power/thermal | not started |
| `0099-negroni-adreno-cx-power-clocks.patch` | clean | GPU/IOSurface | not started |
| `0100-negroni-gpu-status-badge.patch` | clean | GPU/IOSurface | not started |
| `0101-negroni-adreno-rscc-smmu-read.patch` | clean | GPU/IOSurface | not started |
| `0102-negroni-adreno-gmu-memory-trustzone.patch` | clean | GPU/IOSurface | not started |
| `0103-negroni-firmware-area.patch` | clean | other | not started |
| `0104-negroni-adreno-zap-signature.patch` | clean | GPU/IOSurface | not started |
| `0105-negroni-adreno-gmu-space-firmware.patch` | clean | GPU/IOSurface | not started |
| `0106-negroni-wifi-survey.patch` | clean | Wi-Fi | not started |
| `0107-negroni-fb-shift-probe-menu.patch` | clean | display | not started |
| `0108-negroni-adreno-gmu-start-hfi.patch` | clean | GPU/IOSurface | not started |
| `0109-negroni-wifi-cmd-db-direct.patch` | clean | Wi-Fi | not started |
| `0110-negroni-adreno-hfi-messages.patch` | clean | GPU/IOSurface | not started |
| `0111-negroni-adreno-to-first-frame.patch` | clean | GPU/IOSurface | not started |
| `0112-negroni-fb-clock-shift.patch` | clean | display | not started |
| `0113-negroni-adreno-initial-perf-vote.patch` | clean | GPU/IOSurface | not started |
| `0114-negroni-fb-clock-shift-fill.patch` | clean | display | not started |
| `0115-negroni-adreno-zap-segments.patch` | clean | GPU/IOSurface | not started |
| `0116-negroni-badge-opt-in.patch` | clean | other | not started |
| `0117-negroni-adreno-stop.patch` | clean | GPU/IOSurface | not started |
| `0118-negroni-gpu-service.patch` | partial 1/5 failed | GPU/IOSurface | not started |
| `0119-negroni-usb-sm8450.patch` | clean | debug/USB | not started |
| `0120-negroni-wifi-pcie-link.patch` | clean | Wi-Fi | not started |
| `0121-negroni-gpu-watch-panic-log.patch` | clean | debug/USB | not started |
| `0122-negroni-gpu-service-optional.patch` | clean | GPU/IOSurface | not started |
| `0122-negroni-wifi-supply-votes.patch` | clean | Wi-Fi | not started |
| `0123-negroni-gpu-service-trace.patch` | clean | debug/USB | not started |
| `0124-negroni-gpu-service-personality.patch` | clean | GPU/IOSurface | not started |
| `0125-negroni-wifi-rails-xo-slave.patch` | clean | Wi-Fi | not started |
| `0126-negroni-pmap-sync-page-64bit.patch` | clean | machine | ported (0001, from UniXNU zzx-pmap-sync-64bit-pa) |
| `0200-negroni-no-rtc-wait.patch` | fail 1/1 | power/thermal | reworked (0004 IOStartIOKit) |
| `0201-negroni-empty-ioacceleratores.patch` | partial 1/3 failed | GPU/IOSurface | not started |
| `0202-negroni-iokit-quiet.patch` | clean | other | not started |
| `0203-negroni-calendar.patch` | partial 1/6 failed | power/thermal | not started |
| `0204-negroni-hfs-clonefile.patch` | partial 5/6 failed | storage/root | not started |
| `0205-negroni-accel-plugins.patch` | clean | GPU/IOSurface | not started |
| `0210-negroni-usb-command-server.patch` | clean | debug/USB | not started |
| `0211-negroni-power-off.patch` | clean | power/thermal | not started |
| `0212-negroni-usb-settime.patch` | clean | debug/USB | not started |
| `0213-negroni-reboot-mode.patch` | clean | power/thermal | not started |
| `0214-negroni-pon-ps-hold-type.patch` | clean | power/thermal | not started |
| `0220-negroni-aks-no-passcode.patch` | clean | AKS | not started |
| `0221-negroni-aks-passcode.patch` | clean | AKS | not started |
| `0221-negroni-amfi-policy.patch` | partial 1/5 failed | codesign/sandbox | not started |
| `0222-negroni-sandbox-privileges.patch` | clean | codesign/sandbox | not started |
| `0223-negroni-sandbox-appex-container.patch` | clean | codesign/sandbox | not started |
| `0230-negroni-gpu-surface-import.patch` | clean | GPU/IOSurface | not started |
| `0231-negroni-gpu-present.patch` | clean | GPU/IOSurface | not started |
| `0232-negroni-gpu-host-import.patch` | clean | GPU/IOSurface | not started |
| `0233-negroni-gpu-per-client-va.patch` | clean | GPU/IOSurface | not started |
| `0234-negroni-fb-zero-copy.patch` | clean | display | not started |
| `0235-negroni-gpu-level.patch` | clean | GPU/IOSurface | not started |
| `0236-negroni-gpu-clock-probe.patch` | clean | GPU/IOSurface | not started |
| `0237-negroni-gpu-perf-table-khz.patch` | clean | GPU/IOSurface | not started |
| `0240-negroni-adsp-boot.patch` | clean | audio/DSP | not started |
| `0241-negroni-adsp-pas-supported-note.patch` | clean | audio/DSP | not started |
| `0242-negroni-adsp-glink.patch` | clean | audio/DSP | not started |
| `0243-negroni-audio-stage-b.patch` | clean | audio/DSP | not started |
| `0244-negroni-audio-amp-tfa9874.patch` | clean | audio/DSP | not started |
| `0245-negroni-audio-test-tone.patch` | clean | audio/DSP | not started |
| `0246-negroni-audio-earpiece-route.patch` | clean | audio/DSP | not started |
| `0247-negroni-audio-graph-mainline.patch` | clean | audio/DSP | not started |
| `0248-negroni-adsp-crash-watch.patch` | clean | debug/USB | not started |
| `0249-negroni-audio-smmu-s1.patch` | partial 1/7 failed | audio/DSP | not started |
| `0250-negroni-panel-brightness.patch` | partial 1/4 failed | display | not started |
| `0251-negroni-display-sleep.patch` | clean | display | not started |
| `0252-negroni-fb-stats.patch` | clean | display | not started |
| `0253-negroni-fb-display-refresh.patch` | clean | display | not started |
| `0254-negroni-fb-present-thread.patch` | clean | display | not started |
| `0255-negroni-mmio-accessors.patch` | clean | machine | not started |
| `0256-negroni-fb-clock-shift-after-gpu.patch` | clean | display | not started |
| `0257-negroni-iosurface-wrap-client-memory.patch` | clean | GPU/IOSurface | not started |
| `0258-negroni-display-sleep-sequence.patch` | clean | display | not started |
| `0259-negroni-display-te-vrr.patch` | clean | display | not started |
| `0260-negroni-wlan-pcie-inventory.patch` | clean | Wi-Fi | not started |
| `0261-negroni-wlan-mhi-fw.patch` | clean | Wi-Fi | not started |
| `0262-negroni-wlan-power-up.patch` | clean | Wi-Fi | not started |
| `0263-negroni-wlan-stages.patch` | clean | Wi-Fi | not started |
| `0264-negroni-wlan-ipcr-rings.patch` | clean | Wi-Fi | not started |
| `0265-negroni-wlan-qrtr.patch` | clean | Wi-Fi | not started |
| `0266-negroni-wlan-qmi-wlfw.patch` | clean | Wi-Fi | not started |
| `0267-negroni-fb-vsync-after-frame-clock-copy.patch` | clean | display | not started |
| `0268-negroni-panel-wake-on-command.patch` | clean | display | not started |
| `0269-negroni-fb-double-buffer.patch` | clean | display | not started |
| `0270-negroni-battery-spmi-v7.patch` | clean | power/thermal | not started |
| `0271-negroni-battery-service.patch` | clean | power/thermal | not started |
| `0272-negroni-battery-charger-input.patch` | clean | power/thermal | not started |
| `0273-negroni-charger-debug-arbiter.patch` | clean | power/thermal | not started |
| `0274-negroni-charger-glink.patch` | clean | power/thermal | not started |
| `0275-negroni-display-off-fast.patch` | clean | display | not started |
| `0276-negroni-battery-soc-source.patch` | clean | power/thermal | not started |
| `0277-negroni-charger-loop.patch` | clean | power/thermal | not started |
| `0278-negroni-battery-persist-temp.patch` | clean | power/thermal | not started |
| `0280-negroni-thermal-tsens.patch` | clean | power/thermal | not started |
| `0281-negroni-gpu-dcvs.patch` | clean | GPU/IOSurface | not started |
| `0282-negroni-usb-reset-reconfigure.patch` | clean | debug/USB | not started |
| `0283-negroni-thermal-trips.patch` | clean | power/thermal | not started |
| `0284-negroni-cpufreq-governor.patch` | clean | power/thermal | not started |
| `0285-negroni-gpu-power-collapse.patch` | clean | GPU/IOSurface | not started |
| `0286-negroni-gpu-dcvs-ui-floor.patch` | clean | GPU/IOSurface | not started |
| `0287-negroni-gpu-hang-recovery.patch` | clean | GPU/IOSurface | not started |
| `0288-negroni-cpu-idle-psci.patch` | clean | machine | ported (0003 negroni_cpuidle.c; RPMh hooks weak in 0004) |
| `0289-negroni-iosurface-lock-gpu-wait.patch` | clean | GPU/IOSurface | not started |
| `0290-negroni-io-submap.patch` | clean | machine | not started |
| `0291-negroni-cpufreq-floor-lut.patch` | clean | power/thermal | not started |
| `0292-negroni-dsi-cmd-dma-batch.patch` | clean | display | not started |
| `0293-negroni-dsi-read-esd.patch` | clean | display | not started |
| `0294-negroni-te-rate-tearcheck.patch` | clean | display | not started |
| `0295-negroni-te-irq.patch` | clean | display | ported (0003 SPI dispatch) |
| `0296-negroni-dpu-idle-power.patch` | clean | display | not started |
| `0297-negroni-mmio-try.patch` | partial 2/5 failed | machine | reworked (0003: SEA FnV case next to the 12377 expected-fault PC match) |
| `0298-negroni-gpu-kgsl-parity.patch` | clean | GPU/IOSurface | not started |
| `0300-negroni-haptic-direct-play.patch` | clean | input/haptics | not started |
| `0301-negroni-vibrator-service.patch` | partial 1/3 failed | input/haptics | not started |
| `0302-negroni-haptic-ui-actuator.patch` | clean | input/haptics | not started |
| `0303-negroni-haptic-brake-hboost-wait.patch` | clean | input/haptics | not started |
| `0310-negroni-cam-camcc-cci.patch` | clean | camera | not started |
| `0311-negroni-cam-imx789-chip-id.patch` | clean | camera | not started |
| `0312-negroni-cam-cpas-smmu-votes.patch` | clean | camera | not started |
| `0313-negroni-cam-clocks-csiphy.patch` | clean | camera | not started |
| `0314-negroni-cam-imx789-stream.patch` | clean | camera | not started |
| `0315-negroni-cam-csid-ife-rdi.patch` | clean | camera | not started |
| `0316-negroni-cam-icp-pas-hfi.patch` | clean | camera | not started |
| `0317-negroni-cam-smmu-s1.patch` | clean | camera | not started |
| `0318-negroni-cam-ios-stream.patch` | clean | camera | not started |
| `0320-negroni-wlan-cfg-mode.patch` | clean | Wi-Fi | not started |
| `0321-negroni-wlan-ce.patch` | clean | Wi-Fi | not started |
| `0322-negroni-wlan-htc-wmi.patch` | clean | Wi-Fi | not started |
| `0323-negroni-wlan-scan.patch` | clean | Wi-Fi | not started |
| `0324-negroni-wlan-smmu.patch` | clean | Wi-Fi | not started |
| `0325-negroni-wlan-smmu3-default.patch` | clean | Wi-Fi | not started |
| `0326-negroni-wlan-api.patch` | clean | Wi-Fi | not started |
| `0327-negroni-wlan-join-open.patch` | clean | Wi-Fi | not started |
| `0328-negroni-wlan-htt-dp.patch` | clean | Wi-Fi | not started |
| `0329-negroni-wlan-wpa2-psk.patch` | clean | Wi-Fi | not started |
| `0330-negroni-bt-uart-power.patch` | clean | Bluetooth | not started |
| `0331-negroni-bt-hci.patch` | clean | Bluetooth | not started |
| `0332-negroni-bt-h4-transport.patch` | clean | Bluetooth | not started |
| `0333-negroni-bt-hci-shim.patch` | clean | Bluetooth | not started |
| `0334-negroni-bt-qup-clocks.patch` | clean | Bluetooth | not started |
| `0335-negroni-bt-power-follows-client.patch` | clean | Bluetooth | not started |
| `0336-negroni-bt-init-fixes.patch` | clean | Bluetooth | not started |
| `0337-negroni-bt-vendor-answers.patch` | clean | Bluetooth | not started |
| `0338-negroni-bt-le-legacy-to-extended.patch` | clean | Bluetooth | not started |
| `0339-negroni-wlan-sbl-boot-dump.patch` | clean | Wi-Fi | not started |
| `0340-negroni-wlan-ios-iface.patch` | partial 2/7 failed | Wi-Fi | not started |
| `0341-negroni-apple80211.patch` | partial 1/2 failed | Wi-Fi | not started |
| `0342-negroni-wlan-ath11k-sw-reset.patch` | clean | Wi-Fi | not started |
| `0343-negroni-wlan-boot-dump-pcie.patch` | clean | Wi-Fi | not started |
| `0344-negroni-wlan-msi-mailbox.patch` | clean | Wi-Fi | not started |
| `0345-negroni-apple80211-scan-join.patch` | clean | Wi-Fi | not started |
| `0350-negroni-fingerprint-stage-a.patch` | clean | input/haptics | not started |
| `0351-negroni-fingerprint-highlight.patch` | clean | input/haptics | not started |
| `0352-negroni-fingerprint-mcu-frames.patch` | clean | input/haptics | not started |
| `0353-negroni-fingerprint-capture.patch` | clean | input/haptics | not started |
| `0354-negroni-fp-qup-clocks-highlight.patch` | clean | input/haptics | not started |
| `0360-negroni-panic-usb.patch` | clean | debug/USB | ported (0004 debug.c) |
| `0361-negroni-usb-throughput.patch` | clean | debug/USB | not started |
| `0362-negroni-kmem-report.patch` | partial 3/8 failed | debug/USB | not started |
| `0363-negroni-boot-line-1024.patch` | fail 1/1 | other | obsolete: 12377 BOOT_LINE_LENGTH is 1024 |
| `0364-negroni-fb-timing-modes.patch` | clean | display | not started |
| `0365-negroni-battery-charging-ui.patch` | clean | power/thermal | not started |
| `0366-negroni-usb-reconnect.patch` | clean | debug/USB | not started |
| `0367-negroni-bootlog.patch` | clean | debug/USB | ported (0004 debug.c hook; bootlog in negroni_ufs.c not yet) |
| `0368-negroni-usb-adsp-phy.patch` | clean | debug/USB | not started |
| `0369-negroni-charger-vooc.patch` | clean | power/thermal | not started |
| `0370-negroni-charger-write-bisect.patch` | clean | display | not started |
| `0371-negroni-usb-lost-reboot.patch` | clean | debug/USB | not started |
| `0372-negroni-usb-phy-rails.patch` | clean | debug/USB | not started |
| `0373-negroni-charger-ulog.patch` | clean | debug/USB | not started |
| `0374-negroni-typec-sink.patch` | clean | power/thermal | not started |
| `0375-negroni-usb-idle-reboot.patch` | clean | debug/USB | not started |
| `0376-negroni-slpi-start.patch` | clean | audio/DSP | not started |
| `0377-negroni-charge-mode.patch` | partial 1/17 failed | power/thermal | not started |
| `0378-negroni-bootargs-truncate.patch` | clean | other | obsolete with 0363 [I] (check the truncation code) |
| `0379-negroni-smmu-s1-readback-fields.patch` | clean | other | not started |
| `0381-negroni-usb-datafix.patch` | clean | debug/USB | not started |
| `0382-negroni-power-idle.patch` | clean | power/thermal | ported (0004 negroni_top.c, 0003 cpuidle) |
| `0383-negroni-cpuidle-cluster-rpmh-sleep.patch` | clean | machine | ported (0003 cpuidle part); negroni_rpmh.c not started |
| `0384-negroni-gpu-governor-irq.patch` | clean | machine | not started |
| `0385-negroni-usb-phy-gate.patch` | clean | debug/USB | not started |

## 7. PAC / arm64e plan

- [V] The open-source xnu has PAC key code only for the paravirtual VMAPPLE (`hvc`); Apple SoCs set their keys in the
  closed KernelSupport archives. So the arm64e kernel needs our own key code: patch 0005.
- [I] One global key set (EL0 = EL1 keys) first: `SET_JOP/ROP_KEY_REGISTERS` stay empty like every non-paravirtual
  open-source config. Per-process B keys later (save/restore on context switch, like Linux `ptrauth_keys_install_user`).
- [U] Gunyah must let EL1 write `AP*Key*_EL1` (HCR_EL2.APK) and execute PAC instructions (HCR_EL2.API). Android shows
  `paca pacg` in `/proc/cpuinfo`, and Linux at EL1 writes the keys, so this is expected to work [I].
- [U] The shared region: 12377 rebases auth pointers in `vm_shared_region` slide (slide info v5) with the kernel's
  `ptrauth` helpers; with global keys these signatures are valid in every process [I].
- [U] AMX: the A13 donor identity (`CPUFAMILY_ARM_LIGHTNING_THUNDER`) may make Accelerate use AMX instructions;
  report another family or 0.

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

1. Finish the stage-1 link (section 3.1) and clean the warnings that hide real errors.
2. USB live log (`negroni_usb.c` family, slop 0072-0077, 0119, ours 0282, 0361, 0366, 0368, 0371-0375, 0381, 0385) so
   the first phone test (T1, RAM boot) gives a log.
3. Stage 2 compile (`ARCH_STRING=arm64e scripts/ios26/build-kernel.sh`).
4. Crypto + pthread from UniXNU-ios26; UFS + HFS (with the HFS tag of macOS 26.5).
5. AMFI with a CoreEntitlements V2 table.
6. Drivers family by family (ports as is), then the user-client ABI families with the 23F84 shared cache.

## Licenses

`patches/xnu-12377/0001-non-apple-soc-base.patch` and `scripts/ios26/kdk-headers.py` contain code from UniXNU-ios26,
Copyright (c) 2026, UniXNU contributors, BSD-2-Clause-Patent. The full license text is in
[../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) section 1. xnu changes are under the APSL 2.0 like the iOS 16
patches. No Apple file (KDK headers, IPSW parts, kernelcache) is in git: they stay in `out/` and `~/op10-apple/`.
