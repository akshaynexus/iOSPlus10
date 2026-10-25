#!/bin/sh
# Extract the Adreno 730 firmware of the NE2211 from the stock vendor image (read-only).
#   scripts/fw/extract-gpu-fw.sh [VENDOR_IMG]
# Source, first match: the VENDOR_IMG argument (or $VENDOR_IMG); out/camera/payload/vendor.img
# (scripts/camera/inventory.sh); else the full OTA ($OTA, default
# $BACKUP/NE2211_16.0.3.530_EX01_full.zip) with payload-dumper-go -p vendor into a scratch folder
# that is deleted after (the vendor image is ~650 MB).
# Output (git-ignored, vendor firmware: never commit it):
#   out/firmware/gpu/a730_zap.mdt, a730_zap.b00..b02, a730_zap.mbn   zap shader (TrustZone PAS 13)
#   out/firmware/gpu/a730_sqe.fw                                     CP microcode
#   out/firmware/gpu/gmu_gen70000.bin                                GMU firmware
#   out/firmware/gpu/SHA256SUMS
# Next: scripts/fw/build-areas.sh (mkfwarea.py with the 7 files above, not SHA256SUMS)
# (scripts/fw/write-areas.sh writes it). Needs dump.erofs (erofs-utils >= 1.8 for --cat).
set -eu
. "$(dirname "$0")/../lib/env.sh"
OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
G=$OUT/firmware/gpu
FILES="a730_zap.mdt a730_zap.b00 a730_zap.b01 a730_zap.b02 a730_zap.mbn a730_sqe.fw gmu_gen70000.bin"
# Known hashes (external/slop/NOTES.md "GPU firmware pulled", prefixes; slop pulled them from its phone).
# slop's a730_zap.mdt (0706695b) is not from this build: 16.0.3.530 EX01 gives 2a74e9e9 (an OPLUS-signed
# split; the .mbn is the QUALCOMM-signed whole file). The script checks the split itself instead.
KNOWN="a730_sqe.fw:4f8b288f gmu_gen70000.bin:b2d3f0e2 a730_zap.mbn:905b1311"
command -v dump.erofs >/dev/null || { echo "dump.erofs missing (scripts/setup/native-tools.sh)" >&2; exit 1; }

IMG=${1:-${VENDOR_IMG:-}}
TMP=
if [ -z "$IMG" ] && [ -f "$OUT/camera/payload/vendor.img" ]; then IMG=$OUT/camera/payload/vendor.img; fi
if [ -z "$IMG" ]; then
  [ -f "$OTA" ] || { echo "no OTA zip $OTA (scripts/backup/fetch-stock-ota.sh)" >&2; exit 1; }
  command -v payload-dumper-go >/dev/null || { echo "payload-dumper-go missing (docs/setup-*.md)" >&2; exit 1; }
  TMP=$OUT/firmware/.gpu-payload
  rm -rf "$TMP"
  payload-dumper-go -c "$NPROC" -o "$TMP" -p vendor "$OTA"
  IMG=$TMP/vendor.img
fi
[ -f "$IMG" ] || { echo "vendor image not found: $IMG" >&2; exit 1; }

mkdir -p "$G"
for f in $FILES; do
  rm -f "$G/$f"
  dump.erofs --path="/firmware/$f" --cat "$IMG" > "$G/$f"
  [ -s "$G/$f" ] || { echo "empty or missing in the image: /firmware/$f" >&2; exit 1; }
done
[ -z "$TMP" ] || rm -rf "$TMP"

(cd "$G" && shasum -a 256 $FILES) > "$G/SHA256SUMS"
cat "$G/SHA256SUMS"
bad=0
for k in $KNOWN; do
  f=${k%%:*}; want=${k#*:}
  got=$(awk -v f="$f" '$2 == f {print substr($1, 1, 8)}' "$G/SHA256SUMS")
  if [ "$got" = "$want" ]; then echo "known hash OK: $f $want"; else echo "HASH MISMATCH: $f $got != $want" >&2; bad=1; fi
done
# The .mdt is the ELF header segment (.b00) followed by the hash segment (.b02).
if cat "$G/a730_zap.b00" "$G/a730_zap.b02" | cmp -s - "$G/a730_zap.mdt"; then echo "a730_zap.mdt = b00 + b02 OK"
else echo "a730_zap.mdt is not b00 + b02" >&2; bad=1; fi
exit $bad
