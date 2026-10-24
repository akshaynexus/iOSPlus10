#!/bin/sh
# Build the x86_64 build image (docker/Dockerfile).
# macOS: needs Colima with Rosetta (scripts/setup/colima-up.sh). Linux x86_64: plain Docker.
set -eu
. "$(dirname "$0")/../lib/env.sh"
docker build --platform linux/amd64 -t "$IMAGE" "$REPO/docker"
docker run --rm --platform linux/amd64 "$IMAGE" sh -c 'aarch64-linux-gnu-gcc --version | head -1; mkbootimg --help >/dev/null && echo mkbootimg ok'
