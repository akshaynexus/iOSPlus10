# iOSPlus10

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
external/                submodules (see below)
```

## Submodules

| Path | Upstream | Role |
|---|---|---|
| `external/ios-sweet` | akshaynexus/ios-sweet | Original sweet port: shim, mkadt, root tools |
| `external/slop` | MellysInformejtik/slop | negroni source: 128 xnu-8796 patches, shim BOARD=negroni, UEFI tools, A730 bring-up, kernel CI |
| `external/UniXNU-negroni` (`dev`) | pawlickerr/UniXNU-negroni | Board file, payload and boot image scripts |
| `external/Mu-Silicium-negroni` | pawlickerr/Mu-Silicum-negroni | Mu-Silicium UEFI with negroniPkg |
| `external/UniXNU` | UniXNU/UniXNU | Core: boot manager, DarwinBoot, NativeAdreno, NativeMetal, AirNir |
| `external/UniXNU-ios26` (`ios26`) | none24smu/UniXNU | xnu-12377.121.6 (iOS 26) kernel work |
| `external/UniXNU-zeta` | none24smu/UniXNU-zeta | iOS 26 on Surface Duo 2 (no PAC): reference |
| `external/UniXNU-pong` | Chengdong-Yu/UniXNU-pong | iOS 16 on Nothing Phone 2 (SM8475, Adreno 730): reference |
| `external/ios-sailfish` | joranv1/ios-sailfish | iOS 16 on Pixel 1 with working GPU (Mesa freedreno + EAGL shim): GPU reference |
| `external/ios-sweet-upstream` | dipa-studio/ios-sweet | Upstream of all the sweet-based ports (same commit as our fork today) |
| `external/bergamota` (`develop`) | ry-diffusion/bergamota | iOS 18.7.8 on POCO F1, **iOS 18 kernel**: reference for the newer-kernel path |
| `external/ios-apollo` | aTechGeekDev/ios-apollo | iOS 16 on Mi 10T 5G (SM8250): memory-address port of ios-sweet |
| `external/ios-flame` | NWylynko/ios-flame | iOS 16 on Pixel 4 (SM8150) |
| `external/hackios-xnu-kernel`, `external/hackios-xnu-userland` | oosexgang | HackiOS (POCO X5 Pro, SM7325): kernel and userland, Mesa GPU path |

```sh
git clone --recurse-submodules git@github.com:akshaynexus/iOSPlus10.git
# or, after a plain clone:
git submodule update --init
```

Mu-Silicium has its own submodules; initialize them only when you build the UEFI
(`git -C external/Mu-Silicium-negroni submodule update --init --recursive`).

## Rules

- Keep device dumps, serial numbers, firmware images and Apple artifacts out of git
  (`.gitignore` blocks the usual file types). The stock backup stays in `~/op10-backup/`.
- Test with `fastboot boot` first. Confirm each partition write with the owner before it runs.
- Write only `boot_a`, `vendor_boot_a`, `vbmeta_a`, `dtbo_a` and `userdata`. Keep slot B, the GPT
  and the unique partitions (modemst, fsg, persist, oplusreserve) unchanged.

## License

The files in `docs/`, `scripts/` and `tools/` are MIT. Each submodule keeps its own license; `slop` and
`UniXNU-negroni` have no license file.
