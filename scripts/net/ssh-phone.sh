#!/bin/sh
# SSH to iOS on the phone over the USB Ethernet link (macOS and Linux). docs/usb-network.md.
#   scripts/net/ssh-phone.sh                          root shell
#   scripts/net/ssh-phone.sh CMD...                   run a command (e.g. 'ps ax', 'usbnetcfg show')
#   scripts/net/ssh-phone.sh push LOCAL... REMOTE     copy to the phone (scp -O: dropbear has no SFTP)
#   scripts/net/ssh-phone.sh pull REMOTE... LOCAL     copy from the phone
#   scripts/net/ssh-phone.sh wait [SECONDS]           wait until SSH answers (default 300 s)
#   scripts/net/ssh-phone.sh reboot-bootloader [-f]   reboot into fastboot (usbreboot bootloader)
#   scripts/net/ssh-phone.sh reboot [-f]              normal reboot (usbreboot normal)
#   scripts/net/ssh-phone.sh net                      configd network state (usbnetcfg show)
# Env: PHONE_IP (192.168.7.2), PHONE_USER (root), SSH_KEY (private key file), SSH_OPTS (more ssh options),
# PHONE_KNOWN_HOSTS (known_hosts file to check strictly; default out/ssh/known_hosts), PHONE_PASSWORD.
# Login, no setup: the repo key out/ssh/phone_ed25519 (root-add-ssh.py makes it and puts it on the root). A root built before
# that key, or without ssh-keygen, takes the stock iOS password: PHONE_PASSWORD, default alpine, given by phone-askpass.sh.
# In a git worktree without its own out/ssh, the files of the main checkout are used (the one that built the root).
# Host key: out/ssh/known_hosts (written by scripts/net/root-add-ssh.sh, checked strictly); if it is
# missing (key made on the phone, dropbear -R), the first key seen is kept in out/ssh/known_hosts.tofu.
# Your ~/.ssh/known_hosts is not used, so a new image does not cause host key warnings there.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
IP=${PHONE_IP:-192.168.7.2}
U=${PHONE_USER:-root}
SSHD=$REPO/out/ssh
if [ ! -f "$SSHD/known_hosts" ] && [ ! -f "$SSHD/phone_ed25519" ]; then
  main=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  main=${main%/.git}
  if [ -n "$main" ] && [ -d "$main/out/ssh" ]; then SSHD=$main/out/ssh; fi
fi
KH=${PHONE_KNOWN_HOSTS:-$SSHD/known_hosts}
if [ -f "$KH" ]; then hk="-o UserKnownHostsFile=$KH -o StrictHostKeyChecking=yes"
else mkdir -p "$SSHD"; hk="-o UserKnownHostsFile=$SSHD/known_hosts.tofu -o StrictHostKeyChecking=accept-new"; fi
opts="$hk -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR"
if [ -n "${SSH_KEY:-}" ]; then opts="$opts -i $SSH_KEY -o IdentitiesOnly=yes"
elif [ -f "$SSHD/phone_ed25519" ]; then opts="$opts -i $SSHD/phone_ed25519"; fi
# a password only if the phone asks for one (a root without the key); no prompt, so scripts and agents work too (OpenSSH 8.4 or later)
SSH_ASKPASS=$REPO/scripts/net/phone-askpass.sh SSH_ASKPASS_REQUIRE=force
export SSH_ASKPASS SSH_ASKPASS_REQUIRE
opts="$opts -o PreferredAuthentications=publickey,password -o NumberOfPasswordPrompts=1 ${SSH_OPTS:-}"

hint() { # after a failed connection
  echo "ssh-phone: no SSH on $U@$IP." >&2
  echo "  - Is iOS up with the USB network (negroniusb=2) and an SSH=1 root? Kernel log: make usblog" >&2
  echo "  - Does this host have 192.168.7.1 on the phone's interface? (sudo scripts/debug/usblog.sh sets it)" >&2
  echo "  - 'Permission denied': this key is not on the root and the password is not ${PHONE_PASSWORD:-alpine}: rebuild the root (root-add-ssh.py) or set SSH_KEY or PHONE_PASSWORD." >&2
  if [ "$(uname -s)" = Darwin ]; then
    echo "  - macOS 'No route to host' with a working link: Local Network privacy blocks this terminal" >&2
    echo "    app. Allow it in System Settings > Privacy & Security > Local Network (docs/usb-network.md)." >&2
  fi
}

run() { # ssh with our options; exit code 255 = connection problem
  # shellcheck disable=SC2086
  ssh $opts "$@"
}

reboot_mode() { # MODE [-f]
  force=; [ "${2:-}" = -f ] && force=-f
  set +e
  run -n "$U@$IP" "/usr/local/bin/usbreboot $force $1"
  rc=$?
  set -e
  case $rc in
  0|255)
    echo "ssh-phone: reboot ($1) sent; the SSH connection drops."
    if [ "$1" = bootloader ] && command -v fastboot >/dev/null 2>&1; then
      echo "ssh-phone: waiting up to 90 s for fastboot ('fastboot devices')..."
      i=0; while [ $i -lt 90 ]; do
        if [ -n "$(fastboot devices 2>/dev/null)" ]; then fastboot devices; exit 0; fi
        sleep 1; i=$((i + 1))
      done
      echo "ssh-phone: no fastboot device after 90 s. The kernel may hang at 'MACH Reboot':" >&2
      echo "  hold Volume Up + Volume Down + Power until fastboot shows." >&2
      exit 1
    fi ;;
  3)
    echo "ssh-phone: this kernel cannot choose a reboot mode (no kern.negroni_reboot_mode sysctl)." >&2
    echo "  '$0 reboot-bootloader -f' tries a plain reboot (it may hang at 'MACH Reboot');" >&2
    echo "  else hold Volume Up + Volume Down + Power for fastboot." >&2
    exit 3 ;;
  *) exit $rc ;;
  esac
}

case "${1:-}" in
push|pull)
  dir=$1; shift
  [ $# -ge 2 ] || { echo "usage: $0 push LOCAL... REMOTE | pull REMOTE... LOCAL" >&2; exit 2; }
  for last in "$@"; do :; done
  i=0; n=$#
  for a in "$@"; do   # the list is expanded once, so "set --" inside the loop is safe
    i=$((i + 1)); [ $i != 1 ] || set --
    [ $i -lt $n ] || continue
    if [ "$dir" = pull ]; then set -- "$@" "$U@$IP:$a"; else set -- "$@" "$a"; fi
  done
  [ "$dir" = pull ] || last=$U@$IP:$last
  # shellcheck disable=SC2086
  scp -O -r $opts "$@" "$last" ;;
wait)
  t=${2:-300}; i=0
  echo "ssh-phone: waiting for SSH on $IP (max $t s)..."
  until run -n -o ConnectTimeout=2 "$U@$IP" true 2>/dev/null; do
    i=$((i + 3)); [ $i -lt "$t" ] || { hint; exit 1; }; sleep 1
  done
  echo "ssh-phone: $IP answers" ;;
reboot-bootloader|reboot-fastboot) reboot_mode bootloader "${2:-}" ;;
reboot) reboot_mode normal "${2:-}" ;;
net) run -n "$U@$IP" /usr/local/bin/usbnetcfg show ;;
-h|--help) sed -n 2,14p "$0" ;;
*)
  set +e
  if [ $# = 0 ]; then run "$U@$IP"; else run "$U@$IP" "$@"; fi
  rc=$?
  [ $rc != 255 ] || hint
  exit $rc ;;
esac
