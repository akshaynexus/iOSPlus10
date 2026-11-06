# Mi A3 iOS 26: touch does nothing, red top bar

Date: 2026-11-02. Boot 10: `logs/ios26-boot10.txt` of the main checkout. **The fixes ran on the host only. No flash, no phone boot.** SSH to the phone timed out for this whole work (`Connection established`, no banner, also with 90 s). So all phone facts below come from the USB log. Labels: [V] read in code, disassembly or a file, or run here. [I] inference. [U] unknown. Addresses: unslid cache addresses of 23F84.

## 1. Touch: cause

**The kernel sends touch events in the wire format of iOS 16. 23F84 reads another format. The parser reads no finger and position 0.**

Topaz 0058 stages IOHIDFamily-1915.140.3, the version of iOS 16.7. The image `IOHIDLib` and HID.framework of 23F84 are version 2238.120.5 [V `ipsw dyld info`]. Two changes matter:

| Item | 1915 (the kernel, boot 10) | 2238 (23F84) | Evidence |
|---|---|---|---|
| Queue entry | one `IOHIDSystemQueueElement`, then N event records | **one header per event**, children too | `___IOHIDEventCreateWithBytesHelper` with w3 = 0 reads the header again in each round [V 0x197e51ff4]. `IOHIDEvent::readBytes` of the 2238 source [V] |
| Digitizer event | IOFixed, 104 bytes, type at +32 | **doubles, 160 bytes**: X at +16, Y +24, Z +32, index +40, type +44, identity +48, mask +52, button +60 | `_IOHIDEventCreateDigitizerEvent`: `mov w1, #160`, `str d12, [x8, #16]`, `str w24, [x8, #52]` [V 0x197e57118] |

The reader is not in the cache: `/System/Library/HIDPlugins/ServicePlugins/IOHIDEventServicePlugin.plugin`. It imports only `_IOHIDEventCreateWithBytesInternal` [V `llvm-nm`, call at +0xc94], with w3 = 0: raw bytes, **no conversion**. The public `IOHIDEventCreateWithBytes` (w3 = 1) converts the old layout for type 4, 11, 17, but no one takes that path for kernel events [V: `___IOHIDEventHasLegacyEventData`; 0 callers through the stub].

[V, real code] `scripts/laurel/test-ios26-hid.sh` gives the bytes of Apple's `IOHIDEvent.cpp` + our real `SweetHIDTouch::touch` to the real 23F84 parser under Unicorn. Today's kernel, one finger down at 0.5, 0.25:

```
HID event0  children   x0 0x0        no child event
HID event0  x          d0 0.000000   position lost
HID event0  y          d0 0.000000
HID event0  int-type   x0 0x0        no transducer type
HID event0  int-index  x0 0x27       the event mask, in the wrong slot
```

A key event has no child and its layout did not change (32 bytes; usage page +16, usage +18, down +20, press count +28 [V `_IOHIDEventCreateKeyboardEvent` and the kernel struct]). So the keys should work on this kernel [I]: the log shows `SWEET HID: key 0x30 down (1 clients)`, and no line shows the effect.

### What is not the cause

| Lead | Result |
|---|---|
| Driver `on` 32 s after the open | **Not the cause.** The service exists before the open. `sweet_hid_touch()` only needs `gSweetTouch`, and `dispatchEvent` goes through the client list [V code]. Keys print `(1 clients)` in the same way [V log] |
| IRQ, I2C, FT3518 | Works. `SWEET HID: touch 0 down at 439,1559 edge`, `up at 673,935 edge`: a real swipe up from the bottom edge, with the edge flag [V log 22:59:49]. Multi-touch too: `touch 1 down` [V log 22:59:57] |
| `esuc` user client ABI | Same selectors and queue. Only `copyEvent` gets a descriptor path, in 2238 [V diff of the sources] |
| Display association, `AppleMultitouchSPI`, `MTDevice`, `mtmergeprops`, HID filters | **Not needed on 23F84.** IOS-26-Hot has touch on 23F84 with the same service and the same 3 properties (`DisplayIntegrated`, `SurfaceWidth`, `SurfaceHeight`). Its 12 patches on `SweetHID.cpp` hold only corner masks, canvas sizes, its tap to wake and logs [V patch by patch, self-reported result]. The one difference for this bug is `0058-stage-iohidfamily.sh`: "iOS 26 HID wire format" |
| Struct `dispatchDigitizerEvent` of Apple's `IOHIDEventService` | Our service builds the events itself, so no such call exists |

## 2. Touch: fix

**`patches/laurel/xnu-12377/post/9006-laurel-hid-2238.patch`: Apple's IOHIDFamily-2238.120.5 in place of 1915, in the iOS 26 kernel only.** The iOS 16 kernel keeps 1915: no shared patch changes. `SweetHID.cpp`, `IOHIDEventService.h`, `IOHIDDebug.h`, `IOGraphicsTypes.h` of 0058 stay. No new boot-arg, no probe.

`scripts/laurel/ios26-hid-port.sh` makes the patch from Apple's two tags. 2238 has no generated headers in its source, so `IOHIDEvent{Types,StructDefs,FieldDefs,MacroDefs}.h` are the 1915 headers with the exact schema changes of IOS-26-Hot (MIT). Each change must match once, or the tool stops.

The kernel now does floating point in `IOHIDEvent::digitizerEvent` [V `scvtf`, `str d` in the binary], as Apple's kext. FP is on at EL1 [V `start.s`]. The kernel's own FP has never run on this phone in a thread that an IRQ preempts [U].

## 3. Touch: host results [V]

```
scripts/bg.sh ios26-hid-emu scripts/laurel/test-ios26-hid.sh
before: the parser reads no finger: True (the bug)
after: 39 of 39 values: down 0.5, 0.25, mask 0x27; move 0.5, 0.5, mask 4; up, touch 0, mask 3; type 2 (finger), identity 2, index 0; 1 child; collection
PASS
```

Kernel: `kernel-ios26-linux.sh`: 213 applied, 86 applied+rules, 8 skipped, 11 base, 0 errors; 0 linker failures; LSE/RCpc 0; printf-arg-check OK (limit 22); copyio table OK; armv80-check 0. 9006: `post`.

**Limits.** The test stops at the parser's getters. backboardd's event system, its digitizer filters and UIKit do not run. Hot's result on 23F84 is the only evidence past that point, and it is self-reported.

## 4. Touch: what to read on the phone

Kernel only. Nothing on the root changes.

| You see | Meaning |
|---|---|
| `LAUREL BUILD: <commit> ... ios26_4k`, a new series; `root ...: KERNEL SERIES DIFFERS` | Expected with the old root: only a note |
| Swipe up opens the Home Screen | Fixed |
| `SWEET HID: touch ...` and no reaction | The events reach the kernel, not the UI. Read `SMP backboardd` lines and `CRASH backboardd`. The next step is in backboardd's digitizer path: section 3 stops before it |
| `HID error:` or `HID fault:` lines | The 2238 user client refused something. The line says what |
| Power key stops working | A fault of this patch: the old kernel is the way back (`ios26-retry.sh` with the old image) |

## 5. Red top bar

### Settled 2026-11-03 [V 23F84 SystemStatusUI 0x276a0f8f4, phone boot 16]: the wrong stack was hooked

**SpringBoard's bar is `STUIStatusBar` of SystemStatusUI, not `_UIStatusBar` of UIKitCore.** The analysis further down is correct for UIKitCore only, so the hook on `_UIStatusBarVisualProvider_Split` is never reached in SpringBoard.

| Question | Answer |
|---|---|
| Is `UIStatusBarVisualProviderClassName` read? | By UIKitCore: yes. By `STUIStatusBarGetVisualProviderClassForScreen`: **no**. SystemStatusUI has no such string [V]. It reads PTSettings only: `STUIStatusBarSettingsDomain.rootSettings.visualProviderSettings.visualProviderClassName`, then `NSClassFromString` |
| Who picks the provider? | `STUIStatusBarGetNativeVisualProviderClassForScreenWithVisualProviderInfo` 0x276a3c0c8 -> `+[STUI.._iOS]` -> `+[STUI.._Phone]` 0x276a3c7b8 (rect y <= 0: `_Split`, y > 0: `_DynamicSplit`) -> `+[STUI.._Split visualProviderSubclassForScreen:visualProviderInfo:]` 0x276a98010 |
| Fallback in `_Split`? | None: 9 tables, then nil [V]. Nil -> `STUIStatusBarVisualProvider_Fallback`: `systemRedColor` background [V 0x276a58100] |
| Is the class there? | `STUIStatusBarVisualProvider_FixedSplit` exists, complete [V]. Method type `#32@0:8@16@24` [V] |
| Loaded in SpringBoard? | SpringBoard.framework links SystemStatusUI directly [V] |

The phone agrees: the pref file holds the right bytes (`od -c`, 123 bytes) and the UIKit hook gave no line. [U] The text `rdar:45025538` on the bar is in no C string of the cache in that form; the source of the text is not read. The red color and the log string are.

**Fix:** `liblaurel-notch.dylib` hooks `+[STUIStatusBarVisualProvider_Split ...]` too: nil on the embedded 360x780 @2 screen gives `STUIStatusBarVisualProvider_FixedSplit`. The UIKit hook stays with no line of its own.

| The line says | Meaning, next |
|---|---|
| `top bar: on: SystemStatusUI has no provider for 720 px: STUIStatusBarVisualProvider_FixedSplit` | Hook reached. The bar must be split, not red |
| `top bar: on: Apple's table gives ...` | Table matched |
| `top bar: off: SystemStatusUI gives no provider, and the screen ...` | Not the 360x780 @2 embedded screen: Apple's nil stays |
| `top bar: off: 60 s after the start SpringBoard did not ask ...` | Self-check. No bar asked for Split in 60 s. `UIKit asked: 1` says that the UIKit path ran |
| `top bar: off: no STUIStatusBarVisualProvider_Split/_FixedSplit ...` | Class or type changed |
| Crash at start | Crash guard of `laurel-springboard`: 2 fast exits, no dylib for this boot |

Host only: 0 warnings, armv80 0, no new library. **Not run on any UIKit.** [U] The look of `_FixedSplit` on 26: clock, cellular, Wi-Fi, battery, tap and swipe. [U] An app draws its own bar in its own process: the hook is not there, and the UIKit default applies.

### [V] 23F84 UIKitCore (not the bar of SpringBoard)

`_UIStatusBarGetVisualProviderClassForScreen` at 0x18a7e95a0:

1. `[screen _isEmbeddedScreen]` false: step 3 at once.
2. `_UIKitUserDefaults()` = `initWithSuiteName:@"com.apple.UIKit"` [V 0x1891771a0], `objectForKey:@"UIStatusBarVisualProviderClassName"`. **Same key and suite as 20H392.** An NSString, `NSClassFromString`, and that class or a superclass conforms to `_UIStatusBarVisualProvider`. `_FixedSplit` -> `_Split` -> `_Phone` -> `_iOS`, and `_iOS` conforms [V objc data]. So the name on the root is accepted.
3. `_iOS` -> `_Phone` -> `_Split`.
4. `_Split` tries the 9 tables. **New: no fallback to `_FixedSplit`.** No code of UIKitCore names that class any more [V: 0 references to `0x1ed3e3488`]. Only step 2 reaches it. A nil here is `_Fallback`, the red bar [V the one reference to that class, 0x18a7e9858].
5. No Dynamic Island or Jindo test is in this path: `_DynamicSplit` needs an exclusion rect with y > 0.

[V root] `private/var/mobile/Library/Preferences/com.apple.UIKit.plist`, 501:501, 0600, 123 bytes, and `.GlobalPreferences.plist` are in the image of boot 10. [V log] `exec laurel-springboard`, `exec SpringBoard`, `LAUREL CELLBAR: hooks in`: the wrapper inserts libraries into SpringBoard.

### [U] Why step 2 did not take effect in SpringBoard

The red bar means that step 2 gave nothing. Two ways remain: the default reads as nil in that process, or `_isEmbeddedScreen` is false. [I] Prefs work for other files (the lock screen shows, no Setup screen). [V] The kernel says `external` false and answers `IsMainDisplay`. Neither is proof. **SSH did not answer, and UIKit's line (`WARNING: Using overridden ...`, `No status bar visual provider ...`) goes to os_log only. So this is not settled.** I do not guess further.

### Fix

**`liblaurel-notch.dylib` now gives `_FixedSplit` when `_Split` gives nil on the 360x780 @2 screen.** It is what UIKit of 20H392 does with Jindo off. It holds whichever way step 2 failed. `_FixedSplit` inherits the IMP, so no loop: `_UIStatusBarGetVisualProviderSubclassForScreenWithVisualProviderInfo` calls a class only if its IMP differs from its superclass's [V 0x18a7e99d8]. Type encoding checked, `#32@0:8@16@24` [V objc data]. Self-check fails: one `off` line, Apple's nil stays.

- `LAUREL NOTCH` lines now go to `/dev/console` too, so the USB log shows them.
- The one `top bar: on:` line prints **what the default reads in SpringBoard and whether the screen is embedded**: that line settles the [U] above on the next boot.
- Scope: SpringBoard only (lock screen, Home Screen). An app draws its own bar in its own process: **if the default is the cause, an app can still show red**. The line and the look of an app decide the next step.
- `notch=0` turns it off with the rest of the dylib. The same source goes to the iOS 16 root. There step 2 works, so the new path is not reached [I].

Host: `notch-build.sh`: 0 warnings, armv80 0, 23F84 check: 2 libraries, 20 imports, 0 missing, page size 4096. Not run on any UIKit.

### Live

The next root build takes the dylib from `notch-build.sh`; `ios26-parity-build.sh` must check its new hash first. No spec change: `notch()` of `ios26-root-spec.py` installs that file. Live copy: see the report and `docs/plan.md`.

Expected:

```
LAUREL NOTCH: top bar: on: UIKit has no provider for 720 px and read the default as 'not set', embedded screen 1: _UIStatusBarVisualProvider_FixedSplit
LAUREL NOTCH: on: screen type 4 shape {...} pt -> waterdrop {135.2, 0.0, 89.6, 26.5} pt (...)
```

| The line says | Meaning, next |
|---|---|
| `'not set'`, embedded 1 | SpringBoard does not get the file from cfprefsd. Read the file on the phone: `ls -l /var/mobile/Library/Preferences/com.apple.UIKit.plist`, `od -c` of it |
| `'_UIStatusBarVisualProvider_FixedSplit'`, embedded 0 | The screen is not embedded: `-[UIScreen _isExternal]` / main display |
| No `top bar:` line, and no red bar | Step 2 works now |
| `top bar: off: ...` | Reason in the line |

## 6. Test fixes, same branch

- `dual-boot.sh`: `adb` is a function. Every call goes to the Mi A3 by serial, found at the first call. A host-only command asks no phone (16 cases of `ran: adb` are gone). **No Mi A3 on adb: no adb command runs at all.** The old block left a bare adb then, and a bare adb reaches the only other phone. It also takes state `recovery`, which the old block dropped. `timeout` is optional (stock macOS).
- `dual-boot.sh switch rw`: two empty header reads no longer count as "the same volume": the header must be HFS+ or HFSX, in full.
- `dual-boot-test.sh`: 10 new cases: a second phone (`status`, a full `switch`, only the other phone, a host-only command): the other phone gets only the product read, and no call goes out with no serial. Volume: rw after ro-on passes; read-only mode, no ro-on, another create date, another block count, no volume at all: refused. 161 cases, 0 failed.
- `ios26-retry.sh`: the installed `BootLockReceiver` restarts adbd at boot and undoes `adb root`. `to_root` reads root right before each step that needs it, and root must hold for two reads 3 s apart.

## Touch sample rate and priority (2997, from HakiOS 66b8e63 and Scion 357b437; built, NOT BOOTED)

The touch thread polled every 10 ms at the default priority 31 (`touch_wait(10)`, `kernel_thread_start`). 10 ms beats against the 16.7 ms frame: two samples in one frame, one in the next, so a dragged page moved unevenly [V HakiOS, `touch_lat=1`: at 8 ms a quarter of the frames came a refresh late]. 2997: 4 ms (a sample in every frame; 250 reads a second, a 16-byte read under 0.5 ms and a 63-byte one 1.4 ms on the 400 kHz bus: under 35 % busy) at priority 92 (`BASEPRI_PREEMPT`, the display presenter's). Why not 8 ms: 8 beats too (2 then 1 sample a frame); 4 costs 250 wake-ups a second of a kernel thread, nothing against the frame budget. The IRQ latch of 2200 and the read path are unchanged (2914 broke touch by changing them). Line: `LAUREL TOUCH FAST: on: a sample every 4 ms at priority 92`; kill switch `laureltouchfast=0`.
