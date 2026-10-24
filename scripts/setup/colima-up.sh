#!/bin/sh
# macOS only: start the Colima VM for the Mu build container. The container is native arm64 on
# Apple silicon; Rosetta is enabled too, only for PLATFORM=linux/amd64 runs.
set -eu
. "$(dirname "$0")/../lib/env.sh"
# all host cores (EDK2 build uses every CPU it sees); memory: half of the host, at least 8 GiB
CPU=${CPU:-$(sysctl -n hw.ncpu)}
MEM=${MEM:-$(( $(sysctl -n hw.memsize) / 2147483648 > 8 ? $(sysctl -n hw.memsize) / 2147483648 : 8 ))}
if colima status >/dev/null 2>&1; then
  have=$(colima list 2>/dev/null | awk '$1=="default"{print $4}')
  if [ "$have" != "$CPU" ]; then echo "colima has $have CPUs, want $CPU: restarting"; colima stop; colima start --cpu "$CPU" --memory "$MEM" --vm-type vz --vz-rosetta --mount-type virtiofs; else echo "colima already running ($have CPUs)"; fi
else
  colima start --cpu "$CPU" --memory "$MEM" --vm-type vz --vz-rosetta --mount-type virtiofs
fi
docker run --rm --platform "$PLATFORM" ubuntu:24.04 uname -m
