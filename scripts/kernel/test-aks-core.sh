#!/bin/sh
# Host unit test of the software keybag core of the AppleKeyStore stand-in (passcode hash,
# compare, bag blob round trip, DER integers, the blob search in a keybag plist). macOS and
# Linux (needs cc; Linux also OpenSSL headers, e.g. libssl-dev; python3 for the plist check).
# Quick, foreground is fine.
#   scripts/kernel/test-aks-core.sh [PATCH]
#     PATCH  default patches/xnu/0221-negroni-aks-passcode.patch
# The header iokit/Kernel/arm/NegroniKeyStoreCore.h is taken from the patch (it is a new file
# there), so the test checks exactly the code that goes into the kernel.
# Test source: tools/aks-core-test/aks_core_test.c. Build products: out/aks-core-test/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/xnu/0221-negroni-aks-passcode.patch}
D=$OUT/aks-core-test
rm -rf "$D"
mkdir -p "$D"
# the new file's lines: after its "+++ b/...NegroniKeyStoreCore.h" header, every "+" line, until the next "diff"
awk '/^\+\+\+ b\/iokit\/Kernel\/arm\/NegroniKeyStoreCore\.h$/ {p=1; next}
     p && /^diff --git / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/NegroniKeyStoreCore.h"
[ -s "$D/NegroniKeyStoreCore.h" ] || { echo "no NegroniKeyStoreCore.h in $PATCH" >&2; exit 1; }
case "$(uname -s)" in
Darwin) libs="" ;;
*)      libs="-lcrypto" ;;
esac
build() { ${CC:-cc} -O2 -g -Wall -Wextra -Wno-deprecated-declarations "$@" -I"$D" -o "$D/aks_core_test" \
  "$REPO/tools/aks-core-test/aks_core_test.c" $libs; }
# AddressSanitizer + UBSan when the compiler has them (bounds checks of the file and DER parsers)
build -fsanitize=address,undefined -fno-sanitize-recover=all 2>/dev/null || build
"$D/aks_core_test"
# real property lists (binary as keybagd writes them, XML as root-macos.sh writes them) around a blob
if command -v python3 >/dev/null 2>&1; then
  "$D/aks_core_test" --blob "$D/blob.bin"
  python3 -I - "$D" <<'PY'
import plistlib, sys
d = sys.argv[1]
blob = open(d + "/blob.bin", "rb").read()
for name, fmt in (("bin", plistlib.FMT_BINARY), ("xml", plistlib.FMT_XML)):
    with open("%s/systembag-%s.kb" % (d, name), "wb") as f:
        plistlib.dump({"KeyBagKeys": blob, "KeyBagVersion": 4}, f, fmt=fmt)
    with open("%s/sweet-%s.kb" % (d, name), "wb") as f:
        plistlib.dump({"KeyBagKeys": b"SWEET"}, f, fmt=fmt)
PY
  for k in bin xml; do
    "$D/aks_core_test" --find "$D/systembag-$k.kb" || { echo "FAIL: no blob found in the $k plist" >&2; exit 1; }
    if "$D/aks_core_test" --find "$D/sweet-$k.kb"; then echo "FAIL: blob found in the SWEET $k plist" >&2; exit 1; fi
  done
  echo "plist: blob found in binary and XML plists (python3 plistlib), SWEET plists give no passcode"
fi
