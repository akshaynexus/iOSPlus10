#!/bin/sh
# Download and check the upstream sources for the SSH userland (docs/usb-network.md).
#   userland/ssh/fetch.sh        (in tmux: scripts/bg.sh ssh-fetch userland/ssh/fetch.sh)
# Each tarball goes into its own folder out/ssh/dl/<name>/ and is unpacked into out/ssh/src/<name>/.
# The SHA-256 values below are pinned. dropbear also has a signed SHA256SUM.asc: if gpg is
# installed, the signature is checked against the release key from the same site (key not
# independently certified). A mismatch stops the script; nothing is unpacked then.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$REPO/out/ssh
DROPBEAR_V=2026.94
DROPBEAR_SHA=e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81
DASH_V=0.5.13.5
DASH_SHA=40090101a2a491f13e901d3d48e90414f26634628b9bfff35ff540363c227a7d
TOYBOX_V=0.8.15
TOYBOX_SHA=44e2bab43dfe2c171743297631ce558c6d9ed38b87a66fd751cef617574b375e

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

# get NAME FILE URL SHA256
get() {
  d=$W/dl/$1; mkdir -p "$d"
  [ -f "$d/$2" ] || curl -fL --retry 3 -o "$d/$2.part" "$3" && { [ -f "$d/$2" ] || mv "$d/$2.part" "$d/$2"; }
  got=$(sha256 "$d/$2")
  if [ "$got" != "$4" ]; then echo "$2: SHA-256 $got, expected $4" >&2; exit 1; fi
  echo "$2: SHA-256 ok ($4)"
}

get dropbear dropbear-$DROPBEAR_V.tar.bz2 https://matt.ucc.asn.au/dropbear/releases/dropbear-$DROPBEAR_V.tar.bz2 $DROPBEAR_SHA
get dash dash-$DASH_V.tar.gz http://gondor.apana.org.au/~herbert/dash/files/dash-$DASH_V.tar.gz $DASH_SHA
get toybox toybox-$TOYBOX_V.tar.gz https://landley.net/toybox/downloads/toybox-$TOYBOX_V.tar.gz $TOYBOX_SHA

if command -v gpg >/dev/null; then
  d=$W/dl/dropbear
  curl -fsSL -o "$d/SHA256SUM.asc" https://matt.ucc.asn.au/dropbear/releases/SHA256SUM.asc
  curl -fsSL -o "$d/dropbear-key-2015.asc" https://matt.ucc.asn.au/dropbear/releases/dropbear-key-2015.asc
  G=$d/gnupg; mkdir -p "$G"; chmod 700 "$G"
  gpg --homedir "$G" --batch --quiet --import "$d/dropbear-key-2015.asc" 2>/dev/null
  if gpg --homedir "$G" --batch --verify "$d/SHA256SUM.asc" 2>/dev/null &&
     grep -q "$DROPBEAR_SHA.*dropbear-$DROPBEAR_V.tar.bz2" "$d/SHA256SUM.asc"; then
    echo "dropbear: SHA256SUM.asc signature good and lists the pinned hash"
  else
    echo "dropbear: SHA256SUM.asc signature or hash check FAILED" >&2; exit 1
  fi
else
  echo "dropbear: gpg not installed, signature not checked (pinned SHA-256 only)"
fi

for n in dropbear-$DROPBEAR_V:dropbear-$DROPBEAR_V.tar.bz2 dash-$DASH_V:dash-$DASH_V.tar.gz toybox-$TOYBOX_V:toybox-$TOYBOX_V.tar.gz; do
  dir=${n%%:*}; tb=${n#*:}; name=${dir%%-*}
  s=$W/src/$name
  if [ -d "$s/$dir" ]; then echo "$dir: already unpacked"; continue; fi
  mkdir -p "$s" && tar -xf "$W/dl/$name/$tb" -C "$s"
  echo "$dir: unpacked to out/ssh/src/$name/$dir"
done
