#!/bin/sh
# Copy userland/negronigl/ into the Mesa tree as src/gallium/targets/negronigl (rsync keeps mtimes,
# so ninja rebuilds only what changed) and our xf86drm.h into src/redwood-drm/.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
[ -d "$MESA_SRC/src/gallium" ] || { echo "no Mesa tree: run scripts/gpu/mesa-fetch.sh" >&2; exit 1; }
mkdir -p "$MESA_SRC/src/gallium/targets/negronigl"
rsync -a --delete --exclude mesa-patches --exclude '*.md' "$NGL/" "$MESA_SRC/src/gallium/targets/negronigl/"
cmp -s "$NGL/drm/xf86drm.h" "$MESA_SRC/src/redwood-drm/xf86drm.h" ||
  cp "$NGL/drm/xf86drm.h" "$MESA_SRC/src/redwood-drm/xf86drm.h"
for f in negroni_drm.c negroni_drm.h ngl_abi.h; do
  cmp -s "$NGL/drm/$f" "$MESA_SRC/src/redwood-drm/$f" || cp "$NGL/drm/$f" "$MESA_SRC/src/redwood-drm/$f"
done
cmp -s "$NGL/log.c" "$MESA_SRC/src/redwood-drm/log.c" || cp "$NGL/log.c" "$MESA_SRC/src/redwood-drm/log.c"
