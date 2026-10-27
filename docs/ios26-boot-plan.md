# iOS 26 first boot tests on the phone (plan, not run)

Date: 2026-10-27. Status of the kernel and the patches: [ios26-port-status.md](ios26-port-status.md).
Phone rules from CLAUDE.md stay: RAM boot first (`fastboot boot`), **`boot_a` keeps the working iOS 16 image**, no
write to slot B, the GPT or unique partitions. Every test below is a RAM boot unless the line says otherwise; the
phone goes back to iOS 16 with a normal reboot. Hold Volume Up + Volume Down + Power for fastboot at any time.

Marks: [V] verified, [I] inference, [U] unknown.

## Image for a RAM boot

The iOS 16 boot chain stays: `boot_a.img` = shim + Mu UEFI + ESP with DarwinBoot, the kernel and the ADT
(`scripts/ios16/build.sh`). For iOS 26 only the kernel (and later the ADT identity) changes:

```sh
scripts/bg.sh ios26-kernel scripts/ios26/build-kernel.sh             # out/kernel/kernel-ios26.macho
# boot image with the 12377 kernel, the iOS 16 ADT and a separate output folder (iOS 16 images untouched):
IOS16_OUT=out/ios26-t1 KERNEL=out/kernel/kernel-ios26.macho scripts/ios16/build.sh   # [I] KERNEL knob to add
fastboot boot out/ios26-t1/boot_a.img                                  # RAM only
```

[I] `scripts/ios16/build.sh` reads `out/kernel/kernel.macho`; a `KERNEL=` override (or a small
`scripts/ios26/build-boot.sh` wrapper that links a temporary copy) is the only build change needed. The iOS 16
root on userdata is not touched by T1-T4.

## Test order

| Test | Image | Boot-args (add to the iOS 16 set) | Pass when | Needs |
|---|---|---|---|---|
| **T0** host | `build-kernel.sh` stage 1 | - | kernel links; `otool -l` shows `__TEXT` at 0xfffffff007004000 range; `strings` has `Darwin Kernel Version 25.5.0` and `NEGRONI` | patches 0001-0004 |
| **T1** first light | stage 1 kernel, iOS 16 ADT, RAM boot | `-v cpus=1 negronitrace=1` | white band (start.s), early marks 10-18 (`negroni_early_mark`), framebuffer text: version line, `Kernel boot args`, IOKit start, `NEGRONI: starting device-tree platform expert` | 0001-0004 |
| T1 stop point | | | expected panic or hang at the root mount (no UFS/HFS driver yet): `waiting on <dict ID="0"><key>IOProviderClass</key>...` [I] | |
| **T2** log over USB | + USB family port | `negroniusb=2` | `make usblog` gets the same lines as the panel | `negroni_usb.c` family |
| **T3** SMP | T2 | `cpus=8` | 8 CPUs online (`NEGRONI CPU` lines, `PSCI CPU_ON` ok), timer IRQs on every core | 0003/0004 |
| **T4** iOS 16 root on the 12377 kernel | + UFS, HFS, crypto, pthread, AMFI | iOS 16 boot-args | root mounted read-only (`-s` single user, or `rd=` the iOS 16 root), launchd of iOS 16 starts | storage + crypto + pthread + AMFI ports |
| T4 note | | | iOS 16 userland on a 26.5 kernel is a kernel-ABI test only [I]; new syscalls are not used by old userland, removed ones show as `ENOSYS` in the log | |
| **T5** arm64e kernel | stage 2 (`ARCH_STRING=arm64e`) | T3 set + `negronipactest=1` [I: a small self-test sysctl to add] | boot reaches T3 again; `pacia`/`autia` round trip on all CPUs; no `ESR_EC_PAC_FAIL` | 0005 |
| **T6** iOS 26 userland, RAM disk | stage 2 + mockfs ramdisk (slop 0021-0024 ported) with a trimmed 26.5.2 root (launchd, dyld, libSystem, the shared cache, a shell) | `rd=md0` [I] | launchd of 26.5.2 runs, dyld maps the arm64e shared cache (slide info v5), a shell over the USB command server | crypto, pthread, AMFI+CE table, mockfs, `fetch-os.sh` (disk) |
| **T7** iOS 26 root on userdata | **needs the owner's OK**: replaces the iOS 16 root on userdata (`scripts/flash` userdata step) | iOS 26 set | SpringBoard / backboardd start; GLES or SW renderer chosen (log `CA::OGL` context) | all of the above + IOSurface/IOMFB/AKS/HID ABIs |

Rules for every test:
- Keep `boot_a` = iOS 16. A test image goes only through `fastboot boot`.
- One change per test. Write the result (exact log lines, photo of the panel) into docs/notes.md and
  docs/ios26-port-status.md before the next test.
- A panic text stays on the panel (`negronipanic` default 0 = for ever, patch 0004 keeps the hook); with only
  0001-0004 the PMIC reset is a weak no-op, so a "reboot" spins: use the key combination.

## What can go wrong first [I]

| Symptom | Likely cause | Check |
|---|---|---|
| Black panel, no white band | DarwinBoot or Mu does not accept the 12377 Mach-O (new load commands, fileset vs. plain kernel) | DarwinBoot log; compare `otool -l` of the 8796 and 12377 kernels |
| White band, then nothing | early MMU / `arm_vm_init` in 12377 (new KVA layout, `T1SZ_BOOT`), or the splash framebuffer block in start.s | early marks 10-12 |
| Hang after marks | GIC Group 1 path or timer (12377 `rtclock` / `ml_timer` changes) | `negronitrace=1` VTIMER lines |
| Panic in `pmap_bootstrap` | PPL pmap without monitor in 12377 (`config_pmap_ppl` but `NO_MONITOR`) | UniXNU-ios26 boots this config on SM8350 (zeta) [V in their README] |
| Panic about trust cache / code signing | `trust_cache_init` / `csm_*` in 12377 `kernel_bootstrap_thread` | UniXNU `native-trust-cache-runtime` |
