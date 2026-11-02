# The inputs of the Mu FD of the Mi A3, in one place. mu-build.sh writes this hash beside the FD (.fd.patches), uefi-image.sh compares it before a menu image: an FD of other inputs has older slot code,
# and its menu can say "unknown action". Sourced with REPO set (scripts/lib/env.sh).
# Inputs: all patches, also patches/laurel/mu/late/ (MU_RAM_LAYOUT=late), the three slot files that mu-build.sh copies in (tools/laurel-slot), and the commits of the Mu fork, UniXNU and its DarwinBoot.
_laurel_mu_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
laurel_mu_files() {
  for _f in "$REPO"/patches/laurel/mu/*.patch "$REPO"/patches/laurel/mu/late/*.patch "$REPO/tools/laurel-slot/laurel_slot.c" "$REPO/tools/laurel-slot/laurel_slot.h" "$REPO/tools/laurel-slot/uefi/LaurelSlot.c"; do
    # a pattern with no match stays as the text: it counts as absent, in both places
    if [ -f "$_f" ]; then printf '%s %s\n' "${_f#"$REPO"/}" "$(_laurel_mu_sha < "$_f")"; else printf '%s absent\n' "${_f#"$REPO"/}"; fi
  done
}
_laurel_mu_hash() { { laurel_mu_files; printf 'pins %s\n' "$*"; } | _laurel_mu_sha; }
# What a build used: the commits its trees are at. MU UNIXNU: the trees, as MU_TREE and UNIXNU_TREE of mu-build.sh.
laurel_mu_inputs_built() {
  _laurel_mu_hash "$(git -C "$1" rev-parse HEAD 2>/dev/null || echo none)" "$(git -C "$2" rev-parse HEAD 2>/dev/null || echo none)" "$(git -C "$2/drivers/DarwinBoot" rev-parse HEAD 2>/dev/null || echo none)"
}
# What this tree asks for: the pins of the superproject, and the DarwinBoot pin of that UniXNU commit. UNIXNU: a tree that has that commit's objects. So a `git pull` that moves a pin makes an older FD stale, also before a submodule update.
laurel_mu_inputs_wanted() {
  _pm=$(git -C "$REPO" rev-parse HEAD:external/Mu-Silicium-negroni 2>/dev/null || echo none)
  _pu=$(git -C "$REPO" rev-parse HEAD:external/UniXNU 2>/dev/null || echo none)
  _pd=$(git -C "$1" rev-parse "$_pu:drivers/DarwinBoot" 2>/dev/null || echo none)
  _laurel_mu_hash "$_pm" "$_pu" "$_pd"
}
