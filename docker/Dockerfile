# Build environment for the negroni boot chain: ios-sweet shim, Mu-Silicium UEFI, payload, boot images.
# x86_64 like the Mu-Silicium CI (its NuGet tools are x86_64); on Apple silicon run it through Rosetta:
#   colima start --vm-type vz --vz-rosetta
#   docker build --platform linux/amd64 -t iosplus10-build docker/
#   scripts/in-docker.sh <command>
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git mono-devel build-essential lld uuid-dev nasm gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
      python3 python3-pip python3-venv python3-git gettext locales gnupg ca-certificates curl clang llvm \
      android-sdk-libsparse-utils device-tree-compiler cpio acpica-tools xxd file lzfse \
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
