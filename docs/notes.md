# Notes: what we learned (read this first)

The knowledge base for this port. Agents: read this file before you start, and add what you learn
before you stop (facts, numbers, errors and their fixes, decisions). Keep one fact per line, with a
source. Mark each fact: **[V]** = seen (log, source, measurement), **[I]** = inference / guess.
Details that need more space go into the topic docs; link them from here.

Topic docs: [plan.md](plan.md) (phases) · [device-facts.md](device-facts.md) (measured hardware) ·
[boot-speed.md](boot-speed.md) · [gpu-plan.md](gpu-plan.md) · [external-repos.md](external-repos.md) ·
[build-ios16.md](build-ios16.md) · [flash-ios16.md](flash-ios16.md) · [backup-and-restore.md](backup-and-restore.md) ·
[research-report.md](research-report.md) · [uefi-binaries.md](uefi-binaries.md) · [camera-plan.md](camera-plan.md) · `patches/xnu/README-*.md` (per kernel change).

## 1. Current state (handoff, 2026-10-24)

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
| Audio plan + ADSP firmware + ADSP start | `docs/audio-plan.md`, `scripts/audio/`, `patches/xnu/0240` | kernel build |
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
| Audio | AudioReach (GPR/q6apm, not APR); 2x TFA9874 on i2c13 (0x34/0x35, reset gpio50/51) via TERTIARY_TDM_RX_0; WCD9385 over SoundWire; ADSP remoteproc@30000000, PAS id 1, mem 0x85e00000 size 0x2100000, smp2p pid 2; ADSP firmware in `modem_a` | slop NOTES "audio plan" [V DT] |
| Wi-Fi | QCA6490 (no driver in any port) | [I from DT] |

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
  before the hang. Cause unknown [I: a respring + font cache rebuild under CPU rendering, then a crash on
  boot with the pref set]. Pref: `com.apple.Accessibility` in /var/mobile/Library/Preferences [I].
  Recovery: re-flash `userdata` (fresh root). Capture `make usblog` during the next attempt.
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

## 12. Wi-Fi (2026-10-24)

- [V] `out/kernel/wt-wifi/bsd/dev/negroni_wifi.c` in base has Wi-Fi survey steps 1–9; steps 1–4 are reads, steps 5–8 enable supplies/clocks and train PCIe0, and step 9 reads PCI ID/class/BAR registers (source comments in `external/slop/negroni-ios/xnu/patches/0120-negroni-wifi-pcie-link.patch`).
- [V] The current port code does not assign the endpoint BAR or enable an MSI/MSI-X vector; new patch `patches/xnu/0260-negroni-wlan-pcie-inventory.patch` adds an opt-in `negroniwlan=1` and read-only BAR/capability inventory (worktree source; not run on hardware).
- [V] Wi-Fi worktree branch `wifi` commit `a559154` contains the inventory source change; no push was made (`out/kernel/wt-wifi`).
- [V] Wi-Fi docs, extraction script and patch export are committed locally on `main`; no push was made.
- [V] XNU single-file syntax check of `bsd/dev/negroni_wifi.c` succeeded against `out/kernel/buildtree`; it emitted three warnings already present in the source (two shadowed locals and the existing `delay` signedness conversion).
- [V] `scripts/bg.sh wifi-fw scripts/wifi/extract-fw.sh` completed with exit 0 using the NE2211 OTA; its run log is `logs/wifi-fw.log` and WLAN outputs are ignored under `out/firmware/wlan/`.
- [V] Extracted `amss.bin` SHA-256 is `d3328c8a78a1839c13bb33b6d20a4dd5fb4f8d57c4d8a1b482b037485bff40d9`, `m3.bin` is `7446e09fb911c690368d7b2c41216854ddfc7938d6a9d01ce3faa5f21cbc90b5`, and `regdb.bin` is `51808db5a23dc10346335e957ce88b8396d2e7c1870d7c67a2c0602a90f4fb32` (`out/firmware/wlan/SHA256SUMS`).
- [V] The stock modem FAT image lists `bdwlan.*` calibration files; this extraction did not find `board-2.bin` (`out/firmware/modem/modem.img`, `out/firmware/wlan/`).
- [I] MHI/BHI download is not safe to enable until a verified endpoint BAR mapping, DMA allocation/cache contract, and kernel-accessible firmware buffer are implemented; no MHI or BHI command has been issued in this round (`docs/wifi-plan.md`).

## 12. Camera (research handoff, 2026-10-24)

- [V] `out/live.dts:22144-22578` exposes four Qualcomm camera sensor slots on CCI0/CCI1 and CSIPHY subdevice indices 1, 2, 5, 0; it does not provide sensor model names, I2C addresses, or complete lane maps.
- [V] `out/live.dts:22130-22578` includes actuator, EEPROM and OIS nodes; OIS identifiers include LC898128 and LC898124.
- [V] `out/live.dts:184-188` reserves camera memory at `0x9f500000` for `0x800000` bytes; line 13481 contains `qcom,vmid-cp-camera-preview-ro`.
- [V] OnePlus lists main Sony IMX789, ultra-wide Samsung JN1, and telephoto 8 MP/OIS; independent reviews identify telephoto OV08A10 and front Sony IMX615. This does not map modules to DT slots. Source: [camera-plan.md](camera-plan.md), vendor links there.
- [V] Upstream Linux has a public SM8550 CAMSS binding, but no SM8450 CAMSS variant was found in the examined mainline tree; Qualcomm documents a separate downstream Camera Core Driver and upstream CamSS. Source: [camera-plan.md](camera-plan.md).
- [V] `external/hackios-xnu-kernel/xnu/files/bsd/dev/redwood_camera.c` is camera work for POCO X5 Pro / redwood and its sensor configuration does not apply to NE2211.
- [I] iOS 16's D22AP camera path likely expects AppleH10CamIn/Apple ISP private interfaces; validate daemon and driver names against the local 20H392 root before implementation.
- [I] iOS has no documented third-party CMIO/DAL custom-camera extension route; a fake AppleH10CamIn provider is a research-grade route to stock capture apps.
- [I] First action: offline decode of stock DTBO/vendor camera modules, then one sensor's guarded CCI chip-ID probe. See [camera-plan.md](camera-plan.md).

## 13. Bold Text (research, 2026-10-24)
- [V] `AccessibilitySettings.bundle/AccessibilitySettings` strings include `boldTextEnabled:`, `setBoldTextEnabled:specifier:`, and `legibilityWeight`; source: offline strings inspection of `/private/tmp/blwork/root` while mounted.
- [V] UIKit names its app notification `UIAccessibilityBoldTextStatusDidChangeNotification`; it is an `NSNotification`, and public API exposes `UIAccessibility.isBoldTextEnabled`; sources: Apple UIKit documentation linked in `docs/boldtext-crash.md`.
- [V] Public iOS 16 evidence identifies preference `com.apple.Accessibility:EnhancedTextLegibilityEnabled`; Apple device-management accessibility command names corresponding command field `BoldTextEnabled`; source: Apple Device Management docs and iOS reproduction linked in `docs/boldtext-crash.md`.
- [V] Offline font inventory seen in the root included `CoreUI/SFUI.ttf`, Helvetica Neue families, and other Core/CoreUI fonts; source: `find` output from `/private/tmp/blwork/root/System/Library/Fonts` while mounted.
- [V] `root-tweaks-extra.py` and slop `sweet-root-tweaks.py` do not remove font files; sources: those scripts.
- [V] No log records the Bold Text incident: `logs/usblog-20261024-195455.txt` ends before the reported hang; cause remains undiagnosed.
- [I] The leading hypothesis is a SpringBoard/UIKit restart or rendering path under CPU-only software drawing; there is no direct crash trace.
- [I] No exact Darwin notification, CoreText/fontd cache rebuild event, or proven managed restriction that disables the switch was established; do not describe the UIKit notification as Darwin.
- [V] Added `scripts/ios16/root-tweaks-boldtext.py`, which saves `EnhancedTextLegibilityEnabled=false` in a newly built root; it resets startup state but does not lock/hide the Settings switch; source: script.
- [V] Recovery and next-attempt capture steps are documented in `docs/boldtext-crash.md`; they were not run and the phone was not touched.

## 13. Display (from the brightness agent, 2026-10-24)

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

## 14. Metal (2026-10-25, Metal agent)

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
