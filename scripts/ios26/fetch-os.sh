#!/bin/bash
# Get the iOS 26 donor OS images for the root build (no full IPSW download): the OS volume (7.2-7.4 GB AEA), the
# SystemOS cryptex (2.0 GB AEA), the AppOS cryptex (14 MB, plain), their trust caches and root hashes.
# AEA keys come from Apple's public key service (ipsw fw aea --key reads com.apple.wkms.fcs-key-url).
#   scripts/bg.sh ios26-os scripts/ios26/fetch-os.sh                    negroni donor (default DEV=d421ap, iPhone12,3)
#   scripts/bg.sh ios26-os env DEV=n104ap scripts/ios26/fetch-os.sh     Mi A3 donor (iPhone12,1). Use env: tmux does not pass the caller's DEV
# Disk: needs NEED_GIB free (default 30); the script refuses with less.
# Output: $APPLE/ios26/$BUILD-$DEV/os/ (never in git). macOS and Linux. A file that is already there is not fetched again.
# Env: DEV, the names of scripts/ios26/donor.sh, OUTDIR, NEED_GIB, KEEP_AEA=1.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
. "$(dirname "$0")/donor.sh"
D=${OUTDIR:-$APPLE/ios26/$BUILD-$DEV/os}
NEED_GIB=${NEED_GIB:-30}
mkdir -p "$D"
free=$(free_gib "$D")
if [ "$free" -lt "$NEED_GIB" ]; then
  echo "only $free GiB free, need $NEED_GIB GiB (OS AEA + decrypted image + SystemOS): not started" >&2; exit 1
fi
need_ipsw
# Members from BuildManifest (23F84): OS, Cryptex1,SystemOS, Cryptex1,AppOS and their trust caches / root hashes.
members=()
want() { [ -e "$D/$(basename "$1")" ] || [ -e "$D/$(basename "${1%.aea}")" ] || members+=("$1"); }
want "$OS_AEA"; want "$SYSOS"; want "$APPOS"
for m in "$OS_AEA" "$SYSOS" "$APPOS"; do
  want "Firmware/$m.trustcache"; want "Firmware/$m.root_hash"
done
[ ${#members[@]} = 0 ] || "$OUT/bin/op10tool" ipsw-get -j 16 "$IPSW_URL" "$D" "${members[@]}"
for a in "$D/$OS_AEA" "$D/$SYSOS"; do
  [ -f "$a" ] || continue
  aea_decrypt "$a" "$D"
  [ "${KEEP_AEA:-0}" = 1 ] || rm -f "$a"  # keep only the decrypted image (disk)
done
(cd "$D" && sha256_list ./*.dmg ./*.trustcache ./*.root_hash > SHA256SUMS)
ls -l "$D"
cat "$D/SHA256SUMS"
