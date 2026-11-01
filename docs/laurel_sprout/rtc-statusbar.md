# Mi A3: clock from the PM6125 RTC + USB settime (kernel 2720), status bar layout at 360x780 pt (root)

2026-11-01, branch `t3/laurel-rtc-statusbar` (base `laurel-int-1` 6e0af80). Labels: [V] measured or read in source or
binary, [I] inference, [U] unknown. NOT BOOTED.

Seen on the phone (photos of the lock screen, 2026-11-01 06:50, first GPU-drawn UI) [V]:
1. "Wednesday, December 31", about 4:02 PM = 1970-01-01 00:00 UTC + uptime, in Pacific time: no time source.
   USB log: `==== usblog: settime: error: unknown command` and `LAUREL CTL: "settime 1793492561.428602" ... unknown command`.
2. A red bar with "rdar:45025538" at the top, above the clock.

## A. Clock: PM6125 RTC + offset, USB settime (patch 2720)

### Cause [V source]

- `SweetPlatformExpert` (topaz) has no `getUTCTimeOfDay()`: `IOPlatformExpert::getUTCTimeOfDay` gives 0, so
  `clock_initialize_calendar()` (bsd_init -> `IOKitInitializeTime`) starts the calendar at the epoch. Patch 2000 only removed
  the 30 s IORTC wait.
- The laurel command server (2005) had no `settime` (not ported from negroni 0212): `usblog.sh` got `error: unknown command`.

### Hardware facts [V source]

| Item | Value | Source |
| --- | --- | --- |
| RTC block | PM6125 SID 0, RTC_RW 0x6000 (alarm 0x6100), `qcom,qpnp-rtc` | `laurel-kernel-los` `qcom/pm6125.dtsi:163-178` |
| Registers | subtype 0x6005 = 0x01 (RTC_RW), ctrl 0x6046 bit 7 = enabled, counter 0x6048..0x604b (LE seconds), write 0x6040 | `drivers/rtc/qpnp-rtc.c:28-48` |
| Read rule | 4 bytes, then byte 0 again; smaller byte 0 = carry: read the 4 bytes again | `qpnp_rtc_read_time()` |
| Write | `qcom,qpnp-rtc-write = <0>`: Linux never writes the counter (read-only rtc_ops) | `pm6125.dtsi:167`, `qpnp-rtc.c:596` |
| Android offset | userspace `time_daemon` keeps it in `/data/vendor/time/` (and the modem over QMI) | `sm6125-common-los` `init.qcom.rc:293,742`, `proprietary-files.txt:690` |

[I] The raw counter therefore runs from the first PMIC power-up and is usually not wall time (likely a value in 1970-1972).
The Android offset is on the old Android userdata, which the iOS root replaced: not reachable. ABL passes no time to the kernel
[I: no time item in the ABL boot-args/DT that we use]. So: use the RTC as a seconds base and keep our own offset.

### What 2720 does

- New `bsd/dev/laurel_rtc.c` (port of negroni 0203): `SweetPlatformExpert::getUTCTimeOfDay/setUTCTimeOfDay` ->
  `laurel_rtc_get/_set`. Every SPMI access goes through the one core (`sweet_spmi.c`, 2710): new user `SWEET_SPMI_RTC`,
  `sweet_spmi_apid(0, 0x60)`, `sweet_spmi_ext_read` (reads only; the users/errors lines now list `rtc`).
- Sources of the calendar, in order: a host `settime`; `settimeofday()` (iOS timed, later NTP); RTC + the offset saved in
  `/private/var/db/laurel_rtc` (applied in bsd_init after the root mount, before launchd); the RTC alone when its counter is
  already 2020..2100; else the build-date floor (00:00 UTC of `__DATE__` minus 1 day). A counter that went backwards (PMIC reset)
  makes the saved offset invalid; the saved wall time is then a floor.
- Each new offset goes to `/private/var/db/laurel_rtc` (text: `laurel-rtc 1`, `offset`, `rtc`, `wall`) from a thread call;
  while the root is read-only it tries again every 30 s, 60 times.
- **The PMIC is never written.** The DT forbids RTC writes (`qpnp-rtc-write = <0>`), the APID owner is not checked to be EE 0, and
  a write needs the enable bit cleared (a stopped RTC if it fails). The offset file gives the same result without that risk.
- Self-check: SPMI core up, 0x6000 has a channel, subtype 0x01, enable bit set, counter readable. Else one line
  `LAUREL RTC: off: <why>` and the calendar runs from settime / the saved wall time / the build date (no PMIC access).
  Kill switch: boot-arg `laurelrtc=0`.
- USB commands (`sweet_usb.c`, port of negroni 0212), also in early (raw) mode, refused in panic mode:
  - `settime <s>[.<frac>]` (2020..2100): never blocks (the early service runs in a timer call). The value is queued with its
    `mach_absolute_time`; `ud_thread` applies it within 1 ms with `clock_set_calendar_microtime()` (-> `laurel_rtc_set`: new
    offset, saved). If it comes before the calendar starts, `clock_initialize_calendar()` takes it directly. Reply
    `ok settime <s>.<us>`.
  - `time`: reply `time <s> rtc <raw> offset <n> source <...>` (no SPMI access).
- `IOKitInitializeTime`: the 2000 line is now `LAUREL IORTC: no IORTC wait, calendar from the platform expert` (so
  `LAUREL RTC: on/off` means the RTC only); it waits at most 10 s for the platform expert (negroni 0203).

### Expected lines

First boot after this kernel, no saved offset yet (the usual case [I]):
```
LAUREL IORTC: no IORTC wait, calendar from the platform expert
LAUREL RTC: off: counter N s (1970-..-.. ..:..:.. UTC) is not wall time and its offset is unknown (Android keeps it in /data/vendor/time); calendar from the build date 2026-10-31 00:00:00 UTC until a settime or the saved offset (APID A owner EE E)
LAUREL RTC: /private/var/db/laurel_rtc: no saved offset yet (calendar ... s)
LAUREL CTL: "settime 1793492561.428602" -> ok settime 1793492561.428602        (early mode) or LAUREL CTL: ok settime ...
LAUREL RTC: on: 2026-11-01 06:50:12 UTC (raw N + offset M, set by settimeofday or settime)
LAUREL CTL: settime 1793492561.428602: clock set (was 1793404900.123456, RTC offset M)
LAUREL RTC: saved offset M (wall 1793492561) to /private/var/db/laurel_rtc       (maybe after "not written (error 30): again every 30 s")
```
Next boots (also without the host): `LAUREL RTC: /private/var/db/laurel_rtc: RTC + saved offset (calendar ... -> T)` and
`LAUREL RTC: on: <date> (raw N + saved offset M)`. If the counter is already wall time:
`LAUREL RTC: on: <date> (raw N, ctrl 0x80, APID A owner EE E, offset 0)`.
Failure: `LAUREL RTC: off: <reason>` (e.g. `RTC not enabled (ctrl 0x6046 = 0x0)`, `PM6125 RTC_RW 0x6000 has no SPMI channel`).
Host check: `out/bin/op10tool ctl time`. The `LAUREL SPMI: on: ... users: pon keys battery haptic rtc; spmi errors ... rtc 0`.

[U] The raw counter value and the APID owner are not measured; the first boot prints both.

## B. Status bar: red rdar:45025538 bar at 720x1560 @2x (root change)

### Cause [V binary: 20H392 iPhone10,3 UIKitCore and SpringBoard, read with `scripts/debug/statusbar-re.sh`]

`_UIStatusBarGetVisualProviderClassForScreen` (UIKitCore 0x1891aaa80):
1. For an embedded screen it first reads the NSUserDefaults suite `com.apple.UIKit`, key `UIStatusBarVisualProviderClassName`
   (block 0x1891d2c6c: `initWithSuiteName:@"com.apple.UIKit"`). If it is an NSString, `NSClassFromString` finds a class and
   that class or one of its superclasses conforms to the protocol `_UIStatusBarVisualProvider` (`class_conformsToProtocol`
   up the `class_getSuperclass` chain), that class wins and UIKit logs
   `WARNING: Using overridden status bar visual provider class: %@`.
2. Else `_UIStatusBarVisualProvider_iOS +visualProviderSubclassForScreen:` -> by `traitCollection.userInterfaceIdiom`:
   phone -> `_Phone`.
3. `_Phone` (0x189ab546c): `UIScreen _exclusionArea` without a rect -> `_LegacyPhone` (home-button style); rect origin y > 0
   (an island) -> `_DynamicSplit`; else -> `_Split`.
4. `_Split` (0x189ab566c, block 0x189ab58a8): tries Split1125, 1080, 1080_Wide, 1170, 1170_Wide, 1242, 828, 1284, 1284_Wide.
   A class matches only if `+nativeDisplayWidth == UIScreen _nativeDisplayBounds.width` (pixels, +-0.0001) and `+notchSize ==`
   the exclusion area (scaled by nativeScale / referenceScreenScale). Widths: 828, 1080, 1125, 1170, 1242, 1284 px.
   No match: `os_feature_enabled(SpringBoard, Jindo)` true -> nil; false -> `_FixedSplit`.
5. nil -> `No status bar visual provider for screen %@ (width: %.2f, scale: %.2f, idiom: %ld, cornerRadius: %.2f). Please see
   rdar://45025538.` and `_UIStatusBarVisualProvider_Fallback` = the red bar.

The Mi A3 screen is 720 px wide (2103: native canvas, display-scale 2 = 360x780 pt). 720 is in no list -> step 4 gives nil -> red
bar. The exclusion area comes from SpringBoard: `+[UISDisplayContext(SpringBoard) sb_embeddedDisplayDefaultContext]` ->
`sb_thisDeviceDisplayShape` -> `sb_displayShapeForScreenType:` of `SBHScreenTypeForCurrentDevice()` = `SBHScreenTypeLookup(
SBFEffectiveDeviceClass, SBFEffectiveHomeButtonType, SBFEffectiveArtworkSubtype, main screen reference bounds, scale)`.
[I] With iPhone X answers (gesture home, artwork 2436) and 360x780 @2 it falls back to a notched screen type, so `_Phone` takes
`_Split` (we saw the red bar, not the legacy bar).

`_FixedSplit` [V]: `-nativeDisplayWidth` = `UIScreen nativeBounds.width`, `-referenceWidth` = that / scale, `-notchRect` = the
screen's exclusion area scaled, edge insets from the notch rect and the corner radius: a split layout for any width. It is
UIKit's own choice for an unmatched notched screen when Jindo is off.

### Options and the choice

| Option | Result | Why not / why |
| --- | --- | --- |
| Present 1125x2436 @3x (iPhone X, topaz 0061) and scale down 0.64 | Split1125, fully consistent with D22AP/iPhone10,3 | 2.44x the pixels on the A610; the kernel has no scaler (before 2103 it cropped the centre 64 %); touch (2200) and canvas (2103) change |
| Present 828x1792 @2x (XR layout) and scale 0.87 | Split828 | same scaling problem; artwork/screen type would not match the iPhone X identity |
| 720x1560 @2x, no exclusion area (`_LegacyPhone`) | iPhone 8 bar | needs a home-button screen type: home-button UI on a phone without one; clock in the centre under the notch |
| 720x1560 @2x, island exclusion area (`_DynamicSplit`) | 14 Pro bar | needs a 14 Pro artwork/screen type: SpringBoard island code paths on a phone without an island |
| Feature flag SpringBoard/Jindo off in the root | `_FixedSplit` | same provider, but the flag reaches far into SpringBoard |
| **UIKit default `UIStatusBarVisualProviderClassName = _UIStatusBarVisualProvider_FixedSplit`** | `_FixedSplit` | **chosen**: UIKit's own override, embedded screens only, nothing else changes; keeps 720x1560 @2x (2103), the touch map (2200), the ADT identity and the GPU cost |

### Change

`scripts/laurel/root-statusbar.py` (called by `scripts/laurel/root.sh`; `STATUSBAR=0` skips, `STATUSBAR_PROVIDER=<class>`
picks another class) writes the key into `com.apple.UIKit.plist` and `.GlobalPreferences.plist` of mobile (501, 0600) and
root (`/private/var/{mobile,root}/Library/Preferences`), keeping all other keys. The global domain is there because a suite
searches the global domain after its own [I: NSUserDefaults rule], and every process, also a sandboxed app, can read it.

**A root rebuild is needed** (`scripts/bg.sh laurel-root sudo scripts/laurel/root.sh`, then a userdata flash with the owner's
approval). No kernel change for B. With `sweetfb_native=0` (iPhone X canvas) `_FixedSplit` still works (it adapts).

### Expected result

No red bar: the time left of the notch, the battery and signal right, as on an iPhone X. UIKit logs (os_log, not in the kernel
console) `WARNING: Using overridden status bar visual provider class: _UIStatusBarVisualProvider_FixedSplit`.
[U] The notch rect = SpringBoard's fallback screen type shape, not the Mi A3 dewdrop: the gap between the time and the
battery can be wider than the real notch. [U] The home screen grid also uses that fallback screen type (looked normal on topaz).
If an app still shows the red bar inside the app, its sandbox did not read the key: check `.GlobalPreferences.plist` in the root.

## Tools

- `scripts/debug/dsc-annotate.py DSC < listing`: adds objc selectors (objc_msgSend stubs), class names (class refs),
  C strings, CFStrings and doubles to `ipsw dyld disass` output of the iOS 16 arm64 cache (ipsw 3.1 cannot parse its objc
  info). `--read ADDR N` dumps pointers.
- `scripts/debug/statusbar-re.sh`: the analysis above in one run (annotated listings in `out/re-statusbar/`).
