# Notes: what we learned (read this first)

The knowledge base for this port. Agents: read this file before you start, and add what you learn
before you stop (facts, numbers, errors and their fixes, decisions). Keep one fact per line, with a
source. Mark each fact: **[V]** = seen (log, source, measurement), **[I]** = inference / guess.
Details that need more space go into the topic docs; link them from here.

Topic docs: [plan.md](plan.md) (phases) · **[gpu-status.md](gpu-status.md) (GPU work record)** · [metal-management.md](metal-management.md) (enable/disable Metal, strikes, troubleshooting) · [device-facts.md](device-facts.md) (measured hardware) ·
[boot-speed.md](boot-speed.md) · [gpu-plan.md](gpu-plan.md) · [external-repos.md](external-repos.md) ·
[build-ios16.md](build-ios16.md) · [flash-ios16.md](flash-ios16.md) · [backup-and-restore.md](backup-and-restore.md) ·
[research-report.md](research-report.md) · [uefi-binaries.md](uefi-binaries.md) · [camera-plan.md](camera-plan.md) · `patches/xnu/README-*.md` (per kernel change).

## 1. Current state (handoff, 2026-10-24)

**Handoff 2026-10-26 03:30 (newest; read this first).** The 2026-10-25 19:00 handoff is below it, kept for history.
- UI is GPU-rendered through Metal for ALL processes (`/var/db/negronimetal/clients` = `*`): NegroniMetal ->
  ios-flame frontend -> metal2vulkan (submodule external/metal2vulkan) -> Turnip -> RedwoodGPU. [V 2026-10-25
  23:35-23:41] backboardd 150 s and all processes 160 s without a crash, 4.5-14 ms per command buffer at 818 MHz,
  up to 83 GPU presents/s, STAT `late ticks 0`. The GL path (ios-spes port, scripts/gpu/phone-gl.sh) is an A/B
  only: preflight PASS, CA makes its context on Mesa, then a crash from the kernel's unhandled IOSurface
  selector 6 (guarded in eagl.c, kernel fix pending). Reddit note from the spes author: his UI runs on GLES;
  ours runs on Metal; both paths exist here.
- Root causes fixed today (sections 15-17): backboardd SIGSEGV (dc civac over unmapped host imports; Turnip 0002),
  the display path (0252 stats, 0253 CA refresh property, 0254 no fence waits on the tick + SwapWait Busy,
  0256 clock-shift after the GPU copy), the GPU clock (0237: the PERF_TABLE was sent in MHz, the GMU takes kHz;
  the GPU ran at ~5 MHz, now 817 MHz), poster XR10 answer and dead-man rules, power off (0214: PS_HOLD type).
- Known-good image: `out/ios16-khz12` (kernel 0254b+0236+0237, config args + negronigpu_level=12). Newer full
  kernels add 0214/0256/0262/0241 (not yet booted). Flash: `out/bin/op10tool ctl bootloader` (normal shell),
  `IOS16_OUT=out/ios16-khz12 scripts/flash/ios16.sh boot --yes`, `... active --yes`.
- Open: wallpaper poster extensions (AegirPoster nil buffer, Pride MPS init nil, FitnessWidget metallib compile
  kill: section 16), Weather/Calendar widgets, Safari WebGPU flashing, thermal/DCVS (GPU fixed at 818 MHz),
  battery charging (usbin 0 mV under our kernel: the phone drained to brownout during the night; charger patch
  0272 pending), USB link drops, Wi-Fi (PCIe link + QCA6490 detected with negroniwifi=10 [V]; MHI/BHI next;
  the wlan2 test image reboot-loops on a low battery), audio (stage 0 HAL plug-in installed, ADSP step 1 passes
  with 0241). Test images must carry `negronipanic=30 negronipanicreason=2` and a charged battery.
- bg.sh: `scripts/bg.sh NAME env VAR=x cmd` (a VAR=x prefix does not reach tmux). Kernel builds and flashes by
  parallel agents use the lock `out/kernel/.lock` (mkdir/rmdir).

**Handoff 2026-10-25 19:00 (newest; read this first).**
- Phone flashed: userdata = `~/op10-apple/ios16-root.simg` sha256 8f0e2843 (root-update.sh: ios16-root-new.img +
  Metal + PowerMenu; AREAS=1: GPU/ADSP/WLAN firmware areas at the end of userdata); boot_a baea1ceb = kernel
  `out/kernel/local-20261025-131141` (all 28 patches/xnu: ...0213 reboot mode, 0234, 0240 + 0290 io_submap fix,
  0260-0262 Wi-Fi, 0270/0271 battery) with config defaults (negroniadreno=22 keep=1 gpu_pool=512, negroniwifi=4,
  battery default read-only mode 1, ADSP and WLAN off).
- [V] on the phone (18:34, kernel 130140): GPU ladder 22/22, RedwoodGPU registered, no faults; Turnip vkprobe
  finds "Turnip Adreno 730", clear 64x64 PASS. Fence-only submit fix (39b8bf1) removed DeviceLost; the
  metal2vulkan device opens. Next Metal blocker: IOSurface no-copy host-memory import ("HostMemory,
  NotRepresentable"); an agent works on userland/metal/patches/m2v + flame 0003 (WIP 5ef0252).
- [V] 16:52 panic (photo) = io_submap (8 MiB, KMA_NOFAIL) full at the 0240 SMEM map: fixed (0290, 49c361c).
- Not yet tested on the phone: PowerMenu (app + setuid helper; bootloader needs 0213), battery 0270/0271,
  Wi-Fi 0262 (needs negroniwifi=10, then negroniwlan=2), audio 0240 (negroniadsp=1, steps first).
- UI is still CPU-rendered: backboardd/SpringBoard get Metal only when listed in
  /var/db/negronimetal/clients (stage 4, after probe stages 1-3 pass).
- Flash recipe: `CONFIRM=yes scripts/flash/all.sh [--skip-userdata]` after `out/bin/op10tool ctl bootloader`
  (from a normal shell; tmux cannot send UDP: macOS Local Network). Never push files with a "var" directory
  entry (it replaced the /var symlink once): use scripts/metal/phone-test.sh push (fixed) or the root hooks.

**Works [V]:** the full boot chain on the NE2211; iOS 16.7.16 reaches the home screen (photo, 2026-10-24);
touch; power/volume keys; USB live kernel log (`make usblog`).

**Does not work [V]:** GPU (CPU rendering, laggy UI) · Wi-Fi (QCA6490: no driver) · battery level
(no fuel gauge driver) · sound (no ADSP/AudioReach stack) · display brightness and sleep (no backlight
service, no DCS command) · reboot to fastboot from iOS · widgets show "Waiting..." · first boot ~16 min.

**Current flash state (2026-10-25 01:45, all flashed and booting [V]):** kernel
`out/kernel/local-20261024-191117`, `boot_a.img` `faf50996...`, root `~/op10-apple/ios16-root.simg`
`f0ec8142...` (Bold Text off), `vendor_boot_a` `c29329e0...`, `vbmeta_a` verification off, `dtbo_a`
erased, slot a. iOS reaches userspace (launchd, backboardd, SpringBoard, datamigrator) on first boot
in ~1 min [V: `logs/usblog.log` 01:45:17-01:47].

**fastbootd entry, the fix that was missing [V] 2026-10-25:** `fastbootd` boots the KERNEL from
`boot_a` (with the recovery ramdisk), so with the shim in `boot_a` every `fastboot reboot fastboot`
and every recovery boot ran the shim on the wrong initrd -> red `LOADER no SWEETXNU payload` screen
(loader.c:89 magic check, 3 min auto-reset). Fix: flash stock `boot_a` from `~/op10-backup/images`
before the fastbootd step, flash `userdata`, then write our `boot_a` in the bootloader steps
(`scripts/flash/ios16.sh recovery` now does this). `fastboot boot recovery.img` is rejected by the
ABL (`Failed to load/authenticate boot image: Bad Buffer Size`) [V].

**Known gap: the screen stays black at boot until `backboardd` sets brightness [V]** (`NEGRONI BL:
panel DBV 1024` at 01:45:30, ~13 s after the USB console comes up); the shim/Mu/Apple-logo phases
never light the panel. Patches 0250/0251 (DCS 0x51) are not in this build. Owner accepts it for now.

- `out/ios16/` normal image: ADT with `/chosen` MAC addresses, `negroniusb=2`, `negronifb_noconsole=1`
  (no debug text over the UI). Fixes the 16 min first boot [I: same fix worked in 3 other ports].
- `~/op10-apple/ios16-root.simg` (sha256 `f0ec8142...`) with all `root-tweaks-extra.py` tweaks.
- Flash both: `make flash CONFIRM=yes` (needs the owner's approval, phone in fastboot).

**In progress (agents, 2026-10-24), each in its own worktree `out/kernel/wt-*`, outputs below:**

| Work | Output | Needs |
|---|---|---|
| No IORTC wait, empty IOAcceleratorES | `patches/xnu/0200`, `0201` | kernel build |
| UDP 5141 command server (reboot/bootloader/recovery) + `op10tool ctl` | `patches/xnu/0210`, `tools/op10tool/src/ctl.rs` | kernel build |
| AKS no-passcode + wrap/unwrap, AMFI policy + IOService | `patches/xnu/0220-0222` | kernel build |
| GPU kernel: IOSurface import + present | `patches/xnu/0230-0231`, `docs/gpu-abi.md` | kernel build |
| GPU userland: Mesa freedreno A730 + EAGL dylib | `userland/negronigl/`, `scripts/gpu/`, `docs/gpu-userland.md` | kernel GPU work |
| SSH over USB + Mac internet sharing | `userland/ssh/`, `scripts/net/`, `docs/usb-network.md` | root rebuild |
| Audio: stage 0 HAL plug-in (built), ADSP start 0240 (builds), GPR/TFA plan | `docs/audio-plan.md`, `userland/audio/`, `scripts/audio/`, `patches/xnu/0240` | phone test (root `AUDIO=1`, `negroniadsp=1`) |
| Brightness (DCS 0x51) + display sleep | `patches/xnu/0250-0251` (done) | kernel build |
| Power off (PSCI SYSTEM_OFF) + `poweroff` command | `patches/xnu/0211` (done; panic stays on screen: `negronipanic=0` default, owner) | kernel build |
| **Metal on Vulkan (Turnip)**: main GPU goal | `userland/metal/`, `scripts/metal/`, `docs/metal-plan.md` | GPU kernel ABI + Turnip build |
| Bold Text crash loop: root cause found (CoreImage EAGL, no GL driver) | `docs/boldtext-crash.md`, `root-tweaks-boldtext.py` (done); CoreImage software fallback + PosterBoard fix: `userland/cifix/` (agent) | root rebuild |
| Wi-Fi QCA6490 (ath11k-style: PCIe, MHI, QMI, WMI, Apple80211) | `patches/xnu/0260-0269`, `docs/wifi-plan.md`, `scripts/wifi/` | kernel build |
| Camera feasibility + plan | `docs/camera-plan.md` | research |

Done (2026-10-24, apply together on `base` in name order [V]): 0200-0202 (boot waits, IOKit quiet),
0210 (UDP 5141 command server, reboot reason), 0220-0223 (AKS, AMFI, Sandbox), `op10tool ctl`.

Patch number ranges: 0200-0209 boot waits, 0210-0219 reboot/control, 0220-0229 AKS/AMFI/Sandbox,
0230-0239 GPU, 0240-0249 audio, 0250-0259 display, 0260-0269 Wi-Fi. Take a new range for new topics.

**Blocker: kernel builds.** See section 5. Decision pending with the owner: install Xcode 15.4 locally
or a CI repo. Disk: 43 GiB free after the 2026-10-24 cleanup (enough). The owner downloads
`Xcode_15.4.xip` (Apple ID needed).

## 2. Boot chain and the numbers that matter

ABL -> ios-sweet shim (`slop/shim`, BOARD=negroni, header v4 `boot_a`) -> Mu-Silicium UEFI
(`negroniPkg`, in the ramdisk) -> UniXNU boot menu (3 s) -> DarwinBoot -> XNU xnu-8796.141.3
(16K pages, plain arm64, `MACHINE_CONFIG=NEGRONI`, DEVELOPMENT) -> iOS 16.7.16 20H392
(iPhone X D22AP identity) HFS+ root in `userdata` (`rd=ufsroot0`).

- **DarwinBoot green bar** = the kernel entry code ran. Nothing after it = the kernel stopped before its console [V].
- **Mu "Kernel RAM" must be 0x841000000 + 0x13F000000** for the 16K kernel (32 MiB-aligned VA-PA delta;
  DarwinBoot window 0x841004000). 0x840000000 + 0x140000000 (the port's later iOS 17 / 4K value) hangs
  after the green bar [V, first boot 2026-10-24]. Fix: `patches/mu/0001-negroni-kernel-ram-16k.patch`.
- **ADT `/chosen` mac-address-wifi0/bluetooth0/ethernet0 are required.** Without them MobileGestalt waits
  for an IONetworkController on each Wi-Fi-address query; lsd/installd stall ~15 min on first boot
  [V in bergamota, ios-flame, sailfish, HackiOS; our ADT lacked them]. Values in `config [adt.extra.chosen]`:
  `02:00:5e:77:ee:10/11/12`.
- ADT `--dram 840000000:C0000000` (3 GiB). The 12 GB phone has 9 GiB contiguous at 0x840000000 [V],
  so more RAM for XNU is possible later.
- Kernel in use: slop CI run 40007883255 (kernel 0124), artifact expires 2027-01-21.
- Boot-args: `config/negroni-ne2211.toml` `kernel_args`. Debug variant: `make boot-debug`
  (`negronifb_noconsole=0`: kernel log on the panel).

## 3. Hardware facts (SM8450 "Waipio", NE2211 12 GB)

Measured facts: [device-facts.md](device-facts.md) (CPUs, PAC/BTI, RAM banks, UFS, firmware build).

| Block | Fact | Source |
|---|---|---|
| Hypervisor | Gunyah at EL2; traps EL1 physical-timer access (CNTP_CTL_EL0) | slop NOTES:47 [V] |
| Display | Samsung AMOLED, 1080x2412, DSI command mode + DSC; splash `0xB8000000` size `0x2B00000`; the base DT has only simulator panels, the real panel is in the `dtbo` overlays | slop NOTES:63, `out/live.dts` [V] |
| Panel damage | this phone's panel has a cracked vertical stripe near x=600 (shim font scale 2) | slop NOTES:55 [V on NE2213] |
| Touch | Synaptics S3908 (TCM) at I2C 0x4B, vdd 2.8 V = L3C (RPMh), panel coords 5760x12864 | slop NOTES:536,562 |
| GPU | Adreno 730 (Mesa chip id 0x07030001, "FD730"); slop's 22-step bring-up ladder passed once | [gpu-plan.md](gpu-plan.md) |
| Reboot reason | PMK8350 (SPMI SID 0) SDAM 0x7100 + 0x48 = reg 0x7148, bits 1-7 (value << 1): bootloader = 2, recovery = 1; then PSCI SYSTEM_RESET. The imem restart_reason (0x146aa65c) does NOT work | Android DT `qcom,reboot-reason` [V], slop NOTES:55 |
| USB | kernel `negroniusb=2` = CDC-ECM device: phone 192.168.7.2, Mac 192.168.7.1, host MAC 02:00:5e:77:ee:01; console as UDP to :5140; iOS sees `ue0` | `scripts/debug/usblog.sh` [V] |
| Audio | AudioReach (GPR/q6apm, not APR); 2x TFA9874 on i2c13 (0x34/0x35, reset gpio50/51, active-high) on **TERT MI2S (I2S, 3.072 MHz BCLK), not TDM**; WCD9385 over SoundWire; ADSP remoteproc@03000000, PAS id 1, carveout **0x85700000 size 0x2800000** (node name says 85e00000), smp2p pid 2; ADSP firmware in `modem_a` | live DT, `out/audio-src/odm/etc/resourcemanager.xml:518` [V]; [audio-plan.md](audio-plan.md) |
| Wi-Fi | QCA6490 on PCIe0 (`qcom,cnss-qca6490`), PCI 17cb:1103 expected; MSI via GICv3 ITS; no driver in any port | `out/live.dts:13840`, [wifi-plan.md](wifi-plan.md) [V DT] |

## 4. iOS userland facts

- First boot timeline [V, 2026-10-24]: kernel 20:09, userland 20:10, Apple logo until UI at 20:26 (~16 min).
  Causes and fixes: [boot-speed.md](boot-speed.md).
- Live log capture `logs/usblog-20261024-195455.txt` (5300 lines) [V]:
  - 2457 `NEGRONI AKS:` lines: storms of `sel 17` from contextstored, SpringBoard, coreduetd, corespeechd;
    `securityd sel 10 ... -> 0xe00002c7` (wrap_key unsupported, so keychain writes fail).
  - `NEGRONI Sandbox:` denials: aggregated priv 1002, SpringBoard 1007, identityservicesd 12000, cloudd 1002.
  - backboardd: `matching IOAcceleratorES -> 0 found` repeated (QuartzCore polls 300 x 100 ms).
  - bluetoothd and fairplayd.H2 relaunch every ~10 s (no hardware); now dropped by `root-tweaks-extra.py`.
- Crash counts in the same log [V]: activityawardsd 14 (sig 6 at launch, every 10 s: now dropped),
  mediaserverd 2, assetsd 2, Music 2 (`Library not loaded: @rpath/MusicApplication.framework`: the dyld
  @rpath policy, fixed by AMFI policy 0221), Shortcuts 1, PosterBoard 1.
- Owner report 2026-10-24 [V]: turning on **Bold Text** hung iOS; after the restart it loops with repeated
  crashes and ReportCrash output on the screen (debug image). No USB log of it: the log ends at 21:43:59,
  before the hang. The next capture found the cause (ROOT CAUSE line below). Pref:
  `com.apple.Accessibility` / `EnhancedTextLegibilityEnabled` in /var/mobile/Library/Preferences [V, section 14].
- SpringBoard in `logs/usblog-20261024-195455.txt` [V]: **no SpringBoard crash** in 19:54-21:43 (the hang
  came later and was not logged: the old usblog.sh lost the link at the first phone reboot; fixed
  2026-10-24). Its 1724 syslog lines are warnings only: 310 "trying to set state of nil layer",
  CATransformLayer property warnings, "Unbalanced calls to begin/end appearance transitions",
  UICollectionViewFlowLayout size warnings. ReportCrash ran twice: 21:31:47 (ReportMemoryException
  after a burst of daemon launches) and 21:39:41 (activityawardsd abort).
- **Clock is 1969-12-31** in userland timestamps [V: `1969-12-31 17:22:49 SpringBoard[26:245]`]: no RTC /
  calendar source. Expect TLS, certificates, keychain item dates and anything time-based to misbehave
  [I]. 0200 only removes the 30 s wait; a real calendar source (PMK8350 RTC, or time from the host
  over USB) is still needed.
- `hfs_clonefile: cluster_write failed - 34` (ERANGE) 5 times [V] (21:31:42, 21:39:41, 21:40:11, ...):
  clonefile on the HFS+ root fails; writes that rely on clonefile (atomic plist/database copies) can
  fail [I]. Reference fix: ios-flame xnu/patches/0100 (clonefile fallback).
- Thread-count high watermark (32) warnings: appleaccountd, lsd, contextstored, cfprefsd, suggestd,
  healthd, siriinferenced [V] (diagnostic only).
- **Bold Text crash loop: ROOT CAUSE [V, logs/usblog-20261024-235438.txt, 2026-10-25 00:00, symbolicated
  with scripts/debug/symbolicate.sh]**: SpringBoard SIGSEGV every ~7 s, pc 0 (NULL call),
  `CI::GLContext::init() + 204` <- `+[CIContext(Internal) internalContextWithEAGLContext:options:]` <-
  `+[CIContext contextWithOptions:]` <- `+[CUIShapeEffectStack sharedCIContext]` <-
  `-[CUICatalog imageByStylingImage:stylePresetName:...]` <- `-[UIImage _imageWithStylePresets:...]`.
  Bold Text makes UIKit style glyph images through CoreUI -> CoreImage -> its OpenGL ES (EAGL) backend,
  and with no GL driver a GL function pointer is NULL. Same unslid lr 0x194b3858c as slop's 2026-10-22
  SpringBoard loop (slop NOTES:569), so any CoreImage-GPU path in any UIKit process can crash.
  Fix work: CoreImage software fallback (agent, userland/cifix/); the real fix is the GL driver.
- PosterBoard SIGTRAP loop [V same log]: `-[PBFPosterExtensionDataStore _stateLock_setupSwitcherConfigurationForFirstTime] + 2040`
  (assertion) <- `_stateLock_updateExtensions:...` <- `prewarmWithCompletion:` <- `-[PRSServer prewarmWithCompletion:]`;
  matches slop NOTES:800 (poster-provider extensions not registered). 12 SpringBoard + 4 PosterBoard
  crashes in the first minute of the boot.
- Crash symbols: `scripts/debug/symbolicate.sh LOG [PROC] [N]` (ipsw + the root image's shared cache,
  attached read-only). Unslid = address - logged slide.
- Owner report [V]: "slide to power off" does nothing (kernel halt path: patch 0211 in progress);
  the power button takes ~10 s to turn the screen off (CPU rendering; brightness/sleep agent).
- Root tweaks (`scripts/ios16/root-tweaks-extra.py`, on top of slop's `sweet-root-tweaks.py`): drop
  fairplayd.H2, vmd, ReportCrash, spindump, tailspind, aggregated(.addaily), bluetoothd, activityawardsd; ExtensionKit
  `enforce_xpc_cache_code_signing` off; `DMLastMigrationResults`; `FBLaunchWatchdogScale 20`;
  `--migration skip|once`.
- Debug text over the GUI came from `negronifb_noconsole=0` + `-enable_kprintf_spam` in the debug image.
  The normal image uses `negronifb_noconsole=1` and keeps the log on USB only.
- **PowerMenu.app (2026-10-25, details: userland/rebootapp/README.md):** owner's UIKit app, 3 buttons, setuid
  helper `/usr/local/libexec/powermenu-helper` (root:mobile 4750, caller = uid 0 or parent
  `/Applications/PowerMenu.app/PowerMenu`). Hook `scripts/ios16/root-add-powermenu.sh` (POWERMENU=1 default when
  built); running phone: `scripts/net/phone-add-powermenu.sh` (not run). Nothing tested on the phone yet.
  - [V] `userland/rebootapp/build.sh` reproduces the owner's hand-built PowerMenu.app byte for byte (flags: no -O,
    `-fobjc-arc -framework UIKit -framework Foundation -framework QuartzCore`; signed with a copy of
    userland/ssh/entitlements.plist). Two runs give the same bytes.
  - [V] ld (ld-27037.1, Xcode 27.1) puts the output path into LC_UUID: the same object linked to two paths gives two
    UUIDs. Link with a relative `-o` in a fixed folder for reproducible binaries.
  - [V] Apps run as mobile; `reboot(2)` needs euid 0 (`suser()`, kern_xxx.c); no negroni MAC hook checks reboot.
    The app's own `reboot()` call could not work.
  - [V] The negroni kernel has `CONFIG_SETUID` (buildtree DEVELOPMENT_ARM64_NEGRONI Makefile) and sets no MNT_NOSUID on
    the root; the iOS root has no /private/etc/fstab. [I] So setuid binaries on the root work; check `mount` on the phone.
  - [V] No kernel has `kern.negroni_reboot_mode`. The 0210 `bootloader` command is only for UDP frames on ue0 from
    192.168.7.1; 0211 restart always writes reason 0. [I] A process on the phone cannot select fastboot: needs a
    kernel sysctl (small patch). The helper exits 3 for "bootloader" and does not reboot.
  - [V] 20H392 installd: an app with the bundle id of a system app needs `container-required`, or `no-container` +
    `platform-application` (installd string). PowerMenu has the second pair.
  - [V] A new root has no LaunchServices `.csstore` and no `/var/mobile/Library/MobileInstallation/LastBuildInfo.plist`
    (checked on a built root). [I] The first boot builds the app database from /Applications, so no staged-app list
    or installd step is needed (InstalledContentLibrary knows systemAppsDirectory and private/var/staged_system_apps).
  - [V] Stock apps have `UIRequiredDeviceCapabilities` = arm64 (Preferences, MobileSafari); Camera also has SBAppTags
    `still-camera`. PowerMenu's Info.plist asks only arm64.
  - [I] On a running phone `LSApplicationWorkspace registerApplicationDictionary:` (ApplicationType System) registers
    an app in /Applications (bergamota NOTES 2026-10-20, Poco F1, sweetuicache; its iOS version then not checked); our tool: pmregister.
  - **XNUtils rename (2026-10-27).** Owner report [V]: the phone shows the old PowerMenu app, not XNUtils. Cause [V]:
    the owner renamed the sources to XNUtils (`dev.iosplus10.xnutils`, 2026-10-25 19:32), but `build.sh` still made
    `out/powermenu/PowerMenu.app` and the root hook installed `/Applications/PowerMenu.app` (logs/root-update.log).
    Fix: `build.sh` builds `out/powermenu/XNUtils.app` (name from CFBundleExecutable, adds `-framework Metal`, deletes
    the old PowerMenu.app); `root-add-powermenu.sh` installs `/Applications/XNUtils.app` and deletes
    `/Applications/PowerMenu.app`; root-finish.sh tests for `out/powermenu/XNUtils.app`; `phone-add-powermenu.sh`
    unregisters + deletes PowerMenu.app and registers XNUtils.app; the helper's caller path is
    `/Applications/XNUtils.app/XNUtils`. Hook names (`POWERMENU`, `powermenu`) and `out/powermenu` stay.
    - [V] `build.sh` reproduces the owner's hand build byte for byte: unsigned `XNUtils` sha256 afaaebfa…1369,
      `XNUtils.app/XNUtils` (94288 B) sha256 246c5325…8283, same Info.plist and CodeResources.
    - [V] The owner's first XNUtils main.m did not use the helper: Restart/Shut Down called `reboot()` as mobile ([I] no
      effect, `suser()`), Bootloader started `/usr/local/bin/usbreboot -f bootloader` as mobile (usbreboot.c:51 refuses
      non-root). Fixed 2026-10-27 (owner: "make sure xnu utils has proper reboot power off"): main.m spawns
      `/usr/local/libexec/powermenu-helper restart|shutdown|bootloader` (`run_helper()`, pipe for the output, alert on
      exit != 0; exit 3 = no 0213 sysctl). [V by code] no `reboot()` / `usbreboot` left in main.m. Not run on the phone.
    - **Hot toggles (2026-10-27, owner: "a hot toggle to enable and disable metal and other things").** Section
      "GPU SWITCHES" in XNUtils: Metal all / probes / off (segmented), GL for backboardd, GL for apps, glFinish
      (switches), Clear Metal strikes, Restart backboardd (apply). New helper verbs `metal all|probes|off`, `gl on|off`,
      `glapps on|off`, `glfinish on|off`, `strikes-clear`, `restart-ui`, `status` (KEY=VALUE lines the app parses at
      launch and after each change). Same files/owners/modes as `phone-metal.sh` / `phone-gl.sh`; atomic writes
      (tmp + rename in the same dir, root:wheel 644; dirs 755, strikes/cache 1777); constant paths only; strict verbs.
      The app shows the file state only (the UI says so): the plugins read the files at process start.
      [V] `gl off` on a `*` gate: the old `phone-gl.sh off` (grep -vw backboardd) left `*` and so left GL on; the helper
      and the updated `phone-gl.sh off` write the `-backboardd` never line, `on` removes it (tested locally with a
      scratch file). [V] build.sh exit 0, codesign --verify ok, no weak imports. Install on the live phone:
      `scripts/net/phone-add-powermenu.sh`. `root-add-powermenu.sh` now also installs `/usr/local/bin/pmregister`
      (review FIX a). Not verified: the app on the phone (helper caller check as mobile, `restart-ui` kill, layout).
    - [I] A root that booted before keeps PowerMenu.app in its LaunchServices database: run
      `scripts/net/phone-add-powermenu.sh --register-only` (or the full install) on the phone.

## 5. Kernel build facts

- Source tree: `scripts/kernel/prepare-src.sh` -> `out/kernel/xnu`, branch `base` = xnu-8796.141.3 +
  darwin-xnu-build (DXB_SHA 6639065) + slop 125 patches + 3 scripts; 129 applied, 4 dxb patches skipped
  (TrustCache, iobuffermemd_monterey, skywalk_sonoma, syntax_checker_sonoma) [V `out/kernel/patches.txt`].
- Our changes: `patches/xnu/0200+`, made in a worktree from `base`, exported with
  `git -C out/kernel/wt-X diff base -- <files>`, applied in name order after the port's patches.
- **Needs Xcode 15.** Xcode 16+ `iig` emits `IORPC.kernelContent`, which xnu-8796 does not have
  (slop `negroni-ios.yml:37`) [V]. Local Xcode is 27.1 (too new; its clang is also much newer [I: more errors]).
  bergamota's iOS 18 kernel (xnu-11215) builds with Xcode 16.2 on `macos-15`.
- CI template: `ci/negroni-xnu/` + `scripts/kernel/ci-build.sh` (`CI_REPO`, default
  `akshaynexus/negroni-xnu`). Creating a public repo was blocked by the agent permission system: the owner decides.
- `out/kernel/buildtree`: slop CI build tree (generated headers, `build/xnu.obj`) for single-file compile checks.
- The editor's clang diagnostics on kernel files ("file not found") are noise: the IDE has no kernel include paths.

## 6. UEFI (Mu) facts

- Build: EDK2 `stuart`, CLANGPDB. Container: native arm64 on Apple silicon (Mu-Basetools have
  Linux-ARM-64 builds). Native macOS build also works (`make mu-build-macos`).
- Mono crashes under Rosetta: `MONO_ENV_OPTIONS=--interpreter` (only for amd64 on a Mac).
- `build_uefi.py` skips stuart update when `Build/` exists: `build.sh` runs `--setup` / `--update` explicitly.
- NuGet `mu_nasm` failed: `fetch-extdeps.sh` fetches deps with curl.
- macOS: `build` must be on PATH (BaseTools `BinWrappers/PosixLike`) and `PYTHON_COMMAND` set.
- The NE2211 `uefi.img` (`BOOT.MXF.2.0-00925.2-WAIPIO-1.81484.5`) matches all 8 negroni DXE patch sites [V].

## 7. Flash facts

- fastbootd `max-download-size` = 256 MiB: `userdata` goes in 45 pieces (still one command); do not pass `-S`
  ("Invalid size" with 512M) [V].
- Flash `userdata` from fastbootd first, while `vendor_boot`/`dtbo` are still stock (fastbootd needs them);
  the ABL sparse flash loses writes past ~8 GiB (port notes, NE2213).
- Sparse image: `op10tool img2simg` (holes = DONT_CARE, zero data = FILL). The android-sparse crate's encoder is not safe for this.
- One USB cable worked for adb but not for fastboot: use the cable that works in fastboot mode [V].
- Re-flash from iOS: fastbootd needs the stock vendor_boot_a + dtbo_a (iOS replaces them):
  `scripts/flash/all.sh` step 0 (`ios16.sh recovery`) restores both in the bootloader first [I: recovery
  partition is separate on NE2211, so boot_a does not matter].
- Fastboot: Volume Up + Volume Down + Power. In Mu: Volume Up = front page, Volume Down = boot menu.

## 8. Host and tooling gotchas (error -> fix)

| Error | Fix |
|---|---|
| zsh word splitting broke `set --` loops | use bash scripts |
| parallel `git submodule add` raced on `index.lock` | add submodules one at a time |
| `pkg_resources` missing in the uv venv | `setuptools<81` |
| Ubuntu `mkbootimg` has no `gki` module | AOSP mkbootimg clone (`native-tools.sh`) |
| rsync version check died with SIGPIPE under pipefail | read the output first, then match |
| bash 3.2 (macOS) empty arrays under `set -u` | `${arr[@]+"${arr[@]}"}` |
| `diskutil enableOwnership` failed | test ownership with a file instead |
| `/tmp` vs `/private/tmp` mount match | `cd "$(mktemp -d)" && pwd -P` |
| rm safety check | literal paths or `"${VAR:?}"` guards |
| HDR (BT.2020 PQ) screenshots look washed out on SDR | `sips --matchTo "/System/Library/ColorSync/Profiles/sRGB Profile.icc"` (ffmpeg here has no zscale) |
| downloading/running prebuilt UEFIExtract was blocked | own unpacker: `op10tool uefi-unpack` |

- `VAR=x scripts/bg.sh NAME cmd` does not pass VAR into the job once a tmux server already runs (the
  server keeps its own environment): the ios16-gpu12 build wrote into `out/ios16` with the default args
  (2026-10-25). Write `scripts/bg.sh NAME env VAR=x cmd` instead. [V]

## 9. Where things are (outside git)

- OnePlus 10 Pro Linux sources (reference only, git-ignored, scripts/setup/fetch-oneplus-sources.sh, 2026-10-26):
  `out/src/op-kernel` (OnePlusOSS android_kernel_oneplus_sm8450 e9da592, sparse: pci/mhi/cnss2, qmi, smp2p/rpmsg/qrtr,
  power/supply (SMB5 charger), power/reset (msm-poweroff), thermal/qcom (tsens), cpufreq/qcom-cpufreq-hw, spmi,
  pmic-pon-log, qpnp-power-on, usb/dwc3, gpu/msm gen7 GMU/HFI/hwsched/rpmh, dt-bindings) and `out/src/op-modules`
  (android_kernel_modules_and_devicetree_oneplus_sm8450: vendor/oplus/kernel/charger = oplus_chg, dfr,
  display-drivers, the devicetree). The live DT dump is `out/live.dts`.

- The 20H392 dyld shared cache (for scripts/metal/check-imports.py and `ipsw dyld` symbolication):
  `out/dsc/cache/dyld_shared_cache_arm64*` (3.5 GB copy, 2026-10-26). `~/op10-apple` holds only
  `ios16-root.simg` (the flashed root, fallback); the raw `ios16-root.img` and the `20H392/` IPSW extraction
  were deleted for disk space; `simg2img ios16-root.simg ios16-root.img` rebuilds the raw image when a root
  update is needed (then mount read-only for /private/tmp/iosroot-ro).

- `~/op10-backup/`: stock OTA `NE2211_16.0.3.530_EX01_full.zip`, `images/`, `partitions/` (121 partitions + GPT),
  `magisk/`, `device/` (dumps, `live.dtb`), `getvar-all.txt`, `RESTORE.md`.
- `~/op10-apple/`: `20H392/` DMGs, `d22ap.adt`, `ios16-root.img`, `ios16-root.simg`.
- `out/`: `mu/`, `ios16/`, `ios16-debug/`, `kernel/` (xnu, dxb, worktrees, buildtree), `live.dts`.
- `logs/NAME.log` + `.exit`: every tmux job (`scripts/bg.sh`); `logs/usblog-*.txt`: live kernel logs.

## 10. Owner decisions and preferences

- Stay on OxygenOS `NE2211_16.0.3.530(EX01)`; no updates.
- iOS root goes into `userdata`; Android user data may be erased. Never write slot B, the GPT or unique partitions.
- Ask before each partition write. The owner approves flashes.
- Long jobs in tmux (`scripts/bg.sh`); use all cores; libraries over hand-written code; Rust for binary/parallel
  tools, Python/shell for glue; macOS + Linux docs for every script; notify with `scripts/lib/notify.sh`.

## 11. Open questions

- Where kernels build (local Xcode 15.4 vs CI repo).
- Does Xcode 15.4's toolchain run on macOS 27 (only the command-line tools are needed)? [I: probably]
- Wi-Fi: write a QCA6490 driver, or use USB networking only?
- iOS 26: does QuartzCore render without Metal? ([research-report.md](research-report.md))

## 12. Wi-Fi (2026-10-24, reviewed 2026-10-25: docs/reviews/codex-2026-10-25.md)

- [V] `bsd/dev/negroni_wifi.c` (slop 0106/0109/0120/0122) has survey steps 1-9: 1-4 read, 5-8 write (GCC, five RPMh votes, WLAN_EN, PHY, root port, iATU, PERST, link), 9 reads bus 1 ID/class/BAR0/BAR1. Steps 5-9 never ran on a phone (no `NEGRONI WIFI` line in `logs/usblog-*.txt`; slop NOTES:805).
- [V] Patch 0260 (`out/kernel/wt-wifi`, uncommitted on top of `a559154`): step 10 reads endpoint command/status, BAR0 and the MSI/MSI-X capability list, no writes; `negroniwlan=1` (default 0) = `negroniwifi=10`; the probe menu still wins. Not run on hardware.
- [V] MSI on PCIe0 goes through the GICv3 ITS 0x17140000 (`msi-map` RID 0x100 -> DeviceID 0x5981); the SPI MSI node `qcom,pcie0_msi@0x17110040` is disabled (`out/live.dts:1327,20793,20866-20873`). Our XNU has no ITS code (`git grep GITS_`).
- [V] ath11k requests only MSI (`PCI_IRQ_MSI`), no INTx (`ath11k/pci.c` `ath11k_pci_alloc_msi`).
- [V] Endpoint DMA goes through the apps SMMU: `iommu-map` RID 0x100 -> SID 0x1c01 (`out/live.dts:20818`).
- [V] DT has a sixth WLAN supply `wlan-ant-switch` = pmr735a_l7 2.8 V; step 6 does not vote it (`out/live.dts:13870-13871`).
- [V] Linux tells WCN6855 hw2.0 / hw2.1 / QCA2066 / QCA6698AQ apart only through TCSR_SOC_HW_VERSION / SUB_VER via BAR0 (`ath11k/pci.c` `ath11k_pci_probe`); our chip's revision is unknown.
- [V] Stock modem `image/` has amss.bin + amss20.bin (both `WLAN.HSP.2.0-01229`), m3.bin, regdb.bin, 170 `bdwlan.*`, 24 `bdwlang.*` (ELF board files), no wpss, no board-2.bin (`out/firmware/wlan/LISTING.txt`).
- [V] cnss2 loads amss20.bin for MHI major version 2, else amss.bin; board file `bdwlan.e%02x` by QMI board id, `bdwlang.*` when chip_id & 0x10 (cnss2 `pci.c` / `qmi.c`, Xiaomi marble kernel).
- [V] ath11k accepts an ELF board file over QMI (BDF type ELF, `ath11k_qmi_load_bdf_qmi`), so no board-2.bin is needed.
- [V] ath11k QMI order: ind_register + host_cap -> REQUEST_MEM -> respond_mem -> FW_MEM_READY -> target_cap -> BDF/regdb -> m3_info -> FW_READY -> wlan_cfg + mode (`ath11k/qmi.c`). "msa_ready" and "cal_report" are ath10k terms, not ath11k.
- [V] `scripts/wifi/extract-fw.sh` (reworked 2026-10-25) extracts 198 files into `out/firmware/wlan/` with LISTING.txt + SHA256SUMS, modem.img sha256 `bcd07e89...` (`logs/wifi-fw.log`). The first version missed amss20.bin and bdwlang.*, and its run passed `MODEM_IMG=` as an argument, which it ignored.
- [I] Effort for WPA2 Wi-Fi: about 3-5 months of focused work (`docs/wifi-plan.md`).

## 13. Camera (2026-10-24, reviewed 2026-10-25; details: docs/camera-plan.md)

- [V] Slot map (DT `cell-index` = CAMX `cameraId`; `out/camera/dt-table.txt`, `out/camera/modules.txt`
  from `scripts/camera/inventory.sh`): 0 rear main IMX789 (CCI0 M0, 0x34, CSIPHY1, C-PHY 3 trios,
  AF AK7377, OIS LC898128); 1 ultra-wide S5KJN1 (CCI0 M1, 0x20, CSIPHY2, 4-lane D-PHY, fixed focus);
  2 front IMX615 (CCI1 M1, 0x20, CSIPHY5, 4-lane D-PHY); 3 tele OV08A10 (CCI1 M0, 0x6c, CSIPHY0,
  2-lane D-PHY, AF AK7377, OIS LC898124 on CCI0 M1). Addresses 8-bit. MCLK 19.2 MHz.
- [V] Rails, GPIOs, chip IDs and power order per slot: table in docs/camera-plan.md. VIO of all
  sensors is pm8350c_l2 1.8 V; the other rails are PM8010 (i/j) LDOs.
- [V] `camera_region@9f500000` (0x800000) is the `memory-region` of the ICP (`qcom,lx7`, `fw_name`
  CAMERA_ICP). `qcom,vmid-cp-camera-preview-ro` (`out/live.dts:13481`) is in the generic
  `qcom,secure-buffer` node, not tied to that region.
- [V] CAMERA_ICP (.mdt/.bNN, .mbn, .elf) is in /vendor/firmware, signed (attestation chain); the
  OnePlus camera-kernel loads it with `qcom_mdt_load` + `qcom_scm_pas_auth_and_reset(33)`. It serves
  IPE/BPS only (`nrt-device`); raw RDI capture should not need it [I].
- [V] Mainline Linux (5b0764a) has no sm8450 CAMSS binding (sm8550/sm8650 exist). Exact driver:
  OnePlus camera-kernel in `out/src/op-modules`.
- [V] iOS 16 root: `applecamerad` (starts on IOResources property `applecamerad`, loads the ISP
  firmware), `H10ISP.mediacapture` + `H10ISPServices` in the shared cache, CMCapture `D22/` plists;
  no `cameracaptured`. ADT: `isp,t8015`, `AppleH10CamIn` (`out/camera/ios-stack.txt`).
- [I] Our XNU has no Apple kexts: stock capture needs an AppleH10CamIn-like service (reverse
  engineering). Own app on a device node is the first realistic target.
- [I] Next: stage 1 chip-ID read on slot 1 or 2 (needs new camcc + CCI code; RPMh votes exist).
- DT node name trap: the front sensor node is `com,cam-sensor2`; match on `compatible`.
- 2026-10-26 (camera agent; patches 0310, 0311; build-only, phone battery flat). Details:
  `patches/xnu/README-camera.md`, levels: `docs/camera-plan.md` "Staged plan".
  - [V] All camcc sources needed for CCI and MCLK have a 19.2 MHz TCXO entry (camcc-waipio.c:955, 988, 1257, 1587,
    1926): no camcc PLL code. The DT CCI rate is 37.5 MHz (PLL0); at 19.2 MHz use the Linux 19.2 MHz timing table
    (i2c-qcom-cci.c:255-265; Linux maps qcom,sm8450-cci to cci_v2_data, :871).
  - [V] The camera rails are RPMh VRM LDOs, not direct SPMI: slot 0 = ldoi3 2800 mV (VANA), ldoi1 1104 mV HPM (VDIG),
    ldoc2 1800 mV HPM (VIO), ldoi7 2800 mV (VAF), ldoi5 1800 mV HPM (CUSTOM1) (out/live.dts:22220-22230 and the
    ldo nodes 11083-11778). ldoi3/ldoi7 have no qcom,supported-modes (no mode command). The old `negroni_rpmh` API
    had no "off": 0311 adds RH_MODE_OFF (one command, enable = 0) and `negroni_rpmh_cam_rail` (whitelist).
  - [V] The kernel has no IMX789 power table; CAMX sends the module-file order (modules.txt:49-50). Android enables
    the CCI pins after the sensor power-up (camera_io_init); 0311 does the same.
  - [V] Titan top GDSC 0xadf31dc = camcc + 0x131dc, parent MMCX voter (out/live.dts:1015-1024). [I] No MMCX vote from
    us: it would replace the UEFI display vote of the same DRV.
  - [V] Mainline Linux has CSID 680 / VFE 680 code (camss-csid-680.c, camss-vfe-680.c, used by x1e80100,
    camss.c:4309-4505); the SM8450 DT has `qcom,csid680` / `qcom,vfe680`: reference for level 3.
  - [V] Kernel out/kernel/local-20261026-082431 (sha256 fe5d2ef5253470fb...; 0310+0311 applied, 64 patches/xnu; skipped 4 usual dxb + 0274
    charger-glink, not camera); image out/ios16-cam (config args + `negronicam=2 negronipanic=30 negronipanicreason=2`; boot_a
    280e12237a9084b6...). Not flashed. Proof line to look for: `NEGRONI CAM: chip id 0x0789 (expected 0x0789, ...): MATCH`.

- 2026-10-26 evening (camera agent 3; patches 0312-0316; build only). Details: `patches/xnu/README-camera.md` "Levels 3-6",
  `docs/camera-plan.md` (levels 3-6 + the iOS capture service design).
  - [V] Votes now come first (0312, `negronicam_votes=1` default, every level): RPMh `mmcx.lvl` NOM (titan GDSC parent
    pm8350c_s2_mmcx_voter_level, live.dts:10766) and BCM CN0/MM1 (x = 0, y = 1) + MM0/SH0/MC0 for `cam_ahb` and `cam_hf_0`
    (live.dts:22712-22748; BCM membership from Linux sm8450.c). negroni_rpmh.c has a BCM cmd-db lookup (slave type 5,
    aux {u32 unit, u16 width}) and `negroni_rpmh_cam_bcm` (whitelist, bcm-voter.c math). [I] Votes are not dropped.
  - [V] IMX789 has a full self-contained register table in the OnePlus kernel: the FTM table
    `cam_sensor_settings.h:6017-6141` (116 writes, 4000x3008 RAW10 binned, 3 trios, ends with stream on), used by
    `cam_ftm_power_up` after the plain power-up. The init table `cam_sensor_initsettings.h:1` (184 writes) is for the
    CAMX path. The module file has the per-mode tables too (`regSetting`, 40-byte entries; layout not decoded).
  - [V] Module file `resolutionData` words [10]/[11]/[14] = line length / frame length / output pixel clock
    (mode 1: 18880, 3144, 750.45 MHz). [I] module "settle" values are settle counts.
  - [V] CSIPHY rails pm8350_l5/l6 are the UFS PHY rails (live.dts:10429-10430): never vote them from the camera.
  - [V] `qcom,cam_smmu` has no `expanded_memory`: IFE WM addresses are 32-bit (buffers below 4 GiB).
  - [V] camera_region 0x9f500000 lies inside the UEFI "PIL Reserved" map entry (Mu negroniPkg MemoryMapLib.c:14).
  - [V] CAMERA_ICP.mdt: 21 phdrs, seg 0 headers 0x2d4 + seg 20 hash 0x10b8 packed = the 5004-byte mdt; load span
    0..0x700000 relocatable. Empty .bNN files exist (b10-b16, b19): mkadsparea.py now skips empty files.
  - [V] iOS: AppleH10CamInUserClient has 94 selectors (table 0xfffffff006f3c768 in the 20H392 iPhone10,3 kernelcache);
    H10ISP.mediacapture opens type 42; sel 10 = ISP firmware command packets (573 call sites); `FirmwareLoaded`
    property + IOResources `applecamerad` start the stack. `scripts/camera/ios-re.sh` reproduces it into out/camera/ios-re.
  - [V] Build: full kernel out/kernel/local-20261026-173833/kernel.development.negroni, sha256 4e4d155111db6c7329e1b542111c5bc48f9c42afcbeb278eb0ceb378d79a158b (after the review fixes: HFI_Q_WORDS 239, BCM enable x = 0 / y = 1, MXC NOM; all patches applied incl. 0310-0316; skipped only the 4 usual dxb patches). No image (owner rule: the main session builds one combined image). compile-one of negroni_cam.c at each stage 0312-0316 and of negroni_rpmh.c: OK. Not run on the phone.

## 14. Bold Text (2026-10-24, reviewed 2026-10-25)

- [V] Root cause: SpringBoard NULL call in `CI::GLContext::init` via `+[CUIShapeEffectStack sharedCIContext]` (section 4 and "CoreImage/PosterBoard crash"); details: [boldtext-crash.md](boldtext-crash.md).
- [V] Pref: `com.apple.Accessibility` / `EnhancedTextLegibilityEnabled` (only such string in the 20H392 cache, in libAccessibility.dylib); `_AXSEnhanceTextLegibilityEnabledGlobal` reads it with `_AXSGetPreferenceValue` and tests == 1 (`ipsw dyld disass --vaddr 0x191998934`).
- [V] The switch is in `AccessibilitySettings.bundle` (`setBoldTextEnabled:specifier:`) and in DisplayAndBrightnessSettings (shared cache strings).
- [V] libAccessibility has the strings `com.apple.accessibility.text.legibility.status` and `com.apple.accessibility.cache.enhance.text.legibility` [I: Darwin notify names].
- [V] `scripts/ios16/root-tweaks-boldtext.py` writes the key false (binary plist, other keys kept, 501:501, 0600); idempotent; its output equals the file in the current built root (sha256 `71639153...`) (review test on a scratch copy, 2026-10-25).
- [I] Recovery without a re-flash: push the plist over SSH and reboot (`docs/boldtext-crash.md`); not tested. The phone has no `killall`.

## 15. Display (from the brightness agent, 2026-10-24)

- Reference for 120 Hz smoothness [V: external/ios-s9 HEAD 7b72f7c, a separate clone of syncmodz/ios-s9
  (Galaxy S9), not a submodule]: zero-copy scanout (display engine VIG0/VIG1 + QSEED3 fetch backboardd's
  framebuffers directly), SwapWait that waits for the shown frame, CPU copy of dirty rows only. Same idea as
  bergamota xnu/patches-11215/0211 (fb-direct-scanout) and 0127 (fb-zero-copy). Candidate for a display
  patch (0252+) after 120 Hz vsync is tested [I: register layout differs on SM8450 DPU].

- Panel: Samsung AMB670YF08 (S6E3HC3 IC), AMOLED, DSI command mode, DSC 1.2, DSI0 only; UEFI sets
  1080x2412 @120 Hz with DSIEnableAutoRefresh=True: the MDP scans the RAM framebuffer on each TE, no
  kernel kick [V: out/live.dts, Mu panel XML Panel_samsung_amb670yf08_1440_3216_dsc_cmd.xml].
- Brightness: DCS 0x51 + 2-byte DBV (high byte first), normal 1..0x7ff, HBM 0x800..0xfff; LP mode; UEFI
  init already sends 0x53=0x28 [V]. DSI0 0x0AE94000 (size 0x400, dsi-ctrl-hw-v2.6), MDSS 0x0AE00000,
  MDP INTF 0x0AE36000 [V DT].
- CoreBrightness (20H392) finds `AppleARMBacklight` with `backlight-control=true`; without
  `new-backlight-architecture` it uses the legacy path (`brightness`, `FadePeriod`, `backlight-level`
  in IODisplayParameters) [V disassembly]. Details: patches/xnu/README-brightness.md.
- The ~10 s power-button-to-dark delay is iOS sending RequestPowerChange late; 0251 added a kernel
  fast-off on a short power-key press (< 700 ms). Removed by 0258 (2026-10-26, owner: the screen went
  black at once instead of the normal lock); see the end of this section.
- Vsync 120 Hz (2026-10-25): slop patches 0046/0056/0061 set `NEGRONI_FB_VSYNC_US` to 8333 (was
  16667 = 60 Hz) and derive `fFlushTicks` from it, so `negronifb_hz` keeps its meaning. The panel
  scans at 120 Hz, the vsync timer was the 60 Hz limit [V: `scripts/kernel/prepare-src.sh` -> 129
  applied, 4 usual skips].
- CoreAnimation's base quantum (2026-10-25) [V disassembly, QuartzCore 20H392, unslid]:
  `AppleCLCDDisplay::heartbeat_rate` (0x1882dc324) takes, in this order: env `CA_HEARTBEAT_RATE`
  (1/atof) -> `displayRefreshStepMachTime` (mach time, converted to seconds) -> `displayMinRefreshInterval`
  (integer, scale 2^-32, units unclear) -> the constant 1/60. Both fields are in a CFDictionary registry
  property `IOMFBDisplayRefresh` of the IOMobileFramebuffer service (IOMobileFramebufferCopyProperty /
  IORegistryEntryCreateCFProperty, no selector). Our driver had no such property, so CA ran on 1/60 s quanta.
  The vsync notification (type 5) carries 3 u64 values from 32-bit halves {count, host timestamp, interval};
  `IOMFBServer::vsync_callback` (0x1882ba1ec) uses host_ts + interval, and we sent interval 0.
  Experiment order: (1) env lever on the current kernel: `scripts/metal/phone-heartbeat.sh on` (edits the
  backboardd job in /System/Library/xpc/launchd.plist, backup /var/db/negronimetal/launchd.plist.orig, reboot);
  (2) kernel with patch 0253 (`negronifb_carefresh`, default 1: the property with step = 8333 us in mach
  ticks and min interval 1, and the interval in the vsync notification). Next root images get
  CA_HEARTBEAT_RATE=120 for backboardd from scripts/ios16/root-tweaks-extra.py (`CA_HEARTBEAT`, empty = off).
  [I] Not verified: the units of displayMinRefreshInterval; whether CA reads the property only once
  (before the driver sets it) and caches the heartbeat. launchd's env filter flags only `LD_LIBRARY_PATH`
  and `DYLD_*` ([V] "CoreImage/PosterBoard crash" section below), so CA_HEARTBEAT_RATE should pass [I].
  Kernel image not rebuilt yet, phone not booted with it [I].
- 120 Hz measurement (2026-10-25, patch 0252, README-gpu-kernel.md section 12): boot-arg `negronifb_stats`
  (default 1, `=0` off) logs once a second `NEGRONI FB STAT: swaps/s N presents/s N (cpu N gpu N zc N)
  copy avg/max us N/N late ticks N swapwait calls N waited us avg/max N/N timeouts N`. [V] The vsync timer
  re-arms `setTimeoutUS(8333)` at the END of `vsyncFired`, so the real period is 8333 us + the handler time
  (the CPU copy of ~10.4 MB): a slow copy shows as late ticks (> 1.5 x 8333 us). [I] Before 0252 there was
  no per-second rate; the old counters log every 1000 swaps/frames only. Not yet booted.
- Display stalls behind the GPU (2026-10-25, patch 0254, README-gpu-kernel.md section 12 "0254").
  [V phone, kernel local-20261025-170531] CPU-only boot: `present()` 2.5-3.7 ms avg, 6 ms max; swaps/s up to 81,
  presents/s 37, late ticks 11-13/s. After backboardd (Metal) crashed with GPU work pending (`RedwoodGPU: the
  GPU is not done with a buffer ...` 15+ s): every `present()` 51 ms (50 ms `NegroniGPUFenceWait` in the vsync
  handler + copy), sometimes 650-1073 ms, UI ~1 fps. SwapWait returned at once in copy modes, so CA ran free.
  [V telemetry] backboardd on Metal at 220 MHz: commit-to-callback 89 ms .. 14 s, one buffer done every ~60 ms,
  RBBM busy: the GPU is slow, not dead. [V QuartzCore 20H392 disassembly: can_update_ 0x1882be944,
  swap_wait_timeout 0x18853c088] SwapWait 0 releases CA's surface; non-zero keeps it, CA retries (usleep(100),
  up to 1 ms) or skips to the next heartbeat. CA keeps 3 surfaces; only SwapWait gates reuse.
  Design (0254) [I until booted]: fixed-deadline vsync (`wakeAtTime`, deadline += 8333 us, skipped deadlines =
  late ticks); the tick never waits for a render (frame stays pending until its newest fence is done,
  `gpu-wait skips`); the first waiting frame is kept as the "older" one so a slow GPU still shows frames;
  give-up only after 500 ms AND a RedwoodGPU client close, or after 2 s without any fence progress
  (`gave up on fence N of surface M`, `gave-up` count); SwapWait answers 0 only when that id (or a later one)
  is on screen, else kIOReturnBusy at once, in all modes. No present thread (README has what it would need).
  [V phone, first 0254 image, Metal backboardd 2 min] the tick works (gpu-wait skips 85/s, late ticks from the
  copies only), but every CPU copy took 51-54 ms: present() waited on `s->gpuFence`, which Turnip moves to the
  newest in-flight submission (every BO is listed in every submit). Amended 0254: present() uses the swap-time
  fence per layer (`fPendFences`), no wait; a layer whose gpuFence moved on goes the CPU way instead of a 2D copy
  behind newer work (one in-order ring). Kernel local-20261025-175017, image out/ios16-0254b [I until booted].

- Clock-shift fragments (2026-10-26, display agent; patch 0256, README-gpu-kernel.md section 12 "0256").
  [V code] `negronifb_clockshift=100` shifts the left half of the top rows of the panel memory by hand after each
  copy. With 0231/0254 every frame is a GPU 2D copy; `present()` waited 8 ms for the copy's fence and shifted
  whether or not the wait passed, so a slow copy got the previous (already shifted) rows shifted again, then the
  engine wrote the new rows unshifted: duplicated/offset digit fragments. [V] The strip was 150 panel rows = 54 pt
  (panel 1080x2412 in logical 1125x2436, fOffY 12); the status bar is 44 pt = panel row 120, so the lock screen's
  date line (below 44 pt) was inside the strip. Fix: shift only after the fence passed (else pending, done by a
  later tick, `shiftTick()`), strip 120 rows (`negronifb_clockrows=N`), parse the shift arg before the first
  frame. Panel memory is write-combine, so no cache effect is involved. Images: `out/ios16-noshift` (kernel
  local-20261025-214340, no clockshift arg: the control), `out/ios16-0256` (0256, kernel local-20261025-215209, config args). Not flashed (phone battery empty). [I] Visual result:
  not seen by the agent; the owner checks. [I] The date's exact y on the lock screen is not measured.
- No userland lever for the ear [V grep]: `scripts/ios16/root-tweaks-extra.py` and docs have no status-bar /
  notch / safe-area tweak; the only ways to move the status bar's clock are the kernel shift (`negronifb_clockshift`)
  or the whole-picture shift (`negronifb_shift=N`, cuts the bottom rows).
- Display sleep, normal power key (2026-10-26, display-sleep agent; patch 0258, README-brightness.md
  "Display sleep (0258)", README-reboot.md "0258"). [V code] Old 0251 + 0250: `negroni_keys.c` called
  `negroni_backlight_key()`; a power-key press < 700 ms with the display on set DBV 0 at once
  (`negronibl_fastoff`, 20 s), and RequestPowerChange(0) skipped the fade (`fFadeStep = 6`). Now: 0251 keeps
  only its framebuffer hunk (0258 replaces it), 0258 removes the fast-off; the key goes to iOS only (HID
  consumer 0x30). RequestPowerChange(0): 7-tick fade, then (under `fLock`, only if still off) DBV 0 + DCS
  0x28, 21 ms, 0x10, 101 ms (live.dts `qcom,mdss-dsi-off-command = [05 00 00 00 15 00 02 28 00 05 00 00 00
  65 00 02 10 00]`), then a 100 ms vsync tick. RequestPowerChange(1): 0x11, 133 ms (on-command: 12 ms after
  0x11, 121 ms before 0x29), 0x29, last DBV, redraw. `negronifb_sleep=0|1|2` (default 1; 2 = 1: the rails
  vddio pm8350c_l12 1.8 V / vci pm8350c_l13 3.0 V are RPMh LDOs, a rail cycle needs the reset + whole
  on-command incl. DSC PPS). Panic wakes the panel (`negroni_backlight_panic`, no DSI lock). Lines:
  `NEGRONI FB: display off (fade N ms, DCS sleep ok|failed|skipped)`, `NEGRONI FB: display on (sleep-out N
  ms, DCS ok|failed|skipped, panel DBV x)`. [V code] The slide-to-power-off path ends in
  `negroni_power_off()` (RB_HALT -> HOST_REBOOT_HALT -> halt_all_cpus(FALSE) -> kPEHaltCPU); `wdt=-1`,
  the no-op slop IOWatchdog and `negronipanic` are not in it; no 0215. [I] The MDP auto-refresh restarts
  on the first TE after 0x29 and the panel keeps its registers in sleep: not tested.

- TE lock and VRR (2026-10-26, display-refresh agent; patch 0259, docs/display-refresh-plan.md, README-gpu-kernel.md
  section 17). [V live.dts, display-drivers, Mu panel XML] The panel's TE pin feeds the DPU INTF_1 tearcheck
  (base 0x0AE36000: SYNC_CONFIG_VSYNC 0x288 bit 20 = TE pin, [18:0] vsync_count = 19.2 MHz / (vtotal x fps) = 66 at
  120 Hz; VSYNC_INIT_VAL 0x294 = START_POS 0x2A0 = 2412; INT_COUNT_VAL 0x298 = TE count << 16 | lines since the
  TE; AUTOREFRESH_CONFIG 0x2B4 = bit 31 | frames per refresh, the UEFI leaves 0x80000001). Android never uses
  the auto-refresh for frames: a commit kicks the CTL per frame, idle = no transfer, and oplus ADFR then holds
  the panel at a min fps by DCS `F0 5A 5A; B0 00 14 BD; BD N; F7 0F; F0 A5 A5` (N = hold count, 120/(N+1) Hz:
  0x01 60, 0x0B 10, 0x77 1 Hz; oplus_adfr.c:2521). The 60/90/120 Hz timing-switch sets (live.dts 35659/35788/35834,
  721/652/721 bytes) differ only in `60 00|01|09`, `B9[0x38]`/`B9[0x3A]` 02|05|03 and `BD[0x14]` 00|01.
  [V code] 0259: `negronifb_te=1` samples INT_COUNT_VAL at each tick and moves the next deadline by half the
  phase error (target `negronifb_te_off`, default 800 us before the next TE); the tick period follows the
  measured TE period. `negronifb_vrr=1`: after `negronifb_vrr_ms` (3000) without a swap, the min-fps DCS
  (`negronifb_vrr_fps`, default 10 -> N 0x0B) plus the auto-refresh divider 1/12; wake on the next SwapEnd
  (divider back at once, DCS on a thread call). `=2`: the 60 (or 90) Hz timing-switch set verbatim and the
  tick/CA interval at that rate; `=3`: divider only. DCS payload limit 16 -> 60 bytes (FIFO 64 with header).
  Kernel out/kernel/local-20261026-075816 (sha256 a39f24e5...), image `out/ios16-vrr` (config args +
  `negronifb_te=1 negronifb_vrr=1`, boot_a sha256 b7d9ef7c...; 185 patches, only 0330 (the BT agent's
  uncommitted patch) and the 4 dxb skips did not apply). Review fixes in the patch: a failed idle switch turns the
  VRR off for the boot (no retry loop into 0250's 3-failure DSI shutdown) and closes the Samsung key; the
  display-off fade waits up to 60 ticks for a running VRR set; HS DCS default for mode 2; late-tick threshold
  follows the rate. Not booted. [I] Whether the
  panel honours the hold while a frame still arrives every 12 TEs; the line time of the tearcheck counter
  (19.2 MHz assumed). Recovery from a bad switch: `negronifb_vrr=0`.
- Screen-off freeze and 0275 (2026-10-26, wake agent; kernel local-20261026-074105 = 0231..0259 on the phone):
  [V] log 13:23:33-13:25:53: every RequestPowerChange(0) is followed by `late ticks 136..148` and `swaps/s 0
  presents/s 0` in the FB STAT line for 7 s, then `NEGRONI FB: display off (fade 7055 ms, DCS sleep ok)` (also
  6833, 6989 ms); the 7-tick fade (0251) took ~1 s per tick. Cause [V]: the panel memory is mapped write-combined
  (NegroniSurface::kernelAddress), so the per-pixel read-modify-write of 2.6 M pixels is 2.6 M uncached bus reads
  on the vsync work loop; the vsync notification, present and the swap flush stop for that second, backboardd's
  CA spins in SwapWait (`swapwait calls 3861 timeouts 3771` in one second; the "thread 639 caught burning CPU"
  line at 13:23:49 is that spin added up). A power-key press during the fade (13:23:35, 13:25:43) reverses it
  (RequestPowerChange(1) resets fFadeStep): no `display off` line, the UI returns after the running 1 s pass.
  `late ticks N`: rearm() adds every missed 8333 us deadline (1.1 s / 8.33 ms ~ 132) + statTick's +1 per late
  tick. 0275 (after 0259; 0265 was taken by the WLAN QRTR patch): tick 0 writes black with 8-byte stores (`display off: black in N us`), tick 1 calls
  the backlight (`display off (fade N ms ...)`, N expected <= 25), then the 0258 slow tick. No boot-arg. Build 13:33-13:35 IST (job `kernel-wake`, lock held over kernel + image;
  61 patches/xnu incl. the uncommitted 0242/0243/0259/0265-wlan/0266/0310/0311; 0330 and 0350 did not apply, the 4
  usual dxb skips): kernel `out/kernel/local-20261026-080528` sha256
  311be5c584d2aa0bc34dfbc87fe222ca0c562d6d9f4175451e7493b41145f455, image `out/ios16-wake` (config args +
  `negronipanic=30 negronipanicreason=2`; boot_a sha256 eac25faad26d782d3f0031cd720dcbd7c5cbc15e49922a2390eff36bf88f9f77,
  esp 7e710fbb...; esp.img holds this kernel [V byte compare]). The patch was built as 0265 and renamed to 0275
  afterwards (number taken by the WLAN QRTR patch): the comments in the built kernel say 0265, the code is the same.
  [I] The owner's "no app opens after screen off/on": in the log the display path recovers after the wake
  (swaps/s 76 at 13:23:37), SpringBoard (pid 25) stayed alive until 13:24:43, when it crashed (SIGSEGV far 0x18,
  right after `exec Siri` and "MPSCommandBufferImageCache ... commandBuffer does not conform to the MTLCommandBuffer
  protocol": the Siri long-press on the power key, a NegroniMetal/MPS problem, not the display) and respawned as
  pid 367. Between 13:23:49 and 13:24:00 only `exec splashboardd` and five "trying to set state of nil layer"
  bursts (every ~2.4 s) appear, no `exec <App>`: the taps reached SpringBoard but no app process was spawned.
  Whether the 7 s freezes (touches queued, CA spinning) cause that is not proven; retest with 0275.
  Selector 79 (`backboardd sel 79 in 2/0 out 0/40|24`) is not in the driver's table: accepted with zeroed
  output, logged on every call (selector >= 64); it comes with every power-key press and brightness change [V];
  its meaning is unknown [I].

- 120 Hz pipeline and the top-left strip (2026-10-26, display-perf agent; patches 0267, 0286, README-gpu-kernel.md
  section 18). [V log 13:18-13:31, kernel 074105] swaps/s mean 49, presents/s mean 43.5 (max 105), copy avg 2.0-2.6 ms
  (max 8), SwapWait busy 173/s, gpu-wait skips 22/s, DCVS level 4-5 (350-421 MHz) at 20-50 % busy, thermal cap down
  to 4 at CPU 79 C. [V telemetry] backboardd Metal buffers: commit-to-complete mean 15.6 ms (n 9368), 38 % over 16.7 ms,
  ~6.2 M pixels and 7 passes per buffer. [V older log, fixed 818 MHz] presents/s 57.7 vs 43.5 with DCVS.
  [V code] The tick notified CA first, then copied, waited for the copy fence (clock shift) and only then published
  the swap id: CA's SwapWait right after the notification got busy, retried 1 ms and skipped the heartbeat [I: the main
  loss]. [V code + 0265 measurement] the clock shift was an in-place memmove in the write-combined panel memory
  (uncached reads, ~10 MB/s): several ms of half-shifted strip while the engine scans it = the top-left glitch [I visual].
  0267: notify after the frame is queued (`negronifb_notifylate`, default 1); the shift inside the copy (GPU: 4
  rectangles in one IB, CPU: shifted memcpy; left-edge fill = the n pixels pushed out at the middle;
  `negronifb_clockcopy`, default 1). 0286: DCVS UI floor (`negronigpu_uifloor` 9 = 640 MHz at >= `negronigpu_uifps` 30
  swaps/s, held `negronigpu_uihold` 1000 ms; thermal cap still wins). Images `out/ios16-perf`, `out/ios16-perf-noshift`
  (scripts/display/build-perf.sh): kernel local-20261026-082629 (sha256 92f50f3a...), boot_a 2583f0ab... /
  50d09e1b... 0268 became 0286 (it changes 0281/0285 code; name order). [I] Not booted. Next: panel double buffer (DPU base flip, 0234 code) or zero-copy.

- Panel wake and double buffering (2026-10-26, display agent; patches 0268, 0269, README-gpu-kernel.md sections 19/20,
  README-brightness.md "0268"). [V log 13:24-13:30] the 0258 wake (0x11, 133 ms, 0x29) gave `DCS ok` but a black panel
  with a purple strip. [V display-drivers] Android sends the whole on-command and then the 0x0A PPS on every display on
  (dsi_panel.c:5708-5760, dsi_display.c:9165-9170), LP (no on-command-state: default LP, dsi_panel.c:2678-2680), long
  packets by memory DMA (dsi_ctrl_hw_cmn.c:870). [V] The UEFI XML `DSIInitSequence` is not empty (display-refresh-plan.md
  said so: wrong): 116 lines, the same sequence + `2C/00` fake frames in the 121 ms wait; its `39 9E` PPS = the DT 9E
  PPS with version 0x12 and 128 bytes (only byte 1 differs). 0268: `negronifb_wake=2` (default) = auto-refresh paused,
  the 94-packet on-command, the 0x0A PPS, auto-refresh back, 50 ms TE/frame check, DBV; packets > 60 bytes from a
  16 KiB buffer at 0xbaafc000 (end of the splash region) by memory DMA [I: works under XNU's SMMU state; the UEFI used it];
  a set lock against the 0259 VRR sets. 0269 `negronifb_dbuf=1` (default 0): 3 panel buffers (0xb8000000, 0xb89f0000,
  0xb93e0000), full-panel one-layer frames into a free buffer, SSPP_SRC0_ADDR + CTL_FLUSH (0234 probe's pipe/CTL) after
  the copy's fence, flip taken = CTL_FLUSH bits clear; display off parks on the shown buffer; panic = the panel memory.
  2 buffers would cap the GPU path at 60/s. GPU: one mapping per panel buffer. Build: kernel local-20261026-125636
  (sha256 dc55e5fd...), image `out/ios16-dpu` (boot_a fa73ea88...; config args + `negronifb_sleep=1 negronifb_dbuf=1
  negronipanic=30 negronipanicreason=2`). [I] Not booted.

- DSI/DPU follow-up of the display audit (2026-10-26, DSI agent; patches 0292-0296, README-gpu-kernel.md sections 22-26,
  docs/display-refresh-plan.md section 8; all default off; build-only). [V source]
  - 0292 `negronifb_dsidma=1|2`: command sets (0259 VRR, 0268 on-command) as Android sends them: batches up to the packet
    without the DT 0x40 flag in one memory DMA from 0268's buffer 0xbaafc000, inside 0268's set lock, one MDP-busy wait per
    set. A failed DMA = memory DMA off for the boot, rest packet by packet. 0259 mode 1 now HS by default (DT state).
  - 0293 `negronifb_esd=1|2`: DCS reads (port of dsi_message_rx/get_cmd_read_data: 0x37 + 0x06 with BTA, RDBK_DATA_CTRL
    0x1d4, RDBK_DATA 0x6c-0x78); panel ID once (da/db/dc, 0a, 0e, a1 x 11 = oplus date); 0x0a every 5 s, expect 0x9d/0x9f;
    wrong twice = off-command + 0268 wake (`negroni_backlight_reinit`); 3 read errors in a row = check off.
  - 0294: tearcheck vsync_count 66/88/132 on 0259 mode 2 switches (`negronifb_tcfg=0` = off).
  - 0295 `negronifb_teirq=1`: first SPI support of the port (pe_fiq.c `negroni_spi_register`, sleh.c dispatch); MDSS line
    INTID 115 (SPI 83, live.dts mdss_mdp), INTF_1 tear RD_PTR (0x36800 block) at line init + 1; the stamp feeds 0259's
    TE lock (needs `negronifb_te=1`). The tick stays the 0254 timer.
  - 0296 `negronifb_pwrprobe=1` (read-only DISP_CC/GCC/DSI clock and GDSC dump) and `negronifb_idle=2` (Android's
    no-transfer idle: after 58 ms without a swap the auto-refresh goes off with sequence 1, then one CTL_START per new
    frame; display off restores it). No clock gating yet: with the auto-refresh on, no display clock may drop (table in
    README section 26). Refused with `negronifb_vrr=1|3`, `negronifb_dbuf=1`, `negronifb_zerocopy=1`.
  - Rebase lesson: 0268 (written at the same time) already had a memory-DMA path for long packets and a set lock; 0292
    reuses its buffer and lock instead of a second buffer. 0288 also changes sleh.c/pe_fiq.c (CPU idle); 0295 sits after it.
  - Build: kernel only (owner rule 2026-10-26: no boot image); see the plan (Display DSI/DPU status). Suggested first
    test args: config args + `negronifb_dsidma=1 negronifb_esd=1 negronifb_pwrprobe=1`.
  - Full builds failed twice on other agents' work in progress (0324 negroni_wlan_smmu.c `pmap_paddr_t`/`delay`; 0332
    negroni_bt_h4.c `IO_NDELAY`), not on 0292-0296: the full-tree build must wait for every patch on disk to compile.

## 16. Metal (2026-10-25, Metal agent)

Plan: [metal-plan.md](metal-plan.md). Design + interfaces: [metal-design.md](metal-design.md). Code: `userland/metal/`, `scripts/metal/`.

- Route: NegroniMetal.bundle (`_MTLDevice` subclass) -> UniXNU/ios-flame frontend + bridge (MIT) -> metal2vulkan (AIR -> SPIR-V, Metal on Vulkan; GPL-2.0+ OR LGPL-3.0+) -> Turnip -> kernel [decision, owner priority].
- ios-flame (Pixel 4, A640) drew the **20H392** home screen with exactly this stack on 2026-10-22; its frontend has the iOS 16 fixes [V ios-flame 745c434 HANDOFF.md "Metal at user quality, step 2"].
- Metal 20H392 discovery: `IOServiceMatching("IOAcceleratorES")` -> `MetalPluginName` -> `/System/Library/Extensions/<name>.bundle` -> `MetalPluginClassName` or principal class, must subclass `_MTLDevice` -> `initWithAcceleratorPort:` [V disassembly Metal 0x181b144c8, 0x181a3c7c8].
- A nil from `initWithAcceleratorPort:` is skipped: no device, no crash [V Metal 0x181b14584 `cbz x0`].
- `MTLAddDevice` is exported; it asserts `MTLDevice` + `MTLDeviceSPI` and calls `initLimits`, `initFeatureQueries` [V Metal 0x181a1b368].
- iOS 16 has no `MTLCopyAllDevices` (the iOS 27 SDK marks it iOS 18+) [V 20H392 Metal symbols].
- `_MTLDevice` is 528 bytes on 20H392 (536 on iPadOS 17.7.11: UniXNU's size assert must go) [V ipsw class-dump].
- AGXMetalA11 227.6.5: principal class `AGXPrincipalDevice : NSObject`; device chain `AGXA11Device : AGXA11FamilyDevice : IOGPUMetalDevice : _MTLDevice` [V class-dump].
- QuartzCore `default.metallib`: 141 functions (39 vertex, 95 fragment, 7 kernel), AIR 2.5, MSL 3.0; loaded with `newLibraryWithURL:`, specialised with function constants; no `newLibraryWithSource:` [V metallib-info.py, strings].
- The 20H392 root has 143 metallibs / 16,903 functions; 128 are AIR 2.5 [V `out/metal/spi/metallib-summary.txt`].
- Apple's MSL front end is on the device (MTLCompilerService, libGPUCompiler 31001.722, libLLVM) separate from the AGX back end [V dsc image list].
- metal2vulkan 720ef1ce on the Mac, QuartzCore metallib, bare Vulkan 1.2 profile: kernels 3/7, vertex 35/39, fragment 73/95; 20 refusals are FramebufferFetch (Turnip has the extension) [V host-translate.sh; I for Turnip].
- Mesa 25.0.7 Turnip has **no** `VK_EXT_external_memory_host` (needed for IOSurface textures); UniXNU's `turnip-darwin-kmd.patch` adds it with a kernel host-page import [V tu_device.cc; UniXNU-ios26 patches/mesa].
- Turnip on Darwin must not read `CTR_EL0` at EL0 (SIGILL) [V UniXNU turnip-darwin-kmd.patch:1394].
- No PPL on our kernel: the physmap maps managed RAM cacheable, so WC views of managed pages are mismatched aliases; flame used RAM XNU never manages for GPU buffers [V flame HANDOFF 03:40]. Our candidate: 0x900000000-0xA80000000 (outside `--dram 840000000:C0000000`) [I].
- Mesa FD730 = chip_id 0x07030001, a7xx_gen1, 4 CCU, highest_bank_bit 16 [V Mesa 25.0.7 freedreno_devices.py:1065].
- Built 2026-10-25: bridge (1 min 46 s), NegroniMetal bundle 21 MB, m2vtest, metalprobe, vkprobe for arm64-apple-ios16.0 [V]; all imports exist in the 20H392 cache (`scripts/metal/check-imports.py` PASS) [V].
- `ipsw` (brew blacktop/tap/ipsw 3.1.739) reads the 20H392 cache in place: class-dump, disass `--vaddr` (with `--cache` on a writable path: the root mount is read-only), `dyld macho --symbols` [V]. Its nlist dump lacks re-exports (memcpy): check-imports.py also accepts what Apple's own images import [V].
- CMake for iOS makes `.app` bundles of executables unless `CMAKE_MACOSX_BUNDLE OFF` [V].
- Gate files on the phone: `/var/db/negronimetal/{clients,off,env,strikes/,cache/,metal.log}`; default clients = probes only, so backboardd keeps the GL path [decision].
- Round 2 (2026-10-25, review `docs/reviews/gpu-turnip-metal-2026-10-25.md`):
  - [V] QuartzCore `default.metallib` host translation with the stand-in loop (vertex attributes, function constants, attachment formats; `scripts/metal/host-translate.sh`): vk12-floor kernels 7/7, vertex 39/39, fragment 75/95 (20 = FramebufferFetch); A730 estimate profile (`scripts/metal/a730-profile.py`) kernels 7/7, vertex 39/39, **fragment 93/95**.
  - [V] The 2 fragments left are `inplace_copy_lpf/lph`: RasterOrderGroups needs `fragmentShaderPixelInterlock`; Mesa 25.0.7 Turnip has no `VK_EXT_fragment_shader_interlock` (tu_device.cc). [I] CA uses them only when the device reports raster order groups.
  - [I] The A730 profile is vk12-floor limits + features/extensions read from Mesa 25.0.7 tu_device.cc for FD730, not a capture. The 4 tile kernels pass only as tile pipelines (CA needs tile-shader support to use them). Function constants are stand-ins (zero/false), not CA's values.
  - [V] `scripts/metal/selector-gap.py`: QuartzCore names 222 Metal protocol selectors; the flame frontend lacked 20 (MTLTexture swizzle/compression/sparse/parent-relative/gpuResourceID, pipeline/sampler gpuResourceID, makeAliasable, queue SPI finish). Patch `userland/metal/patches/flame/0001-*` adds them: 0 missing. [I] A string match is not proof of a call.
  - [V] The 20H392 root is attached read-only at `/private/tmp/iosroot-ro` (mounted from `~/op10-apple/ios16-root.img`; `ios16-root-new.img` was deleted 2026-10-25, 16 GiB). Copy of QuartzCore's metallib: `out/metal/ref/QuartzCore.default.metallib`.
  - [V] Turnip's DRM layer exports `redwood_drm_note_surface(base, size, surface ID)` (negroni_drm.c, GPU agent, uncommitted). The frontend patch calls it before each IOSurface import, so a host-pointer import goes through kernel 0x7e by surface ID. The staged Turnip (00:22 build) does not export it yet: the plugin logs this, and on the phone the self-test then refuses the device [I].
  - [V] The staged Turnip dylib uses LC_DYLD_INFO_ONLY and imports `dyld_stub_binder`. In the 20H392 cache that symbol is `local` in libdyld (`ipsw dyld symaddr`). [I] dyld4 may still bind it; a Turnip link with chained fixups removes the doubt.
  - [V] Plugin host test on the Mac (`scripts/metal/host-plugin-test.sh`, MoltenVK as the loader): the cases unlisted, off, no GPU, 1 ms timeout (twice, strikes = 2), dead-man and device pass. The device case ran the IOSurface clear self-test through the frontend (681 ms).
  - [V] The plugin and the frontend compile for arm64-apple-ios16.0 with Xcode 27.1 (`scripts/metal/build.sh`) and with Xcode 15.4 (iPhoneOS 17.5 SDK). Import check vs the 20H392 cache: PASS.
- Turnip rebuild (2026-10-25, GPU/Turnip agent; `scripts/gpu/turnip-build.sh`, patch `userland/turnip/mesa-patches/0001-turnip-darwin.patch`):
  - [V] ld (ld-27037.1, Xcode 27.1) drops chained fixups when `-undefined dynamic_lookup` is given and writes LC_DYLD_INFO_ONLY, which imports `dyld_stub_binder`. `-Wl,-fixup_chains` together with dynamic_lookup gives LC_DYLD_CHAINED_FIXUPS; the undefined weak symbols become `<flat-namespace>` binds with `[weak-import]` (`dyld_info -fixups`, small test dylib).
  - [V] Mesa needs dynamic_lookup on Darwin: Mach-O "weak" is weak_import, and the generated entrypoint tables have weak references that no layer defines (lavapipe's meson.build says the same, `b_lundef=false`). Turnip: 4222 such symbols (1351 vk_*, 650 wsi_*, the rest tu_/tu_rmv_ C++ names). [I] dyld4 makes 4222 flat lookups when it loads Turnip: a load-time cost, not measured.
  - [V] Built (last, after the 0232 ABI): `out/gpu/turnip/libvulkan_freedreno.dylib` 11,585,552 bytes, sha256 b0d758e0..., arm64, minos 16.0, chained fixups, no dyld_stub_binder. Exports: `redwood_drm_note_surface`, `vkGetInstanceProcAddr`, `vk_icdGetInstanceProcAddr`, `vk_icdGetPhysicalDeviceProcAddr`, `vk_icdNegotiateLoaderICDInterfaceVersion`. Links IOKit, IOSurface, CoreFoundation, libSystem, libz, libc++.
  - [V] `scripts/metal/build.sh` + `check-imports.py` (libz added to its table): NegroniMetal, Turnip (stripped copy in the bundle), vkprobe, metalprobe, m2vtest: PASS, 0 missing.
  - [V] The Turnip build needs `-DHAVE_LIBDRM` on libvulkan_wsi on Darwin, else wsi_common_drm.c fails with -Wmissing-prototypes (wsi_common_private.h:337 guard).
  - [V] Turnip 25.0.7 needs msm >= 1.6 (tu_knl_drm_msm.cc:1057); negroni_drm.c reports 1.7. Mesa's binary syncobj move swaps handles (vk_drm_syncobj.c:376), so no sync-file export is needed while the fd extensions are off.
  - [V] Host import in negroni_drm.c (`redwood_drm_host_import`), per docs/gpu-abi.md after 07ae8ca: a noted IOSurface by ID (0x7e) first, because only 0x7e / scalar 12 imports take part in the present path (gpu-abi section 8); other pages by 0x49 USERPTR (0232, 24-byte struct, 16 KiB aligned, <= 256 MiB), retried with READ_ONLY when the kernel answers EIO (pages not writable). No "userptr" in the `NegroniGPUABI` text, or ENOSYS once: no more 0x49 calls. Each 0x7e import gives a new handle (0230 importSurface).
  - [V] Turnip host-pointer imports accept only HOST_CACHED types without HOST_COHERENT (gpu-abi section 6); Turnip has one such type when its L1 line size is known (tu_device.cc:1476, the Darwin sysctl path gives 64). The buffer is cached_non_coherent, so vkInvalidateMappedMemoryRanges drops lines with dc civac.
  - [V] Kernel msm timeouts are on mach_continuous_time (0230 millisecondsUntil), a time in the past = only ask. Darwin user CLOCK_MONOTONIC uses the same counter [I: libc source not read].
  - Staging: `out/gpu/turnip/libvulkan_freedreno.dylib` is the only staged Turnip (scripts/metal/env.sh TURNIP_DYLIB); `out/gpu/libvulkan_freedreno.dylib` is gone [decision].
- backboardd SIGSEGV every ~18 s on the m2v completion thread (2026-10-25, async-safety agent; not tested on the phone yet):
  - [V] The fault is the CPU `dc civac` of Turnip `tu_bo_sync_cache` (tu_knl.cc) by the user VA of a host import, called by
    m2v `CommandBuffer::invalidate_host_imports` (m2v/0001) at the top of `complete()`. CoreAnimation had already unmapped the
    pages: they are read-only asset pages (usblog "host import of 0x... read-only pages, the GPU only reads them", the 0x49 EIO ->
    NGL_USERPTR_READ_ONLY retry in negroni_drm.c). The kernel wires host-import pages at import (0232 `importHost`:
    withAddressRange + prepare), so the GPU side is safe. ab7fc35 hid the fault with a CPU wait; b945b99 made the wait opt-in.
  - [V] Kernel CPU_PREP (0230 `cpuPrep`, msm 0x44 and scalar 16) waits for the buffer's fence, then calls `cachePage(b->pa[p])` =
    `flush_dcache64(pa, PAGE_SIZE, TRUE)` over every page: by physical address, for every kind except the pool, kBufferHost
    included (takePages fills `pa` for host imports). No user VA. It does nothing for a buffer that was never submitted.
  - [V] The frontend kept no-copy buffers until -finish only for setBuffer/setTexture/blit/attachments; `useResource:` was a
    no-op and `useResources:`/`useHeap(s):` were missing, and `-[NBBuffer dealloc]` runs the CA deallocator at once.
  - Change: `redwood_drm_host_import` gets `bool *read_only` (true for a NGL_USERPTR_READ_ONLY import); new
    `redwood_drm_cpu_prep(fd, handle)` = msm 0x44 with `MSM_PREP_READ | MSM_PREP_NOSYNC`, no wait (kernel cpuPrep with 0 ms:
    kIOReturnBusy -> EBUSY; scalar s_cpu_prep: EBUSY). A wait would be for the buffer's LAST submission (b->fence), so a later
    frame that lists the same surface would block m2v's completion thread. Turnip
    `0002-turnip-darwin-host-import-cache.patch`: a read-only host import is not `cached_non_coherent`; `tu_bo_sync_cache`
    never touches `bo->map` of a host import in either direction. Flush (CPU-to-GPU): nothing, the kernel cleans written
    pages at each submission that lists the buffer (gpu-abi.md section 6 rule 1). Invalidate (GPU-to-CPU) of a writable
    import: CPU_PREP NOSYNC by GEM handle; EBUSY is skipped (a later submission still lists the buffer; its completion drops
    the lines again) [I: expected and harmless]; any other error is skipped and logged once (mesa_logw).
  - Change: `scripts/metal/build.sh` now runs `check-imports.py` over the staged binaries and fails on a missing import
    (IOS_DSC = the cache path, default the `/private/tmp/iosroot-ro` mount; NO_IMPORT_CHECK=1 skips).
  - Change: `flame/0006-negroni-resource-retention.patch`: useResource(s)/useHeap(s) (all `stages:` forms) add the objects to
    `resourceOwners`; NBBuffer dealloc counts no-copy deallocations while command buffers are in flight (`inflight`) and those
    a runtime command buffer still uses (`used`, NBLOG for the first 8). `m2v/0002-negroni-host-invalidate-stats.patch`:
    counters of `invalidate_host_imports` (C symbol `m2v_negroni_host_invalidate_stat`). Telemetry row:
    `J nocopy-dealloc inflight=N used=N | hostinv n=CALLS r=RANGES kb=KIB`. NEGRONIMETAL_SYNC / DEFER_SCHEDULED stay opt-in.
  - [I] `used` > 0 means a no-copy buffer was freed under GPU work through a path that still does not retain it; the GPU still
    reads the wired pages, but the frontend's retention has a gap there. CPU_PREP drops lines over the whole buffer, not the
    range.

- Compositor policy and crash symbolication (2026-10-25, policy agent; built, not tested on the phone):
  - [V] m2v 720ef1ce emulates two per-pixel Metal answers by default: Metal's colour-write rounding on 8-bit unorm and
    sRGB attachments that store the output as written (`pipeline/color_writes.rs` `color_writes`/`exact_writes`; off only
    with `VkProperty::MetalColorWrites`, which `driver_facts.rs` `DEVIATIONS` gives to MoltenVK 1.4.1 on the M3 Max and M4
    alone), and Metal's exact 8-bit linear filter (`DevicePolicy::UNTRUSTED` `unorm8_linear_filter: Exact`; the device
    filter needs `DeviceWithinOneCode` AND a `DriverDeviation::Unorm8LinearFilter` row: NVIDIA, RADV, ANV, lavapipe, no
    Turnip). Both bridges used `DeviceOptions::default()`; m2v has no env var for either. [I, audit] ~35 instructions per
    unorm channel, ~70 + a 4 KiB table read per sRGB channel.
  - [V] A `MetalColorWrites` row is format-agnostic (it drops the rounding on every unorm/snorm/10:10:10:2 format) and no
    policy switches it off, so `m2v/0003-negroni-compositor-policy.patch` adds `DevicePolicy::color_writes`
    (`ColorWritesPolicy::{Exact (default), DeviceUnorm8, DeviceUnorm8Srgb}`, in `ProfileFields`, so in the fingerprint:
    a policy change gives new shader-cache keys). `DeviceUnorm8` maps each `Unorm{bits:8}` channel to
    `ChannelWrite::Device` (R8/RG8/RGBA8/BGRA8/ARGB8 Unorm, and the alpha of the 8-bit sRGB formats); `DeviceUnorm8Srgb`
    also the sRGB channels. Half-float and the other formats keep their rules. The patch also adds a Turnip row
    (`DriverId::MESA_TURNIP`, vendorID 0x5143, any GPU, Mesa 25.0.7) of `Unorm8LinearFilter`: "NegroniMetal: unmeasured
    on A730, accepted for a UI compositor [I]". A newer Turnip release counts as "Beyond" (taken, announced once).
  - [I] Turnip reports `driverVersion` = VK_MAKE_VERSION(25,0,7) (Mesa's vk_get_driver_version); not read on the phone.
    If it reports something else, the filter row does not match and the filter stays exact (safe).
  - `flame/0007-negroni-device-policy.patch`: both bridges take `objects::negroni_policy()`, from env
    `NEGRONIMETAL_POLICY`: `exact` (m2v defaults), `compositor` (default, also unset/unknown: device 8-bit unorm filter +
    device 8-bit unorm colour writes, containment ON), `compositor-srgb`, `unsafe` (compositor + `containment: UnsafeOff`
    + `isolation: Off`, set together as derive.rs:108 needs). Set it in /var/db/negronimetal/env (docs/metal-management.md).
  - Plugin: after "image base ...", one line `NMTL[pid name]: images NegroniMetal 0x... text 0x... turnip 0x... text 0x...
    (m2v policy NAME)` (dladdr on Turnip's `vk_icdGetInstanceProcAddr`, __TEXT vmsize from the Mach-O header). It goes
    through nlog, so to /dev/console and /var/db/negronimetal/metal.log when that file exists [V: sm2_logs]. Symbolicate:
    `atos -o out/gpu/turnip/libvulkan_freedreno.dylib -l TURNIP_BASE PC` (the unstripped Turnip; the bundle copy is
    stripped). Reason: a backboardd crash (pc in Turnip, callers in m2v, far 0x0) had no Turnip base.
  - [V] Build: fetch (m2v/0003, flame/0007 apply), bridge 1m27s, `scripts/metal/build.sh` check-imports PASS (0 missing).
    Staged NegroniMetal 21,925,072 bytes sha256 2d8fc104...0807 (__TEXT 0x132c000); stripped Turnip 10,975,456 bytes
    sha256 7cb29818...05ea. m2v unit tests not run (a driver_facts test that lists the Unorm8LinearFilter rows may need
    the Turnip row).
  - Next: A/B on the phone, GPU ms per CA frame with `NEGRONIMETAL_POLICY=exact` vs default, then `compositor-srgb`.

- Metal at the real GPU clock (2026-10-25 23:35, kernel 0254b+0236+0237 at level 12, bundle with m2v/0003 compositor
  policy, clients = backboardd): [V] 150 s without a crash; commit-to-callback 4.5-8 ms per command buffer (rp3 dr39
  3 Mpx; before: 60 ms to 14 s at ~5 MHz); STAT `presents/s` 17-83 all by the 0231 GPU copy (`gpu N`, cpu 0), copy
  avg 2 ms, `late ticks 0`, `gpu-wait skips` 3-23 per second (frames shown one tick later), SwapWait busy answers
  pace CA. CPU-only path on the same kernel: `swaps/s 172 presents/s 120 copy 2.4 ms late ticks 0`.
  - [V] Metal for ALL processes (clients `*`, 23:38-23:41): SpringBoard and backboardd on the GPU 160 s, no crash of
    either; command buffers rp7 dr86-272 5.9 Mpx complete in 9.6-13.7 ms; presents all `gpu`, late ticks 0. Only
    AegirPoster crash-loops (sig 6, dead-manned; wallpaper tiles magenta; separate bug). Config default is now
    `negronigpu_level=12`.

- Safari + WebGPU and MSL source (2026-10-26, Safari/efficiency agent; patches flame/0009, flame/0010; the phone went flat
  before the new bundle was tested):
  - [V] 20H392 WebGPU.framework strings (`out/metal/spi/WebGPU.strings.txt`): `newLibraryWithSource:options:error:`,
    "#include <metal_stdlib>" (WGSL -> MSL text), `newArgumentEncoderWithArguments:`, `argumentBuffersSupport`,
    `newTextureWithDescriptor:iosurface:plane:`, `nextDrawable`, `present`, `supportsFamily:`. `scripts/metal/selector-gap.py
    --client WebGPU`: 6 protocol selectors missing (indirect draws/dispatch, `executeCommandsInBuffer:withRange:`,
    `newIndirectCommandBufferWithDescriptor:...`, `copyFromBuffer:...:options:`); the device methods it names resolve on
    `_MTLDevice` so the gap tool did not flag them.
  - [V] The frontend had no `newLibraryWithSource:`; the message resolved to `-[_MTLDevice newLibraryWithSource:options:error:]`
    = `MTLLibraryBuilder::newLibraryWithSource` (this = `_MTLDevice+0x178 _libraryBuilder`, made in `-[_MTLDevice init]`) ->
    `newLibraryWithRequestDataAndHash` -> `initLibraryContainerWithRequestData` (MTLCompilerService XPC,
    `getCompilerConnectionManager`) -> `[[_MTLLibrary alloc] initWithLibraryContainer:device:]` (disassembly in
    `out/metal/spi/disass/`). An `_MTLLibrary` has `bitcodeData` (NSData) and `libraryDataContents` (dispatch_data).
  - [V] On the phone that path faults: `metalprobe --compute --render` (system device, bundle of 23:51 and the 0009 bundle
    of 03:33) = `Segmentation fault: 11` before any plugin log line. usblog: `CRASH metalprobe[364] sig 11 ... slide 0x40ea8000`,
    `pc 0x2129a9df4 lr 0x1c2066fc4 far 0x10000001b`, `bt 0x1c2066a78 0x109a10a48 (NegroniMetal+0x18a48) ...`; second run
    pid 394: `pc 0x2129a9fe4 lr 0x1c20670c0 far 0x7000000000000000 bt 0x1c2066f0c 0x1c2066a78 0x106410a48`. Unslid:
    pc 0x1d1b01fe4, callers 0x1811bf0c0 0x1811bef0c 0x1811bea78 (below Metal's text 0x181a16078: another cache image; not
    symbolicated, the root image is now `~/op10-apple/ios16-root.simg`, an Android sparse image, no mount). `exec
    MTLCompilerServi` never appears in any usblog: the XPC service was never launched [V]; the fault is before or at the
    connection [I].
  - [I] Mechanism of the "black/white flash": Safari's GPU process compiles the page's WGSL shaders through this path, dies
    (usblog 23:51:13 `CRASH com.apple.WebKit[300] sig 11 far 0x16bc9db70` = stack guard page, `map after far prot 0/7`, then
    `exec com.apple.WebKit.GPU` the same second; 10 GPU-process launches in the night), and WebKit relaunches it: the page
    area alternates between the last composited tiles and the empty layer. The GPU process's pipelines.log (303 rows) holds
    only `com.apple.coreanimation` pipelines, no refusal (ok=0: 0), no MISSING line: WebGPU never reached a pipeline maker.
    WebContent never loads the plugin (no `NMTL[... WebContent]` line in metal.log or usblog).
  - Change (flame/0009): `newLibraryWithSource:options:error:` / `...completionHandler:` on the device. Default: a clean
    refusal (nil + NSError, `native-metal: newLibraryWithSource: refused (...)` once per process, journal line `L source
    refused`), so the caller gets a failed shader module and lives. `NEGRONIMETAL_MSL_FRONTEND=1` runs the base IMP (not
    `[super]`: the methods are copied into the `_MTLDevice` subclass) and feeds `bitcodeData` to `nmb_library_new` (bare AIR
    unless "MTLB"): the path to finish once the fault is found. `newArgumentEncoderWithArguments:` answers nil (logged once):
    the base method only raises; WebGPU bind groups need argument buffers, which neither the frontend nor the bridge exposes
    (`NBFunction newArgumentEncoderWithBufferIndex:` is nil too) [V]. So WebGPU content needs: (1) the MSL front end or an
    own WGSL/MSL path, (2) argument buffers, (3) the 6 selectors above for indirect work. Not a quick fix.
  - Idle load [V from logs/usblog.log, 2026-10-25 22:38 - 03:28]: of 8614 `FB STAT` seconds, 5712 have `presents/s 0`:
    nothing is rendered at idle. GPU WATCH: `gxclk 817/818 MHz` in 2341 of 2428 samples (the rest at boot): the clock is
    fixed by the kernel (`negronigpu_level=12`), RBBM idle (0x1) in 2332 of 3049 samples. The idle heat is the fixed clock,
    not bridge work (kernel scope). While the UI moves: backboardd telemetry (03:30) `S c2078 ... R13774 D99661 F4426 B106`,
    `G commit-to-complete mean=9965us`, K rows `rp9-10 dr114-124 kpx8131-8147` (8.1 Mpx per command buffer = 1.75 screens;
    2.1 full-screen passes per command buffer), `J nocopy-dealloc ... hostinv n=2077 r=40067 kb=47609088` (22.9 MB of host
    imports invalidated per command buffer, ~19 ranges: m2v/0001 invalidates every import used, read-only ones included),
    `J surface cache n=0` (backboardd). The GPU process's CA pipelines have colour attachment 0 = pixel format 554
    (`MTLPixelFormatBGR10_XR`) with 15 = write mask; the W row says `PrecisionNote::ExtendedRangeBlendSource` is in the fragment
    functions: CA composites into XR10 attachments over 32-bit surfaces, with m2v's extended-range blend emulation per pixel
    [I: a per-pixel cost candidate for the 10 ms; not measured].
  - Change (flame/0010): `NEGRONIMETAL_SURFACE_FLUSH=0|1` for flushSurfaces (default unchanged). Plugin: `CA_FORCE_TRIPLE_BUFFERING`
    removed (no such string in 20H392 QuartzCore [V]). `scripts/metal/idle-stats.sh` (kernel-log part works offline:
    last 600 s of the log at 03:28 = 94 STAT seconds, 66 idle, GPU busy 13%). Next (not done): (1) count m2v host
    invalidations only for imports the command buffer wrote (m2v patch: `invalidate_host_imports` over used_resources has no
    read/write split), (2) A/B `NEGRONIMETAL_POLICY=compositor-srgb`, (3) why CA picks BGR10_XR attachments with
    `supportsExtendedXR10Formats = 0` (another answer, e.g. `supportsBGR10A2`/display colour mode) and whether BGRA8 cuts ctc.

- MSL source in process, argument buffers, indirect work (2026-10-26, Metal agent; flame/0011; built, phone off, not run):
  - [V] The metalprobe faults of 03:33/03:35 were in the plugin, not in Metal: pc `_platform_memmove`, callers
    `+[NSData dataWithBytes:length:]` <- NegroniMetal+0x18a48 (image base 0x1099f8000 in the log). That build (c1ecf8e)
    called the base `newLibraryWithSource:` and mapped `-[_MTLLibrary libraryDataContents]` with dispatch_data_create_map:
    the base call answered an object and its library data was not a valid dispatch_data. Still no `exec MTLCompilerServi`
    in the logs [V]; why the base path answered without the XPC service is open [I].
  - [V] 20H392 Metal: `MTLCompilerConnectionManagerPrivate(int)` takes the monolithic (in-process) compiler only when
    `_MTLIsInternalBuild()` = `os_variant_has_internal_diagnostics("com.apple.Metal")` is true and env
    `MTL_MONOLITHIC_COMPILER`/`USE_MONOLITHIC_COMPILER` = 1 (0x181a413b4): not usable on a customer build. Disassembly:
    `out/metal/spi/disass/mono/`. `_MTLCreateCompilerConnectionManager(int)` is exported.
  - [V] MTLCompilerService's work is `MTLCompilerObject::buildRequest` (MTLCompiler.framework): source requests call
    libGPUCompiler `MTLGPUCompilerBuildFromSourceToBuffer(compiler, LLVMContext*, source, 0, 0, 0, options, char **log,
    LLVMMemoryBufferRef *out)` (0x1bbdabd58); compiler = `MTLGPUCompilerCreate(0)` (0x1bbdaebbc); the log is strdup'd
    (libGPUCompiler sub_1bbfc23c0); the buffer is a metallib. The front end is libGPUCompilerImplLazy.dylib (in the
    cache, dlopened by libGPUCompiler). libLLVM exports the C API (LLVMContextCreate, LLVMGetBufferStart/Size,
    LLVMDisposeMemoryBuffer). Options are Metal's client text (`-std=metal%u.%u `, `-std=ios-metal%u.%u `, `-ffast-math `).
  - [V] The same API on macOS 27 (GPUCompiler.framework 32023, LLVM C API inside it): `mslprobe` on the host compiles MSL
    to a metallib in ~150-600 ms. With bare options the host front end compiles as C ("not allowed with 'C'", no
    metal_stdlib); `-x metal -finclude-default-header -internal-isystem <clang>/include/metal` fixes it (what `metal -###`
    passes to cc1). negroni_msl.h tries the bare options first and adds these flags on that answer [I: which one the
    20H392 front end needs is not known].
  - [V] root-grep (scripts/metal/root-grep.sh over ios16-root.simg): `MTLCompilerService.xpc`, `libGPUCompilerImpl(Lazy)`
    and `metal_stdlib` names are in the root image. [I] the MSL headers are at
    GPUCompiler.framework/Libraries/lib/clang/31001.*/include/metal.
  - [V] metal2vulkan translation: an xcrun metallib for air64-apple-ios16.0 (AIR 2.5, MSL 3.0) and the host front end's
    metallib (AIR 2.9) both translate 3/3 (host-translate.sh, vk12-floor). 20H392's front end should give AIR 2.5 [I].
  - [V] Host test `msl` case (MoltenVK, M4): in-process compile 316 ms, `NBArgumentEncoder` encodedLength 16 for
    {device float*, constant float*}, argument-buffer kernel 64/64 right, `dispatchThreadgroupsWithIndirectBuffer:` 64/64
    right, `newArgumentEncoderWithArguments:` 16 bytes, compile error -> nil + compiler text. argumentBuffersSupport = 1
    there (m2v's answer for MoltenVK); on Turnip it is m2v's answer from device addresses / descriptor indexing [I].
  - Change: flame/0011 (frontend + bridge), `userland/metal/plugin/negroni_msl.h`, `userland/metal/probes/mslprobe.c`,
    knobs `NEGRONIMETAL_MSL_FRONTEND` (inproc default | xpc | 0), `_OPTIONS`, `_DRIVER`, `_RESOURCE_DIR`,
    `NEGRONIMETAL_GPUCOMPILER`; crash marker `strikes/msl-<process>`. Texture/sampler `gpuResourceID` = m2v's resource ID.
    WebGPU selector gap now 0 (selector-gap.py --client WebGPU); QuartzCore still 0.
  - Open [I]: WebKit GPU process crash 23:51:13 (pid 300): pc `_platform_strcmp`, lr NegroniMetal+0xa6f8 (23:51 build),
    on a libdispatch worker (dispatch source), far in the guard page after another thread's stack: a pointer to a dead
    stack buffer read by a plugin/frontend timer or source handler. Not symbolicated (that binary is gone); may be the
    real cause of the Safari GPU-process restarts.
  - Open: indirect command buffers (m2v has them, indirect_command_buffer.rs; not bridged), indirect draws not run on any
    GPU here (only the dispatch).

- Widget/poster crash triage, MPS conformance (2026-10-26 13:17-13:47, Metal crash agent; flame/0012; bundle sha256
  0e8450f8…6e07fd pushed 13:43, strikes cleared, backboardd/SpringBoard NOT restarted: SpringBoard pid 26 still runs f5e4690a):
  - [V] Boot 13:17-13:31 (`logs/usblog.log`), every CRASH line: driverkitd sig 9 (jetsam ns 1 code 7, before any Metal),
    assetsd sig 6 x4 (pre-existing), FitnessWidget sig 9 x3 (jetsam per-process limit, 0.3 s after its first command buffer),
    AegirPoster sig 6 x14 (2 s loop, see below), SpringBoard sig 11 x1, com.apple.WebKit.WebContent[300] sig 10 x1. No CRASH
    for chronod, PosterBoard, SpringBoard's other widget hosts, WeatherWidget, CalendarWidgetExtension (they never load Metal).
    The CrashReporter directory has no .ips of this boot (`Failed to send exception EXC_CORPSE_NOTIFY` on every crash).
  - [V] SpringBoard 13:24:43 (the owner's side-button press = Siri): stderr `[MPSCommandBufferImageCache
    initWithCommandBuffer:computeEncoder: commandBuffer does not conform to the MTLCommandBuffer protocol`, then SIGSEGV far 0x18
    at `MPSAutoCache::MPSAutoCache(id<MTLCommandBuffer>, id<MTLTexture>)+156` <- MPSCore func_1d3fe7f58 <- `-[SUICOrbView
    _drawSiriFrame:]+940` <- CA DisplayLink (`ipsw dyld a2s`, slide 0x171e0000). Cause: the flame NB* classes never declared
    the Metal protocols (only NBFunction, NBArgumentEncoder); MPS answers nil and dereferences it. A SpringBoard crash restarts
    the whole UI (every widget host and poster extension with it) = "widgets vanish".
  - Change flame/0012 (`userland/metal/patches/flame/0012-negroni-metal-protocol-conformance.patch`): class_addProtocol of the
    20 public protocols at device creation, by `@protocol()` literal (objc_getProtocol by name found 15 of 20 on the phone:
    20H392 Metal registers MTLCommandBuffer but not MTLCommandQueue/MTLHeap/the 3 encoders); log `native-metal: Metal protocols
    adopted by 20 of 20 frontend classes` [V phone 13:43:20]. Plus what MPS sends next (host test, 20H392 MPSCore objc refs):
    `heapTextureSizeAndAlignWithDescriptor:`, `heapBufferSizeAndAlignWithLength:options:` (estimates: runtime bytes-per-row,
    all levels/slices/samples, 16 KiB aligned) and no-ops `memoryBarrierWithResources:count:`, `setImageblockWidth:height:`,
    `setStageInRegion:`. Host test case `mps` (scripts/metal/host-plugin-test.sh): 7 objects conform, MPSImageGaussianBlur
    through the device on MoltenVK completes (status 4) [V]. [I] On the phone MPS kernels are Apple-GPU AIR; whether the Siri
    orb renders is untested (needs a SpringBoard restart: `p=$(ps -A | grep '[/]usr/libexec/backboardd' | ...); kill -9 $p`).
  - [V] AegirPoster: this boot it aborted 4 times WITH a device (pids 333/334/341/342, 13:24:04-13:24:15, each < 1 s after
    `device opened`, bt `_objc_terminate` <- FBSSerialQueue block), then dead-man 4/4 -> no device -> the known nil `_device`
    abort every 2 s (PosterBoard relaunches; 14 crashes in 7 min). No MISSING or refused line, no exception text (extension
    stderr never reaches the kernel log). Change NegroniMetal.mm: `NSSetUncaughtExceptionHandler` installed when the device opens
    (chains the old handler): `uncaught exception NAME: REASON` + 10 frames through nlog. Next AegirPoster start tells why.
    [I] The loop itself only stops when the first abort is fixed; a refusing stand-in device would hide it.
  - [V] com.apple.WebKit.WebContent[300] 13:25:01 sig 10 (KERN_PROTECTION_FAILURE): pc `WebCore::JSDOMConstructor<JSBlob>
    ::construct+440` = `str w8,[x21]` (WTF refcount decrement) with x21 = 0x21203eec0, inside the dyld cache __TEXT (unslid
    0x1fae5eec0, the cstring "Error building SystemDialogAct: "), map 0x212000000-0x214000000 prot r-x/r-x tag 35
    (VM_MEMORY_UNSHARED_PMAP). A wild pointer in JSC/WebCore, not a GPU mapping (WebContent never loads NegroniMetal: no NMTL
    line, no `RedwoodGPU: opened by ...WebContent` ever) -> class (d) iOS-port issue. [I] The WebGL page went blank because this
    process died; WebGL itself runs in com.apple.WebKit.GPU (it opened the device in both boots, 13:20:18 and 13:34:15,
    pipelines compiled, no refusal; `UseGPUProcessForWebGLEnabled` exists in 20H392 WebKit). The f5e4690a bundle had no
    `newLibraryWithSource:`; the pushed one has flame/0011. Not retested with the page (owner needed).
  - [V] FitnessWidget: jetsam ns 1 code 7 each start, with `nil render pipeline` (0 pipelines made). [I] Untested whether the
    plugin's allocations (21 MB bundle + 11 MB Turnip + m2v/Vulkan heap) push it over the widget-extension limit; the
    experiment is `printf '*\n-FitnessWidget\n' > /var/db/negronimetal/clients` and a relaunch.
  - [V] The phone was rebooted at 13:31:43 by a `NEGRONI CTL: "reboot" from 192.168.7.1` (not this agent). Boot UUIDs differ
    per boot (6694732D… -> D459CB59…), so old strike files reset as designed. Phone clock = host time - 12.5 h (the `ls`
    dates in /var/db/negronimetal are phone time).
  - Push: `scripts/metal/phone-test.sh push` replaces `/System/Library/Extensions/NegroniMetal.bundle/{NegroniMetal,Info.plist,
    libvulkan_freedreno.dylib,clients,_CodeSignature/}`, `/usr/local/bin/{vkprobe,metalprobe,mslprobe,m2vtest,carenderprobe,
    layerprobe,metallib-sweep.sh}`, `/usr/local/share/negronimetal/{layerprobe.metallib,metallibs.txt}`; keeps
    `/var/db/negronimetal/{clients,env}`. Verified `/var` still a symlink, metalprobe PASS, `20 of 20` line.

- Blank Calendar/Weather widgets (2026-10-26 13:57-14:03 boot, Metal crash agent): not a crash, not Metal.
  - [V] Boot 3 (13:57): chronod started 13:58:01, pkd 13:58:08, extensionkitservice launched LockScreenPeopleWidget, the
    poster extensions and FitnessWidget; `exec CalendarWidgetExtension` / `exec WeatherWidget` never appeared in 33 min
    (boot 1 had both 15 s after chronod). No `|chronod|`, `|runningboardd|` or Sandbox line about them. Both appex bundles
    are on the root; calaccessd and dataaccessd run; weatherd's plist points to
    /System/Library/PrivateFrameworks/WeatherDaemon.framework/weatherd (not in DROP). chronod's DB
    (/var/mobile/Library/chronod/chrono.sql, copied): ExtensionMetadata lists com.apple.weather.widget and
    com.apple.mobilecal.CalendarWidgetExtension; WidgetConfigs `SpringBoard-Homescreen` hosts Calendar, Maps, ScreenTime,
    Notes, Photos, News, Stocks, Tips, Weather. CalendarWidgetExtension never loads Metal (no NMTL line in any boot) and
    WeatherWidget neither: a Metal/GL cause is excluded for these two.
  - [V] Experiment `kill -9 chronod` (14:01:18): the new chronod (device ok, strike cleared) launched LockScreenPeopleWidget
    and CalendarWidgetExtension (alive, 9 s CPU) within 2 s, FitnessWidget (jetsam x3) - and still no WeatherWidget, Maps,
    Notes, Stocks, Tips, News after 90 s. [I] chronod reloads only the timelines it considers due; the others come from its
    snapshot cache, which may hold the "placeholder/unable to load" image from an earlier boot.
  - [I] Weather needs weatherd + network (no Wi-Fi): a placeholder is expected by design. Calendar: its extension ran after
    the restart; whether it then rendered is unknown (phone sent to the bootloader at 14:03:02 by the host before the owner
    could look). Next: `scripts/net/phone-log.sh chronod WeatherWidget CalendarWidgetExtension` (unified log: WidgetKit says
    why a timeline fails), then `kill -9` chronod and read the lines; clear the snapshot cache
    (/var/mobile/Library/Caches/com.apple.chrono*) if stale images are suspected.

## CoreImage/PosterBoard crash (analysis 2026-10-25; addresses = unslid 20H392 cache, slide 0x1f750000 in logs/usblog-20261024-235438.txt)

- [V] SpringBoard sig 11 pc 0 lr 0x194b3858c: `CI::GLContext::init` 0x194b384c0 calls `_GetMacroContext` -> `_wrapGetMacroContext` 0x194b32614, which bzero's a 0x2c8 dispatch table and leaves it zero when `-[EAGLContext getMacroContextPrivate]` returns NULL; init only logs (`ci_logger_render`) and then calls table+0xe8 with w1=0xb71 (glDisable(GL_DEPTH_TEST)) = NULL (ipsw disass).
- [V] `CI::GLContext::GLContext` 0x194b38730 makes its own EAGLContext (API 3, then 2) via `_wrapEAGLContextCreate` 0x194b3210c and stores it without a nil check: making EAGL init fail does NOT stop the crash.
- [V] `-[CIContext initWithOptions:]` 0x1949a2f1c: returns nil only if `can_use_metal()` and `_CIGLIsUsable()` are both false; `_wrapGLIsUsable` 0x194b31ee0 is `mov w0,#1; ret`, so on iOS 16 GL is always "usable".
- [V] Order in initWithOptions: Metal (`CIMetalCopyDefaultDevice` = MTLCreateSystemDefaultDevice when `CI_ENABLE_METAL_GPU` != 0) -> else if the option `kCIContextUseMetalRenderer` is absent or false -> `internalGLContextWithOptions:` -> `internalContextWithEAGLContext:options:` 0x1949e1640. If the option `kCIContextUseMetalRenderer`=YES and there is no Metal device, it returns nil (clean failure).
- [V] iOS 16 CoreImage has no CPU renderer: the only context vtables are `CI::MetalContext` and `CI::GLContext`. `kCIContextUseSoftwareRenderer` ("software_renderer") only sets "priority_request_low" (initWithOptions 0x1949a2f94..0x1949a3008).
- [V] CoreImage env vars come from getenv (`CI_ENABLE_METAL_GPU` block 0x194a10d64); none of the ~90 `CI_*` names turns off GLES. `CI_ENABLE_METAL_GPU=0` forces GLES (worse). No defaults domain switch was found.
- [V] `CI::GLContext` is built only from `internalContextWithEAGLContext:options:` (ipsw xref of C1 0x194b38958); its callers handle NULL: initWithOptions (cbz -> nil) and `-[CIContext initWithEAGLContext:options:]` (`_initWithInternalRepresentation:` 0x1949e1dac returns nil for NULL).
- [V] CoreUI path: `+[CUIShapeEffectStack sharedCIContext]` -> `contextWithOptions:` (CoreUI passes `kCIContextUseSoftwareRenderer`, ineffective). With a nil context, `_newFlattenedImageFromShapeCGImage:withScale:ciContext:blendOverImage:` 0x19ef088dc still returns a CGImage from a `CGBitmapAllocateData` buffer that CI never writes. `-[UIImage _imageWithStylePresets:tintColor:traitCollection:]` handles a nil styled image (NSLog, returns the original image, 0x1896eaeec).
- [V] Other CoreUI users of sharedCIContext: CUITextEffectStack drawProcessedMask, _CUIGraphicVariantVectorGlyph, _Draw{One,Three,Nine}PartImage, CUIThemeFacet. Any UIKit process (Settings, apps) can reach the same GL crash, not only SpringBoard.
- [V] launchd 20H392 `/sbin/launchd`: the env-var filter at 0x10001a720 flags `LD_LIBRARY_PATH` and every `DYLD_*` except a table of `DYLD_PRINT_*` names. The caller 0x1000092dc skips the var ("Disallowing environment variable: %s") unless job flag bit 39 (byte 0x56c bit 7) is set. 0x100008b34 sets that bit only when the Label does NOT start with "com.apple." (otool -tV).
- [I] So `DYLD_INSERT_LIBRARIES` in launchd.plist EnvironmentVariables of com.apple.SpringBoard / com.apple.backboardd / com.apple.PosterBoard is probably dropped by launchd. This also affects `scripts/gpu/root-add-negronigl.sh` (backboardd). Check on the phone: unified log of launchd for "Disallowing environment variable".
- [V] FrontBoard `+[FBApplicationProcess _internalDebugEnvironmentVariables]` 0x1a266bbf0 is merged into every app launch environment (`_createBootstrapContext` 0x1a266a644, no internal-build check). It reads the `com.apple.frontboard` keys FBMallocStackLogging/Scribble/GuardEdges/CheckHeap/GuardMalloc/FB_ZombieEnabled/FBDYLD*, each also with an `...Always` variant. `FBGuardMallocAlways` adds `DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib` (not present in the root).
- [V] The running kernel lacks 0220-0223: the log has "privilege 1002 denied" and no "NEGRONI AMFI" line. So dyld's AMFI op 0x5a fails and DYLD_* variables have no effect in any process today.
- [V] PosterBoard sig 5 pc 0x1c1778268 = `brk` after the NSAssert "!_stateLock_switcherConfiguration" in `-[PBFPosterExtensionDataStore _stateLock_setupSwitcherConfigurationForFirstTime]` 0x1c1777a70 (checks self+0x98 at 0x1c1777ab0; the second assert at 0x1c1778360 is "!_stateLock_initialExtensionsLoaded", self+0xe9).
- [V] `_stateLock_updateExtensions:...` 0x1c177ce48 calls setup when self+0xe9 (initialExtensionsLoaded) is 0 (0x1c177e2c4) and sets 0xe9=1 after it. Writers of self+0x98: setup itself and `_stateLock_updateDataStoreForSwitcherConfiguration:options:reason:error:` (0x1c17747cc).
- [V] `-[PBFPosterExtensionDataStore updateDataStoreForIncomingFocusModeChange:error:]` 0x1c17713c4 (XPC `server:notifyFocusModeDidChange:completion:`) builds and stores a switcher configuration with no initialExtensionsLoaded check. `server:updateToSelectedConfigurationMatchingUUID:...` does the same through updateDataStoreForSwitcherConfiguration.
- [V] The data store's first update normally comes from `posterExtensionProvider:foundExtensions:` (the `_EXQueryController` for `com.apple.posterkit.provider`). The other triggers are prewarm and the overnight update.
- [I, strong] PosterBoard loop: extension discovery never calls back (empty ExtensionFoundation catalog: no AMFI op 0x60, bergamota docs/EXTENSION_CACHE.md, same 20H392). A SpringBoard XPC (focus mode / selected configuration) stores a switcher configuration first. Then the prewarm XPC runs the first update -> setupForFirstTime -> assert. This matches slop NOTES (no .appex ever starts, LS cache without the 10 providers).
- [I] Fix for Crash 2: a kernel with 0221 (bits 1+2: op 0x60, AMFI IOService) and 0223, plus a LaunchServices re-seed. A fresh root has no LS cache (this root: no private/var/mobile/Containers/Data). An already-booted userdata needs `.../Containers/Data/InternalDaemon/*/Library/Caches/com.apple.LaunchServices*` deleted (bergamota). Without the re-seed, bergamota saw a different PosterBoard crash (NSInvalidArgumentException, nil in dictionaryWithObjects in the same setup method). slop's negroni-poster-register (registerPlugin for the 10 providers) stays a fallback, not proven.
- [V] Crash 1 status: no fix implemented in this repo. The analysis above lists the hook points (internalContextWithEAGLContext:options:, CoreUI flatten) and the injection constraints for the owner to decide.

## Clock and clonefile (2026-10-25, patches 0203, 0204, 0212; details: patches/xnu/README-clock.md)

- [V] 1969 cause: `NegroniPlatformExpert` had no `getUTCTimeOfDay()`; `IOPlatformExpert::getGMTTimeOfDay()` returns 0 (iokit/Kernel/IOPlatformExpert.cpp:394).
- [V] `clock_initialize_calendar()` then sets the calendar to the uptime ("UTC is less then sys time"), so `1969-12-31 16:17` (Pacific) = epoch + 17 min uptime (osfmk/kern/clock.c:1052-1100, logs/usblog-20261024-235438.txt).
- [V] PMK8350 RTC: DT `rtc@6100` "qcom,pmk8350-rtc", reg `<0x6100 0x6200>`, no `allow-set-time` (out/live.dts:12621).
- [V] Linux rtc-pm8xxx.c pmk8350_regs: ctrl 0x6146 (bit 7 enable), write 0x6140, read 0x6148 (4 bytes LE), alarm_rw 0x6240; read = 4 bytes, re-read byte 0, again on carry; without allow-set-time the driver keeps an offset (nvmem/UEFI), never writes the counter (torvalds/linux master).
- [I] The raw RTC counter on this phone may not be wall time (Android time_daemon keeps the offset); not measured yet: the 0203 boot log prints it (`NEGRONI RTC: ... counter N s`).
- [V] 0203: `bsd/dev/negroni_rtc.c` reads the RTC through the v7 arbiter observer (header negroni_spmi_keys.h, as the keys driver), never writes the PMIC; wall = counter + offset (boot-arg `negronirtcoff`, else `/private/var/db/negroni_rtc`); floor = build date - 1 day; `negronirtc=0` = no PMIC access (source).
- [V] 0203: settimeofday and USB settime reach `negroni_rtc_set()` through `PESetUTCTimeOfDay()`; a thread call saves the offset file, retry every 30 s x 60 while the root is read-only (source).
- [V] 0203: IOKitInitializeTime (NEGRONI) waits up to 10 s for the platform expert, else the calendar would read 0 (source).
- [V] 0212: USB commands `settime <s>[.<frac>]` and `time` on UDP 5141; host: `op10tool ctl settime|time`; `scripts/debug/usblog.sh` sends settime on each interface up (`USBLOG_SETTIME=1` default) (source).
- [V] 0212 is a separate patch because dxb applies patches in name order and 0203 comes before 0210 (the command server) (out/kernel/local/dxb/build.sh:472).
- [V] `hfs_clonefile` is not clonefile(2): it is step 2 of `hfs_relocate()` (copy a file's data to new blocks inside the file); callers: defragment-on-open in `hfs_vnop_open()` (8+ extents, after 3 min uptime) and hot files (bsd/negroni_hfs/core/hfs_readwrite.c:5440, hfs_vnops.c:634).
- [V] ERANGE source: `hfs_vnop_blockmap()` returns ERANGE for a read at/after EOF (hfs_readwrite.c:3346); `cluster_write_copy()` pre-reads `[trunc_page(writebase), oldEOF)` when the write starts mid-page (vfs_cluster.c:3758), and that range is past EOF.
- [V] Why only here: writebase = block count x 4 KiB is often not 16 KiB-page aligned on this 16K kernel; with 4 KiB pages it is always aligned (source analysis).
- [V] `negroni_ufs.c` answered DKIOCISSOLIDSTATE with ENOTTY, so HFS had no HFS_SSD and relocation/hot files were on (hfs_vfsops.c:1298, hfs_readwrite.c:5487).
- [V] Error count: 5 in usblog-20261024-195455.txt, 85 in usblog-20261024-235438.txt at ~7 s intervals (grep).
- [I] The ~7 s rhythm is the SpringBoard crash loop re-opening one fragmented file; each failure is restored (truncate to ff_size), no data loss.
- [V] 0204: `negroniclone` bits (default 3): bit 0 = DKIOCISSOLIDSTATE 1 (HFS_SSD: no relocation, no hot files); bit 1 = 16K-safe hfs_clonefile (first chunk ends on a page boundary, oldEOF = max(trunc_page(writebase), ff_size)); 0 = stock (source).
- [V] All patches/xnu/0*.patch apply in name order on base a5b0203 except 0231 (NegroniFramebuffer.cpp:207, not touched by 0203/0204/0212) (`git apply --check`, 2026-10-25).
- [V] Full local build with 0203/0204/0212 (2026-10-25 04:50-04:54 local, Xcode 15.4): exit 0, `out/kernel/local-20261024-232438/kernel.development.negroni` sha256 69af8f1a00679ce9..., all 02xx applied except 0231 (another agent's patch, NegroniFramebuffer.cpp:207); strings "NEGRONI RTC: boot calendar", "NEGRONI HFS: clonefile", "NEGRONI UFS: solid state" present (logs/kernel-local.log).
- [V] Worktree `out/kernel/wt-clock` (branch `clock`): d1ccc64 = 0200+0210+0211, 19b3cc4 = 0203, 8fe5eac = 0212, ccc6719 = 0204. Not tested on the phone yet.

## Battery (2026-10-25, patches 0270-0271; details: patches/xnu/README-battery.md)

- [V] In `base` no IOPMPowerSource is registered: slop 0089 removed the NegroniBattery personality from iokit/KernelConfigTables.cpp; the class is still compiled (iokit/conf/files.arm64).
- [V] The old NegroniBattery is the sweet PM6150 driver: SID 0 0x1006/0x1007/0x100d/0x110b/0x1310/0x48c0; on SM8450 SID 0 is PMK8350 and 0x1300 is PON (keys) (out/live.dts pon_hlos@1300).
- [V] The old bsd/dev/negroni_spmi.c used sweet arbiter v5 addresses (core 0x0c440000, obs 0x0e600000, cnfg 0x0c40a000) and rejected versions >= 0x70000000; SM8450 is v7 (live DT qcom,spmi@c42d000 reg list: cnfg 0xc42d000, core 0xc400000, chnls 0xc500000, obsrvr 0xc440000, intr 0xc4c0000).
- [V] The old class published CurrentCapacity/MaxCapacity in mAh; iOS UI readers want percent with MaxCapacity 100 (bergamota 0130, HackiOS RedwoodBattery.cpp).
- [V] Battery: 2S (two cells in series), 5000 mAh (DT qcom,vbatt_num 2, qcom,batt_capacity_mah 0x1388; OnePlus oplus_battery_sm8450.c DOUBLE_SERIES_WOUND_CELLS).
- [V] Fuel gauge: external gauge IC read by the ADSP (DT qcom,battery_charger: qcom,external_gauge, qcom,fg_info_package_read_support, oplus,chg_ops "plat-pmic"); out/live.dts has no I2C gauge node; none of the gauge compatibles in stock oplus_chg.ko/oplus_chg_v2.ko (bq27541, bq28z610, zy0602/3, sh366002, nfg8011b, cw2217) is in the DT (strings + grep).
- [V] OnePlus official source (OnePlusOSS android_kernel_modules_and_devicetree_oneplus_sm8450, branch oneplus/sm8450_v_15.0.0_oneplus_10_pro, oplus_battery_sm8450.c) reads the gauge through GLINK only: OEM opcode 0x10000, data[0] temp 0.1 C, [1] current uA, [2] voltage uV, [3] SoC hundredths %, [4] remaining mAh per cell, [5] cycles, [6] FCC.
- [V] OnePlus battmgr property enum = upstream sm8350 for 0..23 (CAPACITY 4, VOLT_NOW 7, CURR_NOW 9, TEMP 12, CHG_COUNTER 14, CYCLE_COUNT 15, CHG_FULL_DESIGN 16, CHG_FULL 17); owner 32778, get opcodes 0x30 battery / 0x32 USB / 0x34 wireless (oplus_battery_sm8450.h).
- [V] HLOS-reachable battery data = PMK8350 VADC (ADC7) at SID 0 0x3100: 0x38f vbat_sns 1/3, 0x38e vph_pwr 1/3, 0x311 usb_in_v_div_16 1/16, 0x3a1 ichg_fb 1000/305185, 0x317 iin_fb 32/100, 0x310 chg_temp, 0x146 hot_pocket_therm (OPLUS skin_temp_chan) (live DT vadc@3100).
- [V] No battery NTC channel exists in the ADC7 HLOS list; PM8350B charger/QBG are not in the HLOS DT (only temp-alarm 0xa00, PBS 0x1900, BCL 0x4700, GPIO 0x8800, haptics 0xf000, AMOLED 0xf800-0xfa00).
- [V] ADC7 conversion needs writes (Linux adc7_configure): 0x40 APP_SID, 0x42-0x45 params/channel/settle, 0x47 CONV_REQ 0x80; result 0x50/0x51; volts = code * 1.875 V / 0x70e4 * den / num (qcom-spmi-adc5.c, qcom-vadc-common.c).
- [I] The 1/3 VBAT value is the mean cell voltage (ADC max 1.875 V x 3 = 5.6 V cannot see a 6-9 V pack; either 1S-side node or a 1/6 hardware divider on the pack); `negronibatt=2` logs vph and the 2S midpoint (0x396) to settle it.
- [V] PM8350B BCL (SID 3 0x4700, DT bcl@4700 "qcom,bcl-v5", qcom,pmic7-threshold) is readable without writes: 0x46 MONITOR_EN bit 7, 0x72 VBAT_CONV_REQ, 0x76 VBAT_READ 49.827 mV/bit (0x7f = none), 0x86 IBAT_READ s8 x 78.127 mA (range factor 10, + = discharge, 0 = no new reading); Linux writes MONITOR_EN = 0x80 at probe (OnePlus SM8450 downstream drivers/thermal/qcom/bcl_pmic5.c).
- [V] DT pm8350b-ibat-lvl0 trip 9000 mA on sensor <0x590 0> = the SID 3 BCL (out/live.dts:9570).
- [V] A second BCL exists on PM8350C (SID 2 0x4700); 0271 does not use it (DT).
- [V] 20H392 powerd matches "IOPMPowerSource" and reads CurrentCapacity, MaxCapacity, AppleRawCurrentCapacity, AppleRawMaxCapacity, IsCharging, FullyCharged, ExternalConnected, ExternalChargeCapable, AppleRawExternalConnected, BatteryInstalled, Voltage, Amperage, InstantAmperage, Temperature, CycleCount, DesignCapacity, NominalChargeCapacity, TimeRemaining, AtCriticalLevel, AdapterDetails, BatteryData, PermanentFailureStatus, BatteryCellDisconnectCount (strings of /System/Library/CoreServices/powerd.bundle/powerd); no "AppleSmartBattery" string. 0271 publishes all of them.
- [V] 0270 (final): `negroni_spmi_arbiter()` maps the arbiter once (core 0x3000, EE 0 observer 0x8000, cnfg 0x1000) for the RTC (0203 `nc_init` now calls it) and the battery; reads use `sk_read8` of negroni_spmi_keys.h (SK_POLLS bounded); a timed-out APID is not used again; writes are locked (only modes 4/5 unlock the ADC7 request registers 0x3140-0x3145/0x3147 when EE 0 owns the VADC APID; each write waits at most 2000 x 1 us) (source).
- [V] 0270 read allowlist: SID 3 0x47xx, SID 0 0x31xx, SID 3 offsets 0x04/0x05/0x10. No other driver uses a SID 3 APID or 0x031 (keys 0x013/0x18d, reboot 0x071/0x008, RTC 0x061): grep of all patches. The old census also read SID 1 = the keys' GPIO 0x18d channel (a race with the key thread): removed.
- [V] 0271 boot-arg negronibatt: 0 = no power source (old kernel), 1 = read-only BCL estimate (default), 2 = 1 + raw line per poll + SID 3 census + INT_RT_STS change lines, 3 = static 100 % on AC (no PMIC access), 4 = 1 + VADC conversions (writes the ADC7 request registers), 5 = 4 + the diagnostics of 2; log prefix `NEGRONI BATTERY:` (source).
- [V] 0271 uses the BCL values only when MONITOR_EN bit 7 is set; it never writes it. With the monitor off and no VADC the service publishes the static 100 % on AC and says why after 3 polls (source).
- [I] Nobody sets BCL MONITOR_EN without Linux, so it may be 0 after the Mu/UEFI boot: then only `negronibatt=4/5` measure. The first `negronibatt=2` log shows the value.
- [I] Which node the BCL sees on the 2S pack (1S side or the pack) is not known; VBAT > 5000 mV is halved, and the coulomb count assumes 1S-side current with 5000 mAh.
- [V] 0270 and 0271 apply on a patched-tree.sh tree of all patches up to 0261 + 0213 (out/kernel/tree-battery, 2026-10-25); compile-one.sh OK for negroni_spmi.c and negroni_rtc.c; NegroniBattery.cpp has no diagnostic with its clang++ line from build.log.
- [V] The USB driver forces VBUS valid (negroni_usb.c UTMI_OTG_VBUS_VALID), so USB cannot tell a charger; not used.
- [V] Full build 2026-10-25 (`scripts/bg.sh kernel-battery scripts/kernel/build-local.sh`, battery agent): exit 0, `out/kernel/local-20261025-130140/kernel.development.negroni` sha256 f5c01805913a5ed4..., patch-report: all 27 patches/xnu applied (0200-0261, 0270, 0271, 0290; with the io-fix agent's uncommitted 0234/0240/0260/0261), only the 4 usual dxb skips; strings `NEGRONI BATTERY: SPMI arbiter`, `NEGRONI RTC: PMK8350 RTC APID` and the NegroniBattery personality are in the kernel. `out/kernel/kernel.macho` points to it. Not booted.
- [I] Phone test: boot-args + `negronibatt=2`; check the arbiter/BCL lines (MONITOR_EN, VBAT_CONV_REQ), `raw bcl` vbat 3300-4450 mV, ibat sign on battery/charger, the RTC line still there, the status bar percent; if MONITOR_EN is 0, try `negronibatt=5` (VADC). Details: README-battery.md section 4.
- [I] Without the ADSP nobody configures the PM8350B charger; whether it charges at all is unknown: the `ibat` sign (BCL) or `ichg` (VADC modes) in the 0271 log shows it.
- [I] Exact SoC needs the ADSP charger PD (GLINK PMIC_RTR_ADSP_APPS, after the audio ADSP work); README-battery.md section 6 lists the messages.
- [V] 2026-10-26 phone (kernel 182812, mode 1): the BCL works: `NEGRONI BATTERY: 73% 4085mV -78mA ... source=PM8350B BCL` (22:47-01:31). With the USB cable in all night the pack went 73 % -> 16 % (01:31, -458..-1894 mA); at 68-73 % with `external=1` the net current was only +0..78 mA. The phone then died (02:05, no USB) and was in fastboot at 03:13 (another agent) [logs/usblog.log].
- [I] So the PM8350B charger takes little or no USB input under our kernel: nobody configures it (the ADSP charger PD is off), XBL/ABL leave an SDP limit (DT `qcom,input_current_usb_ma` 500) or USBIN suspended, and the system draws more than that (CPU top rows + GPU 818 MHz, no idle). `usbin=0mV` in mode 1 means "not measured", not "no VBUS".
- [V] Slop 0074 (USB VBUS override) sets only the DWC3 PHY's UTMI_OTG_VBUS_VALID/SW_SESSVLD_SEL bits (negroni_usb.c QSCRATCH); it cannot affect the PMIC charger.
- [V] 2026-10-26 patch 0272 (`patches/xnu/0272-negroni-battery-charger-input.patch`, README-battery.md section 7): SID 3 0x10-0x16 (SMB5 CHGR..MISC) readable; `negroni_spmi_chg_unlock()` opens 0x1042/0x1340/0x1342/0x1365/0x1366/0x1370; `NegroniBattery` logs the charger registers (`charger <state>, USBIN plugged|unplugged[, USBIN SUSPENDED]: st1 .. icl_cfg .. icl_sts .. power_path ..`) and, with `negronichg_ma` (default 500, 0 = read only), writes the input limit, USBIN_MODE_CHG, ICL override, un-suspend and charging enable in the downstream order, at most 5 polls per plug. `ExternalConnected` = USBIN_INT_RT_STS bit 4. Boot-args `negronichg_step` (50|25), `negronichg_force`.
- [V] 03:31 phone with `out/ios16-chg`: `chg=? icl=0mA pp=ff`: none of the SMB5 registers read; the boot-time reason lines are not on USB (console attaches at ADRENO step 21). DT: pm8350b@3 is on bus 0 (`qcom,spmi@c42d000`), HLOS node without the charger blocks; a bus-1 arbiter node (`qcom,spmi@c432000`) and `qcom,spmi-debug@10b14000` (pmic-arb-debug, EE-independent) exist. 0272 amended: per-poll `charger diag` (APID/owner per block 0x10-0x16, reason per read), `SID 3 PPIDs in the APID map` every 3rd poll, `setup (poll n)` in polls 1-3 and every 15th (README-battery.md section 7).
- [I] The SMB5 register layout and the 50 mA/LSB step on PM8350B are inferred from PM8150B (`smb5-reg.h`) and bergamota's SMB2 notes; no public PM8350B HLOS charger driver exists. The first `charger` line on the phone validates it (values must decode; `icl_sts` half of the request = 25 mA step).
- [V] 2026-10-26 charger ownership (README-battery.md section 8): the ADSP charger PD owns the PM8350B charger. DT `qcom,pmic_glink` (out/live.dts:6637, channel PMIC_RTR_ADSP_APPS, protection domain msm/adsp/charger_pd) holds `qcom,battery_charger`; no qpnp-smb5 node; OnePlus `oplus_battery_sm8450.c` has 0 regmap/SPMI calls and sets ICL (`usb_psy_set_icl` :2548), charge enable (:8285) and reads VBUS (:9477) only over GLINK. Linux spmi-pmic-arb.c: observer reads work for any owner if the PPID is in the APID map (:1124), writes need write_ee == ee (:1128).
- [V] 0272 register errors (smb5-reg.h): ICL_STATUS/AICL_ICL_STATUS/POWER_PATH_STATUS are DCDC 0x1107/0x1108/0x110b, not 0x1607/0x1608/0x160b (SMB2 offsets); HC mode needs CMD_ICL_OVERRIDE 0x1342 bit 0 = 0 (smb5-lib.c:165 SW_OVERRIDE_HC_MODE), 0272 wrote 1. Fixed in 0273.
- [V] `usbin` = VADC channel 0x311 pm8350b_usb_in_v_div_16 1/16 (live.dts:12406), correct in NegroniBattery; measured only with negronibatt=4/5. The phone logs were mode 1, so `usbin=0mV` meant "not measured"; 0273 prints `usbin=-` then.
- [V] Debug arbiter `qcom,spmi-debug@10b14000`: `qcom,fuse-enable-bit = <0x12>` at 0x221c8784 (bus usable only when bit 18 is SET), clock = AOSS QMP "qdss" (power-controller@c300000, message `{class: clock, res: qdss, val: 1}`, op-kernel qcom_aoss.c:286-288). Registers: spmi-pmic-arb-debug.c (CMD0-3 0x00-0x0c, STATUS 0x14, WDATA 0x18, RDATA 0x38; opcodes 1 read, 0 write). The fuse value on this phone is unknown [I].
- [V] Patch 0273 (`patches/xnu/0273-negroni-charger-debug-arbiter.patch`; kernel out/kernel/local-20261026-073259 sha256 461b94bc..., image out/ios16-chg2 boot_a sha256 baa05286..., `negronibatt=5`, not booted): `negronichg_arb=auto|normal|debug` (default auto), route chosen at poll `negronichg_route_poll` (3); debug path = fuse check, QMP QDSS vote, check read of BCL 0x4704 vs the normal path; only SID 3 0x10-0x16 use it; writes still only the six 0272 registers and only with `negronichg_ma` > 0; `negronichg_dbgfuse=0`, `negronichg_qdss=0`; read-only with `negroniadsp` set unless `negronichg_force=1`; review fixes: status-error log capped at 8 lines, 32 consecutive errors close the path, fuse read announced + 200 ms sleep, no QDSS vote (and no debug path) while `negroniadsp` is set (0240 shares the QMP mailbox, no lock), `negronichg_arb=debug` never writes through the normal path (closed debug path = control OFF), the 5 tries restart at the route switch (5 + 5 per boot), 0x1370 cap 60 at 50 mA/LSB / 120 at 25 mA/LSB. compile-one OK (negroni_spmi.c), NegroniBattery.cpp `-fsyntax-only` clean with the build's clang++ line; `git apply --check` OK on the 0272 state.
- [V] 2026-10-26 13:17-13:22 phone log (logs/usblog-20261026-131747.txt, negronibatt=5): SMB5 0x10-0x13/0x15 have no APID (0x14/0x16 are EE 4), debug arbiter fused off (0x221c8784 = 0x4900000, bit 18 clear). USB in: VBUS 4.87-4.94 V, iin 725-1000 mA (near 1000 mA under load), ibat 0..+146 mA idle, -351..-1289 mA under load; VADC 3693 mV/cell = fastboot battery-voltage 7382 (2S). [I] ~1 A default input limit, no net charge. `ichg` 35-95 A values are garbage (scale wrong).
- [V] The OnePlus HLOS sets the charger only through pmic_glink (oplus_battery_sm8450.c write_property_id :878; ICL = 0x33 USB_INPUT_CURR_LIMIT id 5 in uA :7822; BATT_CHG_EN = 0x31 id 24 :8285). OPLUS ids: battery 24 CHG_EN, USB 26 SUSPEND_PMIC, 47 USB_IN_STATUS (enum count, needs OPLUS_FEATURE_CHG_BASIC [I]). SoC on OxygenOS = OEM read buffer (opcode 0x10000) word 3 /100 because voocphy_support 1 = ADSP_VOOCPHY (:10727-10745). Downstream pmic_glink.c tells clients UP after the GLINK channel opens, not on PDR UP (:170-195, :547-556). Plan: docs/charger-glink-plan.md.
- [V] Patch 0274 (`patches/xnu/0274-negroni-charger-glink.patch` sha256 3512de92..., README-battery.md section 9): `negronichg_glink=1` (+ negroniadsp) opens GLINK channel 2 PMIC_RTR_ADSP_APPS (hunks in negroni_adsp.c/.h, new negroni_glink_open), client thread from NegroniBattery::start (waits 600 s for GLINK), 20 s poll of battery/USB props + OEM buffer, READY = channel open + a ret_code 0 read, then BC_SET_NOTIFY_REQ, a property dump, ICL ramp 500 mA steps to negronichg_ma (default 1500, cap 2000) with AICL back-off at 4500/4550 mV, un-suspend, BATT_CHG_EN=1 (5 tries per plug). NegroniBattery: `chg=glink icl=NNNNmA`, registry NegroniChargerGlink*. Kernel out/kernel/local-20261026-084835 (6acdaacf...), image out/ios16-chg3 boot_a 9286b5e3... Not booted.

- [V] 0276 (2026-10-26, percentage source; README-battery.md section 10): the "12 % -> 9 %" of the owner report was a reboot at 13:32:30 (two boots in logs/usblog.log); 0271 keeps no value across boots and the first value is the first sample's table value (boot 1: 3693 mV at +146 mA -> 11.5 %; boot 2: 3549 mV at -1240 mA boot load -> 9.1 %). Within a boot the value froze ("never down on a charger", net coulombs ~0 with the cable in).
- [V] True state on 2026-10-26 13:17-13:38: rest `vadc vbat` 3669 -> 3662 mV at 0 mA = 9.3 -> 8.8 % on the 0271 table; net -68 mAh / 14 min and -34 mAh / 8 min: the pack loses ~1 % per 10 min with the USB-C cable in (input ~1 A at 5 V covers the idle load only). `mid2s` = `vbat`: the VBAT pin is on the 1S side.
- [V] `raw ... soc NNNN` is our `fSoc` (1/100 %), not a PMIC register. No QG/QBG node and no OCV table in out/live.dts; OxygenOS takes the percent from the ADSP charger PD (`oplus_battery_sm8450.c:10727` read buffer [3], else `BATT_CAPACITY`; `qti_battery_charger.c:760`); the gauge IC (bq27541 family) is on an ADSP-only bus, no HLOS I2C node; our tree has no GENI I2C driver. So from the AP: GLINK (0274) or the OCV estimate.
- [V] 0276: source order glink (0274 `soc_centi`, fresh <= 3 min) > ocv (IR comp 80 mOhm, outlier reject 250 mV, filter 1/4 rest / 1/8 load, `kOcv` table, rate limit 1 %/30 s, monotonic with the filtered current, both ways at rest); the first value is the first sample's table value and stays until the pack reaches it or the phone rests (|I| < 50 mA); under a discharge current it cannot rise. Review fixes: ExternalConnected takes VBUS first (same source as the plug tick); a ready GLINK SoC is published even with no AP voltage; `charging`/`full` from the filtered current or the PD's BATT_STATUS; log `soc src=ocv|glink ocv=NNNNmV target=N.NN% avg=NmA`; registry `NegroniBatterySOCSource`, `CapacityEstimated` false with glink. compile-one OK (`compile-one.sh` now checks a `.cpp` of iokit/; `COMPILE_LOG=` picks another build log while a build runs).
- [V] 0276 plug latency: the owner saw 5-10 s before "charging" (one full read per 20 s). The timer now ticks every `negronibatt_fast` ms (1000): VBUS over the VADC (or the BCL current sign without the VADC); a change publishes ExternalConnected at once (`external 0->1 (usbin N mV) after N ms`) and runs the full read. No plug interrupt from EE 0: SMB5 USBIN rt_sts has no APID; census `rt_sts 327` (0x2710) bit 6 follows the load current (0xc0 above ~300 mA discharge), not the cable (14 toggles with the cable in).
- [V] 0276 applies with and without 0274 (hunks anchor on 0271-0273 lines; `#if __has_include("negroni_chg_glink.h")`). 0274 stopped applying at 13:41 (0242/0243 changed negroni_adsp.c:1644; rebased by its agent before 14:00). Build `kernel-soc3` (review fixes): out/kernel/local-20261026-084328 (sha256 20026d62...), 0274 + 0276 applied, 4 usual dxb skips; image out/ios16-soc (boot_a sha256 400f1f95..., `negronibatt=5 negronipanic=30 negronipanicreason=2`). Not booted.
- Lesson: a bg build job that ends with `rm -rf` of its tree deletes it even when the build "succeeded" with our patch SKIPPED; check the patch-report before trusting a kernel. The 13:43 kernel-soc build (local-20261026-081636, out/ios16-soc first version) had 0274 and 0276 skipped and was rebuilt.
- [V code] 0277 charge loop (README-battery.md s.11): after the 0274 READY, USB in, every 5 s (oplus_charger.c:110; `oplus_chg_update_work` :14580 -> `oplus_chg_protection_check` :10583 -> `oplus_chg_check_tbatt_is_good` :7950, FV+FCC on a band change :8028-8029; :7556-7558 is the FFC path, not the loop): BATT_TEMP -> JEITA band of live.dts:6681-6718 (removed/low/hot = BATT_CHG_EN 0; cold 4435 mV/600 mA; little_cold..normal 4435/1100; warm 4130/500) -> FV `BATT_VOLT_MAX` id 8 (mV, x2 pack as oplus_charger.c:7252, unit taken from the PD's own value, else no FV write) -> FCC `BATT_CHG_CTRL_LIM` id 10 (uA) = min(band, thermal level 3000/1500/1000/500 mA :6647); read back; logs on change only. Every value <= 4435 mV/cell and 1100 mA (bands_ok + per write). `negronichg_loop=0` = 0274 only.
- [V code] 0278 (README-battery.md s.12): fSoc kept in /private/var/db/negroni_batt (negroni_batt_store.c, the RTC-file way of 0203), used only within 15 % of the OCV estimate; `Temperature` = the PD's BATT_TEMP when fresh (60 s), estimated flag false then; skin + XO (VADC 0x44) to the 0277 hub; BCL MONITOR_EN 0x80 written only when it reads off (bcl_pmic5.c:779; the phone reads `mon 80` today); the 0273 QDSS vote released with `val: 0` (qcom_aoss.c:294-296) when the debug path ends.
- [I] Risk: the saved-percentage file lands where /private/var/db is at that time (the RTC file works there, usblog.log:318/7584).

## 15. GL driver loading on iOS 16 (GL agent, 2026-10-25) [V: 20H392 shared cache, unslid addresses]

- `eagl_init` 0x1d3f52444 (from -[EAGLSharegroup initWithAPI:sharedWithCompute:]): dlopens
  OpenGLES's GLEngine.bundle/GLEngine (in the shared cache), calls gliInitializeLibrary with the
  `IOAcceleratorES` (else `IOAcceleratorESLegacy`) service; GL_BORON=1 sets flag 0x20000000.
- It fills OpenGLES's `_gli_plugin` table 0x1e25b0da0 with 18 GLI entry points (gliChoosePixelFormat ...
  gliPresentViewES); needs gliGetVersion != 0 and a non-NULL pixel format from gliChoosePixelFormat,
  then sets `_eagl_initialized` 0x1e25b0e44.
- -[EAGLContext commonInitWithAPI:properties:] 0x1d3f513f0: private block 0x40e8 bytes, +0x20
  GLIContext, +0x28 inline GLI dispatch 0x2060 bytes (1036 slots = NGL_SLOTS), +0x2088 second dispatch;
  calls gliCreateContextWithShared; nil sharegroup -> nil context.
- **The renderer plugin (the normal driver route):** libGFXShared `gfxInitializeLibrary` 0x1d3f6e2f0
  reads the IORegistry property **`IOGLESBundleName`** of each accelerator service
  (`IOGLESMetalBundleName` if com.apple.opengl UseMetal or `IOGLESDefaultUseMetal`), dlopens
  `/System/Library/Extensions/<name>.bundle/<name>`, calls `gldInitializeLibrary(services, iodata, mask,
  getSurfaceProps, getNewSurface, flags)`; needs `gldGetVersion` != 0 with (4, 1, 0x10, d & 0xffff00ff == 0)
  and all **129** names of `_gfx_gld_names` 0x1dabc2c20 via dlsym, else the plugin is dropped (0x1d3f6ea14).
- Today: no service has IOGLESBundleName -> no renderer -> nil EAGLContext -> CoreImage calls a zero
  dispatch (the Bold Text crash). Plan: 0205 adds IOGLESBundleName="NegroniGL" to IOAcceleratorES;
  ship NegroniGL.bundle as a GLD renderer plugin backed by Mesa (GPU, or softpipe without GPU).
- Open question [I]: GLEngine (Apple's GL front end) sits on top of the GLD plugin; the plugin must
  give GLEngine a renderer it accepts (pixel format + context), so the GLD interface must be implemented
  for real, not stubbed. CoreImage retries API 3 then API 2; CA may not retry.
- Answer [V] (GL agent round 2, out/gpu/re): GLEngine needs a real GLD renderer (a 25-entry render dispatch that
  reads GLEngine state); stub gld functions cannot make GLEngine contexts work.
- [V] gfxInitializeLibrary: plugin function table at +0x420 + 8 x (index in plugin/gld-names.txt).
  gldCreateDevice(&dev+0x18, mask, &dev+0x20), device ID at +0x10. A pixel format needs +8 = device ID and +0xc bit
  0x100 (API 3 also 0x20000). gfxCreateSharedState calls gldCreateShareGroup, which must return 0.
- [V] EAGL uses these GLI entries: CreateContextWithShared, DestroyContext, SetInteger, GetInteger, BindViewES,
  PresentViewES, ChoosePixelFormat, DestroyPixelFormat, GetVersion. texImageIOSurface: = gliSetInteger(0x38e,
  {surface ID, target, internal format, w, h, format, type, plane, 0}) then gliSetInteger(0x399, {target, invert}).
  Context flags 0x10/0x20/0x40 = API 1/2/3. getMacroContextPrivate returns priv+0x20.
- State (2026-10-25, not built): negronigl.c picks freedreno (RedwoodGPU opens) or softpipe (NEGRONIGL_DRIVER, boot-arg
  negronigl_sw=1); sw_winsys.c (softpipe display targets = memory or IOSurface); plugin/gld.c + gen-gld.py (13 real
  gld functions, stubs return 0x2717, 129-name check); mesa-setup.sh adds softpipe (Mesa not rebuilt). Missing: the
  GLI-side file that connects EAGL contexts to Mesa (two agent runs were stopped by safety filters while writing it),
  meson targets, Info.plist, root hook. scripts/gpu/build.sh still copies Turnip into out/gpu (conflicts with
  turnip-build.sh).
- [V] (2026-10-25, second GL agent) gfxInitializeLibrary 0x1d3f6e2f0: plugin record function table
  = +0x420 + 8 * index in `_gfx_gld_names` (userland/negronigl/plugin/gld-names.txt); plugin ID =
  gldGetVersion's 4th value | 0x20000 (0x400 is special); per accelerator `gldCreateDevice(&dev+0x18,
  dev mask, &dev+0x20)` with the device ID (plugin ID | count << 24) already at dev+0x10; nonzero ->
  device dropped. Apple: AppleMetalGLRenderer gldGetVersion = (4, 1, 0x10, 0x7f00).
- [V] GLD pixel format (AppleMetalGLRenderer GLRPixelFormat::preflight): +0 next, +8 device ID
  (0x01007f00; GLEngine gliChoosePixelFormat ORs 0x20000), +0xc flags 0x225dd. EAGLSharegroup init
  needs flags bit 0x100 and, for API 3, 0x20000 (masks 0, 0, 0x20000 at 0x1d3f5331c), then
  gfxCreateSharedState(&pf+8) -> plugin gldCreateShareGroup(device, &out, 4) must return 0.
- [V] EAGL uses only these GLI entries: CreateContextWithShared(&priv+0x20, pf, gfx shared state,
  priv+0x28, priv+0x2088, flags 0x10/0x20/0x40 = API 1/2/3), DestroyContext, SetInteger, GetInteger,
  BindViewES (renderbufferStorage:fromDrawable:, bool), PresentViewES, ChoosePixelFormat,
  DestroyPixelFormat, GetVersion. `-texImageIOSurface:...invert:` = SetInteger(0x38e, {surface ID,
  target, internal format, w, h, format, type, plane, 0}) then SetInteger(0x399, {target, invert});
  attachImage:toCoreSurface: maps the IOSurface format and calls it. glFoo() of OpenGLES = TLS
  key 30 -> priv; x0 = [priv+0x20]; jump [priv+0x28 + 8 * slot] (glClear slot 10, glDisable 63).
- [V] GLEngine is a full GL engine: AppleMetalGLRenderer's gldPopulateContextDispatch copies a
  25-entry render dispatch (0xc8 bytes); a GLEngine context needs a real GLD renderer that reads
  GLEngine state. Decision (coordinator, 2026-10-25): no GLD renderer; the bundle gives EAGL the GLI
  entries on Mesa. Status: that GLI part is NOT written (a safety classifier stopped it); until it
  exists, NegroniGL's gldChoosePixelFormat returns 0x2712, so EAGL contexts stay nil as before.
- [V] Build (scripts/gpu/build.sh): Mesa 25.0.7 freedreno + softpipe, NegroniGL.bundle exports
  129/129 table names + gldInitializeLibrary/gldTerminateLibrary; ngl_init uses softpipe when
  RedwoodGPU does not open (NEGRONIGL_DRIVER=softpipe|freedreno, boot-arg negronigl_sw=1).

### 15a. GLI table written: EAGL contexts on Mesa (GL GLI agent, 2026-10-25)

- [V] How EAGL picks up our GLI table (confirmed in out/gpu/re/OpenGLES.s, unslid):
  - `eagl_init` runs GLEngine's `gliInitializeLibrary` at 0x1d3f52630 (`blr x20`). That path reaches
    libGFXShared `gfxInitializeLibrary` -> our `gldInitializeLibrary` -> `ngl_gli_register`
    (plugin/gli_table.c), which overwrites `_gli_plugin[0]` (0x1e25b0da0) with our bundle handle.
  - Back in eagl_init, the loop at 0x1d3f52648 does `dlsym(_gli_plugin[0], name)` for each name in
    `_eagl_gli_names` (0x1d3f53350, inline 0x20-byte strings) and stores it at `_gli_plugin[+0x08]`
    up to `+0x90` (x20 runs 0x08..0x98, step 8 = 18 entries). Because the handle is now ours, it
    binds our 18 `gli*` exports. If any dlsym returns NULL the loop aborts and EAGL stays
    uninitialised, so all 18 names must be exported.
  - eagl_init then calls `_gli_plugin[+0x80]` = `gliGetVersion` (must return != 0) and
    `_gli_plugin[+0x08]` = `gliChoosePixelFormat(&_gli_pixelformat, attribs)` (must return 0 and store
    a non-NULL format at _gli_pixelformat 0x1e25b0e38). Then it sets `_eagl_initialized` 0x1e25b0e44.
    The 18 names match GLEngine's own exported `gli*` symbols (out/gpu/re/GLEngine.symbols.txt).
- [V] gliBindViewES (+0x88) from -[EAGLContext renderbufferStorage:fromDrawable:] 0x1d3f518f4:
  `gliBindViewES(GLIContext, nativeWindow, retainedBool, colorformat)`; the method first calls it with
  nativeWindow=NULL (detach, result ignored), then with the drawable; it returns YES when the second
  call returns nonzero. GLIContext = EAGL private block +0x20 (our `struct ngl_gli *`).
- [V] nativeWindow layout (GLEngine `_gliBindViewES` 0x1f6f57940): a struct of function pointers, each
  taking the struct as arg 0. The drawable's IOSurface is `((fn)nativeWindow[+0x18])(nativeWindow)`;
  GLEngine then feeds it to `gliSetInteger(0x38e)`/(0x399). Our gliBindViewES takes the same IOSurface
  from +0x18 and binds it as GL_RENDERBUFFER storage through surface.c (ngl_bind_surface), the same
  path gliSetInteger(0x38e) uses. [I] We do not run the window's preflight (+0x08, needs GLEngine's own
  create-buffer callbacks); if the surface is not yet allocated the bind fails cleanly (CGL error).
- [V] gliPresentViewES (+0x90) from -[EAGLContext presentRenderbuffer:] 0x1d3f51b48:
  `gliPresentViewES(GLIContext, mode)` (mode 1 = afterMinimumDuration; a time may be in d0). GLEngine's
  version queues a present on its unpack thread and waits a semaphore (0x1f6f57d08). Ours does glFinish
  so the render lands in the drawable IOSurface; the CAEAGLLayer swap is CoreAnimation's job. [I] untested.
- [V] The 18 slots now have code: gli_table.c (ChoosePixelFormat, DestroyPixelFormat, QueryRendererInfo,
  DestroyRendererInfo, CreateContext, GetAttribute, SetAttribute, CopyAttributes,
  GetMemoryAnnotationList, GetVersion), gli_context.c (CreateContextWithShared, DestroyContext,
  SetInteger, GetInteger), gli_view.c (AttachDrawable, AttachDrawableWithOptions, BindViewES,
  PresentViewES). AttachDrawable/WithOptions are CGL-only; iOS never calls them, so they are no-ops
  that only keep the dlsym loop from binding NULL.
- [V] gldChoosePixelFormat (plugin/gld.c) now returns `&ngl_pf` (device id + flags 0x225dd), not 0x2712.
  The EAGL path reads the format from gli_table.c gliChoosePixelFormat (+0x08), not from the GLD
  renderer path, because ngl_gli_register redirects _gli_plugin to us; gldChoosePixelFormat is kept
  consistent for libGFXShared's own device/sharegroup lookup. gldCreateShareGroup already returns 0.
- [V] Build 2026-10-25 (scripts/bg.sh gpu-build, exit 0): NegroniGL.bundle exports 129/129 GLD names +
  18/18 GLI names + gldInitializeLibrary/gldTerminateLibrary and nothing else (build.sh check updated,
  gen-gld.py GLI_NAMES). arm64, minos 16.0, ad hoc signed, codesign -v OK. 14,895,744 bytes.
- [I] Not run on the phone. ngl_test is an iOS binary, so the GLI entries cannot be exercised on the
  Mac; the first check is on the phone (EAGLContext non-nil; Bold Text on SpringBoard must not crash).

- [V] Review 2026-10-25 (docs/reviews/gpu-gl-plugin-2026-10-25.md section 4) corrects 15a:
  gldInitializeLibrary did NOT call ngl_gli_register (now it does, every load); eagl_dealloc
  (0x1d3f52380) dlsym()s `gliTerminateLibrary` from `_gli_plugin[0]` and calls it with no NULL check,
  so the bundle exports it (19 GLI names; it calls gfxReleaseLibrary and dlcloses GLEngine's handle);
  gldChoosePixelFormat refuses again (0x2712): its only caller is GLEngine's gliChoosePixelFormat
  (+0x468), libGFXShared reads only pf+8. CAEAGLLayer native window: +0x08 attach must run before
  +0x18 begin_iosurface (NULL until attached), +0x10 detach, +0x20 swap(nw, mode, t), +0x30
  begin_properties; attach takes a reference at +0x80. Sharegroup lead UAF and cross-thread destroy
  fixed (gli_context.c). Build exit 0; untested on the phone.

- 2026-10-25 (GL path agent, ios-spes port; docs/gpu-userland.md "GL path (ported from ios-spes)"):
  - [V] ios-spes (Redmi Note 11, A610, same 20H392 iPhone X root) runs CA on GL this way: only backboardd
    gets an `LC_LOAD_WEAK_DYLIB /redwood/lib/libredwood-gl.dylib` written into the zero header padding
    (tools/stage-spes-eagl.py), ad hoc re-signed with its entitlements; no launchd/DYLD env change. The
    bridge is HackiOS eagl.c (8 EAGLContext methods replaced) over libOSMesa (freedreno msm + redwood-drm);
    a preflight (xnu/graphics/spes_gl_preflight.c: `spesgpu=1`, RedwoodGPU within 30 s, renderer FD610,
    triangle readback) runs before any method is replaced. Measured there: ~20 fps with stutters at first,
    all12 frame median 10.8 ms / p90 21.3 ms after queued submissions (0102), 300 MHz GPU clock (0107),
    MDP direct scanout (0109/0116) and 512 MiB GPU VA.
  - [V] Ours: `userland/negronigl/eagl.c` already is that bridge (12 EAGLContext selectors, Mesa linked in).
    New: gate `/var/db/negronigl/{clients,off}` + `ngl_preflight()` (renderer must say FD730, ngl_selftest +
    ngl_surface_selftest PASS, `NEGRONIGL_WAIT` 30 s, `NEGRONIGL_PREFLIGHT=0` skips, `NEGRONIGL_ALLOW_SW=1`
    lets softpipe pass) in negronigl.c; `scripts/gpu/stage-backboardd-gl.py` (port of stage-spes-eagl.py:
    20H392 backboardd has 7808 bytes of load commands and zero padding up to `__text` at 8336, so the 48-byte
    command fits); `scripts/gpu/gl-build.sh` (stage + check-imports), `scripts/gpu/phone-gl.sh`
    (push/backboardd/restore/on/off/restart/test/status/log, single files).
  - [V] Build `gl-build` exit 0: stripped negronigl.dylib 14,214,272 bytes, ngl_test 50,336, staged backboardd
    1,159,536 (sha256 39cb14d1...), check-imports PASS (0 missing, 264 imports). Not run on the phone.
  - [I] Risks: the re-signed backboardd under our AMFI (a main executable, not a bundle); the synchronous
    preflight in backboardd's constructor; `glFinish` on every flush until the kernel waits on per-surface
    fences (patches/xnu/README-gpu-kernel.md section 13 lists the spes kernel deltas we lack).

- 2026-10-25 23:35 (GL path agent, first phone run of ngl_test):
  - [V] Crash before the fix: `ngl_test` SIGSEGV, pc 0x0, lr 0x103dd3950, frames 0x103bcabe8 0x103bcad6c.
    The dylib base was 0x103bb4000 (only base that puts 0x103bcad6c in `ngl_selftest` with 16 KiB
    alignment); `atos -o out/gpu/negronigl.dylib -l 0x103bb4000` gives lr = `st_api_create_context+620`,
    then `ngl_create+156`, `ngl_selftest+48`. The instruction is `blr x8` with x8 = `[fscreen+0x18]` =
    `pipe_frontend_screen.get_param`: Mesa 25.0.7 `st_manager.c:1042` calls
    `fscreen->get_param(fscreen, ST_MANAGER_BROKEN_INVALIDATE)` with no NULL check, and `ngl_init`
    allocated the frontend screen with calloc and set only `screen`, `get_egl_image`, `validate_egl_image`.
    The other unconditional fscreen hooks in st: `get_egl_image`, `validate_egl_image` (set),
    `set_background_context` (glthread only, off).
  - [V] Fix: `negronigl.c` `ngl_get_param()` returns 0 (no window drawables: CA draws into FBOs on
    IOSurface images, glViewport has nothing to invalidate); `ngl_init` sets `f->get_param`. Also
    `ngl_log_image_base()` (dladdr, once per process) from `ngl_load` and from `gldInitializeLibrary`
    (plugin/gld.c): `negronigl: image base 0x100fcc000 /usr/lib/negronigl.dylib (atos -o out/gpu/negronigl.dylib -l BASE ADDR)`.
  - [V] `gl-build` exit 0 (stripped dylib 14,214,448 bytes, sha256 a697d285...), `phone-gl.sh push` OK, then
    `NEGRONIGL_LOG=stderr /usr/local/bin/ngl_test`: GL_RENDERER FD730, ES 3.2, `selftest ... context 99.3 ms
    draw+readback 12.88 ms: PASS`, second frame 1.44 ms, `surface selftest ... BGRA(32,32) 0000ffff
    BGRA(224,224) ff0000ff: PASS`, `selftest PASS, surface selftest PASS`, rc=0. First GPU-rendered GL
    pixels read back on this phone through the dylib (the pid was 352 < 375 of the crash run: the phone
    had rebooted in between, possibly with the GPU clock fix kernel [I]).
  - Next (not done): `phone-gl.sh backboardd`, `on`, `restart` (owner decision; AMFI on the re-signed
    backboardd is the open risk).

- 2026-10-25 23:46 (GL path agent, first CoreAnimation run on Mesa; backboardd pid 732 and 747):
  - [V] Phone: preflight PASS (FD730, triangle, iosurface, 149 ms), `EAGL shim installed`,
    `EAGLContext 0x16150cbf0 API 3 on Mesa`, then backboardd SIGSEGV far 0x30 5 s later, twice. Slide 0x46768000.
  - [V] Chain (`ipsw dyld a2s`, 20H392 cache, unslid): pc 0x1d1b01e70 `_platform_memmove+176` <- lr 0x1a3983ffc
    `IOSurfaceClientGetBulkAttachments+68` <- 0x18833765c `CA::Render::iosurface_get_edr_factor+72` <-
    0x18835538c `CA::WindowServer::IOSurface::wrap_buffer+236` <- 0x1884088cc `CA::OGL::GLESContext::retain_image+312`
    <- 0x188406078 `GLESContext::bind_image_impl+424` <- 0x188327448 `OGL::Context::bind_image+260` <- 0x1882efafc
    `render_contents_background+4380` <- 0x1882d8bf8 `LayerNode::apply+80` <- 0x1882d593c `ImagingNode::render+664`
    <- 0x1882e8344 `render_layers+332` <- 0x1882d8c48 `LayerNode::apply+160`. Not an EAGL/GLI call: CA crashes
    before it reaches our shim.
  - [V] IOSurface.framework (out/gpu/re/IOSurface.s): `_ioSurfaceClientCreateWithLockResult` copies the kernel's
    lock result to client+0x68; GetBulkAttachments does `memmove(out, [client+0x70]+0x30, n)`, so far 0x30 =
    lock result +8 (the shared state page) is NULL. Create (sel 0), Lookup (4) and LookupFromMachPort (34) fill it
    (UniXNU-negroni 0046 `negroni_surface_fill_result`). `IOSurfaceClientWrapClientImage` (sel 6) and
    `WrapClientMemory` (7) are not handled: the kernel's default case returns success with a zeroed struct, and the
    framework builds a client with id 0, size 0 and state NULL.
  - [V] Who calls it: `CA::Render::Image::retain_iosurface` 0x1883c4878 wraps a page-aligned CPU image with
    `IOSurfaceWrapClientImage`; `GLESContext::retain_image` (type 0x18 image) passes the result to wrap_buffer.
    The Metal path did not crash in the 150 s run [I: its retain_image did not take this branch].
  - [V] Same crash and same cause in ios-spes (external/ios-spes/NOTES.md "unhandled IOSurface selector 6"); they
    fixed it in the kernel (sel 6 handler, bergamota 0120-topaz-sweetsurface-client-memory.patch).
  - Fix (userland, eagl.c `surface_wrap_install`): `-[IOSurface initWithClientBuffer:]` (the step after
    WrapClientImage/WrapClientMemory) refuses a client with [client+0x70] == NULL: it releases self and returns
    nil, IOSurfaceWrapClientImage then releases the client (traps 4/5 on id 0), retain_iosurface returns NULL and
    retain_image keeps the image without an IOSurface. Log line (first 4, then powers of 2):
    `negronigl: IOSurface wrap of client memory refused (id 0, no state page: ...), N so far`.
    [I] CA then uploads the image another way (texture upload); not seen yet. [I] The real fix is in the kernel:
    sel 6/7 must fail (kIOReturnUnsupported) or be implemented like ios-spes/bergamota 0120.
  - 2026-10-26 (kernel 0257, build only, phone off): selectors 6 and 7 are implemented
    (`patches/xnu/0257-negroni-iosurface-wrap-client-memory.patch`, README-gpu-kernel.md section 12 "0257"):
    the caller's page-aligned range is wired (`withAddressRange` + `prepare`, like the 0232 host import) and
    published as a cached NegroniSurface with the input's geometry; the answer is the normal lock result (state
    page, id, seed). Input layouts [V, IOSurface.s]: sel 6 struct in 0x20 (`+0 u64 address, +8 width, +0xc height,
    +0x10 format, +0x14 bytes per element, +0x18 bytes per row, +0x1c u32`), sel 7 scalars `address, size`; both
    answer 0xa68 bytes. Bad input returns kIOReturnUnsupported (never a zeroed success). Log once per selector
    `NEGRONI SURF: wrap client memory sel N: WxH bpr B fmt F -> id I`, once per failure kind `... refused: WHY`.
    The eagl.c guard stays as the fallback. Kernel `out/kernel/local-20261026-061605` (sha256 1e3bff08...), image `out/ios16-0257`
    (boot_a 315fe415..., cmdline as 0256). Test when the phone is on: `scripts/gpu/phone-gl.sh backboardd`, `on`, `restart`;
    pass = a `wrap client memory sel 6` line, no `IOSurface wrap of client memory refused` line, no far 0x30 crash.
  - [V] `gl-build` exit 0: stripped negronigl.dylib 14,214,624 bytes, sha256 e527b636...; backboardd unchanged
    (39cb14d1...); check-imports PASS (0 missing). Not run on the phone yet.
- 2026-10-26 (GL completion agent; build only, phone off; docs/gpu-userland.md "Flush and fences", "CAEAGLLayer
  drawables", "GL driver for apps"):
  - [V code] Fences instead of glFinish: Mesa 25.0.7 freedreno never defers a submit that lists a shared bo
    (`freedreno_ringbuffer_sp.c` `!has_shared && should_defer`), an imported IOSurface is `FD_BO_SHARED`, and msm has no
    submit thread (only virtio). So `glFlush` reaches the kernel before it returns; `s_gem_submit` lists every bo handle,
    0230 sets the surface's `gpuFence`, 0254 waits on the SwapEnd fence. `ngl_h_Flush` and present = `ngl_flush()` (view.c):
    glFlush; glFinish with `NEGRONIGL_FINISH=1`, `/var/db/negronigl/finish` or `NegroniGL.bundle/finish`
    (`phone-gl.sh finish on|off`). FinishObject/TestObject/FinishFence keep glFinish.
  - [V 20H392, addresses in docs/gpu-userland.md "CAEAGLLayer drawables"] renderbufferStorage:fromDrawable: needs target
    0x8d41 (0x1d3f51918), `-nativeWindow`, `-drawableProperties` (keys at 0x1d3f51988/0x1d3f5199c, colour formats
    0x1d3f519ac..0x1d3f51a24); present forms pass after = 0/0/1 and d0 (0x1d3f51b8c, 0x1d3f51be8, 0x1d3f51c44). Native
    window table +0x38 = native_window_estimated_size (`str x8, [x0, #0x38]` 0x188468efc). `begin_iosurface` returns NULL
    when not attached (`tbz w8, #0x1` 0x188469a80) or when +0xc0 is set (`ldr`/`cbz` 0x188469a84/0x188469a88);
    [I] +0xc0 = the drawable that is out. It passes `[nw+0xd0]`/`[nw+0xd4]` to get_preflight_buffer (0x188469ae8);
    [I] that is the drawable size set by CA. `begin_properties` also calls get_preflight_buffer (0x18846a204) [V].
  - Review fixes (2026-10-26): present with no next drawable clears `view_surface` and retries at the next present
    (never draws again into the surface CA has); ngl_layer_selftest releases a non-Mesa ctx; `phone-gl.sh test`
    quotes each argument and documents exit 3.
  - New `view.c` (the uncommitted file of the previous agent, finished: declarations in negronigl.h, view.c in
    ngl_core_src): bind/unbind/present for both routes; eagl.c replaces renderbufferStorage:fromDrawable:,
    presentRenderbuffer:, :atTime:, :afterMinimumDuration: (dealloc detaches); plugin/gli_view.c wraps view.c.
  - `ngl_layer_selftest(w, h)` (exported) + `ngl_test --layer [WxH]`: CAEAGLLayer in `+[CAContext localContext]`, two
    frames read back by GL and from the drawable IOSurface. [I] the layer may get no size in a shell process (exit 3).
  - App gate (plugin/gld.c `apps_gate`, NegroniMetal design): env `NEGRONIGL_APPS`, `BUNDLE/off` (fail closed),
    `/var/db/negronigl/off`, lists `BUNDLE/apps`, `BUNDLE/apps.local`, `/var/db/negronigl/apps`; freedreno required.
    Closed = no ngl_gli_register = nil contexts as before. `phone-gl.sh apps on [NAMES]` (default `* -backboardd`) / `off`.
  - [V build] The bundle imported `dyld_stub_binder` (MH_BUNDLE default LC_DYLD_INFO + lazy stubs); the 20H392 cache does
    not export it (check-imports MISSING). [I] dyld would have refused the bundle. Fixed: `-Wl,-fixup_chains`.
  - [V] Kernel already has the app route's property: 0205 sets `IOGLESBundleName = "NegroniGL"` on IOAcceleratorES.
  - Kernel still to add (exactly): (1) IOSurface CPU lock waits for the surface's `gpuFence` (bounded, e.g. 100 ms, then
    log) and drops the CPU cache lines (`NegroniGPUSurfaceForCPU`) before it answers, for CPU readers of GPU-written
    surfaces (CA CPU fallback, screenshots, an app's surface read by a CPU-composited backboardd); (2) optional:
    property `RedwoodWaitsForGPU = true` on RedwoodGPU when 0254 is in, so the library can fall back to glFinish by
    itself on older kernels (today the owner uses `phone-gl.sh finish on`).
  - [V] `gl-build` exit 0: negronigl.dylib 14,233,120 (2b7dd515...), ngl_test 50,496 (8f7d3778...), NegroniGL 13,777,024
    (bf4c7bde..., after the review fixes), backboardd 39cb14d1... unchanged; check-imports PASS (0 missing) for all three. Not run on the phone.
- Poster extensions with Metal for all processes (2026-10-25, Metal agent):
  - [V] The iOS 16 wallpaper extensions (AegirPoster = Astronomy, WeatherPoster, EmojiPosterExtension,
    PridePosterExtension, PhotosPosterProvider) are Metal-only: with no `MTLDevice` they draw nothing.
  - [V] The plugin answered `supportsExtendedXR10Formats` = YES in every process except backboardd
    (NegroniMetal.mm, old lines 783-789); the frontend (ios-flame installAnswers, unchanged by flame/0003) answers NO.
    With YES, AegirPoster renders into an XR10 sRGB colour attachment (pixel format 555 = MTLPixelFormatBGR10_XR_sRGB
    [I: from memory]) with SourceAlpha/OneMinusSourceAlpha blending. metal2vulkan refuses those pipelines
    (`cache/AegirPoster/pipelines.log`: `refused render pipeline: Unsupported { feature: ExtendedRangeBlend(SrgbForm),
    needs: NotImplemented ... at Color(0) }`), flame/0002 skips the draws ("nil render pipeline"), the tiles stay empty.
  - [V] Cold start: shader compiles 0.9-2.8 s plus device open 1.9-2.8 s. The extension missed its launch check-in and
    launchd killed it (SIGKILL, "extension check-in timeout", kernel CRASH line sig 9). The old dead-man wrote the strike
    before the open and counted each kill as an unclean start; after 2 the next starts got no device and threw
    `-[__NSArrayM insertObject:atIndex:]: object cannot be nil` in `-[NUNIAegirRenderer
    getOrCreateUniformBufferforFrameBufferIndex:]` (MTLDevice nil, sig 6).
  - [I] The display chain is 8-bit BGRA: XR10 buys nothing here.
  - Change (plugin only; flame/0003 already answers NO, so plugin and frontend now agree):
    `supportsExtendedXR10Formats` = NO in every process, logged once
    (`supportsExtendedXR10Formats = 0 (NegroniMetal A730 answer: 8-bit BGRA display chain, every process)`).
    Dead-man: the strike file is written when the device has opened, when the open hangs past NEGRONIMETAL_OPEN_MS,
    or by a crash handler (SEGV/BUS/ILL/FPE/TRAP/SYS/ABRT) during the open; a SIGKILL before the open finished adds
    no strike. The strike is removed at the first command buffer that completes after the open (self-test excluded),
    15 s after the open, or at exit(). Limit `NEGRONIMETAL_STRIKE_LIMIT` (env, default 2; old name
    NEGRONIMETAL_MAX_STRIKES still read), twice that (4) for names ending in Poster/PosterExtension/PosterProvider.
    The backboardd GPU watchdog no longer clears the strike (it cleared it at the self-test's completion).
    At the first completed command buffer one line: `pipelines N compiled in T ms, M from cache (...)`
    (native_bridge_metal_work_stats + native_bridge_metal_shader_cache_stats). Pipeline cache dir stays
    /var/db/negronimetal/cache/<name>. [I] Not run on the phone yet. A SIGKILL after the open but before the first
    completed command buffer still adds a strike (the limit 4 covers the PosterBoard relaunches).

- Refusal logging, buffer retry, MPS answers (2026-10-26, Metal agent; bundle sha256 f5e4690a…bf9ec4a, check-imports PASS):
  - [V] AegirPoster: the 615 `sig 6` aborts (`-[__NSArrayM insertObject:atIndex:]: object cannot be nil` in
    `getOrCreateUniformBufferforFrameBufferIndex:`) came after the dead-man refused the device (strikes 4/4): `_device` is nil,
    not a refused buffer. The strikes came from 16 launchd kills (`reason ns 7 code 0x3: extension check-in timeout`) during cold
    opens (device open 1.9-5.2 s plus compiles). metal.log had no `buffer refused` line for AegirPoster. The old refusals in
    `cache/AegirPoster/pipelines.log` (ExtendedRangeBlend) are from before the XR10=NO change (lines 57/59 of 183, file time 12:55).
  - [V] FitnessWidget: the `sig 9` kills are `reason ns 1 code 0x7` = JETSAM_REASON_MEMORY_PERPROCESSLIMIT
    (out/kernel/xnu/bsd/sys/kern_memorystatus.h:290), not a check-in timeout; 29 more are `sig 5` (Swift trap at the same shared-cache
    offset …5a4). Its pipelines.log has 0 refused pipelines and `pipelines 0 compiled`, yet it logs `nil render pipeline`: the
    pipeline it sets was never made through newRenderPipelineStateWithDescriptor (a refused library or function; flame/0008 now
    logs which). The claim "newDefaultLibraryWithBundle compiles the whole metallib" is false: `nmb_library_new` ->
    `Device::new_library_with_data` -> `Library::from_metallib` parses container tags only (metal2vulkan
    crates/metal2vulkan/src/library/function.rs:150, "no bitcode is decoded"); functions compile at pipeline creation. No m2v/0004.
  - [V] chronod: 1399 pipeline lines, 0 refused; `pipelines 2 compiled in 3 ms`; strike cleared at the first frame. WeatherWidget and
    CalendarWidgetExtension have no NMTL lines at all (they never load Metal). Nothing to fix in the plugin for them.
  - [V] PridePosterExtension: pipelines.log 421 lines, 0 refused; 4 strikes. MPSCore (20H392, `ipsw dyld macho --objc-refs`,
    out/metal/spi/mps/) sends the device: supportsFamily:, maxThreadsPerThreadgroup, supports32BitFloatFiltering,
    supportsTextureWriteRoundingMode: (answered) and supportsArrayOfTextures, supportsCommandBufferJump,
    supportsFloat16BCubicFiltering, supportsNorm16BCubicFiltering, supportsQuadShufflesAndBroadcast,
    supportsReadWriteTextureArgumentsTier2, supportsSIMDReduction, supportsSIMDShuffleAndFill, supportsSIMDShufflesAndBroadcast
    (the frontend had no answer). The plugin now adds each missing one as NO (line `MPS feature flags = NO (NegroniMetal A730
    answer): ...`). [I] Whether this is the `MPSAutoCache+156` far 0x18 crash is unverified: the unified log stream
    (logs/phonelog.log) caught no MPS line before the battery died.
  - [V] (b) `MTLCreateSystemDefaultDevice` during the open: `-initWithAcceleratorPort:` runs the open inside `dispatch_once`, and
    Metal's `_MTLRegisterDevices` is itself a once-block, so a second thread blocks until the open ends. No change needed.
  - Changes: flame/0008 (noteRefused: one log line per (what, reason) for refused buffers/textures/libraries/pipelines with
    length/options/descriptor; `failWith` used to count without a line; `newBufferWithLength:`/`newBufferWithBytes:` retry < 1 MiB
    buffers without the CPU cache mode, then with options 0, logged once). NegroniMetal.mm: the MPS NO answers.
  - [V] After push + `rm strikes/*` + kill backboardd (phone time 15:02:17): 4.5 min of kernel log to the battery death at
    03:36:40 host time show no AegirPoster, PridePosterExtension or FitnessWidget CRASH line (usblog lines after 86898; the
    metalprobe/assetsd/Maps/dasd crashes there are other agents' runs). The new `refused (logged once per reason)` lines and the
    MPS line are not read back yet (phone off).

## 16. Wi-Fi facts (Wi-Fi agent, 2026-10-25; OnePlus kernel source e9da592 in out/src/op-kernel)

- [V] SoC version register: BAR0 + 0x224 (family [31:28], device [27:16], major [15:8], minor [7:0])
  (op-kernel drivers/bus/mhi/host/internal.h:197-205, init.c:981); cnss2 loads amss20.bin when (major & 0xf) == 2,
  else amss.bin (cnss2/pci.c:5164-5215); ath11k reads the same offset (TCSR_SOC_HW_VERSION).
- [V] cnss2 sets a 36-bit DMA mask for QCA6490 (cnss2/pci.c:4483-4487); XNU RAM 0x840000000-0x8FFFFFFFF fits.
  Android uses an SMMU S1 IOVA pool at 0xa0000000 (out/live.dts cnss_pci_iommu_group).
- [V] MHI config (cnss2 = ath11k for IPCR): channels 20 out / 21 in, 64 elements, event ring 1; event rings
  32 (control) and 256; sbl_size = seg_len = 512 KiB; fbc_download = true (cnss2/pci.c:93-232, 5522-5524).
- [V] apps SMMU: qcom,skip-init + qcom,handoff-smrs (out/live.dts:15350-15360); PCIe DMA from SID 0x1c01 may
  need an SMR/S2CR entry [I]. PCIe0 (pcie@1c00000) is dma-coherent.
- [V] out/firmware/wlan: ~22.8 MB (amss.bin 5609392 B, amss20.bin 5287936 B, m3.bin 266684 B, regdb.bin
  24278 B, 194 board files ~60 KB): fits a 32 MiB firmware area like the ADSP one.
- Risks [I]: no GICv3 ITS driver for MSI (poll first); DMA above 4 GiB may need an SMMU context; no interconnect
  (BCM) votes for PCIe-DDR yet; survey steps 5-10 never ran on the phone.
- [V] amss.bin and amss20.bin have no second ELF at 512 KiB: BHI loads the first 512 KiB (SBL), BHIe loads the
  whole file (xxd; Linux mhi boot.c mhi_fw_load_handler).
- [V] The phone's DT has no qcom,set-wlaon-pwr-ctrl, so cnss2 does not touch WLAON_QFPROM_PWR_CTRL before MHI
  (cnss2/main.c:3544, out/live.dts:13840-13878).
- [V] Linux ath11k uses a 32-bit coherent DMA mask; cnss2 uses 36 bits for both masks. XNU RAM starts at
  0x840000000, so all MHI contexts and rings are above 4 GiB. [I] Risk: the firmware may need coherent memory below
  4 GiB; Android avoids this with SMMU IOVAs (smmu_iova_ipa 0xb0000000).
- [V] UFS and USB on this port already DMA to physical addresses from cacheable kmem_alloc_contig memory +
  flush_dcache64 (negroni_ufs.c:701, negroni_usb.c:1166). pmap_enter accepts WCOMB on managed RAM (pmap.c:6104, 10647).
- [V] ath11k WCN6855 map: window register 0x310c, window base 0x80000, TCSR_SOC_HW_SUB_VER 0x1910010. ath11k MHI:
  2 event rings (32, 256), IPCR 20/21 on event ring 1, 128 channels, 20 s timeout; cnss2: 32 channels, 3 event
  rings, 10 s timeout.
- [V] apps SMMU at 0x15000000 (0x78 SMRs, 0x4e contexts); PCIe0 stream SID 0x1c01.
- Trees: out/kernel/wt-wlan4 (patched-tree.sh UPTO 0261, replaces wt-wlan2/wt-wlan3, which are deleted) holds the
  stage 1 driver: negroni_wifi.c calls negroni_wlan_start() with negroniwlan=2 after survey step 10,
  negroni_ufs_wlan_area_read() (32 MiB area before the ADSP area: userdata blocks N-19457..N-11266), bsd/conf/files
  entry.
- [V] Stage 1 (patch 0261) is DONE as code and BUILDS (2026-10-25). Five files: negroni_wlan.{c,h},
  negroni_wlan_mhi.{c,h}, negroni_wlan_bhi.c; plus negroni_wifi.c (negroniwlan=2 start) and negroni_ufs.c (area read).
  Each file syntax-checks (scripts/kernel/compile-one.sh) and the full local build links:
  out/kernel/local-20261025-115947/kernel.development.negroni (sha256 b068b5b4...), patch-report: 0260 + 0261 applied,
  no 02xx skipped (only the 4 usual dxb skips: TrustCache, iobuffermemd_monterey, skywalk_sonoma, syntax_checker_sonoma).
  Patch: patches/xnu/0261-negroni-wlan-mhi-fw.patch. Log lines + area recipe: patches/xnu/README-wifi.md (0261 section).
- [V] Review fix this round: negroni_wlan_mhi_init (MMIO context setup) now runs AFTER the BHI SBL download, not in
  PBL. CHDBOFF/ERDBOFF and the context base registers are valid only once the chip leaves PBL; Linux programs them in
  mhi_ready_state_transition after the SBL download (op-kernel pm.c:243, boot.c:546). Also added <kern/clock.h> to the
  mhi/bhi .c files (delay() decl) and made wlan_rings do integer offset math (no -Wcast-align noise).
- [I] UNTESTED ON HARDWARE: the survey steps 5-10 and all of stage 1 have never run on a phone, and the 32 MiB WLAN
  area (scripts/wifi/mkwlanarea.py) is not written to userdata yet.
- [V] Opus review 2026-10-25 (docs/reviews/wifi-0261-2026-10-25.md), fixed in wt-wlan4, patch regenerated, full build
  out/kernel/local-20261025-121738 (sha256 6d69c2b0...), 0261 applied, no 02xx skipped. Facts learned:
  - ml_io_unmap() of an ml_io_map()/ml_io_map_wcomb() mapping PANICS: io_submap is a permanent kernel_map entry and
    vm_map_delete panics on it (osfmk/arm/io_map.c:76-130, vm_map.c:8182-8189). Unmappable RAM views need
    ml_io_map_unmappable(pa, size, VM_WIMG_WCOMB=0x6). negroni_adsp.c:742 still has this bug (negroniadsp=1 only).
  - A PCI BAR must sit at a size-aligned address: a 2 MiB BAR0 goes to 0x60400000, not 0x60300000 (window start).
  - MHI 64-bit doorbells: write the high word first, the low word triggers (op-kernel main.c:84-89).
  - Linux MHI order: BHI SBL -> MHICTRL RESET clear + MHISTATUS READY -> mhi_init_mmio -> event-ring wp + doorbells
    -> M0 -> wake doorbell 127 = 1 -> EE event SBL -> BHIe -> EE AMSS -> channels (pm.c:193-258, 767-781). The old
    "M0 after AMSS" deviation is gone.
  - Failure path: MHICTRL RESET + PCIe bus master off before the DMA pool is freed. SHA-256 mismatch stops.
  - Default negroniwlan_to is now 10000 ms (cnss2 10 s).
  - Open [I]: SMMU SID 0x1c01 may block chip DMA (symptom: BHI SBL error/time-out); MHI CTRL/DATA window is the
    pool only (stage 2 must widen it).
- Next (stage 2): QRTR TX/RX buffers on MHI 20/21, QMI WLFW (ind_register/host_cap/respond_mem/target_cap/BDF/m3_info/
  FW_READY), then HTC/WMI/HTT + HAL rings + scan, then en0 (Sailfish upper half). Details: docs/wifi-plan.md.

### 2026-10-26 Wi-Fi phone test (Wi-Fi/audio agent; patch 0262 rebased on slop 0125, image out/ios16-wifi10)

- [V] 0262 rebased: slop 0125 (`0125-negroni-wifi-rails-xo-slave.patch`) adds its own XO_CLK pulse in step_chip_on
  and the Linux slave-space writes (0x358 = 0, 0x35c = 0x80000000) in step_phy. The rebased 0262 keeps the cnss2
  timing (XO low 10 ms, high 200 us, WLAN_EN, 6 ms, XO low) and the two DBI recipes (vendor recipe 0 default;
  `negroniwifi_dbi=1` = Linux = slop 0125). Build `kernel-wifi3`: out/kernel/local-20261025-182812 (sha256
  3658ff04...), all patches applied, only the 4 usual dxb skips.
- [V] **THE QCA6490 ANSWERS ON PCIe** (USB log 2026-10-26 00:00:35, boot-args `negroniwifi=10`, image
  out/ios16-wifi10 boot_a sha256 4c24ab25...): `7 PHY PCS_STATUS1 0x86 (ready)`, `7 root port DBI ID 17cb:0110,
  LNKCAP 0x524c13, ELBI SYS_STTS 0x1`, `8 root port class 0x60400, buses 0x10100, LNKCTL2 0x10002, iATU0
  0x4/0x80000000`, `8 try 1: link UP: LNKSTA 0x3012 (gen 2 x1), ELBI 0x11401 (state 0x11 L0), LTSSM 0x111`,
  `9 bus 1 device 17cb:1103, class 0x28000, BAR0 0x4, BAR1 0`, `10 BAR0 0x4 (memory, 64-bit), command 0, status
  0x10`, `10 MSI capability at 0x50 control 0x10a`, `10 interrupt inventory: MSI present, MSI-X absent`, `done
  (asked 10)`. The vendor DBI recipe (recipe 0) works; recipe 1 is untested. Steps 5-6 lines are before the USB
  console came up (not in the log). The link trained on the first try at Gen2 x1.
- [V] The wifi10 image booted to the home screen 5 times (00:00, 00:38, 00:48, 01:14, 01:22) with the survey to
  step 10 and `negroniadsp=1 negroniadsp_step=2`; no panic line in logs/usblog.log.
- [V] Image out/ios16-wlan2 (boot_a sha256 59c305dc..., kernel out/kernel/local-20261025-214340 sha256 6ea6ab49...,
  args `negroniwifi=10 negroniwlan=2 negroniadsp=1 negroniadsp_step=4`) was flashed at 03:14 and NEVER produced a
  USB log line (no `NEGRONI WLAN` line exists in logs/usblog.log). [I] Cause unknown: the battery was at 16 %
  (3687 mV, -458 mA, usbin=0 mV: the phone does not charge under our kernel) at 01:31 and the phone was already in
  USB up/down cycles without kernel text from 01:32:37 (01:32:37, 02:03:10, 02:04:20, 02:04:38: `en10 up`, then
  `settime: no reply`, then `interface gone`), so a brownout restart loop is the most likely cause, not stage 1.
  Stage 1 (negroniwlan=2) is still UNTESTED.
- Lesson: test images must carry `negronipanic=30 negronipanicreason=2` so a panic comes back to fastboot by itself
  (a panic screen with the default `negronipanic=0` cannot be left remotely), and the battery must be above ~50 %
  before a test cycle (the phone drains 0.5-1.9 A and never charges under our kernel).
- Next: when the phone is charged, boot ios16-wlan2 again (or rebuild it with `negronipanic=30
  negronipanicreason=2`), read the `NEGRONI WLAN` lines (README-wifi.md 0261 table), fix the first failing MHI step.

### 2026-10-26 Wi-Fi levels 2-4 (patches 0263, 0264; details: patches/xnu/README-wifi.md "0263")

- [V] `negroniwlan=N` is now a level, not an on switch: 2 = steps 1-8 (to the BHI SBL download), 3 = steps
  9-12 (READY, MMIO, M0, EE SBL), 4 = steps 13-15 (BHIe, EE AMSS, IPCR 20/21 + 16 RX buffers). Old
  `negroniwlan=2` behaviour (all of stage 1) = `negroniwlan=4` now. Builds (compile-one + full build).
- [V] Every step prints `NEGRONI WLAN: step N NAME` before it runs and `step N NAME failed: REASON` on an
  error; the badge shows `WLAN N` / `WLAN OK N` / `WLAN STOP N`; BHI/BHIe waits print a heartbeat each second.
- [V source] MHI CTRL/DATA window is now 0..36-bit (cnss2 pci.c:5509-5510); the old pool-only window would
  block the separate RX/TX buffer (0264) and the QMI firmware memory.
- [V source] PCIe0 DMA path: stream 0x1c01 (live.dts iommu-map), TBU clock gcc_ddrss_pcie_sf_tbu_clk
  (halt 0x9d094, vote 0x62000 bit 19) and gcc_aggre_noc_pcie_0_axi_clk (halt 0x7b08c, vote bit 12); the
  survey votes both bits. New step 6 reads them and the apps SMMU (sCR0, SMRs, S2CR) read-only.
- [V source] Review fix: both branches are BRANCH_HALT_SKIP with hwcg (gcc-waipio.c:1756, :1971), so the
  CBCR CLK_OFF bit reads 1 while idle and proves nothing; step 6 only reports it and stops only on a clear
  vote bit (0x62000 bit 12 / 19, gcc-waipio.c:1761/:1976). With sCR0.EXIDENABLE the SMR format differs
  (VALID in S2CR bit 10, 16-bit IDs): step 6 then skips the scan and never writes. M1: Linux toggles
  DEVICE_WAKE (pm.c:334-363), it does not write M0; 0263 now does the same.
  `negroniwlan_smmu` default 1 (stop on a sure fault), 0 report only, 2 writes a bypass SMR/S2CR: owner
  approval needed, never default.
- [I] Restart during the first BHI SBL DMA (2026-10-26) still not isolated: brownout (16 %), SMMU fault,
  gated TBU/NoC clock, or the missing PCIe->DDR interconnect vote (DT `interconnects` on pcie0, not voted).
- [V] Build after the review fixes: kernel out/kernel/local-20261026-073643/kernel.development.negroni (sha256
  3be2d780...), patch-report: 0260-0264 applied, only the 4 usual dxb skips. Image out/ios16-wlan3 (config args
  with `negroniwifi=10 negroniwlan=4 negronipanic=30 negronipanicreason=2`): boot_a sha256 4ee03eff...,
  vendor_boot_a c29329ee..., esp a69afe13.... Patches: 0263 sha256 c37eb0ab..., 0264 6e430f99....
  Not flashed (phone flat).
- Not done: level 5 QRTR and level 6 QMI WLFW (patches 0265/0266). The reference sequence: cnss2 qmi.c
  ind_register :133, host_cap :271, respond_mem :410, tgt_cap :499, bdf :950 (regdb then bdwlan.eNN /
  bdwlan.elf for board id 0xff, bdwlang.* when chip_id & 0x10), m3 :1103; HSP firmware sends FW_INIT_DONE
  (0x38) instead of FW_READY; wlan_cfg + wlan_mode MISSION come before the CE setup (ath11k core.c:2278).

### 2026-10-26 Wi-Fi levels 5-6 (patches 0265 QRTR, 0266 QMI WLFW; details: patches/xnu/README-wifi.md "0265"; build-only)

- [V source] QRTR over MHI IPCR: one MHI transfer = one QRTR packet (net/qrtr/mhi.c). Host node id 1
  (CONFIG_QRTR_NODE_ID default, op-kernel net/qrtr/Kconfig:17; no defconfig in out/src overrides it [I for the shipped
  kernel]), client port 0x4000 (first ephemeral port). Linux sends HELLO to node 0xffffffff (QRTR_EP_NID_AUTO) while the
  chip's node is unknown (af_qrtr.c qrtr_hello_work + :781), v1 header, then learns the node from the chip's HELLO.
  The chip's name service answers HELLO with NEW_SERVER per service (ns.c ctrl_cmd_hello -> announce_servers);
  lookups never cross the link. NEW_SERVER instance = version | instance << 8 (qmi_interface.c:52-53), so WLFW
  (service 0x45, version 1, cnss2 instance 1) shows as instance 0x101 [I: value not seen yet].
- [V source] QMI header 7 bytes {u8 type 0/2/4, le16 txn, le16 msg id, le16 len}; a top-level string has no length
  prefix, a nested one has u8 (max <= 255) or le16; variable arrays have a u8/le16 count (qmi_encdec.c:296-341).
- [V source] cnss2 HSP order (main.c:509 cnss_fw_mem_ready_hdlr): CAP, regdb (type 4, error ignored), INI (skipped by
  us), BDF type CNSS_BDF_ELF = 1 (main.h:356, main.c:56 default; type 0 = .bin, not in the area), M3, QDSS (skipped).
  BDF segments 6144 bytes (QMI_WLFW_MAX_DATA_SIZE_V01, v01.h:123), total_size = remaining bytes (qmi.c:1011).
- [V source] HOST_CAP for this phone: num_clients 1, bdf_support 1, m3_support 1, m3_cache_support 1, cal_done 0,
  host_build_type, feature_list = bit 0 (qcom,xo-clk-gpio) | bit 2 (wlan_en pinctrl) = 0x5; no bit 1 (no
  qcom,drv-supported in live.dts:13840); no wake_msi (no MSI), no ddr_range (SMMU stage 1 off). host_build_type 2
  (SECONDARY) assumes no CONFIG_CNSS2_DEBUG [I]. TLV numbers 0x10..0x1c match ath11k qmi.c (checked).
- [V source] ath11k: QCA6390-class firmware first asks for one ~4 MiB block; on an allocation failure the host answers
  RESPOND_MEM with 0 segments and the firmware asks again in smaller pieces (ath11k qmi.c:1886-1897, :1943). 0266 does
  this once when <= 5 segments.
- [V source] DT `qcom,wlan-cbc-enabled` (live.dts:13853): cnss2 runs a cold-boot calibration before mission mode.
  Level 6 stops at FW_INIT_DONE and does not do it (step 25+).
- [V] The firmware area already has regdb.bin (24278 B), bdwlan.elf (59932 B), bdwlang.elf, bdwlan.e01..ee1:
  no new area image is needed for 0266.
- [V] (review) The NE2211 is project 20847 (out/live.dts bootargs `prjname=20847`), which IS in cnss2's OnePlus lists:
  region BDF (qmi.c:652-659: bdwlan.b0c/b0e/b0a, qmi.c:40-42) and WSA (qmi.c:258-268). The region files are not in the
  vendor firmware, so bdwlan.elf stays right. cnss2 also sends HOST_CAP TLV 0x12 gpios = {0x38242F00} (GPIO 56 output
  low, qmi.c:309-331); 0266 does not (ath11k never does): step-25 candidate if FW_INIT_DONE does not come.
  fw_ready_enable is added in IND_REGISTER (ath11k sets it; cnss2 does not, qmi.c:153-160).
- [V] Host test `scripts/wifi/qmi-host-test.sh out/kernel/tree-wlan7`: request bytes, a full BDF segment = 6182 bytes =
  WLFW_BDF_DOWNLOAD_REQ_MSG_V01_MAX_MSG_LEN (v01.h:648), decode/refusal cases, 500 k random inputs under ASan/UBSan:
  ALL PASS. compile-one: negroni_wlan{,_mhi,_qrtr,_qmi}.c OK.
- [V] Build (lock held across kernel + image): kernel out/kernel/local-20261026-083218/kernel.development.negroni sha256
  ae4c817f... (after the review fixes); patch-report: 0265/0266 applied, skips = only the 4 usual dxb ones. Image out/ios16-wlan6 (config args + `negroniwifi=10
  negroniwlan=6 negronipanic=30 negronipanicreason=2`): boot_a 15cda991..., esp 8f9a0881..., vendor_boot_a c29329ee....
  Patches: 0265 sha256 03487457..., 0266 551f5457.... Review fixes: nested string prefix u8 when max + 1 <= 255
  (qmi_encdec.c:131/:247), NEW_SERVER lines capped at 48, step 24 waits MAX(negroniwlan_to, 10 s), firmware segments
  allocated with max_pnum below 36 bit. Not run on the phone (phone off).
- [V] bsd/conf/files: new lines must go right after negroni_wlan.c. A first build put them after negroni_wlan_mhi.c and
  0330 (Bluetooth, context wlan_mhi/adsp/rpmh) was skipped; fixed and rebuilt.
- Next: owner-approved boot of out/ios16-wlan6 (after out/ios16-wlan3 proves levels 2-4); read `step 16 QRTR HELLO from
  node N`, `step 17 WLFW service at node N port P`, `firmware version ... build "..."`; then step 25+ (WLAN_CFG +
  WLAN_MODE, CE/HTC/WMI: README-wifi.md "What step 25+ needs").

### 2026-10-26 Wi-Fi levels 7-10 + SMMU stage 1 (patches 0320-0324; details: patches/xnu/README-wifi.md "0320"; build-only)

- [V source] PCI 17cb:1103 is WCN6855 in ath11k (pci.c:32); the hw params "wcn6855 hw2.0/2.1" (core.c:397-577) are the
  reference: 9 CEs, target CE table + service map of qca6390 (hw.c:1623/:1720), shadow registers on, credit flow on,
  single_pdev_only, 2 rxdma per pdev, num_vdevs 4, coldboot_cal false.
- [V source] WMI goes host->target on CE3 and target->host on CE2; HTC control: CE0 out, CE2 in; HTT: CE4 out, CE1 in.
  (The task text said CE0 h->t, CE1/CE2 t->h: CE0 carries only HTC control.)
- [V source] CE ring registers are at 0x1b80000 (src) / 0x1b81000 (dst), stride 0x2000, beyond the 2 MiB BAR: they go
  through the window (BAR0 0x310c = 0x40000000 | off[24:19], data at BAR0 0x80000 + off[18:0]). Shadow registers at
  BAR0 0x8fc + 4 i need no window. ath11k's shadow list for wcn6855 has 30 entries (20 non-CE, then 10 CE).
- [V source] Shadow-register chips: ath11k forces the HTC credit total to 1 (htc.c:567-571): one WMI command in flight.
- [V source] ath11k never gives WMI host memory chunks (num_mem_chunks stays 0) and sends no hw-mode TLV in WMI_INIT for
  single_pdev_only chips; host_abi_vers is left 0.
- [I] ath11k has no non-MSI path; ours polls the pointer area the HAL writes (TP_ADDR/HP_ADDR) instead of a CE interrupt.
- [I] Scan without the HTT rx rings: ath11k always sets them up before a scan; if SCAN events come but no MGMT_RX, the
  rxdma refill ring is the first suspect.
- [V] Host tests: `scripts/wifi/wmi-host-test.sh out/kernel/tree-wmi` ALL PASS (WLAN_CFG 493 bytes, WLAN_MODE /
  HOST_CAP gpios bytes, HTC/WMI/beacon parsers, 700 k fuzz inputs, ASan/UBSan); `qmi-host-test.sh` still ALL PASS.
- [V] The five patches apply before 0330/0331/0350-0353 (checked with git apply on the tree at 0311).
- [V] Full build: kernel out/kernel/local-20261026-131532/kernel.development.negroni sha256 1cb619f2040a968f...; patch-report:
  0320-0324 applied, skips = only the 4 usual dxb ones. A first build failed on negroni_wlan_smmu.c (`pmap_paddr_t`
  and `delay` undeclared: bsd/ needs `extern vm_map_address_t phystokv(uint64_t)` as negroni_adreno.c and
  `<kern/clock.h>`); fixed. No boot image (owner rule 2026-10-26: the main session builds one combined image).
- [V] Review fixes in 0324 (SMMU writes read back with EPERM on a mismatch; page entries SH = outer shareable): kernel
  out/kernel/local-20261026-173712 (sha256 in docs/plan.md).
- Next: owner-approved boot of out/ios16-wlan10 after levels 2-6 are proven; read `step 25`..`step 35`, the
  `WMI READY: ... MAC` line and the `BSS N: SSID "..."` lines. If step 8 or RESPOND_MEM fails: `negroniwlan_smmu=3`
  (owner approval: it writes the apps SMMU). If HOST_CAP is refused: `negroniwlan_hostcap=android`.

## 17. Audio (audio agent, 2026-10-25; details: docs/audio-plan.md)

- [V] 20H392 HAL plug-in paths: /System/Library/Audio/Plug-Ins/HAL, /Library/Audio/Plug-Ins/HAL, /Library/Apple/Audio/Plug-Ins/HAL (shared cache strings). Apple drivers there are plain arm64 bundles, CFPlugInTypes 443ABAB8-...; BasebandVoice.driver's table = NULL + 22 function pointers (same as the macOS SDK AudioServerPlugInDriverInterface).
- [V] mediaserverd SIGABRT (logs/symb-mediaserverd.log) = std::terminate in a dispatch block (uncaught exception); the block is not in the backtrace.
- [V] Stage 0 plug-in `userland/audio/build.sh`: arm64, minos 16.0, ad hoc signed, layout check vs SDK 23/23, host test PASS; root hook `AUDIO=1 scripts/audio/root-add-audio.sh` (via root-finish.sh, default off), tested on a fake root. Not on the phone yet.
- [V] Speaker path on Android: PAL `MI2S-LPAIF-RX-TERTIARY` 2 ch 48 kHz S24, VI `MI2S-LPAIF-TX-TERTIARY`; BCLK 48000 x 2 x 32 = 3.072 MHz (AK msm_common.c:443-458); the TDM tert node (1.536 MHz) is not used. Speaker data on SD1 = GPIO124, VI on SD0 = GPIO122 (ACDB I2S sink iid 0x425A).
- [V] GPR: header 24 bytes (word 0 = 0x1860 for header only), domains APPS 3 / ADSP 2, ADSP ports APM 1, PRM 2, AMDB 3; DT ports 3/7/0x17 are APPS-side. SPF ready = APM_CMD_GET_SPF_STATE 0x01001021 -> 0x02001007 status 1. PRM clock 0x104 (TER MI2S IBIT) via PARAM_ID_RSC_AUDIO_HW_CLK 0x0800102C.
- [V] Phone ACDB (odm/etc/acdbdata/acdb_cal.acdb) speaker device graph: SAL -> NXP TFA RX 0x1700B911 (dynamic CAPI, libtfadsp_rx.so) -> SPLITTER -> LOG -> I2S_SINK 0x0700100A; no graph uses TDM_SINK 0x0700100E.
- [V] TFA9874 has no on-chip DSP; the stock kernel driver never talks to the ADSP; register writes alone start it. Reset GPIO is active-high (1, 5 ms, 0, 5 ms). Container odm/firmware/tfa98xx.cnt: 0x34 slot 0, 0x35 slot 1, profiles receiver/speaker/calibrate.cal. Never write MTP (0xF0..).
- [I] Without the NXP module only the on-chip protections stay: keep the gain low. CORRECTION 2026-10-26: TDMSPKG is an attenuation (gain = 21 dB - TDMSPKG), so low gain = HIGH TDMSPKG (0244 floor 9).
- [V] 0240 review vs Linux (smem, smp2p, qcom_aoss, mdt_loader, PAS SCM): layouts and order match. Fix: RPMh votes retry EBUSY up to 1 s (rail_vote), since touch/Wi-Fi share the RPMh try-lock. Full build OK: out/kernel/local-20261025-102834 (kernel sha256 58fffc0c..., all 19 patches/xnu applied).
- [V] Root image 16 GiB (root-macos.sh SIZE=16g): the firmware areas at the end of userdata do not overlap HFS+.

### 2026-10-26 audio phone test (Wi-Fi/audio agent; scripts/audio/phone-audio.sh, patch 0241)

- [V] Before any audio change (boot 22:38, kernel 0254b+0236+0237): mediaserverd pid 28 ran for 3 h with no
  `CRASH mediaserverd` line; the first-boot SIGABRT of 2026-10-24 did not repeat on this root.
- [V] `scripts/audio/phone-audio.sh push` (new; does on the live root what root-add-audio.sh does on an image,
  then kills mediaserverd so launchd restarts it; the phone has no awk/killall/launchctl; macOS tar needs
  COPYFILE_DISABLE=1 or AppleDouble `._*` files land in the bundle) installed
  /System/Library/Audio/Plug-Ins/HAL/NegroniAudio.driver (sha256 fe9c1f71...) and moved VirtualAudio.plugin
  back to /Library/Audio/Plug-Ins/HAL at 23:57. THIS CHANGE IS STILL ON THE PHONE'S ROOT (`phone-audio.sh revert`
  undoes it).
- [V] Result: the restarted mediaserverd (pid 507) ran until the reboot; the next 3 boots (00:00, 00:38, 00:48) had
  no mediaserverd crash. The boots at 01:14 and 01:22 had crashes: 3 x SIGABRT in 50 s at 01:14:35-48, SIGABRT at
  01:31:11 (both = `abort <- demangling_terminate_handler <- _objc_terminate <- std::terminate`, the same uncaught
  exception as 2026-10-24, logs/symb-ms2.log) and one SIGTRAP `__xpc_api_misuse`/`_os_object_retain` in
  `_xpc_connection_send_message` called from a plug-in factory function (`CFPlugInInstanceCreate <-
  HALS_PlugInManager::CreatePlugIn`, main image + 0x437a674; also once at 23:58:33 right after the push).
  [I] The factory that sends XPC is not NegroniAudio (it has no XPC code) but one of the Apple drivers or
  VirtualAudio racing a restart; the SIGABRTs at 01:14/01:31 coincide with the low-battery period (29 % -> 16 %),
  so whether the plug-in helps or hurts is NOT decided: 3 clean boots vs 2 boots with crashes.
- [V] ADSP step 1 (`negroniadsp=1 negroniadsp_step=2`, 00:00:35): `SMEM partition 0/2 at 0x80acf000, 0x30000
  bytes, cacheline 32, free uncached 0x4060 cached 0x30000`, `no ADSP SMP2P item 443`, `our SMP2P item 429:
  absent`, `SCM PAS is supported (adsp): smc 0x42000207 (0x1, 0, 0) -> 0, answer 0`, `stop: TrustZone does not
  report PAS image 1`. So SMEM parsing works on the phone; TrustZone answers "not supported" to the query.
- [V] Patch 0241 (`0241-negroni-adsp-pas-supported-note.patch`, 22 lines): the answer is logged, not obeyed
  (Linux qcom_q6v5_pas never asks it; only mss/wcnss do; the GPU zap PAS calls use the same SMC encoding
  0x420002xx without the fast-call bit and succeed: `SCM PAS auth and reset (zap) -> 0`). Built in
  out/kernel/local-20261025-214340 (6ea6ab49...). Step 2 (firmware area + SHA-256) and steps 3-4 are untested: the
  wlan2 image with `negroniadsp_step=4` never produced a log (see section 16, battery).
- Next: with a charged phone, `negroniadsp=1 negroniadsp_step=4` (reads the area, votes the rails, QMP), then the
  full run; keep `phone-audio.sh status` + `grep "CRASH mediaserverd"` over several boots to decide stage 0.

### 2026-10-26 audio stage (a) step 9 + stage (b) + the XPC fix (audio agent; patches 0242, 0243; build-only)

- [V] Patch 0242 (ADSP step 9, GLINK over SMEM): `bsd/dev/negroni_adsp.c` `step_glink` makes SMEM items 478/479,
  waits for the ADSP FIFO 480, runs GLINK version 1, opens `IPCRTR` + `adsp_apps`, gives RX intents, and exports
  `negroni_glink_send`/`negroni_glink_poll` (new header `bsd/dev/negroni_adsp.h`). One recursive mutex (gl_lock)
  inside the public API serializes the ADSP thread, the audio writer and the charger client (0274). 0242 also puts every ADSP step under `negroniadsp_steptimeout` (default 15000 ms) and prints
  `NEGRONI ADSP: step N (name) failed: reason` on a failure; `smem_alloc_ours` is now a general `smem_alloc(item,bytes)`.
- [V] Patch 0243 (stage (b) + (d)): new `bsd/dev/negroni_audio.c` + `bsd/dev/negroni_audio_abi.h`. ADSP steps 10..15
  call `negroni_audio_step`: 10 QRTR HELLO (no servreg locator yet); default stop is step 9; 11 `APM_CMD_GET_SPF_STATE` -> ready; 12 PRM
  TER MI2S IBIT clock 0x104 at 3.072 MHz + I2S pins 121..124 to func 1; 13 GRAPH_OPEN (WR_SH_MEM_EP -> PCM_CNV -> MFC
  -> I2S_SINK, TERTIARY/SD1/internal WS, 48 kHz S24) + SET_CFG + PREPARE; 14 SHARED_MEM_MAP_REGIONS of our ring
  (SID 0x1801, IOVA 0x10000000) + WR EP media format + START; 15 `/dev/negroni-audio`, `write()` S16->S24 periods to
  the WR EP. The NXP TFA module is left out (dynamic FastRPC; stage (c) does the amps by register writes).
- [I] SMMU: step 14 assumes the boot chain passes SID 0x1801 untranslated (like redwood_sound.c's "passed" path) and
  needs a physically contiguous ring; it fails cleanly if not. A full SMMU context (redwood_sound.c `space_on`) is NOT
  ported yet. [I] SoC-reset limit: a stage-(b) failure calls `negroni_audio_stop` (GRAPH_STOP/CLOSE, mem unmap) and
  leaves the ADSP up; it does not re-reset the DSP, so a graph error does not reset the SoC. Only an ADSP firmware
  fault (steps 1..8) can, and those are gated as before.
- [V] mediaserverd `__xpc_api_misuse` SIGTRAP (logs/symb-ms.log, symb-ms2.log; main image +0x42ee674 / +0x437a674) is
  `BTAudioHALPlugin.driver`: its factory `_AudioServerPlugIn_Create` opens XPC to `com.apple.BTAudioHALPlugin.xpc`
  (bluetoothd, absent) and sends on it (offsets 0x32670/0x356f8/0x3576c matched with `scripts/audio/hfs-extract.py` +
  llvm-objdump). Fix: `root-add-audio.sh` step 2b and `phone-audio.sh push` move it to `HAL.disabled/` by default
  (`BTAUDIO=1` keeps it; `phone-audio.sh revert` restores it). [U] the std::terminate SIGABRT is undecided: it also
  happened on 2026-10-24 before NegroniAudio existed, so it is not our plug-in [I].
- [V] `NegroniAudio.c` stage 1: the real-time I/O thread copies Speaker S16LE frames into a lock-free SPSC ring
  (16384 frames, 341 ms); a writer pthread (StartIO..StopIO) drains to `/dev/negroni-audio` every 5 ms, keeps unwritten
  bytes, drops on a full ring, reopens on ENODEV every 2 s. `build.sh` PASS (layout 23/23, host test 0 failures).
  Driver sha256 `7770ccb43a527c236db723280778cdee3371a9a1e55d9376a64eba4f288b6a0b` (open misses logged once per change). ABI numbers unchanged.
- [V] Full kernel build (scripts/kernel/build-local.sh): all 52 patches/xnu applied, 0242 + 0243 included, 4 usual dxb
  skips, kernel sha256 c476148395483ab2667b3e0b9d3eb1d9ed287297dfcdf38fe58191299bce243d
  (out/kernel/local-20261026-082825; re-review fixes: 8 adsp_apps intents, DONE re-base, negroniaudio_v2; earlier fixes: GPR reply match, PRM status word 1, SPF cmd header,
  QRTR 20-byte control bodies, ring cache clean + DONE flow control, default step 9, GLINK mutex, no locator
  announcement). out/ios16-audio built (boot_a.img sha256 edda5229..., cmdline adds
  `negroniadsp=1 negroniadsp_step=15 negronipanic=30 negronipanicreason=2`). Not booted. Trees deleted.
- Next: on a charged phone with the ADSP up (steps 1..8 pass first), `negroniadsp=1 negroniadsp_step=15
  negronipanic=30 negronipanicreason=2`; read `NEGRONI ADSP`/`NEGRONI AUDIO` over `make usblog`; step by step with
  `negroniadsp_step=10..14` first. Stage (c) (TFA9874 amps) is still only planned.

### 2026-10-26 evening: amps, guard, tone, earpiece, graph, crash watch (audio agent; patches 0244-0248; build-only)

- [V] Paths: speaker = 2x TFA9874 (I2C SE13 0x34/0x35) on TERT MI2S, profile "speaker" (`mixer_paths.xml:2011`);
  earpiece = the same port, 0x34 only, profile "receiver" (`mixer_paths.xml:2161`, `resourcemanager.xml:576`); WSA macro
  and both wsa883x disabled, `wsa-max-devs 0` (`live.dts:27474, 27503, 27517, 27637`); headphones = RX macro + WCD938x
  (`resourcemanager.xml:623`); main mics = TX-macro DMIC3/DMIC4 with WCD938x mic bias (`mixer_paths.xml:2166`).
- [V] 0243 TLMM bug (also in the audit): GPIO registers are at 0x0f100000 + 0x1000 * n; 0243 wrote 0x0f000000 + ...
  and mapped 840 KiB of io_submap. 0244 fixes both (32 KiB).
- [V] TFA9874 cold start = vendor `tfa_dev_start` path for a probus chip: I2CR, RST (reg 0x90 bit 0, generic TFA2 field),
  keys (0x0F=0x5A6B, 0xA0 = 0xFB ^ 0x5A, 0xA1 = 0x5A, 0x0F = 0), revision table (0x0a74/0x0b74/0x0c74), container device
  items, profile items up to "default", MANSCONF 1, PWDN 0, wait CLKS (0x11 bit 7, the 9874 field; the generic TFA2 CLKS
  0x1050 differs), RST 0, SWPROFIL/SWVSTEP, AMPE 1. The container patch is `9874_dummy.patch` (no writes). The vendor's
  XMEM write through regs 0x90-0x92 is left out (no such registers in the 9874 field map) [I].
- [V] Register access: 8-bit address, 16-bit big-endian value (regmap 8/16), reads with a repeated start; reset GPIO
  active-high, 5 ms + 5 ms.
- [V] Host test `scripts/audio/test-guard.sh` found a guard bug before any build: `o > ceiling` compared int64 with uint64,
  so every negative sample became +ceiling. Fixed in 0244. After the fix: full-scale 1 kHz -> -20.00 dBFS peak / -23.02
  rms; 50 Hz -> -44 dBFS; square 8 s held to -25.7 rms; mute, volume (-40), earpiece mix, cap floor (10 dB): PASS.
- [V] (review) TDMSPKG is an ATTENUATION: gain = 21 dB - TDMSPKG, 1 dB per code (TFA9874B/TFA9875 data sheet). The first
  0244 treated it as gain (cap 3 = 18 dB, louder than the vendor's 14/16 dB): REJECTED and fixed. Now a floor: speaker
  TDMSPKG >= 9 (12 dB, 2/4 dB under the vendor), receiver >= 15 (6 dB); never below the container value; logged as 21 - TDMSPKG dB.
- [V] Build 2026-10-26 (`scripts/audio/build-audio-kernel.sh`, kernel only by the owner rule; lock out/kernel/.lock held):
  `out/kernel/local-20261026-174012/kernel.development.negroni` sha256
  daf42c442b7cd2a94e7a82d214d1461ab76f2f28292b6ba0e26369d831765af7 (after the TDMSPKG-floor fix); patch-report: 0242-0248 applied, all patches/xnu
  applied, only the 4 usual dxb skips; strings `NEGRONI TFA`, `TONE done`, `negroniaudio_amp`, `ADSP FATAL AFTER START`,
  `negroni_audio_route` are in the kernel. Patch sha256: 0244 00a3de42..., 0245 f2cb2217..., 0246 d636a7e6..., 0247
  d2ddaa44..., 0248 7d851d26.... Not booted.
- Lesson: agents' patches change under you; cut a patch on `patched-tree.sh OUT 02NN` (the state at its number), not on a
  full tree, and anchor a `bsd/conf/files` line where no later patch has context (0244 uses negroni_ufs/negroni_sample).
- Next: owner writes the new ADSP area (with tfa-init.bin) and boots the combined image with `negroniadsp=1
  negroniadsp_step=15 negroniaudio_amp=1 negroniaudio_tone=1`; then mic (weeks), headset, the HAL
  receiver route (iOS side unknown).

## 17. GPU kernel round 2 (2026-10-25; patches 0232-0234, details: patches/xnu/README-gpu-kernel.md sections 8-11)

- [V] Local full build with 0232-0234: `out/kernel/local-20261025-103035/kernel.development.negroni`
  (sha256 `b88d1274...`), patch-report: every 02xx patch applied (0200-0260), only the 4 usual dxb skips.
  Not booted. Source tree with one commit per patch: `out/kernel/tree-gpu2`.
- [V] backboardd makes two 1125x2436 BGRA framebuffers (bpr 4608, 11239424 bytes) and swaps them in turn,
  layer 0 alone, full canvas (`logs/usblog.log` 2026-10-24 20:10).
- [V] SM8450 SDE in the live DT: MDSS 0x0ae00000 len 0x84000; SSPP VIG0-3 +0x5000..0xb000, DMA0-3
  +0x25000..0x2b000; CTL0-5 +0x16000..0x1b000; INTF1 = DSI; splash 0xb8000000 + 0x2b00000; apps SMMU
  `qcom,handoff-smrs = <0x2800 0x402>` (display stream handed over by the bootloader) (`out/live.dts`).
- [I] SDE register offsets / CTL_FLUSH bits are from the Linux/Qualcomm driver layout (no local copy;
  ios-s9 used the same offsets on SDM845 [V there]). The new boot log lines `NEGRONI FB: DPU ...` show the real values.
- [V] 3D core SMMU context is 2 (slop NOTES boot 0113); Linux's per-process tables need the GPU in context 0
  plus a TrustZone aperture call. Decision: 0233 switches TTBR0 from the CPU while the GPU is idle, behind
  `negronigpu_pt=1` (default 0 = shared tables).
- [I] Under the hypervisor (stage 2 on) DC IVAC at EL1 also cleans; the kernel only uses DC CVAC / DC CIVAC.
- New boot-args (all default off): `negronigpu_pt=1`, `negronifb_zerocopy=1` (needs `negronifb_noconsole=1`,
  no `negronibadge`, no `negronifb_shift`); `negronifb_dpuprobe=0` skips the read-only DPU dump.
- ABI for user space: msm selector 0x49 = `struct redwood_drm_userptr` (as `ngl_abi.h` asked);
  VA_START/VA_SIZE differ by mode (docs/gpu-abi.md sections 4, 5, 6, 8).
- GPU clock (2026-10-25, patch 0235): [V code] step 17 sends ONE HFI GX_BW_PERF_VOTE (id 30)
  `{0, 1, 1, 3}` = GX level 1 (220 MHz), bw level 3, and nothing votes again. Perf table GX levels 0, 220,
  285, 317, 350, 421, 492, 545, 599, 640, 734, 791, 818 MHz; GMU 200/500 MHz; BW table 12 levels.
  New boot-arg `negronigpu_level=N` (default 0 = the old vote): N > 0 (clamped to 12) votes `{0, 1, N, 11}`
  (top bw level) and logs `NEGRONI ADRENO: GX level N (M MHz), bw level 11`. [I] Untested: the GMU may
  refuse a high level without a matching ACD/CX setup; look for `17 HFI GX_BW_PERF_VOTE ack, error 0`.
- Test order (no config change; boot image variants with BOOTARGS_ADD, README-gpu-kernel.md section 12):
  (a) `negronifb_zerocopy=1`, (b) `negronifb_zerocopy=1 negronigpu_level=12`.
- GPU clock probe (2026-10-25, patch 0236; README-gpu-kernel.md section 14): [V phone] a CoreAnimation frame
  costs the GPU ~60 ms at level 1 and at level 12 (ack error 0), ~45-100 Mpx/s per command buffer = XO-like.
  [V code] the watch `CX`/`GX` words are GDSC power bits (gpucc+0x9108/0x905c), not clocks; the vote goes out at
  step 17 before OOB GPU_SET (step 18) and never again; no code touches the GFX3D RCG or the GPU PLLs; cmd-db
  arrays were 16 u16. New boot-args: `negronigpu_clkdump=0` (default 1: gpucc PLL0/PLL1/0x9000 dumps, all cmd-db
  levels, GMU log head), `negronigpu_gxclk=0` (default 1: CP perf counter 0 = PERF_CP_ALWAYS_COUNT,
  `gxclk N MHz` in steps 18/20 and the watch line), `negronigpu_timetest=0` (default 1: `22 blit ... us`),
  `negronigpu_revote=0|1` (default 1 when `negronigpu_level>0`: the same vote again after the GPU_SET ack).
  Offsets from mesa a6xx.xml (RBBM_PERFCTR_CP[0] 0x300 on A7XX, 0x400 on A6XX). [I] CP clock = GX core
  clock; [I] AO counters at 19.2 MHz. Not booted yet.
- GPU clock probe, phone result (2026-10-25, `out/ios16-clk`, level 12 + revote): [V] `20 gxclk 5 MHz with the CP
  running (CP cycles +57413 in AO ticks +211648)`, `22 blit 2.5 Mpx in 31943 us (5 MHz)`, watch `gxclk 5 MHz`.
  The GX clock sits near 5 MHz whatever the vote. [V] USB log attaches at step 21: step-17/18 lines are lost.
  0236 amended: the watch at 5 s prints a late copy (clock dump, cmd-db levels, vote/revote acks, HFI queues,
  last 16 F2H messages) and, with `negronigpu_revote`, votes a third time and measures gxclk 100 ms later
  (README-gpu-kernel.md section 14 item 5). Image `out/ios16-clk2`.

- GPU clock root cause (2026-10-25, patch 0237): [V phone, 0236 probe] with the HFI vote at level 1 or 12 the
  GX PLL0 (gpucc+0x0, Lucid OLE layout: OPMODE +0x04, L +0x10, ALPHA +0x14, CONFIG_CTL +0x20 = 0x20485699 as in
  gpucc-sm8450.c) stays at L 13 (0x0044000d, 250 MHz; CAL_L 0x44), the CP cycle counter gives `gxclk 5 MHz`, the
  2.5 Mpx 2D blit takes 32 ms, every vote is acked (error 0), the HFI queues have no drops and no F2H_MSG_ERROR,
  cmd-db gfx.lvl = 0 56 64 80 128 144 192 224 256 320 384 416. [V code] negroni_adreno.c filled the PERF_TABLE
  frequencies as `gpu_khz[i] / 1000` and `gmu_khz[i] / 1000` = MHz; the GMU firmware takes kHz (Linux
  a6xx_hfi_send_perf_table: `gpu_freqs[i] / 1000` from Hz). So the GMU was asked for an 818 kHz GPU and a 500 kHz
  GMU clock. 0237 sends kHz. Expected after 0237: PLL0 L near 42 at level 12 (818 MHz) and `gxclk` 220 MHz at the
  default vote; the UI frame cost (60 ms per command buffer, ~10 ms per draw at 5 MHz) drops by the clock ratio [I].

- GPU power collapse (2026-10-26, patch 0285, power agent; details: patches/xnu/README-gpu-kernel.md section 16).
  Symptom: GPU hot and battery drain with Metal on. [V code] before 0285 OOB GPU_SET stays set from step 18 for the
  whole boot: GX powered all the time, 0281 only lowers the clock. [V KGSL gen7, out/src/op-kernel]: IFPC = HFI
  FEATURE_CTRL {9, 1, 0x1680} before CORE_FW_START (adreno_gen7_hfi.c:563-620), no PWR_COL_INTER_FRAME register on
  gen7 (adreno_gen7_gmu.c:224-232); the CP needs the power-up register list in ME_INIT (BIT(8), adreno_gen7.c:101-147,
  302-350); oob_gpu is cleared after boot (adreno_gen7_gmu.c:2589-2650); per submission only the SET_MARKER bracket
  and a fenced WPTR write (adreno_gen7.c:150-196), no OOB; slumber = PREPARE_SLUMBER + RSC sleep (CM3 in reset), and
  the wake is a full warm GMU/GPU boot (gen7_gmu_boot, gen7_gpu_boot, gen7_rb_start), not an OOB. [V] 0285:
  `negronigpu_ifpc` (default 1): step 17 asks for IFPC, step 20 gives the list, OOB GPU_SET released after step 22,
  WPTR fenced, ring room from the fences, GX read only held (OOB PERFCNTR). Refused (or `=0`) and
  `negronigpu_slumber=1` (default): slumber after 2000 ms idle, warm restart of steps 14-21 on the next submission
  (first wake logged in full, then `wake N in N us`). IFPC acked but GX never off in 10 s idle -> slumber. WATCH line
  gains `pm ifpc GX collapsed N% gmu N% pwr S fenced N max Nus fail N` (or the slumber counters); watch ticks 100 ms
  busy / 250 ms idle, no GX read per tick. `negronigpu_ifpc=0 negronigpu_slumber=0` = the 0281 behaviour;
  `negronigpu_dcvs=0` still works.
- [I] Not booted. Open: does the A730 GMU firmware accept FEATURE_CTRL IFPC; does the CP keep RB/SQE base and the
  step-20 registers that are not in KGSL's lists across a collapse (KGSL does not list them either); wake time.
- [V] Build 2026-10-26 13:11 IST (job `kernel-ifpc2`, all 53 patches/xnu, 0285 applied, the 4 usual dxb skips; lock held
  over kernel + image): patch sha256 25229bd47b47832b101d8bd925dc2fff36d07b736b682f596219260b1aab2c56, kernel
  `out/kernel/local-20261026-074105` (sha256 27fc0bf81d8924b26292e1ab7676a32e7f16d0d392d647cf5c8fca57d6af859f), image
  `out/ios16-ifpc` (config args; boot_a sha256 22d76f2f21f7e947ae4347ba5df21b0d0809fe442de19c097ee997894fe2d0a1, esp
  d2cb7c7f...). esp.img holds this kernel [V byte compare]. Review fixes: renumbered 0283 -> 0285 (after 0284), the
  WATCH power part is its own `| pm ... |` field (pline 112 bytes), list size 588 bytes. Not flashed (phone off).

- GPU hang recovery (2026-10-26, patch 0287, GPU-recovery agent; README-gpu-kernel.md section 21). [V KGSL] the phone's A730 is
  gen7_0_1 (adreno-gpulist.h:2079-2110), non-hwsched dispatcher, reset = `gen7_gmu_reset` (adreno_gen7_gmu.c:3127-3146:
  `gen7_gmu_pwrctrl_suspend` 1354-1410 = fence ALLOW, CM3 reset, GBIF GX/CX halt, RBBM SW reset, GX GDSC off; then `gen7_boot`);
  fault handling `dispatcher_do_fault` (adreno_dispatch.c:1964-2148, timeout 2000 ms :50, throttle 3/3 s :34-35). [V] 0287:
  detection by RedwoodGPU's 2 s rule, a full ring / lost WPTR, and the watch (2 s fence stall, core SMMU fault, CP_HW_FAULT,
  new GMU watchdog bite / FW_INIT_RESULT bits 9-11); log `NEGRONI GPU RECOVERY: N: ...` (RBBM/CP/IB1/IB2, SMMU FSR/FAR,
  GMU AO status, GMU log head); reset = CM3 reset + GBIF halts + RBBM SW reset (+ GX GDSC collapse with
  `negronigpu_recover=2`) + RSC sleep + FSR clear, then the 0285 warm boot (now `gpu_warm_boot`); in-flight fences read done
  and count as failed (client waits kIOReturnError, `MSM_PARAM_FAULTS` += recoveries = Turnip device lost, per-queue faults
  only for the client's own work); max `negronigpu_recover_max` (3) per 60 s, then gGPUStopped as before. [I] not booted;
  the warm boot after a CM3 reset never ran on the phone.
- [V] Build 2026-10-26 18:21 (job `gpur-kernel`, `scripts/gpu/build-gpur.sh`, lock over kernel + image, patches up to 0291,
  0287 + 0288 applied, the 4 usual dxb skips): kernel `out/kernel/local-20261026-125146` (sha256
  8f1af35996a7ca6347fbd582630db17369831de58b1af736265884b527c0e9b2), image `out/ios16-gpur` (config args + `negronigpu_recover=1
  negronicpuidle=1 negronipanic=30 negronipanicreason=2`; boot_a 02718ef216f7607d1f84ecd1b1d3bc4009b9428b5f8247e99bc7fae09e485323).
  Not flashed. Replaced by the 0298 build below (same image directory).
- KGSL parity (2026-10-26, patch 0298, GPU-recovery agent; README-gpu-kernel.md section 27; source docs/audit/2026-10-26-gpu.md
  section 3): HWCG (53 regs + RBBM_CLOCK_CNTL + 3 GMU AO CGC), slumber from IFPC mode after 2000 ms idle (+ GBIF halt), TLB flush
  + FSR clear at every warm boot, IFPC asked again after every rewake, DCVS busy from the GMU busy counter (XOCLK_0 / AO),
  CP_PROTECT (45 ranges), CHICKEN_DBG x3, ME_INIT BIT(11), rptr shadow (RB_CNTL BIT(27) off), HFI timeout 100 ms after the
  ladder, a guard page after kernel-placed buffers, DDR votes computed from cmd-db BCM aux data + DT bus-table-ddr, the CNOC CN0
  vote, DCVS bw = DT bus-freq. Each has a boot-arg (section 21 table). Left out: ACD (needs the AOP QMP mailbox), preemption.
- [V] Build 2026-10-26 18:47 (job `gpur2-kernel`, lock over kernel + image; patches up to 0298 incl. 0292-0296, the 4 usual dxb
  skips; compile-one 0 errors for the 7 changed files): kernel `out/kernel/local-20261026-131716` (sha256
  7804fca89c4e08e9a1a75f9bc3ba70e3be9171442c6e09d50072afa5ce80332a), image `out/ios16-gpur` rebuilt with it (boot_a
  526eba93e7e6b7a20e56ba767ea26fc2c011fde4e7cd22a46a4d28b491b3d066, esp b710a470664d1deaaa9549e6a57556c388c5c00500a3f684bbd46bbf8557ce9b;
  same args as above). Owner rule from then on: no more images for this work, one kernel build + compile-one is the proof.
  Not flashed, not booted.
- [V] Review fixes (2026-10-26 23:14, job `gpur3-kernel`, kernel only, no image): F1 PSCI_FEATURES(CPU_SUSPEND) bits (bit 1 =
  extended StateID, bit 0 = OSI; the first build read them swapped, so `out/ios16-gpur` would answer "original StateID: WFI only"),
  F3 `dc cvac` of the core's idle record before CPU_SUSPEND and DDR votes never below the Linux constants. Kernel
  `out/kernel/local-20261026-174403` (sha256 dfa9a8a550ecc79d89b7478f1c3217850b55efb9c8cacd124893cf26346e887e), patches up to 0298,
  the 4 usual dxb skips. `out/ios16-gpur` still holds the 131716 kernel (without these fixes).

## 18. Firmware areas at the end of userdata (2026-10-25; scripts/fw/)

- [V] Boot log today: `NEGRONI ADRENO: 12 stop: no a730_zap.mdt in the firmware area (mkfwarea.py + dd)`.
  `fastboot flash userdata` erases the areas (also slop NOTES 2026-10-23). Without them RedwoodGPU never starts.
- [V] N (userdata size in 4096-byte blocks) on THIS phone = 58672399 (getvar `partition-size:userdata:0x37F450F000`).
  slop's block numbers (27429134.., sda14 219457656 sectors, N = 27432207) are from slop's phone: do not reuse them.
- [V] Kernel (negroni_ufs.c, wt-wlan4 + tree-gpu2): ufsroot0/rufsroot0 = the GPT partition named by boot-arg
  `ufsroot` (default `userdata`) on LUN 0; offset 0 = partition first LBA, nblocks = last - first + 1. Logical
  sector 512 (DEV_BSIZE), device block 4096. Writes only with boot-arg `ufsrw=1`; strategy returns EINVAL past the end.
- [V] Areas, relative blocks: log N-1025..N-1 (header magic `SWEETLOG`, not NEGRONILOG as the comment says);
  GPU N-3073..N-1026 (8 MiB, `NEGRONFW`, max 16 files, data from 4 KiB); ADSP N-11265..N-3074 (32 MiB, `NEGRADSP`,
  max 64, data from 8 KiB); WLAN N-19457..N-11266 (32 MiB, `NEGRWLAN`, max 256, data from 32 KiB). Entry = name[48],
  u32 offset, u32 size, sha256[32] (88 bytes). The GPU area is read ONCE at boot (negroni_fw_load): reboot after a write.
- [V] For N = 58672399: GPU seek 58669326 count 2048, ADSP seek 58661134 count 8192, WLAN seek 58652942 count 8192.
  The HFS+ root is 16777216 KiB = 4194304 blocks (`df -k /` on the phone), far below 58652942.
- [V] GPU firmware from the OTA vendor image (`out/camera/payload/vendor.img`, payload-dumper-go from
  NE2211_16.0.3.530_EX01), `/firmware/*` via `dump.erofs --cat`: `scripts/fw/extract-gpu-fw.sh` -> out/firmware/gpu.
  a730_sqe.fw 4f8b288f.., gmu_gen70000.bin b2d3f0e2.., a730_zap.mbn 905b1311.. = slop's values.
- [V] a730_zap.mdt here is 2a74e9e9.. (3564 B), NOT slop's 0706695b. Our .mdt = .b00 + .b02; its hash segment holds
  the SHA-384 of segments 0 and 1; .b01 = the .mbn code segment. The split set is OPLUS-signed (cert "OPLUS
  Attestation CA"), the .mbn QUALCOMM-signed. [I] slop's .mdt came from another build; ours matches this phone's build.
- [V] Images (`scripts/fw/build-areas.sh`, checked by `scripts/fw/checkarea.py` against the kernel reader rules):
  gpu-area.bin 4d0b5bd8b3f9508fcb0d74526c5fc12f99f6e84d885c49e42d067dbffd5b12f8 (7 files),
  adsp-area.bin 3579eab565436233a9a4ccdb785ddfbdacbbb6669d85cad76ebc07b97adeab72 (29 files, same as the 10-24 build),
  wlan-area.bin 76b0c6aa1ea3df5d58c7c72655928f6914d8fd39ca5fbe3d1b1711fbbac7fdcb (198 files). In out/firmware, not in git.
- [V] Phone (read-only checks, 2026-10-25): /dev/rufsroot0 crw-r----- root:operator 18,0; /dev/ufsroot0 brw 1,0 is
  mounted on / (hfs, journaled, read-write); /usr/local/bin/dd -> toybox 0.8.15 (conv=notrunc,fsync, iflag/oflag
  *_bytes); sha256sum, cmp, head are toybox; no sysctl, no dmesg; /bin/sh = dash.
- [I] Write through /dev/rufsroot0 only: XNU spec_open refuses write opens of a mounted block device. If kern.securelevel
  is >= 1 the char node of a mounted disk is refused too (EPERM/EBUSY); not checked (no sysctl on the phone).
- [I] fsync on a character device does not flush the UFS device cache. The log thread sends SYNCHRONIZE CACHE (whole
  LUN) after each log flush (every 10 s when new console text exists); write-areas.sh writes a console line and waits 15 s.
- `scripts/fw/write-areas.sh` (NOT RUN): without CONFIRM=yes it prints the plan and exits 2. With CONFIRM=yes: finds N on
  the phone (binary search with 1-block reads), stops if N != 58672399, checks SWEETLOG at N-1025, checks the HFS+ end,
  never writes below N-19457 or into the log area, pushes + compares sha256, backs up the old area contents to
  out/firmware/area-backup-DATE/, dd bs=4096 seek=S count=C conv=notrunc,fsync, reads back and compares sha256.
- [I] One-flash option (described, not done): make a sparse raw file of N*4096 bytes, clone the root into its start,
  dd the three images at their block offsets (conv=notrunc), then `op10tool img2simg` (holes -> DONT_CARE). One
  `fastboot flash userdata` then writes root + areas, the log area stays DONT_CARE. Unproven: whether fastbootd wipes
  the partition per resparsed piece (-S 256M), and whether the ABL/fastbootd accepts a sparse total of exactly N blocks.
  Test once with a read-back from iOS before relying on it. Ties the root image to this phone's N.
- [V] 2026-10-25 17:45: kernel panic seconds after `scripts/fw/write-areas.sh` opened its first SSH session (its first
  command reads blocks 0 and N of /dev/rufsroot0 with dd while / is mounted from the same ufsroot0). Nothing was
  written. [I] The raw read is the likely trigger; the panic log (log area N-1025) was not read, because reading it
  from iOS needs the same raw read. After the panic the phone came up in the bootloader (fastboot), `fastboot reboot`
  booted iOS again.
- Preferred route since then: the areas go into the userdata flash. `AREAS=1 scripts/ios16/root-simg.sh IMG` clones IMG,
  extends it to N = 58672399 blocks (sparse), dd's the 3 areas at N-3073 / N-11265 / N-19457, reads them back and
  makes one sparse image of N blocks (holes = DONT_CARE). Fake-root test [V]: total_blocks 58672399, area hashes OK.
  [I] Not yet proven on the phone: that fastbootd writes the DONT_CARE-heavy image of the full partition size.
- `sudo scripts/ios16/root-update.sh IN.img OUT.img metal powermenu ...`: APFS clone of an existing root + only the named
  hooks (no DMG rebuild), stops if /var is not a symlink before or after the hooks.

## 19. Reboot mode sysctl (2026-10-25, patch 0213; details: patches/xnu/README-reboot.md "0213")

- [V] `kern.negroni_reboot_mode` (string, `CTLFLAG_RW | CTLFLAG_LOCKED`, root-only write): `normal` (default, 0),
  `bootloader` / `fastboot` (2), `recovery` (1), the 0210 reason numbers. The 0211 `kPERestartCPU` path calls
  `negroni_restart()`: log `NEGRONI REBOOT: reason <name>`, SDAM reason write, PSCI `SYSTEM_RESET`. Halt is unchanged.
- [V] Local build OK: `out/kernel/local-20261025-122742/kernel.development.negroni`, 0213 applied, no 02xx skipped.
- [V] `powermenu-helper bootloader` already wrote the sysctl and read it back; only comments changed. `usbreboot.c`
  matches (no change). Old kernel: helper exit 3, no reboot.
- [I] Not tested on the phone: root write from the setuid helper, and that ABL honours reason 2 after a
  `reboot(RB_AUTOBOOT)` (the 0210 `bootloader` UDP command is the comparison).

## 20. io_submap budget and the ADSP panic (2026-10-25, io-fix agent; patches 0234 0240 0260 0261 0290)

- [V] Panic on the phone (photo, GPU kept on `negroniadreno=22 negroniadreno_keep=1`, Wi-Fi survey to
  step 10, `negroniadsp=1`): `kmem_alloc(0xfffffe1006230e20, 2097152, 0x10002): failed with 3 @vm_kern.c:178`,
  caller 0xfffffe0007aec438 = end of `___kmem_failed_panic` in `out/kernel/local-20261025-103035` (no KASLR
  slide). 2097152 = 0x200000 = 0240 step 1 `ml_io_map_wcomb(SMEM_PHYS, SMEM_SIZE)`. 3 = KERN_NO_SPACE.
  [I] The photo's flags lack a digit: io_map uses KMA_NOFAIL|KMA_PAGEABLE|KMA_PERMANENT = 0x100021.
- [V] `ml_io_map`, `ml_io_map_wcomb`, `ml_io_map_with_prot` take VA from io_submap: 8 MiB for the whole
  kernel (osfmk/arm/io_map.c:65), KMA_NOFAIL + KMA_PERMANENT, so a request that does not fit panics.
  Each map uses round_page(size + (pa & 0x3fff)): the kernel page is 16 KiB (pexpert/arm64/NEGRONI.h
  `__ARM_16K_PG__`), so a 0x1000 map costs 16 KiB.
- [V] `ml_io_unmap` of an io_submap address panics: kmem_free(kernel_map) reaches the permanent io_submap
  entry (vm_map.c:8188 `__vm_map_delete_permanent_panic`).
- [V] `ml_io_map_unmappable(pa, size, flags)` (osfmk/arm64/machine_routines.c:1574) maps the same way
  (pmap_map with `flags` as WIMG) but takes VA from kernel_map (KMA_DATA, not permanent); `ml_io_unmap`
  removes it. WIMG values (osfmk/arm/memory_types.h): VM_WIMG_IO 0x7 (Device, = ml_io_map),
  VM_WIMG_WCOMB 0x6 (Normal non-cacheable, = ml_io_map_wcomb). Not exported to bsd/: local defines.
- [V] `ml_io_unmap(addr, size)` needs a 16 KiB multiple: pmap_remove_options panics on an unaligned end
  (pmap.c:4294, MACH_ASSERT=1 in DEVELOPMENT_ARM64_NEGRONI `mach_assert.h`).
- [V] Early maps (before STARTUP_SUB_KMEM) use virtual_space_start, not io_submap: fbcon (0xb8000000 +
  0x2b00000, pe_serial.c:838, serial_init at arm_init.c:540), GICD/GICR (pe_fiq.c, PE_init_platform(TRUE)
  at arm_init.c:600), both before machine_startup -> kernel_bootstrap. The ADT has no /pram, stram,
  coresight-reg or cpu-impl-reg (slop mkadt.py): those XNU maps do not run.

io_submap use (KiB, 16 KiB pages). Source: the tree `patched-tree.sh` + every `ml_io_map*` call in
bsd/dev/negroni_*.c, iokit/Kernel/arm/Negroni*.cpp [V source; boot order and counts I: from the code, not measured]:

| Group (owner) | Maps, when | KiB before | After this fix |
|---|---|---|---|
| UFS, USB (slop 0028/0072/0074/0089) | GCC 0x90000, DWC3, QSCRATCH, UFS regs: boot | 688 | same |
| keys, reboot, RTC, RPMh, touch, cpufreq (slop + 0203/0210/0211) | SPMI/RSC/cmd-db/TLMM pins/EPSS pages: boot | 416 | same |
| FB DPU/MDSS (0234) | 0x84000, boot (`negronifb_dpuprobe` default 1) | 528 | kernel_map |
| backlight DSI0 (0250) | 0x400, boot | 16 | same |
| Wi-Fi survey GCC + TLMM (slop 0106) | 0x1f4200 + 0xd2000, boot with `negroniwifi>=1` (default 4) | 2864 | kernel_map (0290) |
| Wi-Fi cmd-db, PARF/PHY/DBI/cfg (slop 0109/0120) | steps 3-9 | 128 + 96 | same |
| Adreno GCC (slop 0097) | 0x1f4200, boot with `negroniadreno>=1` (default 22) | 2016 | kernel_map (0290) |
| Adreno GPUCC, GMU, RSCC, SMMU (slop 0097-0101) | boot | 592 | same |
| Adreno GPU regs, CX_MISC, PDC, cmd-db, zap (slop 0108-0111) | GPU steps 15-21 | 480 | same |
| ADSP SMEM (0240) | 0x200000, step 1 | 2048 | kernel_map |
| ADSP carveout (0240) | 0x2800000, step 6, then ml_io_unmap (would panic) | 40960 | kernel_map, unmapped |
| ADSP IPCC, AOSS, TCSR (0240) | steps 4, 7 | 48 | same |
| WLAN BAR0 (0261) | 0x200000, `negroniwlan=2` | 2048 | kernel_map, unmapped on failure |

Totals (of 8192 KiB): default config (wifi=4, adreno=22) 7248 -> 1840; the photo boot before the ADSP
7824 -> 2416 (so 368 KiB were free and the 2048 KiB SMEM map panicked [V matches the photo]);
+ ADSP 1-8 + negroniwlan=2 -> 2464. Biggest left: USB GCC 576, Adreno SMMU/GPU regs 256 each.
Rule for new code: register pages may use `ml_io_map`; anything >= 256 KiB, any RAM view and anything
that is unmapped uses `ml_io_map_unmappable` + `ml_io_unmap` with the page-rounded size.

Patches (2026-10-25, regenerated with scripts/kernel/patched-tree.sh in out/kernel/tree-iofix, deleted after):
- 0240: SMEM and carveout -> `ml_io_map_unmappable(..., 0x6)`; carveout unmapped at the end of step 6 on
  every path (map failure frees the chunk buffer); IPCC/AOSS/TCSR mapped once; static assert carveout 16 KiB multiple.
- 0234: MDSS -> `ml_io_map_unmappable(..., 0x7)`.
- 0261: BAR0 -> `ml_io_map_unmappable(..., 0x7)`, unmapped in wlan_cleanup (after wlan_quiesce); the pool
  view unmap uses round_page(0x691000) = 0x694000 (the old size would have panicked in pmap_remove).
- 0260: step 8 LNKSTA 0xffffffff = link DOWN (stop); step 9 ID 0xffffffff = no answer, `linked` cleared.
- 0290 (new, slop lines only): Adreno GCC, Wi-Fi survey GCC and TLMM -> `ml_io_map_unmappable(..., 0x7)`.
- [I] Small leaks left: Wi-Fi step 4 maps PARF/PHY again in step 7 (32 KiB); NegroniBacklight re-maps DSI0
  if `negroni_dsi_init` fails once and is called again (only from attach today).
- [V] 0270 (battery, added to patches/xnu by another agent during this build): the final 0270 maps no new
  io_submap space in the default mode: the RTC (0203) and the battery share one arbiter mapping (core
  16 KiB + observer 32 KiB + cnfg 16 KiB, which the RTC mapped alone before); `negronibatt=4/5` add one
  16 KiB VADC channel page. Nothing is unmapped (battery agent, source).
- [V] Build 2026-10-25 (`scripts/bg.sh kernel-iofix scripts/kernel/build-local.sh`):
  `out/kernel/local-20261025-125940/kernel.development.negroni` (sha256 39cb11c5...), patch-report: all 27
  patches/xnu applied (0200-0261, 0270, 0271, 0290), only the 4 usual dxb skips. `out/kernel/kernel.macho` points to it.
  [I] Not booted. Next phone test: the same boot-args as the photo; expect no kmem_alloc panic,
  `NEGRONI ADSP: 1 SMEM partition 0/2 at ...`, and `NEGRONI WIFI: 8 link DOWN: ... 0xffffffff`.
- Wi-Fi part 2 leads (not yet in any patch) [V source, I effect]: (1) 0120 writes PARF_DBI_BASE_ADDR_V2 and
  PARF_ATU_BASE_ADDR with CPU physical addresses (Linux qcom_pcie_configure_dbi_atu_base) but not
  PARF_SLV_ADDR_SPACE_SIZE_V2 0x358 = 0 / _HI 0x35c = 0x80000000, which Linux writes with them
  (wlan-linux pcie-qcom.c:440-465); the vendor pci-msm.c:4394/4422 instead writes DBI_BASE 0 and
  SLV_ADDR_SPACE_SIZE 0x4000000. The mix leaves the DBI undecoded -> all-ones reads (matches the photo).
  (2) GPIO95 CLKREQ# is not muxed to pcie0_clkreqn (func 1, pull-up; live.dts pcie0_clkreq_default).
  (3) cnss2 drives XO_CLK GPIO204 high >= 100 us before WLAN_EN, then low 2-5 ms after (power.c:819-904);
  the survey never drives it. (4) cnss2 waits 100 ms after BT_EN off before WLAN_EN (power.c:934).

## 21. Wi-Fi PCIe power-up fixes (2026-10-25, io-fix agent part 2; patch 0262, details: patches/xnu/README-wifi.md "0262")

- [V] Photo 2026-10-25: step 7 PHY ready (PCS_STATUS1 0x86), step 8 LNKSTA read 0xffffffff, PARF_LTSSM 0x180
  (LTSSM_EN + state 0 DETECT_QUIET), step 9 bus 1 ID 0xffffffff.
- [V source] DBI decode: Linux pcie-qcom.c:440-465 writes PARF 0x350/0x354 (DBI) and 0x634/0x638 (ATU) as CPU
  physical addresses AND 0x358 = 0, 0x35c = 0x80000000 (slave space). The phone's kernel (pci-msm.c:4394/4422,
  after the core BCR in msm_pcie_clk_init) writes 0x350 = 0 and 0x358 = qcom,slv-addr-space-size 0x4000000 and
  never the ATU base (vendor DT iATU at 0x60001000). Slop 0120 wrote the Linux addresses without the size.
  [I] That leaves the DBI undecoded = every DBI/config read 0xffffffff. 0262: vendor recipe by default,
  `negroniwifi_dbi=1` = the complete Linux recipe.
- [V source] cnss2 (power.c:819-960) for QCA6490: XO_CLK GPIO204 (live.dts qcom,xo-clk-gpio) high 100-200 us
  before WLAN_EN, WLAN_EN, 1 ms, XO_CLK held 2-5 ms more, then low; with BT_EN (GPIO81) low a 100 ms wait before
  WLAN_EN. GPIO204 is an eGPIO pin: TLMM ctl bit 12 claims it (pinctrl-sm8450.c egpio_enable 12, present 11).
- [V source] GPIO95 = CLKREQ# (function 1 pcie0_clkreqn, pull-up, live.dts pcie0_clkreq_default); slop never muxed it.
- [V source] cnss2 pci.c cnss_pci_enumerate sets the QCA6490 RC to Gen2 first and retries link training 3 times.
- [V source] GCC PCIe0 branch/vote registers in slop match Linux gcc-sm8450.c and vendor gcc-waipio.c (CLKREF_EN 0x9c004).
- [V source] The iATU programming (CFG0 type 4, target bus << 24) matches pci-msm.c msm_pcie_iatu_config.
- [I] Open: vendor PHY table differs in 3 RX values; PCIe PHY LDOs (pm8350 l5/l6) and pcie_noc not voted.
- Sources fetched (sparse, git-ignored): out/src/op-kernel drivers/pci/controller/pci-msm.c,
  drivers/clk/qcom/gcc-waipio.c; out/src/wlan-linux drivers/pci/controller/dwc/pcie-qcom.c, pcie-designware*,
  drivers/phy/qualcomm/phy-qcom-qmp-pcie.c, drivers/clk/qcom/gcc-sm8450.c.
- [V] Build 2026-10-25 (`kernel-wifi2b`; the first `kernel-wifi2` run skipped 0262 because the patch held a
  Finder .DS_Store binary hunk: regenerate patches with `git diff A B -- <files>`): 
  `out/kernel/local-20261025-131141/kernel.development.negroni` (sha256 efb378bd...), patch-report: all 28
  patches/xnu applied (0200-0262, 0270, 0271, 0290), only the 4 usual dxb skips. kernel.macho points to it.
  [I] Not booted. Phone test (owner approval first; the survey writes GCC/TLMM/RPMh/PCIe):
  `negroniwifi=10` (+ `negroniwlan=2` only after step 10 passed once). Expect the 0262 lines of README-wifi;
  the key lines are `7 root port DBI ID 17cb:....` (not ffff) and `8 try N: link UP ... state 0x11 L0`, then
  `9 bus 1 device 17cb:1103`. If step 7 stops with "DBI does not answer": `negroniwifi_dbi=1`.

## 22. Power off (2026-10-26, patch 0214; details: patches/xnu/README-reboot.md "0214")

- [V] Owner symptom: "Shut down" / `op10tool ctl poweroff` ends in a reboot into iOS. Log 2026-10-26
  (logs/usblog.log): `poweroff` at 00:47:38, `NEGRONI REBOOT: PSCI SYSTEM_OFF` (no `returned` line), `en10 up`
  at 00:48:27 = 49 s. `reboot` (PSCI `SYSTEM_RESET`) at 00:37:34, `en10 up` at 00:38:22 = 48 s. Same timing:
  `SYSTEM_OFF` was a reset.
- [V] Cause: TZ implements SYSTEM_OFF and SYSTEM_RESET by dropping PS_HOLD; the PMK8350 PON_PBS
  `PS_HOLD_RST_CTL` type decides (reset or shutdown). 0211 never set it (default mode = SYSTEM_OFF only).
  Android sets SHUTDOWN before every power off and HARD_RESET before every reset (`msm-poweroff.c`,
  `qpnp-power-on.c`, OnePlus sm8450 kernel, branch `oneplus/sm8450_b_16.0_oneplus_10_pro`).
- [V] 0211's PMIC fallback used GEN1/2 offsets `+0x5a/+0x5b`; PON GEN3 (PMK8350, subtype 0x08) has
  `PS_HOLD_RST_CTL` at `+0x52`, `CTL2` at `+0x53` (`qpnp-power-on.c` line 88-90). GEN3 has no PON/POFF reason
  registers; the PMIC PON log is in SDAM 0x7400 (`pmic-pon-log.c`: +0x45 count, +0x46 push ptr, +0x47 push
  SDAM, 4-byte entries at +0x4b..+0xbf).
- [V] 0214: power off = PS_HOLD type SHUTDOWN, then SYSTEM_OFF (SYSTEM_RESET if it returns); restart sets
  HARD_RESET if the type reads SHUTDOWN; boot prints the type and the decoded PON log (`NEGRONI PON LOG:`).
- [V] Full local build OK (2026-10-26): `out/kernel/local-20261025-215453/kernel.development.negroni` (sha256
  8b0c01a3...), 167 patches applied, `Applying 0214-negroni-pon-ps-hold-type.patch`, 5 `NEGRONI PON LOG` strings in the
  kernel. Boot image `out/ios16-0214` (config boot-args, no extra). Not flashed.
- [I] Not tested on the phone yet (battery empty, brownout loop; coordinator hold). The USB auto-boot after a
  shutdown (PON trigger `USB_CHARGER`) is a separate case; the PON log at the next boot shows which one it was.
- [I] Fastboot-menu "Power off" is ABL code; 0214 does not cover it. With the cable in it is likely the same
  USB_CHARGER auto-boot.

## 22. Thermal, GPU DCVS, USB reset (2026-10-26, power agent; patches 0280-0282, details: patches/xnu/README-thermal.md)

- [V] SM8450 TSENS: two `qcom,tsens-v2` controllers, TM 0xc263000/0xc265000, SROT 0xc222000/0xc223000, 16 sensors each; zone map in live.dts (tsens0: aoss-0, cpuss-0..3, cpu-1-0..8, gpuss-0/1; tsens1: aoss-1, cpu-0-0..3, nspss-0..2, video, ddr, mdmss-0..3, camera-0/1). Layout: Sn_STATUS 0xa0+4n, bits 11:0 tenths of a degree, bit 21 valid (Linux tsens-v2.c).
- [V] 0280 `negroni_thermal.c`: 1 s sampling, a line a minute `NEGRONI THERMAL: cpu N C gpu N C ddr N C max N C (name) | gpu cap L cpu cap M MHz`, policy every 10 s (>= 70 C: GPU cap -1 level to 4, CPU cap 3200->2400->1800->1400; < 60 C: back up). `negroni_cpufreq_cap()` added (EPSS row per domain at run time, never below ABL's row). Boot-args negronithermal=0, negronithermal_hot, negronithermal_cool.
- [V] 0281 GPU DCVS on the watch thread (100 ms ticks): busy = RBBM_STATUS bit 23 or a pending fence; idle 500 ms -> level 4 (350 MHz); busy 200 ms -> +1 level up to negronigpu_level (12), lowered by the thermal cap; bw level 3..11 follows; votes only on change, quiet HFI; `NEGRONI GPU DCVS:` lines, WATCH line gains `dcvs L busy N% | <thermal>`. negronigpu_dcvs=0 = the fixed vote.
- [V] USB drops in logs/usblog.log (01:17:28, 01:18:13, 01:20:39, 01:32:34, 02:03:07, 02:04:18, 02:04:35): "gone" then "en10 up" 3 s later, then no kernel line and `settime: no reply`; the first one right after `RedwoodGPU: com.apple.WebKit.GPU closes` and swaps 0. The kernel answered the enumeration (so it ran), but no frame moved.
- [V] Cause in negroni_usb.c: the bus-reset event only cleared the address; `ud.configured` stayed true, so the next SET_CONFIGURATION did nothing (ud_configure early return): no RX TRB, tx_busy stuck. 0282 drops the data state on the reset (DALEPENA EP0 only, tx_busy false, link down) so SET_CONFIGURATION rebuilds it; `negroniusb_resetdrop=0` = old behaviour. Sweet upstream 0081 (link state) is already in slop as 0081-negroni-usb-link-state.
- [I] Why the Mac resets the bus is unknown (the Mac's unified log had no USB-host lines for 01:16-01:23). 01:22:06 and 02:05:02 were real reboots/power loss (the kernel boot lines follow / the battery was flat).
- [I] No temperature or clock measured before/after yet: the phone was flat. Expected effect of 0281: the GPU at 350 MHz between frames; 0280: the first numbers.
- [V] Build: `kernel-pwr` job (all 41 patches/xnu incl. 0272 amended, 0280, 0281, 0282); image `out/ios16-pwr` with the config args; sha256 in logs/kernel-pwr.log and `out/ios16-pwr/SHA256SUMS`. Not flashed.
- [V] 0284 CPU governor (cpufreq agent; details: patches/xnu/README-cpufreq.md): `negroni_cpufreq.c` gets a 100 ms kernel thread. Counter: `processor_cpu_load_info(p, ticks)` (osfmk/kern/processor.c:652), the HOST_CPU_LOAD_INFO `cpu_ticks[]` source: user/system/idle time of `processor->pr_recount` via `recount_processor_usage()` (osfmk/kern/recount.c:972) in `hz_tick_interval` (10 ms) units; `struct processor` is opaque in bsd, so the prototype is declared in the file; the processor comes from `cpu_to_processor(cpu_id)` (osfmk/arm/cpu_common.c:706). busy % = busy ticks * 100 / all ticks over the last 300 ms (3 samples); per domain the busiest core; the first sample is only the base.
- [V] EPSS offsets cross-checked with out/src/op-kernel/drivers/cpufreq/qcom-cpufreq-hw.c lines 104-110 (LUT 0x100, PERF_STATE 0x320, CYCLE_CNTR 0x3c4, DOMAIN_STATE 0x20) and the row decode lines 495-516 (src [31:30], lval [7:0], 19.2 MHz * lval, end at a repeated row); bases and lut-row-size 4 in out/live.dts `qcom,cpufreq-hw`. DOMAIN_STATE [7:0] * 19.2 MHz = the LMh limit (line 143); 0284 logs it as `lmh N`. The LUT values are only in the hardware: no source on disk lists them; known rows [V] from boot 0097/0100: d0 row 14 = 1785, d1 row 15 = 2342, row 17 = 2496, d2 row 14 = 2400, row 20 = 2995 MHz. 0284 prints each table at boot.
- [V] Policy: busy > 70 % -> +1 row per 100 ms up to the cap (min of negronicpufreq_mhz and the 0280 thermal cap); busy < 30 % for 300 ms -> -1 row down to the floor. Floor = the ABL row of every domain (0098); `negronicpufreq_floor_mhz=N` only raises it. A row below the ABL row is blocked three times: the floor, the cap (never below the ABL row), and `wr_perf_state()` (the one PERF_STATE writer after boot clamps to `dom_abl_row`). A mutex serialises the governor and the thermal thread. Boot-args `negronicpufreq_gov` (default 1; 0 = old one-shot), `negronicpufreq_floor_mhz`, `negronicpufreq_hi/_lo`. Lines: `dN table (R rows, MHz): ...; ABL row A`, `governor on (d0 rows a..b (MHz), ...)`, `d0 N MHz busy N% lmh L | d1 .. | d2 ..` on change and once a minute; the GPU WATCH line ends with `cpu N/N/N MHz`.
- [I] Consequence: with the boot 0097 ABL rows (d0 12, d1 17 = top, d2 20 = top) only d0 moves (rows 12..14); d1/d2 stay at the top, the same as the 0280 cap. The governor cannot cool the big cores under the 0098 rule. Boot 0097 ran d1 row 15 / d2 row 14 without a fault [V]: evidence for a later change that drops the rule, not a test of it.
- [V] Build: `kernel-cpugov5` job (all patches/xnu incl. 0284 with the review fixes: change line max 1/s, rows[128], cfg_floor_row kept through thermal caps, hi/lo clamps, GOV_MAX_CPUS rename; exit 0, no 02xx patch skipped): kernel out/kernel/local-20261026-071600 sha256 482e858484b982718501c17371644d812e50a5310982ab68e1de5a7616344a13; image `out/ios16-cpugov` (config args + `negronicpufreq_gov=1`) boot_a.img fefc02ddfc27d0b7311ed4bff05943a1315cea4b4f60522ff4da428b1f0dd812. Not flashed.
- [V code] 0283 (README-thermal.md "0283"): per-zone DT trips every 1 s: cpu-110C (cpu4-emerg0/cpu0-emerg, live.dts:8042/:8509) -> deepest CPU row; gpu-95C (tj_cfg :8404) -> GPU cap -1/s; ipa-53C (:10275, skin 0x146 proxy [I]) and ddr-90C (:8812) -> one CPU step per 10 s; xo-78/80C (:10087/:10094) -> deepest CPU + GPU level 5; bcl-lvl0/1/2 (status 0x4708 bits 0-2, bcl_pmic5.c:27,41-43) -> GPU 10/8/5, CPU 2400/1800/1800. kgsl state k = our level 12-k. Charger FCC level 3 at skin 45 C, 4 at ipa-53C/xo-78C [I design]. Line ends `| trip <names>`. `negronithermal=2` = 0280 rule, 0 = off. Fixed: `cpu` = core sensors only; unmapped TSENS skipped.
- [V] 0283 + abl: With the default `negronicpufreq_floor=abl` every CPU cap of 0280/0283 is a no-op for d1 (A710) and d2 (X2): their ABL rows (17, 20) are their top rows and no cap goes below the ABL row [V negroni_cpufreq.c `negroni_cpufreq_cap`, README-cpufreq.md]. Until `lut` only the d0 caps and the GPU caps act (LMh still throttles in hardware).
- [V code] 0291 (README-cpufreq.md "0291"): `negronicpufreq_floor=abl|lut` (default abl); lut: d1/d2 floor = LUT row 0 (d0 keeps ABL row 12); evidence boot 0097 (d1 row 15, d2 row 14, no fault). LUT rows still unknown (0284 prints them at boot).
- [V] Power set build (0277/0278/0283/0291): Build `pwr-build` (scripts/battery/build-pwr-image.sh, lock out/kernel/.lock held over kernel + image): kernel out/kernel/local-20261026-124827/kernel.development.negroni sha256 01363704dab977e2259aecbe1fb81141133ba5458ec97a59a6b6abf86b981fa3; patch-report applies every patches/xnu patch 0270-0291 incl. 0277/0278/0283/0291 (and the other agent's 0287/0288), only the 4 usual dxb skips; strings `loop: battery`, `store: soc restored`, `trip %s %s (value`, `negronicpufreq_floor`, `QDSS clock vote released` in the kernel. Image out/ios16-pwr was built in that same locked job from that kernel (local-20261026-124827, sha256 01363704...; [V] three 64 KiB pieces of it found byte-equal in out/ios16-pwr/esp.img; the image SHA256SUMS lists only the image files). It is BEFORE review fix 1 (0277 BATT_CHG_EN restart log bound); per the owner the fix gets a kernel-only proof build, the main session builds the combined image. Review fixes 1-4 (2026-10-26 18:5x): kernel-only proof build `pwr-kernel` (IMAGE=0, lock held): out/kernel/local-20261026-132431/kernel.development.negroni sha256 4786905de90c56b9150153d01f33f69ed87bc7769611e494dd111a1c32974b34, 0277/0278/0283/0291 applied, only the 4 usual dxb skips, string `further failures are not logged` (fix 1) in the kernel. 0277 sha256 now in the report. Image (config args + `negronibatt=5 negroniadsp=1 negronichg_glink=1 negronichg_ma=1500 negronifb_sleep=0 negronipanic=30 negronipanicreason=2`): boot_a.img 72ee45050d399b14a1805b55c65c7cd927a90ed45d6b3c8d5596b6582afc9394, vendor_boot_a.img c29329ee..., esp.img 01f9330f..., negroni.adt 12b7654d... (out/ios16-pwr/SHA256SUMS). Not booted. Patch sha256: 0277 cd22073c..., 0278 047a4652..., 0283 564c7390..., 0291 fa95dcd5...

- CPU idle (2026-10-26, patch 0288, GPU-recovery agent; patches/xnu/README-cpuidle.md). [V code] before 0288 an idle core
  ran WFI only (cpu_idle, no PSCI CPU_SUSPEND anywhere). [V out/live.dts:733-775] silver/gold "rail-pc" param 0x40000004
  (exit 750/1550 us, residency 4090/4791 us, local-timer-stop), cluster l3-off 0x41000044 (>= 5309 us), llcc-off 0x4100c344
  (>= 13959 us); psci-1.0 smc with cpu-pd/cluster-pd (1217-1272); timer@17420000 frame 0 SPI 8 = INTID 40 (1344-1357).
  [V Linux] PC mode by default (psci.c:578-592), OSI only for the hierarchical domains. 0288: `negronicpuidle` (kernel default 0
  = WFI only; 1 = core rail-pc when the next deadline is >= the residency; 2 = + cluster params in PC mode), PSCI probe
  (extended StateID needed), resume through XNU's resume_idle_cpu -> arm_init_idle_cpu -> cpu_idle_exit(TRUE) + PE_init_cpu +
  setPop, the frame-0 timer as broadcast wake (IPI), short-sleep guard; log `NEGRONI CPUIDLE: cpuN state S param 0x... entered N
  times ...` every 60 s. [I] Gunyah traps PSCI (its vtimer/SPI behaviour unknown); a wrong param hangs a core with wdt off: the
  test image has `negronicpuidle=1`, the kernel default stays 0. Measure: 0284 busy %, `down %` per core, ibat at idle 0 vs 1 vs 2.

## 23. Vibration / haptics (2026-10-26, haptics agent; patches 0300-0301, details: docs/haptics-plan.md)

- [V] The motor is an LRA on the PM8350B HV haptics block (live DT `qcom,hv-haptics@f000`, SID 3, regs
  0xf000/0xf100/0xf200, status "ok"; vmax 1680 mV, T_LRA 5882 us, vibrator-type 8151 = SLA0815). No I2C LRA
  (no awinic/aw869x/oplus,haptic node). The SoundWire node `qcom,pm8350b-swr-haptics` is the same block fed by
  LPASS audio.
- [V] hBoost is switched by a PBS trigger through the PMK8350 SDAM 0x9d00 (SID 0): 0x42 = 1 on / 2 off, then
  0xe5 = 1 (qcom-hv-haptics.c 1366). Direct play: VMAX 0xf048 = mV/50, amplitude 0xf126, SPMI_PLAY 0xf04c = 0x81
  (PLAY_EN | DIRECT_PLAY), stop = 0x01.
- [V] 0300 `negronihap=1`: owner log of PPIDs 0x3f0/0x3f1/0x3f2/0x09d, register census, 300 ms buzz; writes
  only when EE 0 owns the HAP APIDs (`negronihap_force=1` overrides). API `negroni_haptic_play(ms, strength)`
  (async, thread call stop).
- [V] iOS 20H392: FigVibrator (MediaExperience) uses `IOServiceNameMatching("vibrator")` +
  `IORegistryEntrySetCFProperties` when `VibeSynthEngineHasHardwareSupport` is false (closed-loop MobileGestalt
  answer false and no legacy vibe HAL device). CoreHaptics/UIFeedbackGenerator need the closed-loop answer and the
  HAL device `VirtualAudioDevice_Actuator` (CS42L75 actuator stream on a real D22). No haptic user client exists.
- [V] Our ADT has no `/product/haptics` node. [I] So the legacy IOKit path is the one iOS takes here.
- [V] 0301 publishes `NegroniVibrator` named "vibrator" on IOResources; setProperties parses `hertz_millisecs`
  (pairs of {intensity 16.16}/bool + ms) and `repeat`, a CFNumber 0 stops.
- [V] Build: kernel out/kernel/local-20261026-072436 sha256 0f22dbf4..., image out/ios16-hap boot_a sha256
  99a1123a... Not run on the phone.
- [I] Expected: system-sound/ringtone vibration works with 0301; keyboard/UI taps (CoreHaptics) stay silent until
  an Actuator HAL device exists.
- [V] 2026-10-26 evening (0302-0303, build-only; docs/haptics-plan.md section 8): UIKit feedback level 2 (impact,
  keyboard: `requiredSupportLevel` 0x1890dd1e4 = 2) needs `+[AVHapticPlayer supportsHaptics]` 0x1af58e924 =
  MobileGestalt DeviceSupportsClosedLoopHaptics (`gqDnklGQnpv5ilgh5uHckw`, handler 0x19c564a9c) =
  `IODeviceTree:/product/haptics` `closed-loop`. MG key = base64(md5("MGCopyAnswer"+name))[:22]; property names are
  obfuscated the same way. Haptic server = AVHapticServer in mediaserverd (`com.apple.audio.hapticd`) ->
  VirtualAudioDevice_Actuator (VirtualAudio.plugin) -> HAL UID "Actuator" (NegroniAudio). D22 haptic waveforms are
  48 kHz mono; Keyboard-Key.wav peak 0.10 FS, 3.2 ms.
- [V] 0302: `negronihap_ui=1` publishes /product/haptics {closed-loop 1, supports-3rd-party-haptics 1} from
  NegroniVibrator::start and makes `/dev/negroni-haptic` (S16LE mono 48 kHz -> 2 ms block peaks -> 8 ms envelope ->
  direct-play strength floor 160..255, tap >= 20 ms, cut 5 s); CAL_EN toggle on forced VREG_RDY. 0303: CL brake
  (0x50 = 0x41, PTN 0x70 = ff 3f 1f, SPMI_PLAY 0x89/0x09; `negronihap_brake=0` off) + hBoost-ready wait (20 ms max).
  NegroniAudio: Actuator -> SPSC ring -> haptic writer thread -> the node (host test PASS).
- [V] Build: kernel out/kernel/local-20261026-125419 sha256 6c35b3f5d3ee5bbcc14839cda2ad4ac4cbdcb962b653f025a2518b2f48cdbe23
  (all of patches/xnu; 0292-0296 of another agent skipped); out/ios16-hap2 boot_a sha256
  e479ff370e06c34fd85e57cbcd8ec9d3244d2fad76447ffc5efbca1208262c2a (+ negronihap=1 negronihap_ui=1 negronipanic=30
  negronipanicreason=2); NegroniAudio b43b0304... Not run.
- [I] With closed-loop on, ringtone/alert vibration also goes through the Actuator (unified vibe engine), so 0301 is
  unused; if the Actuator chain fails, all vibration is lost: boot without negronihap_ui and clear the MG cache.
- Lesson: the MobileGestalt cache (`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/
  Library/Caches/com.apple.MobileGestalt.plist`) may keep old answers: scripts/haptics/*.sh remove it.
- Lesson: scripts/audio/hfs-extract.py now follows HFS+ file hard links (iNode<n> in the private-data dir); before,
  hard-linked files (e.g. the D22 tunings) came out empty.


## 24. Bluetooth QCA6490 (2026-10-26, BT agent; patch 0330, details: docs/bluetooth-plan.md, patches/xnu/README-bluetooth.md)

- [V] BT UART = `qcom,qup_uart@894000` (`hsuart0`, QUP2 SE5 "se20"), pins 76-79 function qup20, GCC clocks 130/138/139
  (WRAP2_S5, WRAP_2_M_AHB, WRAP_2_S_AHB), wake byte 0xfd. BT_EN GPIO81, SW_CTRL 82, XO_CLK 204, WLAN_EN 80.
- [V] Rails (DT bt-vdd-*-config): smpb11 966, smpc1 1900, smpb12 1350, ldoe7 2800 mV (+ iPA s3e via AOP, not voted).
  The first three equal the Wi-Fi votes; ldoe7 is new (`negroni_rpmh_bt_enable`).
- [V] Firmware is in the `bluetooth` partition (FAT16, not the vendor image): hpbtfw20/21.tlv + 102 hpnv* NVM files.
  `scripts/bt/fetch-firmware.sh` -> out/bt/firmware (never commit). `scripts/bt/fetch-sources.sh`: Linux hci_qca/btqca,
  geni serial, gcc/pinctrl/rcg2, OnePlus btpower.c + msm_geni_serial.c into out/src.
- [V] iOS bluetoothd: H4 over `/dev/uart.bluetooth` / control socket `com.apple.uart(.sk).bluetooth`, ADT props
  transport-encoding/-speed; chipset tables are Broadcom only. Prior art: external/bergamota/docs/BT_IOS_TRANSPORT.md
  (WCN3990 on SDM845; design reference, no license).
- [V] Build: 0330 compiles (compile-one.sh clean); full kernel + out/ios16-bt: see docs/plan.md. [I] Not run on the phone.
- [V code] 0331 HCI stage (`negroni_bt_hci.c`, README-bluetooth.md section 0331): `negronibt=2` = steps 9-11 (HCI_RESET,
  EDL version 0xfc00/0x19, baud 0xfc48 code 0x0e + host 3 Mbaud + version again); `negronibt=3` = + steps 12-19
  (BT pack, rampatch, board id 0x23, NVM, logging off 0xfc17, reset, build label 0x20, Read_BD_ADDR 0x1009).
  `negronibt_to` (2000 ms), `negronibt_baud`, `negronibt_ibs`. An HCI error -> 0330 failure path (BT_EN low).
- [V btqca.c/hci_qca.c] hp* names = the HSP family = Linux `QCA_WCN6855` (soc_type >= WCN3991): EDL answers are
  Command Complete (`00 19 ..` 15 bytes; TLV ack `00 1e`), not VSE. TLV segment = 243 bytes (MAX_SIZE_PER_TLV_SEGMENT,
  btqca.h:18), not 240. BD address = standard HCI_Read_BD_ADDR 0x1009 (btqca.c:692), not a vendor command.
  Baud: RFR off, 0xfc48, 1-10 ms, host rate, RFR on; Linux waits for no answer (hci_qca.c:1342-1394, 1487-1579).
  Linux sends no HCI_RESET before the version for WCN6855 (we do; a timeout there is not fatal).
- [V files] hpbtfw20/21.tlv: download mode 3 (only the last segment is acked), product 0x13, ROM build 0x0200/0x0201.
  Stock NVM tag 17 = `15 11 22 00 2e 00`: IBS bit (byte 0 bit 7) clear, baud byte 0x11 = 3.2 Mbaud (no clock level at
  16x; we write 0x0e = 3 M). Tag 2 = `ad 5a 00 00 00 00` (default 00:00:00:00:5a:ad). Tag 27 byte 0 = 0x01.
- [V] Firmware path: one file `negroni-bt.bin` (`NEGRBTFW` pack, 105 hp* files, 1011646 B) inside the WLAN area
  (199 files; out/firmware/wlan-area.bin sha256 f8e96b65..., was 76b0c6aa... without the pack). `scripts/bt/mkbtarea.sh`.
  No new userdata area; the WLAN reader is unchanged (it looks files up by name).
- [V] Build 2026-10-26: kernel `out/kernel/local-20261026-123344` sha256 `2c5d53ca...` (0330 + 0331 with the review fix applied, only the
  4 usual dxb skips); `out/ios16-bt` boot_a sha256 `d01f3d6d...` (config args + `negronibt=3 negronipanic=30
  negronipanicreason=2`; `scripts/bt/build-test-image.sh`). [I] Not run on the phone; the BT pack is not on the phone.
- [V disasm, 20H392 bluetoothd = bergamota's binary] Stage B (patches 0332-0333, userland/bluetooth; README-bluetooth.md
  "Stage B"): bluetoothd talks H4 over the kernel control socket (POSIX driver 0x100066bdc), not over /dev nodes; the
  /dev/uart.bluetooth / cu.bluetooth names are only access() checks (0x100026af4). Default control name
  com.apple.uart.sk.bluetooth = Skywalk -> job env BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000.
- [V] bluetoothd discards BT_DEVICE_ADDRESS (zeroed after sscanf, 0x1000268f4) and needs a registry entry "bluetooth"
  with local-mac-address -> ADT node /arm-io/bluetooth (ADT_BT=1 adt-extra.py, config [adt.bluetooth]). Kernel step 20
  writes the same address into the QCA (0xfc14, display byte order).
- [V] BlueTool: Broadcom .hcd only; /etc/bluetool overrides gated on ReleaseType Vendor/Internal (0x100016054-0x100016280);
  the root has no /etc/bluetool and no /usr/share/firmware/bluetooth. bluetoothd's BlueTool reply: result (0 ok, 10/13 =
  "no platform/chipset") -> stand-in userland/bluetooth/negroni-bluetool answers result 0.
- [V] bluetoothd stack init does not keep the manufacturer (0x10010bcd4-0x10010bd10). OGF 0x3f clashes (0xfc48 = QCA baud)
  -> 0333 answers every host vendor command in the kernel. [I] chipset id source unknown (setters 0x10025a8e8/0x100285134).
- [V] iOS SDK marks xpc_connection_create_mach_service unavailable: negroni-bluetool binds it by asm label. The SDK has no
  sys/kern_control.h: hcitest defines ctl_info/sockaddr_ctl itself.
- [V] Build 2026-10-26 (stage B): kernel out/kernel/local-20261026-174538 sha256 cfd8af00a5145843b011737cdf8a08a157d14f3ced415dd4a0aa944763bc904d (after the review fixes F1-F2; before: local-20261026-132747 a94e8f3c...)
  (0330-0333 applied, 4 dxb skips). First build failed: IO_NDELAY needs <sys/vnode.h>. [I] Not run on the phone.
- Tool: `xcrun llvm-objdump -d --macho` disassembles bluetoothd in 3 s with string annotations; `ipsw macho disass -x
  __TEXT.__text` did not finish in 10 min. scripts/audio/hfs-extract.py needs the parent folders of a file target made first.

## 25. Fingerprint sensor, Goodix optical G7 (2026-10-26, fingerprint agent; patches 0350-0351, details: docs/fingerprint-plan.md, patches/xnu/README-fingerprint.md)

- [V live.dts] `goodix_fp` (36711): `goodix,goodix_fp`, ldo-supply pm8350c_l11 = RPMh `ldoc11` 3.0 V 150 mA (36715-36716,
  regulator 11248-11257), IRQ TLMM 40 (pull-down), reset TLMM 41, fp id TLMM 42 (pull-up, `oplus_fp_common` 36695-36708:
  `goodix_optical_G7`, fp-id 1). Panel `oplus,ofp-fp-type = 0x88` (32994) = optical "new solution" (dim layer + pressed
  icon by the HWC), no local HBM.
- [V] No SPI node for the sensor; every `qcom,spi-geni` SPI node is `status = "disabled"`: the SPI is driven by the TEE on
  Android. [I strong] The SE is QUP1 SE2 = spi@a88000 (pins TLMM 36-39 `qupv3_se10`, function 1 "qup10", unused by any
  HLOS node). GCC: APCS vote 0x62008 bits 24 (s2), 20/21 (AHB), 18/19 (core), RCG 0x2827c (gcc-waipio.c 2869, 3141,
  3156, 2807, 2820, 1101).
- [V] The OnePlus kernel source drop has no fingerprint driver at all; only the display side
  `oplus_onscreenfingerprint.c`. The HAL (`/odm/lib64/libgf_hal_G7.so`, "Delmar") talks to `/dev/goodix_fp` with
  GF_IOC_* ioctls and netlink (TP_TOUCH_DOWN/UP, UI_READY), loads a QSEE TA (not found in vendor/odm firmware dirs nor
  as a FAT name in the modem partition), and reads the icon position from
  `persist.vendor.fingerprint.optical.sensorlocation` / `.iconsize` (runtime property; not in any build.prop of
  vendor, odm, my_product, nor in system.img). Extraction: `scripts/fp/extract-vendor-fp.sh` -> out/fp (git-ignored).
- [V] HBM for the capture: whole-panel HBM, DCS `53 E0` + `51 0E FF` inside F0 unlock (live.dts 33140 hbm-on,
  33139 hbm-off, HS mode), ui-ready after `oplus,ofp-hbm-on-period = 2` TEs with the icon on the panel
  (oplus_onscreenfingerprint.c 1150-1441).
- [V] iOS 16: Touch ID/Face ID match inside the SEP; the 20H392 shared cache references `com.apple.biometrickitd`
  (6) and `AppleBiometricSensor` (1); our kernel has no SEP/Mesa/Pearl: no Apple path to use. Design (stage D):
  own daemon + open-source minutiae matcher + passcode injection / SBLockScreenManager hook
  (docs/fingerprint-plan.md section 4).
- [V code] 0350 `negronifp=1|2`: GCC votes, SE probe (protocol must be SPI, FIFO not disabled), FIFO-mode GENI SPI
  (spi-geni-qcom.c sequences, packing 8-bit x4), ldoc11 vote via negroni_rpmh (no disable vote exists: the LDO stays
  on), reset, Goodix `F1 00 00` register-read frame [I: protocol guess], IRQ poll. Bounded waits, reverse power-down.
  0351 `negronifp_hl=1|2`: white disc (defaults 540,2080 r 95 [I placeholders], boot-arg override) drawn after each
  panel copy + the HBM-on set once via 0250's `negroni_dsi_dcs_write`. compile-one.sh clean for both files.
- [I] Risks: XPU fault on the first SE read if the TEE owns 0xa88000 (panic -> reboot with negronipanic=30);
  "QUP0 SE4 FIFO disabled" (touch) may repeat on SE2 (then: GPIO bit-bang SPI next).
- [V] Build 2026-10-26 (after the review fixes: disc on every frame via fFinishPending, ldoc11 off vote
  `negroni_rpmh_vreg_disable` in negroni_rpmh.c, step-3 XPU note): kernel `out/kernel/local-20261026-084051`
  sha256 `f8e2b492...` (195 patches applied, 0350 and 0351 among them; only the 4 usual dxb skips), image
  `out/ios16-fp` boot_a sha256 `1926dc56...` (config args +
  `negronifp=2 negronifp_hl=1 negronipanic=30 negronipanicreason=2`). The first build (081439) skipped 0350/0351
  (bsd/conf/files and present() context moved by 0310/0267): regenerated on a tree with all patches; 0350's
  conf line now follows negroni_cam.c and its init call follows negroni_bt_init().


## 26. Metal/GL audit follow-up (2026-10-26 evening, audit follow-up agent; patch 0289, flame/0013; build only, phone on Android)

Input: docs/audit/2026-10-26-metal-gl.md section 4 ("what remains"), the items that need no phone.
- [V] Kernel 0289 (`patches/xnu/0289-negroni-iosurface-lock-gpu-wait.patch`, README-gpu-kernel.md "0289"): the IOSurface
  lock trap (trap 2) waits for the surface's `gpuFence` (the 0230 import fence = the fence 0254 reads at swap time) up to
  `negronisurf_gpuwait` ms (default 50 = `NEGRONI_FB_GPU_WAIT_MS`, cap 2000, 0 = off) through `NegroniGPUFenceWait`
  (gives up at once on `gGPUStopped`), then `NegroniGPUSurfaceForCPU` over the whole surface when its user mapping is
  cached (`mapCache != kIOMapWriteCombineCache`: slots, wrapped, physical; created surfaces are write-combined), once per
  fence value (`cpuSeenFence`). Give-up log 8 times: `NEGRONI SURF: <proc> lock of surface N: the GPU (fence F) is not
  done after 50 ms: answered anyway`. `RedwoodGPU::start` sets the IORegistry property `RedwoodWaitsForGPU` (true unless
  the boot-arg is 0) and logs `RedwoodGPU: registered (the IOSurface lock waits up to 50 ms for the GPU)`.
  compile-one OK for NegroniSurface.cpp, NegroniGPU.cpp, NegroniFramebuffer.cpp. Full build 12:31 (`gl2-build`,
  `scripts/gpu/build-test-image.sh`, lock held across kernel + image): 197 patches applied (0289 among them), the 4
  usual dxb skips; kernel `out/kernel/local-20261026-123128` sha256 151428d3...; image `out/ios16-gl2` boot_a
  78c23259..., esp 851a6735..., vendor_boot c29329ee... (config args + `negronipanic=30 negronipanicreason=2`). Not booted.
  [I] Cost: the lock trap now takes gGPULock once per lock of a GPU-written surface (a fence compare when the fence
  was seen); a page walk only for cached mappings and only on a new fence.
- [V] GL library: `ngl_drm_kernel_waits_for_gpu()` (drm/negroni_drm.c, reads `RedwoodWaitsForGPU` once) and view.c
  `want_finish`: without the property the flush is `glFinish` (log `flush = glFinish (the kernel has no
  RedwoodWaitsForGPU (older than 0289): ...)`), with it `glFlush + kernel fence (default: RedwoodWaitsForGPU)`. Env and
  the `finish` files still win. [I] On today's kernels (no 0289) the new dylib therefore finishes every frame (safe,
  slower) until out/ios16-gl2 boots.
- [V] GL build housekeeping: `userland/negronigl/mesa-patches/0002-turnip-darwin.patch` deleted (an old Turnip copy the
  GL tree never compiled); `scripts/gpu/mesa-fetch.sh` applies `userland/turnip/mesa-patches/0001-turnip-darwin.patch`
  (`TURNIP_DARWIN_PATCH` in scripts/gpu/env.sh) after the negronigl patches, and `scripts/gpu/build.sh` refetches when
  any of those patch hashes changed (the stamp lists them). The Turnip patch applied cleanly on the GL base. `gl-build`
  exit 0 (12:4x): stripped negronigl.dylib 14,233,360 (38af4413...), NegroniGL 13,777,152 (90fc522a...), ngl_test
  50,496 (8f7d3778..., unchanged), backboardd unchanged (39cb14d1...); check-imports PASS (0 missing); 129/129 GLD +
  18/18 GLI exports.
- [V] flame/0013 (`userland/metal/patches/flame/0013-negroni-sync-switch-nmtl-dir.patch`): the NEGRONIMETAL_SYNC file
  switch reads `NMTL_DIR "/sync"` (was the hard-coded `/private/var/db/negronimetal/sync`); no phone behaviour change,
  the host test's `sync` file is now under its work directory. Base copy for the next patch: `out/metal/patchbase/flame13`
  (= flame 0001-0012 applied). Plugin comment at NegroniMetal.mm (the `CI_USE_MTL_DAG_FOR_CIKL_SRC` paragraph) now says
  the variable IS set (3 places) and does nothing on 20H392; metal-plan.md says the same.
- [V] Metal bundle rebuilt (`metal-build`, scripts/metal/build.sh + host-plugin-test.sh): check-imports PASS (0 missing);
  host test 12/12 PASS (unlisted, off, bundleoff, blocked, nogpu, timeout x2, deadman, device, msl, mps, watchdog, lost).
  Staged NegroniMetal 22,027,136 bytes sha256 7473f41b99b41c4faca0ec957084b3bb1f9010cbd4fd72e55f2be4dfa35ed628, Turnip
  7cb29818... (unchanged), dSYM `out/metal/NegroniMetal.dSYM`. Not pushed.
- Decision: indirect command buffers stay a clean refusal. m2v's runtime has them (`indirect_command_buffer.rs`), the
  ios-flame bridge (`bridge/NativeMetalBridge.{h,rs}`) has no ICB entry point (grep `indirect` = none), so the frontend
  has nothing to call; a bridge + frontend job of about 15 `nmb_*` calls, to start when a WebGPU/game test logs
  `executeCommandsInBuffer` skipped lines (metal-management.md section 3).
- [V] Docs drift fixed (audit section 5): metal-plan.md status line, ICB/heaps/argument-buffer row, watchdog 60/30 s,
  Chlorophyll "ran on the phone" split, probes "never run", CI_USE text; metal-design.md OPEN_MS 20000; gpu-userland.md
  patch row, phone status, flush section. On-phone test plan: metal-management.md section 4 (8 numbered steps with
  commands and the log lines to read).
- Next (phone): metal-management.md section 4 in order; step 1 boots `out/ios16-gl2` with the 7473f41b bundle.
- **Stage C (evening, fingerprint agent 2; patches 0352/0353, docs/fingerprint-plan.md section 7).**
- [V] Public source of the same HAL exists: `techyminati/android_vendor_oplus_secure`
  `biometrics/fingerprints/bsp/vendor/fingerprint/goodix_optical/goodix_G7` (`scripts/fp/get-references.sh` ->
  `out/fp/ref/oplus-secure`, commit 006d08f) and the OPLUS kernel shim `OnePlusOSS/android_kernel_oneplus_sm8475`
  `drivers/input/oplus_fp_driver/goodix_optical_fp` (`out/fp/ref/op-sm8475`, 7278ce9). Neither has an SPI frame:
  the HAL sends `gf_cmd_header_t` commands to the TA (`GF_CMD_DELMAR_SENSOR_READ_IMAGE = 101`,
  `gf_delmar_types.h:221-226`; `DelmarSensor::readImage` `DelmarSensor.cpp:333-363`), the shim does ioctls
  (`GF_IOC_*` 0..23, magic 'g'), reset = 5 ms low + 10 ms (`gf_platform.c:443-456`), `GF_IOC_ENABLE_SPI_CLK` only
  clocks the QUP for the TEE.
- [V] The module is MCU + sensor die: HAL strings `test reset and interrupt pin between mcu and sensor`,
  `fw_app_version`, `fw_bootcode_version`, `GF_ERROR_SPI_FW_DOWNLOAD_FAILED`; public header
  `DELMAR_C_CHIP_TYPE_GW183/GW183D_ECO1/2`, sensor types `SINGLE_T_SE1..SE5`, `SINGLE_CS_SE1..3`, `GM182`
  (`gf_delmar_config.h:176-189`); the stock HAL names `GF_CHIP_DELMAR_T_SE1`. Origin frame
  `DELMAR_ORIGIN_BUFFER_LEN 183456 = 364*252*2`, raw/bmp 182*132, OTP 64 bytes, chip id 32 bytes
  (`gf_delmar_types.h:52-66`).
- [V] Public Goodix MCU protocol (`out/fp/ref/goodix-fp-dump`, cc43bb3; `goodix.py:56-114`): pack `A0 len16 sum8`,
  protocol `cmd (plen+1)16 payload (0xAA-sum8 | 0x88)`; commands NOP 00, MCU_GET_IMAGE 20, READ/WRITE_SENSOR_REG
  82/80, UPLOAD_CONFIG 90, RESET A2, READ_OTP A6, FIRMWARE_VERSION A8, QUERY_MCU_STATE AE, ACK B0 (full list in the
  plan 7.1); image reply 12-bit packed 6 bytes -> 4 px (`tool.py:36-46`); SPI transport of the 5120
  (`protocol.py:147-185`): write `CC F2 seq16` + pack, read `BB F1 00 00` + clocked bytes, IRQ = answer ready.
  [I] Whether the G7 MCU speaks it over SPI is the open question; 0352 tests it.
- [V] 0352 (`negronifp=3`, `negronifp_wrap`, `negronifp_irqwait`): `gx_encode/gx_decode`, `se_tx_long/se_rx_long`
  (64-byte FIFO pieces), `gx_write/gx_read` (plain or wrapped), `irq_wait`, `gx_probe`, `mcu_probe` = step 10
  (nop, AE 55, A8 00 00, A6 00 00, 82 00 00 00 04 on both transports), verdict line `MCU probe result`. Audit
  fixes: ldoc11 vote EBUSY retry 40 x 50 ms + stop on failure. Frame check: `AE 55` = `a0 05 00 a5 ae 02 00 55 a5`.
- [V] 0353 (`negronifp=4`, `negronifp_img`): step 11 = `negroni_fp_hbm(true)`, `negroni_fb_te_wait(2, 100)` (new in
  NegroniFramebuffer.cpp: 0259's INTF_TEAR_INT_COUNT_VAL frame counter, -1 when `negronifb_te=0` -> 17 ms timed),
  `20 01 00` = `a0 06 00 a6 20 03 00 01 00 86`, HBM off right after the frame + IRQ wait (<= 100 ms; review fix), bounded read into a kmem buffer under
  one CS (early stop after 16 idle pieces; `BB F1 00 00` once, the public driver per 256 bytes), stats + verdict. `/dev/negroni-fp` (0600): 32-byte header `NFPI, 364, 252, len, mode,
  wrap, proto, 0` + bytes; `scripts/fp/raw-to-png.py` (self-test with a synthetic dump OK: u16le/u12/u8 PNGs).
- [V] compile-one.sh clean for negroni_fp.c and NegroniFramebuffer.cpp (tree out/kernel/tree-fp2, deleted).
  Build 2026-10-26 12:37 UTC: kernel `out/kernel/local-20261026-123703` sha256 `f193e9ef...` (200 patches
  applied, 0350-0353 among them, the 4 usual dxb skips), image `out/ios16-fp3` boot_a sha256 `e4ee60fa...`
  (config args + `negronifp=3 negronifp_hl=2 negronipanic=30 negronipanicreason=2`). Disk: 11 GiB free (98 %).
- [V] TA search (`scripts/fp/find-ta.sh`, string scan of the partition dump, ASCII + UTF-16 FAT names): the only
  hits for goodix/delmar/gf_ta are the device-tree node names in `dtbo_a`; `modem_a` (= /vendor/firmware_mnt),
  `oplus_sec_a`, `tz_a` have none; `oplusreserve2/3/5` (log/backup partitions) carry logcat text with the TA path
  **`/odm/vendor/vendor/firmware/goodixfp.mdt`** (`out/fp/lists/ta-scan.txt`: `goodixfp` x42, `DelmarProductTestUtils` x114,
  `oplus.optical.goodix.fp`), a path the HAL searches; the first extraction listed only odm `/firmware`, not
  `/vendor/vendor/firmware`. A second pass with `gdx|fpta|finger|optical` on
  modem/tz/oplus_sec/tzsc/keymaster/qupfw (`ta-scan2.txt`): modem = Qualcomm's own ultrasonic `qfp_*`/`QFP_*` strings
  (not Goodix), keymaster `get_fpta_name`, `GDX`/`G8DX` are unrelated modem tokens. `scripts/fp/extract-ta.sh` pulls
  `goodixfp.*` from odm.img `/vendor/vendor/firmware` into `out/fp/ta` and string-dumps it. Result [V]: the TA is at odm.img `/vendor/firmware/goodixfp.{mdt,b00-b07}`
  (= `/odm/vendor/firmware`; b01 8.0 MB, b03 4.1 MB, b06 276 KB; `out/fp/SHA256SUMS`), a 64-bit aarch64 ELF whose
  strings are in the clear (10124 unique strings >= 6 chars in `out/fp/lists/ta-all-strings.txt`; log tags
  `[gf_delmar_mcu]`, `[gf_hw_dc]`, `[gf_hw_spi]`, `[gf_delmar_t...]`). Function names show **two sensor paths**:
  `gf_bus_mcu_*` (write_cmd, poll_int_sts, checksum16, write_img_cmd, flash/otp, `soft reset mcu`, an embedded MCU
  firmware `__firmware_malibu_bin`, "It is not GM182! It's normal if single chip") and `gf_bus_dc_*` /
  `gf_delmar_t_*` (DC = direct sensor: `secspi_read_byte/word`, `secspi_write_bytes`, `get_trim`, `get_hr_image`,
  `delmar_dc_wakeup`, `gf_delmar_t_read_chip_id`, `gf_delmar_t_read_sub_version`). The stock HAL's
  `GF_CHIP_DELMAR_T_SE1` is the **Delmar-T direct path**: the AP's SPI talks to the sensor die registers, not to
  an MCU [I from the names]. So the public MCU message-pack frames of 0352 are expected to get MISO idle; the
  register-level frame format is in the TA's code (`gf_bus_dc_secspi_read_word`), which this session did not
  disassemble: whether to analyse the TA binary further is the owner's decision. A QSEE TA on a production device is encrypted
  (segments) and signed; the file would give ELF header strings only. Not needed for stage C/D.
- [V] Stage D decisions (plan 4.3): SourceAFIS Apache-2.0 (Java/C#/Rust ports), libAFIS C BSD-3 (`Simprints/libAFIS`),
  NBIS mindtct/bozorth3 public domain (inside libfprint, LGPL-2.1): pick the SourceAFIS Rust port, NBIS as the A/B
  extractor; unlock = passcode injection (a) when a passcode is set, SBLockScreenManager hook (b) only without a
  passcode; templates in `/var/db/negronifp/` encrypted with a device-derived key, no SEP, no liveness check.
- [V] Review fixes (0353 regenerated, 350 lines; 0352 untouched): HBM off right after the get-image frame + IRQ wait
  (capped 100 ms), `hbm_on` guard on the tx-failure path, `/dev/negroni-fp` 0600, `raw-to-png.py --self-test`,
  `BB F1 00 00` once-per-CS note. Proof build 2026-10-26 13:18 UTC (`KERNEL_ONLY=1 scripts/fp/build-test-image.sh`,
  no image): kernel `out/kernel/local-20261026-131837` sha256 `328dd126...`, 233 patches applied incl. 0352/0353
  (other agents' patches of the same hour included), the 4 usual dxb skips. No new warnings in negroni_fp.c.
- Lessons: `scripts/bg.sh` does not pass environment variables to the tmux command (use `env VAR=... cmd`); a
  patched-tree build of all 201 patches takes ~4 min; the full kernel + image build ~10 min with a warm dxb tree.


## 2026-10-26 handoff (main session, afternoon)

- [V] Phone state at 14:05: Android boot chain restored on slot A (Magisk boot_a, stock vendor_boot_a/dtbo_a/vbmeta_a,
  `scripts/flash/restore.sh --magisk`); `fastboot -w` was refused by the ABL ("battery's capacity is very low"), so
  userdata still holds the iOS root. The phone charges in **fastbootd** (recovery Linux + vendor charger stack): 9 % ->
  20 % in minutes. Bootloader fastboot (ABL) does NOT charge beyond the hardware default; neither did iOS (no charger
  path: no SMB5 APID, debug bus fused off; ~1 A at 5 V, all used by the phone). Lesson: charge in fastbootd or Android.
- [V] Before the iOS re-flash: `fastboot -w` or the `userdata` step (writes the root + the GPU/ADSP/WLAN/BT firmware
  areas), then `vendor_boot`, `vbmeta`, `dtbo`, `boot` with the chosen image, `active`. Root tweak change pending a root
  rebuild: FBLaunchWatchdogScale 20 -> 3 (a hung Camera launch blocked all app launches ~400 s).
- [V] Test images built today (all from the full patch set; boot-args in each cmdline.txt): out/ios16-all2 (0275 fast
  off + negronifb_sleep=0; booted 13:57: screen-off 11-16 ms, wake 0 ms, works), out/ios16-everything (every addition
  on: negroniwlan=6 negroniadsp=1 step 15, hap, cam, bt, fp, te, vrr; diagnostic boot, kernel 082825 without 0274),
  out/ios16-chg3 (0274+0276, needs the ADSP firmware area), out/ios16-soc, out/ios16-perf(-noshift) (0267/0286),
  out/ios16-vrr, out/ios16-wlan6, out/ios16-audio, out/ios16-cam, out/ios16-fp, out/ios16-bt, out/ios16-ifpc.
  Kernels under out/kernel/local-20261026-08*; the newest full kernel after 0330's fixes is local-20261026-084835+.
- [V] Booted results (kernel 081240 + 0e8450f8 Metal bundle, 13:57-14:03): 0275 OK; IFPC 0285 OK (GX collapsed 60 %
  idle); thermal 80 C boot burst -> 50 C idle; no backboardd crash; AegirPoster loop stopped after the strike clear;
  SpringBoard crash in MPS fixed by flame/0012 (not yet exercised: Siri orb); Weather/Calendar widgets blank = chronod
  did not relaunch the extensions (not Metal); Camera launch hang -> launch block (root tweak).
- Lessons for agents (added to the briefs): hold out/kernel/.lock across the kernel AND the image build (another job
  relinks kernel.macho otherwise); never run clean-builds.sh from an agent (it deleted every out/ios16-* image and most
  kernels at 13:36); patches that add a `bsd/conf/files` line collide when they use the same context (0310/0330/0350):
  anchor each on a unique neighbour; take a fresh patched-tree.sh tree when other agents' patches changed.
- Stopped by limits: the 0331 BT HCI agent and the seven audit agents (docs/audit/2026-10-26-*.md) hit the session
  limit at 14:25 (reset 17:20); resume them with one message each. The 0331 brief: Linux hci_qca.c/btqca.c port.

## 27. First boot of out/ios16-everything: panic in the apps-SMMU SMR scan (2026-10-26 23:30, main session)

- Flash: userdata (ios16-root.simg, 45 sparse chunks, 310 s in fastbootd), then vendor_boot_a, vbmeta_a, dtbo
  (erase), boot_a (1b73f70d...), slot a active. Kernel local-20261026-174831 (233 patches).
- [V] Panic (photo of the screen; USB log empty, the panic came before the USB console was up): `Kernel data abort`,
  pc 0xfffffe0007546524 = `_wlan_dma_path+0x170`, lr `+0x140` (right after the "apps SMMU sCR0 .. IDR0 .. (113 SMRs)"
  printf), far 0xfffffe51ad324800 = the SMMU mapping + 0x800 = **SMR0**, esr 0x96000010 = data abort, DFSC 0x10 =
  synchronous external abort. x8 = 0: the first SMR read faulted. Reads of sCR0 (+0), IDR0 (+0x20), IDR1 (+0x24),
  sGFSR (+0x48) in the same 16 KiB mapping answered just before (113 SMR groups, EXIDS 0, USFCFG 1, CLIENTPD 0).
- [V] The same scan is in patches 0263 (wlan_dma_path, Wi-Fi level 2 step 6), 0324 (negroniwlan_smmu=3 path) and
  0312 (camera level 3 step 13). 0243/0244 (audio) only name the address, they read nothing. The Adreno GPU SMMU
  (0x3da0000) is a different SMMU and XNU programs its SMR/S2CR fine (ADRENO step 13/19 lines in every usblog).
- [I] The hypervisor (QHEE/Gunyah) injects the SEA: Linux reports the same ESR 0x96000010 on S2CR writes for a
  stream the hypervisor refuses (purwa GPU SID 1 patch, 2026-04; lemans S2CR 0xc28). Research agent report:
  docs/notes.md section 28 (pending).
- The last line on the screen, `handshake structure not initialized`, is only the kdp shared-memory coredump stage
  (osfmk/kdp/output_stages/out_shmem.c:499) that runs after the panic text; it is not the error.
- `negronipanic=30 negronipanicreason=2` did not bring the phone to fastboot within minutes (no `fastboot devices`);
  the panic screen stayed. Reset by hand (power + volume down).
- Fallback image `out/ios16-nosmmu` (same ADT/vendor_boot/kernel; boot-args of everything with `negroniwlan=1`
  (survey only), `negronicam=2`): boot_a 6380e314..., esp 5dc6dc20.... Waiter `flash-nosmmu` flashes boot_a when the
  phone appears in fastboot.
- Fix (2026-10-27, kernel agent): new patch 0255 `bsd/dev/negroni_mmio.h` (`negroni_mmio_rd32`/`wr32`, one inline-asm
  `ldr w,[x]` / `str w,[x]`, "r" operands); 0263 (`SRD`/`SWR`) and 0324 (`SR`/`SW`, + limits 0x4e contexts / 0x78 SMRs)
  use it for every apps-SMMU access; 0312 already used the asm `rd()`/`wr()` of 0310. [V] Kernel
  out/kernel/local-20261026-182859 (sha256 9bee3bfe...), 234 patches applied, only the 4 dxb skips; objdump: the scan is
  `ldr w12, [x9]` + `add x9, x9, #0x4`, no writeback/pair/WZR/64-bit access on the SMMU mapping in wlan_dma_path,
  negroni_wlan_smmu_on/off/map/report or the camera scan (inlined in cam_thread). Gotcha: a new `#include` in 0263's
  include list broke 0265 (it anchors on that list); the include sits before `#define APPS_SMMU_PHYS` instead.

## 29. Panic over USB, ctl after a panic, timed panic reset (2026-10-27, kernel agent; patch 0360, details: patches/xnu/README-panic.md)

- [V, code] Why `negronipanic=30 negronipanicreason=2` never reset (section 27): the image has `debug=0xc`. DB_NMI (0x4)
  sets `panicDebugging` on arm64 (`osfmk/kern/debug.c` debug_init). Then `debugger_collect_diagnostics()` sends
  `PEHaltRestart(kPEPanicDiagnosticsDone)`, runs `panic_spin_shmcon()` (the "handshake structure not initialized" line)
  and `panic_spin_forever()`; it never calls `kdp_machine_reboot_type(kPEPanicRestartCPU)`. So 0211's
  `negroni_panic_restart()` never ran. [I] The old `delay(1000000)` loop also waited with WFE (machine_delay_until).
- [V, code] Why the USB log had no panic text: the live log is a thread (`ud_log_thread`, every 100 ms, socket), and in
  a panic all threads stop. The panic log body (registers, backtrace) goes through `paniclog_append_noflush` ->
  `console_write_unbuffered`, which bypasses the console ring hook in `_cnputs`; only `negroni_log_panic()` (model_dep.c)
  copies it into the ring, and only when the UFS partition log runs.
- 0360: `kPEPanicDiagnosticsDone` (sent in every panic, also with panicDebugging) enters `negroni_panic_restart()`.
  It busy-waits on `mach_absolute_time()` (no WFE, no timer), polls the DWC3 (events, ep0, ARP for 192.168.7.2, UDP
  5141 commands), sends the console ring (with the full panic log) to 192.168.7.1:5140, and runs the timed reset.
  Commands after a panic: `ping` -> `pong (panic)`, `log`, `reboot`, `bootloader`, `recovery`, `poweroff`. No lock,
  no mbuf alloc/free, no sleep in panic mode. `negronipanic=0` (default) still stays on the screen, now with ctl.
  New boot-arg `negronipanicusb=0` (off). op10tool: `ctl log` (new), `ctl ping` accepts `pong (panic)`.
- [V] Kernel out/kernel/local-20261026-185209 (sha256 1dab7ee1...), 235 patches applied, only the 4 dxb skips;
  `kernel.macho` now points to it. nm: `_negroni_usb_panic_begin`, `_negroni_usb_panic_service`,
  `_negroni_panic_restart`, `ud_panic_*`; strings `pong (panic)`, `NEGRONI PANIC: ...`; objdump: the hook's switch
  covers type 0xa (kPEPanicDiagnosticsDone) -> `bl _negroni_panic_restart`; the loop calls only
  `negroni_usb_panic_service`, `mach_absolute_time`, `kdb_printf`, `negroni_reboot`, `negroni_power_off` (no `delay`, no WFE).
- Not verified on the phone (no device): polled enumeration, ARP reply, ENDTRANSFER restart, reset from the loop.
  Test: `make usblog`, panic (or `op10tool ctl panic`), look for `NEGRONI LOG: panic log follows` and
  `NEGRONI PANIC:` in logs/usblog-*.txt, then `out/bin/op10tool ctl ping` / `ctl bootloader`.
- Gotchas: a panic before NegroniPlatformExpert::start() (no hook yet) still stays for ever. Nested-panic "Stage 1/2
  bailout" with panicDebugging still spins. The ring flush waits for any frame from 192.168.7.1 after the link is
  (re)configured (usblog.sh's `settime`) or 10 s, so the text does not go out before the Mac has its address.

## 30. Night of 2026-10-26/27: boots, bisection of the journal panic, Metal on (main session)

- [V] Panic 2 and 3 (photos; fallback images ios16-nosmmu and ios16-noidle = every feature arg except the apps-SMMU
  readers / except cpuidle): `Kernel data abort`, far 0, esr 0x96000045 (write, translation fault level 1), pc
  `_memcpy+0x48`, lr `_end_transaction+0x620` (bsd/negroni_hfs/core/hfs_journal.c:3991): `memcpy(blkptr, ...)` with
  `blkptr = &blhdrim->buffers[0]` and `blhdrim->buffers == NULL` (x8 = *(x20-8) = 0, x28 = tbuffer_offset = 0). The
  buffer comes from `hfs_malloc_data(tbuffer_size - blhdr_size)` = IOMallocData(3 MiB - 96 KiB) at transaction start
  (hfs_journal.c:2532). Right after `jnl: journal replay done` = the first write transaction of the root mount.
  The root image's volume header and journal header are sane (journaled, 8 MiB journal, blhdr_size 0x18000 = what this
  kernel computes, jhdr_size 0x200).
- [V] Bisection (same kernel local-20261026-182859 with the SMMU accessor fix, same ADT/root; each image = config
  args + the group + negronipanic/negronipanicreason): base args: boots to SpringBoard (frames presented). Power group
  (adsp, adsp_step, audio_amp, audio_tone, batt, chg_glink, chg_ma, cpufreq_floor=lut): boots. Peripherals group
  (bt=4, fp=4, fp_hl=2, hap, hap_ui, cam=2): boots to SpringBoard. Display+wifi group (fb_dbuf, dsidma, esd,
  pwrprobe, sleep, te, teirq, vrr, wifi=10, wlan=1; kernel local-20261026-185209 with 0360): boots and runs. So no
  single group panics; the panic needs a combination (next: power+peripherals = out/ios16-g12).
- [I] IOMallocData(3 MiB) returning NULL = kernel data-heap VA exhausted (not physical pages: Z_WAITOK waits for
  pages) or a corrupted pointer. The data range is a large share of the kernel map (vm_kern.c kmem_range_init), so a
  sum of the features' buffers (< 20 MiB of KMA_DATA) is unlikely; a combination effect (a map/range change, or a
  DMA engine writing into kernel memory) stays open.
- [V] Phone USB link: in the base, g1 and g2a boots the host interface vanished 6-60 s after it came up
  (`usblog: phone interface gone`), without a panic; in the g2b boot (0360 kernel) it stayed up. Not understood.
- [V] Metal on (g2b boot, 00:27): `scripts/gpu/phone-accel.sh on` -> clients `*`, strikes cleared, backboardd
  restarted; metal.log: backboardd and SpringBoard `device Turnip Adreno (TM) 730` opened (724 ms / 2034 ms),
  `dead-man: strike cleared (first command buffer completed ...)`, pipelines 17 / 6 compiled, 0 failed; FB STAT
  shows gpu presents. GL apps gate `* -backboardd`. bluetoothd crashes ("Bluetooth fatal error", reason 1201) in a
  boot without negronibt: the root's bluetoothd job has no transport then (expected).

## 31. Safari WebGL blank canvas fixed (2026-10-27, Metal agent; flame/0014 + flame/0015; full story docs/metal-webgl-2026-10-27.md)

- [V] WebGL on 20H392 runs in `com.apple.WebKit.GPU` (ANGLE Metal back end, `libANGLE-shared.dylib` in WebCore.framework). WebContent
  never asks for a Metal device. The GPU process gets our device (clients `*`), so the clients gate was not the cause.
- [V] Cause 1: `angle::IsMetalRendererAvailable()` = `MTLCreateSystemDefaultDevice()` + `[device supportsFeatureSet:4]`
  (MTLFeatureSet_iOS_GPUFamily3_v1), cached in a static per process. The frontend answered NO to every feature set -> no EGL display ->
  `getContext('webgl')` gives an object whose every call answers null (context lost at creation). Fix flame/0014: `supportsFeatureSet:`
  answered from `supportsFamily:` (iOS set 0..16 -> Apple family 1..5).
- [V] Cause 2 (after 0014): ANGLE's passes use `resolveTexture` (MSAA default framebuffer, depth resolved in the pass; the frontend dropped
  it -> `RenderPass(ResolveWithoutTexture(Depth))` refusal), late store actions (`MTLStoreActionUnknown` + `set*StoreAction:` at
  endEncoding) and the LOD-clamp sampler selectors (`setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:` -> `MISSING` ->
  NSInvalidArgumentException -> GPU process gone). Fix flame/0015: bridge (`NmbPassAttachment.resolve_*`, `nmb_render_set_*_store_action`)
  + frontend selectors. The bridge struct grew: bridge and plugin rebuilt together (`build-bridge.sh` incremental 6 s).
- [V] Result: WebGL 1 + 2 contexts, correct pixel read-back, three.js keyframes example runs (presents/s 4-11, 105 ANGLE pipelines,
  GPU pid stable, no crash). Plugin sha256 `4ce44784…22fa` on the phone (pushed, no reboot). `host-plugin-test.sh`: 0 failed.
- [V] Pipeline compiles on our device are slow: 0.1-1.2 s per ANGLE render pipeline (`pipelines.log` R lines, samples=4): a heavy page
  spends its first seconds compiling. Shader cache warms the second load (probe page 60 frames: 6.5 s cold -> 1.5 s warm for WebGL 2).
- [V] Symbolication recipe for libANGLE frames in metal.log backtraces: `ipsw dyld macho DSC libANGLE-shared.dylib --loads` gives the
  __TEXT base (0x1ce2b5000 in the 20H392 cache), add the `+ offset` of the frame, `ipsw dyld a2s DSC ADDR`. `ipsw dyld extract` +
  `--symbols` lists the objc_msgSend$selector stubs a dylib uses (which selectors a client sends our device).
- [V] New tools: `scripts/net/phone-open-url.sh URL` (uiopen, opens Safari over SSH, no tap), `scripts/metal/webgl-test.sh` (probe page
  served from the Mac over the USB link, results reported back), `scripts/metal/angleprobe.sh` (the ANGLE path as a root CLI).
- [V] Upstream metal2vulkan: 688 commits after our pin 720ef1ce (master = development = f6a96b7d, 2026-10-26); heavy churn in every file
  our m2v patches touch (render.rs 70, command_buffer 65, device 43). Not rebased: the blank canvas was ours; the runtime at the pin
  already has late store actions and resolve attachments.
- [I] Next WebGL items: frame rate on real pages (pipeline compile time; `samples=4` passes on every WebGL canvas with antialias),
  WebGPU (`webgpu.github.io/webgpu-samples`) untested, `Safari` screen content not seen from the Mac (owner checks).

## 32. USB Ethernet throughput (2026-10-27, kernel agent; patch 0361, details: patches/xnu/README-usb.md)

- [V] Before: 1.0-1.2 MB/s both ways, with SSH and with raw netcat (16 MiB in 13.6-15 s), ping 1.4 ms.
- [V] The link is high speed: kernel log `NEGRONI USB: connected, speed 0` (DSTS CONNECTSPD 0 = HS), macOS ioreg
  `USBSpeed` 3. The `DSTS 0x00820001` of the "running" line is read before the host connects: ignore its speed bits.
  No HS PHY / eUSB2 work is needed.
- [I] Cause: one TRB per direction, armed again only on the next 1 ms poll of ud_thread = one frame per poll
  (1514 B / ~1.2 ms = the measured rate). Also a TX queue of 32 that dropped frames.
- Fix 0361: RX ring of 32 TRBs (CSP, link TRB, re-armed per 64-byte cache line + UPDATETRANSFER, because the DMA is
  not coherent), TX batches of up to 32 frames per transfer, TX queue 128, one ifnet_input per poll, 200 us polls
  while busy. Counters: a log line every 10 s with traffic and `op10tool ctl usbstats` (new ctl command).
  Fallback: `negroniusb_ring=0` (old one-TRB paths), `negroniusb_pollus=0` (old 1 ms poll).
- Not tested on the phone yet (build only). Check the boot line `RX ring 32 TRBs, TX batch 32, queue 128`.

## 33. Proofs on the phone, 2026-10-27 01:30-01:38 (main session)

- [V] 0360: the g12 boot (power + peripherals args, kernel local-20261026-200003) panicked in the journal again
  (same `_memcpy+0x48` from `_end_transaction+0x620`, far 0, esr 0x96000045) and the whole panic text (panic
  string, registers, pc/lr/far/esr) arrived in logs/usblog-20261026-233816.txt at 01:32:41, followed by
  `NEGRONI PANIC: USB not configured (waiting for the host): console ring 66777 bytes ...` and `staying on the
  panic screen (negronipanic=0)`. `op10tool ctl ping` -> `pong (panic)`; `op10tool ctl bootloader` ->
  `ok bootloader (panic)` and the phone was in fastboot within seconds. No button press needed any more.
- [V] 0361: boot line `NEGRONI USB: RX ring 32 TRBs, TX batch 32, queue 128 (negroniusb_ring=1)`; raw TCP with
  netcat (16 MiB): host->phone 36.7 MB/s (was 1.2), phone->host 28.7 MB/s (was 1.1). `op10tool ctl usbstats`:
  rx 16964 frames, tx 16659 frames, tx drops 251, rx max 26/poll, tx max 32/batch, poll 200 us. The tx drops
  (251 of 16659) are TCP's own back-off material; a larger TX queue or back-pressure to the stack is a later
  tune. The host tool out/bin/op10tool must be copied from tools/op10tool/target/release after a cargo build.
- Bisection: power + peripherals together panic; each alone boots; display+wifi alone boots. Diagnostic patch
  for the kernel data range in progress (agent).
- New: scripts/debug/panic-symbolize.sh [LOG [KERNEL]] | -a ADDR...: the last panic in the USB log ->
  esr/far decoded, pc/lr/caller as symbol+offset, disassembly around pc; saved to logs/panic-<time>.txt.

## 34. Journal panic: kernel VA and memory numbers, diagnostic patch 0362 (2026-10-27, kernel agent)

- [V, build.log + code] The kernel is built with `-DARM_LARGE_MEMORY=1` and `XNU_PLATFORM_MacOSX` (dxb uses the
  macOS SDK): VM_MIN_KERNEL_ADDRESS 0xfffffe0000000000, VM_MAX_KERNEL_ADDRESS 0xfffffe8fffffffff (576 GiB), the
  physmap sits below VM_MIN (arm_vm_init.c:1901), kernel_map = [dynamic_memory_begin, VM_MAX] (pmap.c:2222),
  zone map VA 128 GiB (zalloc.c:164, MacOSX values). [V] panic pc 0xfffffe0007... matches this layout.
- [I, code arithmetic] kmem_add_extra_claims (vm_kern.c:3524): L = largest free hole after the static claims
  (zones 128 GiB, IOKit pageable 4 x 512 MiB, io_submap 8 MiB, compressor, ipc, mb, bufs) = about 440 GiB;
  3 ptr ranges of L/8 (about 55 GiB), sprayqtn = min(L/8, sane_size/2) = 1.5 GiB, **data range about 270 GiB**.
  So the data VA range is NOT the limit: all feature buffers together use less than 120 MiB of it.
- [V, code] The other way kalloc_large(Z_WAITOK) returns NULL: vm_page_alloc_list (vm_resident.c:6790). When
  vm_page_grab() finds no page and wired + free_target pages > max_mem - request, it returns
  KERN_RESOURCE_SHORTAGE (6) at once (no wait). XNU has only 3 GiB (ADT `--dram 840000000:C0000000`).
  KERN_NO_SPACE (3) = no VA hole. Known feature buffers wire less than 30 MiB [I].
- [V] The g12 panic log (logs/usblog-20261026-233816.txt 01:32:41) has the context: `RedwoodGPU: write-combined
  pool ... (512 MiB)`, ADSP step 1 done, `NEGRONI ADSP: 2 firmware area: 44 files` (ADSP step 2 runs at the same
  time as the root mount), then `jnl: ... journal replay done.` and the data abort. x20 0xfffffe200085df08.
- 0362 `negroni-kmem-report` (diagnostic, no boot-arg): one line after kmem_range_init (`NEGRONI KMEM:
  kernel_map ..., data range ..., ptr ranges N x M MiB, sprayqtn ...`), one line before the root mount
  (`NEGRONI KMEM: before root mount: ... data range used/free/largest hole; pages free/wired/free_target/reserved,
  max_mem`), on each kalloc_large failure (first 16, then every 256th) `NEGRONI KMEM: kalloc_large(N) failed: KR
  (heap ..)` + the report line, and in journal_allocate_transaction `NEGRONI KMEM: hfs journal transaction buffer
  of N bytes is NULL` + the report line. Reading of the next g12 boot: kr 3 = VA (unexpected), kr 6 = physical
  pages / wired memory (check `wired` vs `max_mem`), no NULL line before the abort = the pointer was overwritten
  after the allocation (corruption, for example a DMA engine), not an allocation failure.
- [V] Kernel out/kernel/local-20261026-201152 (sha256 c2ed65f9...), 237 patches applied, only the 4 dxb skips.
- [I] Side note: 0243 (audio ring), 0315 (camera frames) and 0316 (HFI) call kmem_alloc_contig with max_pnum
  atop(4 GiB) - 1, but all XNU RAM is at 0x840000000 and higher: these calls can never succeed on this port.

## 35. Widgets black / crashing (2026-10-27, Metal agent; full story docs/metal-widgets-2026-10-27.md)

- [V] FitnessWidget `sig 9 reason ns 1 code 0x7` (jetsam per-process limit) x3 per boot, 1-8 s after our device opened,
  inside `VFXCore.Renderer.init` -> `newDefaultLibraryWithBundle:` (VFX.framework default.metallib 3.17 MB) ->
  `metal2vulkan Library::from_metallib` (`bytes.into()` copy, memmove). Every WidgetKit extension has a 30 MiB fatal
  limit (new tool `scripts/metal/memlimit.sh` = userland/metal/tools/memlimit.c, root: `memorystatus_control` +
  `proc_pid_rusage`); chronod runs at 31 MiB with the device, widgets at 4-13 MiB without it.
- [V] MusicWidgets (strlen(NULL) in `-[MPMediaLibrary _MediaLibrary_coreLibrary]`), SleepWidgetExtension and
  SafariLinkExtension (sig 11 at the Swift extension entry right after `cs_invalid_page` on their own __TEXT page) never
  load Metal and crashed the same way at 00:04/00:26, before the gate was `*`. Not Metal.
- Fix: plugin rule `memory_rule` in NegroniMetal.mm (jetsam limit < NEGRONIMETAL_MIN_LIMIT_MB=48 from task_info +
  syscall 534 `memorystatus_available_memory`, or NSExtensionPointIdentifier com.apple.widgetkit-extension -> no device;
  0 = off). Every process now logs `memory: footprint .. jetsam limit .. extension point ..` at the gate.
- [I] "All black": chronod renders every widget snapshot on our device since the gate is `*` (465x465 2-plane
  surfaces, 2 pipelines, 0 refused). No screenshot path; the test is `-chronod` in /var/db/negronimetal/clients +
  `kill -9 chronod` (doc, section 4). Side note [V]: com.apple.WebKit.GPU footprint 396 MiB against a 300 MiB fatal
  limit (memlimit.txt) - watch for jetsam of the GPU process under WebGL.
- No crash report files: ReportCrash is removed (root-tweaks-extra.py); the kernel CRASH lines are the only record.

## 35. ROOT CAUSE of the root-mount panic: boot_args command-line length mismatch (2026-10-27 02:00, main session)

- [V] Diagnostic boots with 0362 (+ two extra prints): `NEGRONI KMEM: size_up_tbuffer: hw.memsize
  7450482243115248993 -> def_tbuffer_size -1006239744`. 7450482243115248993 = 0x67656e20323d6d61 = the bytes
  "am=2 neg" = part of our boot-args ("negronic**am=2 neg**ronipanic=..."). The kernel data range was healthy (255 GiB
  free, 190520 free pages): not a memory problem.
- [V] Mechanism: DarwinBoot (external/UniXNU/drivers/DarwinBoot/DarwinBootPkg/Driver/BootArgs.h) writes the macOS
  arm64 boot_args: CommandLine[1024] at 0x6c, BootFlags at 0x470, MemorySizeActual at 0x478. Our iOS 16 xnu had
  BOOT_LINE_LENGTH 608 (pexpert/pexpert/arm64/boot.h), so it read bootFlags/memSizeActual at 0x2d0/0x2d8 = command
  line bytes 612..627. Any command line longer than about 620 bytes became max_mem_actual (hw.memsize). The HFS+
  journal computes `def_tbuffer_size = 128 KiB * (memsize / 256 MiB)` as an int -> negative -> IOMallocData(negative)
  = NULL -> end_transaction memcpy to NULL. Image command lines: base 431, g2b 585, g12 661, everything 835 bytes: the
  two that panicked are the two over 620. The bisection "any two groups together" was only the length.
- Also explains: boot-args after byte 607 were never seen by the kernel (cut off), so features at the end of a long
  list were silently off in earlier boots.
- Fix: patches/xnu/0363-negroni-boot-line-1024.patch (BOOT_LINE_LENGTH 1024 = DarwinBoot's layout). Guard:
  scripts/ios16/build.sh refuses boot-args of 1024 bytes or more. Variant list: scripts/ios16/variants/everything.args.
  The slop shim loader (external/slop/shim/loader.c, 608) is a different boot path (not used with UniXNU).

## 37. Wi-Fi: SMMU re-check (0325), API seam, join, HTT data path, WPA2-PSK (2026-10-27, kernel agent; patches 0325-0329, details: patches/xnu/README-wifi.md "0325", "0326-0329")

- The owner approved the SMMU write path, and 0325 first made `negroniwlan_smmu=3` the default. After the 0249 SEA
  (section 45: Gunyah refuses GR1 CBAR writes of some "free" banks) the default is `negroniwlan_smmu=1` again; `=3` is
  opt-in until the bank probe says which banks HLOS may write. 0325 also takes `negroni_smmu_claim_lock` (0249), re-reads
  the SMR before writing, and its teardown writes only registers that setup proved writable.
- [V, live.dts pcie0] `iommu-map` RID 0 -> 0x1c00, RID 0x100 -> 0x1c01, `qcom,smmu-sid-base 0x1c00`; wlan iommu group:
  `iommu-faults = stall-disable, HUPCF, no-CFRE, non-fatal`, `iommu-pagetable = coherent`, pcie0 `dma-coherent`.
- [V, pci-msm.c msm_pcie_config_sid] Android programs the PCIe BDF-to-SID table (PARF 0x2c00 bit 0 BYPASS off, 256
  hash entries at PARF 0x2000, BDF 0x100 -> SID offset 1 at crc8 hash 0x15) on every link enable. Our survey resets the
  core at step 7, so the table is at reset. [I] Without it the chip may DMA as SID 0x1c00: the 0263/0324 SMR for 0x1c01
  alone could miss it. 0325 programs the table (policy 3) and the SMR matches 0x1c00 mask 1.
- [V, U-Boot qcom-hyp-smmu.c] free context bank = CBAR type S2_TRANS, or S1_TRANS_S2_BYPASS with VMID 0xff; it then
  writes S1_TRANS_S2_BYPASS VMID 0 + CBA2R VA64. HakiOS redwood_wifi.c (SM7325, Gunyah) did the same SMMU stage-1
  setup for WCN6750 (stream 0x1c00 mask 1, SMR 8 / context 7) and it worked on its phone (comment, 13 October).
- [V] Kernel out/kernel/local-20261026-202932 (sha256 c8c3a9d5...d0eb) contains the first 0325 (without 0363 and without the
  review fix of the SMR reuse rule; a later kernel of this agent carries both), 238 patches applied, only the 4 dxb skips;
  kernel.macho points to it (build-local.sh relinks). objdump: every apps-SMMU access in negroni_wlan_smmu.c is a plain
  `ldr w, [x]` / `str w, [x]` (50 / 18); the writeback stores there are page-table entries in RAM.
- Not run on the phone. Test boot args: `negroniwifi=10 negroniwlan=10 negronipanic=30 negronipanicreason=2`.
- 0326 `bsd/dev/negroni_wlan_api.h`: the seam for the iOS side (caps, register rx/event callbacks, link, scan + results,
  associate/disassociate, 802.3 TX); every associate ends with LINK_UP or LINK_DOWN, every scan with SCAN_DONE.
- 0327 join (open): PEER_CREATE before VDEV_START (WCN6855 vdev_start_delay), AUTH/ASSOC by WMI mgmt TX from a DMA slot,
  PEER_ASSOC from the AP's elements, VDEV_UP, AUTHORIZE; link loss by deauth/kickout/roam/10 s without beacons.
- 0328 HTT data path (ath11k dp/hal for WCN6855, polled, Ethernet encap/decap): common rings before HTC READY, REO dst
  before WMI INIT, LMAC rings + HTT SRING_SETUP after READY, REO queues per peer; CE4 for HTT out. `negroniwlan_dp=0` off.
- 0329 WPA2-PSK: HakiOS lx_wpa.c ported as negroni_wlan_wpa_crypto.c (MIT notice kept); [V] its own host test
  (tools/wpa-test, reference AP in Python cryptography, ASan/UBSan) on the port: 195 checks, 0 failed. Keys by
  WMI_VDEV_INSTALL_KEY after message 4 left; no MFP, no TKIP group, no WPA3.
- None of 0326-0329 has run on the phone; the DMA path needs `negroniwlan_smmu=3` (bank probe) or another IOVA answer.
- 0325 rework after the SMMU agent's panic decode (FAR = GR1 CBAR(74), a stage-2 bank): banks from MAX(IDR1.NUMS2CB, 1),
  skip 0249 probe verdicts READ_ABORT/CLAIM_REFUSED/OURS, try-reads and claim writes through 0297 negroni_mmio_try_rd32/wr32
  (a refusal skips the bank), no CBAR/CBA2R write-back on teardown, TLB sync 500 ms, default still negroniwlan_smmu=1.
- [V] Kernel out/kernel/local-20261026-213256 (sha256 80017d10...3d141c5e) has 0325 (rework) + 0326-0329 with 0249/0297/0363:
  257 patches applied, only the 4 dxb skips; kernel.macho points to it. objdump: negroni_wlan_smmu_on calls
  negroni_mmio_try_rd32 5 times and negroni_mmio_try_wr32 3 times (scan reads, claim writes and read-backs).
- [V] Phone t6 (kernel local-20261026-214005, negroniwlan_smmu=3): the stage-1 claim works under Gunyah (context 6,
  SMR6 0x80011c00, pool IOVA 0xa0000000); BHI SBL (512 KiB at 0xa0010000) done at once; then MHISTATUS 0 / EE 0 for 10 s,
  no SMMU fault (FSR 0, sGFSR 0). MHI VER reads 0xdeadbeef in PBL. Cause not known yet.
- 0339 (renamed from 0337: the number was taken by BT meanwhile) dumps the cnss2 boot registers (BHI all, PBL logging,
  SBL log pointer, PBL boot cfg/bootstrap status, WLAON power status, scratch, PBL/SBL log SRAM) before the doorbell, after
  BHI DONE, every 3 s while waiting for READY (now 30 s) and at the time-out; the SBL image's ELF magic through the NC view.
- Review fixes (Opus REJECT -> fixed): 0325 claim order/skip list/TLBSTATUS/-2/SMR reuse/TLB sync results; 0328 D1-D7
  (link-desc alignment, buffer ownership + repost list, aligned HW pointers, pdev id 0, REO PN check, decrypted-only
  after keys, soft data-path failure) + PEER_UNMAP/queue/state notes; 0329 W1-W4 (KRACK: no re-install, TPTK, GTK 16
  bytes idx 1..3, failed rekey -> down) + INSTALL bit, beacon RSN in message 3, key-complete match, MIC by pointer.
  [V] adapted HakiOS wpa-test on the changed port: 231 checks, 0 failed.
- [V] Kernel out/kernel/local-20261026-215923 (sha256 ba34cb32...1c669e): 263 patches applied, only the 4 dxb skips; it
  was built with the patch still named 0337 (same content; only comments now say 0339); kernel.macho points to it.

## 38. Camera + audio DMA addressing, iOS camera stream (2026-10-27, kernel agent; patches 0249, 0317, 0318; details: patches/xnu/README-camera.md "0317, 0318 and 0249", plan docs/camera-ios-2026-10-27.md)

- [V] Bug: 0243 (audio ring), 0315 (frames) and 0316 (HFI) allocated with `kmem_alloc_contig(max_pnum = 4 GiB - 1)`,
  but all XNU RAM is at 0x840000000+: the allocations always failed. Fixed: allocations anywhere + an apps-SMMU
  stage-1 context of ours (new helper `bsd/dev/negroni_smmu_s1.c`, 0249, a generic copy of the Wi-Fi 0324/0325
  sequence; TODO one shared negroni_smmu.c for both). No collision with Wi-Fi: top-down vs bottom-up, U-Boot CBAR
  free rule (as 0325), SCTLR.M/S2CR checks, SMR re-read before each write, CBAR/CBA2R restored.
- [V source] Audio: Android gives the ADSP `IOVA | (0x1801 & 0xf) << 32` from the msm-audio-ion context (pool
  0x10000000 + 256 MiB, live.dts:24782-24791), not a physical/carveout address: out/src/op-modules
  vendor/qcom/opensource/audio-kernel/dsp/msm_audio_ion.c:37 (MSM_AUDIO_SMMU_SID_OFFSET 32), :276-279 (IOVA |= SID
  bits), :901-904 (SID from the iommus cell & qcom,smmu-sid-mask). 0249: ring at IOVA 0x10000000, ADSP
  address 0x110000000. `negroniaudio_smmu=0` = old path.
- Review fixes (Opus review ACCEPT + FIX, applied): the exported claim lock `negroni_smmu_claim_lock` (header
  negroni_smmu_s1.h) is held from the free-entry scan to the last SMR/S2CR/CBAR write and over the teardown; the
  CBAR is read again right before it is written; map checks the TLB sync. Wi-Fi 0324/0325 is outside the lock until
  it takes it. Camera: HFI block freed only after the SMMU teardown and kept (leaked) when the ICP PAS shutdown
  fails; >= 1 MiB unmapped IOVA after each buffer; /dev/negronicam root:mobile 0660.
- Camera 0317: `negronicam_smmu=3` (default at level >= 5): IFE SMR 0x800/0x460, ICP (level 6) 0x2000/0x2040/0x2100
  mask 0x420 + 0x2080/0x400; frames at IOVA 0x10c00000+, HFI in Android's fw_uncached (0x10400000) + shared
  (0x800000) layout. ICP PAS SCM resume loop 2000000 (as 0240).
- Camera 0318: `negronicam=7` publishes `/dev/negronicam` with the HakiOS `/dev/hakios-camera` ABI (120-byte header,
  magic NCFRAME1); a read starts a session (bring-up, 3-place ring, SOF address rotation), last close / 1 s idle /
  fault ends it. iOS side (not started): port HakiOS camera_device.c + camera_isp.c + the vendor hook
  (20H392 `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` = 0x1a1f40c84, other addresses in the plan),
  ADT `/arm-io/isp camera-rear=1`, `/product/camera`.
- [V] Kernel out/kernel/local-20261026-210550 (sha256 87b572181039611225db8bb5d84357bf302b1bad352dc9ddccfeebe770ae7bc5, with the review fixes),
  249 patches applied, only the 4 dxb skips; build-local.sh relinked out/kernel/kernel.macho to it. Not run on the phone.
- Test boot: `negronicam=5 negronipanic=30 negronipanicreason=2` (TPG only: + `negronicam_src=1`), then `negronicam=7`.

## 39. Bluetooth: stage A step 4 root cause, patch 0334 (2026-10-27, kernel agent; details patches/xnu/README-bluetooth.md "0334")

- [V] The everything boot stopped at step 4 because `gcc_qupv3_wrap_2_s_ahb_clk` is a hardware-gated branch:
  CBCR 0x80000002 = CLK_OFF + HW_CTL. Linux skips the halt check in that mode (clk-branch.c `clk_branch_wait`);
  0330 waited for CLK_OFF = 0. The vote bits worked (core, core_2x, m_ahb, s5 on). 0350 (fingerprint) stops on the
  same bit in the same boot (`wrap_1_s_ahb ... CBCR 0x80000002`): the same fix applies there (not changed).
- 0334: on / hw-gated / OFF branch states; RPMh BCM `QUP2` vote (qup-core, 5000 kBps = CORE_2X_100_MHZ, bcm-voter
  arithmetic, vote_scale 1) through new `negroni_rpmh_qup_bcm`; failure only logged; `negronibt_bcm=0`, `negronibt_bcm_kbps`.
- [V] GENI SE firmware: the OnePlus kernel never loads it; upstream loads it only for protocol 0xff + `firmware-name`
  (absent on SM8450) -> the boot chain loads it. [I strong] step 5 shows protocol 2.
- [V] Userland is ready up to the transport (logs/phone-log-20261027-004129.txt): ADT `bluetooth` node, bluetoothd job,
  negroni-bluetool boot/init result 0, keychain reads/writes result 0 (no bergamota keychain blocker). Reason 1201 =
  transport init failed (CTLIOCGINFO on a kernel without 0332, or a chip-FAILED transport).
- [V] The phone's WLAN area holds the BT pack (WLAN: `firmware area has 199 files`).
- Build: out/kernel/local-20261026-204513/kernel.development.negroni sha256
  f3c1e0d222eb3b8181c172cb82724ad826f4ee13c05b601055a5db28a4723de4 (all patches applied, only the 4 dxb skips).
  Not run on the phone. Test boot-args: `negronibt=4 negronipanic=30 negronipanicreason=2` (+ `ADT_BT=1` image, BT root).
- 0335 (owner bug "Bluetooth cannot be switched off"): with a failed chip, each host command gets a local Command
  Complete with status 0x03, not EIO. [I] Before, bluetoothd hung in its power-on.
  With a working chip, power follows the client: 3 s after the last close, BT_EN goes low; the next connect powers
  the chip on again (BT_EN sequence + HCI stage).
  [V] The 2-minute repeats in usblog-20261026-233816 are whole phone reboots.
  [V] bluetoothd keeps the switch as `defaultPoweredState` through SCPreferences
  /Library/Preferences/SystemConfiguration/com.apple.radios.plist (the file was empty, so the default was on). [I] The
  key lives in that file.
  Build: out/kernel/local-20261026-205555 sha256 7c3a4660b85f8061db979cc17bc9e151a21bf1517165b5512e833392a62f6281
  (0334 + 0335 applied, only the 4 dxb skips). The table is in README-bluetooth.md "0335".

## 40. Fingerprint overlay: lock screen + capture only; QUP1 hw-gated clocks (2026-10-27, kernel agent; patch 0354, details patches/xnu/README-fingerprint.md "0354")

- [V] The white disc on the display came from `negronifp_hl=2` in the everything boot-args (0351 drew it on every
  frame from boot and made every GPU frame wait on its copy fence in presentFinish). The main session dropped the
  boot-arg; 0354 changes the semantics: `negronifp_hl=1|2` only ALLOWS the overlay, nothing is drawn by itself.
- 0354 (NegroniFramebuffer.cpp): shown = 1 the lock-screen glyph (two thin rings, 25 % blend, no fill, no HBM) while
  `kern.negroni_fp_ui=1`; 2 the capture disc only while 0353's capture window is open (2 s timeout) and a finger
  is inside the circle (negroni_touch.c -> `negroni_fp_touch`); else nothing, no fence wait, no per-frame cost.
  Drawn after each copy and at once on a state change (`negroni_fp_overlay_update`, pixels under it saved and
  restored; not while zero-copy is active). `negronifp_hl=2` skips the HBM DCS set in the capture.
- 0354 (negroni_fp.c): sysctl `kern.negroni_fp_ui` (root writes); step 11 waits `negronifp_fingerwait` (10 s) for
  a finger before HBM + disc (no finger: no HBM, no disc, the protocol test runs); step 2: `wrap_1_m_ahb`/`s_ahb`
  with HW_CTL (CBCR 0x80000002, where 0350 stopped on the phone) are not checked, as Linux clk_branch_wait and
  0334 for QUP2; RPMh BCM `QUP1` vote first (0334's `negroni_rpmh_qup_bcm`, `negronifp_bcm=0` skips).
- Userland: `userland/fp/negroni-fpd.c` (root launchd daemon, notify(3) `com.apple.springboard.lockstate` /
  `hasBlankedScreen` -> `kern.negroni_fp_ui`), `userland/fp/build.sh` (built: out/fp/userland/negroni-fpd),
  `FPD=1 scripts/fp/root-add-fpd.sh ROOT` (root-finish.sh hook, default off; tested on a fake root: job
  `com.iosplus10.negroni-fpd` in the launchd cache). [I] the notification names/states are the public ones; not yet
  seen on this port's SpringBoard. The glyph needs `negronifp_hl=1` + a `FPD=1` root; it also shows over Control
  Center / Notification Center / the camera on the lock screen.
- Opus review REJECT -> fixed and regenerated: F1 one IOLock around every drawing and state change, save buffer
  and lock made once at the boot-arg parse (no IOFree/realloc race); F2 fingers tracked in every mode (the
  default negronifp_hl=0 capture keeps its finger-gated HBM); F3 the glyph is a fixed dim grey 0x505050, not a
  blend (idempotent over re-copies); F4 presents counted in present(); limits [I]: a stale 191x191 restore after a
  present that did not rewrite the area, one frame without the glyph when a direct drawing held the lock.
- Test boot-args: `negronifp=4 negronifp_hl=2 negronifb_te=1 negronipanic=30 negronipanicreason=2` + `FPD=1`
  root. Expect `clock wrap_1_s_ahb hw-gated (CBCR 0x80000002 ...)` then step 3 (new), `capture: put a finger on the
  sensor area (10 s)`, `NEGRONI FP HL: overlay capture disc (...)` while the finger is on the circle, and
  `overlay lock-screen glyph (ui 1, ...)` at lock / `overlay off` at unlock with the daemon.
- Build (after the review fixes): see the SHA256 line below (all patches applied incl. 0334, 0354, 0364; only the
  4 dxb skips; link out/kernel/kernel.macho). Not run on the phone; no image built.

## 41. 120 Hz display mode for UIKit, charging state for the battery UI (2026-10-27, kernel agent; patches 0364, 0365; details docs/display-refresh-plan.md section 9, patches/xnu/README-battery.md section 13)

- [V disasm 20H392] `UIScreen.maximumFramesPerSecond` = round(current `CADisplayMode.refreshRate`); `CADisplayMode
  refreshRate` = bits 29..53 of QuartzCore's packed mode / 65536 (the timing's `SyncRate`, 16.16). Modes come from
  the IOMFB service properties `TimingElements`/`ColorElements` (`IOMobileFramebufferGetSupportedDigitalOutModes`),
  the current mode from GetBlock (selector 79) block 0x40, 40 bytes, ids at +4/+8. No ProMotion/MobileGestalt gate;
  60 only for old-SDK apps; third-party CADisplayLink keeps the `CADisableMinimumFrameDurationOnPhone` rule.
- [V log] Before 0364: backboardd `sel 79 ... out 0/40` and `out 0/1580` answered with zeros; `FB STAT swaps/s` max 97,
  most active seconds 52-66.
- 0364: `TimingElements` 1125x2436 @ `negronifb_modehz` (default 120) + GetBlock 0x40 = (1, 1); `negronifb_modes=0`
  = off. Port of HakiOS `MiniIOMobileFramebuffer.cpp` publishModes (APSL 2.0). VRR (0259) unchanged.
- [V log] Without the ADSP the charger feeds 0.5-1 A at ~5 V (`iin` 495-999 mA) while BCL `ibat` reads 0 at rest and
  -849 mA under load: 0271/0276 said `charging=0` (no bolt). 0365: `IsCharging` = VBUS + `iin` >= 100 mA (charger
  active, Apple/Linux meaning), PD `BATT_STATUS` when the ADSP charger PD is up; `AdapterDetails` Watts/Current/
  AdapterVoltage measured, `FamilyCode` from PD `USB_ADAP_TYPE` (id 7 on OPLUS; HakiOS uses id 6 `USB_TYPE` on its
  Poco firmware); `Amperage` filtered, times to full/empty. New log line `NEGRONI BATTERY: charge: ...`.
- Build: out/kernel/local-20261026-213038/kernel.development.negroni sha256
  127cae2a976695d78131e9116be18f99daa601010f80aa4520b8de9698ac9c7c (after the review fixes B1, C1-C3, C5) (257 applied incl. 0363-0366, only the 4 dxb
  skips). Not run on the phone; no image built. Test with `scripts/ios16/variants/everything.args` (needs
  `negronibatt=5` for VBUS/iin); fallback `negronifb_modes=0`.

## 42. Wi-Fi greyed out in Settings: wifid never starts; iOS side 0340/0341 (2026-10-27, kernel agent; details patches/xnu/README-wifi.md "0340-0341")

- [V] ROOT CAUSE: the launchd job `com.apple.wifid` has `_LimitLoadToDeviceTree = ("wlan", "marconi-wifi")`. launchd
  20H392 checks it with MIG 2887 `io_device_tree_entry_exists_with_name` = `IODTFindMatchingEntries(root, recursive,
  name)`. Our ADT has neither node, so wifid never runs: `bootstrap_look_up of WiFiManager server failed`,
  `WiFiManagerClientCopyDevices failed: NULL` (phone-log-20261027-004129). [I] Settings disables the switch without a
  WiFiManager device; Control Center only changes its own state.
- [V] HakiOS hit the same gate (`userland/mkjobs.py:271-273` drops the key). We make the DT entry in the kernel.
- [V] IO80211.framework 20H392 matches `IO80211Controller`, then `IOPropertyMatch` `IO80211InterfaceRole` =
  `Infrastructure` + `IOInterfaceName`, and without a user client "Falling back to IOCTL path". XNU passes unknown
  interface ioctls to the driver (bsd/net/if.c:3548-3564), so SIOCGA80211/SIOCSA80211 reach en0.
- 0340: DT entry `wlan` at boot (before launchd), en0 (KPI ifnet, subfamily Wi-Fi, chip MAC) when the 0326 seam is
  IDLE, property-only IO80211Controller + IONetworkInterface, worker thread, KEV_DL_LINK_ON/OFF, soft radio switch,
  fake radio `negroniwlan_ios=2`. 0341: Apple80211 gets/sets + class-6 events (HakiOS layouts, 16.5). Port of HakiOS
  APSL 2.0 files, notices kept. Numbering 0340-0345 = Wi-Fi iOS side (main session).
- Opus review REJECT -> fixed: join sequence number + one state-based reconcile (no bit-order decisions; network
  switch ends up on the new BSS), 40 s join time-out (ETIMEDOUT), en0 down on driver FAILED/OFF, SSID not logged,
  root only for sets and gets 1/9/11/103 ([V] wifid has no UserName = root), RX in one 2 KiB cluster mbuf (ue0
  pattern; mbuf_allocpacket panicked on this phone). README-wifi.md "0340-0341" item 8.
- Build: out/kernel/local-20261026-212322/kernel.development.negroni sha256
  df262c5674234271c161e1cb03d9862f9baed459f996603a42191ea959122316 (254 applied incl. 0326, 0327, 0340, 0341; only
  the 4 dxb skips; link out/kernel/kernel.macho). Not run on the phone; no image built.
- Test: first `negroniwlan_ios=2` (UI only: 3 fake networks, passphrase `negronifake`), then everything.args.
  Expect `NEGRONI WLAN iOS: ... IODeviceTree "wlan" made`, `en0 attached`, `wifid gets/sets ...` lines, and the
  180 s per-type summary (the list of requests still refused).
- Scratch: out/src/hackios-next (HakiOS clone, shared with another agent) is still there; delete it when nobody needs it.
- Build: out/kernel/local-20261026-211510/kernel.development.negroni sha256
  32100110d7d51d500072de5a946cf929d674304354f9f979951b0e59dff8587c (252 patches applied incl. 0334, 0354, 0364;
  only the 4 dxb skips; link out/kernel/kernel.macho). Not run on the phone; no image built.

## 43. Camera.app: ADT nodes + NegroniCamera.driver (2026-10-27, userland agent; details userland/camera/README.md)

- [V] Camera.app has SBAppTags/UIRequiredDeviceCapabilities `still-camera` (section 4). [I, from HakiOS
  docs/ru/notes.md:1712-1722 + xnuloader/loader.c:3226-3234, not our disassembly] MobileGestalt answers
  `still-camera`/`rear-facing-camera` from `/arm-io/isp` `camera-rear` = 1, which our ADT did not have.
  Fix: `ADT_CAM=1` in `scripts/ios16/adt-extra.py` adds `/arm-io/isp` (only `camera-rear` = 1, no compatible) and
  `/product/camera` (no `flash`); no `camera-front` (no IMX615 driver). Checked on a copy:
  `out/camera/negroni-adtcam.adt`, `out/camera/adt-camera-dump.txt` (phandles 0x18, 0x19). Image ADT unchanged.
- Ship-together rule: `scripts/camera/root-add-camera.sh` (CAMERA=1; root-finish.sh default on when the driver is
  built) writes the stamp `out/camera/root-has-camera` (sha256 of the installed driver, date, root path).
  `scripts/ios16/build.sh` sets `ADT_CAM=1` by default only when the stamp sha = the built driver's; otherwise it
  warns and leaves the nodes out (`ADT_CAM=1/0` overrides). So build the root before the image.
- [V] launchd: no job in the 20H392 root (/private/tmp/iosroot-ro, xpc/launchd.plist) has `_LimitLoadToDeviceTree`
  `isp` or `camera`; the only ones are SepUpdateTimer (hilo), biometrickitd.pearl (pearl-sep), wifid (wlan,
  marconi-wifi), iomfb_bics_daemon (hilo, twodbl). applecamerad/dietapplecamerad start on IOResources properties,
  not on DT nodes. The new nodes start no Apple camera daemon. Nothing stripped.
- [V] `userland/camera/`: HakiOS camera_device.c + camera_isp.c (MIT, 8851317) + the hook part of inject_media.c ->
  `NegroniCamera.driver` (HAL plug-in, factory returns NULL, constructor in mediaserverd only, no hooks if the self
  pin fails). 144 720 bytes, sha256 d5ab3cc95d784dca29d7d9a62a54457150817daf0daa968e87f257f592ac166d, arm64, minos
  16.0, no weak imports, ad hoc, no entitlements. ISP self test (colour bars, 4 Bayer orders) PASS on the host.
- [V] `scripts/camera/check-cache.sh` PASS: cache UUID 8F970452-C9E3-3E88-B114-FEB1864BC9E0, base 0x180000000; 8 hook
  addresses + first words (portrait prewarm `+[BWCoreImageFilterRenderer
  prewarmPortraitFilterVersion:semanticStyleFilters:]` = 0x1a2165b8c in 20H392); H10ISP vtable versions 1/3/1/2 as
  HakiOS 16.5; all dlsym targets exported (kFigCapturePortType_* and the metadata keys in CMCaptureCore,
  HEVCVideoEncoder_CreateInstance in VCPHEVC.videocodec).
- Refusal, exactly: the device create function checks only `access(/dev/negronicam)` and `negronicam_failed`
  and returns -12783 at once. EIO, a bad header, 5 failed reads or no memory are seen by the frame worker of an
  existing device: it sets `negronicam_failed` and stops (that session: black preview, the shutter waits [I]);
  the next stream start and device create are refused. [I] Camera.app's view of a refused create is not seen.
- Gotcha: `ipsw dyld symaddr CACHE SYM --all` scans the whole cache for minutes; use `--image NAME` (0.5 s).
- Next: image with `negronicam=7` (everything.args has `negronicam=6`, which does not publish /dev/negronicam:
  0318 publishes at level == 7 only) + a CAMERA=1 root first, then the image (ADT_CAM default). Not verified: HAL with a
  NULL factory, IFE latch event, IMX789 Bayer order, gain formula, black level 64, picture orientation.

## 43. USB gadget does not come back after unplug or an ADSP Type-C re-attach; patch 0366 (2026-10-27, kernel agent; details patches/xnu/README-usb.md "0366")

- [V] Unplug + replug (~02:30) and the first boot with a running ADSP (02:42:23, 3 s after `THE ADSP IS UP`): the Mac
  lost the device and never saw it again. The phone kept running.
- [V] The QSCRATCH VBUS override hides the detach: no disconnect event. DEVTEN 0x7 hid the L2 suspend too. A bus
  reset did not ENDTRANSFER the always-active RX ring (0361), a stuck TX batch or a notification. Nothing retried.
- [V] GUSB2PHYCFG 0x00102500 at boot: SUSPHY already 0, ENBLSLPM 1. sm8450.dtsi sets dis_u2_susphy + dis_enblslpm.
- [I] Exact replug failure unknown (no log from that period). Fix covers both candidates.
- [I] logs/usblog-20261026-233816.txt: the losses at 02:03:33 and 02:05:29 were reboots (log silent ~12 s before,
  new boot ~64 s later); 02:06:40 has no silence before it (unplug or link loss).
- 0366: ENDTRANSFER on reset/disconnect/SET_CONFIGURATION(0), ep0 back to setup phase, DEVTEN + wakeup/suspend/
  erratic/link-change (all logged with DSTS), GUSB2PHYCFG SUSPHY+ENBLSLPM off, DSTS watchdog every 100 ms: no SOF
  for 5 s, or a device event without SOF after 1 s -> soft disconnect + core soft reset + connect (Linux
  dwc3_gadget_soft_disconnect/_soft_connect). Also in the panic loop. Fallbacks: negroniusb_reconnect=0,
  negroniusb_resetend=0, negroniusb_events=0, negroniusb_phycfg=0.
- [I] Not done: the ADSP may also want a UCSI client (pmic_glink owner 32779) on PMIC_RTR_ADSP_APPS. Linux
  ucsi_glink answers it; we do not. If the re-attach repeats after the ADSP comes up, look there next.
- [V] Phone 02:55 (first 0366 build): boot lines OK (GUSB2PHYCFG -> 0x00102400, DEVTEN 0x25f, en10 up, 36 MB/s).
  ADSP up 02:55:44, Mac lost the device 02:55:46 and saw no USB device at all afterwards: nothing for a reconnect
  to talk to. [I] The ADSP (VOOC / Type-C data-line switch) takes the lines; another agent investigates.
- Opus review ACCEPT with fixes, applied: 1 ms after each ENDTRANSFER (also the 0360 panic TX timeout), ep0/1 end
  with CMDIOC and no FORCERM, 50 ms after the core soft reset, fallbacks restore the old paths (notification end and
  the resetdrop=0 reset branch gated), the event rule once per episode, 30 s period at once while configured in L2,
  default negroniusb_events=1 (DEVTEN 0x257, no link state change events).
- Build (with the review fixes): out/kernel/local-20261026-213752/kernel.development.negroni sha256
  512a2c450ab79f05a963c442eddafd30d2d941fe42a680d05bc4f75e157f5859 (258 applied incl. 0366; only the 4 dxb
  skips; link out/kernel/kernel.macho). Not run on the phone; no image built.
- Test: unplug 10 s, replug: expect `no SOF for 3 s`, then `bus reset`, `connected`, `configured (1)`,
  `SOF again after N ms`, or `soft reconnect #1 ...: device event without SOF` 1 s after the replug; en10 back
  within ~3 s of the replug. Link 4/5 instead of 3: `soft reconnect` every 5 s while unplugged.

## 44. Phone proofs 2026-10-27 02:40-02:51 (main session; boot_a = out/ios16-safe, tests RAM-booted)

- [V] RAM test t1 (kernel local-20261026-210736, all SMMU writers off by boot-arg): `NEGRONI ADSP: 8 THE ADSP IS UP
  after 35 ms`, GLINK step 9 ok (0240 SCM resume fix). 3 s later the Mac lost the USB gadget for good; the phone later
  reset to the Apple logo without USB; a clean `fastboot reboot` into out/ios16-safe brought USB back (02:48:22).
  [I] the ADSP firmware (Type-C/charger owner) re-attaches the port; the gadget does not recover (agent on 0366).
- [V] RAM test t2 (kernel local-20261026-211707, negroniadsp=0, negroniwlan_ios=2): Bluetooth stage A passes step 4
  (`s_ahb hw-gated`, BCM QUP2 vote errno 0), SE5 FW protocol 2 (UART), 115200 RTS/CTS, BT_EN sequence, HCI_RESET
  ok, QCA product 0x13 SoC 0x400c0210 ROM 0x0201, 3 Mbaud, rampatch + NVM from the WLAN-area pack, then bluetoothd
  drives the controller over com.apple.uart.bluetooth (LE commands 0x2060/0x202f/0x2031/0x2024/0x201c/0x200f/0x204a/
  0x2074 all Command Complete status 0 at 02:50:07). Battery line `external=1 charging=1` (0365). backboardd
  `GetBlock 0x40 ... current mode (colour 1, timing 1)` (0364). wifid/configd query en0 (0340/0341, fake radio mode).

## 43. Passcode: software keybag in the AppleKeyStore stand-in (2026-10-27, kernel agent; patch 0221-negroni-aks-passcode, details patches/xnu/README-aks-amfi.md "0221 passcode")

- Owner: "passcodes can't be turned on at all". [V] keybagd sets a passcode with libaks selector 15
  (`aks_change_secret`), then 3 save, 5 set_system, 105 epilogue, 4 unload, 87 invalidate; 0220 answered 15 with
  kIOReturnUnsupported and always reported "no passcode" (MC `isPasscodeSet` = `MKBGetDeviceLockState() != 3`).
  No log has a `sel 15` line, so where the owner's try stopped is not known [I].
- [V] Full selector map with scalar/struct shapes from the 20H392 cache + keybagd/profiled/MobileKeyBagLockState
  disassembly (`ipsw dyld disass --image AppleKeyStore|MobileKeyBag|ManagedConfiguration`, root image attached
  read-only); table in the README. Gotchas: passcodes are user pointers in scalars (copyin); keybagd loads
  systembag.kb only when selector 14 answers 0xe00002f0, and a load failure = `FATAL KEYBAG ERROR` + reboot;
  lock/unlock events are interest messages 0xe3ffd00d (lock_status) / 0xe3ffd00f (first_unlock) for
  MobileKeyBagLockState.plugin; wrong passcode = 0xe00002e2.
- 0221: PBKDF2-HMAC-SHA256 (20000 iterations, random salt, own HMAC on the kernel SHA256_*), 128-byte blob that
  keybagd keeps in systembag.kb, lock state 0x1/0x4/0x5 and sls 0/1 with a passcode (0x6/3 without), grace period,
  keybagd-only gate for bag-changing selectors. Fail-open everywhere: no file / foreign or damaged blob /
  `negroniaks_reset=1` = no passcode. `negroniaks=3` = 0220 behaviour. Lock-screen gate only, no data protection.
- Host test `scripts/kernel/test-aks-core.sh` (core header taken from the patch): all pass (RFC vectors, PBKDF2 vs
  CommonCrypto, blob round trip, 128 corruptions refused). Fable review: ACCEPT WITH FIXES, F1-F3 applied.
- Build: out/kernel/local-20261026-212112/kernel.development.negroni sha256
  32093879e909256fb806aa2310a97044b79207af3d3f275766639a7e5d80f964 (254 applied; only the 4 dxb skips; link
  out/kernel/kernel.macho). Not run on the phone; no image built. Owner test and recovery steps: README.
- Review 2 (Opus, 2026-10-27), fixes in the patch: [V] the root has slop's systembag.kb ("SWEET", root-macos.sh), so
  the old 0221 sent keybagd into its untested file-load path (14 = NotFound) on every boot, also with no passcode;
  any keybagd failure there = FATAL KEYBAG reboot loop. Now 14 always answers handle 0 (as 0220) and the kernel reads
  systembag.kb itself at keybagd's first 14 (`nks_find_blob`: binary plist raw bytes, keybagd writes format 200
  [V: keybagd 0x10000c664]; XML base64). [V] SpringBoard blocks permanently / asks for a wipe when sfa >= mua
  (`SBFUserAuthenticationModelSEP _refreshStateForMkbState:`): sfa now capped at 9. verify_password reads a prefix;
  non-keybagd callers of bag selectors get the 0220 answer. [V] LockoutState.plist is educational mode only.
- Review 3 (Opus, 2026-10-27): [V xnu source] `fifo_open` sleeps until a writer comes when FREAD is set without
  O_NONBLOCK; the kernel holds the AKS lock during the file read, so a FIFO at systembag.kb (root userland) hung
  keybagd and every AKS caller. Fix: `vnode_lookup` NOFOLLOW first, open only a regular file, `O_NONBLOCK` on the
  open, type checked again. Parser (`nks_find_blob`: no offset table is read, raw scan + bounded base64), DER
  reader, lock order (no vnode path calls AKS; no cprotect wraps registered) and the no-passcode boot answers
  (14, 7, 17, 31 the same bytes as 0220) checked: no other defect.
  Build: out/kernel/local-20261026-225642/kernel.development.negroni sha256 da5a7e794df427d2028e7b4a5e43d3df5bd05e4a08b4e22c45a6ab376f8fe9ac
  (only the 4 dxb skips; link out/kernel/kernel.macho). Host test pass. Not run on the phone.

## 45. apps-SMMU stage-1: SEA panic on the CBAR restore; writers default OFF; refusable accesses + bank probe (2026-10-27, SMMU kernel agent; patches 0249, 0297, 0317; details patches/xnu/README-camera.md "2026-10-27: panic ...")

- [V] Panic photo, boot with 0249 (kernel local-20261026-210400): `Kernel data abort`, ESR 0x96000010 (SEA), FAR
  0xfffffe3006c99128 = global page 1 + 0x128 = CBAR(74), pc in `undo()` at the CBAR restore after the tlb_sync loop.
  Which setup step failed first is not known.
- [V source] Linux sm8450 arm-smmu.c: stage-1 banks from IDR1.NUMS2CB up; CBAR 0x1f300; domain free writes SCTLR 0
  only, never CBAR; TLB sync per context, 500 ms; no power vote. HakiOS (SM7325): lowest free bank (7/8 on hardware),
  CBAR never restored. [I] Gunyah refuses an HLOS CBAR write of type S2_TRANS; our old helper (and 0325) wrote the
  old type-0 CBAR back.
- [V source] xnu `handle_kernel_abort` offers only VM faults to the CONFIG_XNUPOST expected-fault hook: an SEA can
  not be caught without a patch. 0297 adds `negroni_mmio_try_rd32/wr32` (SEA at that one instruction -> -1).
- Defaults now OFF: `negroniaudio_smmu` 0, `negronicam_smmu` 1 (opt-in 3), Wi-Fi `negroniwlan_smmu` 1 asked of 0325
  (one line, Wi-Fi agent). The helper: refusable accesses, banks bottom-up from NUMS2CB, claim = test (skip on
  refusal, no restore), teardown SCTLR 0 + TLB sync only, 500 ms sync with TBU/TCU ack lines.
- Probe: `negronismmu_probe=1` (dormant banks get the same-value CBAR write) / `=2` (all banks); one
  `NEGRONI SMMU PROBE: cb N ...` line per bank + summary lists. Next test: RAM boot with `negronismmu_probe=1` only.
- Build: out/kernel/local-20261026-212617/kernel.development.negroni sha256
  5dac8d75b51b4249489505626d14085ec3823b30caeabd6442cfab80e035963b (254 applied incl. 0249/0297/0317/0325; only
  the 4 dxb skips; link out/kernel/kernel.macho). Not run on the phone; no image built.

## 46. Boot log on userdata: the last 8 boots survive a lost USB link, a hang or a reset (2026-10-27, kernel agent; patch 0367, details patches/xnu/README-bootlog.md)

- [V] Trigger today: a RAM-booted test image started the ADSP, the Mac lost the USB gadget 3 s later, nothing more
  was seen; the phone reset and stayed at the Apple logo without USB. The USB live log was the only channel.
- [V code] Before 0367: slop 0047/0121 kept a 4 MiB console ring and wrote it (only with `ufsrw=1`, every 10 s) to ONE
  area at N-1025 ("SWEETLOG"), overwritten by the next boot within seconds. 0360's `negroni_log_panic` wrote the
  panic log there only when that thread ran, with `delay()` and printf in the panic path.
- 0367: new area N-28673 .. N-19458 (36 MiB, right below the WLAN area; NE2211 blocks 58643726 .. 58652941; HFS+
  root ends at 4194304). Superblock "NEGRBLOG" + 8 slots x (header "NEGRBOOT" + 4 MiB ring). One slot per boot
  (boot counter), flush every 1 s with new text (5 s heartbeat), SYNCHRONIZE CACHE each time. Always on
  (`negronilog=0` = off), no `ufsrw=1` needed: a separate write gate allows only the area, set after the kernel
  checked the HFS+ volume header (volume end <= area start). The old SWEETLOG area is no longer written.
- Marks: SpringBoard seen (flag + uptime), panic (polled, lockless write from `negroni_log_panic`, 1 s command
  timeout, first panic line in the header), halt/restart (platform expert), USB ctl reset/power off, resets from
  the panic hold loop (`/ then: ...`). No mark = reset/hang/power loss; the last flush uptime says when.
- Reset detector: the 0214 PON log dump now also gives `NEGRONI PON LOG: summary: pon=.. reset=.. type=..` (entries
  before the last PON trigger = how the previous boot ended); stored in each slot header. [I] PS_HOLD covers both
  our PSCI reset and a TZ watchdog bite; the boot log end mark separates them.
- Read back: `op10tool ctl bootlog` (one line), `op10tool bootlog [N]` / `make bootlog` (UDP 5141 `bootlog read A C`,
  pipelined, resends lost datagrams) -> `logs/bootlog-<boot>.txt` + one summary line per boot + last 5 lines;
  SSH: `scripts/debug/bootlog-ssh.sh` (`/dev/negronibootlog`, root 0400); dumps: `op10tool bootlog --file`.
- Layout files: `scripts/ios16/root-simg.sh` (AREAS=1: root must end below N-28673; embeds the superblock from
  `op10tool bootlog --mkarea`), `scripts/fw/write-areas.sh` (layout comment; accepts NEGRBLOG as the N check).
  No userdata reflash is needed: the area is in today's DONT_CARE space and the kernel formats it.
- Host test [V]: `tools/op10tool/tests/bootlog-test.sh` (fake area: panic / clean / wrapped ring / bad CRC; and the
  UDP path against a fake server with 10 % datagram loss: same text).
- First build: out/kernel/local-20261026-213526 (48ba234d...), superseded by the review build below.
- Opus review: ACCEPT with conditions, all applied: F1 wear budget (1 s only in the first 5 min, then 5 s; > 256 KiB
  in 10 s -> 10 s; idle heartbeat 30 s), F2 layout anchor before the gate opens (`NEGRWLAN` at N-19457 or our
  superblock), F3 gate closed on every setup error, F4 static asserts for 28673/9216/8201, F5 panic write only if
  the UFS lock is free or `ufsrw` is off, F6 write-areas.sh checks HFS+ end <= N-28673, F7 NUL-terminated header
  strings; new slot headers zeroed with a new superblock; pure checks in `bsd/dev/negroni_bootlog_core.h`, host test
  `scripts/kernel/test-bootlog-core.sh` [V] 65 checks, 0 failed. slop's tools/negroni-log-pull.sh (SWEETLOG) is
  obsolete for kernels with 0367.
- Owner policy: with 0367 the kernel writes userdata on every boot without `ufsrw=1` (the gated area only).
  Test images keep `negronilog=0` until the owner accepts this.
- Next (owner): boot image with the review build (no boot-arg change), then the test in README-bootlog.md: boot,
  `op10tool ctl bootlog`, `op10tool ctl panic`, `op10tool ctl reboot`, after the next boot `make bootlog`.
- Review fixes (Opus ACCEPT, F1-F4 + N2) and readable probe: 0297 `.alt_entry` on the instruction labels; helper
  report/fsr/ON lines through the refusable accessors; SCTLR only after the claim; probe-REFUSED/CHANGED banks skipped.
  [V] t4 RAM boot (03:01, negronismmu_probe=1): the EARLY_BOOT lines are not in `op10tool ctl log`. Now the text comes
  again 60 s after boot (`negronismmu_probe_again`) and from `sysctl kern.negroni_smmu_probe` (root).
- 0335 review fixes (A1 RX thread in dead mode, A2 no power-on loop, A3 partial frame reset, A4 Command Status
  answers). 0336: the QCA6490 init gaps for bluetoothd. 0x0c6d gets a local status 0 (the chip answers 0x11).
  0x0c5a/0x0c5b get local answers, and their bits are set in the 0x1002 mask: bluetoothd checks the mask locally,
  which gave "status=628", then "HCI initialization failed" and restart reason 108. Details: README-bluetooth.md "0336".
  Build: out/kernel/local-20261026-214005/kernel.development.negroni sha256
  78bce8a5e31047414dabfd35e7f17a6dd4db3f6e42814bf6cf2af7af3c344619 (258 applied; only the 4 dxb skips).

## 47. SMMU bank probe on the phone (2026-10-27 03:12, RAM test t5, kernel local-20261026-214005)

- [V] `NEGRONI SMMU PROBE: level 1: 113 SMRs, 75 contexts, NUMS2CB 0, page 0x1000; IDR2 0x5111 sGFSR 0 ...; 6 of
  113 SMRs valid`; `summary: 75 banks (stage-1 from 0): rewrite OK 0, REFUSED 69, ... 69 aborts caught`; banks 6..74
  refuse a same-value CBAR write (SEA caught by 0297, no panic); banks 0..5 are in use (not tried).
- [I] A same-value write keeps the stage-2 type (S2_TRANS) that Gunyah keeps for itself; Linux writes the stage-1
  value 0x1f300. Next test: Wi-Fi with negroniwlan_smmu=3 (claim through the try-accessor, a refusal skips the bank).
- [V] 2026-10-27 03:14, RAM test t6 (negroniwlan_smmu=3): the stage-1 claim with CBAR 0x1f300 is ACCEPTED by
  Gunyah on bank 6 (`SMMU context 6 claimed ... now CBAR 0x1f300 CBA2R 0x1`, SMR6 0x80011c00 -> S2CR6 6, Wi-Fi
  stream 0x1c01 through context 6, IOVA 0xa0000000+, no context or global fault). BHI SBL (512 KiB at IOVA
  0xa0010000) written; then MHI never READY (MHISTATUS 0, EE 0) in 10 s: next is the BHI status/errcode readout.

## 48. USB lost 2-3 s after ADSP up: the ADSP charger firmware owns the HS PHY during its port detection; VOOC HLOS side (2026-10-27, kernel agent; patches 0368, 0369; details patches/xnu/README-usb.md "0368", README-battery.md sections 14-15)

- [V] logs/usblog-20261026-233816.txt 02:42:20 and 02:55:44: the Mac loses the phone 2-3 s after `THE ADSP IS UP`, no
  device at all, also with 0366. [V] The ADSP image (`out/firmware/adsp/adsp.b14` strings) has `usb_hs_phy_reset`,
  `usb_hs_phy_set_nondrive_mode`, `usb_hs_phy_toggle_dp`, `usb_hs_phy_dp_high`, `usb_hs_phy_dp_default_state`,
  `usb_hs_phy_enable_clkref` on `gcc_eusb3_0_clkref_en` = our PHY's ref_clk (live.dts hsphy clocks `<0x23 0x1f>`,
  GCC id 31, GCC + 0x9c00c), next to its APSD/BC1.2 and VOOC code. [V] negroni_usb.c never set the PHY up; Android
  starts the gadget after the ADSP and runs the PHY init on each role change. [I] Cause: the ADSP's detection leaves the
  PHY reset / non-driving / without ref clock. No GLINK message to prevent it is known.
- 0368: PHY baseline at gadget start, change log (10 ms samples from ADSP start to up + 10 s), repair = soft reconnect
  with ref clock on + GCC_QUSB2PHY_PRIM_BCR reset (GCC + 0x22000) + Linux qcom_snps_hsphy_init sequence (baseline
  FSEL/REFCLK/overrides); every 0366 reconnect after an ADSP start also re-inits the PHY. Boot-args
  `negroniusb_phyfix=0|1|2`, `negroniusb_phyfix_ms`. Also: every PMIC_RTR_ADSP_APPS message logged for 10 s.
- 0369: VOOC/SuperVOOC HLOS side (enable policy, PMIC park on 0x52, status decode 0x48, 0x59 answer, 8.5 s recovery,
  MATCH_TEMP, telemetry). Default `negronichg_vooc=0` = USB_VOOCPHY_ENABLE 0 (plain charging); `=1` = allowed for a DCP
  at 12.0-43.0 C without thermal limit.
- Build [V]: out/kernel/local-20261026-214742/kernel.development.negroni sha256
  4eef13848fb7b4e334b4036fb7f019762c2165488706c7028fc115b6993958b9 (260 applied incl. 0368, 0369; only the 4 dxb
  skips; link out/kernel/kernel.macho). Not booted; no image.
- Next: RAM boot with `negroniadsp=1 ... negronichg_glink=1` (VOOC off): expect the `PHY change` lines at the ADSP
  start, then `soft reconnect ...: the PHY differs from the reference`, `PHY re-init #1`, the device back on the Mac.
  Then (separately) `negronichg_vooc=1` with the SuperVOOC adapter (README-battery.md section 15 test).

## 49. Widgets: 64 MiB jetsam limit + Metal for widgets; zero blocks flashed as DONT_CARE damage 112 root files (2026-10-27 03:05-03:25, Metal agent; details docs/metal-widgets-2026-10-27.md sections 5-7)

- [V] The 30 MiB widget limit: com.apple.jetsamproperties.D22.plist (+ .D221, uname -m iPhone10,3) Version4 > Extension >
  Override > com.apple.widgetkit-extension {ActiveHardMemoryLimit 30, InactiveHardMemoryLimit 30}, read once by
  runningboardd (RBJetsamPropertyManager). Now 64/64: scripts/ios16/jetsam_widgets.py, root-tweaks-extra.py step 6
  (WIDGET_JETSAM_MB, default 64), live scripts/metal/phone-widget-jetsam.sh (kill -9 runningboardd re-reads it; no
  launchctl on the phone; SpringBoard survives). memlimit.sh shows 64/64 for every widget extension.
- [V] Plugin memory_rule: the widgetkit clause is removed, only `limit < NEGRONIMETAL_MIN_LIMIT_MB` (40) is left (the
  value in section 35 that says 48 is wrong: the code default is 40). After respring 03:18:20: FitnessWidget opens the
  device (759 ms, first frame 275 ms later, 11.5 MiB footprint) and did not crash; it logs `render pipeline skipped:
  nil render pipeline` (VFX rings pipeline not built by m2v; a Metal item, not a crash).
- [V] ROOT CAUSE of SleepWidgetExtension/SafariLinkExtension sig 11 + cs_invalid_page: `op10tool img2simg` wrote APFS
  holes of ios16-root.img as DONT_CARE, also where the HFS+ volume uses the block (zero file data). The flash left old
  userdata bytes there: 20296 blocks / 79 MiB / 112 files, including dyld_shared_cache_arm64.07/.21/.42 (both copies).
  SleepWidgetExtension's zero __DATA page holds old bytes on the phone; its crash address is those bytes. Fixed in
  tools/op10tool/src/img2simg.rs (`hfs_allocated`: allocated hole blocks -> FILL 0). **Rebuild op10tool and the simg
  before the next root flash.** Live proof: SleepWidgetExtension replaced from the image (bad copy in
  /var/root/SleepWidgetExtension.bad) runs without crash.
- [V] Phone note: a push that is not followed by `sync` is lost on a reset some seconds later (HFS journal); phone-test.sh
  push now syncs.
- 0367 review build [V]: out/kernel/local-20261026-215004/kernel.development.negroni sha256
  8793f10ae9727a8fc7487c7e17791db21e8d58949156117a9999e7579e53730c (260 applied, 0367 then 0368 and 0369 on top;
  only the 4 dxb skips; link out/kernel/kernel.macho). Strings: anchor / `layout not proven` / `UFS busy at the
  panic` / budget lines. Only warning kinds of the old code (-Wshadow on a local `total`, as at the old flush). Not booted; no image.
- 0337 (2026-10-27, kernel agent): bluetoothd restarted with reason 3602 (ANTENNA_PREF_B "timedout waiting for
  controller"). Cause [V, disassembly]: `_BCM_ByteStreamEventParser` drops a vendor answer that has fewer than
  2 data bytes, so the command never completes. Now every local vendor answer carries 8 bytes (sub-opcode echo +
  zeros), and 0xfd3c/0xfce9/0xfce2/0xfd48/0xfd47 get status 0. 0x2007 status 0x0c becomes 0 (0 dBm). 0x0c6d now goes
  to the chip with Simultaneous_LE_Host = 0. Kernel out/kernel/local-20261026-215458 sha256 b5db26ba...
- Phone t8 (03:19-03:20, kernel local-20261026-214742, main session) [V]: PHY at the ADSP start / ADSP up = baseline, no
  PHY change, no repair; the drop came 2 s after `glink: start`. The PHY cause is NOT confirmed; the drop follows our
  charger GLINK traffic. [I] Candidates: 1.5 A input limit on a Mac host port (stock: SDP 500 mA; macOS cuts an
  overcurrent port = "no USB device at all"), or the usb 13 (VOOC PHY enable) write. 0370: ICL per adapter type as stock
  (SDP 500, CDP 1500, DCP chg_ma; `negronichg_icl_bytype=0` = old), bisect boot-args `negronichg_wr=<mask>` (1 ICL,
  2 SUSPEND_PMIC, 4 CHG_EN, 8 FV/FCC, 0x10 VOOC, 0x20 notify, 0x40 other; 0 = read only), `negronichg_wr_delay_s=N`,
  `+N ms` on every write line (README-battery.md section 16).
- Opus review fixes applied: 0368 F1-F4 (no PHY init without halt; host port, hold-off 5 s, EUD, not during VOOC; 5 inits per
  ADSP start; 200 window lines); 0369 B1, B2, F5-F8 (README-battery.md section 15 "Review fixes").
- Build [V]: out/kernel/local-20261026-220250/kernel.development.negroni sha256
  79bd77350764f77e952907c46ad07710812080bfe91788879cdb81dd01545269 (263 applied incl. 0368-0370; 4 dxb skips; link
  out/kernel/kernel.macho). Not booted.
- Re-review fixes (Opus: 0368 ACCEPT + 1 fix, 0369 N1/N2, 0370 B3/N3): host gate = DSTS.SOFFN moved between two watch
  samples; READY reads USB_VOOCPHY_STATUS before PMIC writes; un-park restores type limit / saved ICL / 500 mA and resets
  the write budget; unknown/ACA type: 500 mA floor when ICL < 100 mA; VOOC safety writes bypass `negronichg_wr` and the
  delay; deferred notify + VOOC-off when the delay ends. Build [V]: out/kernel/local-20261026-221333/kernel.development.negroni
  sha256 008220510465a5b090a8e7da35ab3162f0cc5d5082b75509b05b02571f42f2ec (263 applied, 4 dxb skips; kernel.macho). Not booted.

## 50. ADSP/USB bisection (2026-10-27 03:51, RAM test t11 on the reflashed root, kernel local-20261026-220250)

- [V] Root reflashed with the fixed img2simg (20304 allocated zero blocks as FILL) via scripts/flash/reflash-root.sh
  (the documented order: stock recovery images -> fastbootd -> userdata -> bootloader -> iOS chain from ios16-safe).
- [V] t11: boot log on (`boot 1 reached SpringBoard ... 56.957 s`), ADSP up 03:51:00, PHY registers unchanged,
  `glink: start ... ICL per adapter type on` at 03:51:00, Mac lost the device at 03:51:02 (same as 03:20 with 1500 mA):
  the drop comes ~2 s after our charger GLINK client starts, before any input-limit write. Next: negronichg_wr=0.

## 54. USB: reboot when the host stays lost, boot-arg negroniusb_lost_reboot=S (2026-10-27, kernel agent; patch 0371, details patches/xnu/README-usb.md "0371")

- [V] Why: with the ADSP on, the Mac lost the device for good ~2 s after the charger GLINK channel started (boots
  03:20:28, 03:51:02); the phone kept running and could not be reached. boot_a holds a known-good image.
- 0371: once configured in this boot, no SOF for S s in one stretch (soft reconnects do not end it) -> log
  `NEGRONI USB: host lost for S s: rebooting (negroniusb_lost_reboot)`, reason 0, the USB "reboot" command path
  (500 ms later: negroni_bootlog_end(4, "reset (USB host lost S s)") + negroni_reboot_reset). Default 0 = off. Never
  in panic mode. Use S above the 0366 periods (e.g. 60).
- Build: out/kernel/local-20261026-222425/kernel.development.negroni sha256
  5ba022127aa9f50bdefb5ef0dadac4beb92fafb280376b3c8400ed4ce36a13ba (264 applied incl. 0371; only the 4 dxb skips;
  link out/kernel/kernel.macho). Not run on the phone; no image built.

## 51. watchdogd SIGTRAP every ~10 s = kern.bootargs ENOMEM after 0363 (2026-10-27, kernel agent; patch 0378)

- [V log] With long boot-args (t1/t2/t4/t6, everything-0363: 798-876 bytes), each watchdogd start crashes at once:
  `CRASH watchdogd sig 5 code 0x600000001` (EXC_BREAKPOINT), pc = mh + 0xb620, bt mh+0x792c, libdispatch
  `_dispatch_client_callout` / `_dispatch_once_callout`, mh+0x78c4, mh+0xa730, mh+0x7490, dyld `start`. No
  `NEGRONI WDT: watchdogd sel 0` line in these boots: it dies before IOServiceOpen. With 444-byte boot-args (pre-0363
  kernel, usblog-20261026-131747) there is no crash: `sel 0 ... -> ok`, then one more exec 10 s later.
- [V disasm] watchdogd (20H392, from the root image, 152816 bytes, sha256 7951d706d73f906b5e0a139b09c05982385469b46e872d75da5da53c1fc4b1e1):
  the dispatch_once block at 0x1000078c8 calls `sysctlbyname("kern.bootargs", buf, &len = 0x260, NULL, 0)`. On
  error it calls 0x10000b5e8: log "could not retrieve device boot-args, failed with error: %s", then
  `_os_crash("could not retrieve device boot-args")` + `brk #1` at 0x10000b620 = the crash pc.
- [V code] xnu `sysctl_sysctl_bootargs` uses `sysctl_io_string(..., trunc 0)`: a buffer smaller than strlen+1 gives
  ENOMEM. 0363 set BOOT_LINE_LENGTH 1024, so a command line of 608 bytes or more no longer fits the 608-byte buffer
  that iOS 16 user space uses. Before 0363 the kernel cut the line at 607 bytes, so it always fitted.
- Not the IOWatchdog service: slop 0040/0045 (`NegroniWatchdog.cpp`) answers every selector and arms nothing.
- [V disasm] watchdogd then checks `wdt_test=no_user_checkin` with strnstr ("watchdogd detected testing boot-args to
  not run, exiting"); this boot-arg is at byte ~150, so the 607-byte prefix keeps it.
- Fix 0378 (`patches/xnu/0378-negroni-bootargs-truncate.patch`): kern.bootargs uses trunc 1: a too-small buffer gets
  the first oldlen-1 bytes + NUL (the same bytes the 608-byte kernels gave); a size query still gets the full length.
  The first 8 truncations log `NEGRONI: kern.bootargs truncated to N of M bytes for <proc>`. No hardware access.
  Other daemons with 608-byte buffers get the same fix [I].
- How the binary was found (no DMGs on the Mac): scan the raw chunks of `~/op10-apple/ios16-root.simg` for
  "IOServiceOpen failed with error", take the Mach-O header (0xfeedfacf) before it at a 4 KiB boundary, length from
  LC_SEGMENT_64/LC_CODE_SIGNATURE (the file is contiguous in the HFS+ image).
- Phone test: RAM-boot an image with this kernel and long boot-args (>= 608 bytes, e.g. the everything variant). Expect
  `NEGRONI: kern.bootargs truncated to 607 of N bytes for watchdogd`, no `CRASH watchdogd`, and the
  `NEGRONI WDT: watchdogd sel 0` line (or a clean exit by no_user_checkin) as in the short-args boots.
- Build [V]: out/kernel/local-20261026-224120/kernel.development.negroni sha256
  81f4378235d08c0332fcefe89220a17d9bf5ddd52f05a9b85c8392e6dc150698 (265 applied incl. 0378; only the 4 dxb skips; link
  out/kernel/kernel.macho; the tree also had the uncommitted 0221-aks-passcode and 0335-0337 BT patches). Not booted; no image.

## 52. Camera step 14: TCR2 readback 0x38071 = TBI0/TBI1; helper readback = owned fields (2026-10-27, SMMU kernel agent; patch 0379, details patches/xnu/README-camera.md "0379")

- [V log] negronicam=7 negronicam_smmu=3 (kernel local-20261026-222425): claim of context 7 accepted, SMR112 -> 7, then
  `SMMU context 7 TCR2 reads 0x38071 after writing 0x38011` -> errno 1 (EPERM), stream entries put back.
- [V log] The same 0x38071 readback on Wi-Fi bank 6 (t6, accepted by the 0325 mask rule, DMA worked) and on Adreno
  banks 13/19 (2026-10-25/26 usblogs). Wi-Fi bank 6 SCTLR reads 0x107 after 0x1107 (ASIDPNE not kept).
- [V spec] SMMUv2 TCR2 = TCR_EL1[63:32]: PASIZE 2:0, AS 4, TBI0 5, TBI1 6, SEP 17:15. Bits 5/6 = top byte ignore.
- [I] The MMU-500 or Gunyah forces TBI0/TBI1 to 1. No effect: our IOVAs have a zero top byte.
- Fix 0379 (negroni_smmu_s1.c, used by camera 0317 and audio 0249): compare only owned fields (TCR2 0x3801f, TCR
  0xc0ffbf, TTBR0 all, MAIR0 0xff, SCTLR M, S2CR 0x300ff, SMR all, CBA2R bit 0, CBAR 0x300ff); print other
  differences as `bits X differ outside the fields we own Y; accepted`. Claim code unchanged (same as 0325, accepted).
  Wi-Fi file not edited. compile-one OK; full build: logs/kbuild-camtcr2.log.
- Next test expects: `SMMU context 7 TCR2 reads 0x38071 after writing 0x38011: bits 0x60 differ outside the fields
  we own 0x3801f; accepted`, [I] `SCTLR reads 0x27 after writing 0x1027: bits 0x1000 ...; accepted`, then
  `SMMU SMR112 = 0x84600800, S2CR112 = 0x7` and `SMMU context 7 ON`.

## 53. Wi-Fi SBL never reaches MHI READY: ath11k power-up reset + PCIe/WLAON boot dump (2026-10-27, Wi-Fi kernel agent; patches 0342, 0343, details patches/xnu/README-wifi.md "0342-0343")

- [V] t6 and the 0339 boot: BHI SBL DONE at IOVA 0xa0010000, no SMMU fault, then EE 0 and MHISTATUS 0 for 30 s;
  `no SBL log (start 0 size 0x30 ...)` = PCIE_BHI_ERRDBG2 is 0. The full 0339 dump of that boot is not in the repo.
- [V source] Image (first 512 KiB of amss20.bin, fbc), file name (major 2 -> amss20.bin), BHI register order, the
  32-bit IOVA and the SBL-log read all match cnss2/MHI. The one Linux step we skip: ath11k_pci_sw_reset(ab, true)
  (LTSSM, PCIE_INT_ALL_CLEAR, QFPROM, BHIe vectors, WLAON_WARM_SW_ENTRY = 0, reset cause, SOC_GLOBAL_RESET, MHICTRL
  RESET). cnss2 skips it but power-cycles all rails; we never cycle the aon rail.
- [I] Best guess: a latched PCIe hot-reset/link-down interrupt (ath11k: "SBL will open Interrupt ... and crash
  immediately") or a stale WLAON warm-boot entry (ath11k: "warm path ... dead loop").
- 0342 `negroniwlan_swreset=0|1|2` (default 0): 1 = the clears, 2 = + SoC global reset + MHICTRL RESET. 0343
  `negroniwlan_bootdbg` (default 1, read only): PCIe/WLAON/host-PCIe lines + a verdict in every BOOT dump.
- Test order: (1) 0343 only, (2) `negroniwlan_swreset=1`, (3) `=2`; all with `negroniwifi=10 negroniwlan=10
  negroniwlan_smmu=3`. Build log: logs/wlansbl-kbuild.log.

## 55. USB lost ~3 s after ADSP up: the ADSP votes the USB PHY rails, APPS has no vote; charger PD log (2026-10-27, kernel agent; patches 0372, 0373, details patches/xnu/README-usb.md "0372", "0373")

- [V] t12 (`negronichg_wr=0`) and t13 (`negronichg_glink=0`, 03:58:26 up, 03:58:29 gone) drop like t11: the ADSP
  causes the drop alone, not our charger client. t13: no line after the drop reached the Mac; the 0371 reboot brought
  the phone back (new boot at 04:00:21). So the 0366 soft reconnects and the 0368 PHY re-inits did not help.
- [V] t11: the ADSP acked our PMIC_RTR open at 03:51:00, its own OPEN (= charger PD start) had not come before the drop.
- [V] adsp.b14 strings: PMIC rail resources `/pm/ldob2|ldob5|ldob6|ldoc1` (`/en`, `/mode`, `/mV`). live.dts: HS PHY
  vdd = ldob5 (0.88 V), vdda18 = ldoc1 (1.8 V), vdda33 = ldob2 (3.072 V); SS PHY core = ldob6 (1.2 V). The DT rails have
  `qcom,set = 3`, init-voltage, init-mode HPM: Linux votes them from APPS at probe. XNU sends no vote for them.
- [V] adsp.b14 also: `charger_detection_inital_detection: adsp rerun status`, `rerun_apsd`, `TypecModeAsSink`,
  `oplus_set_otg_switch_status::set typec_mode = drp|sink_only`, `Sent Hard Reset Signal`, `Data Role Changed`.
- [I] Cause candidate 1 (best fit): the charger PD releases its rail votes after its detection; with no APPS vote RPMh
  turns the PHY's analog rails off/LPM. Registers still read (0368 saw nothing), soft reconnect cannot help, only a
  reboot restores them. Candidates 2/3: PD Hard Reset / Type-C role change, or the APSD rerun with our pull-up on.
- 0372: `negroniusb_rails` 0 off, 1 (default) log the 4 LDOs' PMIC registers (SPMI observer reads, new allowlist
  entries SID 1 0x41/0x44/0x45, SID 2 0x40, offsets 0x08/0x40/0x41/0x45/0x46) at ADSP start/up and every 50 ms to up + 30 s,
  2 = also APPS RPMh votes (ldob5 880, ldoc1 1800, ldob2 3072, ldob6 1200 mV, HPM) before PAS auth-and-reset.
- 0373: `negronichg_ulog=1` (default 0): GLINK channel PMIC_LOGS_ADSP_APPS (4th channel), Linux pmic_pdcharger_ulog
  protocol (owner 32778, opcode 0x18, 8192 bytes), every line as `NEGRONI ULOG: ...` (boot log keeps them).
- Build [V]: out/kernel/local-20261026-225104/kernel.development.negroni sha256
  201a9ae54fc9ce02c9062e8e16de90adacffbd23272a12f6eee7f5c3621eaf07 (271 applied incl. 0372, 0373; only the 4 dxb skips;
  link out/kernel/kernel.macho at build time). Only the old warning kinds. Not booted; no image.
- Next: RAM boot t13 args + `negroniusb_rails=1 negronichg_ulog=1` (evidence, then read the 0367 boot log), then
  `negroniusb_rails=2` (the fix). Expected lines: README-usb.md "0372" Boot lines.

## 53. Bluetooth: 0337 review, 0338 legacy LE -> extended LE, why the switch does not go off (2026-10-27, BT kernel agent; patch 0338, details patches/xnu/README-bluetooth.md "0337 review" and "0338")

- [V] 0337 works: in the 04:06 boot (logs/usblog-20261026-233816.txt, kernel local-20261026-222425) bluetoothd passed every Apple VSC. No `timedout waiting for controller`.
- [V disassembly] `_BCM_ByteStreamEventParser` (0x100126134) calls the callback when at least 2 bytes follow the status, for any status. `_BCM_SubOpcodeChecker` checks only 0xfce9 (byte 0 = sub-opcode; no data = match).
- [V] Name fixes: 0xfce2 is a multiplex opcode (sub-opcodes 0x0b, 0x1c, 0x15, 0x26, 0x1e, 0x36 seen). 0xfd48 carries `01` + a 6-byte address (the next 0x2005 address). [I] 0xfce2 sub 0x1c = SET_MIN_AFH_LE_CHANNELS.
- [V] The new stop: `0x200b` LE_Set_Scan_Parameters -> status 0x0c Command Disallowed -> `exit bluetoothd status 1`, every ~10 s. 0x2007 also gets 0x0c at init. The host sent no extended LE command before. [I strong] The QCA6490 firmware BTFW.HSP.2.1.0-00394 accepts only the extended LE command set.
- [I] Settings cannot turn Bluetooth off because bluetoothd dies ~1 s after each start (crash loop). [V disassembly] The off path: `Beginning asynchronous power shutdown` -> core stack halt -> `applebt_transport_terminate` / `applebt_hci_close` (the control socket closes; 0335 drives BT_EN low 3 s later) -> `Powering off chipset` (BlueTool `deepsleep`). No IOKit power property. No new power code was necessary.
- 0338: the shim translates 0x200b/0x200c/0x200d/0x2006/0x2008/0x2009/0x200a to 0x2041/0x2042/0x2043/0x2036/0x2037/0x2038/0x2039 (advertising set 0, 0x2035 for a random own address). Extended reports go back as legacy reports. `negronibt_lext=0` = the old pass-through. Opus review: ACCEPT with fixes, F1-F6/F8/F10 fixed (F1 was a report length error that broke the H4 stream).
- Host test: `scripts/kernel/test-bt-shim.sh TREE` (tools/bt-shim-test, ASan/UBSan). [V] all ok.
- Build [V]: out/kernel/local-20261026-225500/kernel.development.negroni sha256
  9c76386625f09c190511e599b4b9ecdaef318f9bede09bdb45c85a805052cd12 (0330-0338 applied, only the 4 dxb skips; link
  out/kernel/kernel.macho). Not run on the phone; no image.
- Next test: boot-args `negronibt=4 negronipanic=30 negronipanicreason=2`. Expect `lext: 0x2041 answer (status 0) delivered as legacy 0x200b`, no `exit bluetoothd`, `Stack: STACK_BUSY -> STACK_READY`, then the switch off: `h4 control unit 1 disconnected`, `power off: BT_EN low`.

## 56. Wi-Fi: MSI into a RAM mailbox, boot-arg negroniwlan_msi (2026-10-27, Wi-Fi kernel agent; patch 0344, details patches/xnu/README-wifi.md "0344")

- [V phone] 0342 level 1 and 2 did not help: BHI SBL DONE (0xbe92258b), then EE 0, MHISTATUS 0, READY time-out 30 s,
  no SMMU fault. Level 2 resets (0xff04 SYS_ERR, then MHICTRL RESET clears it). TCSR_PBL_LOGGING 0xef150600 ->
  0xef0e0200 once, then nothing. No SBL log pointer.
- [V phone] Endpoint MSI capability 0x50 = 0x10a7005: MSI off, 32 vectors, per-vector mask, 32-bit address only.
- [V source] ath11k and cnss2 enable MSI before the MHI power-up. We never did (no ITS).
- 0344 `negroniwlan_msi` (default 0): bit 0 = MSI address = pool IOVA + 0x8000 (free page, static assert), data 0xa500,
  32 vectors unmasked, enable; polls print `MSI #n data .. (vector ..) at <when> after N ms`. Needs
  `negroniwlan_smmu=3` (pool PA above 4 GiB). Bit 1 = PCIE_SOC_WAKE = 1 before BHI. Every failure path masks and
  disables MSI first (`wlan_quiesce`).
- [I] Guess under test: the SBL needs MSI enabled. A `vector 0` line at `BHI SBL` proves the MSI path works.
- Test: `negroniwifi=10 negroniwlan=10 negroniwlan_smmu=3 negroniwlan_msi=1`, then `=3`.
- Build [V]: out/kernel/local-20261026-230626/kernel.development.negroni sha256
  10e876ff3dd19ba6ca58c11379865fb4f225f2b7ba901f068ff799a731376720 (0344 applied, only the 4 dxb skips, no new
  warning class in the Wi-Fi files; link out/kernel/kernel.macho). Log: logs/wlanmsi-build.log. Not run on the phone.

## 57. Wi-Fi boots with MSI on: MHI READY, firmware up, en0 for wifid (2026-10-27 04:42, RAM test t21, kernel local-20261026-231147)
- Boot-args: `negroniwifi=10 negroniwlan=10 negroniwlan_smmu=3 negroniwlan_msi=1` (patch 0344), ADSP off.
- [V] `MSI #1 data 0xa500 (vector 0) at BHI SBL after 66 ms`, then `MHISTATUS READY (0x101) after 2 ms, execution environment 1`.
  Without MSI (t16-t18, 0342 levels 0/1/2) EE stayed 0 for 30 s. Cause: the WCN6855 SBL needs endpoint MSI enabled
  (Linux/cnss2 enable it before MHI power-up). No GIC ITS needed: the MSI lands in a RAM mailbox through SMMU context 6.
- [V] All steps then pass: BHIe full image, EE AMSS, QRTR HELLO node 7, WLFW IND_REGISTER/HOST_CAP/RESPOND_MEM/CAP/BDF/
  M3_INFO, FW_INIT_DONE, WLAN_CFG, HTC READY (CE2, 2 credits, 5 endpoints), WMI SERVICE_READY (fw build 0x200104cd,
  2 RF chains, 242 scan channels).
- [V] iOS: en0 exists; wifid and configd query it (CARD_CAPABILITIES, POWER, HW_SUPPORTED_CHANNELS, CHANNELS_INFO
  answered; RSSI_BOUNDS not built; SSID ENXIO before a join).
- Default: `negroniwlan_smmu=3 negroniwlan_msi=1` are now in scripts/ios16/variants/everything.args.
- Next: scan and join a network from Settings; RSSI_BOUNDS; 0342 swreset stays off (not needed).

## 58. USB lost after ADSP up = Type-C role flip: the charger PD's TCPM makes the phone the source; 0374 sink only (2026-10-27, kernel agent; patch 0374, details patches/xnu/README-usb.md "0374")

- [V] t19 (logs/bootlog-9.txt, 0373 ULOG): the PD starts its TCPC/TCPM ~2.1 s after ADSP up; 10 ms later the sink
  attach is gone (`GetSnkSrcMode[0x0]`, `bPlugIn[0]`, VBUS 5 mV); port role DRP; 0.6 s later the CC interrupt gives
  `ROLE_CONTROL = 0x07` (Rp on CC2), `ConnectPartnerType=2` (UFP), `PowerDirection=1`, `OTG_ENABLE_REQ`, `POWER_STATUS
  1C` (phone sources VBUS), PD `DataRole=1 PowerRole=1`, Source_Capabilities without GoodCRC. The Mac became the sink/UFP,
  so it is no USB host. The PHY dpdm writes and `clkref_en 1->80000000` at +2110/+2161 ms are the PD's "no cable" path.
- [V] Not the cause: our charger client (t13), charger writes (t12), PHY rails (t19 rails=2 held, 0 changes).
- [V] SID 3 0x13xx has no APID (`charger USBIN 0x1300: no APID`): the PM8350B charger is not at the SMB5 0x10-0x16
  map; the stock comment names the Type-C mode register 0x2b44 [I: PM8350B Type-C block at 0x2b00].
- [V stock code] USB_TYPEC_MODE (usb id 19) write = PM_TYPEC_PORT_ROLE (DRP 0, SNK 1, SRC 2, DISABLE 3); read = 0 sink,
  other source; USB_OTG_SWITCH 15; OTG scheme CID (`qcom,otg_scheme = <0>`).
- 0374: boot-arg `negronichg_typec` (default 0): bit 1 = USB_TYPEC_MODE = SNK at the first answer after the PD's OPEN
  and again when the role reads 1 or BC_OTG_ENABLE 0x50 comes (max 6, 3 s apart); bit 2 = USB_OTG_SWITCH = 0; 4 = watch
  only. With `negronichg_glink=0` it runs as a typec-only client (no charger writes). Reads every 500 ms for 60 s,
  then 5 s. [I] Not proven on the phone.
- Build [V]: out/kernel/local-20261026-232521/kernel.development.negroni sha256
  d2d943ae8fa17bfe14ca22af9dc0b1801cd8ab6a4b306ac69eb4b55b37c243f9 (273 applied incl. 0374; 4 dxb skips; link
  out/kernel/kernel.macho). Only the old warning kind. Not booted; no image.
- Next: RAM boot with t19 args + `negronichg_typec=3` (`negronichg_glink=0`, `negronichg_ulog=1`): expect the typec
  write lines, PD `set typec_mode[1]`, no `OTG_ENABLE_REQ`, `bPlugIn[1]`, the Mac sees the device again.

## 59. USB enumerates but the data path is dead (t22); 0375 data-path watchdog (2026-10-27, kernel agent; patch 0375, details patches/xnu/README-usb.md "0375")

- [V] t22 (`negroniadsp=1 negronichg_typec=3`): 05:05:19 link drop at the ADSP charger start; 05:05:25 the Mac
  enumerated the phone again (en10 up), but ping, ARP, ctl (`settime: no reply`) and the live log were dead.
  05:10:02 `usb-host-kick reenum`: en10 up again, still dead. 05:12:41 `usb-host-kick suspend 80`: no reboot and no
  new enumeration on the Mac in 80 s. Button reset needed.
- [V code] 0371's latch `ever_configured` is never cleared (not by a re-enumeration). In L2 SOFFN does not move.
  With SOFs stopped and ud_thread alive, 0366 reconnects after 30 s (configured + L2) and the Mac would enumerate
  again; that is not in the log. So [I] either the Mac kept sending SOFs (port not really suspended), or ud_thread
  did not run ud_link_watch. 0371 and 0366 run only in ud_thread. A held suspend cannot reach 0371 anyway while
  0366 (30 s) is faster than S (60 s).
- [V code] usblog.sh sent `settime` only at interface up, nothing periodic.
- 0375: boot-arg `negroniusb_idle_reboot=S` (default 0). Own kernel thread (250 ms). Armed after the first
  configuration and the first host OUT frame. Fires on no OUT frame for S s, or an IN transfer active S s without
  completion: one line, reason 0, end mark "reset (USB data idle S s)", PSCI reset, done by the watchdog thread
  itself (thread_call fallback 5 s). Once per boot, not in panic, a pending command wins (takeover only when it is
  not run 5 s after its time). Also logs `ud_thread has not run for N ms: in step ...` (stall detector, own SOFFN
  sample) to tell the two t22 cases apart next time. 0371 hardening: the stretch ends only on two SOFFN changes in a
  row.
- Host: usblog.sh sends a UDP broadcast `keepalive` to 192.168.7.255:5142 every 10 s (`USBLOG_KEEPALIVE`; no ARP
  needed). build.sh adds `negroniusb_idle_reboot=90` to test images (`IDLE_REBOOT`). Restart the usblog tmux job
  (old script has no keepalive) before a test with the arg, or the phone reboots ~90 s after boot.
- Build [V]: out/kernel/local-20261026-235425/kernel.development.negroni sha256
  26d079d28ab223ad7d2444ac9e5ec36b3117d089ed51cc231828be592ab31384 (274 applied; 4 dxb skips). Not booted.

## 60. Camera.app black: the test images had no camera ADT nodes; payload adds them now (2026-10-27 05:55, camera userland agent 2; details docs/camera-ios-2026-10-27.md section 7)

- [V] `out/ios16-t20..t23/negroni.adt` (sha256 24948e87..., the ios16-everything ADT of 10-26 23:19) have no
  `camera-rear`: test images run `build.sh payload` + `boot` on a copied ADT, and only the `adt` step adds the camera
  nodes. The CAMERA=1 root (driver d5ab3cc9...) was on userdata from 03:50 (`logs/reflash.log`).
- [V] Stock `sharedCaptureDeviceVendor` 20H392 does not cache nil (tries again under its lock), so a late hook works.
- [V] No `|mediaserverd|` line in any USB/boot log: the plug-in logs to os_log only; use `phone-camera.sh log`.
- Fix: `build.sh payload` adds the nodes to a copied ADT without them (`adt_cam()`; any NegroniCamera stamp is
  enough; `ADT_CAM=0` overrides). Plug-in: hot off switch `/var/db/negronicam/off`; build sha256 ea16947e...
  `phone-camera.sh`: restart / off / on / log / revert prev; push keeps `.prev` and writes the stamp.
- [I] Main cause = no `rear-facing-camera` in MobileGestalt. Not verified on the phone.

## 61. SLPI (sensor DSP) start, phase 1: patch 0376 negronislpi (2026-10-27, sensors kernel agent; details patches/xnu/README-sensors.md)

- [V] SLPI values: PAS id 12 (Linux `sdm845_slpi_resource_init`, used for sm8450), crash reason 424, load_state
  `slpi`, proxy lcx/lmx, no minidump id; carveout 0x87f00000 + 0x1a00000; SMEM hosts 0/3; SMP2P in 481 / out 430
  (entries master-kernel, sleepstate bit 12); IPCC client 4 (signal 2 SMP2P, 0 GLINK); GLINK edge `dsps` items
  478-480; channels IPCRTR + fastrpcglink-apps-dsp; QMI 400 = sns_client.
- [V] Firmware: slpi.mdt + 22 segment files (24 headers, b22 BSS, b23 hash; span 0x88000000..0x89a00000 =
  0x1a00000, relocatable). The ADSP area table is 64 entries (44 used), so the SLPI files go in as one entry
  `slpi.pak` (own table `NEGRSLPI`, 26 files, 9662464 bytes). `scripts/sensors/extract-slpi-fw.sh` makes it;
  `mkadsparea.py` adds it (45 files, 29392896 of 33554432 bytes); `checkarea.py` checks it. The area on the
  phone is NOT rewritten yet (owner: `scripts/fw/build-areas.sh` + `write-areas.sh`).
- 0376: `negronislpi=1` PAS start ("THE SLPI IS UP"), `=2` + GLINK listen (logs each channel the SLPI opens,
  answers none), `=3` + IPCRTR/QRTR (logs NEW_SERVER, expects service 400). Own file negroni_slpi.c (copy of the
  0240/0242/0248 code, the proven ADSP file is not refactored). Step 0 waits for the ADSP thread (QMP mailbox,
  TCSR mutex 3, lcx/lmx vote are shared with no lock). No USB/charger access. Crash watch after start.
- Opus review ACCEPT WITH FIXES; F1-F8 applied (partition-only SMEM items, SPMI QDSS QMP guard also for
  negronislpi, ADSP `rails_on` after the failure unvote, GLINK oversize stop, QRTR handler before open, atomics,
  SMEM header bounds, intent slots).
- [V] Build out/kernel/local-20261027-004027/kernel.development.negroni sha256
  07f6194ef8cff8bf08f0bb1c8fb11a9dbf5add9efaea6ffffe19996a89e6996a (275 applied, 4 dxb skips). Not booted.
- Test order: `negronislpi=1 negroniadsp=0`, then `=2`, `=3`, then with `negroniadsp=1`.
- Phase 2 (README-sensors.md): FastRPC `apps_std` file server in the kernel (SLPI asks for
  `/vendor/etc/sensors/sns_reg_config`, the persist registry dir, `/odm/etc/sensor/config`, `/sys/devices/soc0/*`
  [V strings / I]); apps SMMU SIDs 0x541-0x543; maybe a servreg locator for `msm/slpi/sensor_pd`; sns_client QMI
  0x20/0x21/0x22 with protobuf [I].

## 62. Wi-Fi iOS side: wifid's scan + join requests mapped from the 20H392 binaries; patch 0345 (2026-10-27, Wi-Fi iOS agent; details patches/xnu/README-wifi.md "0345")
- [V] Type and event names come from IO80211.framework 20H392 itself: `kIoctlNameTable` (418 entries) and `eventArray`
  (`ipsw dyld extract out/dsc/cache/dyld_shared_cache_arm64 IO80211`; wifid from the root with
  `scripts/audio/hfs-extract.py ~/op10-apple/ios16-root.simg OUT /usr/sbin/wifid`; tables dumped with `ipsw dyld dump`).
  The unknown types of t21: 96 VIRTUAL_IF_ROLE, 97 VIRTUAL_IF_PARENT, 115 POWER_DEBUG_INFO, 365 DISPLAY_STATE,
  383 SET_PROPERTY, 419 LTE_RESTRICTED_CHANNELS.
- [V] RSSI_BOUNDS (106) = 16 bytes {version 1, RSSI_MIN, RSSI_MAX, RSSI_THRESHOLD} (int32); wifid retries it 6 times only
  on -3905/61/16, a refusal is skipped.
- [V] Join result: sync `__waitForJoinResult` polls ASSOCIATE_RESULT (21) every 20 ms for 8 s (0 = running); async reads
  21 on ASSOC_DONE (9), 0xffff = try again. 1 = success. wifid monitors 63 event codes, not RSN_HANDSHAKE_DONE (20).
- [V] t21 (real chip): no SCAN_REQ came in 10 min; the fake boot 16 (02:54:35) got `SCAN_REQ type 1, 13 channels`,
  SCAN_DONE, 3 SCAN_RESULT + EIO, so the scan path works when wifid asks. [I] wifid scans for a client (Settings >
  Wi-Fi open) or for known networks; in t21 nobody asked.
- [V] t21 log budget: wifid's CURRENT_NETWORK polls (192 in 5 min) used all 400 request lines. 0345: 6 lines per kind,
  scans/joins/leaves/power sets always.
- 0345 (build-only): answers 5, 6, 8, 14, 17, 18, 106; accepts 86 (scan), 5, 365, 382; fix: DISASSOCIATE no longer
  looks like a driver LINK_DOWN to the next join (stale EAUTH could end it at once). Next: phone test with Settings >
  Wi-Fi open, then a WPA2 join (README "0345" Test).

## 63. Cable power-on boots iOS: kernel charge-only mode, patch 0377 negronicharge (2026-10-27, charge kernel agent; details patches/xnu/README-charge.md)

- [V] The shim does not pass ABL's `/chosen/bootargs` (e.g. `androidboot.mode=charger`) to XNU: `NegroniBootMemoryDxe.c`
  reads only `/memory`, `/reserved-memory` and the initrd from ABL's DT; `NegroniXnuBoot.c` uses the `payload.bin`
  command line. The kernel decides from the PMIC PON log (SDAM 0x7400) instead.
- [V] Boot logs 10/13: `NEGRONI PON LOG: FIFO read failed at +0x4b` / `+0x9c` (offset changes). [I] Cause: the
  NegroniBattery census uses the same EE 0 observer channel (APID 60) at that time. 0377: 4 tries per byte, header +
  FIFO read until two passes agree (max 4); summary gets `after=` (a reset after the last PON trigger).
- 0377 `negronicharge` (default 0 = dry run, log only; 1 = act; `negronicharge_force=1` = enter on every boot, test
  only, never on boot_a). Hook: start of `load_init_program()` (init thread, before launchd). Enter when: last PON
  trigger USB_CHARGER (0x31c2/0x8732) or `androidboot.mode=charger`, no reset after it, no warm/hard reset type before
  it, power key up, VBUS present (NegroniBattery snapshot; "absent" only from a VADC USBIN reading).
- Mode: no launchd, console drawing muted, battery screen in the boot framebuffer, screen off after 10 s, short press
  = on, hold 2 s = PS_HOLD HARD_RESET + reason 0 + reset (next boot: trigger HARD_RESET = iOS), no VBUS 3 s = PMIC power
  off (0214). USB ctl stays up. No charger writes (XBL defaults without the ADSP PD).
- Host test: `scripts/kernel/test-charge-core.sh` (decision + state machine from the patch's header). Opus review
  ACCEPT WITH FIXES: F1/F2/F4/F5 fixed; F3 (blocks the bootstrap thread) checked and not true.
- Build: out/kernel/local-20261027-090703/kernel.development.negroni sha256 dceee47df05df4671ad5619d053e19f707bc6ba12d6a87d64b494dd8c2201a28 (277 applied, only the 4 usual dxb skips; 0377 applied; only the usual declaration-after-statement warnings). Not booted.
- [U] The real PON trigger code of a cable power-on on this phone. Test order: dry run on a normal boot, RAM boot with
  `BOOTARGS_ADD="negronicharge_force=1"` (screen, 10 s off, short press, `op10tool ctl reboot`, hold 2 s, unplug 3 s),
  then `negronicharge=1` on boot_a (owner's go) and a real cable power-on.

## 64. t22 dead data path: bootlog-12 does not hold the drop; 0381 negroniusb_datafix (2026-10-27, USB kernel agent; details patches/xnu/README-usb.md "0381")

- [V] logs/bootlog-12.txt = t22 (boot-args line 6). The 4 MiB ring wrapped (line 9: 17831467 of 22025771 bytes lost):
  the file covers uptime 21208-25560 s only. The ADSP start and the drop (~57-59 s) are not in it. In the tail: no
  `NEGRONI USB`, `CTL`, `ULOG`, `typec` or `NET` line. The Mac gave VBUS all the time (76 charge lines, `external=1`;
  one `usbin 0mV` sample at line 22509 has `iin 1417mA`: [I] an ADC glitch). The end is an iOS power-menu restart
  (lines 26062-26155), not a button reset.
- [V] Live log (usblog-20261026-233816.txt 206573-207096): ADSP up 05:05:17, typec-only client start and our
  PMIC_RTR open acked at 05:05:17, NO `PMIC_RTR_ADSP_APPS is open` / `typec:` line before the drop at 05:05:19.
  bootlog-9 (t19): PD PHY writes + `clkref_en 1->80000000` (2953/2962) before the ADSP's OPEN (2967); ULOG
  `pmic_glink_open` (3431), sink attach lost 10 ms later (3443-3445). [I strong] The first drop comes with the TCPM start
  and cannot be stopped by a GLINK write (the channel opens with it). The SNK write fixed the role afterwards.
- [V] `event 0x0000c046` = endpoint event, physical ep 3 (0x81 bulk IN), XferComplete, status IOC|LST: a normal log TX
  batch end. Not a flood: only the first 200 events per boot print (196 in this boot, 83 of them c046; the last ~1 s
  before the drop).
- [V code] ue0 is never re-plumbed after a reset (only KEV_DL_LINK_OFF/ON, address set once at boot); TX queue and log
  socket survive resets. Nothing writes GCTL/QSCRATCH except our ud_hw_start (device mode at every soft reconnect).
- [U] Root cause. Candidates that fit all t22 facts: (a) full-speed link (PD PHY override) with our 512-byte bulk
  packets; (b) IN path dead (tx_busy stuck); (c) stack lost 192.168.7.2 / ARP. The usblog file ends at 05:10:13, so the
  0375 claim "no new en10 up during the 80 s suspend" is not proven.
- 0381 `negroniusb_datafix` (default 0): bit 1 re-init when the host sends SOFs but no frame N s after its link up or
  an IN transfer hangs N s (state lines, soft reconnect + PHY init past the cap, TX queue drop, ue0 up + address again,
  new log socket; 3 per episode); bit 2 raw live log + kernel ARP answer; bit 4 watch only; bit 8 64-byte bulk at full
  speed. `negroniusb_datafix_s` (default 10).
- Test: t22 args + `negroniusb_idle_reboot=90 negroniusb_datafix=0xb`. Read the `data path dead ... state:` lines (speed,
  IN active, ARP count, `GONE from ue0`, PHY DIFFERS) to pick (a)/(b)/(c).
- Build [V]: out/kernel/local-20261027-100646/kernel.development.negroni sha256
  f5af17707f1294d0c1eebb5d137aeaaa8329b17d050e35f15841c4ac8d5504bf (278 applied incl. 0381; 4 dxb skips). Only old
  warning kinds. Not booted, not reviewed, no image.

## 65. Location L0/L1 code: negroni-locd + simulation entitlement (2026-10-27, location userland agent; details docs/location-plan.md section 5)

- [V] 20H392 `locationd` accepts `com.apple.locationd.simulation` clients only with the entitlement
  `com.apple.locationd.simulation` = true (`valueForEntitlement:` + NSNumber `boolValue`); else
  `unentitled client attempting to simulate location`.
- [V] The switch read: `CFPreferencesCopyValue("LocationServicesEnabledIn8.0", "com.apple.locationd", "mobile",
  kCFPreferencesAnyHost)`. [I] file `/private/var/mobile/Library/Preferences/com.apple.locationd.plist`.
- [V] `Beginning Simulation Service` is in no phone log so far: [U] the listener may start late or on a condition.
- Code: `userland/location/` (build.sh -> `out/location/userland/negroni-locd`), `scripts/location/phone-location.sh`
  (live phone), `scripts/location/root-add-locd.sh` (LOCD=1, LOCD_JOB=1), `root-tweaks-extra.py` LOCATION_SWITCH=1.
  All default off. Not tested on the phone.

## 66. Wi-Fi: wifid does not scan because its init stalls, not because of Bluetooth (2026-10-27, Wi-Fi iOS agent 2; no patch; details patches/xnu/README-wifi.md "0346 analysis")
- [V] The lead "wifid waits for bluetoothd to exit" is wrong. t21 (0 bluetoothd exits) and 03:01 (bluetoothd alive)
  finished the init within 1-3 s; boot 16 #1 saw an exit and stayed stuck 4 min; 16 #2 saw four exits in its 50 s
  stall. The exit timing in 02:42 / 02:54 is coincidence (bluetoothd crashed every ~10 s then).
- [V] wifid's own log (logs/phone-log-20261027-025305.txt): `WiFiManagerScheduleWithQueue: entering` at 14:23:36.4,
  then nothing until 14:24:26.18 (50 s). In the stall the WiFiManager MIG server and the CoreWiFi XPC listener are
  not up, so Settings has no Wi-Fi interface. After it: `First unlock since launch`, `Turning WiFiManager ON`,
  `Device power state = ON`, Settings `interface became available`, and the only SCAN_REQ (02:54:35).
- [V] t23 is the same stall: open (12, 96, 97) at 12:11:54, no POWER/106/254, no `exec wifianalyticsd` until the log
  ended at 12:14:51, Settings opened at 12:13:14. The kernel (en0, Apple80211, AKS lock state 0x6) is not the blocker.
- [I] The stall is a synchronous wait for another process in `WiFiXPCManager activate` / `CWFKeyValueStore activate`
  (wifid 0x10006b954-0x10006b968), about half of the boots with en0, no timeout. Suspects, not proven: runningboardd
  (RBSProcessMonitor in CWFXPCManager init), cfprefsd, accountsd.
- Next (phone): in the stall run `scripts/wifi/wifid-stall.sh` (spindump of wifid + all processes) and read the main
  thread; test the work-around "kill wifid, launchd restarts it" (boot 16 #2 got through). Then decide the fix.

## 67. GPU "iffy" and hot: IFPC was off after every 0298 boot; 0384 governor + fence IRQ + slumber fix (2026-10-27, GPU kernel agent; patch 0384, details patches/xnu/README-gpu-kernel.md section 28)
- [V] Every 0298 boot: IFPC accepted and on, then 3 x `17 HFI PREPARE_SLUMBER ack, error 1002` -> `slumber off for this boot`
  (bootlog-13.txt:1693-1758, also bootlog-3/6/11, usblog-20261027-060101.txt:732-797, usblog-20261027-121304.txt:3255-3306).
  The code then set `PM_OFF` with OOB GPU_SET held: GX powered for the whole boot (`pm off`, `GX 0xf8222800` in all 3819
  WATCH lines of bootlog-12.txt, a 7.1 h boot). The 0285-only boot had IFPC working (usblog-20261026-131747.txt:1030
  `GX collapsed 100%`).
- [V] The 0286 UI floor held 640 MHz + DT bus 10 (bootlog-12.txt: level 9 in 3482 of 3819 lines, busy 0 % in 3768).
- [V] Frames wait on the GPU fence, not on the clock: usblog-20261027-121304.txt 3112 `gpu-wait skips` for 6218 presents,
  also at level 9. No hang or recovery in any log. Metal client crashes are userland: AegirPoster `CAMetalLayerInvalid:
  unsupported extended range format` (:111), then 73 x SIGABRT in a loop.
- [V code] KGSL turns the GMU power counter off before PREPARE_SLUMBER and sends `{freq 2, bw 2}` (initial-pwrlevel 10), after
  the lowest idle level (adreno_gen7_gmu.c:1424-1450, 2513-2535). 0298 sent `{0, 0}` with the counter on. [I] that is error 1002.
- 0384: IFPC never goes off on a slumber failure; KGSL slumber order; slumber only with the display off (FB power request);
  wake retry after a reset; Linux simple_ondemand governor (90/5) on the GMU busy counter over the DT OPPs (220-818 MHz, DT bus
  vote), level 1 when idle or display off, late-frame step, no UI floor by default; `negronigpu_level=N` = fixed level (removed
  from config/negroni-ne2211.toml); fence interrupt on GIC SPI 300 (INTID 332, CACHE_CLEAN_TS) wakes RedwoodGPU's fence
  waiters, polled fallback 1000 us. Kernel out/kernel/local-20261027-110800 (sha256
  cee20b34f7e6e935d98021c656795df5a09b7d6e50a74f798a31829bf3825dbc), no image, not booted.
- Next: boot it (README section 28 test plan). If `irq armed` with `fence 0/s`: the line does not reach the CPU (INTID or
  GIC group). If PREPARE_SLUMBER is still refused: IFPC stays (cost far below `pm off`); look at the ack word.

## 68. Phone hot with the screen off: no core, cluster or APSS power-down ever ran; 0383 OSI cluster states, RPMh sleep sets, sleep stats (2026-10-27, power kernel agent; patch 0383, details patches/xnu/README-cpuidle.md "0383")

- [V logs] All logged boots ran `negronicpuidle=0` (WFI only); no PSCI idle line exists in logs/. The everything image
  has `negronicpuidle=1`, but no log of it shows the CPUIDLE lines.
- [V Gunyah source, out/src/gunyah via scripts/setup/fetch-rpmh-sleep-sources.sh] XNU is the HLOS VM of Gunyah. A vCPU
  in WFI stays "active" for Gunyah's PSCI aggregation, so the physical CPU only clock-gates. Only CPU_SUSPEND lets
  Gunyah power down the core / L3 / APSS. Gunyah gives the HLOS FEATURES(CPU_SUSPEND) = 3 (OSI + extended StateID), the
  VM starts in PC mode, SET_SUSPEND_MODE(OSI) is allowed while no other vCPU is suspended.
- [V] apps RSC DRV 2: no HW solver (solver=0x4010100), TCS 0-2 ACTIVE, 3-4 SLEEP, 5-6 WAKE, 7 FAST (live.dts
  tcs-config). Before 0383 only ACTIVE votes. With Linux rules (sleep != wake only) our current votes give no sleep/wake
  pairs: the missing APSS collapse, not the sleep sets, is the main reason CX/XO stay up. [I] UEFI votes left in DRV 2
  are not visible.
- 0383: `negronicpuidle=3` (OSI, last core picks l3-off; llcc-off only with `negronicpuidle_llcc=1`), RPMh ready check
  before any cluster param, `negronirpmh_sleep=1|2` SLEEP/WAKE sets (default 0), read-only stats every 60 s: AOP
  rpmh-sleep-stats (aosd/cxsd/ddr), DDR LPM counts, CPUSS C4/D4 counters (`negronicpuidle_stats`, also at level 0 when
  given = WFI baseline). Kernel defaults unchanged (0).
- [V] Build `k0383`: kernel out/kernel/local-20261027-111225 (sha256
  0a0f433450f4452cb430c6c00d715cb8853a118667b2dbf0e673349fa097498b), 0383 applied, the 4 usual dxb skips. Not booted.
- Next: README-cpuidle.md "0383" test plan, steps 1-5 (baseline stats, level 1, 3, + llcc, + rpmh sleep), screen off
  5 min each, compare `aosd`/`cxsd` `+N` and the battery current.

## 69. Screen-off wakeups: ~1270 timer wakes/s from pollers; 0382 adaptive polls + NEGRONI TOP (2026-10-27, power-idle kernel agent; patch 0382, details patches/xnu/README-power-idle.md)

- [V source] Before 0382 no driver read the display state. Screen off: USB `ud_thread` 1 ms (also with no cable),
  touch 10 ms, keys 20 ms, BT RX 20 ms (also with the chip off), chg GLINK 50 ms, FB tick 100 ms + a vsync
  notification to every client per tick, cpufreq 100 ms, battery 1 s (+8 IOSleep(1)): [I] about 1270 wakes/s,
  so no core reaches the 4 ms PSCI residency (0288/0383).
- [V source] The CPUFREQ `busy` is the busiest core over 300 ms, printed mostly on row changes: a biased sample.
  Unbiased minute lines with the screen off (usblog-20261026-131747 13:28-13:30): d0 34-56 %, d1/d2 ~0.
- [V source] `delay()` never spins in thread context here: powergate_latency 0 -> cpu_idle_latency 0 ->
  ml_delay_should_spin FALSE -> it blocks on a timer. negronicpuidle=0 = WFI (clock gating only).
- [V log] FB STAT/TE/VRR/DBUF/DPU lines print every 1 s with the screen off (297 FB STAT lines in 322 s off),
  which also keeps the UFS boot log writing every 5 s.
- [V log] bluetoothd crash-loops every 10 s (`reason=1201`), each start reloads the BT controller (500-780 BT
  lines/min); AegirPoster crash-loops (60-90 per 10 min). Userland, not changed.
- [V log] Boot 12 (7 h): no `display off` in the last 4352 s; 66 frames/s on the lock screen, GPU 639 MHz at 0 %
  busy, CPU 49-53 C on USB power. The display never slept (check Auto-Lock).
- 0382: `negroni_display_asleep` (FB); USB idle poll 4 ms / 20 ms dark or no host (1 ms with host data in 2 s,
  200 us only for host traffic, TX wakes the thread); USB live log 250 ms dark / 1 s unconfigured; touch 50 ms,
  keys 40 ms, battery plug tick 5 s while dark; BT RX 1 s with the chip off; FB off tick 500 ms after 5 s dark
  with a wake kick; dark stat lines once a minute; DPU TE SPI masked while dark; `negronifb_offnotify=0`
  (gated, default 1) stops dark vsync notifications. Watchdogs 0371/0375/0381/0368 unchanged in function.
- New diagnostic `NEGRONI TOP` every 60 s (negronitop): busy % and irq/timer/ipi per second per CPU, top
  processes and threads (kernel threads with unslid return addresses). `scripts/power/idle-log.py LOG` sums it.
- Build [V]: out/kernel/local-20261027-111424/kernel.development.negroni sha256
  783eb5ca4f53f6e5458b01a6889141c9ad398983e5f8218ec5203af5806801f1 (0382 + 0383 + 0384, the 4 usual dxb skips).
  Not booted, no image.
- Next: README-power-idle.md section 6 (screen off 5 min with usblog, then idle-log.py; A/B with the old values).
- Opus review (2026-10-27), 4 fixes in 0382 (compile-checked: negroni_usb.c, NegroniFramebuffer.cpp with 0384,
  negroni_top.c; 0383/0384 still apply). The build above is from before these fixes.
  (1) FB: the dark flag was stored after fLock was dropped. A wake in that window left it at 1 with the display
  on (slow pollers, TE IRQ masked until the next off/on). Now it is stored under fLock, only while fPowerOff.
  (2) TOP: `bzero(tasks)` after the thread walk cleared the sums, so the procs line was always empty. Moved
  before the walk. (3) TOP: the kernel-stack read of a blocked thread was not locked. The thread could run,
  hand off its stack, and stack_collect could unmap it (data abort). Now read under thread_lock at splsched.
  (4) USB: a frame queued between ud_poll_period() and assert_wait got no wakeup (one long period, max 100 ms,
  for its completion). ud_poll_sleep_ms checks the TX state again after assert_wait (long sleeps only).
  New A/B switch `negronifb_asleep=0`: the flag stays 0, so every dark-dependent poller is as before.
  idle-log.py: TOP thread frames were never captured (regex); TOP procs now follow the window's dark flag.

## 70. t25: the 0368 PHY repair refused a Mac port (adapter type 17 = PD_SDP); 0385 gate fix (2026-10-27, USB kernel agent; patch 0385, details patches/xnu/README-usb.md "0385")

- [V log] t25 (logs/bootlog-1.txt, `negroniadsp=1 negronichg_typec=3`): ~2.2 s after the ADSP start the charger PD writes
  the HS PHY (utmi0 21212121, utmi1 1010101, ctrl2 e0e0e0e, cfg0 3030303), at +5931 ms it leaves utmi0 9090909 +
  cfg0 1010101 (SLEEPM + OPMODE non-driving with the datapath override: no pull-up). Link L2, never back.
- [V log] Our typec SNK and OTG-off writes succeed. The PD reports `adapter type 17`. Every 0368 repair and every
  reconnect PHY init was refused (`the adapter type is not a host port (SDP/CDP)`); 0371 rebooted after 60 s.
- [V source] 17 = `POWER_SUPPLY_USB_TYPE_PD_SDP` ("USB With PD Port", oplus_charger.h:481); stock maps it to
  POWER_SUPPLY_TYPE_USB (an SDP host port that is also a PD source).
- 0385: the gate allows SDP/CDP/PD_SDP, or any type after a host in this boot (SET_CONFIGURATION or SOFs); it refuses a
  wall charger (DCP/HVDCP/BrickID) without a SET_CONFIGURATION in this boot and VOOC (0369). hp_init now writes utmi0,
  utmi1, ctrl2 and cfg0 back to the gadget start values and logs `UTMI overrides cleared|NOT cleared`. Re-apply after a
  new PD write: the 0368 watch, at most 5 per ADSP start. 0366/0371/0375/0381 unchanged.
- [I] The PD's non-driving write is part of its BC1.2/PD detection on D+/D-; it does not undo it because on stock the
  HLOS USB driver re-inits the PHY at each role change. Not booted yet.
- Build [V]: out/kernel/local-20261027-115931/kernel.development.negroni sha256
  de9908ce7d530e80c2633efda81114ad56df8e0fa510ab31fdf41a655fbb5ae5 (the 4 usual dxb skips). Not booted, no image.

## 71. Wi-Fi: Settings hangs on Wi-Fi because configd InterfaceNamer never publishes *QUIET* (no IONetworkStack); WaitStackTimeout tweak (2026-10-27, Wi-Fi agent; no kernel patch, details patches/xnu/README-wifi.md "wifid stall root cause")
- [V] Spindump (`logs/wifid-spindump-20261027-173347.txt`): wifid's first `SCNetworkInterfaceCopyAll` (CoreWiFi
  `CWFSCNetworkInterface` init on the XPC-common-mutex queue) is in `__wait_for_IOKit_to_quiesce`, a
  `SCDynamicStoreNotifyWait` loop on configd key `Plugin:InterfaceNamer` until it has `*QUIET*`, `*COMPLETE*` or `*TIMEOUT*`.
  Every other wifid queue waits on that thread, so the WiFiManager server is not up and Settings waits.
- [V] configd InterfaceNamer adds `*QUIET*` but publishes only with an IONetworkStack user client (`No network stack
  object` x234 in t23). Our kernel has no IONetworkStack. The stack timer (WaitStackTimeout, default 300 s) publishes
  `*TIMEOUT*`. Boot 16 and the spindump boot: wifid init at configd exec + 302 s and + 301 s.
- [V] `logs/phone-full-20261027-1743.txt` was taken after the stall ended (wifid[407] passed at 17:37:39, configd + 301 s);
  it shows wifid working (XPC answers, en0 ioctls), not the wait.
- [I] Good boots: another updateStore (upgrade / pre-configured / lockdown trust list) published `*QUIET*` early; a race.
- Fix (default off): `WaitStackTimeout` in `InterfaceNamer.bundle/Info.plist`. Root: `IFNAMER_WAIT_S=10`
  (`scripts/ios16/root-tweaks-extra.py` item 8). Live: `scripts/wifi/phone-ifnamer-timeout.sh on 10`, reboot.
  Not tested on the phone. Kernel option (IONetworkStack stub with a user client) is in the README, not done.

## iOS 26 kernel: same series as iOS 16 + 12377 rules (2026-10-27, iOS 26 agent; branch ios26-prep, details docs/ios26-port-status.md, patches/xnu-12377/README.md)

- [V] `scripts/ios26/apply-series.py` applies slop + `patches/xnu/*.patch` unchanged on the 12377 base 0001-0005;
  12377 differences are data rules (`scripts/ios26/patch-rules.py`) + `patches/xnu-12377/skip.txt`. Result:
  154 applied, 96 applied+rules, 0 replaced, 39 skipped, 0 errors. Stage 1 kernel links (22,547,872 bytes,
  SHA-256 `bdfa185f...61aa`). A new iOS 16 patch that breaks on 12377 stops `scripts/ios26/build-kernel.sh`.
- Gotcha: `git apply --recount` reads the next plain-diff header `--- a/...` as a removed line; slop patches are
  plain diffs. The tool recounts hunk headers itself instead.
- Gotcha: `git apply --reject` creates no file at all when one file of the patch is missing ("No such file").
- Gotcha: the build-list "glue" rule (add `+` lines next to their context anywhere in the file) is only safe for
  `*/conf/files*`; on a Makefile.template it dropped an `endif` ("missing `endif'").
- 12377 API facts: `kmem_alloc`/`KMA_*` in `vm/vm_kern_xnu.h`; `struct vm_shared_region` in
  `vm/vm_shared_region_xnu.h`; no `vm_map_lock_read`/`vm_map_lookup_entry` (VM map range locks); `pid_hibernate`
  in `kern_proc.c`; `pset->primary_map` only with `CONFIG_SCHED_SMT`; the realtime CPU choice is in `sched_rt.c`.

## Mi A3 (laurel_sprout) port start (2026-10-31, branch laurel-sprout; details docs/laurel_sprout/port-plan.md)
- [V] Phone: SM6125, Kryo 260 Gold `0x51AF8002` x4 + Silver `0x51AF8014` x4, ARMv8.0 (no LSE, no RCpc, no PAC, no PAN),
  6 GB, Adreno 610 v1, 720x1560 Samsung AMOLED, UFS `0x4804000`, Android One 11 `V12.0.26.0.RFQMIXM`, active slot `_b`, no root.
- [V] Same MIDRs, GPU, GIC (`0xF200000`/`0xF300000`), UFS and splash FB (`0x5C000000`) as ios-topaz (SM6225). Topaz runs
  XNU on the Gold cores only (Silver has no 16K granule) and emulates LSE/`ldapr` for the iPhone X userland.
- [V] Mu-Silicium has `Platforms/Xiaomi/laurel_sproutPkg` on `Silicon/Qualcomm/NicobarPkg`.
- [I] iOS 26 needs PAC lowering of the arm64e userland (zeta route); the negroni native-PAC route does not apply.
- `/proc/cmdline` and the live FDT need root; the RAM banks for the ADT are still [U].

## Mi A3 fastboot facts and first boot tests (2026-10-31, branch laurel-sprout)
- [V] Bootloader fastboot (ABL, USB 18d1:d00d) is the right mode; no fastbootd (no dynamic partitions,
  `is-userspace` unknown). Enter it with `adb reboot bootloader`; max-download-size 805306368.
- [V] **This ABL refuses `fastboot boot` ("unknown command") for every image, also the stock boot.img**, in any
  command order. The upload (`download`) works. So the shim image must be flashed to `boot_b` (owner approved
  2026-10-31). Restore: `fastboot flash boot_b ~/laurel-backup/stock/images/boot.img` (V12.0.26.0.RFQMIXM, sha256 201b9e9f...).
- [V] ABL replies get out of step after some failed commands (`getvar` answers belong to the previous command,
  "unknown command"); entry by buttons after a failed boot left `getvar` broken. A clean session (Android ->
  `adb reboot bootloader`) fixes it. `fastboot reboot bootloader` started Android instead of fastboot.
- [V] The first test (22:51) hung the ABL after the upload (USB dropped at 22:52:24, nothing drawn); not our image running.
- [V] Host: Google platform-tools 37.0.1 in ~/.local/bin (scripts/setup/platform-tools.sh); distro fastboot 37.0.0 behaves the same.
- Shim: draws into the buffer the MDP scans out (patches/laurel/shim/0001: VIG0/DMA0/DMA1 SRC0_ADDR/stride/format),
  first lines `FB <addr>`, `pipe= fmt=`, `stride= bpp=`.
