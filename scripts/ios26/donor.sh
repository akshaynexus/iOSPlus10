# iOS 26 donor table, sourced by fetch-donor.sh, fetch-sysos.sh, fetch-os.sh. Takes $DEV, sets the IPSW and member names.
#   DEV=n104ap : Mi A3 (laurel_sprout). iPhone 11, iPhone12,1, A13, owner decision, docs/laurel_sprout/ios26-userland.md.
#   DEV=d421ap : negroni, default, unchanged (iPhone 11 Pro, iPhone12,3, docs/future-ios26.md). d431ap: same IPSW.
# Each name can be overridden from the environment. IPSW_URL, IPSW_SHA256 and IPSW_SIZE are for the whole IPSW (ipsw.me).
DEV=${DEV:-d421ap}
case "$DEV" in
n104ap)
  IPSW_URL=${IPSW_URL:-https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-26331/A86BA9CA-4666-4AD9-BF0D-14700375EF03/iPhone12,1_26.5.2_23F84_Restore.ipsw}
  IPSW_SHA256=${IPSW_SHA256:-174dc7eae48af470563db67c9ae380ceb34e8e3e91a327371fe481fef53f6cca}
  OS_AEA=${OS_AEA:-094-55773-107.dmg.aea}
  SYSOS=${SYSOS:-094-56417-109.dmg.aea}
  KC=${KC:-kernelcache.release.iphone12b} ;;
j171ap)
  # Not a donor: iPad 7th gen, A10, newest plain arm64 firmware (fallback measured in docs/laurel_sprout/ios26-userland.md).
  IPSW_URL=${IPSW_URL:-https://updates.cdn-apple.com/2026WinterFCS/cae87706-e21d-4989-a880-3210b045ef28/iPad_10.2_18.7.11_22H384_Restore.ipsw}
  IPSW_SHA256=${IPSW_SHA256:-579973d0a5bbbe6b8c47ffaa8ccf05b30ace59f984d885c0675074d1f877b571}
  OS_AEA=${OS_AEA:-094-32804-044.dmg.aea}
  SYSOS=${SYSOS:-094-33089-044.dmg.aea}
  APPOS=${APPOS:-094-32850-044.dmg}
  KC=${KC:-kernelcache.release.ipad7c} ;;
d421ap|d431ap)
  IPSW_URL=${IPSW_URL:-https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25381/6ABE5EEB-511D-4DF4-AB43-FE86D0A7718A/iPhone12,3,iPhone12,5_26.5.2_23F84_Restore.ipsw}
  IPSW_SHA256=${IPSW_SHA256:-49714db41d2e590e7b1fda55c090a53af5fc9d3293352449e879a664f8c0602b}
  OS_AEA=${OS_AEA:-094-55352-108.dmg.aea}
  SYSOS=${SYSOS:-094-55541-109.dmg.aea}
  KC=${KC:-kernelcache.release.iphone12} ;;
*) echo "donor.sh: unknown DEV=$DEV (n104ap, j171ap, d421ap, d431ap)" >&2; exit 1 ;;
esac
APPOS=${APPOS:-094-54871-112.dmg}
AGX=${AGX:-Firmware/agx/armfw_g12p.im4p}
BUILD=${BUILD:-$(basename "$IPSW_URL" | sed 's/.*_\([0-9A-Z]*\)_Restore\.ipsw/\1/')}
APPLE=${APPLE:-$HOME/op10-apple}
PATH=$OUT/bin:$PATH                     # scripts/setup/get-ipsw-cli.sh puts ipsw here
sha256_list() { # FILE... : SHA-256 lines on stdout, macOS and Linux
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
free_gib() { # DIR : free GiB, macOS and Linux
  df -k "$1" | awk 'NR==2 {print int($4 / 1048576)}'
}
need_ipsw() {
  command -v ipsw >/dev/null 2>&1 || { echo "needs the ipsw CLI: scripts/setup/get-ipsw-cli.sh" >&2; exit 1; }
}
aea_decrypt() { # FILE.aea OUTDIR : fetch the key from Apple's public key service (header com.apple.wkms.fcs-key-url), decrypt
  ipsw fw aea --key "$1" > "$1.key"
  ipsw fw aea --key-val "$(tail -n 1 "$1.key" | awk '{print $NF}' | sed 's/^base64://')" -o "$2" "$1"
}
