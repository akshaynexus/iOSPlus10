#!/bin/sh
# Prepare external/Mu-Silicium-negroni for a build: shallow submodules at the pinned commits,
# then the negroni patches (patches/apply.sh). Runs on the host (macOS or Linux), needs git.
#
# Special case: the fork pins Silicium-ACPI to 5d26c38, a commit that only existed in the
# author's local tree. README-negroni.md gives the real base, 2d465ad, plus
# patches/silicium-acpi-negroni.patch.
# All nested submodules (also OpenSSL's krb5, wycheproof, ...) are fetched here with --depth 1:
# otherwise the Mu build's setup step clones them at full depth inside the container (slow).
# This step cleans the Binaries submodule, so run scripts/uefi/prepare.sh after it.
set -eu
. "$(dirname "$0")/../lib/env.sh"
MU=$EXT/Mu-Silicium-negroni
cd "$MU"

# path -> commit (the superproject's gitlink, except Silicium-ACPI)
pin() {
  case "$1" in
  Silicium-ACPI) echo 2d465ad77c25de908f0ec7bdfcb57f865b61233c ;;
  *) git ls-tree HEAD "$1" | awk '{print $3}' ;;
  esac
}

git submodule init >/dev/null
for p in $(git config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'); do
  c=$(pin "$p")
  url=$(git config -f .gitmodules "submodule.$(git config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk -v p="$p" '$2==p{sub(/^submodule\./,"",$1); sub(/\.path$/,"",$1); print $1}').url")
  [ -e "$p/.git" ] || git clone -q --no-checkout --depth 1 "$url" "$p" 2>/dev/null || true
  if [ "$(git -C "$p" rev-parse HEAD 2>/dev/null)" != "$c" ]; then
    git -C "$p" fetch -q --depth 1 origin "$c"
    git -C "$p" checkout -q --force "$c"
  fi
  # restore pristine sources before patching (re-runnable)
  git -C "$p" reset -q --hard "$c"
  git -C "$p" clean -qfd
  echo "$p @ $(git -C "$p" rev-parse --short HEAD)"
done

# Repair nested submodules left half-cloned by an interrupted run (no valid HEAD): deinit them and
# drop their git data, so the update below clones them again.
repair() {
  parent=$1
  [ -f "$parent/.gitmodules" ] || return 0
  gd=$(git -C "$parent" rev-parse --absolute-git-dir)
  git config -f "$parent/.gitmodules" --get-regexp 'submodule\..*\.path' | awk '{print $2}' | while read -r sp; do
    if [ -e "$parent/$sp/.git" ] && ! git -C "$parent/$sp" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      echo "repairing broken nested submodule $parent/$sp"
      git -C "$parent" submodule deinit -q -f -- "$sp" || true
      rm -rf "${gd:?}/modules/$sp" "${parent:?}/$sp"
    fi
  done
}

# nested submodules (BaseTools brotli, MipiSysT, cmocka, OpenSSL test suites, ...)
for p in Mu_Basecore Common/Mu Common/Mu_OEM_Sample Common/Features/mu_feature_dfci Common/Features/mu_feature_config \
         Silicon/Silicium/OpensslPkg/Library/OpensslLib/openssl; do
  repair "$p"
  git -C "$p" submodule update -q --init --recursive --depth 1 --jobs "$NPROC" --checkout --force
done

# The fork's patches to its submodules (patches/apply.sh). Since fork commit 81f18229 Mu_Basecore points at
# akshaynexus/mu_basecore, which already holds mu_basecore-negroni.patch: a patch that reverse-applies is skipped.
for pt in patches/*.patch; do
  case "$pt" in *mu_basecore*) sub=Mu_Basecore ;; *silicium-acpi*) sub=Silicium-ACPI ;; *) echo "setup-mu: unknown patch target $pt" >&2; exit 1 ;; esac
  if git -C "$sub" apply --reverse --check "$PWD/$pt" 2>/dev/null; then echo "$sub: $(basename "$pt") already in $(git -C "$sub" rev-parse --short HEAD)"
  else git -C "$sub" apply "$PWD/$pt"; echo "$sub: $(basename "$pt") applied"; fi
done
