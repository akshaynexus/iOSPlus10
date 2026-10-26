#!/bin/sh
# Add the Metal path (NegroniMetal.bundle + probes + its config directory) to a mounted, writable iOS 16 root.
# Off unless METAL=1. Run as root (macOS or Linux) so that the files belong to root:wheel:
#   METAL=1 scripts/metal/root-add-metal.sh MOUNTED_ROOT
# Input: out/metal/stage from scripts/metal/build.sh. Installs:
#   /System/Library/Extensions/NegroniMetal.bundle   (the kernel's IOAcceleratorES names it: MetalPluginName)
#   /usr/local/bin/{vkprobe,metalprobe,m2vtest}      (the SSH test tools, scripts/metal/phone-test.sh)
#   /private/var/db/negronimetal/{clients,env,cache/,strikes/,metal.log}
#     clients: processes that get a device (default "*" = every process, owner 2026-10-27; XNUtils hot-toggles it)
#     off:     create it to disable the plugin for every process that can read /var/db (next process start);
#              /System/Library/Extensions/NegroniMetal.bundle/off reaches sandboxed apps too (NegroniMetal.mm)
# METAL_CLIENTS="metalprobe m2vtest backboardd SpringBoard" overrides the default clients list.
# Nothing here changes the kernel: without a MetalPluginName on IOAcceleratorES (patch 0201 has none), Metal never
# loads the bundle; metalprobe --bundle can still load it by hand (stage 1, docs/metal-plan.md).
set -eu
R=${1:?usage: METAL=1 $0 MOUNTED_ROOT}
if [ "${METAL:-0}" != 1 ]; then echo "metal: skipped (METAL=1 adds NegroniMetal.bundle + probes)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/metal/stage
NAME=${PLUGIN_NAME:-NegroniMetal}
[ -d "$R/System/Library/Extensions" ] || { echo "$R does not look like an iOS root" >&2; exit 1; }
[ -d "$S/usr/local/bin" ] || { echo "no $S: run scripts/metal/build.sh first" >&2; exit 1; }
root=1
[ "$(id -u)" = 0 ] || { root=0; echo "warning: not root; owners stay as they are (test runs only)" >&2; }
own() { [ $root = 1 ] && chown "$@" || true; }

# 1. the bundle
if [ -d "$S/System/Library/Extensions/$NAME.bundle" ]; then
  B=$R/System/Library/Extensions/$NAME.bundle
  rm -rf "$B.new"
  cp -R "$S/System/Library/Extensions/$NAME.bundle" "$B.new"
  rm -rf "$B" && mv "$B.new" "$B"
  own -R 0:0 "$B"
  chmod -R u=rwX,go=rX "$B"
  [ -f "$B/libvulkan_freedreno.dylib" ] || echo "warning: $NAME.bundle has no libvulkan_freedreno.dylib (no Turnip yet)" >&2
  echo "metal: installed /System/Library/Extensions/$NAME.bundle"
else
  echo "warning: no plugin in $S (bridge not built): probes only" >&2
fi

# 2. probes
mkdir -p "$R/usr/local/bin"
for f in "$S"/usr/local/bin/*; do
  cp "$f" "$R/usr/local/bin/"
  own 0:0 "$R/usr/local/bin/$(basename "$f")"
  chmod 755 "$R/usr/local/bin/$(basename "$f")"
done
echo "metal: installed /usr/local/bin/{$(ls "$S/usr/local/bin" | tr '\n' ',' | sed 's/,$//')}"

# 3. config + cache directory. The plugin runs in backboardd/SpringBoard (user mobile) too: cache/ and strikes/
#    are world-writable with the sticky bit, metal.log is mode 666.
D=$R/private/var/db/negronimetal
mkdir -p "$D/cache" "$D/strikes"
if [ -n "${METAL_CLIENTS:-}" ] || [ ! -f "$D/clients" ]; then
  cp "$S/var/db/negronimetal/clients" "$D/clients"
  [ -n "${METAL_CLIENTS:-}" ] && printf '%s\n' "$METAL_CLIENTS" >> "$D/clients"
fi
[ -f "$D/env" ] || printf '# KEY=VALUE lines for every Metal process (e.g. TU_DEBUG=startup, MESA_LOG_FILE=...)\n' > "$D/env"
: >> "$D/metal.log"
own -R 0:0 "$D"
chmod 755 "$D"
chmod 1777 "$D/cache" "$D/strikes"
chmod 644 "$D/clients" "$D/env"
chmod 666 "$D/metal.log"
echo "metal: clients = $(grep -v '^#' "$D/clients" | tr '\n' ' ')"
