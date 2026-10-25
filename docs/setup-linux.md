# Setup on Linux (x86_64)

Tested target: Ubuntu 24.04 or newer. Other distributions work if they have the packages below.

## 1. Host packages

```sh
sudo apt install -y git tmux make docker.io android-sdk-platform-tools python3 python3-venv \
  apfs-fuse hfsprogs rsync curl
sudo usermod -aG docker "$USER"          # log out and in again
curl https://sh.rustup.rs -sSf | sh      # if cargo is missing
```

- `adb` / `fastboot`: use platform-tools 37.0.1 or newer from Google if the distribution package is
  older.
- USB access without root needs udev rules (package `android-sdk-platform-tools-common`, or the
  `51-android.rules` from https://github.com/M0Rf30/android-udev-rules).
- `payload-dumper-go`: download the linux_amd64 release from
  https://github.com/ssut/payload-dumper-go/releases.
- The iOS root build needs the `hfsplus` kernel module (`sudo modprobe hfsplus`).

## 2. Repo and tools

```sh
git clone --recurse-submodules git@github.com:akshaynexus/iOSPlus10.git
cd iOSPlus10
make references     # optional: reference-only repos (scripts/setup/get-references.sh, not submodules)
make tools          # apt cross GCC, gawk, rsync; AOSP mkbootimg; pyfatfs venv
make op10tool       # Rust CLI -> out/bin/op10tool
make image          # x86_64 build container for Mu (native on x86_64)
make status
```

On an arm64 Linux host, install `qemu-user-static` + `binfmt-support` so that the x86_64 container
can run.

## 3. Stock backup (once, before any flash)

Same commands as in [setup-macos.md](setup-macos.md), step 3.

## 4. Build

Follow [build-ios16.md](build-ios16.md). `make root` runs `scripts/ios16/root-linux.sh`
(apfs-fuse + hfsplus loop mount, the port's `mkiosroot.sh`).
