# Notes: what we learned (read this first)

The knowledge base for this port. Agents: read this file before you start, and add what you learn
before you stop (facts, numbers, errors and their fixes, decisions). Keep one fact per line, with a
source. Mark each fact: **[V]** = seen (log, source, measurement), **[I]** = inference / guess.
Details that need more space go into the topic docs; link them from here.

Topic docs: [plan.md](plan.md) (phases) · [device-facts.md](device-facts.md) (measured hardware) ·
[boot-speed.md](boot-speed.md) · [gpu-plan.md](gpu-plan.md) · [external-repos.md](external-repos.md) ·
[build-ios16.md](build-ios16.md) · [flash-ios16.md](flash-ios16.md) · [backup-and-restore.md](backup-and-restore.md) ·
[research-report.md](research-report.md) · [uefi-binaries.md](uefi-binaries.md) · `patches/xnu/README-*.md` (per kernel change).

## 1. Current state (handoff, 2026-10-24)

**Works [V]:** the full boot chain on the NE2211; iOS 16.7.16 reaches the home screen (photo, 2026-10-24);
touch; power/volume keys; USB live kernel log (`make usblog`).

**Does not work [V]:** GPU (CPU rendering, laggy UI) · Wi-Fi (QCA6490: no driver) · battery level
(no fuel gauge driver) · sound (no ADSP/AudioReach stack) · display brightness and sleep (no backlight
service, no DCS command) · reboot to fastboot from iOS · widgets show "Waiting..." · first boot ~16 min.

**Built, not flashed yet:**
- `out/ios16/` normal image: ADT with `/chosen` MAC addresses, `negroniusb=2`, `negronifb_noconsole=1`
  (no debug text over the UI). Fixes the 16 min first boot [I: same fix worked in 3 other ports].
- `~/op10-apple/ios16-root.simg` (sha256 `3630f5f7...`) with all `root-tweaks-extra.py` tweaks.
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
| Brightness (DCS 0x51) + display sleep | `patches/xnu/0250-0251` | kernel build |

Patch number ranges: 0200-0209 boot waits, 0210-0219 reboot/control, 0220-0229 AKS/AMFI/Sandbox,
0230-0239 GPU, 0240-0249 audio, 0250-0259 display. Take a new range for new topics.

**Blocker: kernel builds.** See section 5. Decision pending with the owner: install Xcode 15.4 locally
(needs ~20-30 GB free disk first; 12 GiB free on 2026-10-24) or a CI repo.

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
- Root tweaks (`scripts/ios16/root-tweaks-extra.py`, on top of slop's `sweet-root-tweaks.py`): drop
  fairplayd.H2, vmd, ReportCrash, spindump, tailspind, aggregated(.addaily), bluetoothd; ExtensionKit
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
