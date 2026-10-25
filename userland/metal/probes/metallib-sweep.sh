#!/bin/sh
# SPDX-License-Identifier: MIT
# Copied from Chlorophyll (ry-diffusion/Chlorophyll 787338f, test/ca-sweep.sh), MIT: see LICENSE.Chlorophyll in userland/metal/probes.
# NegroniMetal changes: one process per system metallib (theirs: one per QuartzCore fragment function), through
# metalprobe --metallib (every kernel -> compute pipeline, every fragment function with the first vertex function -> render
# pipeline, function constants unset); the library list is every .metallib of the 20H392 root (their tools/extract-metallibs.sh
# names 9 by hand; ours is out/metal/spi/metallibs.txt, which scripts/metal/build.sh stages); the stop rule is the GPU watchdog's
# marker (theirs: bootinfo "state=lost") or 3 runs in a row without a device; the dead-man strike of metalprobe is removed
# before each run, so one crashing library does not switch the device off for the next; only dash builtins + metalprobe.
#
# On the phone (scripts/metal/phone-test.sh 3b):
#   metallib-sweep.sh BUNDLE OUT.tsv [LIST]       LIST: one metallib path per line (default: the staged list)
# OUT.tsv: one line per library: path, result (PASS / refusals / crashed / nodevice), exit code, metalprobe's summary.
# Last line: "metallib-sweep: PASS|FAIL N libraries: P pass, F with refusals, C crashed, D without a device".
# Env (for a host test with a fake metalprobe): METALPROBE, NMTL_STRIKES, TMPDIR.
B="${1:?usage: metallib-sweep.sh BUNDLE OUT.tsv [LIST]}"
out="${2:?usage: metallib-sweep.sh BUNDLE OUT.tsv [LIST]}"
list="${3:-/usr/local/share/negronimetal/metallibs.txt}"
probe=${METALPROBE:-/usr/local/bin/metalprobe}
strikes=${NMTL_STRIKES:-/var/db/negronimetal/strikes}
tmp=${TMPDIR:-/var/tmp}/metallib-sweep.$$
[ -f "$list" ] || { echo "metallib-sweep: FAIL no list $list"; exit 1; }
: > "$out"
n=0 pass=0 fail=0 crash=0 nodev=0 nodev_run=0
while read -r lib; do
  case "$lib" in ''|'#'*) continue ;; esac
  [ -f "$lib" ] || { echo "metallib-sweep: missing $lib"; continue; }
  if [ -e "$strikes/gpu-lost" ]; then echo "metallib-sweep: GPU lost (watchdog marker $strikes/gpu-lost): stopping before $lib"; break; fi
  rm -f "$strikes/metalprobe"
  "$probe" --bundle "$B" --metallib "$lib" > "$tmp" 2>&1
  rc=$?
  sum=""
  while read -r line; do
    case "$line" in
    *" metallib: "*) sum="${line#metalprobe: }" ;;
    "metalprobe:   kernel "* | "metalprobe:   fragment "*) echo "  ${lib##*/}: ${line#metalprobe:   }" ;;
    esac
  done < "$tmp"
  n=$((n + 1))
  case $rc in
  0) r=PASS; pass=$((pass + 1)); nodev_run=0 ;;
  1) r=refusals; fail=$((fail + 1)); nodev_run=0 ;;
  2) r=nodevice; nodev=$((nodev + 1)); nodev_run=$((nodev_run + 1)) ;;
  *) r=crashed; crash=$((crash + 1)); nodev_run=0 ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$lib" "$r" "$rc" "$sum" >> "$out"
  printf 'metallib-sweep: %s %s (exit %s) %s\n' "$r" "$lib" "$rc" "$sum"
  if [ $nodev_run -ge 3 ]; then echo "metallib-sweep: 3 runs in a row without a device: stopping"; break; fi
done < "$list"
rm -f "$tmp"
res=PASS
[ $crash = 0 ] && [ $nodev = 0 ] && [ $fail = 0 ] || res=FAIL
echo "metallib-sweep: $res $n libraries: $pass pass, $fail with refusals, $crash crashed, $nodev without a device (table: $out)"
[ $res = PASS ]
