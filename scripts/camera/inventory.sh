#!/bin/sh
# Offline camera inventory of the NE2211 (no phone access). Run it in tmux, it extracts ~2 GB:
#   scripts/bg.sh camera-inv scripts/camera/inventory.sh
# Inputs (read-only): $BACKUP/device/live.dtb, $BACKUP/images/dtbo.img, the OTA zip ($OTA).
# Output (git-ignored): out/camera/
#   dt-table.txt      camera DT nodes of the live DT, phandles resolved (camdt.py table)
#   dtbo/index.txt    DTBO entries (board/project ids) + checksum of their camera fragments
#   modules.txt       CAMX sensor modules: cameraId, slave address, chip ID, lanes, power order
#   files.txt         camera files in odm/vendor + SHA-256 of the extracted ones
# Needs: dtc, erofs-utils (fsck.erofs, dump.erofs), payload-dumper-go, out/venv with `fdt`
# (scripts/setup/native-tools.sh installs dtc, erofs-utils and fdt).
# KEEP_IMAGES=0 deletes the extracted vendor/odm images (1.9 GB) at the end.
set -eu
# shellcheck source=scripts/lib/env.sh
. "$(dirname "$0")/../lib/env.sh"

OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
C=$OUT/camera
PY="$OUT/venv/bin/python3 -I"
for t in dtc fsck.erofs dump.erofs payload-dumper-go; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "$t missing: run scripts/setup/native-tools.sh (macOS: brew install dtc erofs-utils" \
			"payload-dumper-go; Linux: apt install device-tree-compiler erofs-utils, payload-dumper-go" \
			"from docs/setup-linux.md)" >&2
		exit 1
	}
done
$PY -c 'import fdt' 2>/dev/null || { echo "out/venv has no fdt: run scripts/setup/native-tools.sh" >&2; exit 1; }
mkdir -p "$C"

# 1. Live DT (base DTB + applied DTBO overlay). dtc rewrites it: the fdt library rejects FDT_NOP tags.
dtc -q -I dtb -O dtb -o "$C/live.dtb" "$BACKUP/device/live.dtb"
$PY "$REPO/scripts/camera/camdt.py" table "$C/live.dtb" > "$C/dt-table.txt"

# 2. Stock DTBO table: split, decompile, extract the CCI fragments (the camera nodes).
rm -rf "$C/dtbo"
$PY "$REPO/scripts/camera/camdt.py" split "$BACKUP/images/dtbo.img" "$C/dtbo" > "$C/dtbo/index.txt"
for f in "$C"/dtbo/*.dtbo; do
	b=${f%.dtbo}
	dtc -q -I dtb -O dts -o "$b.dts" "$f"
	awk '/target = <&cam_cci[01]>;/{p=1} p{print} /^\t};$/{p=0}' "$b.dts" > "$b.cam.dts"
done
(cd "$C/dtbo" && for f in *.cam.dts; do
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"; else shasum -a 256 "$f"; fi
done) >> "$C/dtbo/index.txt"

# 3. vendor + odm images from the OTA (EROFS), only when not already extracted.
P=$C/payload
if [ ! -s "$P/vendor.img" ] || [ ! -s "$P/odm.img" ]; then
	[ -f "$OTA" ] || { echo "no OTA zip: $OTA" >&2; exit 1; }
	rm -rf "$P"
	payload-dumper-go -c "$NPROC" -o "$P" -p vendor,odm "$OTA"
fi

# 4. Camera files: odm (OnePlus modules) and vendor (Qualcomm modules, ICP firmware).
X=$C/x
rm -rf "$X"
mkdir -p "$X/vendor-firmware"
{
	for img in odm vendor; do
		echo "== /$img/lib64/camera"
		dump.erofs --ls --path=/lib64/camera "$P/$img.img" | awk 'NR > 8 && $3 != "." && $3 != ".." {print $3}'
	done
	echo "== /vendor/firmware (camera)"
	dump.erofs --ls --path=/firmware "$P/vendor.img" | awk 'NR > 8 {print $3}' | grep -i '^CAMERA' || true
} > "$C/files.txt"
fsck.erofs --no-preserve --extract="$X/odm-camera" --path=/lib64/camera "$P/odm.img" >/dev/null
grep '^CAMERA' "$C/files.txt" | while read -r f; do
	fsck.erofs --no-preserve --extract="$X/vendor-firmware/$f" --path="/firmware/$f" "$P/vendor.img" >/dev/null
done
(cd "$X" && for f in odm-camera/com.qti.sensormodule.* odm-camera/com.qti.sensor.* vendor-firmware/*; do
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"; else shasum -a 256 "$f"; fi
done) >> "$C/files.txt"

# 5. Sensor module facts.
$PY "$REPO/scripts/camera/cammodule.py" "$X"/odm-camera/com.qti.sensormodule.*.bin > "$C/modules.txt"

if [ "${KEEP_IMAGES:-1}" = 0 ]; then rm -rf "$P"; fi
grep -E '^==|cell-index|cci-master|csiphy-sd-index|-supply|_active|cam_default|-src' "$C/dt-table.txt" || true
cat "$C/modules.txt"
echo "outputs: $C/dt-table.txt $C/dtbo/index.txt $C/modules.txt $C/files.txt"
