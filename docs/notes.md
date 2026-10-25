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
- The ~10 s power-button-to-dark delay is iOS sending RequestPowerChange late; 0251 adds a kernel
  fast-off on a short power-key press (< 700 ms) [I until tested].
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
  - [V] `gl-build` exit 0: stripped negronigl.dylib 14,214,624 bytes, sha256 e527b636...; backboardd unchanged
    (39cb14d1...); check-imports PASS (0 missing). Not run on the phone yet.
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

## 17. Audio (audio agent, 2026-10-25; details: docs/audio-plan.md)

- [V] 20H392 HAL plug-in paths: /System/Library/Audio/Plug-Ins/HAL, /Library/Audio/Plug-Ins/HAL, /Library/Apple/Audio/Plug-Ins/HAL (shared cache strings). Apple drivers there are plain arm64 bundles, CFPlugInTypes 443ABAB8-...; BasebandVoice.driver's table = NULL + 22 function pointers (same as the macOS SDK AudioServerPlugInDriverInterface).
- [V] mediaserverd SIGABRT (logs/symb-mediaserverd.log) = std::terminate in a dispatch block (uncaught exception); the block is not in the backtrace.
- [V] Stage 0 plug-in `userland/audio/build.sh`: arm64, minos 16.0, ad hoc signed, layout check vs SDK 23/23, host test PASS; root hook `AUDIO=1 scripts/audio/root-add-audio.sh` (via root-finish.sh, default off), tested on a fake root. Not on the phone yet.
- [V] Speaker path on Android: PAL `MI2S-LPAIF-RX-TERTIARY` 2 ch 48 kHz S24, VI `MI2S-LPAIF-TX-TERTIARY`; BCLK 48000 x 2 x 32 = 3.072 MHz (AK msm_common.c:443-458); the TDM tert node (1.536 MHz) is not used. Speaker data on SD1 = GPIO124, VI on SD0 = GPIO122 (ACDB I2S sink iid 0x425A).
- [V] GPR: header 24 bytes (word 0 = 0x1860 for header only), domains APPS 3 / ADSP 2, ADSP ports APM 1, PRM 2, AMDB 3; DT ports 3/7/0x17 are APPS-side. SPF ready = APM_CMD_GET_SPF_STATE 0x01001021 -> 0x02001007 status 1. PRM clock 0x104 (TER MI2S IBIT) via PARAM_ID_RSC_AUDIO_HW_CLK 0x0800102C.
- [V] Phone ACDB (odm/etc/acdbdata/acdb_cal.acdb) speaker device graph: SAL -> NXP TFA RX 0x1700B911 (dynamic CAPI, libtfadsp_rx.so) -> SPLITTER -> LOG -> I2S_SINK 0x0700100A; no graph uses TDM_SINK 0x0700100E.
- [V] TFA9874 has no on-chip DSP; the stock kernel driver never talks to the ADSP; register writes alone start it. Reset GPIO is active-high (1, 5 ms, 0, 5 ms). Container odm/firmware/tfa98xx.cnt: 0x34 slot 0, 0x35 slot 1, profiles receiver/speaker/calibrate.cal. Never write MTP (0xF0..).
- [I] Without the NXP module only the on-chip protections stay: keep the gain low (TDMSPKG <= 3 for the first test).
- [V] 0240 review vs Linux (smem, smp2p, qcom_aoss, mdt_loader, PAS SCM): layouts and order match. Fix: RPMh votes retry EBUSY up to 1 s (rail_vote), since touch/Wi-Fi share the RPMh try-lock. Full build OK: out/kernel/local-20261025-102834 (kernel sha256 58fffc0c..., all 19 patches/xnu applied).
- [V] Root image 16 GiB (root-macos.sh SIZE=16g): the firmware areas at the end of userdata do not overlap HFS+.

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
