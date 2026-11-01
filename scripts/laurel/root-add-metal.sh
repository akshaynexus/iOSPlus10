#!/bin/sh
# Add the Metal path to the mounted Mi A3 iOS 16 root (scripts/laurel/root.sh calls it; on by default, METAL=0 skips):
#   /System/Library/Extensions/NegroniMetal.bundle/{NegroniMetal,Info.plist,libvulkan_freedreno.dylib,clients}
#   /usr/local/bin/{vkprobe,metalprobe,mslprobe,m2vtest,carenderprobe,layerprobe,metallib-sweep.sh}
#   /private/var/db/negronimetal/{clients,env,cache/,strikes/,metal.log}
# Input: out/metal/stage from scripts/laurel/metal-build.sh (Turnip for the A610 + metal2vulkan bridge + plug-in).
# The kernel (patch 2850) names the bundle on IOAcceleratorES only when these files are in the root and the A610 runs;
# without them it logs "LAUREL METAL: off: ... missing" and CoreAnimation keeps its current renderer. No stage: exit 1, root.sh's table says `metal missing`.
#   sudo METAL=1 scripts/laurel/root-add-metal.sh MOUNTED_ROOT
#   METAL_CLIENTS="..."   the processes that get a Metal device (/var/db/negronimetal/clients). Default: the probes only
#                         ("metalprobe m2vtest carenderprobe layerprobe"), marked as the gate's list: at boot
#                         /usr/libexec/laurel-metal-gate (userland/laurel/metal/metal_gate.c; launchd job com.laurel.metal-gate,
#                         root, scripts/laurel/metal-gate-job.py) widens it to "* -backboardd" for all of iOS when the GPU runs
#                         with the stage-1 SMMU, the kernel registered the plug-in and m2vtest passes on this build; else it
#                         stays the probes.
#                         A list given here is the owner's: the gate leaves it alone. Steps by hand: docs/laurel_sprout/metal.md
#                         section 8 ("SpringBoard", then "* -backboardd", then "*" only after test 3 passes).
#                         When AREA B's GL wrapper for backboardd is in the root (/usr/libexec/real/backboardd), a "*"
#                         list gets "-backboardd" added unless it names backboardd itself (GL owns backboardd there).
#   METAL_ENV="TU_DEBUG=sysmem"              lines added to /var/db/negronimetal/env (Turnip/metal2vulkan settings)
# Design and the A610 facts: docs/laurel_sprout/metal.md.
set -eu
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/metal/stage
B=$S/System/Library/Extensions/NegroniMetal.bundle
if [ "${METAL:-1}" = 0 ]; then
  echo "laurel-root: metal: off: METAL=0"; exit 0
fi
for f in "$B/NegroniMetal" "$B/libvulkan_freedreno.dylib" "$B/Info.plist"; do
  if [ ! -f "$f" ]; then
    echo "laurel-root: metal: off: no ${f#$REPO/} (scripts/laurel/metal-build.sh)"; exit 1
  fi
done
D=$R/private/var/db/negronimetal
had_clients=0; [ -f "$D/clients" ] && had_clients=1
# an earlier root's default list (no mark line, only the probes) is no owner's list: it gets the gate's mark again
if [ $had_clients = 1 ] && [ -z "${METAL_CLIENTS:-}" ] && ! grep -q '^# laurel-metal-gate' "$D/clients" &&
   [ "$(grep -v '^#' "$D/clients" | tr -s ' \n' ' ' | sed 's/ $//')" = "metalprobe m2vtest carenderprobe layerprobe" ]; then
  had_clients=0
fi
METAL_CLIENTS= METAL=1 PLUGIN_NAME=NegroniMetal "$REPO/scripts/metal/root-add-metal.sh" "$R"
# The clients list (the shared script copies negroni's "*"): ours, unless the root kept its own list and none is asked
clients=${METAL_CLIENTS:-metalprobe m2vtest carenderprobe layerprobe}
if [ -e "$R/usr/libexec/real/backboardd" ] && printf ' %s ' "$clients" | grep -q ' \* ' &&
   ! printf ' %s ' "$clients" | grep -qE ' -?backboardd '; then
  clients="$clients -backboardd"
  echo "laurel-root: metal: GL wrapper for backboardd in the root: clients get -backboardd"
fi
if [ -n "${METAL_CLIENTS:-}" ] || [ $had_clients = 0 ]; then
  {
    # the default list is the gate's (first line "# laurel-metal-gate"): it widens it after its self-check
    [ -z "${METAL_CLIENTS:-}" ] && echo "# laurel-metal-gate: root default (probes only) until the gate's self-check passes"
    echo "# Processes that get the NegroniMetal Metal device (scripts/laurel/root-add-metal.sh, METAL_CLIENTS)."
    echo "# Names separated by blanks, \"*\" = all, \"-NAME\" = never NAME. Laurel default: the probes only, until the"
    echo "# gate's self-check passes at boot (docs/laurel_sprout/metal.md section 6.1); then all of iOS but backboardd."
    echo "$clients"
  } > "$D/clients"
  chmod 644 "$D/clients"
fi
echo "laurel-root: metal: clients = $(grep -v '^#' "$D/clients" | tr '\n' ' ')"
if [ -n "${METAL_ENV:-}" ]; then
  printf '%s\n' "$METAL_ENV" >> "$D/env"
fi
# The Metal client gate (built by scripts/laurel/gpu-userland.sh; its own launchd job, as root, once per boot)
G=$REPO/out/laurel/gpu/root/usr/libexec/laurel-metal-gate
if [ -s "$G" ]; then
  install -m 755 "$G" "$R/usr/libexec/laurel-metal-gate"
  [ "$(id -u)" != 0 ] || chown 0:0 "$R/usr/libexec/laurel-metal-gate"
  python3 -I "$REPO/scripts/laurel/metal-gate-job.py" "$R" on
  echo "laurel-root: metal: /usr/libexec/laurel-metal-gate installed (clients widened at boot after its self-check)"
else
  rm -f "$R/usr/libexec/laurel-metal-gate"
  python3 -I "$REPO/scripts/laurel/metal-gate-job.py" "$R" off
  echo "laurel-root: metal: no $G (scripts/laurel/gpu-userland.sh): clients stay as listed"
fi
# RenderBox reads RB_COLOR_MODE before the plug-in loads: in the jobs' own environment (chronod's widgets: plain BGRA, no '_RB4')
python3 -I "$REPO/scripts/laurel/metal-job-env.py" "$R" on
# Extensions with a Metal device: every extension point at least METAL_EXT_MB (default 64), posters METAL_POSTER_MB (default 128),
# the Photos daemons at least 64 (docs/laurel_sprout/metal.md 6.3; jetsamproperties read by runningboardd and launchd at boot)
for j in "$R"/System/Library/LaunchDaemons/com.apple.jetsamproperties.*.plist; do
  [ -f "$j" ] || continue
  echo "laurel-root: metal: $(python3 -I "$REPO/scripts/ios16/jetsam_widgets.py" --extensions "${METAL_EXT_MB:-64}" --posters "${METAL_POSTER_MB:-128}" "$j")"
  for d in com.apple.assetsd com.apple.photos.ImageConversionService com.apple.photos.VideoConversionService; do
    python3 -I "$REPO/scripts/ios16/jetsam_widgets.py" --daemon "$d" --mb 64 "$j" > /dev/null
  done
done
# what was built, for the log on the phone side (metal.log names no build)
{
  echo "# laurel_sprout Metal stage, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (cd "$S" && find . -type f -perm -u+x ! -name '*.sh' | sort | while read -r f; do
     printf '%s %s\n' "$(sha256sum "$f" | cut -c1-16)" "${f#.}"; done)
} > "$D/build.txt"
chmod 644 "$D/build.txt"
echo "laurel-root: metal: on: NegroniMetal.bundle (Turnip a610 + metal2vulkan), $(grep -c / "$D/build.txt") binaries"
