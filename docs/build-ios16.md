# Build the iOS 16 boot chain (NE2211)

Every step is a script. Run each long step in tmux: `scripts/bg.sh NAME COMMAND...`, then
`scripts/bg.sh -s NAME`. Host setup first: `docs/setup-macos.md` or `docs/setup-linux.md`.

## Native or container

Only the Mu-Silicium UEFI build uses the container. Upstream supports only Linux/Windows x86_64:
its `stuart` build downloads x86_64-only NuGet tools (iasl and others) and uses GNU
`aarch64-linux-gnu-` binutils with Clang. On macOS the container runs through Rosetta.

| Step | Script | Runs |
|---|---|---|
| Native tools (cross GCC, gawk, rsync, AOSP mkbootimg, pyfatfs venv) | `scripts/native-tools.sh` | native |
| Mu submodules + negroni patches | `scripts/setup-mu.sh` | native (git) |
| Qualcomm DXEs from the stock uefi.img, r0q patches, `Binaries/negroni` | `scripts/mu-prepare.sh` | native (Python) |
| Mu UEFI (`SILICIUM_UEFI-DEBUG.fd`) | `scripts/mu-build.sh` | **container** |
| Kernel from the slop CI | `scripts/fetch-kernel.sh` | native (gh) |
| Apple D22AP device tree | `scripts/fetch-d22ap-adt.sh` | native (Python, macOS libcompression or `lzfse`) |
| ADT, payload, `boot_a.img`, `vendor_boot_a.img` | `scripts/ios16-build.sh` | native (`scripts/native-env.sh`) |
| iOS DMGs (32 parallel range requests) | `scripts/fetch-ios16-dmgs.sh` | native (Python + curl) |
| iOS root image (HFS+) | `scripts/ios16-root-macos.sh` (sudo) | native macOS; Linux: the port's `build-ios16-root.sh` |
| Android sparse image | `scripts/ios16-root-simg.sh` | native (`scripts/img2simg.py`) |

`scripts/native-env.sh` puts `out/tools/bin` first in PATH. On macOS it links the names the
port's scripts call (`aarch64-linux-gnu-gcc/objcopy/readelf/nm`, `awk` with `strtonum`) to
Homebrew `aarch64-elf-*` and `gawk`.

## Order

```sh
scripts/bg.sh tools  scripts/native-tools.sh
scripts/bg.sh mu-all sh -c 'scripts/setup-mu.sh && scripts/mu-prepare.sh && scripts/mu-build.sh DEBUG'
scripts/bg.sh kernel scripts/fetch-kernel.sh
scripts/fetch-d22ap-adt.sh                       # 33 KB
scripts/bg.sh dmgs   scripts/fetch-ios16-dmgs.sh
scripts/bg.sh ios16  scripts/ios16-build.sh      # after mu-all and kernel
scripts/bg.sh root   sudo scripts/ios16-root-macos.sh   # tmux attach -t root for the password
scripts/bg.sh simg   scripts/ios16-root-simg.sh
```

Outputs: `out/ios16/{negroni.adt,esp.img,boot_a.img,vendor_boot_a.img,SHA256SUMS}`,
`~/op10-apple/ios16-root.{img,simg}`.

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
