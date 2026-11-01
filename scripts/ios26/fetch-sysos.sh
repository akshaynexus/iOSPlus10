#!/bin/sh
# Get and decrypt the SystemOS cryptex of the iOS 26 donor IPSW (the dyld shared cache lives there).
#   scripts/ios26/fetch-sysos.sh              negroni donor (default DEV=d421ap)
#   DEV=n104ap scripts/ios26/fetch-sysos.sh   Mi A3 donor (iPhone12,1); under scripts/bg.sh use: env DEV=n104ap ...
# Run it with scripts/bg.sh: 2.0 GB download, 5.2 GB decrypted APFS image.
# Env: DEV, the names of scripts/ios26/donor.sh (IPSW_URL, SYSOS), OUTDIR (default $APPLE/ios26/23F84-sysos for negroni,
#      $APPLE/ios26/23F84-n104ap/os for n104ap), KEEP_AEA=1 keeps the encrypted file.
# iOS 26 OS and SystemOS images are Apple Encrypted Archives (AEA1). `ipsw fw aea --key` reads the
# fcs-key URL from the AEA header and fetches the key from Apple's server; `ipsw fw aea` then decrypts.
# Inspect: macOS hdiutil attach -readonly -nobrowse -mountpoint MNT IMG; Linux scripts/ios26/sysos-tree.sh (apfs-fuse, no root).
# The image is large: delete it after the audit; this script makes it again in about 5 minutes.
# Needs: out/bin/op10tool, the ipsw CLI (scripts/setup/get-ipsw-cli.sh). macOS and Linux.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$(dirname "$0")/donor.sh"
case "$DEV" in n104ap|j171ap) def=$APPLE/ios26/$BUILD-$DEV/os ;; *) def=$APPLE/ios26/$BUILD-sysos ;; esac
OUTDIR=${OUTDIR:-$def}
mkdir -p "$OUTDIR"
need_ipsw
[ "$(free_gib "$OUTDIR")" -ge 13 ] || { echo "need 13 GiB free in $OUTDIR (2 + 5.2 GiB + 5 GiB reserve)" >&2; exit 1; }
[ -f "$OUTDIR/$SYSOS" ] || "$OUT/bin/op10tool" ipsw-get -j 16 "$IPSW_URL" "$OUTDIR" "$SYSOS"
aea_decrypt "$OUTDIR/$SYSOS" "$OUTDIR"
[ "${KEEP_AEA:-0}" = 1 ] || rm -f "$OUTDIR/$SYSOS"
ls -l "$OUTDIR"
( cd "$OUTDIR" && sha256_list "${SYSOS%.aea}" > "SHA256SUMS-sysos" && cat SHA256SUMS-sysos )
