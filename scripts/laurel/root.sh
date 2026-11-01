#!/bin/bash
# Build the Mi A3 (laurel_sprout) iOS 16.7.16 root for userdata (rd=ufsroot0) on Linux, as a sparse image.
#   scripts/bg.sh laurel-root sudo scripts/laurel/root.sh       (needs root: loop mounts, apfs-fuse, rsync -aH)
# Input: $APPLE/20H392/*.dmg (scripts/ios16/fetch-dmgs.sh, op10tool ipsw-get; default APPLE=~/op10-apple).
# SSH=1 (default, when out/ssh/ios exists): dropbear + tools (scripts/net/root-add-ssh.sh); SSH=0: none.
# Honest build (docs/laurel_sprout/build-honest.md): preflight first (every stage of a wanted feature exists and is fresh, or no start; prints the inputs),
# one feature table at the end and in the root (/usr/share/laurel/root-manifest), exit 1 unless each absent feature has its own =0 switch, and exit 1 when
# an input changed during the run. Then no sparse image is made; $APPLE/laurel-ios16-root.manifest says why and root-flash-test.sh will not flash.
# Steps: 1. external/ios-topaz/tools/mkiosroot.sh (case-sensitive journaled HFS+, OS + SystemOS/AppOS cryptexes,
#        dyld cache link, plain system keybag); 2. topaz sweet-root-tweaks.py (build 20H392 fixes, launchd,
#        CommCenter drop, Setup, migration) + negroni root-tweaks-extra.py (vmd etc. dropped), root-tweaks-perf.py (restart-loop jobs),
#        root-system-features.py (32 staged apps to /Applications, aggregated back; docs/laurel_sprout/system-features.md) and
#        root-tweaks-boldtext.py, root-add-gpu.sh (GPU), root-add-metal.sh (Metal, METAL=0 skips), root-audio.sh
#        (speaker HAL plug-in; AUDIO=0 skips), root-bt.sh (Bluetooth userland; BT=0 skips), root-camera.sh (sensor tables, NegroniCamera.driver;
#        CAMERA=0 skips), root-hevc.sh (HEVC/HEIC decoder; HEVC=0 skips), root-statusbar.py
#        (status bar provider for 360x780 pt + the waterdrop dylib for SpringBoard from out/laurel/notch, scripts/laurel/notch-build.sh;
#        STATUSBAR=0 skips both, NOTCH=0 only the dylib), root-flashlight.sh (the flashlight's one owner: camera plug-in, else its own plug-in; TORCH=0 = no button) and root-brightness.py
#        (auto-brightness off; BRIGHTNESS=0 skips), root-xnutils.sh (XNUtils.app; XNUTILS=0 skips); 3. fsck; 4. op10tool img2simg -> ios16-root.simg (owned by the user).
# Output: $APPLE/laurel-ios16-root.img + .simg (Apple content: never in git). SIZE=16G (userdata is 108 GiB).
# Flash (erases Android user data; owner confirms first): fastboot reboot bootloader, then
#   fastboot -S 512M flash userdata $APPLE/laurel-ios16-root.simg
set -euo pipefail
# Everything is in main(): bash reads a function whole, so an edit of this file during the run cannot change what runs.
main() {
[ "$(id -u)" = 0 ] || { echo "laurel-root: run with sudo" >&2; exit 1; }
U=${SUDO_USER:-$USER}
H=$(getent passwd "$U" | cut -d: -f6)
REPO=$(cd "$(dirname "$0")/../.." && pwd)
APPLE=${APPLE:-$H/op10-apple}
D=$APPLE/20H392
IMG=$APPLE/laurel-ios16-root.img
SIDECAR=${IMG%.img}.manifest
TOPAZ=$REPO/external/ios-topaz/tools
M=$REPO/scripts/laurel/root-manifest.py
for t in apfs-fuse mkfs.hfsplus fsck.hfsplus rsync python3; do
  command -v "$t" >/dev/null || { echo "laurel-root: missing $t (paru -S hfsprogs apfs-fuse-git)" >&2; exit 1; }
done
for f in 087-86698-044.dmg 087-86593-047.dmg 087-86715-047.dmg; do
  [ -s "$D/$f" ] || { echo "laurel-root: missing $D/$f (scripts/ios16/fetch-dmgs.sh)" >&2; exit 1; }
done
ts() { date +%H:%M:%S; }
mnt=$(mktemp -d)
INPUTS=$(mktemp)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; rm -f "$INPUTS"; chown "$U": "$SIDECAR" 2>/dev/null || true' EXIT
# before anything slow: every stage of a wanted feature, the kernel stamp; the inputs of this run
python3 -I "$M" preflight --inputs "$INPUTS" || exit 1
# from here the old image is not the current one: the sidecar says so until the end
python3 -I "$M" begin "$SIDECAR"
modprobe hfsplus

echo "$(ts) laurel-root: 1/4 mkiosroot -> $IMG (${SIZE:-16G})"
rm -f "$IMG"
# mkiosroot ends with one fsck repair and a read-only verify; after the big copy the verify can still ask
# for a "minor repair" of the volume header (2026-11-01): scripts/laurel/root-fsck.sh repairs (max 3) until clean.
if ! bash "$TOPAZ/mkiosroot.sh" "$D/087-86698-044.dmg" "$D/087-86593-047.dmg" "$D/087-86715-047.dmg" "$IMG" "${SIZE:-16G}"; then
  [ -s "$IMG" ] || { python3 -I "$M" fail "$SIDECAR" "mkiosroot failed"; echo "laurel-root: FAILED: mkiosroot failed before the image existed" >&2; exit 1; }
  bash "$REPO/scripts/laurel/root-fsck.sh" "$IMG" || { python3 -I "$M" fail "$SIDECAR" "fsck after mkiosroot"; exit 1; }
  echo "$(ts) laurel-root: volume checked"
fi

echo "$(ts) laurel-root: 2/4 root tweaks (topaz sweet-root-tweaks.py)"
mount -t hfsplus -o loop,force,rw "$IMG" "$mnt"
python3 -I "$TOPAZ/sweet-root-tweaks.py" "$mnt"
# negroni's tweaks on top (docs/laurel_sprout/negroni-ports.md "Userland / root image"): launchd drop list
# (vmd: ~29k CommCenter retries per boot without a modem, the main idle CPU load; the ios-redfin Pixel 5 port
# measured ~5 % average CPU after killing it; fairplayd.H2, ReportCrash, spindump, tailspind, aggregated,
# bluetoothd, activityawardsd), ExtensionKit signing flag, FBLaunchWatchdogScale 3, migration skip.
# CA heartbeat 60: the Mi A3 panel runs at 60 Hz (negroni's default 120 is for its 120 Hz panel).
CA_HEARTBEAT=${CA_HEARTBEAT:-60} python3 -I "$REPO/scripts/ios16/root-tweaks-extra.py" "$mnt"
python3 -I "$REPO/scripts/ios16/root-tweaks-boldtext.py" "$mnt"
# launchd jobs that only burn CPU on the Mi A3 (restart loops, docs/laurel_sprout/battery-power.md); PERF_DROP_JOBS= keeps them
python3 -I "$REPO/scripts/laurel/root-tweaks-perf.py" "$mnt"
# system apps and jobs back (docs/laurel_sprout/system-features.md): the 32 staged Apple apps to /Applications, aggregated (power log for
# Settings > Battery) back with a 32 MiB limit. STAGED_APPS=0, RESTORE_JOBS= and AGGREGATED_JETSAM_MB= turn parts off.
python3 -I "$REPO/scripts/laurel/root-system-features.py" "$mnt"
# every feature, each with its row in the one table (scripts/laurel/root-features.sh; switches listed there)
missing=0
bash "$REPO/scripts/laurel/root-features.sh" "$mnt" --inputs "$INPUTS" --sidecar "$SIDECAR" || missing=1
sync
umount "$mnt"
if [ "$missing" != 0 ]; then
  python3 -I "$M" fail "$SIDECAR" "a feature is missing"
  echo "$(ts) laurel-root: FAILED: a feature is missing (table above): no sparse image. $IMG stays for a look" >&2
  exit 1
fi

echo "$(ts) laurel-root: 3/4 fsck"
bash "$REPO/scripts/laurel/root-fsck.sh" "$IMG" || { python3 -I "$M" fail "$SIDECAR" "fsck"; exit 1; }

# a script or stage that changed during the run: the image is not what the inputs say (the race of 2026-11-01)
if ! python3 -I "$M" inputs-check "$INPUTS"; then
  python3 -I "$M" fail "$SIDECAR" "an input changed during the run"
  echo "$(ts) laurel-root: FAILED: an input changed during the run: no sparse image; run root.sh again" >&2
  exit 1
fi

echo "$(ts) laurel-root: 4/4 sparse image (op10tool img2simg)"
OP=$REPO/out/bin/op10tool
[ -x "$OP" ] || sudo -u "$U" "$REPO/scripts/setup/build-op10tool.sh"
"$OP" img2simg "$IMG" "$IMG.simg.partial" && mv "$IMG.simg.partial" "${IMG%.img}.simg"
chown "$U": "$IMG" "${IMG%.img}.simg"
python3 -I "$M" seal "$SIDECAR" "${IMG%.img}.simg"
ls -l "$IMG" "${IMG%.img}.simg"
echo "$(ts) laurel-root: done"
}
main "$@"
exit 0
