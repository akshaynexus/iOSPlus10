#!/bin/bash
# Host test of laurel 3040 and 3041: no "LAUREL ...: on/off" line prints before the kernel can print. [V phone 2026-11-07] Two hangs of the
# laurel-sprout image came from a printf too early: 2998's in arm_init() before the boot thread (TPIDR_EL1 0: fault loop), 2994's in a
# STARTUP(TIMEOUTS) function before STARTUP(LOCKS) made the msgbuf ticket lock valid (DEVELOPMENT: "Invalid ticket lock" panic).
# Rule: a printf runs at the earliest from a STARTUP(EARLY_BOOT) function, or from code that runs after kernel_startup_bootstrap().
#   1. laurel_ucache_apply() (2998 + 3040): every printf is behind `startup_phase >= STARTUP_SUB_TUNABLES`.
#   2. ml_init_lock_timeout() (xnu-12377 + 2994 + 3041): no printf in the function; the line is in a STARTUP(EARLY_BOOT, ...) function.
#      Needs the xnu cache of one kernel build (out/laurel-kernel-ios26/cache/xnu.git, here or in the main checkout); else that part is skipped.
#   3. No series or post patch adds a printf/kprintf/IOLog to arm_init.c before thread_bootstrap() (the hunks of arm_init.c are read by line).
# Seconds; no device.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bad=0
# 1
mkdir -p "$T/u/osfmk/arm64"
python3 -I - "$REPO/patches/laurel/xnu/2998-laurel-ucache.patch" "$T/u/osfmk/arm64/laurel_ucache.c" <<'PY'
import sys
out, take = [], False
for line in open(sys.argv[1]):
    if line.startswith('+++ b/osfmk/arm64/laurel_ucache.c'): take = True; continue
    if take and line.startswith('diff --git'): break
    if take and line.startswith('+') and not line.startswith('+++'): out.append(line[1:])
open(sys.argv[2], 'w').write(''.join(out))
PY
(cd "$T/u" && patch -p1 -s < "$REPO/patches/laurel/xnu/3040-laurel-ucache-line-after-boot-thread.patch")
python3 -I - "$T/u/osfmk/arm64/laurel_ucache.c" <<'PY' || bad=1
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'\nlaurel_ucache_apply\(void\)\n\{(.*?)\n\}\n', s, re.S); body = m.group(1)
g = body.find('startup_phase >= STARTUP_SUB_TUNABLES'); early = [p.start() for p in re.finditer(r'\bprintf\(', body) if g < 0 or p.start() < g]
print(f"1. laurel_ucache_apply: guard {'present' if g >= 0 else 'MISSING'}, {len(early)} printf before it"); sys.exit(1 if g < 0 or early else 0)
PY
# 2
main=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
cache=; for c in "$REPO/out/laurel-kernel-ios26/cache/xnu.git" "$main/out/laurel-kernel-ios26/cache/xnu.git"; do [ -d "$c" ] && { cache=$c; break; }; done
if [ -n "$cache" ] && git -C "$cache" rev-parse -q --verify refs/tags/xnu-12377.121.6 >/dev/null 2>&1; then
  mkdir -p "$T/m/osfmk/arm64"; git -C "$cache" show xnu-12377.121.6:osfmk/arm64/machine_routines.c > "$T/m/osfmk/arm64/machine_routines.c"
  for p in 2994-laurel-lock-timeout 3041-laurel-lock-timeout-line-at-early-boot; do
    (cd "$T/m" && patch -p1 -s -F3 < "$REPO/patches/laurel/xnu/$p.patch") || { echo "2. $p does not apply on xnu-12377 machine_routines.c"; bad=1; }
  done
  python3 -I - "$T/m/osfmk/arm64/machine_routines.c" <<'PY' || bad=1
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'\nml_init_lock_timeout\(void\)\n\{(.*?)\n\}\n', s, re.S); body = m.group(1)
n = len(re.findall(r'\bprintf\(', body))
late = re.search(r'STARTUP\(EARLY_BOOT,\s*STARTUP_RANK_\w+,\s*laurel_lock_timeout_line\)', s) is not None
print(f"2. ml_init_lock_timeout: {n} printf (must be 0); laurel_lock_timeout_line at EARLY_BOOT: {late}"); sys.exit(0 if n == 0 and late else 1)
PY
else
  echo "2. skipped: no xnu cache (one kernel build makes it)"
fi
# 3
python3 -I - "$REPO/patches/laurel/xnu" "$REPO/patches/laurel/xnu-12377" <<'PY' || bad=1
import glob, re, sys
hits = []
for d in sys.argv[1:]:
    for p in sorted(glob.glob(d + '/*.patch') + glob.glob(d + '/post/*.patch')):
        cur = None; at = None
        for line in open(p, errors='replace'):
            if line.startswith('+++ '): cur = line[6:].strip(); continue
            if cur != 'osfmk/arm/arm_init.c': continue
            m = re.match(r'@@ -\d+(?:,\d+)? \+(\d+)', line)
            if m: at = int(m.group(1)); continue
            if at is None: continue
            if line.startswith('+') and re.search(r'\b(printf|kprintf|IOLog)\(', line) and at < 480:
                hits.append(f"{p.split('/')[-1]} arm_init.c line {at}: {line.strip()[:80]}")
            if not line.startswith('-'): at += 1
print("3. arm_init.c before thread_bootstrap (line 488 of the 12377 tree):", "no printf added" if not hits else "\n   ".join([""] + hits))
sys.exit(1 if hits else 0)
PY
echo "test-early-lines: $([ $bad = 0 ] && echo PASS || echo FAIL)"; exit $bad
