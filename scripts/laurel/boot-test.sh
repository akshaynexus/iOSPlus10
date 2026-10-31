#!/bin/sh
# Mi A3 (laurel_sprout) boot test loop: flash -> boot -> capture the kernel log over USB -> back to fastboot.
#   scripts/bg.sh laurel-test scripts/laurel/boot-test.sh            (always in tmux)
# Needs: the phone in fastboot (ABL) on the USB cable, and the USB log listener running:
#   make usblog                 (once; sudo password: tmux attach -t usblog; it stays up across reboots)
# Steps (each prints a time-stamped line):
#   1. flash out/laurel/laurel-boot.img to boot_b (scripts/laurel/flash-boot.sh) and reboot
#   2. wait for the phone's USB Ethernet (host MAC 02:00:5e:77:ee:01, kernel patch 2005), then for
#      `op10tool ctl ping` = pong (the command server, UDP 192.168.7.2:5141)
#   3. watch the live log (logs/usblog-*.txt, written by usblog.sh) for HOLD_S seconds (default 120) or
#      until a panic line; copy this boot's lines to logs/laurel-boot-<time>.log and print the last lines
#   4. `op10tool ctl bootloader`: the kernel (or the panic hold) resets into ABL fastboot, so the next
#      run needs no Power+VolDown; wait for the fastboot USB device
# Env: HOLD_S=120, IMG=out/laurel/laurel-boot.img, NOFLASH=1 (phone already booting), NOBACK=1 (leave it running),
#      WAIT_IF_S=180 (USB interface), WAIT_PING_S=60, BOOT=continue|reboot (flash-boot.sh: how ABL leaves fastboot). Exit 0 = log captured (a panic is reported, not an error),
#      2 = no USB interface, 3 = no pong.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
OP=$REPO/out/bin/op10tool
MAC=02:00:5e:77:ee:01
HOLD_S=${HOLD_S:-120}
WAIT_IF_S=${WAIT_IF_S:-180}
WAIT_PING_S=${WAIT_PING_S:-60}
IMG=${IMG:-$OUT/laurel/laurel-boot.img}
ts() { date +%H:%M:%S; }
say() { echo "$(ts) boot-test: $*"; }
ecm_if() { ip -o link | grep -i "$MAC" | awk -F': ' '{print $2}' | cut -d@ -f1; }
fastboot_dev() { lsusb | awk '/18d1:d00d/{print $4}'; }
newest_usblog() { ls -t "$REPO"/logs/usblog-*.txt 2>/dev/null | head -1; }

[ -x "$OP" ] || { say "missing $OP (make op10tool)"; exit 1; }
tmux has-session -t usblog 2>/dev/null || { say "the USB log listener is not running: make usblog (then: tmux attach -t usblog, sudo password)"; exit 1; }
LOGF=$(newest_usblog)
[ -n "$LOGF" ] || { say "usblog.sh has written no logs/usblog-*.txt yet (sudo password pending? tmux attach -t usblog)"; exit 1; }
start_line=$(wc -l < "$LOGF")
OUTLOG=$REPO/logs/laurel-boot-$(date +%Y%m%d-%H%M%S).log

if [ "${NOFLASH:-0}" != 1 ]; then
  say "step 1: flash $IMG ($(stat -c %s "$IMG") bytes) to boot_b"
  [ -n "$(fastboot_dev)" ] || say "no fastboot device: waiting (phone in fastboot? Power+VolDown, or op10tool ctl bootloader)"
  while [ -z "$(fastboot_dev)" ]; do sleep 1; done
  WAIT_NEW=0 "$REPO/scripts/laurel/flash-boot.sh" "$IMG" || { say "flash failed"; exit 1; }
fi

say "step 2: waiting up to $WAIT_IF_S s for the USB Ethernet interface ($MAC)"
t0=$(date +%s); IF=""
while :; do
  IF=$(ecm_if); [ -n "$IF" ] && break
  [ $(( $(date +%s) - t0 )) -lt "$WAIT_IF_S" ] || { say "no USB interface in $WAIT_IF_S s (kernel not up to the USB start, or 'LAUREL USB: off' - check the panel)"; exit 2; }
  sleep 1
done
say "USB interface $IF after $(( $(date +%s) - t0 )) s; waiting for 192.168.7.1 (usblog.sh sets it) and pong"
t0=$(date +%s); pong=0
while [ $(( $(date +%s) - t0 )) -lt "$WAIT_PING_S" ]; do
  if ip -o addr show dev "$IF" 2>/dev/null | grep -q "192.168.7.1/" && "$OP" ctl ping >/dev/null 2>&1; then pong=1; break; fi
  sleep 1
done
if [ $pong = 1 ]; then say "pong after $(( $(date +%s) - t0 )) s"; else say "no pong in $WAIT_PING_S s (log capture goes on)"; fi

say "step 3: holding $HOLD_S s for the log (stops early on a panic); live file $LOGF"
t0=$(date +%s); panic=""
while [ $(( $(date +%s) - t0 )) -lt "$HOLD_S" ]; do
  panic=$(tail -n +"$((start_line + 1))" "$LOGF" | grep -m1 -E "panic\(cpu|LAUREL PANIC:")
  [ -n "$panic" ] && { sleep 5; break; }
  sleep 2
done
tail -n +"$((start_line + 1))" "$LOGF" > "$OUTLOG"
n=$(wc -l < "$OUTLOG")
say "captured $n lines -> $OUTLOG"
echo "---- LAUREL/SWEET state lines"
grep -E "LAUREL (USB|CPU|REBOOT|CTL|PANIC)|SWEET CPU: .*(alive|initialized)|SWEET USB: (running|configured|ECM)" "$OUTLOG" | tail -20
if [ -n "$panic" ]; then
  echo "---- PANIC"; grep -n -A25 -m1 -E "panic\(cpu" "$OUTLOG" | head -40
else
  echo "---- last 25 lines"; tail -25 "$OUTLOG"
fi

[ "${NOBACK:-0}" = 1 ] && { say "NOBACK=1: the phone stays up"; exit 0; }
say "step 4: op10tool ctl bootloader (back to fastboot without buttons)"
if "$OP" ctl bootloader; then
  t0=$(date +%s)
  while [ -z "$(fastboot_dev)" ]; do
    [ $(( $(date +%s) - t0 )) -lt 60 ] || { say "no fastboot device 60 s after the bootloader command (IMEM reason not taken? use Power+VolDown)"; exit 0; }
    sleep 1
  done
  say "phone is in fastboot ($(fastboot_dev)); next: scripts/bg.sh laurel-test scripts/laurel/boot-test.sh"
else
  say "no reply to 'bootloader': hold Power+VolDown to reach fastboot"
  [ $pong = 1 ] && exit 0 || exit 3
fi
exit 0
