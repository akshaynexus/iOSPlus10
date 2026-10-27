#!/bin/sh
# Live kernel log from the phone over USB Ethernet (macOS and Linux).
#   sudo scripts/debug/usblog.sh          (in tmux: make usblog; the address needs root)
# The negroni kernel with negroniusb=2 (slop patches 0072-0077, 0119) is a CDC-ECM USB device
# (1209:0001, host-side MAC 02:00:5e:77:ee:01) and streams its console to UDP 192.168.7.1:5140.
# This waits for that interface, gives the host 192.168.7.1/24 and writes every packet with a
# host timestamp to logs/usblog-<date>.txt (and stdout). Python stdlib only. The address is
# applied again after every phone reboot (new interface), so boot loops are logged too.
# USBLOG_SETTIME=1 (default): each time the interface comes up, also send this host's clock to the
# kernel command server ("settime <unix s>.<us>" to 192.168.7.2:5141, patch 0212; retried for 30 s
# until the kernel replies). USBLOG_SETTIME=0 turns it off.
# USBLOG_KEEPALIVE=N (default 10, 0 = off): every N s one UDP broadcast datagram ("keepalive") to
# 192.168.7.255:5142 over the phone's interface. It needs no ARP and no answer (the phone's stack drops it),
# but it is a bulk OUT frame: the kernel's data-path watchdog (patch 0375, negroniusb_idle_reboot=S) reboots
# the phone when no OUT frame comes for S s, so a test image needs this sender (or other host traffic).
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
has_addr() {
  case "$(uname -s)" in
  Darwin) ifconfig "$1" 2>/dev/null | grep -q "inet 192.168.7.1 " ;;
  Linux)  ip -o addr show dev "$1" 2>/dev/null | grep -q "192.168.7.1/" ;;
  esac
}
set_addr() {
  case "$(uname -s)" in
  Darwin) ifconfig "$1" inet 192.168.7.1 netmask 255.255.255.0 up ;;
  Linux)  nmcli dev set "$1" managed no 2>/dev/null || true
          ip addr replace 192.168.7.1/24 brd + dev "$1"; ip link set "$1" up ;;
  esac
}
# One "settime" to the phone (patch 0212), retried once a second for 30 s until a reply comes
# (ARP and the kernel's link can lag the interface). Older kernels answer "error: unknown command".
send_time() {
  r=$(python3 - <<'PY' 2>&1
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('192.168.7.1', 0))
s.settimeout(1)
for _ in range(30):
    t = time.time()
    try:
        s.sendto(f'settime {int(t)}.{int(t % 1 * 1e6):06d}'.encode(), ('192.168.7.2', 5141))
        print(s.recv(512).decode('utf-8', 'replace').strip())
        break
    except OSError:
        time.sleep(0.2)
else:
    print('no reply in 30 s')
PY
)
  echo "$(date +%H:%M:%S) ==== usblog: settime: $r" | tee -a "$LOG"
}
# Each phone reboot makes a new USB interface without our address: keep (re)applying it, so the
# log continues across reboots (and boot loops). Marks each (re)connect in the log.
watch_if() {
  last=""
  while :; do
    IF=$(find_if)
    if [ -n "$IF" ] && ! has_addr "$IF"; then
      set_addr "$IF" && echo "$(date +%H:%M:%S) ==== usblog: $IF up (192.168.7.1 <-> phone 192.168.7.2)" | tee -a "$LOG"
      [ "${USBLOG_SETTIME:-1}" = 1 ] && { send_time & }
    elif [ -z "$IF" ] && [ -n "$last" ]; then
      echo "$(date +%H:%M:%S) ==== usblog: phone interface gone (reboot or unplug)" | tee -a "$LOG"
    fi
    last=$IF; sleep 1
  done
}
# 0375: a bulk OUT frame at least every USBLOG_KEEPALIVE s while the interface has our address
keepalive() {
  # exec: the background PID is python itself, so the EXIT trap stops it (no orphan sender keeps a dead phone "alive")
  exec python3 - "${USBLOG_KEEPALIVE:-10}" <<'PY'
import socket, sys, time
period = float(sys.argv[1])
s = None
while True:
    try:
        if s is None:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.bind(('192.168.7.1', 0))      # fails until the interface has the address
        s.sendto(b'keepalive', ('192.168.7.255', 5142))
    except OSError:
        if s is not None:
            s.close()
        s = None
    time.sleep(period)
PY
}
echo "waiting for the phone's USB Ethernet ($MAC); log -> $LOG"
watch_if &
PIDS=$!
if [ "${USBLOG_KEEPALIVE:-10}" != 0 ]; then keepalive & PIDS="$PIDS $!"; fi
trap 'kill $PIDS 2>/dev/null' EXIT INT TERM
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$REPO/logs" 2>/dev/null || true
python3 -u - "$LOG" <<'EOF'
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
