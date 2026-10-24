#!/bin/sh
# macOS only: start the Colima VM that runs the x86_64 build container through Rosetta.
set -eu
. "$(dirname "$0")/../lib/env.sh"
CPU=${CPU:-6} MEM=${MEM:-8}
if colima status >/dev/null 2>&1; then echo "colima already running"; else
  colima start --cpu "$CPU" --memory "$MEM" --vm-type vz --vz-rosetta --mount-type virtiofs
fi
docker run --rm --platform linux/amd64 ubuntu:24.04 uname -m
