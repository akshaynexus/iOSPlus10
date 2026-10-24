# Setup on macOS (Apple silicon)

Tested on macOS 27, MacBook Air M4, 16 GB.

## 1. Host packages

```sh
brew install android-platform-tools tmux colima docker aria2 payload-dumper-go rsync
curl https://sh.rustup.rs -sSf | sh          # if cargo is missing
```

- `adb` / `fastboot` 37.0.1 or newer. No USB driver is needed on macOS.
- If macOS asks "Allow accessory to connect?", click **Allow** (also in fastboot mode, which is a
  new USB device).
- Use a USB cable that works in fastboot mode. A cable that works for adb can still fail in fastboot.

## 2. Repo and tools

```sh
git clone --recurse-submodules git@github.com:akshaynexus/iOSPlus10.git
cd iOSPlus10
make tools          # aarch64-elf-gcc, gawk, rsync, AOSP mkbootimg, pyfatfs venv
make op10tool       # Rust CLI -> out/bin/op10tool
make colima         # Colima VM with Rosetta, for the x86_64 Mu build container
make image          # build container image
make status         # wait until the jobs show "finished, exit 0"
```

`scripts/lib/env.sh` points Docker at `~/.docker-colima` (an empty config), because the normal
`~/.docker/config.json` may name Docker Desktop's credential helper.

## 3. Stock backup (once, before any flash)

```sh
make backup-ota     # official full OTA into ~/op10-backup, MD5 check
payload-dumper-go -o ~/op10-backup/images -p boot,vendor_boot,dtbo,vbmeta,uefi \
  ~/op10-backup/NE2211_16.0.3.530_EX01_full.zip
make backup-dump    # all small partitions + GPT; needs adb root (Magisk)
```

## 4. Build

Follow [build-ios16.md](build-ios16.md): `make mu kernel devicetree`, then `make boot`,
`make dmgs`, `make root` (sudo: `tmux attach -t root`, type the password, Ctrl-b d), `make simg`.

## Disk space

About 15 GB for the OTA backup, the Mu tree and the container image, plus about 25 GB for the iOS
DMGs and the root image.
