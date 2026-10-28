# iOSPlus10

> [!NOTE]
> **Project Update: Pausing OnePlus 10 Pro Development — Moving to OnePlus 15**  
> Active development on the OnePlus 10 Pro port is paused and focus is shifting to exploring iOS 16 and iOS 26 on the **OnePlus 15**.  
> The physical 10 Pro device has been sold; this repository remains preserved as an open reference for the work completed (UEFI boot, Metal2Vulkan GPU acceleration, Wi-Fi, Bluetooth, and battery fixes).

iOS on the OnePlus 10 Pro 5G (NE2211, "negroni", Snapdragon 8 Gen 1 / SM8450), booted natively
through UEFI. Goal: iOS 26 with GPU (Metal) acceleration. First milestone: the existing iOS 16
port on this phone.

The Cortex-X2/A710/A510 cores have ARMv8.3 PAC (`paca pacg`), so the arm64e iOS 26 userland can
run without the shared-cache rewrite that phones without PAC need.

## Quick start

```sh
git clone --recurse-submodules git@github.com:akshaynexus/iOSPlus10.git && cd iOSPlus10
make help           # all targets; long ones run in tmux (make status)
```

Host setup: [docs/setup-macos.md](docs/setup-macos.md), [docs/setup-linux.md](docs/setup-linux.md).
Knowledge base and handoff (read first): [docs/notes.md](docs/notes.md).
Build flow: [docs/build-ios16.md](docs/build-ios16.md). Status and next step: [docs/plan.md](docs/plan.md).

## Layout

```
Makefile                 entry point (macOS + Linux); long targets start tmux jobs
CLAUDE.md                rules for agents and humans: repo-only work, tmux, phone safety
config/
  negroni-ne2211.toml    board config: kernel CI run, ADT args, boot args, boot image params
docs/
  plan.md                phases and status (read first)
  build-ios16.md         flow, scripts per OS, native vs container, known traps
  flash-ios16.md         make flash / flash-boot / flash-restore, order and why
  setup-macos.md         host setup on macOS (Homebrew, Colima + Rosetta)
  setup-linux.md         host setup on Linux
  uefi-binaries.md       Qualcomm DXEs + ported r0q patches
  research-report.md     stack map, iOS 16 and iOS 26 tracks, GPU path, blockers
  device-facts.md        measured CPU, RAM map, firmware, storage
  gpu-plan.md            GPU path: ios-sailfish reference, A730 state, steps
  external-repos.md      every external repo: submodule (build) vs reference
  boot-speed.md          boot-time findings from the reference ports + status
  backup-and-restore.md  device state, stock backup, restore commands
docker/                  x86_64 container for the Mu UEFI build only
scripts/
  bg.sh                  run a job in tmux (logs/NAME.log, logs/NAME.exit)
  lib/                   env.sh (paths), native-env.sh (native tools in PATH), conf.py (config)
  setup/                 native-tools, build-op10tool, colima-up, docker-image, in-docker
  backup/                fetch-stock-ota, dump-partitions
  uefi/                  setup-mu, prepare (patch-dxe + binaries.py), build, patch-locate.py
  ios16/                 fetch-kernel, fetch-d22ap-adt, fetch-dmgs, build, root(-macos|-linux|-finish), root-simg
  flash/                 all.sh (whole chain), restore.sh (back to stock), ios16.sh (single steps)
tools/op10tool/          Rust CLI: img2simg, ipsw-get, uefi-unpack, uefi-portpatch, im4p
                         (tests/: Python reference versions + compare-python.sh)
external/                submodules + reference clones (see below)
```

## External repos

Six repos are **submodules** (the build reads them). The other thirteen are **reference** repos that
we read and port from: they are not submodules, they are git-ignored, and
`scripts/setup/get-references.sh` (`make references`) clones them at a pinned commit on demand.
Details: [docs/external-repos.md](docs/external-repos.md).

| Path | Upstream | Kind | Role |
|---|---|---|---|
| `external/slop` | akshaynexus/slop | submodule | negroni source: 128 xnu-8796 patches, shim BOARD=negroni, UEFI tools, A730 bring-up, kernel CI |
| `external/Mu-Silicium-negroni` | akshaynexus/Mu-Silicum-negroni | submodule | Mu-Silicium UEFI with negroniPkg |
| `external/UniXNU` (`iosplus10`) | akshaynexus/UniXNU | submodule | Core: boot manager, DarwinBoot, NativeAdreno, NativeMetal, AirNir |
| `external/ios-flame` | NWylynko/ios-flame | submodule | iOS 16 on Pixel 4 (SM8150) |
| `external/hackios-xnu-userland` | oosexgang/hackios-xnu-userland | submodule | HackiOS (POCO X5 Pro, SM7325) userland, Mesa GPU path |
| `external/metal2vulkan` | steelbrain/metal2vulkan | submodule | Metal shading language / API translation to Vulkan |
| `external/ios-sweet` | akshaynexus/ios-sweet | reference (scripts/setup/get-references.sh) | Original sweet port: shim, mkadt, root tools |
| `external/ios-sweet-upstream` | dipa-studio/ios-sweet | reference (scripts/setup/get-references.sh) | Upstream of all the sweet-based ports (same commit as our fork today) |
| `external/UniXNU-negroni` (`dev`) | pawlickerr/UniXNU-negroni | reference (scripts/setup/get-references.sh) | Board file, payload and boot image scripts |
| `external/UniXNU-ios26` (`ios26`) | none24smu/UniXNU | reference (scripts/setup/get-references.sh) | xnu-12377.121.6 (iOS 26) kernel work |
| `external/UniXNU-zeta` | none24smu/UniXNU-zeta | reference (scripts/setup/get-references.sh) | iOS 26 on Surface Duo 2 (no PAC) |
| `external/UniXNU-pong` | Chengdong-Yu/UniXNU-pong | reference (scripts/setup/get-references.sh) | iOS 16 on Nothing Phone 2 (SM8475, Adreno 730) |
| `external/ios-sailfish` | joranv1/ios-sailfish | reference (scripts/setup/get-references.sh) | iOS 16 on Pixel 1 with working GPU (Mesa freedreno + EAGL shim): GPU reference |
| `external/bergamota` (`develop`) | ry-diffusion/bergamota | reference (scripts/setup/get-references.sh) | iOS 18.7.8 on POCO F1, **iOS 18 kernel**: reference for the newer-kernel path |
| `external/ios-apollo` | aTechGeekDev/ios-apollo | reference (scripts/setup/get-references.sh) | iOS 16 on Mi 10T 5G (SM8250): memory-address port of ios-sweet |
| `external/hackios-xnu-kernel` | oosexgang/hackios-xnu-kernel | reference (scripts/setup/get-references.sh) | HackiOS (POCO X5 Pro, SM7325) kernel |
| `external/ios-s9` | syncmodz/ios-s9 | reference (scripts/setup/get-references.sh) | iOS 16 on Samsung Galaxy S9 (SM-G9600): shim, XNU patches, drivers |
| `external/Chlorophyll` | ry-diffusion/Chlorophyll | reference (scripts/setup/get-references.sh) | Bergamota's Metal driver (AIR -> NIR -> ir3 over freedreno, Adreno 630), MIT |
| `external/ios-spes` | AdyaGMD/ios-spes | reference (scripts/setup/get-references.sh) | iOS on Redmi Note 11 (SM6225) |

```sh
git clone --recurse-submodules git@github.com:akshaynexus/iOSPlus10.git
# or, after a plain clone:
git submodule update --init
# reference repos, only when you need them (no args = all missing; -l = list and state):
scripts/setup/get-references.sh [-l | NAME...]
```

Mu-Silicium has its own submodules; initialize them only when you build the UEFI
(`git -C external/Mu-Silicium-negroni submodule update --init --recursive`).

## Rules

- Keep device dumps, serial numbers, firmware images and Apple artifacts out of git
  (`.gitignore` blocks the usual file types). The stock backup stays in `~/op10-backup/`.
- Test with `fastboot boot` first. Confirm each partition write with the owner before it runs.
- Write only `boot_a`, `vendor_boot_a`, `vbmeta_a`, `dtbo_a` and `userdata`. Keep slot B, the GPT
  and the unique partitions (modemst, fsg, persist, oplusreserve) unchanged.

## Credits

This project builds directly upon groundbreaking work across the open-source XNU and Android porting communities:
- [UniXNU-negroni](https://github.com/pawlickerr/UniXNU-negroni) & [Mu-Silicium-negroni](https://github.com/pawlickerr/Mu-Silicum-negroni) (pawlickerr, Project Silicium): Starting point, board definitions, and UEFI firmware tree for negroni.
- [slop](https://github.com/MellysInformejtik/slop) (MellysInformejtik / akshaynexus): Negroni XNU kernel patches, device shim, and root tools.
- [ios-sweet](https://github.com/dipa-studio/ios-sweet) (dipa-studio): Foundational XNU-on-Qualcomm port and root tools.
- [UniXNU](https://github.com/UniXNU/UniXNU) & [DarwinBoot](https://github.com/UniXNU/DarwinBoot): Unified UEFI boot manager and XNU loader on ARM64.
- [hackios-xnu-userland](https://github.com/oosexgang/hackios-xnu-userland) & [hackios-xnu-kernel](https://github.com/oosexgang/hackios-xnu-kernel) (OOSEX GANG): HackiOS userland integration and Mesa/EAGL userspace.
- [ios-flame](https://github.com/NWylynko/ios-flame) (NWylynko): Pixel 4 (SM8150) port and userland tools.
- [metal2vulkan](https://github.com/steelbrain/metal2vulkan) (steelbrain): Metal shading language / API translation to Vulkan.
- [ios-sailfish](https://github.com/joranv1/ios-sailfish) (joranv1): Working GPU acceleration on iOS (Mesa freedreno + EAGL shim) and fast boot optimizations.
- [bergamota](https://github.com/ry-diffusion/bergamota) & [Chlorophyll](https://github.com/ry-diffusion/Chlorophyll) (ry-diffusion): Bergamota iOS 18 kernel port and Chlorophyll Metal driver.
- [UniXNU-pong](https://github.com/Chengdong-Yu/UniXNU-pong) (Chengdong Yu): Nothing Phone 2 (SM8475, Adreno 730) reference port.
- [Mesa](https://mesa3d.org/) / freedreno: Open-source Gallium Adreno driver and Turnip Vulkan driver.
- [Apple Inc.](https://opensource.apple.com/): Open-source releases of the XNU kernel and Darwin libraries (APSL 2.0).

See [CREDITS.md](CREDITS.md) for full attributions and upstream details.

## License

- Project files in `docs/`, `scripts/`, `userland/negronigl/`, and `tools/` (including `op10tool`) are licensed under the [MIT License](LICENSE).
- Submodules and third-party components retain their upstream licenses (BSD-2-Clause-Patent, Project Mu BSD-2-Clause, MIT, LGPL-3.0/GPL-2.0, APSL-2.0, etc.).
- Verbatim license texts and third-party copyright notices are collected in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
