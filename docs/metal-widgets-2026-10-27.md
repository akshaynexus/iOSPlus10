# Widgets: black, crashing, missing (2026-10-27, Metal clients gate `*`)

Owner: "why are widgets all black now, read the logs pls and see why widgets are so iffy / crashing often and
rendering black". Boot analysed: logs/usblog-20261026-233816.txt after 01:34:28 IST (phone clock = host - 12.5 h),
plugin flame/0014+0015, Metal clients `*`, NegroniGL apps `* -backboardd`. Evidence copies: logs/widgets-20261027/
(metal.log, memlimit.txt, chronod snapshot cache + chrono.sql). Symbolication: `DSC=out/dsc/cache/dyld_shared_cache_arm64
scripts/debug/symbolicate.sh LOG [PROCESS] [N]` (shared cache) and `atos -o out/metal/NegroniMetal.dSYM/... -l BASE` (plugin;
BASE from the `images NegroniMetal 0x... turnip 0x...` line in the kernel log).

[V] = verified (log line, symbol, measurement). [I] = inference.

## Crash counts, first 2 minutes of the boot

| process | signal | count | Metal device in the process | class |
|---|---|---|---|---|
| FitnessWidget | 9 (`reason ns 1 code 0x7` = JETSAM_REASON_MEMORY_PERPROCESSLIMIT) | 3 (then chronod gave the widget up) | yes (opened 3 times) | **our Metal device + the 30 MiB widget limit** |
| MusicWidgets | 11 | 3 | never (0 NMTL lines in any boot) | pre-existing, not Metal |
| SleepWidgetExtension | 11 | 2 | never | pre-existing, not Metal |
| SafariLinkExtension | 11 | 1 | never | pre-existing, not Metal |
| assetsd | 6 | 3 | - | not a widget |
| bluetoothd | 6 | every 10 s | - | not a widget (Bluetooth fatal error 1201) |

MusicWidgets and SleepWidgetExtension crashed the same way at 00:04 and 00:26, before the clients gate became `*` (00:27).

## 1. FitnessWidget: jetsam, per-process limit, 1-8 s after our device opened [V]

- Limits, measured as root with `scripts/metal/memlimit.sh` (userland/metal/tools/memlimit.c:
  `memorystatus_control(GET_MEMLIMIT_PROPERTIES)` + `proc_pid_rusage` footprint), logs/widgets-20261027/memlimit.txt:
  every WidgetKit extension has a 30 MiB limit (active and inactive, attr 0x1 = fatal): WeatherWidget, CalendarWidgetExtension,
  StocksWidget, TipsWidget, GeneralMapsWidget, PhotosReliveWidget, ScreenTimeWidgetExtension, mobilenotes.WidgetExtension,
  LockScreenPeopleWidget. Their footprints without Metal: 4-13 MiB. chronod (limit 98/45 MiB) runs at 31 MiB **with** our
  device; MapKit.SnapshotService at 20 MiB with it (its inactive limit is 12 MiB). The plugin + Turnip + the Vulkan device
  cost about 15-20 MiB of footprint: a 10 MiB widget cannot hold them under 30 MiB.
- Kernel log, pid 288: `RedwoodGPU: opened by FitnessWidget` 01:35:46, `device Turnip Adreno (TM) 730 in 579 ms`,
  `render pipeline skipped ... nil render pipeline`, `pipelines 0 compiled`, `CRASH FitnessWidget[288] sig 9 ... reason ns 1
  code 0x7` at 01:35:47. pid 243 lived 8 s, pid 292 1 s. No kernel `memorystatus` line (the kernel prints none).
- Where it died (atos on the plugin, base 0x10c504000): `_platform_memmove` <- `metal2vulkan::library::function::from_metallib`
  (function.rs:345, `bytes: bytes.into()` copies the whole metallib) <- `Device::new_library_with_data` <- `nmb_library_new` <-
  `-[NBDeviceMethods newLibraryWithFile:]` <- `newLibraryWithURL:` <- `newDefaultLibraryWithBundle:` <-
  `VFXCore.Renderer.init(device:commandQueue:options:)` (the Fitness rings renderer). The bundle is VFX.framework, its
  default.metallib is 3,168,440 bytes: the copy is the last allocation before the limit, not the only one.
- Older boots (logs/usblog-20261025-223827.txt): 24 x sig 9 with the device, plus 29 x sig 5 = Swift `assertionFailure`
  (`_$ss17_assertionFailure...+248` from a `dispatch_once` in the extension's own code) after `device refused in 12029 ms`
  and once after `not listed`; in logs/usblog-base-boot-ok.txt and usblog-g2b-boot-ok.txt the extension was `not listed`
  and did not crash. [I] The assertion is the renderer's own nil-device check and depends on which timeline entry it draws.

## 2. MusicWidgets: `strlen(NULL)` in MediaPlayer, pre-existing [V]

`__platform_strlen+4` <- `std::string(const char *)` <- `-[MPMediaLibrary(MediaLibraryCore) _MediaLibrary_coreLibrary]+140`
<- `-[MPMediaLibraryView initWithLibrary:filteringOptions:]` <- `MPModelLibraryRequestOperation` on an NSOperationQueue.
A C string the media library expects (a path or an identifier) is NULL on this port. Same crash at 00:26 before Metal was
on for everyone. Not Metal, not fixed here. [I] Candidates: no iTunes/MediaLibrary database, or the sandbox container
path (MusicWidgets reads the Music library through MediaLibraryCore).

## 3. SleepWidgetExtension and SafariLinkExtension: code-signing page fault at the Swift entry, pre-existing [V]

- `CODE SIGNING: cs_invalid_page(0x1005dc000): p=283[SleepWidgetExten] final status 0x22000000, allowing (remove VALID)
  page` is logged right before `CRASH SleepWidgetExten[283] sig 11 ... far 0x1321936a49793e1` (mh 0x1005d4000: the fault is
  on the extension's own third __TEXT page). Frames: `main image + 0x3b94` -> `$s7SwiftUI12WidgetBundleP0C3KitE4mainyyFZ+292`
  -> `$s7SwiftUI12WidgetBundlePxycfCTj` (the WidgetBundle `init` witness, a garbage pointer). SafariLinkExtension: the same
  pattern (`cs_invalid_page(0x104708000)`, mh 0x104700000, then `swift_getAssociatedTypeWitness+24` from
  `ExtensionFoundation.AppExtension.main`). Both at 00:04/00:26 too, both without Metal. lockdownd logs the same
  cs_invalid_page on shared-cache pages (5 times) without crashing.
- [I] The kernel's "allowing (remove VALID)" path leaves the page mapped but its content is not what the Swift runtime
  expects (the protocol witness tables live in __TEXT,__const of that page). A kernel code-signing item, not Metal.

## 4. "All black" [I, not provable from the Mac]

There is no screenshot path from the Mac. What the logs allow:
- chronod renders every widget snapshot (SwiftUI archive -> 465x465 / 987x465 IOSurfaces, `NEGRONI SURF: chronod create
  ... 465x465 fmt 0x5f524234 planes 2`) and, since the gate is `*`, it does that on our device (`NMTL[128 chronod]: device ...
  in 400 ms`, 2 pipelines, 0 refused, strike cleared at the first frame). Before 00:27 chronod had no device (CA rendered on
  the CPU). The widgets that are alive (Weather, Calendar, Stocks, Tips, Maps, Photos, ScreenTime, Notes) never load Metal:
  if all of them are black at once, the common path is chronod's Metal snapshot render, not the extensions.
- The cached snapshots (logs/widgets-20261027/snap, `AAPL` CA snapshot format, compressed) are not uniform black, but
  their write times are not tied to this boot.
- Test for the owner (one command, no rebuild): `scripts/net/ssh-phone.sh 'printf "* -chronod\n" > /var/db/negronimetal/clients;
  kill -9 $(ps -eo pid,comm | grep chronod | sed "s/^ *//;s/ .*//")'`; the widgets re-render on the CPU within ~10 s. Black gone
  = chronod's Metal path (an IOSurface-backed render target that never reaches the surface, or the 2-plane format); then
  it is a flame/bridge item. Black stays = SpringBoard/backboardd side. Put `*` back afterwards.

## Fix (plugin rule, userland/metal/plugin/NegroniMetal.mm, `memory_rule`)

The gate now logs, in every process, `memory: footprint N MiB, jetsam limit M MiB (0 = none/unknown), extension point P,
rule R MiB` and refuses the device when:
- the limit is known (task_info phys_footprint + `memorystatus_available_memory()` syscall 534, both unprivileged) and
  below `NEGRONIMETAL_MIN_LIMIT_MB` (default 40), or
- the main bundle's `NSExtensionPointIdentifier` is `com.apple.widgetkit-extension` (30 MiB limit on iOS 16, whether or not
  the kernel reports it: the syscall answers 0 for non-"app" processes).
`NEGRONIMETAL_MIN_LIMIT_MB=0` in /var/db/negronimetal/env turns the rule off. Metal stays on by default for every other
process (owner's rule: on for everything that works). The small posters (Gradient/Emoji/Unity, 30 MiB) are covered by the
limit branch if they ever open a device; the big ones (Weather/Collections/Extragalactic/Pride/Photos, 200-250 MiB) are not
touched. XNUtils' "all" preset stays `*`.

Not done: a smaller metallib load (`bytes.into()` copy in metal2vulkan, m2v patch candidate), the MusicWidgets NULL string,
the cs_invalid_page kernel path.

## Proof

(filled in below after the push)
