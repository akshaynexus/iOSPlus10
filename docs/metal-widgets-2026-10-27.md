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

The gate logs, in every process, `memory: footprint N MiB, jetsam limit M MiB (0 = none/unknown), extension point P,
rule R MiB` and refuses the device when the limit is known (task_info phys_footprint + `limit_bytes_remaining`) and
below `NEGRONIMETAL_MIN_LIMIT_MB` (default 40). `NEGRONIMETAL_MIN_LIMIT_MB=0` in /var/db/negronimetal/env turns the rule
off. The first version also refused every `com.apple.widgetkit-extension` outright; FitnessWidget then trapped
(sig 5, `code 0x600000001`, its renderer requires a device) - removed on 2026-10-27 03:10, see section 5.

## 5. Where the 30 MiB comes from, and the 64 MiB fix (2026-10-27 03:05-03:20) [V]

- Model: `uname -m` = iPhone10,3 (D22). /System/Library/LaunchDaemons/com.apple.jetsamproperties.D22.plist and
  .D221.plist (same content): `Version4 > Extension > Override > com.apple.widgetkit-extension =
  {ActiveHardMemoryLimit 30, InactiveHardMemoryLimit 30}` (no JetsamPriority key; the old `com.apple.widget-extension`
  has 32/32, priority 90). chronod is a Daemon override (ActiveSoft 98, InactiveHard 45, priority 150).
- Reader: runningboardd (RunningBoard.framework `RBJetsamPropertyManager`: "Loaded jetsamproperties from %@",
  `_addJetsamValuesForSection:fromPlist:toDatabase:`, paths /System/Library/LaunchDaemons/com.apple.jetsamproperties
  and /AppleInternal/...). It reads the file once at its start. The phone has no launchctl (no userspace reboot), but
  `kill -9 runningboardd` is enough: launchd restarts it (KeepAlive, ThrottleInterval 1); SpringBoard and backboardd
  survived it (03:09:08), and every widget launched afterwards had 64/64 (memlimit.sh).
- Change: `scripts/ios16/jetsam_widgets.py` (idempotent; never lowers a limit) sets both keys to 64 MiB.
  Root image: `scripts/ios16/root-tweaks-extra.py` step 6 (env `WIDGET_JETSAM_MB`, default 64, empty = off) patches
  every com.apple.jetsamproperties.*.plist. Live phone: `scripts/metal/phone-widget-jetsam.sh on [MB] | off | status`
  (originals kept as *.orig next to the plists, restarts runningboardd). Applied on the phone 03:09; it survived the
  following reboots (the root is on userdata).
- Plugin: the widgetkit clause is gone; only the runtime limit check is left (40 MiB). A stock 30 MiB widget still
  gets no device, a 64 MiB widget gets it. Before the change (boot 03:14, 64 MiB limit, old plugin) metal.log showed
  `jetsam limit 64 MiB ... WidgetKit extension (30 MiB jetsam limit; reported 64 MiB): no Metal device` and 3 x sig 5:
  so the runtime limit read is correct.
- Note: a plugin push followed by a reset within ~10 s is lost (HFS journal not flushed): the 03:15:45 push was gone
  after the 03:15:56 reboot that another session started. phone-test.sh push should end with `sync` (now done by hand).

## 6. SleepWidgetExtension / SafariLinkExtension: ROOT CAUSE = zero blocks flashed as DONT_CARE [V]

- The phone's SleepWidgetExtension differs from the root image at file bytes 0x8000-0xc000 (its __DATA segment).
  In the image these 16 KiB are all zero; on the phone they are old bytes (`c9 93 97 a4 36 19 32 01 ...`). The fault
  address of every SleepWidgetExten crash, `far 0x1321936a49793e1`, is the first 8 bytes of that page (+0x18): the
  Swift runtime reads a "pointer" from the zero __DATA page. The page hashes (CodeDirectory, 4 KiB pages) fail for pages
  8-11 only, which is the `cs_invalid_page ... allowing (remove VALID)` line. Same crash at every boot since the root
  was flashed: the bytes are on the flash, not a read error.
- Why: macOS keeps all-zero 4 KiB runs of ~/op10-apple/ios16-root.img as APFS holes (SEEK_HOLE at 0x87314000 =
  exactly that page, file extent starts at 0x8730c000). `op10tool img2simg` wrote every hole as DONT_CARE, so
  `fastboot flash userdata` left whatever was on userdata in blocks that the HFS+ volume uses. Count for the current
  image: 20296 blocks (79 MiB, 128 runs) are holes and allocated in the HFS+ bitmap. They touch 112 files (scan with
  F_LOG2PHYS over the mounted image, list in logs/holefiles.log), among them SleepWidgetExtension, SafariLinkExtension,
  MusicRecognition, MobileSMS, MobileSlideShow, SpringBoardEducation, 12 DiagnosticsService plug-ins,
  10 AccessibilityBundles, 7 DriverKit files and **dyld_shared_cache_arm64.07, .21 and .42.dyldlinkedit** (both copies:
  /System/Library/Caches and /private/preboot/Cryptexes/OS). lockdownd's cs_invalid_page on shared-cache pages has the
  same cause. [I] Other "random" crashes in shared-cache code can come from these pages too.
- Fix (tools/op10tool/src/img2simg.rs, `hfs_allocated`): when the image starts with an HFS+ volume header with 4096-byte
  blocks, img2simg reads the allocation bitmap and writes a hole block that the volume uses as FILL 0 (DONT_CARE only for
  free blocks and for blocks past the volume). Test: a 32 MiB HFS+ image with a 64 KiB zero run in a file, made sparse:
  196 allocated hole blocks -> FILL (old tool: 0), simg2img round trip byte-identical. The simg size does not change
  (FILL chunks are 16 bytes); the flash writes 79 MiB more zeros. **The next root flash must use a simg made with the new
  op10tool** (scripts/setup/build-op10tool.sh, then scripts/ios16/root-simg.sh).
- Live repair proof: the correct SleepWidgetExtension from the mounted image was copied to the phone (new file + mv,
  root:admin 0775, bad copy kept in /var/root/SleepWidgetExtension.bad). After the respring at 03:18:20 the extension
  runs (pid 352, 8.6 MiB) and did not crash (section "Proof"). The shared-cache files are not replaced live (mapped by
  every process; 115-334 MB each): they need the reflash.

## 7. MusicWidgets [V/I]

- Not in the list of damaged files (its own binary is fine). Crashed 3 x sig 11 in the 03:14 boot, 0 in the 03:01 boot.
  /var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb exists (4 KiB + 680 KiB WAL), so the "no media library
  directory" idea is wrong. [I] The NULL C string in `_MediaLibrary_coreLibrary` can come from the damaged
  shared-cache pages (MediaPlayer/MediaLibraryCore live in the cache); check again after the reflash with the new simg.

## Proof

Kernel log logs/usblog-20261026-233816.txt (CRASH lines with `[pid] sig`, de-duplicated by pid; the log replays some
lines once).

| window | widget limit | plugin | FitnessWidget | SleepWidgetExten | MusicWidgets | SafariLinkExtens |
|---|---|---|---|---|---|---|
| boot 03:01, first 2 min | 30 MiB | widgetkit refused | 3 x sig 5 (no device) | 2 x sig 11 | 0 | 1 x sig 11 |
| boot 03:14, first 2 min | 64 MiB (read 64 at runtime) | widgetkit refused | 3 x sig 5 (no device) | 2 x sig 11 | 3 x sig 11 | 1 x sig 11 |
| respring 03:18:20 -> 03:19:29 (69 s, then another session rebooted the phone) | 64 MiB | limit rule only | 0 (device opened, frame done, 11.5 MiB) | 0 (binary replaced from the image) | 0 | 0 (not started) |

- memlimit.sh after the respring: ScreenTime, Weather, Fitness, LockScreenPeople, Sleep, Music widgets all 64/64 MiB,
  footprints 4.4-11.5 MiB; chronod 98/45.
- The phone was rebooted into fastboot by other sessions at 03:11:05, 03:15:56, 03:19:28 and 03:20:28, so no full
  2-minute window was possible. The root changes (plists, plugin, SleepWidgetExtension) are synced on userdata and
  stay for the next boots.

What the owner should see: the Fitness widget renders (no more "crash then gone"; the rings may be empty because the
VFX render pipeline is nil, see below), the Sleep widget renders, and widgets no longer disappear after 3 crashes.
Open: FitnessWidget `render pipeline skipped: nil render pipeline` (VFX metallib pipeline not built by metal2vulkan),
MusicWidgets (re-check after the reflash), and the reflash with a simg from the new op10tool for the 112 damaged files
(shared cache included).
