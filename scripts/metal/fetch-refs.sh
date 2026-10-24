#!/bin/bash
# Fetch the reference sources for the Metal path into out/metal/ref (git-ignored).
# These are the UniXNU-ios26 submodules that hold the Metal work (pins from
# external/UniXNU-ios26 .gitmodules / submodule status at 68c5134). Reference only.
# Run in tmux: scripts/bg.sh metal-refs scripts/metal/fetch-refs.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DST=$REPO/out/metal/ref
mkdir -p "$DST"
pins=(
  "UniXNU/NativeMetal ff0c70d7249a04ee381d9854c214069324a34d5c"
  "UniXNU/AirNir 032a867b5dc3121164bbd706e4e81e3b9fcd2b8f"
  "UniXNU/NativeAdreno 805c7e4bfb7451eb6923f4a14dea8c657b9be7d2"
)
for spec in "${pins[@]}"; do
  set -- $spec
  d=$DST/$(basename "$1")
  [ -d "$d/.git" ] || git clone -q "https://github.com/$1.git" "$d"
  git -C "$d" fetch -q origin "$2" 2>/dev/null || true
  git -C "$d" checkout -q "$2" 2>/dev/null || echo "pin $2 not found in $1: using HEAD"
  echo "$1 $(git -C "$d" rev-parse --short HEAD)"
done
