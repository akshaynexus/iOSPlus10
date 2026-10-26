#!/bin/sh
# Get and decrypt the SystemOS cryptex of the iOS 26 donor IPSW (the dyld shared cache lives there).
#   scripts/ios26/fetch-sysos.sh        (run it with scripts/bg.sh: 2.0 GB download, 5.2 GB decrypted APFS image)
# Env: IPSW_URL, SYSOS (member name, default 094-55541-109.dmg.aea = iPhone12,3/12,5 23F84 SystemOS),
#      OUTDIR (default $APPLE/ios26/23F84-sysos), KEEP_AEA=1 keeps the encrypted file.
# iOS 26 OS and SystemOS images are Apple Encrypted Archives (AEA1). `ipsw fw aea --key` reads the
# fcs-key URL from the AEA header and fetches the key from Apple's server; `ipsw fw aea` then decrypts.
# Inspect (macOS): hdiutil attach -readonly -nobrowse -mountpoint MNT OUTDIR/<name>.dmg (Linux: apfs-fuse).
# The image is large: delete it after the audit; this script makes it again in about 5 minutes.
# Needs: out/bin/op10tool, the `ipsw` CLI (brew install blacktop/tap/ipsw). macOS and Linux.
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
URL=${IPSW_URL:-https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25381/6ABE5EEB-511D-4DF4-AB43-FE86D0A7718A/iPhone12,3,iPhone12,5_26.5.2_23F84_Restore.ipsw}
SYSOS=${SYSOS:-094-55541-109.dmg.aea}
OUTDIR=${OUTDIR:-$APPLE/ios26/23F84-sysos}
mkdir -p "$OUTDIR"
avail=$(df -k "$OUTDIR" | awk 'NR==2{print $4}')
[ "$avail" -gt $((13 * 1024 * 1024)) ] || { echo "need 13 GiB free in $OUTDIR (2 + 5.2 GiB + 5 GiB reserve)" >&2; exit 1; }
[ -f "$OUTDIR/$SYSOS" ] || "$OUT/bin/op10tool" ipsw-get -j 16 "$URL" "$OUTDIR" "$SYSOS"
ipsw fw aea --key "$OUTDIR/$SYSOS" > "$OUTDIR/$SYSOS.key"
ipsw fw aea --key-val "$(tail -n 1 "$OUTDIR/$SYSOS.key" | awk '{print $NF}' | sed 's/^base64://')" -o "$OUTDIR" "$OUTDIR/$SYSOS"
[ "${KEEP_AEA:-0}" = 1 ] || rm -f "$OUTDIR/$SYSOS"
ls -l "$OUTDIR"
( cd "$OUTDIR" && shasum -a 256 ./*.dmg > SHA256SUMS-sysos && cat SHA256SUMS-sysos )
