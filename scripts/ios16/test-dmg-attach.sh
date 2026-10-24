#!/bin/bash
# Diagnostic (macOS): attach the three iOS DMGs read-only exactly as root-macos.sh does, list the top
# of each, then detach. No sudo needed. Mount points: out/dmg-test/{os,sysos,appos} (git-ignored).
#   scripts/ios16/test-dmg-attach.sh
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
D=${APPLE:-$HOME/op10-apple}/20H392
W=$OUT/dmg-test
while read -r dmg name kind; do
  extra=()
  [ "$kind" = raw ] && extra=(-imagekey diskimage-class=CRawDiskImage)
  mkdir -p "$W/$name"
  plist=$(hdiutil attach -readonly -nobrowse -noverify -noautoopen ${extra[@]+"${extra[@]}"} \
          -mountpoint "$W/$name" -plist "$D/$dmg")
  dev=$(printf '%s' "$plist" | python3 -c 'import plistlib,sys; e=plistlib.loads(sys.stdin.buffer.read())["system-entities"]; print(min(x["dev-entry"] for x in e))')
  echo "$name: $dev | $(ls "$W/$name" | head -8 | tr '\n' ' ')"
  hdiutil detach -force "$dev" >/dev/null
done <<'EOF'
087-86698-044.dmg os udif
087-86593-047.dmg sysos raw
087-86715-047.dmg appos raw
EOF
