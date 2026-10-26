#!/bin/sh
# Remove old build output to save disk space (macOS and Linux). Run it after every successful new build.
#   scripts/clean-builds.sh          show what would go (dry run)
#   scripts/clean-builds.sh --yes    remove it
# Keeps: the KEEP_KERNELS newest out/kernel/local-* builds (default 2) and the one out/kernel/kernel.macho
# links to; every kernel tree (out/kernel/tree-*, wt-*) with a file changed in the last KEEP_HOURS hours
# (default 3: an agent may still use it); out/kernel/local (the build tree), buildtree, the default
# boot image dir out/ios16. Removes: older local-* builds, idle trees, out/kernel/keep, old boot-image
# variants out/ios16-* (not ios16-debug, ios16-safe, ios16-everything), out/backup-orphan-* older than 2 days.
# Never touches ~/op10-apple, ~/op10-backup, firmware, or anything outside out/.
set -eu
. "$(dirname "$0")/lib/env.sh"
YES=${1:-}
KEEP_KERNELS=${KEEP_KERNELS:-2}
KEEP_HOURS=${KEEP_HOURS:-3}
K=$OUT/kernel
cand=""
add() { cand="$cand
$1"; }

# kernel builds: newest KEEP_KERNELS + the linked one
linked=$(readlink "$K/kernel.macho" 2>/dev/null | cut -d/ -f1 || true)
n=0
for d in $(ls -d "$K"/local-2* 2>/dev/null | sort -r); do
  n=$((n + 1))
  [ "$n" -le "$KEEP_KERNELS" ] && continue
  [ "$(basename "$d")" = "$linked" ] && continue
  add "$d"
done
# kernel trees with no change in KEEP_HOURS hours
for d in "$K"/tree-* "$K"/wt-*; do
  [ -d "$d" ] || continue
  if [ -z "$(find "$d" -type f -mmin "-$((KEEP_HOURS * 60))" -print -quit 2>/dev/null)" ]; then add "$d"; fi
done
[ -d "$K/keep" ] && add "$K/keep"
for d in "$OUT"/ios16-*; do
  [ -d "$d" ] || continue
  case $(basename "$d") in ios16-debug|ios16-safe|ios16-everything) continue ;; esac   # safe = the known-good boot_a (test-boot.sh)
  # test images (out/ios16-tNN) changed in KEEP_HOURS hours stay: a queued RAM test or log read may still use them
  [ -n "$(find "$d" -type f -mmin "-$((KEEP_HOURS * 60))" -print -quit 2>/dev/null)" ] && continue
  add "$d"
done
for d in "$OUT"/backup-orphan-*; do
  [ -d "$d" ] && [ -n "$(find "$d" -maxdepth 0 -mtime +2)" ] && add "$d"
done

total=0
echo "$cand" | while IFS= read -r d; do
  [ -n "$d" ] || continue
  echo "$(du -sh "$d" 2>/dev/null | cut -f1)	${d#"$REPO"/}"
done
if [ "$YES" = --yes ]; then
  echo "$cand" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    case $d in "$OUT"/*) rm -rf "$d" ;; *) echo "skip (outside out/): $d" >&2 ;; esac
  done
  echo "removed. free: $(df -h "$OUT" | awk 'NR==2{print $4}')"
else
  echo "dry run: scripts/clean-builds.sh --yes removes the list above"
fi
