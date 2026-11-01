#!/bin/bash
# Mi A3 iOS 26.5.2 (23F84, iPhone12,1 N104AP) root: an HFS+ image, built on Linux with no Apple tool and no root access. It writes nothing to a device.
#   scripts/bg.sh ios26-root scripts/laurel/ios26-root.sh
#   FORCE=1     build again when the inputs did not change      AREA_GIB=32     the iOS area (owner decision 2026-11-02)      VAR_GIB=8   refuse less free space
# Steps: 1. read-only apfs-fuse mounts of the three donor images; 2. scripts/laurel/ios26-root-spec.py: layout, lowered files, tweaks with an audit line per item,
# trust data, spec; 3. op10tool hfs-build; 4. checks: op10tool hfs-verify (every file against its SHA-256), fsck.hfsplus -n, a real read-only kernel mount (udisks) with
# scripts/laurel/ios26-root-check.py. Inputs: scripts/ios26/fetch-os.sh, sysos-tree.sh, lower-userland.sh with DEV=n104ap (docs/laurel_sprout/ios26-userland.md section 2).
# Output (Apple content, never in git): $APPLE/ios26/23F84-n104ap/root/ios26-root.img + .manifest + report.txt; link out/ios26/root-n104ap.
# Size: the area minus 256 header blocks and 1025 log blocks (tools/laurel-dualboot/laurel_dualboot.h, bsd/dev/sweet_ufs.c SWEET_LOG_BLOCKS). 32 GiB: 34354491392 bytes.
# Same inputs give the same bytes; a run with the same inputs checks the image and stops. Writing it to the phone is another step (scripts/laurel/dual-boot.sh install), not this one.
# The negroni path is scripts/ios26/root-macos.sh; this script does not touch it.
set -euo pipefail
main() {
. "$(dirname "$0")/../lib/env.sh"
DEV=n104ap
. "$REPO/scripts/ios26/donor.sh"
B=$APPLE/ios26/$BUILD-$DEV
D=$B/os
T=$B/tree
L=$B/lowered
R=$B/root
W=$R/work
IMG=$R/ios26-root.img
TOOL=$OUT/bin/op10tool
AREA_GIB=${AREA_GIB:-32}
VAR_GIB=${VAR_GIB:-8}
for t in apfs-fuse fusermount3 python3 fsck.hfsplus sha256sum; do command -v "$t" >/dev/null || { echo "ios26-root: missing $t" >&2; exit 1; }; done
[ -x "$TOOL" ] || { echo "ios26-root: no $TOOL (scripts/setup/build-op10tool.sh)" >&2; exit 1; }
for f in "$D/${OS_AEA%.aea}" "$D/${SYSOS%.aea}" "$D/$APPOS" "$L/dyld_shared_cache_arm64e" "$L/cdhashes.tsv"; do [ -s "$f" ] || { echo "ios26-root: missing $f" >&2; exit 1; }; done
# the size comes from the two constants the kernel and the helper use
RES=$(sed -n 's/^#define LDB_RESERVED_BLOCKS *\([0-9]*\)u.*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
BLK=$(sed -n 's/^#define LDB_BLOCK *\([0-9]*\)u.*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
LOGB=$(sed -n 's/^.*const LOG_BLOCKS: u64 = (4 << 20) \/ B + 1;.*$/1025/p' "$REPO/tools/op10tool/src/dualboot.rs")
[ "$RES" = 256 ] && [ "$BLK" = 4096 ] && [ "$LOGB" = 1025 ] || { echo "ios26-root: the area constants changed: header $RES, block $BLK, log $LOGB: read dual-boot.md" >&2; exit 1; }
SIZE=$(( (AREA_GIB << 30) - (RES + LOGB) * BLK ))
avail=$(df -k --output=avail "$APPLE" | tail -1)
[ "$avail" -gt $((30 << 20)) ] || { echo "ios26-root: under 30 GiB free at $APPLE" >&2; exit 1; }
echo "ios26-root: area $AREA_GIB GiB, volume $SIZE bytes (area - $RES header blocks - $LOGB log blocks), at least $VAR_GIB GiB free for /private/var"; df -h "$APPLE" | tail -1
mkdir -p "$W" "$OUT/ios26"
MNT=$OUT/ios26/mnt/root26; mkdir -p "$MNT/os" "$MNT/sys" "$MNT/app" "$MNT/ro"
LOOP=
un() { mountpoint -q "$1" && { fusermount3 -u "$1" 2>/dev/null || fusermount3 -uz "$1" 2>/dev/null || true; }; return 0; }
cleanup() {
  if [ -n "$LOOP" ]; then udisksctl unmount -b "$LOOP" --no-user-interaction >/dev/null 2>&1 || true; udisksctl loop-delete -b "$LOOP" --no-user-interaction >/dev/null 2>&1 || true; fi
  un "$MNT/os"; un "$MNT/sys"; un "$MNT/app"
}
trap cleanup EXIT
apfs-fuse "$D/${OS_AEA%.aea}" "$MNT/os"
apfs-fuse "$D/${SYSOS%.aea}" "$MNT/sys"
apfs-fuse "$D/$APPOS" "$MNT/app"
echo "ios26-root: 1. spec"
python3 -I "$REPO/scripts/laurel/ios26-root-spec.py" --os "$MNT/os/root" --sys "$MNT/sys/root" --app "$MNT/app/root" --tree "$T" --lowered "$L" --osdir "$D" --work "$W"
# what this image is made of: hash of the spec, of the changed files and of each lowered file's size and date. Same value: nothing to do.
INPUTS=$( { sha256sum "$W/spec" | cut -d' ' -f1; (cd "$W/overlay" && find . -type f -print0 | sort -z | xargs -0 sha256sum); sha256sum "$L/cdhashes.tsv" "$L/macho-lowered.tsv"; sha256sum "$0" "$REPO/scripts/laurel/ios26-root-spec.py" "$REPO/tools/op10tool/src/hfs.rs"; echo "$SIZE"; } | sed "s#$REPO/##" | sha256sum | cut -d' ' -f1)
if [ "${FORCE:-0}" != 1 ] && [ -s "$IMG" ] && [ -s "$IMG.manifest" ] && [ "$(cat "$R/inputs.sha256" 2>/dev/null)" = "$INPUTS" ]; then
  echo "ios26-root: 2. inputs unchanged ($INPUTS): the image stays; checking it"
else
  echo "ios26-root: 2. hfs-build"
  rm -f "$R/inputs.sha256"
  "$TOOL" hfs-build --spec "$W/spec" --out "$IMG.partial" --manifest "$IMG.manifest" --size "$SIZE" --max-size "$SIZE" --min-free $((VAR_GIB << 30)) --label iOSRoot
  mv -f "$IMG.partial" "$IMG"
  echo "$INPUTS" > "$R/inputs.sha256"
fi
un "$MNT/os"; un "$MNT/sys"; un "$MNT/app"
echo "ios26-root: 3. hfs-verify"
"$TOOL" hfs-verify --image "$IMG" --manifest "$IMG.manifest" | tee "$W/verify.txt"
echo "ios26-root: 4. fsck.hfsplus -f -n"
# This Linux fsck says "Volume header needs minor repair" on every journaled volume, also a fresh mkfs.hfsplus -J, and still after its own repair [V 2026-11-02]. That one line is
# not a finding. Any other indented line (an invalid or overlapped or illegal thing) is.
fsck_rc=0; fsck.hfsplus -f -n "$IMG" 2>&1 | tee "$W/fsck.txt" | tail -12 || true
if grep -E '^   [A-Z]' "$W/fsck.txt" | grep -vE '^   (Volume header needs minor repair|The volume name is|Executing fsck_hfs)' | grep -q .; then fsck_rc=1; fi
grep -q 'Checking volume information' "$W/fsck.txt" || fsck_rc=1
echo "ios26-root: fsck findings beyond the known header line: $fsck_rc (0 = none)"
echo "ios26-root: 5. read-only kernel mount"
kmount=not-run
if out=$(udisksctl loop-setup -r -f "$IMG" --no-user-interaction 2>&1); then
  LOOP=$(echo "$out" | sed -n 's/.* as \(\/dev\/loop[0-9]*\)\.*$/\1/p')
  udisksctl unmount -b "$LOOP" --no-user-interaction >/dev/null 2>&1 || true
  if m=$(udisksctl mount -b "$LOOP" -t hfsplus -o ro --no-user-interaction 2>&1); then
    P=$(echo "$m" | sed -n 's/.* at \(.*\)$/\1/p')
    echo "$m"; findmnt -no FSTYPE,OPTIONS "$P" | cut -c1-80
    python3 -I "$REPO/scripts/laurel/ios26-root-check.py" "$P" "$IMG.manifest" | tee "$W/mount-check.txt"
    kmount=ok
  else
    echo "ios26-root: kernel mount failed: $m"; kmount=failed
  fi
else
  echo "ios26-root: no loop device through udisks: $out"; kmount=no-loop
fi
cleanup; LOOP=; trap - EXIT
{
  echo "iOS 26 root, Mi A3: build $BUILD $DEV, $(date -u +%F)"
  echo "image $IMG: $(stat -c %s "$IMG") bytes, real $(du -k "$IMG" | cut -f1) KiB"
  echo "area $AREA_GIB GiB = $((AREA_GIB << 30)) bytes; header $RES blocks, log $LOGB blocks; volume $SIZE bytes"
  echo "inputs $INPUTS"
  sed -n 2p "$IMG.manifest"
  cat "$W/verify.txt"
  echo "fsck.hfsplus -f -n: $([ "$fsck_rc" = 0 ] && echo OK || echo "not OK: $W/fsck.txt")"
  echo "kernel read-only mount: $kmount"
  [ -f "$W/mount-check.txt" ] && cat "$W/mount-check.txt"
  echo "tweak audit:"; cat "$W/audit.txt"
  echo "not in this image (iOS 16 stages with no iOS 26 build): Mesa and EAGL shim, audio HAL, Bluetooth userland, camera, HEVC, status bar, XNUtils, SSH"
} > "$R/report.txt"
ln -sfn "$R" "$OUT/ios26/root-$DEV"
grep ' metal26:' "$W/audit.txt" || echo "off       metal26: no audit line"
sha256sum "$IMG.manifest" "$W/spec"
ls -l "$IMG"; du -h "$IMG"
[ "$kmount" = ok ] && [ "$fsck_rc" = 0 ] && echo "ios26-root: done, all checks OK: $R/report.txt" || { echo "ios26-root: FINISHED with a failed check: $R/report.txt"; exit 1; }
}
main "$@"
exit 0
