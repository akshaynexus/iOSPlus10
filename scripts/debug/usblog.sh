#!/bin/sh
# Live kernel log from the phone over USB Ethernet (macOS and Linux).
#   sudo scripts/debug/usblog.sh          (in tmux: make usblog; the address needs root)
# The negroni kernel with negroniusb=2 (slop patches 0072-0077, 0119) is a CDC-ECM USB device
# (1209:0001, host-side MAC 02:00:5e:77:ee:01) and streams its console to UDP 192.168.7.1:5140.
# This waits for that interface, gives the host 192.168.7.1/24 and writes every packet with a
# host timestamp to logs/usblog-<date>.txt (and stdout). Python stdlib only.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MAC=02:00:5e:77:ee:01
LOG=$REPO/logs/usblog-$(date +%Y%m%d-%H%M%S).txt
mkdir -p "$REPO/logs"

find_if() {
  case "$(uname -s)" in
  Darwin) ifconfig -a | awk -v m="$MAC" '/^[a-z]/{i=$1; sub(":","",i)} $1=="ether" && tolower($2)==m {print i}' ;;
  Linux)  ip -o link | grep -i "$MAC" | awk -F': ' '{print $2}' | cut -d@ -f1 ;;
  esac
}
echo "waiting for the phone's USB Ethernet ($MAC)..."
until [ -n "$(find_if)" ]; do sleep 1; done
IF=$(find_if)
case "$(uname -s)" in
Darwin) ifconfig "$IF" inet 192.168.7.1 netmask 255.255.255.0 up ;;
Linux)  nmcli dev set "$IF" managed no 2>/dev/null || true
        ip addr replace 192.168.7.1/24 dev "$IF"; ip link set "$IF" up ;;
esac
echo "$IF up: 192.168.7.1 <-> phone 192.168.7.2; log -> $LOG"
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$REPO/logs" 2>/dev/null || true
exec python3 -u - "$LOG" <<'EOF'
import socket, sys, time, os
log = open(sys.argv[1], 'a', buffering=1)
os.chown(sys.argv[1], int(os.environ.get('SUDO_UID', 0)), int(os.environ.get('SUDO_GID', 0)))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 5140))
while True:
    data, _ = s.recvfrom(65535)
    for line in data.decode('utf-8', 'replace').splitlines():
        out = f'{time.strftime("%H:%M:%S")} {line}'
        print(out); log.write(out + '\n')
EOF
