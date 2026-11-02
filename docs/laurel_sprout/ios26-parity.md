# Mi A3 iOS 26 root: parity with the iOS 16 root

Date: 2026-11-02. Branch `t3/laurel-ios26-parity`. **Host only. Nothing here has run on the phone. No flash, no reboot, no write to a device.** Labels: [V] measured here (code, disassembly, a host test), [I] inference, [U] unknown.

Owner requirement: the iOS 26 image has all features and additions of the Mi A3 on iOS 16; nothing may be missed silently.

## 1. Commands

```sh
scripts/bg.sh ios26-parity scripts/laurel/ios26-parity-build.sh     # every binary of the hooks + its check against 23F84 (about 20 minutes: one check at a time)
scripts/bg.sh ios26-root env FORCE=1 scripts/laurel/ios26-root.sh   # the root; read the lines that start with off at its end, or report.txt
python3 -I scripts/laurel/ios26-root-spec.py --self-test            # hooks: air, Metal, debug, parity
python3 -I scripts/laurel/ios26-parity-audit.py --before DIR --after DIR --write docs/laurel_sprout/ios26-parity.md     # section 9; exit 1 = an item has no row, or a row is not in the image
```

Before the root: `scripts/laurel/ios26-debug-build.sh`, `ios26-metal-build.sh`, `kernel-ios26-linux.sh`, and `gpu-firmware.sh` + `camera-inventory.sh` from the owner's stock vendor image (`ios26-first-boot.md` section 7).

## 2. What the audit found that the old list did not name

1. **No GPU firmware on the iOS 26 root.** `TopazAdreno.cpp` reads `/usr/share/firmware/laurel/`. The manifest of the root of 2026-11-01 has only `Rose` and `bluetooth` under `usr/share/firmware` [V]. On iOS 16 `root-add-gpu.sh` installs these files, and the iOS 26 path dropped that script with the GL parts. Result [V code, not run]: `LAUREL GPU: off`, no Metal device, no picture. Hook `gpu-firmware`.
2. **System apps.** 49 apps stayed in `/private/var/staged_system_apps`, with placeholders. Mail, Calendar, Notes, Maps and others would not show. Hook `staged-apps`.
3. **Sensor tables and lens libraries for the kernel** (`/usr/share/firmware/laurel-camera`). The kernel reads them on any iOS. Hook `camera-tables`.
4. Brightness and Bold Text: the two preference tweaks were not in the iOS 26 list. Hooks `brightness`, `bold-text`.

## 3. Rules each hook follows

| Rule | How |
|---|---|
| A failed stage never removes SSH or debug | `feature()` of `ios26-root-spec.py`: a failure of any kind restores the tree, launchd.plist and the overlay files to what they were before that hook, and writes one line `off NAME: why`. Self-test: "half way" |
| Independent | No hook needs another, except what iOS 16 has too: cell and ringer need the wrapper of the notch hook. Each has its own line |
| One audit line | `report.txt`, `/usr/share/laurel/ios26-root-audit.txt`, and a row in `/usr/share/laurel/root-manifest` |
| Same switches as iOS 16 | `GPU STATUSBAR NOTCH CELL AUDIO BT CAMERA TORCH HEVC XNUTILS BRIGHTNESS STAGED_APPS`, new `RINGER`. `=0` is the only wanted off |
| Binary rules | `need_binary()`: thin plain arm64, signed, page size 4096, and its sha256 on `out/ios26/parity-check.tsv`, which only `ios26-parity-build.sh` writes after `ios26-injected-check.py` (0 instructions newer than ARMv8.0, each library and import in the 23F84 cache). Another file: refused, one line |
| No probes | Each plug-in has its self-check and one on/off line; a boot-arg is only a kill switch: `notch=0 cell=0 ringer=0 torch=0 laurel_hevc=0 cell_data=0` |
| Nothing new can stop a boot | No hook edits a boot task. Launchd's own plist has 25 Boot tasks, 16 with `RequireSuccess` (13 programs: fsck, mount, dirs_cleaner, cc_fips_test, init_data_protection, launchd_cache_loader, tzinit, and the restore ones); self-test: none of those programs is touched by a hook, and no job has a boot-task key. launchd loads the new jobs after those tasks |
| A crash loop blocks no other job | `com.laurel.celld`: KeepAlive false. The wrappers of SpringBoard and cameracaptured: two fast exits in a boot = no inserted file for the rest of the boot; the exec of Apple's file stays. Restarts stay launchd's own (ThrottleInterval) |

## 3.1 Wi-Fi settings service

Nothing to install: as on iOS 16, stock `wifid` holds `com.apple.wifi-xpc` and the other Wi-Fi services [V launchd.plist], with the ADT node `wlan` of `mkadt.py` that its `_LimitLoadToDeviceTree` asks for. Kernel: Apple80211 at the 23F84 sizes (`ios26-userland.md` 8.3). `InterfaceNamer` 10 s is in `tweaks()`. IOS-26-Hot found on its phone that configd made a Wi-Fi service for en0 only when `preferences.plist` held no network part [self-reported, its case: a file with host names only]. Ours holds the USB service from `root-add-ssh.py`, as iOS 16, where configd added the Wi-Fi service [V iOS 16 boot; `root-update.md`]. On 26: [U]. Evidence to read: `scutil --dns` style lines of `ssh-net.txt`, the list in Settings.

## 4. Audio

- 23F84 has no mediaserverd. `audiomxd` holds the audio services [V launchd.plist]. `System/Library/Audio/Plug-Ins/HAL` and `Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin` are in the donor [V]. IOS-26-Hot runs its plug-in of the same origin in the same process [self-reported].
- `ios26-devices.patch` on top of the iOS 16 source, only for this build (`IOS26=1 userland/laurel/audio/build.sh`). Hot's D421AP plug-in has five devices and four microphone channels, data sources `mc01`..`mc04`; 23F84 VirtualAudio has the string `Baseband Voice` [V]. Ours: `Baseband Voice` exists with no call path (the output goes nowhere, the input is silence); `Codec` has 4 channels with the one microphone copied to each. The kernel side (2500, 2920) does not change; 2920 already names `audiomxd`.
- With the plug-in in the root, `VirtualAudio.plugin` stays and `BTAudioHALPlugin.driver` goes to `HAL.disabled`, as iOS 16. With no plug-in VirtualAudio goes, as iOS 16 without devices.
- Ringer: Hot needs `-[SBRingerControl isRingerMuted]` = NO on 23F84 [self-reported]. `liblaurel-ringer.dylib` does this in SpringBoard. Hot's backboardd part is not here: iOS 26 runs Apple's backboardd with no wrapper, and a wrapper there is a risk for the compositor. Evidence to read: `LAUREL RINGER: on` and sound from system alerts.
- Not ported: Hot's `adspd`: our ADSP path is in the kernel.

## 5. Flashlight

[V disassembly of 23F84 CMCapture]. `com.apple.coremedia.flashlight` is a MachService of `cameracaptured`, which starts `FigFlashlightServerStart` itself. So there is no HAL host. `laurel-cameracaptured` (`cc_wrap.c`) is the job's start program; it inserts `LaurelFlashlight` and execs Apple's file. The file stays at the HAL path because the kernel's button test (2783) reads that path; on 26 it is a dylib with no plug-in type in `Info.plist`, so `audiomxd` does not load it.

The messages FigFlashlight sends changed, and `LF_IOS26` answers the new ones:

| Message | 20H392 | 23F84 |
|---|---|---|
| Register | `...deviceSharingWithOtherClientsAllowed:deviceAvailabilityChangedHandler:` | `...deviceSharingWithOtherClientsAllowed:clientType:deviceAvailabilityChangedHandler:` |
| Stream | `copyStreamForFlashlightWithPosition:deviceType:forDevice:` | `copyStreamWithoutControlFromDevice:position:deviceType:error:` |
| Take back | `takeBackDevice:forClient:informClientWhenDeviceAvailableAgain:` | `...:prefersDeviceInvalidatedImmediately:` |
| Availability | `activeDeviceEquals:` | `isActiveDefaultDeviceAvailableToFlashlight:` |

Guards: cache UUID `6EF96C18-...` (the lowered cache keeps it [V header]), the method at `0x1ae2d0b34` with first word `mov x2, #0`, callers by range from the CMCapture symbols. Other callers get the stock vendor. Evidence to read: `LAUREL FLASHLIGHT: on`, `TorchLevel L -> P %`. `[U]`: `flashlight_IsOverheated` compares `-[FigCaptureThermalMonitor maxTorchLevel]` with 1.0. If the thermal monitor gives less on this phone, the button says overheated.

## 6. Camera

The kernel part and the sensor tables are in. The iOS plug-in **is not ported**. Exact reasons [V unless marked]:

1. `media_hooks.c` replaces 11 CMCapture methods with a table of unslid 20H392 addresses and first words. It is keyed to the cache UUID, so on 23F84 it stays off. One method of the table, `-[BWGraph _logActiveSinkNodesAfterGraphStopTimeout]`, has no symbol in 23F84.
2. `initWithDeviceCreateFunction:` is not in 23F84. The vendor is `initWithDefaultDeviceCreateFunction:cmioExtensionDeviceCreateFunction:cmioDiscoverySession:`, reached by `+sharedCaptureDeviceVendorWithDefaultDeviceCreateFunction:`; a hook point exists, the code does not.
3. Capture moved to `cameracaptured`, which starts its own servers and `FigCapturePreloadShaders` in `main` [V imports]. The plug-in's list of servers and its skip of the shader preload are for mediaserverd. `cameracaptured` has no Metal device here: it is not on the client list (`-cameracaptured`).
4. The FigCaptureDevice and FigCaptureStream class tables of 23F84 were not read. A wrong offset is a crash in each capture session.
5. There is no known good result to port against: on iOS 16 no frame has shown light (`half-done-audit.md` row 1, `camera.md`). IOS-26-Hot has no camera: it removes the job (`SKIP_LABELS`).

Evidence needed from a real boot, in this order: (a) `LAUREL CAMERA: rear stream` lines on this kernel, with light on a frame; (b) `cameracaptured` state: `ctl ps`, `CRASH cameracaptured`, whether it reaches "cameracaptured servers have finished starting"; (c) what `LAUREL FLASHLIGHT` says, as that hook goes through the same vendor. Then: a 23F84 hook table from `out/ios26/parity/CMCapture.syms`-style symbols, and the class tables read from `BWFigCaptureDeviceVendor _createDevice:`.

Until then: the ADT nodes stay (`mkadt.py`, `CAMERA=0` removes them), so Camera.app shows and has no device. `FBLaunchWatchdogScale` 3 frees the foreground slot, as on iOS 16.

## 7. No-wipe update

**Not ported.** `root-update.sh` works over SSH on a running root, with `phone.sh` on toybox + dash, against the sidecar and stages of `root.sh`, and a `flash-check` keyed to the iOS 16 features. It needs a booted iOS 26 root with SSH, and it has never written on a phone on iOS 16 (`root-update.md` section 9). Payload without a consumer would be a stub. Evidence needed: first boot with SSH (`LAUREL SSH: on`); first `--dry-run` of the iOS 16 path on the phone. Until then the iOS 26 root goes on with `dual-boot.sh install`, which erases `/private/var` of iOS 26.

## 8. Results [V host, at merge c4903b2 with origin/laurel-sprout cad01db]

| Check | Result |
|---|---|
| Binaries | `ios26-parity-build.sh`: 13 of 13 pass: 0 instructions newer than ARMv8.0, 0 libraries and 0 imports missing in 23F84, page size 4096: liblaurel-notch, laurel-springboard, liblaurel-ringer, liblaurel-cellbar, laurel-celld, RedwoodAudio, negroni-bluetool, LaurelFlashlight, laurel-cameracaptured, HEVCH8.videodecoder, XNUtils, powermenu-helper, pmregister |
| Hook self-test | `ios26-root-spec.py --self-test`: air 10 of 10, Metal 15 of 15, debug 27 of 27, parity 58 of 58 with the real stages |
| Audio host test | `scripts/laurel/mic-host-test.sh`: PASS, with `hal_test_ios26.c` under ASan and UBSan. It found one bug of the first patch: 5 devices in a list of `words[4]`. Fixed |
| iOS 26 kernel | `kernel-ios26-linux.sh`: 212 applied, 86 applied+rules, 7 skipped, 11 base, 0 errors; 0 linker failures; LSE/RCpc 0; printf-arg-check OK; armv80-check 0. `LAUREL BUILD: c4903b26fd 320 patches, series b01e2598da61163b, ios26_4k`. No new kernel patch was needed |
| iOS 16 kernel | `kernel-linux.sh`: applied 314, failed 0; LSE/RCpc 0; printf-arg-check OK; armv80-check with the data symbols 0. `git diff` of `patches/` on this branch: none of ours |
| Full root at a scratch path | `ROOT_OUT=out/ios26/root-scratch`: 34,354,491,392 bytes, real 18.0 GB, inside iosroot with margin 401,584,128 bytes. `hfs-verify`: 236,660 files, 2,844 symlinks, 222,717 folders, SHA-256 all match, 17,505 MiB, 14,261 MiB free of 32,762 MiB. `fsck.hfsplus -f -n`: OK. Kernel read-only mount: 462,221 of 462,221 entries, 0 extra, 0 differ. Layout 11 of 11. SHA-256 through the mount: 5,089 MiB, 0 differ |
| Root manifest | `c4903b26fd 20261102T060446 kernel-series b01e2598da61163b features 19 installed 17 off 2 missing 0` |
| Build honesty | `build-honest-test.sh`: 60 of 60 (the iOS 16 path) |

The shared image `~/op10-apple/ios26/23F84-n104ap/root/ios26-root.img` was not written. It is the "before" of the table. The owner rebuilds it: section 1.

One root build failed with EIO from `apfs-fuse` on one file (`ContactsUI.axbundle/_CodeSignature/CodeResources`, 8 tries) while two kernels built at the same time and the donor images had a second mount. The next run with no other load passed. It is the read path of `apfs-fuse`, not of the image: run the root alone.

## 9. The table (generated)

<!-- ios26-parity-audit.py: begin -->

Generated by `scripts/laurel/ios26-parity-audit.py`. Counts: **20 present, 19 ported now, 2 not portable before a boot, 5 not applicable**, of 46 rows. 47 source items and 114 kernel patches, each in a row. Tweak items: 46 same, 1 not applicable, 0 differ.

### Features

| Feature | iOS 16 path | In kernel-ios26 | In iOS 26 root | State | Action |
|---|---|---|---|---|---|
| Wi-Fi: join, 5 GHz, signal bars | kernel series; stock wifid | yes: 2400 2401 2402 2403 2405 2406 2407 2408 2409 2410 2411 2880 2881 2882 2883 2884 2885 2886 2887 2888; strings `LAUREL WIFI:` | yes: job com.apple.wifid | present | None. 23F84 sizes of Apple80211: kernel post/9000, ios26-userland.md 8.3, host test only |
| Wi-Fi settings service | stock wifid (com.apple.wifi-xpc), configd; root-tweaks-extra.py InterfaceNamer | yes: 2411 | yes: `/System/Library/SystemConfiguration/InterfaceNamer.bundle/Info.plist`, job com.apple.wifid, job com.apple.wifianalyticsd | present | None new: wifid stays with its MachServices. Its load key needs the ADT node wlan: mkadt.py. wifiFirmwareLoader stays as on a stock root [U on this phone] |
| Cellular: SIM, bars, name in iOS | root-cell.sh, userland/laurel/cell/laurel_cellbar.c | yes: 2760 2786; strings `LAUREL CELL:` | yes: `/usr/local/lib/liblaurel-cellbar.dylib` | ported now | Hook cell. Classes and selectors in the 23F84 cache [V names]. Method types: its self-check. CommCenter stays out, as iOS 16 |
| Cellular: data session (laurel-celld) | root-cell.sh, celld-job.py, userland/laurel/cell/laurel_celld.c | yes: 2940 2941 2942 2943; strings `LAUREL IPA:`, `LAUREL CELL DATA:` | yes: `/usr/local/libexec/laurel-celld`, job com.laurel.celld | ported now | Hook cell. KeepAlive false, exits at once with no kern.laurel_cell_net |
| Cellular: dual SIM | kernel 2760 (nas1, nas2); cellbar shows both slots | yes: 2786; strings `LAUREL CELL:` | yes: `/usr/local/lib/liblaurel-cellbar.dylib` | ported now | Hook cell: the same two-slot code. Default SIM: not built on iOS 16 either |
| Cellular: network search, SMS, voice, Settings > Cellular | not built on iOS 16 (cellular.md 11.6) | - | no: nothing to port | not applicable | iOS 16 has no such stage, so nothing to port. IOS-26-Hot has CoreTelephony XPC in its cellulard on 23F84 [self-reported]: a new feature, not parity |
| Cellular: IPA data path | kernel; boot-arg ipa=0 by default (uefi-image.sh) | yes: 2775 2780 2782 2941; strings `LAUREL IPA:` | not needed | present | Same boot-arg path: ios26-image.sh calls uefi-image.sh. IPA_TEST=1 is the test image |
| Audio out: speaker | root-audio.sh, external/ios-topaz/userland/audio | yes: 2500; strings `LAUREL AUDIO:` | yes: `/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver/RedwoodAudio`, `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio` | ported now | Hook audio: audiomxd loads the plug-in from the same folder [V strings; Hot self-reported]. 5 devices: Speaker, Hawking, Actuator, Codec, Baseband Voice (ios26-devices.patch). VirtualAudio stays, BTAudio to HAL.disabled |
| Microphone | userland/laurel/audio/mic-input.patch | yes: 2920; strings `LAUREL MIC:` | yes: `/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver/RedwoodAudio` | ported now | Hook audio. Codec has 4 channels, the one microphone in each. Kernel: audiomxd is on its name list [V 2920] |
| Voice input: Siri, Dictation | not tested on iOS 16 (audio.md): needs assistantd and Apple services | - | no: nothing to port | not applicable | iOS 16 has no stage for it; the microphone row is the part we own |
| Mute switch answer | none on iOS 16 | - | yes: `/usr/local/lib/liblaurel-ringer.dylib` | ported now | Hook ringer: new for 23F84 (IOS-26-Hot 504d74c, self-reported). SpringBoard part only: backboardd has no wrapper on 26 |
| Haptics | kernel 2700 + Actuator device of the plug-in | yes: 2700; strings `LAUREL HAPTIC:` | yes: `/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver/RedwoodAudio` | ported now | Hook audio |
| Bluetooth | root-bt.sh, scripts/bt/bt-launchd.py, userland/laurel/bt | yes: 2600; strings `LAUREL BT:` | yes: `/usr/libexec/negroni-bluetool`, job com.apple.bluetoothd, job com.apple.BlueTool | ported now | Hook bluetooth: job with BT_HCI_TRANSPORT, stand-in. Strings of the transport in 23F84 bluetoothd [V]; the BlueTool XPC of 26: [U] |
| Camera: kernel, sensor tables | root-camera.sh steps 1, 5 | yes: 2770 2771 2772 2773 2784 2913; strings `LAUREL CAMERA:` | yes: `/usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_sunny.so`, `/usr/share/firmware/laurel-camera/libactuator_dw9800.so` | ported now | Hook camera-tables: the kernel reads them, on any iOS |
| Camera: iOS plug-in | root-camera.sh step 2, userland/camera, userland/laurel/camera | - | no: one audit line `off` | not portable before a boot | See "Camera" below: 20H392 hook table, capture moved to cameracaptured, vendor init changed, ABI not read, no frame with light on iOS 16 to compare |
| Flashlight | root-flashlight.sh, userland/laurel/flashlight | yes: 2781 2783; strings `LAUREL TORCH:` | yes: `/System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver/LaurelFlashlight`, `/usr/local/libexec/laurel-cameracaptured` | ported now | Hook flashlight: LF_IOS26 build with the 23F84 vendor messages; laurel-cameracaptured inserts it |
| HEVC, HEIC, wallpapers | root-hevc.sh, userland/laurel/hevc | - | yes: `/System/Library/VideoDecoders/HEVCH8.videodecoder` | ported now | Hook hevc: same slot in 23F84 VTLoadVideoDecoders, same decoder class shape [V]. Runs in videocodecd |
| Brightness | root-brightness.py | yes: 2201 2871 2872; strings `LAUREL BACKLIGHT:`, `LAUREL PANEL:` | yes: pref com.apple.backboardd BKEnableALS=False | ported now | Hook brightness |
| Touch | kernel | yes: 2017 2200 2914; strings `LAUREL TOUCH:` | not needed | present | Kernel only: no file on the root |
| Keys | kernel | yes: 2202; strings `LAUREL KEYS:` | not needed | present | Kernel only: no file on the root |
| Top bar (status bar provider) | root-statusbar.py part 1 | - | yes: pref com.apple.UIKit UIStatusBarVisualProviderClassName='_UIStatusBarVisualProvider_FixedSplit' | ported now | Hook statusbar: same override; no iPhone model in it |
| Notch: waterdrop in SpringBoard | root-statusbar.py part 2, userland/laurel/notch | - | yes: `/usr/local/lib/liblaurel-notch.dylib`, `/usr/local/libexec/laurel-springboard`, job com.apple.SpringBoard | ported now | Hook notch: asks the screen type in force and needs 360x780 @2, no iPhone10,3 in the code [V]. Safe areas: the type the N104AP ladder picks: read on the phone |
| Resolution 720x1560 @2 | kernel 2103 + mkadt.py | yes: 2001 2002 2008 2101 2103 2104 2870 2915; strings `LAUREL FB PIPE:`, `LAUREL FB SCANOUT:`, `LAUREL SPOOL:` | not needed | present | ADT donor N104AP has artwork 0x700; the panel size is in /chosen display-scale. ios26-kernel.md 5 |
| Battery, charging | kernel | yes: 2300 2301 2302 2710; strings `LAUREL BATTERY:`, `LAUREL CHARGE MODE:`, `LAUREL SPMI:` | not needed | present | Kernel only: no file on the root |
| Thermal, CPU clocks | kernel | yes: 2303 2890 2891; strings `LAUREL THERMAL:`, `LAUREL CPUFREQ:`, `LAUREL CPU TOP:` | not needed | present | Kernel only: no file on the root |
| RTC | kernel | yes: 2720; strings `LAUREL RTC:` | yes: `/private/var/db` | present | The kernel writes /private/var/db/laurel_rtc; the folder is on the root |
| XNUtils, stats | root-xnutils.sh, userland/laurel/xnutils | yes: 2911; strings `LAUREL STATS:` | yes: `/Applications/XNUtils.app/XNUtils`, `/usr/local/libexec/powermenu-helper`, `/usr/local/bin/pmregister` | ported now | Hook xnutils: XNUTILS_IOS26=1 copy; helper root:mobile 4750 in the catalog |
| Bench | none on iOS 16 stage (ios26-metal.md 10) | - | yes: `/Applications/XNUtils.app/XNUtils` | ported now | Hook xnutils: bench.m is in the iOS 26 copy |
| Widgets, posters: jetsam | root-tweaks-extra.py, jetsam_widgets.py | - | yes: `/System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist` | present | In tweaks() and root-add-metal-ios26.sh |
| System apps | root-system-features.py | - | yes: `/Applications/MobileCal.app/Info.plist`, `/Applications/MobileNotes.app/Info.plist` | ported now | Hook staged-apps: 49 apps; the first LaunchServices seed registers them |
| aggregated job and its limit | root-system-features.py | - | no: nothing to port | not applicable | com.apple.aggregated is not in 23F84: launchd.plist has only .addaily [V] |
| No-wipe update | root-update.sh, root-delta.py, rootupdate/ | - | no: one audit line `off` | not portable before a boot | See "No-wipe update" below: the path needs SSH on a booted root, and has never written on a phone on iOS 16 |
| GPU firmware | root-add-gpu.sh, gpu-firmware.sh | yes: 2150 2151 2153 2154 2155 2156 2157 2158 2159 2160 2161 2892 2895 2961; strings `LAUREL GPU:`, `LAUREL GPU SMMU:`, `LAUREL GPU POOL:` | yes: `/usr/share/firmware/laurel/a610_zap.mdt`, `/usr/share/firmware/laurel/a630_sqe.fw` | ported now | Hook gpu-firmware. **The root before this table had none: `LAUREL GPU: off`, so no Metal device and no picture** [V code + manifest] |
| Mesa, EAGL shim, backboardd GL wrapper | root-add-gpu.sh, gpu-userland.sh | yes: 2152 | no: nothing to port | not applicable | 23F84: CA::WindowServer::AccelServer::renderer is Metal or nothing; the server path reaches no GLESContext [V ios26-userland.md 8.1]. Not missing |
| Metal stack, compositor | root-add-metal.sh; iOS 26: root-add-metal-ios26.sh | yes: 2850 2851; strings `LAUREL METAL:` | yes: `/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal` | present | Hook metal26 |
| SSH, debug tools, USB network | scripts/net/root-add-ssh.sh; iOS 26: root-debug-ios26.sh | yes: 2005 2006 2007 2013 2014 2162 2905 2951 2955 2956; strings `LAUREL USB:`, `LAUREL CTL:`, `LAUREL USB POLL:` | yes: `/usr/local/bin/dropbearmulti`, job dev.iosplus10.dropbear | present | Hook debug-ios26 |
| AirPlay | root-airplay.sh | - | yes: `/usr/libexec/laurel-airplay`, job com.laurel.airplay | present | Hook air-ios26 |
| AirDrop, AWDL | root-awdl.sh | yes: 2930 2931 2932; strings `LAUREL AWDL:` | yes: `/usr/libexec/laurel-awdld`, job com.laurel.awdl, no job com.apple.wifip2pd | present | Hook air-ios26 |
| Bold text off | root-tweaks-boldtext.py | - | yes: pref com.apple.Accessibility EnhancedTextLegibilityEnabled=False | ported now | Hook bold-text |
| Jobs that only burn CPU | root-tweaks-perf.py | - | yes: no job com.apple.syncdefaultsd | present | In tweaks(). Program list unchanged; their loop on 26: [U] |
| launchd tweaks | sweet-root-tweaks.py, root-tweaks-extra.py | - | yes: no job com.apple.CommCenter, no job com.apple.fairplayd.H2, no job com.apple.voicemail.vmd, no job com.apple.ReportCrash, no job com.apple.spindump, no job com.apple.tailspind, no job com.apple.activityawardsd | present | In tweaks(), one audit line each |
| Root layout: containers, logd stores, keybag, dyld | external/ios-topaz/tools/mkiosroot.sh | yes: 2904; strings `LAUREL AKS:` | yes: `/private/var/keybags/systembag.kb`, `/private/var/db/diagnostics/.migrated`, `/private/var/containers/Bundle`, `/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e` | present | ios26-root-spec.py main() and tweaks() |
| Kernel base: CPU, RAM, UFS, boot, power off | kernel | yes: 2000 2003 2004 2009 2011 2012 2015 2016 2018 2100 2404 2902 2906 2916; strings `LAUREL RTC:`, `LAUREL REBOOT:`, `LAUREL CPU:` | not needed | present | Kernel only: no file on the root |
| Sandbox grants, entitlements | kernel | yes: 2903 2910; strings `LAUREL SANDBOX:` | not needed | present | Grants by entitlement, not by process name [V 2910]; 23F84 ops: post/9000 |
| EL0 LSE emulation fixes of topaz 0081 | kernel 2960 | NO: 2960: skipped: not needed: iOS 16 fix of t | no: nothing to port | not applicable | iOS 26 has its own emulator (laurel_a64emu) and post/9000 moved the table end; 2960 is in skip.txt: docs/laurel_sprout/ios16-lse.md |
| Dual boot, build stamp | kernel; dual-boot.sh; root-manifest | yes: 2912 2950; strings `LAUREL BUILD:`, `LAUREL DUALBOOT:` | yes: `/usr/share/laurel/root-manifest` | present | The manifest has one row per hook here |

### Tweaks of the iOS 16 root, per item

| Script | Item | iOS 26 root | Evidence |
|---|---|---|---|
| root-tweaks-extra.py | drop com.apple.fairplayd.H2 | yes | job not in launchd.plist |
| root-tweaks-extra.py | drop com.apple.voicemail.vmd | yes | job not in launchd.plist |
| root-tweaks-extra.py | drop com.apple.ReportCrash | yes | job not in launchd.plist |
| root-tweaks-extra.py | drop com.apple.spindump | yes | job not in launchd.plist |
| root-tweaks-extra.py | drop com.apple.tailspind | yes | job not in launchd.plist |
| root-tweaks-extra.py | drop com.apple.aggregated | yes | job not in launchd.plist |
| root-tweaks-extra.py | drop com.apple.aggregated.addaily | yes | job not in launchd.plist |
| root-tweaks-extra.py | drop com.apple.bluetoothd | yes | dropped, then back with BT_HCI_TRANSPORT from the bluetooth hook, as root-bt.sh on iOS 16 |
| root-tweaks-extra.py | drop com.apple.activityawardsd | yes | job not in launchd.plist |
| root-tweaks-extra.py | com.apple.migration DMLastMigrationResults | yes | DMLastMigrationResults = {'buildVersion': '23F84', 'success': True} |
| root-tweaks-extra.py | com.apple.locationd LocationServicesEnabledIn8.0 | yes | LocationServicesEnabledIn8.0 = True |
| root-tweaks-extra.py | com.apple.frontboard FBLaunchWatchdogScale | yes | FBLaunchWatchdogScale = 3 |
| root-tweaks-extra.py | com.apple.springboard FBLaunchWatchdogScale | yes | FBLaunchWatchdogScale = 3 |
| root-tweaks-extra.py | InterfaceNamer WaitStackTimeout | yes | key present |
| root-tweaks-extra.py | ExtensionKit enforce_xpc_cache_code_signing | yes | key present |
| root-tweaks-extra.py | backboardd CA_HEARTBEAT_RATE | yes | CA_HEARTBEAT_RATE=60 |
| root-tweaks-extra.py | widget + lsd jetsam | yes | audit line, file in the overlay |
| sweet-root-tweaks.py | com.apple.migration LastSystemVersion | yes | LastSystemVersion = '23F84' |
| sweet-root-tweaks.py | com.apple.migration DMUserDataDisposition | yes | DMUserDataDisposition = {'SyntheticDidUpgrade': False, 'buildVersion': '23F84'} |
| sweet-root-tweaks.py | com.apple.springboard BKNoWatchdogs | yes | BKNoWatchdogs = True |
| sweet-root-tweaks.py | com.apple.springboard FBLaunchWatchdogExceptions | yes | FBLaunchWatchdogExceptions = {'com.apple.purplebuddy': 100.0} |
| sweet-root-tweaks.py | com.apple.springboard MCForceShowCloudConfigurationUI | yes | MCForceShowCloudConfigurationUI = False |
| sweet-root-tweaks.py | com.apple.purplebuddy SetupDone | yes | SetupDone = True |
| sweet-root-tweaks.py | com.apple.purplebuddy SetupFinishedAllSteps | yes | SetupFinishedAllSteps = True |
| sweet-root-tweaks.py | com.apple.purplebuddy SetupVersion | yes | SetupVersion = 11 |
| sweet-root-tweaks.py | com.apple.purplebuddy daemonizeNeedsToRun | yes | daemonizeNeedsToRun = False |
| sweet-root-tweaks.py | com.apple.purplebuddy.notbackedup ShouldRunDiagnosticsMiniBuddy | yes | ShouldRunDiagnosticsMiniBuddy = False |
| sweet-root-tweaks.py | com.apple.purplebuddy.notbackedup ShouldRunHSA2MiniBuddy | yes | ShouldRunHSA2MiniBuddy = False |
| sweet-root-tweaks.py | com.apple.purplebuddy.notbackedup ShouldRunKeychainSyncMiniBuddy | yes | ShouldRunKeychainSyncMiniBuddy = False |
| sweet-root-tweaks.py | com.apple.purplebuddy.notbackedup ShouldRunMesaMiniBuddy | yes | ShouldRunMesaMiniBuddy = False |
| sweet-root-tweaks.py | com.apple.purplebuddy.notbackedup ShouldRunPaymentMiniBuddy | yes | ShouldRunPaymentMiniBuddy = False |
| sweet-root-tweaks.py | com.apple.purplebuddy.notbackedup ShouldRunStandardMiniBuddy | yes | ShouldRunStandardMiniBuddy = False |
| sweet-root-tweaks.py | com.apple.purplebuddy.notbackedup SilentICDPUpgrade | yes | SilentICDPUpgrade = False |
| sweet-root-tweaks.py | com.apple.managedconfiguration.notbackedup LockdownActivationIndicatesCloudConfigurationAvailable | yes | LockdownActivationIndicatesCloudConfigurationAvailable = False |
| sweet-root-tweaks.py | launchd _PanicOnCrash renamed | yes | no job has the key |
| sweet-root-tweaks.py | drop com.apple.CommCenter | yes | job not in launchd.plist |
| sweet-root-tweaks.py | MediaToolbox StartRecorderServer | yes | applied (audit line) |
| sweet-root-tweaks.py | activation data ark | yes | not-found (audit line) |
| sweet-root-tweaks.py | containers | yes | in the manifest |
| root-tweaks-perf.py | drop by program nanotimekitcompaniond | yes | no job runs it |
| root-tweaks-perf.py | drop by program wifip2pd | yes | no job runs it |
| root-tweaks-perf.py | drop by program syncdefaultsd | yes | no job runs it |
| root-tweaks-boldtext.py | com.apple.Accessibility EnhancedTextLegibilityEnabled | yes | EnhancedTextLegibilityEnabled = False |
| root-brightness.py | com.apple.backboardd BKEnableALS | yes | BKEnableALS = False |
| root-statusbar.py | com.apple.UIKit UIStatusBarVisualProviderClassName | yes | UIStatusBarVisualProviderClassName = '_UIStatusBarVisualProvider_FixedSplit' |
| root-system-features.py | staged apps | yes | in the manifest |
| root-system-features.py | aggregated back | n/a | not in 23F84: only com.apple.aggregated.addaily [V] |

### Audit lines of the hooks in the judged root

```
applied   debug-ios26: 160 files and links; the same in a root with no compositor. Not proven until it runs on the phone
applied   air-ios26: 9 files; jobs out: []; laurel-root: air-ios26: awdl on, first try waits for the owner; airplay on; wifip2pd out; 2 cdhashes
applied   metal26: 18 files; laurel-root: metal26: on: NegroniMetal.bundle (Turnip a610 + metal2vulkan), clients * -chronod -cameracaptured -WidgetRenderer_Default -PosterBoard, compositor on Metal, 8 binaries, no GL fallback on 2
applied   gpu-firmware: 5 files in /usr/share/firmware/laurel, the phone's own: a610 zap shader + SQE. The kernel reads them for the Metal device. Not proven until it runs on the phone
applied   statusbar: UIStatusBarVisualProviderClassName = _UIStatusBarVisualProvider_FixedSplit in com.apple.UIKit and .GlobalPreferences of mobile and root (4 files): 360x780 pt matches no notched table of UIKit. Not proven until
applied   notch: liblaurel-notch.dylib + laurel-springboard; job com.apple.SpringBoard starts the wrapper (crash guard: 2 fast exits = Apple's shape for this boot; notch=0). Waterdrop {135.2, 0, 89.6, 26.5} pt. Not proven until it
applied   cell: 3 files: liblaurel-cellbar.dylib for laurel-springboard, laurel-celld + job com.laurel.celld (KeepAlive false; exits with no kern.laurel_cell_net). CommCenter stays out: as iOS 16, no Settings > Cellular, SMS or vo
applied   ringer: liblaurel-ringer.dylib for laurel-springboard: -[SBRingerControl isRingerMuted] = NO (no mute switch here; idea of IOS-26-Hot 504d74c); ringer=0. Not proven until it runs on the phone
applied   audio: RedwoodAudio.driver: Speaker, Hawking, Actuator, Codec (4 channels, the one microphone in each: /dev/redwood-mic, kernel 2920), Baseband Voice (no call path); VirtualAudio.plugin stays; BTAudioHALPlugin moved to H
applied   bluetooth: job com.apple.bluetoothd with BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000; BlueTool job runs /usr/libexec/negroni-bluetool. With no ADT node or laurelbt=0: bluetoothd exits 0 once (SuccessfulE
applied   camera-tables: 3 sensor and 2 lens libraries in /usr/share/firmware/laurel-camera (the phone's own: the kernel reads them). Not proven until it runs on the phone
off       camera-plugin: not ported before a boot: 20H392 hook table (11 fixed addresses), initWithDeviceCreateFunction: is gone in 23F84 (initWithDefaultDeviceCreateFunction:cmioExtensionDeviceCreateFunction:cmioDiscoverySession:
applied   flashlight: LaurelFlashlight (23F84 vendor messages, cache UUID + first word checked) in cameracaptured through laurel-cameracaptured (crash guard, torch=0, /var/db/laurel/flashlight-off); kernel 2781 + 2783 publish the 
applied   hevc: on: HEVCH8.videodecoder, 1619808 bytes, sha256 44583b60ad03d1a9; it runs in videocodecd; Apple's VCPHEVC stays behind it; laurel_hevc=0. Not proven until it runs on the phone
applied   xnutils: 5 files: /Applications/XNUtils.app, powermenu-helper root:mobile 4750, pmregister: stats, Metal options, bench. Not proven until it runs on the phone
applied   brightness: BKEnableALS false in com.apple.backboardd of mobile and root: no ambient light sensor for iOS; the key is in 23F84 [V strings]; the slider sets the level (kernel 2201). Not proven until it runs on the phone
applied   bold-text: EnhancedTextLegibilityEnabled false in com.apple.Accessibility of mobile, as iOS 16. The iOS 16 reason (CoreImage GL) has no proof on 26; the key is in 23F84 [V strings]. Not proven until it runs on the phone
applied   staged-apps: 49 apps moved to /Applications, their placeholders gone; the first LaunchServices seed registers them. Same volume: no size change. Not proven until it runs on the phone
off       root-update: not ported before a boot: the update path needs SSH on a booted iOS 26 root and has never written on a phone on iOS 16. Evidence needed: docs/laurel_sprout/ios26-parity.md "No-wipe update"
```

<!-- ios26-parity-audit.py: end -->

## 10. Differences from IOS-26-Hot that this branch does not take

Hot removes 41 jobs on 23F84 (`tools/sweet-root-tweaks.py` `SKIP_LABELS`, self-reported). 32 of them stay on our root: `ManagedSettingsAgent`, `PerfPowerServices` (+Extended), `perfpowermetricd`, `biomed`, `biomesyncd`, `biometrickitd.pearl`, `callintelligenced`, `cameracaptured`, `cloudpaird`, `deviceaccessd`, `driverkitd`, `factory.NFQRCoded`, `familycircled`, `findmy.findmybeaconingd`, `findmy.findmylocated`, `generativeexperiencesd`, `icloud.findmydeviced`, `modelcatalogd`, `nanobackupd`, `nanoprefsyncd.2`, `nanoregistryd`, `nanoregistrylaunchd`, `nfcd`, `passd`, `security.cryptexd`, `seld`, `siriinferenced`, `sirittsd`, `softposreaderd`, `watchdogd`, `webinspectord`. Not an iOS 16 item, and not proven here. If the first boot shows a crash loop in one of them, this is the first list to read. The same for its `CA_DISABLE_FRAMEBUFFER_COMPRESSION=1` on backboardd.

Hot's `cellulard` (a CoreTelephony XPC server) gives Settings > Cellular and calls on its phone [self-reported]. The iOS 16 root has neither, so it is a new feature, not parity. Its QMI lives in user space over `/dev/pmem`; ours lives in the kernel (2760). Not taken.

## 11. What is not proven

All of it runs only on the phone. In particular: dyld 23F84 with opcode fixups in binaries of minos 16.0 (`ios26-first-boot.md` table), `DYLD_INSERT_LIBRARIES` in the two wrappers, the method types of the status bar classes (each self-check says so on the phone), the XPC protocol of `com.apple.BlueTool` on 26, VirtualAudio's route build with these five devices, the decoder in `videocodecd`'s sandbox, `FigCaptureThermalMonitor`, and each kernel feature on this xnu.
