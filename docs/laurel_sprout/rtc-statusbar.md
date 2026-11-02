# Mi A3: clock from the PM6125 RTC + USB settime (kernel 2720), status bar layout at 360x780 pt and the waterdrop (root)

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

**iOS 26 (23F84):** SpringBoard's bar is `STUIStatusBar` of SystemStatusUI. It does not read this key. See `ios26-touch.md` section 5. The text below is iOS 16 (20H392).

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
[V, part C] With iPhone X answers (gesture home, artwork 2436) and 360x780 @2 it falls back to screen type 4 (D22Zoomed, a notched
type), so `_Phone` takes `_Split` (we saw the red bar, not the legacy bar).

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

No red bar: a split bar (time left, battery and signal right). UIKit logs (os_log, not in the kernel console)
`WARNING: Using overridden status bar visual provider class: _UIStatusBarVisualProvider_FixedSplit`.
The notch that FixedSplit uses comes from SpringBoard; without part C it is the D22Zoomed fallback (iPhone X notch, centred for a
320 pt screen): time centred at x 41.5 pt, a 178 pt free centre. Part C below replaces it with the waterdrop.
If an app still shows the red bar inside the app, its sandbox did not read the key: check `.GlobalPreferences.plist` in the root.

## C. Top bar for the waterdrop: notch rect, safe area, bar height (root + SpringBoard dylib)

2026-11-01, branch `t3/laurel-statusbar2` (base `laurel-int-1` 7a3bf26). Owner: "fix the top bar display on this device properly
given it's a weird resolution". NOT BOOTED; host test only.

### The Mi A3 screen [V source]

| Item | Value | Source |
| --- | --- | --- |
| Panel | 720x1560 px AMOLED (19.5:9); iOS canvas 360x780 pt @2 (2103) | hardware-map.md, uefi-boot.md |
| Waterdrop | `config_mainBuiltInDisplayCutout` = `M -89.6 0 C -65.1 0 -51.2 0.2 -37 31.3 C -29.3 44.1 -15.5 53 0 53 C 15.5 53 29.3 44.1 37 31.3 C 51.2 0.2 65.1 0 89.6 0 L -89.6 0 Z` (px, origin top centre): 179.2 px wide at the top edge (curved shoulders), 74 px wide at y 31.3, 53 px deep | `laurel-device-los` `overlay/frameworks/base/core/res/res/values/config.xml:176` |
| In points | {135.2, 0, 89.6, 26.5} pt, centred | /2 |
| Corners | `rounded_corner_radius` 75 px = 37.5 pt; `rounded_corner_content_padding` 35 px | same overlay, `values/dimens.xml:34-37` |
| Android bar | `status_bar_height_default` 35 dp (= 35 pt here: 320 dpi, 1 dp = 2 px) | `values/dimens.xml:23` |

### Where iOS takes each value [V 20H392 iPhone10,3 cache; `scripts/debug/statusbar-re.sh` reproduces all of it]

1. **Layout class** (time/battery placement, bar height): UIKit, in every process: FixedSplit by part B. `_Split +height` = 47 pt,
   FixedSplit inherits it (Split1125 = iPhone X: 44, Split1080 = 12 mini: 50). Fixed per class: no default, no MobileGestalt key.
2. **Notch rect** (`UIScreen _exclusionArea`): SpringBoard -> every app. `+[UISDisplayContext(SpringBoard)
   sb_embeddedDisplayDefaultContext]` sets `exclusionArea = +[UISDisplaySingleRectShape sb_thisDeviceDisplayShape]` =
   `sb_displayShapeForScreenType: SBHScreenTypeForCurrentDevice()`.
3. **Safe area, home affordance**: same context, `displayEdgeInfo = sb_thisDeviceDisplayEdgeInfo` -> per screen type.
4. **Screen type**: `__SBHScreenTypeLookup(SBFEffectiveDeviceClass, SBFEffectiveHomeButtonType, SBFEffectiveArtworkSubtype,
   reference bounds, scale)`. Each type = {bounds, scale, artwork subtype (0 = any), home button type}; the bounds and scale must
   be equal. 360x780 @2 is in no entry. Then the fallback for a gesture phone compares only the bounds with
   430x932 (D74), 428x926 (D54), 414x896 (D33), 393x852 (D73), 390x844 (D53), 375x812 (D22), else **type 4 = D22Zoomed**
   (iPhone X display zoom: 320x693 @3, artwork 2436). (Home-button answers would give type 0 = N41, an iPhone 5.)
5. **D22Zoomed values**: shape = D22's notch in px (627x90 at x 249) / its native scale (3 x 375 / 320 = 3.516) =
   {70.8, 0, 178.3, 25.6} pt: centred at x 160 (a 320 pt screen), ours is 360 pt. Edge info: safe area top 38, bottom 29,
   left/right 0; home affordance overlay allowance 21. (D22: 44 / 34.)
6. **FixedSplit placement** [V `-leadingCenteringEdgeInset`, `-_edgeInsetsFromCenteringEdgeInset:trailing:`]: the time is centred at
   c = notch.x / 2 + 0.15 x corner radius (pixel-rounded), the battery/signal group at width - c; the regions end at
   (referenceWidth - notch width) / 2 from each side. referenceWidth = nativeBounds.width / scale = 360. Top inset 14.67 pt.
7. **Corner radius** (`UIScreen _displayCornerRadius`): UIKit default `DisplayCornerRadiusOverride` (internal), else the initial
   device context, else MobileGestalt `DeviceCornerRadius` (iPhone X answer, 39 pt [I: public value]).

So the MobileGestalt answers cannot fix the notch: the screen type depends on the bounds first, and no artwork subtype has a
360x780 @2 entry. `ArtworkDeviceSubType` stays 2436 (gesture identity). DeviceCornerRadius 39 vs the panel's 37.5 moves the time by
0.15 x 1.5 = 0.2 pt: not changed (a MobileGestalt cache edit is not worth the risk for that). `main-screen-*` answers already come
from the 720x1560 @2 canvas (2103).

### Options

| Option | Look on 360x780 | Verdict |
| --- | --- | --- |
| `_LegacyPhone` (iPhone 8 bar, no split) | 20 pt bar, **time in the centre** | no: the waterdrop is 26.5 pt deep and centred: it covers the time; also needs a home-button screen type |
| `_Split1080` (12 mini, 360 pt reference width) | fixed 226x34.3 pt notch, 50 pt bar | no: fixed notch, wider than D22Zoomed; nativeDisplayWidth 1080 fixed |
| `_Split1125` (iPhone X) | 44 pt bar, layout for 375 pt | no: insets for a 375 pt width, the right group moves off |
| FixedSplit + Apple's D22Zoomed shape (part B alone) | time at x 41.5, group at 318.5, 178 pt free centre | works, iPhone X spacing; the fallback when the dylib is off |
| **FixedSplit + waterdrop shape (part C)** | **time at x 73.5, group at 286.5, regions end at 135.2 / 224.8 (89.6 pt free centre = the drop)** | **chosen** |

FixedSplit centres each group in its "ear" (iPhone design). With the real drop the ears are 135 pt wide, so the groups sit near
the middle of each ear, at the drop's sides, not at the screen corners.

### What part C does

- `userland/laurel/notch/laurel_notch.c` -> `/usr/local/lib/liblaurel-notch.dylib`: in SpringBoard, replaces the implementation
  of `+[UISDisplaySingleRectShape(SpringBoard) sb_displayShapeForScreenType:]` (type encoding checked: `@24@0:8Q16`). For the
  current screen type it returns `initWithRect:{135.2, 0, 89.6, 26.5}`; other types (classic-mode apps) keep Apple's shapes.
  Self-check at the first shape request: SpringBoard, the methods exist, `SBHScreenTypeForCurrentDevice` /
  `__sb__mainScreenReferenceBounds` / `__sb__mainScreenScale` resolve (no UIScreen: the main-thread-free path also asks), the
  screen is 360x780 @2. Else Apple's shape stays and one `off:` line says why.
- `userland/laurel/notch/sb_wrap.c` -> `/usr/local/libexec/laurel-springboard`: the launchd job `com.apple.SpringBoard` starts it
  (ProgramArguments[0]); it sets `DYLD_INSERT_LIBRARIES` and execs Apple's SpringBoard at its own path (same pid, Mach services,
  SpringBoard.app unchanged). Kill switch boot-arg `notch=0`; crash guard: after 2 starts within 30 s of the previous one in a
  boot, no dylib for that boot (`/var/tmp/laurel-sb.state`). launchd drops DYLD_* from job plists (ios-topaz bbd_wrap.c), so a
  start program is needed. Same pattern as the backboardd GL wrapper (bbd_wrap.c), but SpringBoard's binary is not moved.
- Safe areas, home affordance and the bar height are **not changed**: top 38 pt = drop 26.5 + 11.5 pt (Android: 35), bottom 29,
  home affordance 21, bar view 47 pt (FixedSplit, every process; a per-app change would need code in every app).
- `scripts/laurel/notch-build.sh` builds both (gpu-env.sh toolchain: clang + theos ld64/ldid + iPhoneOS16.5.sdk; ad-hoc signed,
  ARMv8.0 checked, only /usr/lib dependencies). `scripts/laurel/root-statusbar.py` (root.sh) installs them (root:wheel 755, Mach-O
  + signature check) and edits the job; without the build output it prints a note and leaves Apple's start program.
  `NOTCH=0` gives the job back to Apple's SpringBoard; `STATUSBAR=0` skips B and C.

### Host checks

- `python3 -I scripts/laurel/root-statusbar.py --expect`: the geometry above, from the Lineage path (or a built-in copy).
- `python3 -I scripts/laurel/root-statusbar.py --check MOUNTED_ROOT`: the four UIKit plists, the SpringBoard job, the two files
  (Mach-O, owner, mode, sha256). Exit 0 when part B is complete.
- Done 2026-11-01 [V] on a copy of the 20H392 `launchd.plist` (`out/sb2-test`): install, second run, `NOTCH=0` undo, `STATUSBAR=0`;
  the only launchd.plist change is ProgramArguments of com.apple.SpringBoard. Build: 0 warnings, 0 ARMv8.1+ instructions.

### Expected look and lines

- Lock screen, home screen, apps: time centred about 73 pt from the left edge, battery + signal (+ Wi-Fi) centred about 73 pt
  from the right edge, both clear of the drop; nothing in the 89.6 pt above the drop. Control Center grabber under the right group.
  Content starts 38 pt from the top; home indicator in the bottom 29 pt.
- `/var/tmp/laurel-notch.log` and syslog: `LAUREL NOTCH: /usr/local/lib/liblaurel-notch.dylib inserted into SpringBoard ...`, then
  `LAUREL NOTCH: on: screen type 4 shape {70.8, 0.0, 178.3, 25.6} pt -> waterdrop {135.2, 0.0, 89.6, 26.5} pt (...)`.
  Off cases: `off: notch=0 in the boot-args`, `off: SpringBoard exited N times within 30 s`, `off: main screen 375x812 pt @3.00 is not
  the native 360x780 @2 canvas` (sweetfb_native=0), `off: UISDisplaySingleRectShape has no ...`. "inserted" without an on/off
  line = dyld did not load the dylib.
- [U] Not seen on the phone: the exact vertical place of the time in the 47 pt bar; whether launchd starts a job whose
  ProgramArguments[0] is not Apple's binary with POSIXSpawnType App (the BT stand-in job does the same for BlueTool, a daemon).
- Recovery: boot-arg `notch=0`, or `NOTCH=0` root rebuild. If SpringBoard does not come up at all: the crash guard turns the dylib
  off after 2 fast exits; if the start program itself fails, it logs `exec of ... failed` (the job then needs `NOTCH=0`).

## Tools

- `scripts/debug/dsc-annotate.py DSC < listing`: adds objc selectors (objc_msgSend stubs), class names (class refs),
  C strings, CFStrings and doubles to `ipsw dyld disass` output of the iOS 16 arm64 cache (ipsw 3.1 cannot parse its objc
  info). `--read ADDR N` dumps pointers.
- `scripts/debug/statusbar-re.sh`: the analysis above in one run (annotated listings in `out/re-statusbar/`); part C adds the screen
  type lookup, the type names + fallback sizes, the shape and edge-info tables, FixedSplit centring, the corner-radius sources.
  `IPSW=... DSC=...` select another ipsw binary / cache.
