#!/bin/sh
# Give the phone internet through this computer over the USB Ethernet link (macOS and Linux).
#   scripts/net/share-internet.sh [start] [UPLINK]   NAT 192.168.7.0/24 out of UPLINK (default: the
#                                                    interface of the default route)
#   scripts/net/share-internet.sh stop               undo everything start did
#   scripts/net/share-internet.sh status
# Needs root (asks through sudo). The phone is 192.168.7.2 and uses 192.168.7.1 as router and
# 1.1.1.1 / 8.8.8.8 as DNS (scripts/net/root-add-ssh.sh). This script keeps 192.168.7.1/24 on the
# phone's interface (host MAC 02:00:5e:77:ee:01) if it is present, turns on IPv4 forwarding and adds:
#   macOS: one pf NAT rule in the anchor com.apple/iosplus10-share (the stock /etc/pf.conf loads
#          "com.apple/*" anchors), pf enabled with a reference token (pfctl -E / -X)
#   Linux: iptables (or nft) MASQUERADE for 192.168.7.0/24 + FORWARD accepts, comment iosplus10-share
# The old forwarding value and the pf token are saved in /var/run/iosplus10-share.state; stop
# restores them. Nothing is persistent: a host reboot also removes it. Not macOS Internet Sharing
# (that would put its own DHCP subnet on the link).
set -eu
MAC=02:00:5e:77:ee:01
NET=192.168.7.0/24
HOSTIP=192.168.7.1
ANCHOR=com.apple/iosplus10-share
TAG=iosplus10-share
STATE=/var/run/iosplus10-share.state
OS=$(uname -s)

if [ "$(id -u)" != 0 ]; then exec sudo "$0" "$@"; fi
cmd=${1:-start}

phone_if() {
  case $OS in
  Darwin) ifconfig -a | awk -v m="$MAC" '/^[a-z]/{i=$1; sub(":","",i)} $1=="ether" && tolower($2)==m {print i}' ;;
  Linux)  ip -o link | grep -i "$MAC" | awk -F': ' '{print $2}' | cut -d@ -f1 ;;
  esac | head -1
}
uplink() {
  case $OS in
  Darwin) route -n get default 2>/dev/null | awk '/interface:/{print $2}' ;;
  Linux)  ip route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}' ;;
  esac
}
linux_fw() { # iptables if present (works with the nft backend and keeps distro FORWARD policies), else nft
  if command -v iptables >/dev/null 2>&1; then echo iptables; elif command -v nft >/dev/null 2>&1; then echo nft; else echo none; fi
}
ipt_rules() { # ACTION(-A/-I/-D) UPLINK
  iptables -t nat "$1" POSTROUTING -s $NET -o "$2" -m comment --comment $TAG -j MASQUERADE
  iptables "$1" FORWARD -s $NET -o "$2" -m comment --comment $TAG -j ACCEPT
  iptables "$1" FORWARD -d $NET -i "$2" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment $TAG -j ACCEPT
}

start() {
  [ ! -f $STATE ] || { echo "already on ($STATE exists); run: $0 stop" >&2; exit 1; }
  pif=$(phone_if)
  up=${1:-$(uplink)}
  [ -n "$up" ] || { echo "no default route on this host; give the uplink: $0 start IFACE" >&2; exit 1; }
  [ "$up" != "$pif" ] || { echo "the default route goes through the phone ($pif)" >&2; exit 1; }
  if [ -n "$pif" ]; then
    case $OS in
    Darwin) ifconfig "$pif" inet $HOSTIP netmask 255.255.255.0 up ;;
    Linux)  nmcli dev set "$pif" managed no 2>/dev/null || true
            ip addr replace $HOSTIP/24 dev "$pif"; ip link set "$pif" up ;;
    esac
    echo "phone interface $pif: $HOSTIP/24"
  else
    echo "phone interface not present now (MAC $MAC); NAT is set up anyway. Give it $HOSTIP/24 later"
    echo "(sudo scripts/debug/usblog.sh does that) or run start again."
  fi
  case $OS in
  Darwin)
    fwd=$(sysctl -n net.inet.ip.forwarding)
    sysctl -w net.inet.ip.forwarding=1 >/dev/null
    echo "nat on $up inet from $NET to any -> ($up)" | pfctl -q -a $ANCHOR -f -
    token=$(pfctl -E 2>&1 | awk '/^Token/{print $3}')
    printf 'os=Darwin\nup=%s\nfwd=%s\ntoken=%s\n' "$up" "$fwd" "$token" > $STATE ;;
  Linux)
    fwd=$(cat /proc/sys/net/ipv4/ip_forward)
    fw=$(linux_fw)
    case $fw in
    iptables) ipt_rules -I "$up" ;;
    nft) nft -f - <<EOF
table ip $TAG {
  chain postrouting { type nat hook postrouting priority srcnat; ip saddr $NET oifname "$up" masquerade; }
  chain forward { type filter hook forward priority filter - 1;
    ip saddr $NET oifname "$up" accept; ip daddr $NET iifname "$up" ct state established,related accept; }
}
EOF
      ;;
    *) echo "neither iptables nor nft found" >&2; exit 1 ;;
    esac
    sysctl -q -w net.ipv4.ip_forward=1
    printf 'os=Linux\nup=%s\nfwd=%s\nfw=%s\n' "$up" "$fwd" "$fw" > $STATE ;;
  *) echo "unsupported OS $OS" >&2; exit 1 ;;
  esac
  echo "internet sharing on: $NET -> $up (forwarding was $fwd). Undo: $0 stop"
}

stop() {
  [ -f $STATE ] || { echo "not on (no $STATE)"; exit 0; }
  up=$(sed -n 's/^up=//p' $STATE); fwd=$(sed -n 's/^fwd=//p' $STATE)
  case $OS in
  Darwin)
    pfctl -q -a $ANCHOR -F all 2>/dev/null || true
    token=$(sed -n 's/^token=//p' $STATE)
    [ -z "$token" ] || pfctl -X "$token" 2>&1 | grep -v '^$' || true
    sysctl -w net.inet.ip.forwarding="${fwd:-0}" >/dev/null ;;
  Linux)
    case $(sed -n 's/^fw=//p' $STATE) in
    iptables) ipt_rules -D "$up" 2>/dev/null || true ;;
    nft) nft delete table ip $TAG 2>/dev/null || true ;;
    esac
    sysctl -q -w net.ipv4.ip_forward="${fwd:-0}" ;;
  esac
  rm -f $STATE
  echo "internet sharing off (forwarding back to ${fwd:-0})"
}

status() {
  if [ -f $STATE ]; then echo "on:"; sed 's/^/  /' $STATE; else echo "off"; fi
  echo "phone interface: $(phone_if || true)"
  case $OS in
  Darwin) echo "net.inet.ip.forwarding=$(sysctl -n net.inet.ip.forwarding)"
          pfctl -a $ANCHOR -s nat 2>/dev/null || true
          pfctl -s info 2>/dev/null | head -1 || true ;;
  Linux)  echo "net.ipv4.ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
          if command -v iptables >/dev/null 2>&1; then iptables-save 2>/dev/null | grep $TAG || true; fi
          if command -v nft >/dev/null 2>&1; then nft list table ip $TAG 2>/dev/null || true; fi ;;
  esac
}

case $cmd in
start) start "${2:-}" ;;
stop) stop ;;
status) status ;;
*) sed -n 2,7p "$0"; exit 1 ;;
esac
