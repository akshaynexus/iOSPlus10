#!/bin/sh
# Get the blacktop `ipsw` CLI (MIT) into out/bin/ipsw. Used for AEA decrypt (scripts/ios26/fetch-*.sh) and shared-cache
# inspection on Linux and macOS. Pinned version + SHA-256 of the release archive, checked before unpacking.
#   scripts/bg.sh ipsw-cli scripts/setup/get-ipsw-cli.sh
# A newer version: set IPSW_VERSION, IPSW_SHA256 (from the release's checksums.txt).
set -eu
. "$(dirname "$0")/../lib/env.sh"
V=${IPSW_VERSION:-3.1.741}
case "$(uname -s)/$(uname -m)" in
Linux/x86_64)  A=ipsw_${V}_linux_x86_64.tar.gz ;;
Linux/aarch64) A=ipsw_${V}_linux_arm64.tar.gz ;;
Darwin/arm64)  A=ipsw_${V}_macOS_arm64.tar.gz ;;
Darwin/x86_64) A=ipsw_${V}_macOS_x86_64.tar.gz ;;
*) echo "no ipsw release for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "$OUT/bin" "$OUT/ipsw-cli"
T=$OUT/ipsw-cli
B=https://github.com/blacktop/ipsw/releases/download/v$V
curl -fsSL -o "$T/$A" "$B/$A"
curl -fsSL -o "$T/checksums.txt" "$B/checksums.txt"
want=${IPSW_SHA256:-$(awk -v a="$A" '$2==a{print $1}' "$T/checksums.txt")}
[ -n "$want" ] || { echo "no checksum for $A" >&2; exit 1; }
if command -v sha256sum >/dev/null; then got=$(sha256sum "$T/$A" | cut -d' ' -f1); else got=$(shasum -a 256 "$T/$A" | cut -d' ' -f1); fi
[ "$got" = "$want" ] || { echo "SHA-256 mismatch: $got != $want" >&2; exit 1; }
tar -xzf "$T/$A" -C "$T"
find "$T" -type f -name ipsw -exec cp {} "$OUT/bin/ipsw" \;
chmod +x "$OUT/bin/ipsw"
rm -f "$T/$A"
"$OUT/bin/ipsw" version
echo "ipsw $V sha256 $got"
