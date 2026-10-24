# Shared settings, sourced by the other scripts.
REPO=$(cd "$(dirname "$0")/.." && pwd)
EXT=$REPO/external
OUT=$REPO/out                                   # build products (git-ignored)
BACKUP=${BACKUP:-$HOME/op10-backup}             # stock backup, never in git
IMAGE=${IMAGE:-iosplus10-build}
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
