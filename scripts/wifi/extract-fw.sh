#!/bin/sh
# Extract QCA6490 WLAN firmware and board files from the stock NE2211 modem image.
# Long OTA payload extraction should run as:
#   scripts/bg.sh wifi-fw scripts/wifi/extract-fw.sh
# Inputs: OTA (default ~/op10-backup/NE2211_16.0.3.530_EX01_full.zip), or MODEM_IMG.
# Output: out/firmware/wlan/ (ignored; never commit vendor firmware).
set -eu
. "$(dirname "$0")/../lib/env.sh"

OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
MODEM_IMG=${MODEM_IMG:-}
M=$OUT/firmware/modem
W=$OUT/firmware/wlan
mkdir -p "$M" "$W"

if [ -z "$MODEM_IMG" ]; then
	[ -f "$OTA" ] || { echo "no OTA zip: $OTA" >&2; exit 1; }
	command -v payload-dumper-go >/dev/null 2>&1 || {
		echo "payload-dumper-go missing; install it using docs/setup-macos.md or docs/setup-linux.md" >&2
		exit 1
	}
	rm -rf "$M/payload"
	payload-dumper-go -o "$M/payload" -p modem "$OTA"
	[ -f "$M/payload/modem.img" ] || { echo "payload-dumper-go did not produce modem.img" >&2; exit 1; }
	MODEM_IMG=$M/payload/modem.img
fi
[ -f "$MODEM_IMG" ] || { echo "modem image not found: $MODEM_IMG" >&2; exit 1; }

F="python3 -I $REPO/scripts/audio/fatcopy.py"
rm -f "$W"/amss.bin "$W"/m3.bin "$W"/regdb.bin "$W"/bdwlan.* "$W"/bdf_*
$F "$MODEM_IMG" get image 'amss.bin' "$W"
$F "$MODEM_IMG" get image 'm3.bin' "$W"
$F "$MODEM_IMG" get image 'regdb.bin' "$W"
# The OTA stores calibration/board variants as bdwlan.* and may include bdf_*.bin.
$F "$MODEM_IMG" get image 'bdwlan.*' "$W"
if python3 -I "$REPO/scripts/audio/fatcopy.py" "$MODEM_IMG" list image | awk '{print $3}' | grep -qi '^bdf_'; then
	$F "$MODEM_IMG" get image 'bdf_*.bin' "$W"
fi

for f in amss.bin m3.bin regdb.bin; do
	[ -s "$W/$f" ] || { echo "required WLAN file missing or empty: $f" >&2; exit 1; }
done
if ! ls "$W"/bdwlan.* >/dev/null 2>&1 && ! ls "$W"/bdf_*.bin >/dev/null 2>&1; then
	echo "no board-data files (bdwlan.* or bdf_*.bin) found in modem image" >&2
	exit 1
fi

# macOS ships shasum; Linux commonly ships sha256sum. Skip absent optional globs.
(cd "$W" && {
	for f in amss.bin m3.bin regdb.bin bdwlan.* bdf_*.bin; do
		[ -f "$f" ] || continue
		if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"; else shasum -a 256 "$f"; fi
	done
} > SHA256SUMS)
echo "WLAN files and SHA-256 checksums: $W/SHA256SUMS"
echo "modem image SHA-256: $( (sha256sum "$MODEM_IMG" 2>/dev/null || shasum -a 256 "$MODEM_IMG") | cut -d' ' -f1)"
if [ -d "$M/payload" ]; then
	rm -rf "$M/payload"
fi
