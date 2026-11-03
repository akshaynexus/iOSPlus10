# Mi A3 iOS 26: wallpaper, widgets, BlastDoor, pc 0

Date: 2026-11-03. Branch `t3/laurel-ios26-wallpaper-widget-fixes`. Evidence: `logs/usblog-20261103-000638.txt` (main checkout), 23F84 donor files and cache. **Host only. No adb, SSH, fastboot or flash.** Marks: [V] measured or read here, [I] inference, [U] unknown. Nothing here has run on the phone. No job is removed; `PERF_DROPS` stays off.

## Summary

| # | Item | Cause | Mark | Fix | Needs |
|---|---|---|---|---|---|
| 1 | Black wallpaper | SpringBoard waits for a poster. No poster extension ran in any boot of the log, and PosterBoard asked no Metal device | [V] facts, [U] why no provider runs | Hook `wallpaper`: Autobahn flags off, `Lock/HomeBackground.cpbitmap` from 23F84's own default | New root |
| 2 | Top widgets white, `Waiting…` | `-[SBHWidget displayName]` gives that text when LaunchServices has no containing record for the extension id. So the plate is not a GPU result and not a chronod denial | [V] code, [I] catalog as the reason | `enforce_xpc_cache_code_signing` off in the system file too | New root; first LaunchServices seed. If the plates stay: read R1 |
| 3 | MessagesBlastDoorService sig 5 | Fatal `BlastDoor cannot run unsandboxed.`: `sandbox_check(self, NULL, 0)` gives 0 on the stand-in. **Not** the post launch line that `ios26-gpu-render.md` named | [V host] | Kernel `post/9010` | New kernel |
| 4 | Spotlight sig 11, pc 0 | objc method cache race on ARMv8.0: new sel, imp 0 | [V] code and the fault, [I] that this race was the crash | `a64-lower`: imp 0 is a miss | New lowering, new root |

## 1. Wallpaper

Facts:

- [V] The log has `exec PosterBoard` in each boot, 0 `NMTL[... PosterBoard]` lines: it never asks for a device. So the clients line never acted on it.
- [V] Exec lines against all 23F84 `.appex` files: 0 of the 33 `com.apple.posterkit.provider` files ran. Every extension that ran is in `System/Library/ExtensionKit/Extensions`, none from an app's `PlugIns`.
- [V] 23F84: `Autobahn`, `AutobahnLegacyMigration`, `AutobahnLegacyMigrationSupportingDistinctHome` in `FeatureFlags/Domain/SpringBoard.plist`, phase FeatureComplete. PaperBoardUI has the line "wallpaper migration will not run in SpringBoard with Autobahn enabled."
- [V] `PBUIWallpaperDirectoryDataStore`: directory `CPSharedResourcesDirectory` + `Library/SpringBoard`, names `LockBackground`, `HomeBackground`; `wallpaperImageForVariant:wallpaperMode:` reads through `CPBitmapCreateImagesFromData(data, &meta, 1, &err)`.
- [V] `CPBitmapCreateImagesFromData`: last word 0xdcb543a2 (or 0xcba43291, older); format 4, 6 or 7 goes the encoded path. Trailer of 7 words: IOS-26-Hot's order.
- [V] `init_featureflags` reads `/System/Library/FeatureFlags`, `.../Unified`, `/Library/Preferences/FeatureFlags`. `/Library/Preferences` links to `private/var/preferences`. It runs each boot [V log].
- [V host] `ios26-user-emu.py --cpbitmap FILE`: the real `CPBitmapCreateImagesFromData` takes our trailer and goes on into ImageIO (frame AppSupport+0x21b6c -> ImageIO+0x41e9c). There the fake kernel ends: ImageIO asks CFPreferences over XPC. So the container is proven, the PNG decode is not, on this host.
- IOS-26-Hot turns the flags off and stages these files, and reports a wallpaper on 23F84 [self-reported]. It sets the flags in the system file and in `/var/preferences`. Same here, so the level does not matter.

Why not repair posters first: the poster path needs a provider that runs under `EXRequiresSceneHosting`, a store PosterBoard fills once, and a snapshot through Metal. 3 unknowns and no read of the phone. The owner asked for a wallpaper by default. If R1 shows providers registered after fix 2, the poster path can be tried with `WALLPAPER=0`.

The hook (`scripts/laurel/ios26-root-spec.py` `wallpaper`):

| What | Value |
|---|---|
| Picture | 23F84's default of this model (`DefaultWallpapers~iphone.plist` default 7565), `Background Dark.HEIC`, 1700x1300, cut to 720x1560. No Apple file enters git: the root build decodes it |
| Tools at the root build | `heif-dec` and ImageMagick. Without them: a plain gradient, in pure Python, and the audit line says so |
| Files (mobile, 0644) | `private/var/mobile/Library/SpringBoard/{Lock,Home}Background.cpbitmap`, `*Thumbnail.cpbitmap`, `*Thumbnail.jpg`. Pref `com.apple.PaperBoard` as Hot |
| Flags | `System/Library/FeatureFlags/Domain/SpringBoard.plist`, `private/var/preferences/FeatureFlags/Domain/SpringBoard.plist` |
| Off | `WALLPAPER=0` at the root build. A failure: `off wallpaper: why`, nothing of it stays (`feature()`) |

Effects of Autobahn off that I could not test [U]: lock screen customization and the poster gallery go back to the old wallpaper settings. Glass has a real picture to capture.

### Clients list: `-PosterBoard` goes

Decision with evidence: PosterBoard asked no device in any of the 4 boots [V], so the denial was never the cause. Its reason came from Hot's `_RB4` report, and `RB_FAMILY` removed that case here [V `ios26-gpu-render.md`]. If PosterBoard asks later, a device costs memory only then. A denial would give it a path that this project has not tested. New default: `* -chronod -cameracaptured`.

`-chronod` stays. The white plate has a cause before any drawing (section 2). A boot with chronod on Metal (00:26:39 in the log) shows no widget extension either [V]. Hot reports white plates with chronod on Metal [self-reported]. Rendering is in WidgetRenderer_Default, which has its device now.

## 2. Widgets

**Correction, 2026-11-03, boot of 05:11, read on the phone: the catalog is not the limit. lsd drops each app extension because MobileGestalt says `arm64e` = false: `docs/laurel_sprout/ios26-control-center.md`. R1 gave 0 for `com.apple.weather.widget`; `missing extension cache entry` has 0 lines.**

- [V] `SpringBoardHome.loctable`: `WAITING_ICON_LABEL` = `Waiting…`. Two users: `-[SBHProxiedApplicationPlaceholder icon:statusDescriptionForLocation:]` and `-[SBHWidget displayName]`.
- [V] `-[SBHWidget displayName]` 0x1c113a2bc: `SBHContainingBundleRecordForWidgetWithBundleIdentifier(extensionBundleIdentifier)` is nil gives this text. That function: `[[LSApplicationExtensionRecord alloc] initWithBundleIdentifier:error:]`, then `containingBundleRecord`.
- [V] `DefaultIconState~iphone.plist`: the two stacks are `com.apple.weather.widget`, `com.apple.Maps.GeneralMapsWidget`, `com.apple.mobilenotes.WidgetExtension`, and `com.apple.mobilecal.CalendarWidgetExtension`, `com.apple.news.widget`, `com.apple.mobileslideshow.PhotosReliveWidget`. All in apps of the `staged-apps` hook.
- [V] 0 of 120 `com.apple.widgetkit-extension` files in an app's `PlugIns` ran. `WiFiSettingsControlsExtension` and other ExtensionKit ones ran, from `System/Library/ExtensionKit/Extensions`, 1 or 2 times each.
- [V] The iOS 16 logs of 2026-11-01 have WeatherWidget and the others: same hook, same kernel stand-in.
- [V] `.private-exception` is a name suffix in `ChronoServices` (`CHSScreenshotManager`). A small plate file fits a plate with no timeline [I].

The chain [I]: lsd checks each `PlugIns` extension against the catalog of extension points (`InstalledContentLibrary`: "Extension cache does not have an entry for %@"; Hot and Bergamota saw that on 20H392). In 23F84 [V]: `-[EXExtensionPointEnumerator initWithSDKDictionary:urls:config:]` reads `extensions.plist` through the signature when `enforceXPCCacheCodeSigning`, else as a plain file. The flag is `ExtensionKit` / `enforce_xpc_cache_code_signing`, `Enabled` true in the system file. `com.apple.widgetkit-extension` and `com.apple.posterkit.provider` are only in that file, not in the 62 `ExtensionPoints/*.appexpt` [V]. Our root had the override only in `/var/preferences`. The kernel's AMFI service logs each selector the first time; selector 6 (the trust question) is in no boot [V]. So either the override works, or the check fails before it asks.

Fix: the flag also in the system file. It makes the read a plain one in both cases. **This may not be the whole reason**: read R1 says.

Not done, on purpose: writing `.appexpt` copies of the 64 points. Their format differs (`translateAppexptDictionary`), and with no read of the phone that is a guess.

## 3. BlastDoor

- [V] `BlastDoor/Sandbox.swift`, 0x21825d59c: `_bd_sandbox_check` = `sandbox_check(getpid(), NULL, 0)`; not 1: fatal `BlastDoor cannot run unsandboxed.` Then `sandbox_enable_state_flag("blastdoor-post-launch", token)`; false: the post launch fatal. The crash frames (0x2186ee51c, 0x21825d6b8) fit both.
- [V] libsystem_sandbox: `__sandbox_ms("Sandbox", 2, args)`, args `{ u64 *result; i64 pid; const char *operation; ... }`, result nonzero = 1. The stand-in's op 2 returns 0 and writes nothing. Op 0x41 returns 0 = done.
- [V host] `scripts/laurel/test-ios26-blastdoor.sh`, PASS, real code under Unicorn: old answer: `fatal: BlastDoor cannot run unsandboxed.`; new answer: `sandbox_check pid 27 operation 0x0`, `sandbox_enable_state_flag 'blastdoor-post-launch'`, the gate returns.
- [V] 8 binaries in PrivateFrameworks carry `com.apple.private.security.enable-state-flags`, all `blastdoor-post-launch`: Messages, Hubble, MessagesAirlock, IDS, Thumbnails, Telephony, Wallet, MediaAnalysis services. Kernel answer 1 only for: the process about itself, no operation, this entitlement. Any other process sees no change. Kill switch `laurelbdsandbox=0`. Line: `LAUREL SANDBOX: on: NAME and its kind are told they are sandboxed...`.
- Hot replaces the binary with an idle stub [self-reported]: not needed. Its `ReslideSharedCache` false: not taken. The crash slide equals the boot's slide [V], so no reslide happens here.
- What comes after the gate on the phone (`xpc_main`, the parsers) [U]. The host fake stops in libxpc. The service does nothing until Messages sends data. If a new sig 5 appears, the crash line gives the next site.

### Other loops of the log

No log line has a sandbox failure text other than the one above [V grep]. Signals and sites, boot log of 2026-11-03:

| Process | Count | Signal, site | Finding | Mark |
|---|---:|---|---|---|
| MessagesBlastDoorService | 54 | 5, `_assertionFailure` | Section 3 | [V] |
| cryptexd | 40 | 5, `__panic_npx` in `__darwin_el0_init` of libimage4 (`img4_chip_select_personalized_ap`) | Not sandbox. Security hardware. A job the owner keeps | [V] site, [U] fix |
| cameracaptured | 17 | 11, `CIKernelReflection::consolidate` +144 | Not sandbox. Metal shaders of CoreImage | [V] site, [U] cause |
| webbookmarksd, Safari, SafariConfiguration | 29 | 6, `objc_terminate`, from `+[NSURL fileURLWithPath:isDirectory:]` nil path | A path comes back nil. **Possible** container path of the stand-in (op 4) | [V] site, [I] |
| backboardd | 5 | 6, same abort, CA frames | Not this work | [V] site |
| deviceaccessd, gamepolicyd, liveactivitiesd, linkd, intents_helper | many | 9, ns 1 code 7: jetsam | Limits, not sandbox | [V] |

## 4. pc 0

- [V] Log: 3 crashes `pc 0x0`: Spotlight lr 0x18e718d98 (`objc_msgSend` of `_cacheRenditionProperties`), SpringBoard lr 0x18e718c9c (`objc_msgSendSuper2` in `-[CUINamedImage initWithName:...]`), liveactivitiesd lr 0x19b692ddc (`objc_msgSend` of `isOneWay`, `__vetProtocol`). So: not CoreUI. Each is a first send of a selector with threads at work.
- [V] 23F84 `cache_t::insert` 0x1800a009c: `stp x16, x19, [x9]` (imp, sel), into an empty bucket. `objc_msgSend`: `ldp x17, x9, [x13], #-16`, `cmp x9, x1`, then a jump to x17. No lock. Arm: 2 atomic 64-bit accesses in an ARMv8.0 LDP or STP, in no fixed order; 16-byte atomicity comes with FEAT_LSE2. Apple's CPUs have it [I]; the Mi A3's do not [V ARMv8.0].
- So a reader can see the new sel and the old imp, 0. Then `br x17` = pc 0, with lr of the caller, far 0. That is the crash line [V shape, I cause: the line has no registers].
- On real PAC hardware the `brab` would fault there too, so it is not lowering that made it: it is the CPU.

Fix in `tools/op10tool` (`a64::objc_bucket_race`): the two words before the jump (`eor x10,x10,x1; eor x10,x10,x16`) only built the PAC modifier. They become `cbz x17, miss; nop`. `miss` comes from the `cbz x9` of the next probe. Same addresses, inside `objc_restartableRanges`, no new memory access. A miss takes the lock and finds the method.

Results [V host]: 4 sites (`objc_msgSend`, `Super2`, `objc_msgLookup`, `LookupSuper2`), `a64-verify` counts 4 + 4, no problem. `scripts/ios26/test-objc-cache-race.py`, real code: old cache `sel+imp 0 -> fault 0x0` (and imp 0 from lookup), new cache `-> at 0x18009b8a0` / `0x18009b940`; sel+imp still reaches the imp. `test-ios26-user-emu.sh`: 6 of 6 reach main. Two lowerings are the same bytes. Only `dyld_shared_cache_arm64e.01` changes (108 MiB).

Not covered: a sel-first read (it needs more code in the hot path); `cache_getImp` returns 0 = miss already. Old imp with new sel cannot happen: only an empty bucket is filled [V insert], and a replaced table is new memory.

## What the phone needs

| Change | Way |
|---|---|
| `wallpaper`, flags, clients | **New root**: `ios26-root.sh` + `dual-boot.sh install` (erases `/private/var`: a new LaunchServices seed, which fix 2 needs). Flags and files by SSH alone are not enough: an old store is not seeded again [self-reported Apollo] |
| `clients.local` alone | File copy works (`ios26-live-update.sh`). No effect on the wallpaper |
| `post/9010` | **New kernel** (boot image): `kernel-ios26-linux.sh`, built here: `LAUREL BUILD: ... 338 patches, series 23ca40863d95e922`, 0 errors, 208 s |
| objc rule | First `scripts/bg.sh ios26-lower env DEV=n104ap scripts/ios26/lower-userland.sh` (rewrites the shared `lowered/`; I did not), then the new root |

## Reads that decide what is left [U]

Only if the owner allows a read, after the new root; no write:

- **R1**: `ls /var/mobile/Containers/Data/InternalDaemon/*/Library/Caches/com.apple.LaunchServices*`, then copy that `.csstore` to the host and count `com.apple.weather.widget` and `com.apple.posterkit.provider` in `strings` of it. Found 0: extensions are still refused; then R2. Found: the record exists and the next limit is chronod's launch.
- **R2**: the `lsd` lines of `/var/db/diagnostics` that contain `Extension cache does not have an entry` or `Failed to read extension point cache`.

Expected lines on the next boot: `LAUREL SANDBOX: on:`; no `CRASH MessagesBlastDoo` with sig 5; no `pc 0x0`; `exec WeatherWidget`; a picture behind Home.
