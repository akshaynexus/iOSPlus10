# Build environment for the Mu-Silicium UEFI build (the only container step; see docs/build-ios16.md).
# Multi-arch: native arm64 on Apple silicon (Colima, no Rosetta) or amd64 on x86_64 Linux.
#   scripts/setup/docker-image.sh          (platform from scripts/lib/env.sh)
#   scripts/setup/in-docker.sh <command>
# No Mono/NuGet: scripts/uefi/fetch-extdeps.sh installs the NuGet-type deps (mu_nasm) with curl.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential lld uuid-dev nasm python3 python3-pip python3-venv python3-git gettext \
      locales gnupg ca-certificates curl clang llvm android-sdk-libsparse-utils device-tree-compiler \
      cpio acpica-tools xxd file lzfse \
    # aarch64-linux-gnu-* tools: native names on arm64, cross packages on amd64
    && if [ "$(dpkg --print-architecture)" != arm64 ]; then \
         apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu; fi \
    && rm -rf /var/lib/apt/lists/*
# Ubuntu's mkbootimg package lacks its gki module; use AOSP's mkbootimg (header v4 support).
RUN git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg /opt/mkbootimg \
    && ln -s /opt/mkbootimg/mkbootimg.py /usr/local/bin/mkbootimg \
    && ln -s /opt/mkbootimg/unpack_bootimg.py /usr/local/bin/unpack_bootimg
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv --system-site-packages /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt
ENV PATH=/opt/venv/bin:$PATH CLANGPDB_AARCH64_PREFIX=aarch64-linux-gnu- GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=*
WORKDIR /work
