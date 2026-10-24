#!/bin/sh
# Download the official OxygenOS full OTA for a OnePlus 10 Pro build and check its MD5.
#
#   scripts/backup/fetch-stock-ota.sh [model] [version] [outdir]
#   scripts/backup/fetch-stock-ota.sh NE2211 'NE2211_16.0.3.530(EX01)' ~/op10-backup
#
# The catalog is roms.danielspringer.at/api/ota.php. Its source_url is a OnePlus
# downloadCheck URL that redirects to a signed CDN link; the CDN needs the okhttp
# User-Agent and the userId header. Needs: curl, aria2c, python3.
set -eu
MODEL=${1:-NE2211}
VERSION=${2:-NE2211_16.0.3.530(EX01)}
OUT=${3:-$HOME/op10-backup}

entry=$(curl -fsS -A "Mozilla/5.0" "https://roms.danielspringer.at/api/ota.php?model=$MODEL" |
  python3 -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)
rel = d.get("releases", d) if isinstance(d, dict) else d
for r in rel:
    if r.get("version") == want:
        print(r["source_url"], r.get("md5", ""), r["ota_version"])
        break
else:
    sys.exit("version not found: " + want)
' "$VERSION")
set -- $entry
URL=$1 MD5=${2:-} OTA=$3
FILE=$(printf '%s' "$VERSION" | tr -d '()' | tr ' ' '_')_full.zip

mkdir -p "$OUT"
echo "ota_version $OTA -> $OUT/$FILE"
aria2c -c -x16 -s16 -k4M --console-log-level=warn \
  --header='User-Agent: okhttp/3.12.12' --header='userId: oplus-ota|16002018' \
  -d "$OUT" -o "$FILE" "$URL"

if [ -n "$MD5" ]; then
  got=$(md5 -q "$OUT/$FILE" 2>/dev/null || md5sum "$OUT/$FILE" | cut -d' ' -f1)
  [ "$got" = "$MD5" ] && echo "MD5 OK $MD5" || { echo "MD5 MISMATCH: $got != $MD5"; exit 1; }
fi
