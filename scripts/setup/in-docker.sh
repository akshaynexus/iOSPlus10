#!/bin/sh
# Run a command inside the build container with the repo mounted at the same path.
#   scripts/setup/in-docker.sh <command...>
# The backup folder is mounted read-only at the same path, so scripts can read stock images.
set -eu
. "$(dirname "$0")/../lib/env.sh"
mkdir -p "$OUT"
tty=""; [ -t 0 ] && tty="-it"
# Only for PLATFORM=linux/amd64 on a Mac: x86_64 Mono crashes under Rosetta ("should not be reached
# at tramp-amd64.c:606"); its interpreter mode works. (NuGet itself is no longer needed:
# scripts/uefi/fetch-extdeps.sh installs the NuGet-type deps with curl.)
mono=""; [ "$(uname -s)" = Darwin ] && [ "$PLATFORM" = linux/amd64 ] && mono="--interpreter"
exec docker run --rm $tty --platform "$PLATFORM" \
  -v "$REPO:$REPO" -v "$BACKUP:$BACKUP:ro" -w "$REPO" \
  -e HOME=/tmp -e BACKUP="$BACKUP" -e MONO_ENV_OPTIONS="$mono" "$DOCKER_IMAGE" "$@"
