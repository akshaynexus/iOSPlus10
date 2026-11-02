# Mi A3 iOS 26: backboardd dies in CoreBrightness, launchd reboots

Date: 2026-11-02. Boot: `logs/ios26-boot9.txt` of the main checkout. **The fix ran on the host only. No flash, no phone boot.** Labels: [V] read in code, disassembly or a file, or run here. [I] inference. [U] unknown. Addresses: unslid cache addresses of 23F84, or `launchd` file addresses.

## 1. Cause

**23F84's CoreBrightness needs the property `backlight-calibration-parameters` on the backlight service. Our `AppleARMBacklight` does not publish it. The fallback path of Apple's code then reads a table through a NULL pointer.**

```
CRASH backboardd pc 0x1f1b35924 lr 0x1f1b31298 far 0x0        slide 0xfb70000: unslid 0x1e1fc5924, 0x1e1fc1298
```

| Frame (unslid) | Function | |
|---|---|---|
| 0x1e1fc5924 | `__DisplaySliderToLogicalBrightnessInternal` +0x114 | `ldr x8,[x8,#0x48]; ldr s0,[x8]`: `display->table[0]`, **no test of the pointer here** (the tests above it skip only the interpolation) |
| 0x1e1fc1298 | `_DisplayCreateWithCapabilitiesAndID` +0x67c | The call: slider 0 |
| 0x1e1ef1d40 | `-[CBDisplayModuleiOS initWithBacklight:queue:display:]` +0x450 | `DisplayCreate(service, 0, 0, displayId)` |
| 0x1e1fb81cc | `-[CBDisplayContaineriOS setupInternalModules]` +0x19c | |
| 0x1e1fb602c | `-[CBDisplayContaineriOS handleDisplayArrival:]` +0x69c | |
| 0x1e1fb5438 | `-[CBDisplayContaineriOS findBacklight]` +0x1c4 | The `backlight-control` match of the log: 1 found |

In `_DisplayCreateWithCapabilitiesAndID` [V disassembly]:

1. `[CBBacklightNode getBacklightCalibration:&display->0x508]` (0x1e1fc1234) reads the service's dictionary `backlight-calibration-parameters` (`IORegistryEntrySearchCFProperty`). No dictionary: answer NO.
2. On NO: defaults 5, 140, 400, then `__DisplaySliderToLogicalBrightnessInternal(display, 0.0)` at 0x1e1fc1294.
3. `display->0x48`, the table, is set only later (0x1e1fc224c), from `backlight-marketing-table`. So the NO path **always** faults on 23F84. A real iPhone never takes it, because its driver publishes the dictionary [V N104AP kernelcache has the strings `backlight-calibration-parameters`, `exportCalibration`, `lMaxProduct`, ...; its ADT `/backlight` has `backlight-marketing-table`, 17 points].

Values of the dictionary [V `getBacklightCalibration:`]: `current-for-max-backlight`, `current-for-mid-backlight`, `hardware-max-current-limit`, `lMaxProduct`, `lMidProduct`, `lMinProduct`, `lMaxPanel`, `lMidPanel`, `lMinPanel` (each 16.16, `integerValue / 65536`), `milliAmps2NitsScaleFactor` (optional).

**IOS-26-Hot met the same crash on the same 23F84** [V `phone/media/inject_sysfix.c`]: `-[CBBacklightNode getBacklightCalibration:] fallback for 625-nit AppleARMBacklight so _DisplayCreateWithCapabilitiesAndID does not call __DisplaySliderToLogicalBrightnessInternal before copyMarketingTable`. It hooks the method in the process, and its ADT `/backlight` has the table.

### What was not the cause

| Lead | Result |
|---|---|
| `IODeviceTree:/core-brightness -> none` | **False lead** [V]: the N104AP ADT has no such node either. Real driver or not, the answer is the same |
| The DCP and AV interface matches just before the crash | Notifications with no match. Not read on this path [V stack] |
| `IOAcceleratorES`, Turnip, Metal | The device opened before the crash. Not on the stack |

### The other `IOK backboardd` refusals before the crash

| Line | State |
|---|---|
| `ApplePearlSEPDriver`, `arm-io/pearl-sep`, `IOAccessoryManager 0 found`, `marconi-bt` | The same on iOS 16 [V `usblog-20261101-165828`], where the UI came up. The N104AP ADT has `pearl-sep`; ours has no Face ID. Not on this path |
| `AppleM2ScalerCSCDriver` none, `IOServiceMatchingfailed for: AppleM2ScalerCSCDriver` | The same on iOS 16 |
| `AGXAccelerator` none | The same on iOS 16 |
| `AppleM2ScalerParavirtDriver` none, `DCPAVCECInterfaceProxy` notify | New on iOS 26. [I] Not needed: a match that finds nothing; no crash follows them in the replay |
| `native-metal: refused ... binary archive ... default.metallib` | Handled: `new_metal_context` tests the nil (`cbz x22` at 0x1841550b4), logs, goes on [V]. No precompiled pipelines: CA compiles them. Section 6 |

## 2. Fix

**`patches/laurel/xnu-12377/post/9005-laurel-backlight-calibration.patch`: `AppleARMBacklight` publishes `backlight-calibration-parameters` and `backlight-marketing-table`, before `registerService`.** 12377 only; the iOS 16 kernel does not have it. No stub: these are two properties a real `AppleARMBacklight` has, with this panel's numbers. No hook, no injected code.

| Value | 16.16 of | Why |
|---|---|---|
| table, 17 points as N104AP | `430 nits * s^2`, floor the panel's lowest level | The driver's own curve (`laurel_level_for`: DBV = max * s^2). 430 is our estimate since patch 2201, [I] as before |
| `lMax*` | 430 | Table end |
| `lMid*` | 107.5 | Table middle, as on N104AP (Lmid 155 = table[8]) |
| `lMin*` | 0.84 | DBV 4 of 2047 |
| 3 currents | 0 | No LED current on an AMOLED. CoreBrightness only prints them [V references of +0x508, +0x50c, +0x510 in `Display*`] |
| not published | `digital-dimming-min-nits`, `user-accessible-max-nits`, `milliAmps2NitsScaleFactor` | Absent: min-nits equals `lMin`, so digital dimming stays off [V replay: flag +0x5ec 0], the same as on iOS 16 (`patches/xnu/README-brightness.md`) |

It checks its input: no nits, or a bad DBV range: one `off` line, and backboardd then dies as today. A failure touches nothing else.

## 3. Host replay [V]

`ios26-user-emu.py` could not run a daemon past `main()`: no workqueue, no launchd. So `--display-create PLIST` runs **the real function** from `main()` of backboardd, with the real lowered cache on a cortex-a72. IOKit and CFPreferences stop at their entry; each property comes from the real `IOCFUnserialize`, from a plist made by `ios26-backlight-props.py`.

```
scripts/bg.sh ios26-bbd-emu scripts/laurel/test-ios26-bbd-emu.sh
before: the phone's fault: pc CoreBrightness+0x169924, lr +0x165298, far 0
after: returned a display
display 0x300c3c000: table at +0x48 0x300637820, 17 entries: [0.84, 1.68, 6.72, 15.12, 26.88, 41.99, 60.47, 82.3, 107.5, 136.05, 167.97, 203.24, 241.88, 283.87, 329.22, 377.93, 430.0]
lMaxProduct 430.00 lMidProduct 107.50 lMinProduct 0.84 lMaxPanel 430.00 lMidPanel 107.50 lMinPanel 0.84 milliAmps2Nits 430.00
digital dimming flag +0x5ec 0, extrabright +0x5ed 0
container: handleDisplayArrival: and setupInternalModules returned
PASS
```

So with today's registry it gives the phone's own fault, at the same offsets. With 9005 the same code goes on to its end. `--container` runs the frames of the crash from `handleDisplayArrival:`, with the other modules of `setupInternalModules` (`CBABModuleiOS`, telemetry, ...). No other fault.

**Limits.** No CADisplay (nil), so the replay forces `_CBU_IsAccessory` to take the branch of a display. No XPC: NSUserDefaults and CFPreferences answer "not set". No thread: blocks stay on their queues, timers do not fire. 34 properties more are read and absent in the function, about 50 in `--container` (`use-AAP`, `aab-*`, ...): same as on a device that does not have them [V each `loadUint`/`loadInt` keeps its default]. **It does not run `main()` of backboardd, CA or the first frame.** The value is one thing: this crash is gone, and the next NULL in these frames is not there.

## 4. The reboot loop

**Rule** [V launchd 23F84]: `0x100021c4c`: a crash exit, and service flag bit 60, and the number of crashes in the last 60 s == 3. Then `<Critical>: rebooting due to critical process crashes`, `/usr/libexec/devicerecoverytool`, shutdown, reboot.

| Item | |
|---|---|
| Source of the flag | **`/System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist`, `Version4/Daemon/Override/NAME/RecoverOnCrash = true`** for `com.apple.backboardd`, `com.apple.SpringBoard`, `com.apple.configd`, `com.apple.runningboardd` [V file; launchd 0x10000d8ec registers the key `RecoverOnCrash` with the block at 0x10007c130, whose function 0x10000ea10 sets bit 60]. This closes the [U] of `ios26-entry.md` section 5 |
| Count | 3 (0x100081df0), window 60 s (0x100081de8 = 60,000,000,000 ns; timestamps older than that are dropped, 0x100027b00) [V] |
| Gate 0x100049f9c | True unless a byte is set at the event of 0x100015ef8 and that event is over 300 s ago [V]. It does not protect a loop at boot |
| `ThrottleInterval` | A raise **does** stop the reboot, if it is above 30 s: then 3 crashes cannot fall in 60 s [V rule; I it was not run]. But each crash then costs that wait, and it needs one key per job. Not chosen |
| `_RecoverOnCrash` in a job | The same flag. Removing it does nothing: the jobs have no such key [V] |

**Change: `no_recover_on_crash()` in `ios26-root-spec.py` removes the key from those 4 daemons** of the jetsam file. No boot-arg, no launchd.plist edit. Audit line: `applied jetsam RecoverOnCrash: removed from [...]`, which `ios26-root.sh` prints at its end. A root built with `RECOVER_ON_CRASH=1` keeps Apple's key. Self-test: `recover hook self-test: 7 of 7`.

**What this changes, stated:**

- A crash loop of these 4 daemons restarts them every `ThrottleInterval` (10 s; runningboardd 1 s) for as long as it lasts. It does not reboot, so SSH stays up.
- **The phone does not reboot itself out of such a loop.** So such a loop uses up no retry of slot b. The way back to Android: Power + Vol Down, or `op10tool ctl bootloader`, or the owner's Power button for each retry (`dual-boot.md` section 1).
- `dead-man: strike N armed (limit 6)`: backboardd's Metal strike counts one each crash within 15 s of the device open. The reboot kept that at 3. Without the reboot a loop of an early crash reaches 6 in about one minute: then `dead-man: 6 unclean starts in a row (limit 6), no Metal device`, and CA has no renderer. Read the **first** `CRASH backboardd`. `rm /private/var/db/negronimetal/strikes/backboardd` re-arms it.

On a shipping root put the key back (`RECOVER_ON_CRASH=1`) after the UI is stable.

With no new root: `scripts/laurel/ios26-recover-off.sh` over SSH, on a phone with the `rw` image. It takes effect at the next boot. **Not run.**

## 5. The other crashes of boot 9

| Crash | Cause [V] | Fix? |
|---|---|---|
| `cryptexd`, `sig 5`, 11 times, pc 0x2a256427c (`0x2b20d427c` minus the slide; 0x2bbcf827c is the same word in the next boot) | `libimage4.dylib` `__panic_npx`, from `__darwin_el0_init`: `panic: failed to get manifest properties`: `IORegistryEntryFromPath("IODeviceTree:/chosen/manifest-properties")` gives none. Called from `_img4_chip_select_personalized_ap`, in cryptexd's start. The N104AP ADT has that node (all `Unused*Property` zeros); our mkadt does not. zeta's has it empty | **No, not now.** Not on the path of SSH or backboardd; no `RecoverOnCrash` in its job or jetsam entry. It restarts each 10 s (`KeepAlive` while `/private/var/run/com.apple.security.cryptexd/init` is absent): a small cost. If a client needs it: add the node to mkadt `--donor n104ap`. [U] what it does next: `AppleImage4` is absent too, and it may stop at the next property |
| `devicerecoverytool`, `sig 5`, `Fatal error: could not get registry entry` | `devicerecoverytool.swift:18`, `IORegistryEntryFromPath("IODeviceTree:/options")`. It wants to write `one-time-boot-command` and `device-recovery-boot-reason` to NVRAM. launchd goes on to its reboot when it dies | **No, and do not fix it.** It runs only on the reboot path, and the crash is harmless. With a working `/options` it would ask for a recovery boot on hardware that has none |

## 6. Next likely blockers

| # | Item | State |
|---|---|---|
| 1 | The rest of backboardd's start: real `CADisplay`, `BKDisplayRenderOverlay`, HID, and CoreBrightness' queued blocks | [I] most likely the next `CRASH`. The replay does not reach them |
| 2 | First frame: `CA::WindowServer::AccelServer::renderer` -> `new_metal_context` -> `IOMFBDisplay::allocate_buffer` | Device up [V log]. No `LAUREL METAL26: first frame` yet, because of this crash. 240 s limit in the plug-in |
| 3 | First compile: 139+ pipelines at about 175 ms each on this CPU [V iOS 16], so about 30 to 120 s [I]. No binary archive: `refused` is handled [V], so every pipeline is compiled here. The generic `fixed_frag`: 63,688 instructions, 15 to 40 s if CA asks it [I] | A wait, not a stop. The persistent cache needs a writable `/var` (`rw`). On a read-only root each start pays again |
| 4 | IOMFB swap | SwapEnd selector 5, 0x588 bytes, in `post/9000` [V code], and sel 90, 91, 92. Not run on a real frame. sel 88, 57, 18, 15, 22, 29, 33, 74 answered 0x0 in boot 9 [V]. Any other selector shows as a `SWEET FB: backboardd sel N ...` line with a non-zero answer |
| 5 | Vsync with the refresh period (K8), fence sleep (K7), `work_interval` ops (K11) of `ios26-metal.md` section 7 | Speed and frame clock, not a crash [I] |
| 6 | CA on the A610: picture | [U]: black layers (`ios26-metal.md` B4). `LAUREL METAL26: screen: N of 64 samples lit` answers it |
| 7 | Brightness on 23F84 | CoreBrightness may now write `brightness-nits`, or `brightness` as on iOS 16: the driver takes both [V `setProperties`]. Which one: [U]. `DisplayBrightnessNitsNVRAM` is set at start [V replay]; the driver ignores it [V] |
| 8 | `SpringBoard`: started before backboardd is ready, in boot 9 too | `ios26-first-boot.md` section 8 |

## 7. Next boot

Kernel only: patch 9005 stops this crash. `RecoverOnCrash` is in the root.

```sh
scripts/bg.sh ios26-kernel scripts/laurel/kernel-ios26-linux.sh
scripts/bg.sh ios26-retry scripts/laurel/ios26-retry.sh rw      # the owner's yes for each write: boot_b, dtbo_b
scripts/laurel/phone-ssh.sh wait 300 && scripts/laurel/ios26-recover-off.sh    # on that boot: no reboot from the next boot on
```

Or a new root, which has both: `scripts/bg.sh ios26-root env FORCE=1 scripts/laurel/ios26-root.sh`, then the root steps of `dual-boot.md`. It prints `applied   jetsam RecoverOnCrash: removed from [...]`.

Expected, in order. A missing line is the result:

```
LAUREL BACKLIGHT: on: calibration for CoreBrightness: max 430, mid 107, min 840/1000 nits, table of 17 points; no digital dimming
LAUREL BACKLIGHT: on: DCS max 2047 (...); AppleARMBacklight published ...
NMTL[.. backboardd]: LAUREL METAL26: on: Metal device Turnip Adreno (TM) 610 for the compositor
IOK backboardd: matching ... backlight-control ... -> 1 found
```

And **no** `CRASH backboardd pc ...924` with `lr ...298`. Then, if the rest holds: `NMTL[.. backboardd]: LAUREL METAL26: first frame on a screen surface (720 x 1560, ...)`, `LAUREL FB CANVAS: first frame on the panel`, `LAUREL BACKLIGHT: first AppleARMBacklight brightness from backboardd`.

| You see | Meaning |
|---|---|
| The same pc again | The old kernel: read `LAUREL BUILD:` and the `calibration` line |
| `CRASH backboardd` at another pc | Real work of backboardd: section 6. Symbolize: unslide with `LAUREL DYLD: cache on: ... slide`, names from `tree/cache` (it has `.symbols`; `lowered/` has not) |
| `CRASH backboardd` again and again, no `<Critical>` | Expected with the new root: the phone stays up. `scripts/laurel/phone-ssh.sh` |
| `<Critical>: rebooting ...` | This root still has `RecoverOnCrash` |
