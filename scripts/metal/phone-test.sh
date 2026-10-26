#!/bin/sh
# Run the Metal stage tests on the phone over SSH (scripts/net/ssh-phone.sh, root@192.168.7.2) and keep the output
# in logs/metal-phone-<stage>-<time>.log. The phone needs a root made with METAL=1 scripts/metal/root-add-metal.sh
# (or `push` below). docs/metal-plan.md says what each stage proves and what to look at when it fails.
#   scripts/metal/phone-test.sh push            copy out/metal/stage to the phone (bundle, probes, clients) without a new root
#   scripts/metal/phone-test.sh 0               Turnip: vkprobe (instance, device, extensions) + vkprobe --clear
#   scripts/metal/phone-test.sh 1               Metal loads our device: metalprobe (system discovery) and
#                                               metalprobe --bundle (in-process MTLAddDevice, works without MetalPluginName)
#   scripts/metal/phone-test.sh 2               command buffers: clear + IOSurface clear
#   scripts/metal/phone-test.sh 3               shaders: compute + render from MSL, QuartzCore default.metallib pipelines,
#                                               m2vtest (the bridge's self-test, no Metal.framework)
#   scripts/metal/phone-test.sh 3b              all system metallibs, one metalprobe --metallib process each
#                                               (metallib-sweep.sh, from Chlorophyll's sweep; table /var/tmp/metallib-sweep.tsv)
#   scripts/metal/phone-test.sh 4a              CoreAnimation over our device in test processes, before backboardd (stage 4):
#                                               layerprobe (CAMetalLayer drawable -> IOSurface -> CPU readback) and
#                                               carenderprobe (CARenderer scenes vs renderInContext:, PPMs in /var/tmp/carender)
#   scripts/metal/phone-test.sh log             the plugin log (/var/db/negronimetal/metal.log)
# No phone writes except `push` (files under /System/Library/Extensions, /usr/local/bin, /usr/local/share, /var/db/negronimetal)
# and the test outputs of 3b/4a (/var/tmp/metallib-sweep.tsv, /var/tmp/carender/, the probes' strike files).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
B=/System/Library/Extensions/NegroniMetal.bundle
stage=${1:?usage: $0 push|0|1|2|3|3b|4a|log}
mkdir -p "$REPO/logs"
LOG=$REPO/logs/metal-phone-$stage-$(date +%Y%m%d-%H%M%S).log
run() { echo "== $*" | tee -a "$LOG"; "$SSHP" "$@" 2>&1 | tee -a "$LOG"; }

case $stage in
push)
  S=$REPO/out/metal/stage
  [ -d "$S/usr/local/bin" ] || { echo "no $S: scripts/metal/build.sh" >&2; exit 1; }
  T=$(mktemp -d)
  # Files and symlinks only, no directory entries, and var/ as private/var/: on iOS /var is a symlink
  # to /private/var, and a "var" directory entry makes the phone's tar replace that symlink with an
  # empty directory (2026-10-25: that broke /var/root/.ssh and so SSH).
  (cd "$S" && find System usr var \( -type f -o -type l \) | LC_ALL=C sort) > "$T/list"
  COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --no-recursion -s '#^var/#private/var/#' -czf "$T/metal.tgz" -C "$S" -T "$T/list"
  if tar -tzf "$T/metal.tgz" | grep -Eq '(^|/)$|^var/|^\./'; then echo "push: archive has directory or var/ entries" >&2; exit 1; fi
  "$SSHP" push "$T/metal.tgz" /private/var/tmp/metal.tgz
  rm -rf "$T"
  # keep an existing clients/env on the phone; the probes and the bundle are replaced
  run 'cd / && [ -L /var ] || { echo "/var is not a symlink: stop"; exit 1; };
       mkdir -p /var/db/negronimetal && cp -p /var/db/negronimetal/clients /var/tmp/clients.keep 2>/dev/null;
       tar -xzpf /private/var/tmp/metal.tgz -C / && rm /private/var/tmp/metal.tgz;
       [ -f /var/tmp/clients.keep ] && mv /var/tmp/clients.keep /var/db/negronimetal/clients;
       mkdir -p /var/db/negronimetal/cache /var/db/negronimetal/strikes && chmod 1777 /var/db/negronimetal/cache /var/db/negronimetal/strikes;
       touch /var/db/negronimetal/metal.log && chmod 666 /var/db/negronimetal/metal.log;
       sync; ls -la '"$B"' /usr/local/bin'   # sync: a reset 10 s after an unsynced push lost it (2026-10-27 03:15)
  ;;
0)
  run "/usr/local/bin/vkprobe --icd $B/libvulkan_freedreno.dylib"
  run "/usr/local/bin/vkprobe --icd $B/libvulkan_freedreno.dylib --clear --quiet"
  ;;
1)
  run "/usr/local/bin/metalprobe --registry"
  run "/usr/local/bin/metalprobe --bundle $B"
  ;;
2)
  run "/usr/local/bin/metalprobe --bundle $B --clear --iosurface"
  ;;
3)
  run "/usr/local/bin/metalprobe --bundle $B --compute --render"
  run "/usr/local/bin/metalprobe --bundle $B --metallib /System/Library/Frameworks/QuartzCore.framework/default.metallib"
  run "/usr/local/bin/m2vtest $B/libvulkan_freedreno.dylib /var/db/negronimetal/cache/m2vtest /System/Library/Frameworks/QuartzCore.framework/default.metallib"
  ;;
3b)
  run "/usr/local/bin/metallib-sweep.sh $B /var/tmp/metallib-sweep.tsv"
  ;;
4a)
  run "/usr/local/bin/layerprobe --bundle $B"
  run "mkdir -p /var/tmp/carender && /usr/local/bin/carenderprobe --bundle $B /var/tmp/carender"
  ;;
log)
  run "tail -n 200 /var/db/negronimetal/metal.log"
  ;;
*) echo "usage: $0 push|0|1|2|3|3b|4a|log" >&2; exit 1 ;;
esac
echo "log: $LOG"
grep -q "FAIL" "$LOG" && exit 1 || exit 0
