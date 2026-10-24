# iOSPlus10

iOS on the OnePlus 10 Pro 5G (NE2211, "negroni", Snapdragon 8 Gen 1 / SM8450), booted natively
through UEFI. Goal: iOS 26 with GPU (Metal) acceleration. First milestone: the existing iOS 16
port on this phone.

The Cortex-X2/A710/A510 cores have ARMv8.3 PAC (`paca pacg`), so the arm64e iOS 26 userland can
run without the shared-cache rewrite that phones without PAC need.

## Layout

```
docs/
  research-report.md     stack map, iOS 16 and iOS 26 tracks, GPU path, blockers
  backup-and-restore.md  device state, stock backup, restore commands
  plan.md                phases and status
scripts/
  fetch-stock-ota.sh     download and check the official full OTA
  uefi-fv-extract.py     extract the Qualcomm DXEs from a stock uefi.img
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

The files in `docs/` and `scripts/` are MIT. Each submodule keeps its own license; `slop` and
`UniXNU-negroni` have no license file.
