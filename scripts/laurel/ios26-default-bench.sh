#!/bin/bash
# Mi A3 iOS 26: one measure of the default stack (metal2vulkan + Turnip) with the fixed UI test, under given settings. Docs: docs/laurel_sprout/ios26-default-speed.md.
#   scripts/bg.sh bench-NAME scripts/laurel/ios26-default-bench.sh NAME [KEY=VALUE ...] [-- autotest run args]
# Always under the lock: scripts/bg.sh bench-NAME scripts/laurel/phone-lock.sh m2v scripts/laurel/ios26-default-bench.sh NAME ...  (the native agent shares the phone).
# TURNIP=FILE, PLUGIN=FILE (env): this run uses these files for Turnip and options/default; the phone's own go back at the end. KEY=VALUE lines go into /var/db/negronimetal/env for this run only. The steps: save option and env; set option default; new env; restart the UI; wait for it; run the test;
# put back option and env (at any exit), and restart the UI so that the phone goes on with its own settings. NO_RESTORE=1: stays as it is, for a next run.
# Table: logs/bench-NAME.txt. A run that did not run on stack default says so and fails: the native agent can take the phone in between.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
DB=/private/var/db/negronimetal
SETTLE_S=${SETTLE_S:-45}
name=${1:?usage: $0 NAME [KEY=VALUE ...] [-- autotest args]}; shift
extra=()
while [ $# -gt 0 ] && [ "$1" != -- ]; do extra+=("$1"); shift; done
[ "${1:-}" != -- ] || shift
say() { echo "$(date +%H:%M:%S) bench $name: $*"; }
phone() { "$SSHP" "$@"; }
restart_ui() { phone 'sync; for w in $(ps -ax -o pid=,comm= | grep "/backboardd$"); do kill -9 "$w"; break; done'; }

B=/System/Library/Extensions/NegroniMetal.bundle
# FILE PATH: a new file, read back by hash, moved over PATH; the old one stays in PATH.bench-saved until restore()
put() {
  local want; want=$(sha256sum "$1" | cut -d' ' -f1)
  phone "[ -f '$2.bench-saved' ] || cp -p '$2' '$2.bench-saved'; cat > '$2.new'" < "$1"
  [ "$(phone "shasum -a 256 '$2.new' 2>/dev/null || sha256sum '$2.new'" | cut -d' ' -f1)" = "$want" ] || { say "bad copy of $2"; exit 4; }
  phone "chown 0:0 '$2.new'; chmod 755 '$2.new'; mv -f '$2.new' '$2'"
  say "this run: $2 = $1"
}
back() { phone "[ -f '$1.bench-saved' ] && mv -f '$1.bench-saved' '$1'; true"; }
# A run that a reboot ended left its settings: they go first (we hold the lock, so no run is under way).
phone "[ -f $DB/option.bench-saved ] && mv -f $DB/option.bench-saved $DB/option; [ -f $DB/env.bench-saved ] && mv -f $DB/env.bench-saved $DB/env; for f in $B/libvulkan_freedreno.dylib $B/options/default/NegroniMetal; do [ -f \$f.bench-saved ] && mv -f \$f.bench-saved \$f; done; true" || { say "no SSH"; exit 2; }
old_option=$(phone "cat $DB/option 2>/dev/null")
phone "cp $DB/env $DB/env.bench-saved; cp $DB/option $DB/option.bench-saved" || { say "no SSH"; exit 2; }
restore() {
  [ "${NO_RESTORE:-0}" = 1 ] && { say "stays: option default, env and files of this run"; return; }
  back "$B/libvulkan_freedreno.dylib"; back "$B/options/default/NegroniMetal"
  phone "tail -c +${meta_at:-1} $DB/metal.log; rm -f $DB/telemetry" > "$REPO/logs/bench-$name.metal.log" 2>/dev/null
  # With no SSH here, the copies stay on the phone, and the next run puts them back first.
  if phone "mv -f $DB/env.bench-saved $DB/env; mv -f $DB/option.bench-saved $DB/option"; then say "restored: option $old_option, env"; else say "NOT restored: no SSH: option and env stay until the next run"; fi
  restart_ui
}
trap restore EXIT
[ -z "${TURNIP:-}" ] || put "$TURNIP" "$B/libvulkan_freedreno.dylib"
[ -z "${PLUGIN:-}" ] || put "$PLUGIN" "$B/options/default/NegroniMetal"
{ phone "printf '%s\n' default > $DB/option; touch $DB/telemetry"; meta_at=$(phone "wc -c < $DB/metal.log"); for e in ${extra[@]+"${extra[@]}"}; do phone "printf '%s\n' '$e' >> $DB/env"; done; }
# Another agent's test can leave the GPU off until a reboot (LAUREL GPU: off, then NoDevice at each open). Then this run reboots the phone once: the standing order allows it.
main_log() { local m; m=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p'); ls -t "$REPO"/logs/usblog-*.txt "$m"/logs/usblog-*.txt 2>/dev/null | head -1; }
LOG=$(main_log)
log_at() { wc -c < "$LOG"; }
gpu_lost_since() { tail -c +"$1" "$LOG" | grep -aqE 'open refused: device: NoDevice|LAUREL GPU: off|Metal device refused'; }
reboots=0
say "env: $(phone "cat $DB/env.bench-saved | grep -v '^#' | tr '\n' ' '") + ${extra[*]:-nothing}"
while :; do
  at=$(log_at)
  restart_ui
  "$SSHP" wait 120 >/dev/null
  say "UI restarted; waiting $SETTLE_S s"
  sleep "$SETTLE_S"
  gpu_lost_since "$at" || break
  [ "$reboots" = 0 ] || { say "the GPU is off after a reboot too"; exit 5; }
  reboots=1
  say "the GPU is off (an earlier test): reboot"
  "$SSHP" reboot -f || true
  sleep 40
  "$SSHP" wait 300 >/dev/null || { say "no SSH after the reboot"; exit 5; }
  sleep 30
done
# The first minutes of a boot hold the start's load (chronod, dasd, iconservicesagent: 377 s busy of 480 at 2 min, run s9): a run there measures that load. SETTLE_UP_S=0: no wait.
OP=$REPO/out/bin/op10tool; [ -x "$OP" ] || OP=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')/out/bin/op10tool
while up=$("$OP" ctl state 2>/dev/null | sed -n '1s/.*up=\([0-9]*\).*/\1/p'); [ "${up:-0}" -lt "${SETTLE_UP_S:-420}" ]; do
  say "uptime ${up:-none} s: waiting until ${SETTLE_UP_S:-420} s"
  sleep 20
  settle_tries=$((${settle_tries:-0} + 1))
  [ "$settle_tries" -le 45 ] || { say "no settled phone in 900 s: last uptime ${up:-none}"; exit 6; }
done
active=$(phone "head -c 100 $DB/stack/active 2>/dev/null")
case "$active" in default*) ;; *) say "NOT stack default: $active"; exit 3 ;; esac
# WARMUP=1: the test once before the measure: a new Turnip file means no pipeline cache, and pipelines compiled in the middle of a motion measure the compiler.
if [ "${WARMUP:-1}" = 1 ]; then
  "$REPO/scripts/laurel/ios26-autotest.sh" run "$@" > /dev/null 2>&1 || true
  say "warm-up done"
fi
rc=0
t=$(mktemp)
start=$(log_at)
cpu() { phone 'for n in backboardd SpringBoard; do p=; for w in $(ps -ax -o pid=,comm= | grep "/$n\$"); do p=$w; break; done; echo "== $n $p"; ps -M -p $p | cut -c1-60; done'; }
cpu0=$(cpu)
# CORES_S=N: how the CPU time of the UI's processes splits over Gold and Silver, in the N seconds of the test
if [ -n "${CORES_S:-}" ]; then
  phone "/usr/local/bin/laurel-autotest cpus $CORES_S" > "$REPO/logs/bench-$name.cpus" 2>&1 &
  phone 'L=; for n in backboardd SpringBoard; do for w in $(ps -ax -o pid=,comm= | grep "/$n\$"); do L="$L $w"; break; done; done; echo pids $L; /usr/local/bin/laurel-autotest cores '"$CORES_S"' $L' > "$REPO/logs/bench-$name.cores" 2>&1 &
fi
# SAMPLE_S=N: where backboardd's and SpringBoard's threads spend their time, for N seconds (scripts/laurel/ios26-sample-sym.py logs/bench-NAME.samples). SAMPLE_ALL=all: all threads, which changes the cadence at 100 Hz; SAMPLE_ALL=only=N,N: only these threads; SAMPLE_SB=only=N: SpringBoard's own list (default SAMPLE_ALL). SAMPLE_HZ (default 100).
if [ -n "${SAMPLE_S:-}" ]; then
  phone 'for w in $(ps -ax -o pid=,comm= | grep "/backboardd$"); do /usr/local/bin/laurel-autotest sample $w '"$SAMPLE_S"' '"${SAMPLE_HZ:-100}"' '"${SAMPLE_ALL:-}"'; break; done' > "$REPO/logs/bench-$name.samples" 2>/dev/null &
  phone 'for w in $(ps -ax -o pid=,comm= | grep "/SpringBoard$"); do /usr/local/bin/laurel-autotest sample $w '"$SAMPLE_S"' '"${SAMPLE_HZ:-100}"' '"${SAMPLE_SB:-${SAMPLE_ALL:-}}"'; break; done' > "$REPO/logs/bench-$name.sb.samples" 2>/dev/null &
fi
"$REPO/scripts/laurel/ios26-autotest.sh" run "$@" 2>&1 | tee "$t" || rc=$?
{ echo "bench $name: env + ${extra[*]:-nothing}"; sed -n '/^Mi A3 iOS 26 UI test/,$p' "$t"; } > "$REPO/logs/bench-$name.txt"
rm -f "$t"
cpu1=$(cpu)
python3 -I "$REPO/scripts/laurel/ios26-thread-cpu.py" <(printf '%s\n' "$cpu0") <(printf '%s\n' "$cpu1") | tee -a "$REPO/logs/bench-$name.txt"
tail -c +"$start" "$LOG" | grep -aE 'LAUREL GPU PASS|LAUREL FRAME|RedwoodGPU: [0-9]+ submissions|LAUREL FLIP' > "$REPO/logs/bench-$name.kernel.txt"
python3 -I "$REPO/scripts/laurel/ios26-gpu-pass-sum.py" "$REPO/logs/bench-$name.kernel.txt" | tee -a "$REPO/logs/bench-$name.txt"
say "table: logs/bench-$name.txt (test exit $rc)"
exit "$rc"
