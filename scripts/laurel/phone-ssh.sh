#!/bin/sh
# Mi A3: run commands on iOS over the USB Ethernet link (dropbear on 192.168.7.2:22), macOS and Linux.
#   scripts/laurel/phone-ssh.sh                       root shell
#   scripts/laurel/phone-ssh.sh CMD...                one command ('ps ax', 'sysctl kern.laurel_reboot_mode')
#   scripts/laurel/phone-ssh.sh push LOCAL... REMOTE  copy to the phone (scp -O)
#   scripts/laurel/phone-ssh.sh pull REMOTE... LOCAL  copy from the phone
#   scripts/laurel/phone-ssh.sh wait [SECONDS]        wait until SSH answers (default 300 s)
#   scripts/laurel/phone-ssh.sh reboot | reboot-bootloader [-f]   usbreboot (kern.laurel_reboot_mode, patch 2003)
#   scripts/laurel/phone-ssh.sh bootlog [N]           the boot log area (/dev/laurelbootlog, kernel patch 2900; parked: patches/laurel/parked/)
#                                                     -> logs/laurel-bootlog-<time>/bootlog-<boot>.txt (op10tool)
# Needs: a root image with SSH (scripts/laurel/root.sh installs it when out/ssh/ios exists: userland/ssh/build.sh,
# Linux or macOS), the host address 192.168.7.1 on the phone's interface (make usblog sets it), and a
# kernel that attached ue0 ("LAUREL USB: ue0 attached" in the live log). Everything else (keys, known_hosts,
# PHONE_IP, SSH_KEY, SSH_OPTS) as scripts/net/ssh-phone.sh, which does the work.
# Without SSH (kernel only) the command server still answers: out/bin/op10tool ctl ping|log|bootlog|time|reboot ...
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
OP=$REPO/out/bin/op10tool

case "${1:-}" in
bootlog)
  n=${2:-}
  d=$REPO/logs/laurel-bootlog-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$d"
  # 9216 blocks of 4096 bytes = the whole area (superblock + 8 slots + reserve); toybox dd in /usr/local/bin
  "$SSHP" "/usr/local/bin/dd if=/dev/laurelbootlog bs=4096 count=9216 2>/dev/null" > "$d/area.bin"
  echo "phone-ssh: $(wc -c < "$d/area.bin") bytes -> $d/area.bin" >&2
  [ -x "$OP" ] || "$REPO/scripts/setup/build-op10tool.sh"
  # shellcheck disable=SC2086
  exec "$OP" bootlog $n --file "$d/area.bin" --out "$d" --kernels "$REPO/out/laurel-kernel/out"
  ;;
*)
  "$SSHP" "$@" || {
    rc=$?
    if [ $rc = 255 ] && [ -x "$OP" ]; then
      echo "phone-ssh: kernel command server: $("$OP" ctl ping 2>&1 | tail -1)" >&2
      echo "  (pong = the kernel and ue0 run: SSH is missing on the root, or dropbear did not start)" >&2
    fi
    exit $rc
  }
  ;;
esac
