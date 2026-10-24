# Qualcomm UEFI binaries for Mu-Silicium negroni

Mu-Silicium uses Qualcomm's own DXE drivers for UFS, clocks, RPMh, SPMI, TLMM, I2C and more. They
are proprietary, so they are not in any repo. We take them from the stock `uefi.img` in the
official OTA and port the Galaxy S22 (r0q) patches onto them.

```sh
scripts/uefi/setup-mu.sh        # once: Mu submodules + negroni patches
scripts/uefi/prepare.sh      # unpack, patch, build Binaries/negroni, check references
```

Inputs: `~/op10-backup/images/uefi.img` (`BOOT.MXF.2.0-00925.2-WAIPIO-1.81484.5`) and
`external/Mu-Silicium-negroni/Binaries/r0q` (Device-Binaries, `BOOT.MXF.2.0-00805-WAIPIO-1`,
has both `X.efi` and `X.patched.efi` for each patched driver).
Outputs (git-ignored): `out/uefi/modules`, `out/uefi/patched`, `out/uefi/Binaries-negroni`, then
copied to `external/Mu-Silicium-negroni/Binaries/negroni`.

## Tools

| Script | Job |
|---|---|
| `scripts/uefi/unpack.py` | Pure-Python FV/FFS unpacker (gzip + LZMA GUID sections). One folder per FILE_GUID with `pe32.efi`, `depex.bin`, `raw.bin`, `name.txt`; `index.tsv`. Replaces UEFIExtract. |
| `scripts/uefi/portpatch.py` | Ports byte patches by masked aarch64 context (from slop `portpatch2.py`). New: patched branches are re-aimed by code match of the r0q destination; `--skip` for a known-missing run; `--byte OFF=OLD:NEW` for a checked data patch. |
| `scripts/uefi/patch-dxe.sh` | Runs the port for the 7 patched drivers. |
| `scripts/uefi/binaries.py` | Mirrors the r0q INFs by FILE_GUID into `Binaries/negroni`, fills sections from our modules, uses `out/uefi/patched/X.efi` where an INF names `X.patched.efi`, copies raw files (panel XMLs, configs) to `RawFiles/`. |
| `scripts/uefi/patch-locate.py` | Diagnostic: shows a code window of our driver next to its best match in a reference build. |

## Result (2026-10-24)

93 code modules unpacked; 88 drivers mirrored; 12 Samsung-only r0q drivers skipped; all 81
`Binaries/negroni` paths that negroniPkg references exist.

| Driver | r0q patch | NE2211 site | Written words | Notes |
|---|---|---|---|---|
| ClockDxe | 0xbec8+8 | 0xedd0 | `52800000 17ffffdc` (mov w0,#0; b 0xed44) | keeps MDSS (display) on; branch target found by code match |
| PmicDxe | 0x3fa8, 0x3fbc | 0x3e70, 0x3e84 | `d503201f` (nop) x2 | minimal PMIC init removed |
| PmicDxe | 0x131c8+8 | — | — | power-button check: no counterpart in the OnePlus build (same as the port). If UEFI shuts down by itself, look here. |
| SPMI | 0x2e50+8 | 0x2e80 | `52800000 d65f03c0` (mov w0,#0; ret) | SPMI handle function removed |
| TzDxeLA | data byte | 0xf55c | 00 -> 01 | global TZ applet flag; data, so applied as a checked byte |
| UFSDxe | 0xab08+8 | 0xcad0 | `52800021 94000550` (mov w1,#1; bl 0xe014) | sleep call -> wakeup call; 0xe014 found by code match (the port found it by hand) |
| UsbConfigDxe | 0x5180+4 | 0x51d8 | `1400000e` (b 0x5210) | USB deinit at ExitBootServices skipped |
| UsbMsdDxe | 0x4034+4 | 0x40d0 | `52800008` (mov w8,#0) | mass storage: non-removable |

All sites agree with `external/slop/uefi/negroni/README.md`, which the port author made on an
NE2213 with the same firmware build.
