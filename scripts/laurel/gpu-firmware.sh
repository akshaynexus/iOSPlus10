#!/bin/bash
# Mi A3 GPU firmware from the phone's OWN stock vendor image (never from git, never from another phone):
#   a610_zap.mdt + a610_zap.b00..bNN   zap shader, TrustZone PAS 13 (signed for SM6125; topaz's khaje blob does not auth here)
#   a630_sqe.fw                        CP SQE microcode (the A6xx one kgsl loads on trinket)
#   scripts/bg.sh laurel-gpufw scripts/laurel/gpu-firmware.sh
#   VENDOR=path   vendor image: Android sparse or raw ext4 (default ~/laurel-backup/stock/images/vendor.img)
#                 or a directory that holds the files (e.g. an `adb pull /vendor/firmware`)
# Output: out/laurel/gpu/firmware/ (git-ignored) + SHA256SUMS. root-add-gpu.sh installs it to /usr/share/firmware/laurel.
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
VENDOR=${VENDOR:-$HOME/laurel-backup/stock/images/vendor.img}
F=$G/firmware
W=$G/fw-work
[ -e "$VENDOR" ] || gpu_die "no vendor image $VENDOR (set VENDOR=)"
rm -rf "$F" "$W"; mkdir -p "$F" "$W"
trap 'rm -rf "$W"' EXIT

if [ -d "$VENDOR" ]; then
  for f in "$VENDOR"/a610_zap.* "$VENDOR"/a630_sqe.fw; do [ -f "$f" ] && cp "$f" "$F/"; done
else
  command -v debugfs >/dev/null || gpu_die "missing debugfs (e2fsprogs)"
  raw=$VENDOR
  if file -b "$VENDOR" | grep -q 'Android sparse'; then
    command -v simg2img >/dev/null || gpu_die "missing simg2img (android-tools)"
    raw=$W/vendor.raw
    echo "gpu-firmware: simg2img $(basename "$VENDOR") ($(du -h "$VENDOR" | cut -f1))"
    simg2img "$VENDOR" "$raw"
  fi
  # vendor partition: /firmware holds the GPU files (kgsl's request_firmware path /vendor/firmware)
  for d in /firmware /firmware_mnt/image; do
    ls=$(debugfs -R "ls -p $d" "$raw" 2>/dev/null || true)
    names=$(printf '%s\n' "$ls" | awk -F/ 'NF>5 && ($6 ~ /^a610_zap\./ || $6 == "a630_sqe.fw") {print $6}' | sort -u)
    [ -n "$names" ] || continue
    echo "gpu-firmware: found in $d: $(echo $names)"
    for n in $names; do debugfs -R "dump $d/$n $F/$n" "$raw" >/dev/null 2>&1; done
    break
  done
fi

ls "$F"/a610_zap.mdt >/dev/null 2>&1 || gpu_die "no a610_zap.mdt in $VENDOR"
ls "$F"/a610_zap.b0* >/dev/null 2>&1 || gpu_die "no a610_zap.bNN segments in $VENDOR"
[ -s "$F/a630_sqe.fw" ] || echo "gpu-firmware: note: no a630_sqe.fw in the vendor image: the kernel uses its built-in SQE (topaz)"
# sanity: the .mdt is a 32-bit ELF (Qualcomm PIL metadata), the kernel driver rejects others too
head -c 5 "$F/a610_zap.mdt" | od -An -tx1 | grep -q '7f 45 4c 46 01' || gpu_die "a610_zap.mdt is not an ELF32 file"
(cd "$F" && gpu_sha256_files * > SHA256SUMS)
ls -l "$F"
echo "gpu-firmware: $F (not for git: Qualcomm/Xiaomi firmware)"
