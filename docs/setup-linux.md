# Setup on Linux (x86_64)

Tested target: Ubuntu 24.04 or newer. Other distributions work if they have Docker.

## 1. Host tools

```sh
sudo apt install -y git tmux aria2 docker.io android-sdk-platform-tools python3
sudo usermod -aG docker "$USER"          # log out and in again
```

- `adb` / `fastboot`: use platform-tools 37.0.1 or newer from Google if the distribution package is
  older.
- USB access without root needs udev rules (package `android-sdk-platform-tools-common`, or the
  `51-android.rules` from https://github.com/M0Rf30/android-udev-rules).
- `payload-dumper-go`: download the linux_amd64 release from
  https://github.com/ssut/payload-dumper-go/releases.

## 2. Repo

```sh
git clone --recurse-submodules git@github.com:akshaynexus/iOSPlus10.git
cd iOSPlus10
scripts/bg.sh setup-mu scripts/setup-mu.sh
```

## 3. Build container

The container is the same as on macOS, but runs natively:

```sh
scripts/bg.sh docker-image scripts/docker-image.sh
scripts/bg.sh -s docker-image
```

On an arm64 Linux host, install `qemu-user-static` + `binfmt-support` so that the x86_64 container
can run.

## 4. Stock backup

Same commands as in `docs/setup-macos.md`, step 4. `md5` is replaced by `md5sum` automatically.
