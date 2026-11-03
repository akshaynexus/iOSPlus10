# Mi A3 iOS 26: Control Center, widgets, bluetoothd, tccd

Date: 2026-11-03. Branch `t3/laurel-control-center-modules`. Evidence: boot of 05:11 (`logs/usblog-20261103-000638.txt`, near its end), read-only copies of phone files, 23F84 cache and `bluetoothd`. Marks: [V] measured or read here, [I] inference, [U] unknown. Nothing here ran on the phone. No job is removed; `PERF_DROPS` stays off.

The unified log can be read with no Apple tool now: `tar cf - diagnostics uuidtext` in `/var/db` over SSH, then `scripts/laurel/ios26-unified-log.py DIAGNOSTICS UUIDTEXT [REGEX]`. Private arguments are in the file too: `strings -a` on the decompressed chunks shows them.

## Summary

| # | Item | Cause | Mark | Fix | Needs |
|---|---|---|---|---|---|
| 1 | Control Center has no modules | MobileGestalt says `arm64e` = false. Each of the 54 modules requires `arm64e` | [V] | Kernel `post/9011`: `LAUREL ARCH: on` | New kernel + a new MobileGestalt cache and LaunchServices store |
| 2 | Widgets `Waiting…` | The same answer: lsd drops each app extension | [V] | The same | The same |
| 3 | Add-control screen stuck | No proof. Not in the log | [U], [I] same cause | The same; read after the boot | |
| 4 | `bluetoothd` loop | The chip refuses LE Set Extended Scan Parameters; bluetoothd restarts on status 701 | [V] loop, [I] the chip | Kernel `post/9012`: `LAUREL BT SCAN: on` | New kernel |
| 5 | `tccd` CPU | Each new bluetoothd makes its clients ask tccd again | [V] counts, [I] the CPU link | `post/9012` | New kernel |

## 1. Why the modules are missing

Chain, each step read:

1. [V phone log, SpringBoard] Each `CCSModuleMetadata` line has `Required Device Capabilities`. All 54 have `arm64e`; `FlashlightModule` has `camera-flash` too. From `UIRequiredDeviceCapabilities` of each `Info.plist` [V files].
2. [V code] `-[CCSModuleRepository _queue_filterModuleMetadataByGestalt:]` 0x24b090718: `MGCopyMultipleAnswers(questions)`, and a module stays only when its capabilities are all known and true.
3. [V code] libMobileGestalt: capability `arm64e` (0x1b1c3f504) -> 0x1b1c2b670: `MGGetStringAnswer("CPUArchitecture") == "arm64e"`. `CPUArchitecture` (0x1b1c37de0) = `NXGetLocalArchInfo()->name`. libmacho: `host_info(HOST_PREFERRED_USER_ARCH)` (flavor 12), then flavor 1.
4. [V phone] The cache has `CPUArchitecture` = `arm64` (key `k7QIBwZJJOVw+Sej/8h8VA`), and `ksysctl hw.cpusubtype` gives 1. So `arm64e` is false.
5. [V phone log] No `Loadable module` argument for any of the 54. Only the two Conference modules load, by another path.
6. [V phone] `ControlsIconState.plist`: `iconLists` `[[]]`, from the first boot of this root. `checkInvalidModules()` and `checkAllInvalidControlIconElements()` run in the log. `ModuleConfiguration.plist` has its 6 defaults, but none can load. **This file stays empty after the fix unless it is removed.**

iOS 16 had Control Center because no such requirement stops it there: the same kernel answer (arm64) matches a 20H392 arm64 root [I: the 20H392 plists were not read here]. No script of the iOS 16 root touches Control Center [V grep]. IOS-26-Hot, UniXNU-ios26 and ios-flame have no fix of this answer in their tools or patches [V grep].

### The fix

`post/9011`, `osfmk/kern/host.c`: `HOST_PREFERRED_USER_ARCH` and `HOST_BASIC_INFO` give `CPU_SUBTYPE_ARM64E` to user space when the slot is arm64 ALL or V8. `hw.cpusubtype` follows, because it reads `HOST_BASIC_INFO`. The kernel's own grading (`cpu_subtype()`, `ml_grade_binary`) does not change. The donor is an iPhone12,1, whose true answer is arm64e, so each caller gets what it expects there. Users of `hw.cpusubtype` in the cache: kperf, kperfdata, perfdata, ktrace, PodcastsUI, ProVideo, DVTInstrumentsFoundation [V `ipsw dyld str`]. Kill switch `laurelarch=0`.

Not chosen: an edit of the cache plist (needs a phone-specific `CacheData`, and it does not survive a rebuild); a hook of `MGCopyMultipleAnswers` (lsd, chronod, SpringBoard and others all ask); an edit of each `Info.plist` (changes signed bundles, and the question stays wrong for others).

Not proven: that `NXGetArchInfoFromCpuType(arm64, 2)` gives `arm64e` on the phone: the name is in its table [V], the run is [I]. What runs next: SpringBoard loads about 50 bundles, and about 266 extensions get records, then descriptors [U load]. Other callers that change behaviour on this answer [U].

## 2. Widgets: the same cause

- **Not fixed on this boot** [V]: csstore (15 MB, both stores): `com.apple.weather.widget` 0, `com.apple.mobilenotes.WidgetExtension` 0; `com.apple.widgetkit-extension` 22 and `com.apple.posterkit.provider` 22: those are points and system ones. Paths with `PlugIns`: 4 only: StickersUltra's (the executable of an app record) and 3 of frameworks. `chrono.sql`: `ExtensionMetadata` 4, `Descriptors` 4, `WidgetMetadata` 0: ToggleAirplaneMode, ToggleCellularData, PersonalHotspotControl, ControlCenterControlsExtension.
- [V phone log, private text of lsd] 639 lines, 614 different ids: `Ignoring app extension com.apple.weather.widget because it is not applicable to this device's capabilities: ... CapabilitiesMatch = 0; MismatchedCapabilities = { arm64e = 0; }`. Every mismatch is `arm64e` only (1278 lines of 1278).
- [V code] `-[MIBundle _filterExtensionBundles:forValidationFlags:]` 0x1b331ca6c -> `isApplicableToCurrentDeviceCapabilitiesWithError:` -> `-[MICapabilitiesManager checkCapabilities:withOptions:error:]`.
- [V phone] All 266 `.appex` in `/Applications/*/PlugIns` have `arm64e`. So do the ExtensionKit ones, which are scanned by another path (`_scanExtensionKitDirectory`) and get records.
- [V log] `missing extension cache entry`: 0 lines. `Failed to read extension point cache`: 0 lines. So the catalog line `enforce_xpc_cache_code_signing` of `ios26-wallpaper-widgets.md` was not the limit on this boot. It stays; it is harmless.
- [V log] chronod: `Reload failed ... ChronoCoreErrorDomain Code=1 "Unknown extension process"`. It comes from the missing record. Then `SBHWidget displayName` gives `Waiting…` [V, earlier doc].

### chronod and Metal

[V] The widget failure comes before any drawing. The denial in `clients` is not the cause. `WidgetRenderer_Default` has its device and ran. The `-chronod` line stays.

[V log, not fixed] chronod writes its control icons as HEIC: `writeImageAtIndex:1311: CMPhotoCompressionSessionAddImage: err = kCMBaseObjectError_UnsupportedOperation`, then `ImageIOError.unableToFinalizeImageDestination` (28 times, `com.apple.Preferences`), and 15 empty files in `/var/mobile/Library/chronod/icons`. There is no HEVC encoder here (the decoder only). [I] A control can lose its icon. [U] If this stops the gallery. Not Metal: it is CMPhoto. Next item if controls show with no icons.

## 3. The add-control screen

[U] The log has no line of the hang: the gallery code logs little, and no crash. `ControlsGalleryManager` (ControlCenterUIServices) has a loading queue and lists custom collections from modules plus controls from extensions. [I] With 0 modules and 4 extensions it has almost nothing to list, so the cause can be the same. Read after the new boot: R1.

## 4. bluetoothd and tccd

- [V log] `Could not start LE scan (leScanParamsLPCoreCb): STATUS 701` (91) and `(leScanParamsCb): STATUS 701` (34) = 125. `Bluetooth error - restarting { build=release, reason=701 }` = 125. 119 processes. So a new bluetoothd each 10 s: launchd's throttle, `LAUREL BT: ios: client gone` in the kernel log.
- [V code, bluetoothd 23F84] Both callbacks follow command table id 0xd7 (0x10008c34c, 0x100084838) or 0xab. Table at 0x100b3dc68, 24 bytes each: id 0xd7 = opcode 0x2041, id 0xab = 0x200b. The flag at 0x100b5660e selects 0xd7.
- [V code] The kernel's `lbt_local_answer` answers OGF 0x3f only. So status 1 of an LE command comes from the chip [I: only one left; a chip refuses no 0x200b]. The chip (soc 0x40070120) lists 0x2041 as supported, or bluetoothd would get 628 and not 701 [V table mask, I].
- [V] The string `rv=0x100` is in no log of this boot: neither USB nor unified. Its source is [U].
- Other errors, no restart: `SubOpcode Incorrect STATUS 701` (394: `BD_VSC_MATCHTABLE_CONFIG`, `BD_VSC_ADVBUF_CONFIG`: Broadcom commands that the kernel answers with status 1), `LE_InitMultipleAdvertising failed STATUS 105` (127).

`post/9012`, `bsd/dev/laurel_bt_h4.c`: 0x2041 -> 0x200b and 0x2042 -> 0x200c on the way to the chip, the answer back under the extended opcode, LE event mask bit 1 kept on, and each legacy report up as one extended report (subevent 0x0d). Kill switch `laurelbtscan=0`. Host test: `scripts/laurel/test-bt-scan.sh`, real code of the patch under ASan and UBSan: PASS.

Not proven: bluetoothd's next limit after the scan starts [U]. The owner's bluetooth settings path is not touched.

**tccd** [V log, 53,355 lines]: most are `kTCCServiceBluetoothAlways` from sharingd, searchpartyd, rapportd, locationd, bluetoothd, each `Unable to construct an identity` (Code 2). Each new bluetoothd brings them again. [I] So the CPU follows the loop. At 05:17 tccd had 3.4 % and 12 s of time [V `ps`], so the 84 % was a burst. The identity error itself: [U], no fix. `healthd` and FitnessIntelligence: no cause was looked for [U].

## Host results

[V] `kernel-ios26-linux.sh`, both patches: `LAUREL BUILD: d035476edb 347 patches, series bdd4abcff8aaca74, ios26_4k`; series 226 applied, 86 applied+rules, 8 skipped, 11 base, 0 errors; printf-arg-check OK; armv80-check 0; 251 s. `test-bt-scan.sh` PASS. Not booted.

## What the phone needs

| Change | Way |
|---|---|
| `post/9011`, `post/9012` | New boot image (`kernel-ios26-linux.sh`, then `ios26-image.sh`). No root change |
| Old answers in `/var` | `dual-boot.sh install` erases them. **Or** the test write below, with no new root |
| Root items of `ios26-wallpaper-widgets.md` | As that doc says |

### Test write, only if the owner allows it (after a boot of the new kernel)

```sh
rm /var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
rm /var/mobile/Containers/Data/InternalDaemon/470B1F70-CD18-4CC9-8E92-72A74A3A9FDC/Library/Caches/*com.apple.LaunchServices-*.csstore
rm /var/mobile/Library/ControlCenter/ControlsIconState.plist /var/mobile/Library/ControlCenter/ControlsMigrationSettings.plist
# then a reboot by the owner. The first boot seeds again: minutes of work, as on a new root.
```

## Reads after the boot

Expected: `LAUREL ARCH: on`; `LAUREL BT SCAN: on`; one `exec bluetoothd`, not one each 10 s; `exec WeatherWidget`.

- **R1**: the plist `iconLists`; csstore count `com.apple.weather.widget` above 0; `chrono.sql` `ExtensionMetadata` many; unified log `Ignoring app extension` 0. If the add screen still hangs: a `ps` of chronod and SpringBoard at that moment, and the log of that minute.
- **R2**: if `CPUArchitecture` is not `arm64e` in the new MobileGestalt plist, `post/9011` missed a caller.
