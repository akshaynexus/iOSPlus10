# Build the iOS 16 boot chain (NE2211)

Host setup first: [setup-macos.md](setup-macos.md) or [setup-linux.md](setup-linux.md).
Each `make` target runs a script; long ones start a detached tmux job (`scripts/bg.sh`).
Check jobs with `make status`; logs are in `logs/NAME.log`.

## Flow

```
make tools  make op10tool  make image                        one-time setup
     |
make mu  ──────────────► out/mu/SILICIUM_UEFI-DEBUG.fd       Mu UEFI (container)
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
| `tools` | `scripts/setup/native-tools.sh` | Homebrew aarch64-elf-gcc, gawk, rsync; AOSP mkbootimg; uv venv + pyfatfs | apt cross GCC, gawk, rsync; same |
| `op10tool` | `scripts/setup/build-op10tool.sh` | `cargo build` -> `out/bin/op10tool` | same |
| `colima` | `scripts/setup/colima-up.sh` | Colima VM with Rosetta | not needed |
| `image` | `scripts/setup/docker-image.sh` | x86_64 build image (Rosetta) | x86_64 build image (native) |
| `mu` | `scripts/uefi/setup-mu.sh`, `prepare.sh`, `build.sh` | setup + prepare native, build in container | same |
| `kernel` | `scripts/ios16/fetch-kernel.sh` | `gh run download` | same |
| `devicetree` | `scripts/ios16/fetch-d22ap-adt.sh` | `op10tool ipsw-get` + `op10tool im4p` | same |
| `boot` | `scripts/ios16/build.sh` | native (`scripts/lib/native-env.sh`) | native |
| `dmgs` | `scripts/ios16/fetch-dmgs.sh` | `op10tool ipsw-get` (32 threads) | same |
| `root` | `scripts/ios16/root.sh` | `root-macos.sh`: native APFS + HFS+ (`hdiutil`, `newfs_hfs`) | `root-linux.sh`: apfs-fuse + hfsplus loop mount |
| `simg` | `scripts/ios16/root-simg.sh` | `op10tool img2simg` | same |

Both root scripts end with `scripts/ios16/root-finish.sh` (bring-up tweaks, staged apps).

## Why one step uses a container

On macOS the x86_64 container runs through Rosetta. x86_64 Mono (which stuart uses for
`NuGet.exe`) crashes under Rosetta in JIT mode, so `scripts/setup/in-docker.sh` sets
`MONO_ENV_OPTIONS=--interpreter` on macOS hosts.


The Mu-Silicium UEFI build (EDK2 `stuart`) is supported upstream only on Linux/Windows x86_64: it
downloads x86_64-only NuGet tools (iasl and others) and uses GNU `aarch64-linux-gnu-` binutils
with Clang. Everything else runs natively on macOS and Linux.

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
