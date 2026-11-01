#!/bin/sh
# Entry point for the iOS 26 root build (root track): the Metal stack and the compositor on Metal, in a mounted, writable Mi A3 23F84 root. Replaces scripts/laurel/root-add-metal.sh on that path.
#   METAL26=0                                   skips, one line
#   sudo scripts/laurel/root-add-metal-ios26.sh MOUNTED_ROOT
# Input: out/ios26/metal/stage (scripts/laurel/ios26-metal-build.sh; check: scripts/ios26/abi-check.py). Writes:
#   /System/Library/Extensions/NegroniMetal.bundle/{NegroniMetal,Info.plist,libvulkan_freedreno.dylib,clients,clients.local}   Metal.framework reads this folder [V 23F84 getMetalPluginClassForService]
#   /usr/local/bin/{vkprobe,metalprobe,mslprobe,m2vtest,carenderprobe,layerprobe}
#   /private/var/db/negronimetal/{clients,env,cache/,strikes/,metal.log,build.txt}
# Clients: "*" minus four (below), backboardd included: 23F84 has no GL path (CA::WindowServer::AccelServer::renderer is Metal or nothing). So no gate job (iOS 16's laurel-metal-gate): a gate that widens the list after a test comes too late
# for backboardd, and launchd.plist is signed here (launchd.plist.sig), so no job goes in without the kernel track's trust work. The self-check is the plug-in's (device open + self-test at each start; one LAUREL METAL26 line).
# No GL wrapper: /usr/libexec/backboardd stays Apple's (the lowered copy). Kill switches: boot-arg negronimetal=0, file /private/var/db/negronimetal/off; both mean no renderer in backboardd (phone reachable, screen stays).
# METAL_ENV="KEY=VALUE..." lines added to the env file. Kernel needs: docs/laurel_sprout/ios26-metal.md section 7.
set -eu
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=${METAL_STAGE:-$REPO/out/ios26/metal/stage}
B=$S/System/Library/Extensions/NegroniMetal.bundle
if [ "${METAL26:-1}" = 0 ]; then
  echo "laurel-root: metal26: off: METAL26=0: no compositor on this root"; exit 0
fi
for f in "$B/NegroniMetal" "$B/libvulkan_freedreno.dylib" "$B/Info.plist"; do
  [ -f "$f" ] || { echo "laurel-root: metal26: off: no ${f#$REPO/} (scripts/laurel/ios26-metal-build.sh): no compositor on this root"; exit 1; }
done
[ -d "$R/System/Library/Extensions" ] && [ -f "$R/usr/libexec/backboardd" ] || { echo "laurel-root: metal26: off: $R does not look like an iOS root"; exit 1; }
python3 -I "$REPO/scripts/ios26/abi-check.py" "$S" > /dev/null || { echo "laurel-root: metal26: off: the stage fails scripts/ios26/abi-check.py"; exit 1; }
METAL_CLIENTS="$CLIENTS" METAL=1 PLUGIN_NAME=NegroniMetal METAL_STAGE=$S sh "$REPO/scripts/metal/root-add-metal.sh" "$R"
D=$R/private/var/db/negronimetal
# All of iOS but four processes with a CPU path on 23F84 (IOS-26-Hot d249939 --mtl2-clients, reported on an A640: RenderBox _RB4 render targets; cameracaptured): less GPU work and memory on the A610. METAL_CLIENTS=... replaces it.
CLIENTS=${METAL_CLIENTS:-"* -chronod -cameracaptured -WidgetRenderer_Default -PosterBoard"}
{
  echo "# Processes that get the NegroniMetal device, iOS 26 root (scripts/laurel/root-add-metal-ios26.sh). Every process: the compositor has no GL path on 23F84."
  echo "$CLIENTS"
} > "$D/clients"
printf '%s\n' "$CLIENTS" > "$R/System/Library/Extensions/NegroniMetal.bundle/clients.local"
chmod 644 "$D/clients" "$R/System/Library/Extensions/NegroniMetal.bundle/clients.local"
{
  echo "# KEY=VALUE lines for every Metal process (scripts/laurel/root-add-metal-ios26.sh)"
  # a slower CPU than iOS 16's boot: the device open with its self-test gets more time; a refused device is no renderer here, so one bad start does not end it
  echo "NEGRONIMETAL_OPEN_MS=60000"
  echo "NEGRONIMETAL_STRIKE_LIMIT=6"
  if [ -n "${METAL_ENV:-}" ]; then printf '%s\n' "$METAL_ENV"; fi
} > "$D/env"
chmod 644 "$D/env"
# CA reads these once: a first boot must already pick 8-bit BGRA, no compressed framebuffer (IOS-26-Hot, wave 6: BGRA from boot 1). The plug-in sets them too, at its device open, which can be late [I].
python3 -I - "$R" <<'PY'
import os, plistlib, sys
root = sys.argv[1]
for home in ("private/var/mobile", "private/var/root"):
    d = os.path.join(root, home, "Library/Preferences")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "com.apple.backboardd.plist")
    v = {}
    if os.path.exists(p):
        with open(p, "rb") as f:
            v = plistlib.load(f)
    v.update({"CAEnableDeepFramebuffer": False, "CAEnableFramebufferCompression": False, "CAEnableIOSurfaceCompression": False})
    with open(p, "wb") as f:
        plistlib.dump(v, f, fmt=plistlib.FMT_BINARY)
print("laurel-root: metal26: CAEnable* false in com.apple.backboardd")
PY
# Extensions with a Metal device: as on iOS 16, every extension point at least 64 MiB, posters 128 (jetsam file of this donor: com.apple.jetsamproperties.N104.plist [V])
for j in "$R"/System/Library/LaunchDaemons/com.apple.jetsamproperties.*.plist; do
  [ -f "$j" ] || continue
  echo "laurel-root: metal26: $(python3 -I "$REPO/scripts/ios16/jetsam_widgets.py" --extensions "${METAL_EXT_MB:-64}" --posters "${METAL_POSTER_MB:-128}" "$j")"
done
{
  echo "# laurel_sprout iOS 26 Metal stage, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (cd "$S" && find . -type f -perm -u+x ! -name '*.sh' | sort | while read -r f; do
     printf '%s %s\n' "$(sha256sum "$f" | cut -c1-16)" "${f#.}"; done)
} > "$D/build.txt"
chmod 644 "$D/build.txt"
echo "laurel-root: metal26: on: NegroniMetal.bundle (Turnip a610 + metal2vulkan), clients $CLIENTS, compositor on Metal, $(grep -c / "$D/build.txt") binaries, no GL fallback on 23F84"
