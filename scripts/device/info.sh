#!/bin/sh
# Read the facts of the phone on adb (no root needed, nothing is written to the phone).
# Usage: scripts/device/info.sh [OUTFILE]     default: logs/device-info-<device>.txt
# The serial number and other unique IDs are not read (they must stay out of git and logs).
set -eu
. "$(dirname "$0")/../lib/env.sh"

adb get-state >/dev/null 2>&1 || { echo "info: no adb device" >&2; exit 1; }
dev=$(adb shell getprop ro.product.device | tr -d '\r')
out=${1:-$REPO/logs/device-info-$dev.txt}
mkdir -p "$(dirname "$out")"

sh_() { adb shell "$@" 2>&1 | tr -d '\r'; }
{
  echo "# device info, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "## properties"
  for p in ro.product.model ro.product.device ro.product.board ro.board.platform ro.hardware \
           ro.build.fingerprint ro.build.version.release ro.build.version.security_patch \
           ro.boot.slot_suffix ro.boot.verifiedbootstate ro.boot.flash.locked \
           ro.boot.vbmeta.device_state ro.build.ab_update ro.boot.dynamic_partitions \
           ro.treble.enabled ro.product.cpu.abilist gsm.version.baseband sys.panel.display \
           ro.sf.lcd_density; do
    echo "$p=$(sh_ getprop "$p")"
  done
  echo "## kernel";   sh_ uname -a
  echo "## cpu";      sh_ cat /proc/cpuinfo | grep -E '^(Hardware|CPU implementer|CPU part|CPU variant|CPU revision|Features)' | sort | uniq -c
  echo "## memory";   sh_ cat /proc/meminfo | head -3
  echo "## display";  sh_ wm size; sh_ wm density
  echo "## gpu";      sh_ cat /sys/class/kgsl/kgsl-3d0/gpu_model
  echo "## power supplies"; sh_ ls /sys/class/power_supply
  echo "## partitions (by-name)"; sh_ ls /dev/block/by-name | tr '\n' ' '; echo
  echo "## root"
  if adb shell 'command -v su' >/dev/null 2>&1; then
    echo "su: present"
    echo "## cmdline (root)"; sh_ su -c cat /proc/cmdline | sed -E 's/(serialno|serial)=[^ ]*/\1=<removed>/g'
    echo "## dt model (root)"; sh_ su -c cat /sys/firmware/devicetree/base/model; echo
    echo "## partition sizes (root)"
    sh_ su -c 'for p in /dev/block/by-name/*; do echo "$(basename $p) $(blockdev --getsize64 $p)"; done'
  else
    echo "su: absent (cmdline, devicetree and partition sizes need root)"
  fi
} > "$out"
echo "info: $out"
