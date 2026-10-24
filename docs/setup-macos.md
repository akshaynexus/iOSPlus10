# Setup on macOS (Apple silicon)

Tested on macOS 27, MacBook Air M4, 16 GB.

## 1. Host tools

```sh
brew install android-platform-tools tmux colima docker aria2 payload-dumper-go
```

- `adb` / `fastboot` 37.0.1 or newer. No USB driver is needed on macOS.
- If macOS asks "Allow accessory to connect?", click **Allow** (also in fastboot mode, which is a
  new USB device).
- Use a USB cable that works in fastboot mode. A cable that works for adb can still fail in fastboot.

## 2. Repo

```sh
git clone --recurse-submodules git@github.com:akshaynexus/iOSPlus10.git
cd iOSPlus10
scripts/bg.sh setup-mu scripts/setup-mu.sh      # Mu-Silicium submodules + negroni patches
```

## 3. Build container (x86_64 through Rosetta)

The Mu-Silicium build downloads x86_64 tools, like its upstream CI. Colima runs the x86_64
container through Rosetta:

```sh
scripts/colima-up.sh                            # colima start --vm-type vz --vz-rosetta
scripts/bg.sh docker-image scripts/docker-image.sh
scripts/bg.sh -s docker-image                   # status
```

`scripts/env.sh` points Docker at `~/.docker-colima` (an empty config), because the normal
`~/.docker/config.json` may name Docker Desktop's credential helper.

## 4. Stock backup

```sh
scripts/bg.sh ota scripts/fetch-stock-ota.sh    # official full OTA into ~/op10-backup, MD5 check
payload-dumper-go -o ~/op10-backup/images -p boot,vendor_boot,dtbo,vbmeta,uefi \
  ~/op10-backup/NE2211_16.0.3.530_EX01_full.zip
scripts/bg.sh dump scripts/dump-partitions.sh   # needs adb root (Magisk)
```

## Disk space

The Mac needs about 15 GB free for the OTA backup, the Mu tree and the container image, and
about 25 GB more for the iOS root image (IPSW + HFS+ image).
