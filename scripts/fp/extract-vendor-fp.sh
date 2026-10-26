#!/bin/sh
# Pull the fingerprint-related files of the NE2211 stock OTA (read-only) and list where the rest is.
#   scripts/fp/extract-vendor-fp.sh            (run in tmux: scripts/bg.sh fp-extract scripts/fp/extract-vendor-fp.sh)
# Source: $OTA (default $BACKUP/NE2211_16.0.3.530_EX01_full.zip) with payload-dumper-go -p vendor,odm
# into out/fp/payload (vendor 0.7 GB + odm 1.3 GB; with modem/my_product/system it was 5 GB; deleted at the end unless KEEP_PAYLOAD=1). Output (git-ignored, vendor
# binaries: never commit them):
#   out/fp/odm/libgf_hal_G7.so, fingerprint.goodix_G7.default.so   the Goodix "Delmar" G7 HAL
#   out/fp/odm/*.rc, init.oplus.fingerprints.sh, fingerprint.json  init scripts and config
#   out/fp/lists/{vendor,odm}-firmware.txt, odm-lib64-fp.txt        where the TA is not (see docs/fingerprint-plan.md 1.2)
#   out/fp/lists/hal-strings.txt                                    strings of the HAL with the ioctl/netlink/property names
# Needs payload-dumper-go and dump.erofs (scripts/setup/native-tools.sh).
set -eu
. "$(dirname "$0")/../lib/env.sh"
OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
P=$OUT/fp/payload
D=$OUT/fp/odm
L=$OUT/fp/lists
for t in payload-dumper-go dump.erofs; do command -v $t >/dev/null || { echo "$t missing" >&2; exit 1; }; done
[ -f "$OTA" ] || { echo "no OTA zip $OTA" >&2; exit 1; }
mkdir -p "$P" "$D" "$L"
[ -f "$P/vendor.img" ] && [ -f "$P/odm.img" ] || payload-dumper-go -c "$NPROC" -o "$P" -p vendor,odm "$OTA"

cat_file() { dump.erofs --path="$2" --cat "$1" > "$3"; [ -s "$3" ] || { echo "empty: $2" >&2; exit 1; }; }
cat_file "$P/odm.img" /lib64/libgf_hal_G7.so "$D/libgf_hal_G7.so"
cat_file "$P/odm.img" /lib64/hw/fingerprint.goodix_G7.default.so "$D/fingerprint.goodix_G7.default.so"
cat_file "$P/odm.img" /etc/init/vendor.oplus.hardware.biometrics.fingerprint@2.1-service.rc "$D/fingerprint-service.rc"
cat_file "$P/odm.img" /bin/init.oplus.fingerprints.sh "$D/init.oplus.fingerprints.sh"
cat_file "$P/odm.img" /etc/fingerprint.json "$D/fingerprint.json"
dump.erofs --ls --path=/firmware "$P/vendor.img" | awk '{print $3}' | grep -v '^$' > "$L/vendor-firmware.txt"
dump.erofs --ls --path=/firmware "$P/odm.img" | awk '{print $3}' | grep -v '^$' > "$L/odm-firmware.txt"
{ dump.erofs --ls --path=/lib64 "$P/odm.img"; dump.erofs --ls --path=/lib64/hw "$P/odm.img"; dump.erofs --ls --path=/bin/hw "$P/odm.img"; } \
  | awk '{print $3}' | grep -i -E 'finger|goodix|gf_|biometric' > "$L/odm-lib64-fp.txt"
strings -n 5 "$D/libgf_hal_G7.so" | grep -E 'GF_IOC|GF_NETLINK|persist\.vendor\.fingerprint|/dev/goodix|/sys/kernel/oplus_display|Load ta|firmware' | sort -u > "$L/hal-strings.txt"
(cd "$D" && shasum -a 256 ./*) > "$OUT/fp/SHA256SUMS"
cat "$OUT/fp/SHA256SUMS"
[ "${KEEP_PAYLOAD:-0}" = 1 ] || rm -rf "$P"
echo "done: $D, $L"
