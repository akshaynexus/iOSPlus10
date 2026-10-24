#!/bin/sh
# iOS 16 root image: picks root-macos.sh or root-linux.sh for this host. Needs sudo.
#   sudo scripts/ios16/root.sh [OUT.img]
case "$(uname -s)" in
Darwin) exec bash "$(dirname "$0")/root-macos.sh" "$@" ;;
Linux)  exec bash "$(dirname "$0")/root-linux.sh" "$@" ;;
*) echo "unsupported host $(uname -s)" >&2; exit 1 ;;
esac
