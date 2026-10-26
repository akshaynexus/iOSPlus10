#!/bin/sh
# The Goodix fingerprint TA of the stock OTA: the partition-dump scan (scripts/fp/find-ta.sh) names
# /odm/vendor/vendor/firmware/goodixfp.mdt; in odm.img the file is /vendor/firmware/goodixfp.* (= /odm/vendor/firmware), a path the HAL searches (hal-strings.txt). Pull the
# goodixfp.* split image out of odm.img (read-only; a QSEE TA is signed and its code segments are
# encrypted on production devices: we only list the files and dump the plain strings).
#   scripts/bg.sh fp-ta scripts/fp/extract-ta.sh
# Output: out/fp/ta/goodixfp.* (git-ignored, vendor binaries: never commit), out/fp/lists/odm-vendor-firmware.txt,
#         out/fp/lists/ta-strings.txt. The odm payload is deleted at the end unless KEEP_PAYLOAD=1.
set -eu
. "$(dirname "$0")/../lib/env.sh"
OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
P=$OUT/fp/payload
T=$OUT/fp/ta
L=$OUT/fp/lists
for t in payload-dumper-go dump.erofs; do command -v $t >/dev/null || { echo "$t missing" >&2; exit 1; }; done
mkdir -p "$P" "$T" "$L"
[ -f "$P/odm.img" ] || payload-dumper-go -c "$NPROC" -o "$P" -p odm "$OTA"
dump.erofs --ls --path=/vendor/firmware "$P/odm.img" | awk '{print $3}' | grep -v '^$' > "$L/odm-vendor-firmware.txt"
cat "$L/odm-vendor-firmware.txt"
for f in $(grep -i 'goodix\|gf_\|gdx' "$L/odm-vendor-firmware.txt" || true); do
  dump.erofs --path="/vendor/firmware/$f" --cat "$P/odm.img" > "$T/$f"
done
ls -la "$T"
: > "$L/ta-strings.txt"
for f in "$T"/*; do
  { echo "== $(basename "$f") $(stat -f %z "$f") bytes"; file "$f" 2>/dev/null; strings -n 6 "$f" | sort -u | head -400; } >> "$L/ta-strings.txt"
done
(cd "$T" && shasum -a 256 ./*) >> "$OUT/fp/SHA256SUMS"
[ "${KEEP_PAYLOAD:-0}" = 1 ] || rm -rf "$P"
echo "done: $T, $L/ta-strings.txt"
