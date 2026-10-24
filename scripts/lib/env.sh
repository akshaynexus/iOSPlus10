# Shared settings, sourced by the other scripts.
# repo root: git toplevel of the calling script (works at any folder depth)
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/../.." && pwd))
EXT=$REPO/external
OUT=$REPO/out                                   # build products (git-ignored)
BACKUP=${BACKUP:-$HOME/op10-backup}             # stock backup, never in git
# Build container platform: the host's own CPU (no emulation). Mu's prebuilt BaseTools and mu_nasm
# have Linux-ARM-64 and Linux-x86-64 builds, so arm64 Macs run a native arm64 container.
# Override with PLATFORM=linux/amd64 (e.g. to compare with the upstream x86_64 CI).
case "$(uname -m)" in
arm64|aarch64) PLATFORM=${PLATFORM:-linux/arm64} ;;
*)             PLATFORM=${PLATFORM:-linux/amd64} ;;
esac
IMAGE=${IMAGE:-iosplus10-build:${PLATFORM#linux/}}
case "$(uname -s)" in
Darwin)
  # Colima: a Docker config without Docker Desktop's credential helper.
  export DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker-colima}
  if [ ! -f "$DOCKER_CONFIG/config.json" ]; then
    mkdir -p "$DOCKER_CONFIG"
    echo '{"currentContext":"colima"}' > "$DOCKER_CONFIG/config.json"
    [ -d "$HOME/.docker/contexts" ] && cp -R "$HOME/.docker/contexts" "$DOCKER_CONFIG/"
  fi ;;
esac
