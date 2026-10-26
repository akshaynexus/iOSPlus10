#!/bin/sh
# Fetch Mesa (pinned release, SHA-256 checked) and make the patched source tree out/gpu/mesa-VERSION:
#   1. the freedreno-on-Darwin patches of HackiOS (scripts/gpu/env.sh: HACKIOS_COMMIT, HACKIOS_PATCHES),
#   2. our patches userland/negronigl/mesa-patches/*.patch (in name order), then the Turnip-on-Darwin
#      patch userland/turnip/mesa-patches/0001-turnip-darwin.patch (TURNIP_DARWIN_PATCH, shared with
#      scripts/gpu/turnip-build.sh: one copy of those changes, the GL tree does not build Turnip),
#   3. src/redwood-drm/: the libdrm header freedreno is built against = our
#      userland/negronigl/drm/xf86drm.h. The functions themselves are in negronigl (drm/negroni_drm.c).
# Also makes the Python environment out/gpu/venv (meson, mako, pyyaml, packaging) with uv.
# The tree is made again from the archive each time (about 20 s), so it always matches the patches.
#   scripts/gpu/mesa-fetch.sh            (long: run it with scripts/bg.sh gpu-fetch ...)
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
mkdir -p "$DL" "$G"

# Python tools (uv; fall back to python3 -m venv + pip where uv is missing)
if [ ! -x "$VENV/bin/meson" ]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv -q --allow-existing "$VENV"
    VIRTUAL_ENV=$VENV uv pip install -q "meson==1.7.2" mako pyyaml packaging
  else
    python3 -m venv "$VENV"
    "$VENV/bin/pip" -q install "meson==1.7.2" mako pyyaml packaging
  fi
fi
"$VENV/bin/meson" --version

A=$DL/mesa-$MESA_VERSION.tar.xz
if [ ! -f "$A" ] || ! echo "$MESA_SHA256  $A" | shasum -a 256 -c - >/dev/null 2>&1; then
  rm -f "$A.part"
  curl -L --fail --retry 3 -o "$A.part" "$MESA_URL"
  echo "$MESA_SHA256  $A.part" | shasum -a 256 -c -
  mv "$A.part" "$A"
fi
echo "mesa $MESA_VERSION: sha256 ok"

rm -rf "$MESA_SRC" "$G/extract"
mkdir -p "$G/extract"
tar -xJf "$A" -C "$G/extract"
mv "$G/extract/mesa-$MESA_VERSION" "$MESA_SRC"
rmdir "$G/extract"

git -C "$HACKIOS" cat-file -e "$HACKIOS_COMMIT^{commit}" ||
  { echo "external/hackios-xnu-userland lacks $HACKIOS_COMMIT (git submodule update --init)" >&2; exit 1; }
for p in $HACKIOS_PATCHES; do
  echo "patch hackios $p.patch"
  git -C "$HACKIOS" show "$HACKIOS_COMMIT:tools/mesa/$p.patch" |
    patch -s --no-backup-if-mismatch -d "$MESA_SRC" -p1
done
for p in "$NGL"/mesa-patches/*.patch "$TURNIP_DARWIN_PATCH"; do
  [ -f "$p" ] || continue
  echo "patch $(basename "$(dirname "$(dirname "$p")")") $(basename "$p")"
  patch -s --no-backup-if-mismatch -d "$MESA_SRC" -p1 < "$p"
done
find "$MESA_SRC" -name '*.orig' -delete

# freedreno-darwin.patch builds src/redwood-drm/redwood_drm.c into libfreedreno_drm and puts
# src/redwood-drm on the include path. Ours: the header only; the .c is empty on purpose.
mkdir -p "$MESA_SRC/src/redwood-drm"
cp "$NGL/drm/xf86drm.h" "$MESA_SRC/src/redwood-drm/xf86drm.h"
cat > "$MESA_SRC/src/redwood-drm/redwood_drm.c" <<'EOF'
/* negronigl: the libdrm functions are in userland/negronigl/drm/negroni_drm.c, linked into the dylib. */
typedef int negronigl_redwood_drm_placeholder;
EOF

{
  echo "mesa $MESA_VERSION $MESA_SHA256"
  echo "hackios $HACKIOS_COMMIT: $HACKIOS_PATCHES"
  for p in "$NGL"/mesa-patches/*.patch "$TURNIP_DARWIN_PATCH"; do
    [ -f "$p" ] && echo "$(basename "$(dirname "$(dirname "$p")")") $(basename "$p") $(shasum -a 256 "$p" | cut -c1-16)"
  done
  echo "xf86drm.h $(shasum -a 256 "$NGL/drm/xf86drm.h" | cut -c1-16)"
} > "$MESA_SRC/NEGRONIGL-SOURCE"
cat "$MESA_SRC/NEGRONIGL-SOURCE"
echo "ready: $MESA_SRC"
