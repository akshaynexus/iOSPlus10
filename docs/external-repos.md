# External repositories (`external/`)

These are the HackiOS-family projects we found: every public port of Apple's XNU and iOS userland
to Android phones that was useful to us, plus the UEFI and loader projects the negroni chain is
built on. The required ones are git submodules. The reference ones are **not** submodules: they are
git-ignored and `scripts/setup/get-references.sh` (`make references`) clones each one at the commit
pinned in its table (`-l` lists the state, `NAME...` fetches only those, a directory that exists is
never changed).

**Forks (2026-10-25):** the five repos the build actually needs are forked to `akshaynexus` and our
changes are committed there, so a clone of this repo gets a working submodule: `Mu-Silicum-negroni`
(`main`) with nested `mu_basecore` (`iosplus10`) and `Silicium-ACPI` (`main`), plus `UniXNU`
(`iosplus10`) with nested `DarwinBoot` (`main`). `origin` in each local checkout points at our fork,
`upstream` at the original. Reference repos stay on their original URLs with no changes;
for those we still keep our work in this repo (`scripts/`, `patches/`, `config/`, `tools/`) and apply
it with scripts.

## Needed to build (the build reads these)

| Submodule | Used by | What we take from it |
|---|---|---|
| `slop` (MellysInformejtik/slop) | `scripts/kernel/prepare-src.sh`, kernel CI, `scripts/ios16/build.sh`, `scripts/ios16/root-*.sh`, `scripts/uefi/*` | The negroni port: 125 xnu-8796 kernel patches + 3 staging scripts (`negroni-ios/xnu/patches`), the shim (`shim/`), `mkadt.py` + `adt.py`, `mkdarwinboot.py`, `sweet-root-tweaks.py`, `mkiosroot.sh` (Linux root), `remotezip.py`, the UEFI patch tools. **Required.** |
| `Mu-Silicium-negroni` (**akshaynexus/Mu-Silicum-negroni**, fork of pawlickerr) | `scripts/uefi/setup-mu.sh`, `prepare.sh`, `build.sh`, `build-macos.sh` | The Mu-Silicium UEFI tree with `negroniPkg`, built into `SILICIUM_UEFI.fd`. Our fix on top: `patches/mu/`, plus committed in the fork: `Kernel RAM` at `0x841000000`. Nested `mu_basecore` (branch `iosplus10`: timer freq PCD fallback, boot menu Power Off/Exit, USB `TPL_CALLBACK`, AArch64 `.text`, runtime variable write protection) and `Silicium-ACPI` (`Platforms/OnePlus/negroni` SSDT/Touch/GPU tables) also on our forks. **Required.** |
| `UniXNU` (**akshaynexus/UniXNU**, branch `iosplus10`, fork of UniXNU/UniXNU) | the Mu build (`UNIXNU_ROOT`), `scripts/uefi/prepare.sh` | `package/UniXNUPkg` (boot manager) and the `drivers/DarwinBoot` submodule (loads XNU, fork **akshaynexus/DarwinBoot** on `main` with the boot-refused-on-screen debug), linked into the Mu build. Branch `iosplus10` = upstream `main` minus 30 commits + our DarwinBoot pointer (keeps the tested state). **Required.** |

## Reference only (read, compared, ported from; not used by the build; `scripts/setup/get-references.sh`)

| Repo | Device / scope | What it is good for |
|---|---|---|
| `ios-sweet` (akshaynexus/ios-sweet) | Redmi Note 10 Pro (SM7150), iOS 16 | The original XNU-on-Qualcomm port everything below forks from. Our fork. |
| `ios-sweet-upstream` (dipa-studio/ios-sweet) | same | Upstream of all sweet-based ports; watch for new commits (e.g. `/pram` panic region, 1664d63). |
| `UniXNU-negroni` (pawlickerr/UniXNU-negroni) | OnePlus 10 Pro (NE2213), iOS 16 | The negroni device repo (board file, payload/boot scripts). Our `config/negroni-ne2211.toml` and `scripts/ios16/build.sh` replace its WSL-specific scripts. |
| `UniXNU-ios26` (none24smu/UniXNU, `ios26`) | Surface Duo 2 work, xnu-12377 (iOS 26) | iOS 26 kernel work: starting point for our iOS 26 phase (arm64e/PAC). |
| `UniXNU-zeta` (none24smu/UniXNU-zeta) | Surface Duo 2 (SM8350, no PAC), iOS 26 | Shared-cache PAC rewrite (not needed on our PAC CPU); "lite" job list; boot watchdog policy. |
| `UniXNU-pong` (Chengdong-Yu/UniXNU-pong) | Nothing Phone 2 (SM8475, Adreno 730), iOS 16 | Same GPU family as ours; on-demand launchd policy (`userland/mkjobs.py`, `build.py`); no-RTC-wait patch. |
| `ios-sailfish` (joranv1/ios-sailfish) | Pixel 1 (MSM8996), iOS 16.7.16 20H392 | **Working GPU** (Mesa freedreno + EAGL shim in `tools/sweetgl`), ~20 s boot, root tweaks (jobs, feature flags), kernel fixes (IORTC wait, empty IOAcceleratorES, AKS lock state). Main reference for GPU and boot speed (`docs/gpu-plan.md`, `docs/boot-speed.md`). No license file: reference only. |
| `ios-flame` (NWylynko/ios-flame; a submodule, the userland build reads it) | Pixel 4 (SM8150), iOS 16.7.16 20H392 | ADT MAC fix, fairplayd deadlock, IORTC, AMFI policy + IOService stand-in, kernel command server (UDP 5141 reboot), Metal-through-Turnip notes for iOS 16. MIT. |
| `bergamota` (ry-diffusion/bergamota, `develop`) | POCO F1 (SDM845), iOS 16 and **iOS 18 (xnu-11215)** | The newer-kernel path: CI recipe for xnu-11215 (macos-15 / Xcode 16.2), iOS 18 ABI fixes, pacstrip; SSH over USB (`tools/ssh`, `usbnet()`, `ssh()`), reboot-mode notes, log tools. No license file. |
| `ios-apollo` (aTechGeekDev/ios-apollo) | Mi 10T 5G (SM8250), iOS 16 | Hypervisor-safe MMIO accessors (no post-indexed loads), staged GPU zap ladder. MIT. |
| `hackios-xnu-kernel` (oosexgang; `hackios-xnu-userland` is a submodule) | POCO X5 Pro (SM7325), iOS 16.5 | HackiOS: ~20 s boot with an on-demand job set, Mesa + EAGL GPU path, AKS wrap/unwrap, in-kernel APFS, loader-return logging. |

## How we use the reference repos

- **Findings**, with file and line evidence: `docs/research-report.md` (stack, iOS 26), `docs/boot-speed.md`
  (boot time), `docs/gpu-plan.md` (GPU).
- **Porting rule**: code that we adapt from a reference repo goes into our own files (`patches/xnu/`,
  `scripts/`), with a comment naming the source repo, file and commit. Check the source license first:
  `ios-sailfish`, `bergamota` and `slop` have no license file; `ios-flame`, `ios-apollo`, `ios-sweet` are
  MIT; UniXNU is BSD-2-Clause-Patent.
- **Updating**: a submodule pin moves with `git submodule update --remote external/<name>`. A reference
  pin moves by a new COMMIT in the table of `scripts/setup/get-references.sh`; check
  `docs/boot-speed.md` / `docs/gpu-plan.md` for what to re-read.
