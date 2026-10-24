#!/bin/sh
# Prepare external/Mu-Silicium-negroni for a build: shallow submodules at the pinned commits,
# then the negroni patches (patches/apply.sh). Runs on the host (macOS or Linux), needs git.
#
# Special case: the fork pins Silicium-ACPI to 5d26c38, a commit that only existed in the
# author's local tree. README-negroni.md gives the real base, 2d465ad, plus
# patches/silicium-acpi-negroni.patch. OpenSSL is used without its own nested submodules.
set -eu
. "$(dirname "$0")/env.sh"
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

# nested submodules (BaseTools brotli, MipiSysT, cmocka, ...), not for OpenSSL
for p in Mu_Basecore Common/Mu Common/Mu_OEM_Sample Common/Features/mu_feature_dfci Common/Features/mu_feature_config; do
  git -C "$p" submodule update -q --init --recursive --depth 1 --jobs 8
done

sh patches/apply.sh
