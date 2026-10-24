#!/bin/sh
# Run a command inside the build container with the repo mounted at the same path.
#   scripts/setup/in-docker.sh <command...>
# The backup folder is mounted read-only at the same path, so scripts can read stock images.
set -eu
. "$(dirname "$0")/../lib/env.sh"
mkdir -p "$OUT"
tty=""; [ -t 0 ] && tty="-it"
exec docker run --rm $tty --platform linux/amd64 \
  -v "$REPO:$REPO" -v "$BACKUP:$BACKUP:ro" -w "$REPO" \
  -e HOME=/tmp -e BACKUP="$BACKUP" "$IMAGE" "$@"
