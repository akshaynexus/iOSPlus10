#!/bin/sh
# macOS only: start the Colima VM for the Mu build container. The container is native arm64 on
# Apple silicon; Rosetta is enabled too, only for PLATFORM=linux/amd64 runs.
set -eu
. "$(dirname "$0")/../lib/env.sh"
CPU=${CPU:-6} MEM=${MEM:-8}
if colima status >/dev/null 2>&1; then echo "colima already running"; else
  colima start --cpu "$CPU" --memory "$MEM" --vm-type vz --vz-rosetta --mount-type virtiofs
fi
docker run --rm --platform "$PLATFORM" ubuntu:24.04 uname -m
