#!/bin/sh
# Build the Mu build image (docker/Dockerfile) for $PLATFORM (default: the host CPU, see lib/env.sh).
# macOS: Colima (scripts/setup/colima-up.sh). Linux: plain Docker.
set -eu
. "$(dirname "$0")/../lib/env.sh"
docker build --platform "$PLATFORM" -t "$DOCKER_IMAGE" "$REPO/docker"
docker run --rm --platform "$PLATFORM" "$DOCKER_IMAGE" sh -c \
  'uname -m; aarch64-linux-gnu-objcopy --version | head -1; clang --version | head -1; mkbootimg --help >/dev/null && echo mkbootimg ok'
