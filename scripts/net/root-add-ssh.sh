#!/bin/sh
# Add SSH (dropbear on 192.168.7.2:22) and the USB network service (ue0 -> internet through the
# host) to a mounted, writable iOS 16 root. Off unless SSH=1. Run as root (macOS or Linux):
#   SSH=1 scripts/net/root-add-ssh.sh MOUNTED_ROOT
# Optional: SSH_PUBKEY=FILE (default: ~/.ssh/id_ed25519.pub of SUDO_USER, then id_ecdsa, id_rsa;
# none = password login with the stock iOS root password), SSH_PASSWORD_AUTH=1 (passwords also
# with a key). Needs out/ssh/ios from userland/ssh/build.sh (macOS). Details: docs/usb-network.md.
set -eu
R=${1:?usage: SSH=1 $0 MOUNTED_ROOT}
if [ "${SSH:-0}" != 1 ]; then echo "ssh: skipped (SSH=1 adds SSH + the USB network service)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
[ "$(id -u)" = 0 ] || echo "warning: not root; owners stay as they are (test runs only)" >&2
exec python3 -I "$REPO/scripts/net/root-add-ssh.py" "$R"
