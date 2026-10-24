# Build the iOS 16 boot chain (NE2211)

Host setup first: [setup-macos.md](setup-macos.md) or [setup-linux.md](setup-linux.md).
Each `make` target runs a script; long ones start a detached tmux job (`scripts/bg.sh`).
Check jobs with `make status`; logs are in `logs/NAME.log`.

## Flow

```
make tools  make op10tool  make image                        one-time setup
     |
make mu  ──────────────► out/mu/SILICIUM_UEFI-DEBUG.fd       Mu UEFI (container; or mu-build-macos)
make kernel ───────────► out/kernel/kernel.macho             xnu-8796 from the slop CI
make devicetree ───────► ~/op10-apple/d22ap.adt              Apple /product data
     |
make boot ─────────────► out/ios16/boot_a.img, vendor_boot_a.img, esp.img, negroni.adt
     |
make dmgs ─────────────► ~/op10-apple/20H392/*.dmg           3 DMGs from the IPSW
make root  (sudo) ─────► ~/op10-apple/ios16-root.img         HFS+ root
make simg ─────────────► ~/op10-apple/ios16-root.simg        for fastboot
```

## Steps and scripts

| `make` | Script | macOS | Linux |
|---|---|---|---|
| `tools` | `scripts/setup/native-tools.sh` | Homebrew aarch64-elf-gcc, gawk, rsync, llvm, lld, acpica, nasm; AOSP mkbootimg; uv venv (pyfatfs, pyyaml, Mu requirements) | apt cross GCC, gawk, rsync; same |
| `op10tool` | `scripts/setup/build-op10tool.sh` | `cargo build` -> `out/bin/op10tool` | same |
| `colima` | `scripts/setup/colima-up.sh` | Colima VM | not needed |
| `image` | `scripts/setup/docker-image.sh` | **arm64** build image (native, no Rosetta) | build image for the host CPU |
| `mu` | `scripts/uefi/setup-mu.sh`, `prepare.sh`, `fetch-extdeps.sh`, `build.sh` | setup + prepare native, build in container | same |
| `mu-build-macos` | `scripts/uefi/build-macos.sh` | **experimental**: whole Mu build native (Homebrew LLVM, BaseTools from source) | use `mu` |
| `kernel` | `scripts/ios16/fetch-kernel.sh` | `gh run download` | same |
| `devicetree` | `scripts/ios16/fetch-d22ap-adt.sh` | `op10tool ipsw-get` + `op10tool im4p` | same |
| `boot` | `scripts/ios16/build.sh` | native (`scripts/lib/native-env.sh`) | native |
| `dmgs` | `scripts/ios16/fetch-dmgs.sh` | `op10tool ipsw-get` (32 threads) | same |
| `root` | `scripts/ios16/root.sh` | `root-macos.sh`: native APFS + HFS+ (`hdiutil`, `newfs_hfs`) | `root-linux.sh`: apfs-fuse + hfsplus loop mount |
| `simg` | `scripts/ios16/root-simg.sh` | `op10tool img2simg` | same |

Both root scripts end with `scripts/ios16/root-finish.sh` (bring-up tweaks, staged apps).

## The Mu UEFI build: container, arm64 container, or native

Mu-Silicium (EDK2 `stuart`) is supported upstream only on Linux/Windows hosts. What it needs:

| Need | Where it comes from |
|---|---|
| Compiler (CLANGPDB, AARCH64) | only `clang`, `lld-link`, `llvm-lib`: Ubuntu LLVM in the container, Homebrew `llvm` + `lld` natively |
| BaseTools (`GenFw`, `GenFv`, ...) | prebuilt `Mu-Basetools` (GitHub release): Linux-x86, **Linux-ARM-64**, Windows; no macOS build, so `build-macos.sh` compiles them from `BaseTools/Source/C` |
| `onecrypto-bin` | GitHub ZIP of ARM target binaries (any host) |
| `mu_nasm` (NuGet) | `scripts/uefi/fetch-extdeps.sh` downloads the .nupkg with curl (no NuGet.exe, no Mono); not used for AARCH64 code |

- Default: the container for the **host CPU** (`scripts/lib/env.sh` sets `PLATFORM`): native arm64
  on Apple silicon, so no Rosetta. `PLATFORM=linux/amd64` still works (Rosetta on macOS; then
  `in-docker.sh` sets `MONO_ENV_OPTIONS=--interpreter`, because x86_64 Mono crashes under Rosetta).
- `make mu-build-macos`: experimental native macOS build (no Docker). It shares the Mu tree and
  `Build/` with the container build: run only one at a time.

Everything else runs natively on macOS and Linux.

## Tools: Rust vs Python vs shell

- `tools/op10tool` (Rust, one binary): `img2simg`, `simg2img`, `ipsw-get`, `uefi-unpack`,
  `uefi-portpatch`, `im4p`. Binary formats, large files, parallel downloads. Libraries where they
  fit: `zip` (IPSW directory, through an HTTP range reader), `rayon` (parallel chunks), `ureq`,
  `flate2`, `crc32fast`, `android-sparse` (sparse format; our own block classification, because the
  crate's encoder would turn zero data into don't-care), `simple_asn1` (IM4P), `lzfse_rust`,
  `lzma-rs`, `clap`. Hand-written only where no library fits: the Qualcomm FV walker and the
  aarch64 patch-port masks. `tools/op10tool/tests/compare-python.sh` checks every command against
  the earlier Python versions (same output; sparse images by decoded content).
- Python (short glue): `scripts/lib/conf.py`, `scripts/uefi/binaries.py`,
  `scripts/uefi/patch-locate.py`, and the port's own tools in `external/slop`.
- Shell: orchestration in `scripts/`.

## Parallelism

| Step | How it uses the cores |
|---|---|
| Mu UEFI (EDK2 `build`) | auto-detects the CPU count (no `-n` set); in the container that is Colima's CPU count, so `colima-up.sh` gives Colima all host cores |
| BaseTools (native) | `make -j$(sysctl -n hw.ncpu)` |
| Submodules | `git submodule update --jobs $NPROC` |
| op10tool | cargo builds in parallel; `ipsw-get` 32 parallel ranges; `img2simg` classifies 16 MiB batches of blocks with rayon |
| Root image | the OS, SystemOS and AppOS trees are copied by three rsync processes at the same time |
| Independent steps | separate tmux jobs (`make mu`, `make kernel`, `make dmgs` can all run at once) |

## Outputs

- `out/ios16/`: `negroni.adt`, `esp.img`, `cmdline.txt`, `boot_a.img`, `vendor_boot_a.img`, `SHA256SUMS`
- `~/op10-apple/`: Apple files and the root image (never in git)

## Known traps (from the port's notes)

- The OnePlus ABL's sparse `fastboot flash userdata` did not land writes beyond about 8 GiB into
  the partition on the NE2213. Check the end of the root after flashing, or flash userdata from
  fastbootd / recovery instead.
- A `fastboot flash userdata` overwrites the GPU firmware area and the log area at the end of
  userdata (only relevant for the GPU tests later).
- Low battery: fastboot writes once left `vbmeta_a` flags at 0. Charge before flashing; check
  the flags after.
- Use `fastboot set_active a` before reboot: failed boots use slot A's retries, then ABL falls
  back to slot B.
