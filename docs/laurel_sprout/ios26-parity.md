# Mi A3 iOS 26 root: parity with the iOS 16 root

Date: 2026-11-02. Branch `t3/laurel-ios26-parity`. **Host only. Nothing here has run on the phone. No flash, no reboot, no write to a device.** Labels: [V] measured here (code, disassembly, a host test), [I] inference, [U] unknown.

Owner requirement: the iOS 26 image has all features and additions of the Mi A3 on iOS 16; nothing may be missed silently.

## 1. Commands

```sh
scripts/bg.sh ios26-parity scripts/laurel/ios26-parity-build.sh     # every binary of the hooks + its check against 23F84 (about 20 minutes: one check at a time)
scripts/bg.sh ios26-root env FORCE=1 scripts/laurel/ios26-root.sh   # the root; read the lines that start with off at its end, or report.txt
python3 -I scripts/laurel/ios26-root-spec.py --self-test            # hooks: air, Metal, debug, parity
python3 -I scripts/laurel/ios26-parity-audit.py --before DIR --after DIR --write docs/laurel_sprout/ios26-parity.md     # section 8; exit 1 = an item has no row, or a row is not in the image
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
| Nothing new can stop a boot | No hook edits a boot task. Launchd's own plist has 24 Boot tasks, 14 with `RequireSuccess`; self-test: none of their programs is in the tree of the hooks' files, and no job has a boot-task key. launchd loads the new jobs after those tasks |
| A crash loop blocks no other job | `com.laurel.celld`: KeepAlive false. The wrappers of SpringBoard and cameracaptured: two fast exits in a boot = no inserted file for the rest of the boot; the exec of Apple's file stays. Restarts stay launchd's own (ThrottleInterval) |

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

## 8. The table (generated)

<!-- ios26-parity-audit.py: begin -->
<!-- ios26-parity-audit.py: end -->

## 9. Differences from IOS-26-Hot that this branch does not take

Hot removes 41 jobs on 23F84 (`tools/sweet-root-tweaks.py` `SKIP_LABELS`, self-reported). 32 of them stay on our root: `ManagedSettingsAgent`, `PerfPowerServices` (+Extended), `perfpowermetricd`, `biomed`, `biomesyncd`, `biometrickitd.pearl`, `callintelligenced`, `cameracaptured`, `cloudpaird`, `deviceaccessd`, `driverkitd`, `factory.NFQRCoded`, `familycircled`, `findmy.findmybeaconingd`, `findmy.findmylocated`, `generativeexperiencesd`, `icloud.findmydeviced`, `modelcatalogd`, `nanobackupd`, `nanoprefsyncd.2`, `nanoregistryd`, `nanoregistrylaunchd`, `nfcd`, `passd`, `security.cryptexd`, `seld`, `siriinferenced`, `sirittsd`, `softposreaderd`, `watchdogd`, `webinspectord`. Not an iOS 16 item, and not proven here. If the first boot shows a crash loop in one of them, this is the first list to read. The same for its `CA_DISABLE_FRAMEBUFFER_COMPRESSION=1` on backboardd.

Hot's `cellulard` (a CoreTelephony XPC server) gives Settings > Cellular and calls on its phone [self-reported]. The iOS 16 root has neither, so it is a new feature, not parity. Its QMI lives in user space over `/dev/pmem`; ours lives in the kernel (2760). Not taken.

## 10. What is not proven

All of it runs only on the phone. In particular: dyld 23F84 with opcode fixups in binaries of minos 16.0 (`ios26-first-boot.md` table), `DYLD_INSERT_LIBRARIES` in the two wrappers, the method types of the status bar classes (each self-check says so on the phone), the XPC protocol of `com.apple.BlueTool` on 26, VirtualAudio's route build with these five devices, the decoder in `videocodecd`'s sandbox, `FigCaptureThermalMonitor`, and each kernel feature on this xnu.
