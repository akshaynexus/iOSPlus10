#!/bin/bash
# Every system shader of iOS 16.7.16 (20H392) through the metal2vulkan translator for the Adreno 610's Vulkan profile, on the host (no
# phone, no GPU): AIR -> SPIR-V + spirv-val, per function. It shows what a Metal client can expect from the translator, and not what
# Turnip's ir3 does with the SPIR-V: that part runs in m2vtest on the phone (docs/laurel_sprout/metal.md 6.1).
#   scripts/bg.sh metalall-corpus scripts/laurel/metal-corpus.sh [ui|all]      default ui (30 libraries, about 2 min); all = every metallib (142)
# Input: the OS image $APPLE/20H392/087-86698-044.dmg (mounted read-only with apfs-fuse, user space), out/metal/src from
# scripts/laurel/metal-build.sh fetch. Output: out/metal/corpus/runs/<time>-*/{summary.txt,summary.tsv,libs/*/results.tsv}. A set of ui
# compares with the baseline userland/metal/tests/shader-corpus-a610-ui.tsv (exit 1 on a regression); new ones: BASELINE=1.
# Profile: scripts/laurel/a610-profile.py, an estimate from tu_device.cc until a vkprobe capture exists.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/metal-env.sh"
laurel_metal_tools
set_name=${1:-ui}
# Disk rules (a run once wrote 273 GiB of repro bundles and filled the shared disk, 2026-11-01): no start with less than MIN_FREE_GB
# (default 50) free on the output disk or in the temp directory; a watcher stops the run below that, or when its output passes
# MAX_OUT_GB (default 10); at the end only the TSV files and the summary stay.
MIN_FREE_GB=${MIN_FREE_GB:-50}; MAX_OUT_GB=${MAX_OUT_GB:-10}; export MIN_FREE_GB
free_gb() { df -Pk "$1" | awk 'NR==2 {print int($4 / 1048576)}'; }
mkdir -p "$OUT/metal/corpus/runs"
TMPD=${TMPDIR:-/tmp}
if [ "$(free_gb "$OUT/metal/corpus/runs")" -lt "$MIN_FREE_GB" ]; then
  echo "metal-corpus: not started: less than $MIN_FREE_GB GiB free on $OUT" >&2; exit 3
fi
OS_DMG=${OS_DMG:-$APPLE/20H392/087-86698-044.dmg}
C=$OUT/metal/corpus
MNT=$C/mnt
mkdir -p "$C" "$MNT" "$OUT/metal/profiles"
PROFILE=$OUT/metal/profiles/a610-turnip-est.json
python3 -I "$REPO/scripts/laurel/a610-profile.py" "$OUT/metal/src/metal2vulkan/crates/metal2vulkan-validation/profiles/vk12-floor.json" "$PROFILE"
umnt() { mountpoint -q "$MNT" 2>/dev/null && fusermount3 -u "$MNT" || true; }
umnt
apfs-fuse -o ro "$OS_DMG" "$MNT"
trap umnt EXIT
ROOT=$MNT/root
case "$set_name" in
ui) L=$C/a610-ui.txt
    ROOT=$ROOT SET=ui "$REPO/scripts/metal/shader-corpus-test.sh" fetch
    grep -v '^#' "$C/fetch-list.txt" > "$L" ;;
all) L=$C/a610-all.txt
    (cd "$ROOT" && find System/Library Applications private/var/staged_system_apps -name '*.metallib' 2>/dev/null | sed 's#^#/#') | sort > "$L"
    ROOT=$ROOT SET=$L "$REPO/scripts/metal/shader-corpus-test.sh" fetch ;;
*) echo "usage: $0 [ui|all]" >&2; exit 2 ;;
esac
export PROFILE
stamp=$C/.run-start; : > "$stamp"
SET=$L LIB_TIMEOUT=${LIB_TIMEOUT:-300} "$REPO/scripts/metal/shader-corpus-test.sh" run &
run_pid=$!
# the watcher: the whole process group of the run goes when the disk or the output passes its limit
(
  while kill -0 "$run_pid" 2>/dev/null; do
    now=$(find "$C/runs" -mindepth 1 -maxdepth 1 -type d -newer "$stamp" | head -1)
    used=0; [ -z "$now" ] || used=$(du -xsk "$now" | awk '{print int($1 / 1048576)}')
    tmp=$(du -xsk "$TMPD/metal2vulkan-repros" 2>/dev/null | awk '{print int($1 / 1048576)}'); tmp=${tmp:-0}
    if [ "$(free_gb "$C/runs")" -lt "$MIN_FREE_GB" ] || [ "$used" -ge "$MAX_OUT_GB" ] || [ "$tmp" -ge 1 ]; then
      echo "metal-corpus: STOPPED: free $(free_gb "$C/runs") GiB, output $used GiB, repro bundles in $TMPD $tmp GiB" >&2
      pkill -TERM -P "$run_pid" 2>/dev/null || true
      kill -TERM "$run_pid" 2>/dev/null || true
      exit 0
    fi
    sleep 5
  done
) &
wait "$run_pid" || echo "metal-corpus: the run ended with an error (or the watcher stopped it)" >&2
r=$(ls -1dt "$C"/runs/*-a610-"$set_name" | head -1)
# only the numbers stay
find "$r" -type f ! -name '*.tsv' ! -name 'summary.txt' ! -name 'errors.txt' -delete
find "$r" -mindepth 1 -type d -empty -delete
echo "metal-corpus: kept $(du -sh "$r" | cut -f1) in $r"
echo "metal-corpus: $r"
grep -a 'functions=' "$r/summary.txt" || true
if [ "$set_name" = ui ]; then
  B=$REPO/userland/metal/tests/shader-corpus-a610-ui.tsv
  if [ "${BASELINE:-0}" = 1 ] || [ ! -f "$B" ]; then
    cp "$r/summary.tsv" "$B"; echo "metal-corpus: baseline $B"
  else
    python3 -I - "$B" "$r/summary.tsv" <<'PY'
import sys
def load(p):
    return {tuple(f[:2]): int(f[3]) for f in (l.rstrip("\n").split("\t") for l in open(p)) if len(f) >= 4 and f[3].isdigit()}
base, now = load(sys.argv[1]), load(sys.argv[2])
worse = [k for k in base if now.get(k, 0) < base[k]]
print("metal-corpus: regressions:", worse or "none")
sys.exit(1 if worse else 0)
PY
  fi
fi
