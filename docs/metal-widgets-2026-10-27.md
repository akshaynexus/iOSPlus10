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

## 8. Blank/white widgets: root cause, metal2vulkan f6a96b7d, fix (2026-10-27 18:30, Metal widgets agent)

Evidence: logs/usblog-20261027-171256.txt (kernel), logs/camlog3/4/5-full.txt and logs/phone-full-20261027-1743.txt
(unified log, phone clock = host - 12.5 h). Disassembly: `ipsw dyld disass out/dsc/cache/dyld_shared_cache_arm64`
(RenderBox, QuartzCore, MediaPlayer of 20H392).

### 8.1 What fails [V]

- chronod renders the home-screen widgets in its own scenes (`ChronoCore.WidgetWindow`) with SwiftUI -> RenderBox
  (RBLayer) on our Metal device (`NMTL[126 chronod]: device Turnip Adreno (TM) 730`, pipelines 2, 0 refused). backboardd
  composites the result from the IOSurfaces of those layers.
- chronod creates the widget surfaces as `465x465 fmt 0x5f524234 planes 2` (OSType `'_RB4'`). RenderBox makes them in
  `RB::create_iosurface(MTLPixelFormat 550/551)`: plane 0 = 4 bytes a texel, plane 1 = 1 byte a texel, that is
  MTLPixelFormatRGB10A8_2P_XR10 (_sRGB).
- RenderBox picks that format in `RB::ColorMode::pixel_format` (0x1e68c944c): for a wide colour mode, a non-opaque layer
  and a device of tier >= 3 it reads the table at 0x1e6945390 = {554 BGR10_XR, 555 BGR10_XR_sRGB, 550, 551}. The tier is
  the highest `supportsFamily:MTLGPUFamilyAppleN` (RB::Device ctor, loop 1001..1007, stored at +0x111). It does NOT read
  `supportsExtendedXR10Formats`, so our NO answer did not stop it.
- The frontend refused every IOSurface with planes: `newTextureWithDescriptor:iosurface:plane:` started with
  `if(... plane || IOSurfaceGetPlaneCount(surface)) return nil;` and logged nothing.
- Result in chronod: `(RenderBox) RBDisplayList: no drawable` (RB::DisplayList::RootTexture::make_texture: the drawable
  callback gave nil). Result in backboardd: `(QuartzCore) Failed to allocate MTLTexture from IOSurface 0x3d4/0x3de`,
  the same 2 surface IDs every frame, right after the chronod line (camlog5 05:24:44.853 -> .873). [I] The 2 IDs are
  the Weather and Calendar widget surfaces (timing; the kernel logs only the first 64 creations). Counts: camlog3 496,
  camlog4 84, camlog5 125, phone-full 118. The widget area keeps only what CA draws on the CPU (background): blank/white.
- 3 more backboardd lines: `Failed to allocate [WxH] b3a8 framebuffer MTLPixelFormatRGB10A8_2P_XR10` (same refusal).
- Not the cause: memory (chronod 14-19 MiB, no jetsam), pipelines (0 refused), `FB STAT ... gpu-wait skips 0`.

### 8.2 AegirPoster crash loop: same family, other check [V]

`NMTL[AegirPoster]: uncaught exception CAMetalLayerInvalid: unsupported extended range format`, frame 3 =
QuartzCore + 0x288b8 = `-[CAMetalLayer setPixelFormat:]` -> `layer_private_check_pixel_format` (0x1883712dc): an XR
CA format and `[device supportsExtendedXR10Formats] == NO` -> raise. ClockKitUI (Astronomy face) sets the XR format
whatever the answer. 143 `CRASH AegirPoster` lines in the log. Our answer NO (since 2026-10-25) causes it. The reason for
NO was metal2vulkan 720ef1ce refusing BGR10_XR_sRGB blends (`ExtendedRangeBlend(SrgbForm)`); f6a96b7d builds every
blend into BGR10_XR_sRGB (crates/metal2vulkan/src/lower/arith/extended_range/blend.rs: SrgbForm is now only
BGRA10_XR_sRGB beyond the narrow blends).

### 8.3 Fix (three layers)

1. RenderBox setting (plugin, `userland/metal/plugin/NegroniMetal.mm`, constructor): `setenv("RB_COLOR_MODE", "fixed", 0)`.
   RenderBox parses RB_COLOR_MODE once at the first RB::ColorMode (after the device exists; options deep wide extended
   fixed linear nonlinear 5bpc 422 420). `fixed` sets the depth/gamut byte to 0: BGRA8Unorm(_sRGB), one plane, the 8-bit
   display chain's format. [I] This is the main fix: chronod's widget surfaces become plain BGRA. Off: a line
   `RB_COLOR_MODE=` in /var/db/negronimetal/env.
2. Surfaces with planes (flame/0016 + metal2vulkan f6a96b7d): the frontend makes textures over any plane through the new
   bridge call `nmb_texture_new_on_surface_plane` -> `Buffer::new_texture_with_iosurface_plane` with the surface's facts
   (`IoSurfaceYCbCr`: OSType, plane, size, plane 1 offset/bytesPerRow). metal2vulkan f6a96b7d holds RGB10A8_2P_XR10 over a
   `'b3a8'` surface (texture/surface_two_planes.rs, a shadow image) and two-plane YCbCr (`420f`/`420v`) surfaces
   (ycbcr.rs). `'_RB4'` with 4+1 bytes a texel is passed as `'b3a8'`. Refusals are now logged once per reason. This
   covers the `_RB4` surfaces made before the env takes effect, CA's `b3a8` framebuffers in backboardd and the posters'
   camera/photo surfaces.
3. XR10 answer per process (plugin): `NEGRONIMETAL_XR10` = auto (default) | 0 | 1. auto = YES in processes whose name
   ends in Poster, PosterExtension or PosterProvider; NO elsewhere (backboardd and SpringBoard keep the 8-bit chain).
   Log line: `supportsExtendedXR10Formats = 1 (NegroniMetal A730 answer, NEGRONIMETAL_XR10=auto: ...; RB_COLOR_MODE=fixed)`.

### 8.4 metal2vulkan update 720ef1ce -> f6a96b7d [V]

- Submodule working tree: `external/metal2vulkan` at f6a96b7da82f3032e3fd7b1dc52c07bfd9b78dc8 (origin/master = the
  default branch, 2026-10-26, 688 commits after 720ef1ce; `development` is 13 commits further, not taken). The gitlink
  is not committed. ios-flame: no new upstream commit (still 745c434).
- Relevant upstream changes: two-plane IOSurface textures (YCbCr, RGB10A8_2P_XR10), XR blends into BGR10_XR_sRGB,
  host-import residency (imports may be released while idle), PaddedReadsPolicy removed, profile fingerprint once per
  profile (4348323b), module decode once per creation (cba1270d). `library::function::from_metallib` still copies the
  whole metallib (function.rs unchanged): FitnessWidget's memory cost stays.
- Patches. ios-flame's copies (for 720ef1ce) are replaced by rebased ones in `userland/metal/patches/m2v-flame/`;
  `scripts/metal/fetch-sources.sh` takes ios-flame's only for pin 720ef1ce.

| patch | result on f6a96b7d |
|---|---|
| flame 0001 optional-constant-output-members | applies unchanged |
| flame 0002 resource-wait-storage-dependencies | applies unchanged |
| flame 0003 cache-device-entry-point-priming | ported: prime() takes push/calibration/drawn, `Has` has 13 fields (+Debug); Store::new(dir, sink, None), write_record_soon, name(&Hash256) |
| flame 0004 fold-constant-global-field-loads | applies unchanged |
| flame 0005 keep-module-decodes-and-profile-fingerprints | dropped: upstream 4348323b (fingerprint once per profile, same effect) + cba1270d (decode kept per `StageEntries`, 4 decodes / 32 MiB; flame kept 4 per process, keyed by bytes: a new MTLFunction object decodes again) |
| flame 0100 sweet-8mb-memory-blocks | applies unchanged |
| flame 0101 sweet-padded-writers-alias | ported: `PADDING_ALIASES` const in linear_plan::holding (PaddedReadsPolicy is gone) and in `aliases()` (`padded_alone`, the old `Holds::Padding` check; review 2026-10-27: without it `texels_alone` refused every padded image after a wasted vkCreateImage). Reaches only padded textures over the runtime's own buffers: since upstream e35bf78b every texture over host pages (each IOSurface) is a shadow first. Unit tests follow the const |
| m2v/0001 host-import-noncoherent | ported: `HostPages::import_range` reads the import through `listing()` (no expose), `None` while released |
| m2v/0002 host-invalidate-stats | ported (context only) |
| m2v/0003 compositor-policy | ported: no framebuffer_fetch/PaddedReads in the policy any more; `ColorWritesPolicy` added beside the new fields |
| flame/0016 (new) | bridge: `SharedEventListener::new()` is infallible; plane textures (8.3 item 2) |

- Build [V]: fetch-sources.sh applies all 6 + 3 + 16 patches; the patch series on a clean f6a96b7d export reproduces
  out/metal/src/metal2vulkan byte for byte. build-bridge.sh ios: exit 0 (libnative_metal_bridge.a 363,960,232 bytes).
  build.sh: exit 0, NegroniMetal 26,579,264 bytes (sha256 85af9a19ba084227...), check-imports PASS (0 missing).
  No test on the phone yet. Review 2026-10-27: `cargo +1.98.0 test -p metal2vulkan-runtime --lib -- linear_plan
  shader_cache prime texture` on the Mac: 169 passed, 0 failed (before the 0101 test fixes: 2 failed in linear_plan).
- Review 2026-10-27 [V]: fetch-sources.sh skipped every flame patch with exit 0 ("Skipped patch": out/metal/src/flame
  had no own git repository, so `git -C` used this repo); it now runs `git init` there first. Rebuild after the review
  fixes: fetch (6 + 3 + 16 patches really applied), build-bridge exit 0, build.sh exit 0, NegroniMetal 26,680,832 bytes
  (sha256 d8f20dc714489...), check-imports PASS.

### 8.5 Other widget items [V/I]

- MusicWidgets sig 11 (9 lines): `-[MPMediaLibrary(MediaLibraryCore) _MediaLibrary_coreLibrary]+140`:
  `[[self databasePath] lastPathComponent].UTF8String` is NULL (databasePath nil) -> `std::string(NULL)` -> strlen.
  [I] The widget's sandbox has no media library path (TCC/MediaLibrary access), not Metal. Not fixed.
- WeatherWidget: `getTimelines(1)` watchdog -> CHSErrorDomain 1050 (camlog5): a data/network timeout, not rendering.

### 8.6 Test procedure (main session; no new root)

1. `scripts/metal/phone-test.sh push` (copies out/metal/stage: bundle, probes; keeps clients/env; ends with sync).
2. `scripts/net/ssh-phone.sh 'rm -f /var/db/negronimetal/strikes/*'` and respring: `scripts/net/ssh-phone.sh 'kill -9
   $(ps -eo pid,comm | grep -E "backboardd$" | sed "s/^ *//;s/ .*//")'` (or a reboot). The new metal2vulkan changes the
   profile fingerprint: every process compiles its pipelines again once (slow first start; posters can hit the launchd
   check-in timeout on the first try).
3. Proof lines (usblog / metal.log):
   - `NMTL[... chronod]: supportsExtendedXR10Formats = 0 (... RB_COLOR_MODE=fixed)`.
   - `NEGRONI SURF: chronod create ... 465x465 fmt 0x42475241 ... planes 0` (BGRA, not 0x5f524234 planes 2).
   - unified log: no `RBDisplayList: no drawable` (chronod), no `Failed to allocate MTLTexture from IOSurface`
     (backboardd), in a new unified-log capture made the same way as logs/camlog5-full.txt.
   - `NMTL[... AegirPoster]: supportsExtendedXR10Formats = 1`, no `CAMetalLayerInvalid`, no `CRASH AegirPoster`.
   - A plane texture, if any process still makes one: `native-metal: first texture over a surface with planes: fmt 550 ...`;
     a refusal: `native-metal: refused (logged once per reason): texture fmt N ... over plane P of 2 of a 'xxxx' surface: ...`.
   - Owner check: the widgets show content.
4. A/B (no rebuild): `RB_COLOR_MODE=` in /var/db/negronimetal/env + kill chronod: widgets then depend on item 2 alone.

### 8.7 Risks [I]

- RB_COLOR_MODE=fixed applies to every RenderBox user with our plugin (SpringBoard, SwiftUI apps): wide-colour/XR
  content renders in 8-bit sRGB. The display chain is 8-bit already.
- Plane textures of RGB10A8_2P_XR10 are shadow images (copy in/out per use): slower than plain BGRA.
- [V code, I cost] metal2vulkan e35bf78b: every texture over a no-copy buffer (each IOSurface the frontend imports:
  CA framebuffers, layer contents) is a shadow image, copied in before a use and merged back after a write. On 720ef1ce
  these were linear images over the pages. Watch the frame time of backboardd/SpringBoard against the 720ef1ce stage.
- YES for posters: the poster's BGR10_XR drawables must be sampled by backboardd, which still answers NO. If backboardd
  refuses them, the wallpaper stays empty, but the crash loop stops.
- metal2vulkan is 688 commits newer: unknown regressions in other processes (backboardd's 41 pipelines, apps). Fallback:
  check out 720ef1ce in external/metal2vulkan, fetch-sources.sh (for that pin: ios-flame's m2v patches, our
  `userland/metal/patches/m2v-720ef1ce/`, and no flame `*-m2v-*.patch`, so flame/0016 is left out), or push the previous
  stage from a backup.
