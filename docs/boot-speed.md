# Boot speed and stability: findings from the reference ports

First boot on the NE2211 (2026-10-24): kernel at 20:09, userland at 20:10, Apple logo until the
UI at 20:26 (**~16 min**). Sources: `external/{ios-sailfish,ios-flame,bergamota,hackios-*,slop,
UniXNU-pong,UniXNU-zeta}`. [V] = seen in source/log/image, [I] = inference.

## Measured boot times in other ports

| Port | Time to lock screen | Source |
|---|---|---|
| ios-sailfish (Pixel 1) | ~20 s; first boot "a few minutes longer" | README:11, :70 |
| HackiOS (POCO X5 Pro) | ~20 s (on-demand launchd policy) | hackios-xnu-kernel README:42 |
| bergamota (POCO F1) | ~2-3 min after the MAC fix, >15 min before | NOTES.md:152-159 |
| slop negroni (before) | "logo hang" ~8 min | slop NOTES.md:564 |

## Root causes found

1. **No `/chosen` MAC addresses in the ADT** [V missing in our ADT; V cause in bergamota, ios-flame,
   ios-sailfish, HackiOS]. MobileGestalt waits for an IONetworkController for each Wi-Fi-address query;
   lsd asks once per app bundle during its first LaunchServices seed, installd 5 s per bundle.
2. **fairplayd.H2 relaunch loop** [V log]: exits at launch, relaunched every 10 s; Mach messages to
   `com.apple.fairplayd.versioned` never get a reply -> locationd (CLMescalSigner) and synchronous
   CoreLocation clients deadlock (flame HANDOFF:238-245, sailfish tweaks:15-18).
3. **30 s IORTC wait** in IOKitInitializeTime (kernel; sailfish 0086, flame 0099, pong no-rtc-wait).
4. **30 s IOAcceleratorES polling** per CoreAnimation process (QuartzCore polls 300 x 100 ms);
   sailfish 0166 / bergamota 0122 publish an empty IOAcceleratorES [V log: our backboardd polls].
5. CPU spent by crash loopers / reporters: bluetoothd (10 s loop), vmd (~29k CommCenter retries),
   ReportCrash (~60 % of a core) (sailfish).

## Status

| Change | Where | Status |
|---|---|---|
| `/chosen mac-address-{wifi0,bluetooth0,ethernet0}` | `scripts/ios16/adt-extra.py`, `config [adt.extra.chosen]` | **done** (boot image) |
| Drop fairplayd.H2, vmd, ReportCrash, spindump, tailspind, aggregated(.addaily), bluetoothd | `scripts/ios16/root-tweaks-extra.py` | **done** (next root) |
| ExtensionKit `enforce_xpc_cache_code_signing` off | same | **done** (next root) |
| `DMLastMigrationResults success`, `FBLaunchWatchdogScale 20` | same | **done** (next root) |
| Normal image: no on-screen console, no `-enable_kprintf_spam`, USB log kept | `config` (`negroniusb=2`) | **done** |
| Empty IOAcceleratorES (until the GPU service exists) | kernel patch | needs a kernel build |
| Skip the IORTC wait / publish IORTC (PMK8350 RTC) | kernel patch | needs a kernel build |
| AKS lock state "no passcode" (sailfish 0180), wrap/unwrap (HackiOS) | kernel patch | needs a kernel build |
| AMFI policy named "AMFI" + IOService stand-in (extensions, @rpath) | kernel patch | needs a kernel build |
| `/pram` + `embedded-panic-log-size` (panic backtraces) | ADT + kernel | later |
| On-demand launchd policy (HackiOS/pong: only ~22 jobs at boot) | root | later, high payoff, higher risk |
| SSH over USB (dropbear job + ue0 configd service: bergamota `tools/ssh`, `usbnet()`, `ssh()`) | root | next |
| Reboot to fastboot from iOS (flame UDP 5141 command server; bergamota REBOOT_MODE.md) | kernel | needs a kernel build |

Kernel builds: xnu-8796 needs Xcode 15 (GitHub `macos-14` runner); bergamota's iOS 18 kernel
(xnu-11215.81.4) builds on `macos-15` / Xcode 16.2 in ~20 min with ccache.
