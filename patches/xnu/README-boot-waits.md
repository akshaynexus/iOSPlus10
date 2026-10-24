# Boot-wait patches (0200-0202)

These patches remove three waits from the negroni (OnePlus 10 Pro, NE2211) boot. Each patch is
for the NEGRONI machine config only (`ARM64_BOARD_CONFIG_NEGRONI` / `NEGRONI`). Other configs
compile the same code as before.

Base: branch `base` of `out/kernel/xnu` (xnu-8796.141.3 + dxb + slop negroni patches).
Work branch: `boot-waits` in `out/kernel/wt-boot-waits` (one commit per patch).

| Patch | Removes | Default | Boot-arg to undo |
|---|---|---|---|
| `0200-negroni-no-rtc-wait.patch` | 30 s IORTC wait in `IOKitInitializeTime` | on | `negronirtcwait=N` (wait up to N s) |
| `0201-negroni-empty-ioacceleratores.patch` | ~30 s IOAcceleratorES polling per CoreAnimation process | on | `negroniaccel=0` |
| `0202-negroni-iokit-quiet.patch` | registry root busy for ever (IOKit never quiet) | on | `negronidaemonhold=1` |

Each patch applies alone on `base` with `git apply`, and the three apply together in any order.
The patches touch different hunks of the same files (0200 and 0202 both edit
`iokit/Kernel/IOStartIOKit.cpp`). 0201 and 0202 were made with `git diff` from the previous
commit, so the line numbers assume the earlier patches. `git apply` finds the hunks at the
offset.

## 0200: no IORTC wait

File: `iokit/Kernel/IOStartIOKit.cpp`, function `IOKitInitializeTime()`.

Stock code waits 30 s for `resourceMatching("IORTC")`. No negroni driver publishes IORTC, so
every boot lost 30 s. Then `clock_initialize_calendar()` read `PEGetUTCTimeOfDay()`.

The patch skips the wait on NEGRONI and logs
`NEGRONI: no IORTC provider, calendar from the platform (no 30 s wait)`.
`clock_initialize_calendar()` runs as before, so the clock result is the same as after the
timeout. `negronirtcwait=N` waits up to N seconds again (to test a future RTC driver).

References: ios-sailfish `xnu/patches/0086-sweet-no-rtc-wait.patch` (commit fb5ee28),
UniXNU-pong `patches/xnu/zzzzzzz-pong-no-rtc-wait.patch` (commit 36a8801).

Not done: a real IORTC from the PMK8350 RTC (ios-flame `xnu/patches/0099-flame-rtc.patch`
does this for PM8150 peripheral 0x60). Reasons:
- `bsd/dev/negroni_spmi.c` allows reads of SID 0 peripherals 0x10-0x13 and 0x48 only. The RTC
  (PMK8350 `rtc@6100`, alarm 0x6200 in Linux `pmk8350.dtsi`) needs a change to that allow list.
  That file belongs to the battery driver.
- `negroni_spmi_init()` has no lock around its first call. Its comment says only the
  NegroniBattery start thread calls it. A second caller at `bsd_init` time is a race.
- On Qualcomm phones the HLOS usually cannot set the PMIC RTC. Android keeps the wall-clock
  offset in userspace (time_daemon). The raw RTC value is then not the correct date [inference].

## 0201: empty IOAcceleratorES

Files:
- new `iokit/Kernel/arm/NegroniAccel.cpp`: `class IOAcceleratorES : public IOService`,
  `IOAcceleratorES::start()` only.
- `iokit/KernelConfigTables.cpp`: personality `IOClass IOAcceleratorES`,
  `IOProviderClass AppleCLCD`, `IOMatchCategory IOAcceleratorES`.
- `iokit/conf/files.arm64`: build entry for `NegroniAccel.cpp`.

QuartzCore (`CAMetalContextCreate`) polls `IOServiceMatching("IOAcceleratorES")` 300 times,
100 ms apart, in each process that sets up CoreAnimation. Our live log
(`logs/usblog-20261024-195455.txt`) shows `IOK backboardd: matching1 ... IOAcceleratorES ...
-> none` many times.

The stub matches on AppleCLCD (the framebuffer from `NegroniFramebuffer.cpp`) when AppleCLCD
registers. `start()` reads `negroniaccel` (default 1). With 0 it returns false and IOKit
removes it. Otherwise it registers and logs
`NEGRONI ACCEL: empty IOAcceleratorES on AppleCLCD (...)`.
The service has no `MetalPluginName` / `MetalPluginClassName` and no user client. Metal skips
it and CoreAnimation keeps its CPU path. This is the same result that bergamota reports on the
POCO F1 (NOTES.md boot 0124: `1 found`, no 30 s polling).
No change to `NegroniFramebuffer.cpp`: the personality does the attach.

GPU path (RedwoodGPU, `NegroniGPU.cpp`, `negroniadreno_keep=1`): no conflict. RedwoodGPU is a
different class (`RedwoodGPU : IOService`) on IOResources with the resource `NegroniGPUKept`.
IOAcceleratorES lookups do not find it and RedwoodGPU lookups do not find the stub.
For the GPU agent: if a real driver publishes its own IOAcceleratorES (with a Metal plugin),
remove the stub personality from `KernelConfigTables.cpp` (or boot with `negroniaccel=0`).
Metal expects only one IOAcceleratorES device (bergamota `docs/TOPAZ_MERGE.md`).
A real driver must not use the class name `IOAcceleratorES` while `NegroniAccel.cpp` exists:
the same class name twice is a link error.

References: ios-sailfish `xnu/patches/0166-sweet-ioacceleratores-iokit-quiet.patch` (fb5ee28),
bergamota `xnu/patches/0122-topaz-empty-ioacceleratores.patch` (2e0a572) and
`docs/TOPAZ_MERGE.md` (both after MakrSas/ios-topaz 0138). Both attach the stub below AppleCLCD
from `AppleCLCD::start()`. Here a personality does the same, so the framebuffer file is not
edited.

## 0202: no registry-root busy hold for the IOKit daemon

Files: `iokit/Kernel/IOStartIOKit.cpp` (`StartIOKitMatching()`, new global
`gIONegroniDaemonBusyHold`), `iokit/Kernel/IOService.cpp` (`IOService::iokitDaemonLaunched()`).

`StartIOKitMatching()` adds a busy count to the registry root when
`OSKext::iokitDaemonAvailable()` is true (always, if `-restore` is not set). Only
`iokitDaemonLaunched()` removes it, when the IOKit daemon sends its kext request. The negroni
kernel is built with `-DXNU_TARGET_OS_OSX` (see the CI `.CFLAGS` in `out/kernel/buildtree`), so
the daemon is `kernelmanagerd`. iOS has no kernelmanagerd. The registry root stays busy, IOKit
is never quiet, and callers of `IOKitWaitQuiet` (configd's InterfaceNamer, then wifid and
others) wait for their full timeout. `NO_KEXTD` is not set in `MASTER.arm64.negroni` (the
CONFIG_DEFINES of the CI build tree confirm it), so this code is active.

The patch takes the hold on NEGRONI only with `negronidaemonhold=1`. The flag
`gIONegroniDaemonBusyHold` records that the hold was taken. `iokitDaemonLaunched()` removes
the busy count only if the flag is set, so no unbalanced `adjustBusy(-1)` can occur. Deferred
matching (`startDeferredMatches()`) and `publishUserResource(gIOResourceIOKitKey)` are not
changed.

References: ios-sailfish 0166 (second part, fb5ee28), bergamota
`xnu/patches/0123-topaz-iokit-quiesce-sweetbusy.patch` (2e0a572; after ios-topaz 0128).
The bergamota `sweetbusy=N` busy-service lister is not ported.

Risk: code that expected IOKit to stay busy can now continue earlier. bergamota saw no
problem. If the boot gets worse, first test `negronidaemonhold=1`.

## Verification

- No full kernel build (needs Xcode 15, CI does it later).
- Each changed and new file was syntax-checked with the local clang (Apple clang 21) against
  the CI build tree `out/kernel/buildtree` (generated headers, `.CFLAGS`, `.CXXFLAGS`,
  CONFIG_DEFINES, the iokit `-D` flags) and the kernel warning set (`-Weverything` minus the
  `MakeInc.def` / `iokit/conf/Makefile.arm64` exclusions). The changed lines give no warnings.
  The only warnings in `NegroniAccel.cpp` come from `OSDefineMetaClassAndStructors`. They also
  occur in all existing Negroni*.cpp files, and the build has `-Wno-error` for them. Script:
  `out/kernel/cc-boot-waits/cc.sh <worktree> <file> [flags]` (warning set in `warn.txt`
  next to it).
- Preprocessor check: the NEGRONI branches are active in that build configuration.
- `git apply --check` of each patch alone on `base`, and all three in both orders. The result
  is the same as the `boot-waits` branch.

## What to look for on the first boot

- `NEGRONI: no IORTC provider ...` early in the log. Userland starts about 30 s earlier.
- `NEGRONI ACCEL: empty IOAcceleratorES on AppleCLCD ...`. The repeated
  `IOK backboardd: matching1 ... IOAcceleratorES ... -> none` lines stop
  (`-> IOAcceleratorES` once).
- No `registry root held busy, kernelmanagerd has not checked in` message from waitQuiet.
- Regression signs: backboardd/SpringBoard crash in Metal or QuartzCore, or a black UI. Then
  boot with `negroniaccel=0`. A hang before the lock screen: test `negronidaemonhold=1`.
