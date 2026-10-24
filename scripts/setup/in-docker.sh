#!/bin/sh
# Run a command inside the build container with the repo mounted at the same path.
#   scripts/setup/in-docker.sh <command...>
# The backup folder is mounted read-only at the same path, so scripts can read stock images.
set -eu
. "$(dirname "$0")/../lib/env.sh"
mkdir -p "$OUT"
tty=""; [ -t 0 ] && tty="-it"
# x86_64 Mono crashes under Rosetta ("should not be reached at tramp-amd64.c:606") when stuart runs
# NuGet.exe; Mono's interpreter mode works. Native x86_64 Linux keeps the JIT.
mono=""; [ "$(uname -s)" = Darwin ] && mono="--interpreter"
exec docker run --rm $tty --platform linux/amd64 \
  -v "$REPO:$REPO" -v "$BACKUP:$BACKUP:ro" -w "$REPO" \
  -e HOME=/tmp -e BACKUP="$BACKUP" -e MONO_ENV_OPTIONS="$mono" "$IMAGE" "$@"
