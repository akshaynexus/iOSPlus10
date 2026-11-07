#!/bin/sh
# Mi A3 (laurel_sprout) guardian: the iOS 26 test loop needs no key press (owner, 2026-11-07: "if a panic happens it should go back to
# fastboot mode once the logs are given"). Kernel 3090 lands every panic in fastboot, 3091 turns a dead USB link into such a panic, the PMIC
# watchdog (3030, mu 0202) resets a hang with no CPU. This job is the host side: docs/laurel_sprout/self-recovery.md.
#   scripts/bg.sh phone-guardian scripts/laurel/phone-guardian.sh          the loop, in tmux (survives the agent session)
#   scripts/laurel/phone-guardian.sh note-flash IMG [WHO]                  record: IMG is on boot_b now (every flasher calls this)
#   scripts/laurel/phone-guardian.sh queue IMG                             flash IMG at the next fastboot (the Android guard checks it)
#   scripts/laurel/phone-guardian.sh mark-good                             by hand: the image on boot_b is good now
#   scripts/laurel/phone-guardian.sh status                                the records and the last log lines
# What it does, one line per action in logs/phone-guardian.log:
#   fastboot, and no job holds phone-lock for FREE_S (3 s; a fastboot visit lasted 18 s twice on 2026-11-07 07:23 and 07:29 [U why]):
#     takes the lock; `getvar product` once (laurel_sprout, or no answer); the queued image, or the last good image after FAIL_LIMIT (3)
#     boots in a row that did not reach SSH, goes to boot_b at once (this ABL fails every second command of a session: each command is
#     sent twice when the first try fails, no `reboot bootloader` round trip); then set_active b (slot b active, ABL's retries back to
#     7 [I ABL SetActiveSlot]), then fastboot reboot. No image to flash: set_active b + reboot only. About 10 s in all.
#   iOS with an image queued and ctl answering (pong): `op10tool ctl bootloader` at once, and the fastboot step flashes it.
#   iOS on USB (1209:0001): SSH for GOOD_S (10 min) with no panic = the image on boot_b is good: a copy in out/laurel/guardian/last-good.img,
#     and mark-kernel-good.sh for the menu's own fallback entry. No SSH and no pong for NOSSH_S: one `op10tool ctl bootloader` per 5 min.
#   Android on adb (slot a: ABL's retries ran out, or the menu's Android entry): after ANDROID_WAIT_S with the lock free: PON 0x857 read
#     (the PMIC watchdog count must not survive into Android: 00), then the documented way back: ios26-retry.sh FAST_SWITCH=1 (Android must
#     open its data, boot_b + dtbo_b, slot b from fastboot, no Android boot in between). If that fails: adb reboot bootloader, and the
#     fastboot step above flashes the last good image.
#   nothing on USB: a boot in progress, or a hang before USB: the PMIC watchdog resets it (case C/D); logged once.
# Never: fastboot flashing lock, writes to any partition but boot_b, set_active a, the GPT, userdata; no adb to a device that is not
# laurel_sprout by ro.product.device; no serial in any output. A file out/laurel/guardian/pause stops every action (the loop only logs).
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
G=$REPO/out/laurel/guardian
LOG=$REPO/logs/phone-guardian.log
mkdir -p "$G" "$REPO/logs"
FREE_S=${FREE_S:-3}; GOOD_S=${GOOD_S:-600}; NOSSH_S=${NOSSH_S:-300}; FAIL_LIMIT=${FAIL_LIMIT:-3}; ANDROID_WAIT_S=${ANDROID_WAIT_S:-120}
TICK=${TICK:-5}; LEAVE_S=${LEAVE_S:-12}
TOOL=${OP10TOOL:-$REPO/out/bin/op10tool}
EXTRA=${GUARDIAN_EXTRA_ARGS:-"ufsqueue=0 laurelucache=0"}
PL=${PHONE_LOCK:-/tmp/iosplus10-phone.lock}      # the test gives its own
STOCK_DTBO=${STOCK_DTBO:-$HOME/laurel-backup/stock/images/dtbo.img}

now() { date +%s; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') guardian: $*" >> "$LOG"; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
rec() { cat "$G/$1" 2>/dev/null || echo "${2:-}"; }
set_rec() { printf '%s\n' "$2" > "$G/$1"; }

# ---- records ----
note_flash() {
  img=$1; who=${2:-flash}
  [ -f "$img" ] || { echo "guardian: note-flash: no such image $img" >&2; return 1; }
  cp -f "$img" "$G/flashed.img.new" && mv -f "$G/flashed.img.new" "$G/flashed.img"
  [ ! -f "$img.stamp" ] || cp -f "$img.stamp" "$G/flashed.img.stamp"
  [ ! -f "$img.dualboot" ] || cp -f "$img.dualboot" "$G/flashed.img.dualboot"
  printf 'sha256 %s\nwhen %s\nsource %s\nwho %s\n' "$(sha "$img")" "$(date -u +%Y%m%dT%H%M%SZ)" "$img" "$who" > "$G/flashed.txt"
  set_rec fails 0
  set_rec boot_good 0
  log "noted: boot_b = $img ($(sha "$img" | cut -c1-12), by $who); the fail count starts at 0"
}
mark_good() {
  [ -f "$G/flashed.img" ] || { log "mark-good: no record of the image on boot_b (nobody called note-flash): nothing marked"; return 1; }
  if [ "$(sha "$G/flashed.img")" = "$(sha "$G/last-good.img")" ]; then set_rec fails 0; return 0; fi
  cp -f "$G/flashed.img" "$G/last-good.img.new" && mv -f "$G/last-good.img.new" "$G/last-good.img"
  [ ! -f "$G/flashed.img.stamp" ] || cp -f "$G/flashed.img.stamp" "$G/last-good.img.stamp"
  [ ! -f "$G/flashed.img.dualboot" ] || cp -f "$G/flashed.img.dualboot" "$G/last-good.img.dualboot"
  { echo "marked $(date -u +%Y%m%dT%H%M%SZ)"; cat "$G/flashed.txt"; } > "$G/last-good.txt"
  set_rec fails 0
  log "last good image: $(sha "$G/last-good.img" | cut -c1-12) ($(sed -n 's/^line=//p' "$G/last-good.img.stamp" 2>/dev/null | cut -c1-40))"
  # the menu's own fallback entry (mu 0202): the kernel of this image, when a built copy with its stamp still exists
  want=$(sed -n 's/^kernel_sha256=//p' "$G/last-good.img.stamp" 2>/dev/null)
  if [ -n "$want" ]; then
    for k in "$REPO"/out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k "$HOME"/.t3/worktrees/iOSPlus10/*/out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k; do
      [ -f "$k" ] && [ -f "$k.stamp" ] || continue
      if [ "$(sha "$k")" = "$want" ]; then
        if out=$(sh "$REPO/scripts/laurel/mark-kernel-good.sh" "$k" 2>&1); then log "menu fallback: $out"; else log "menu fallback: mark-kernel-good failed: $(echo "$out" | tail -n 1)"; fi
        break
      fi
    done
  fi
}
status() {
  echo "guardian records in $G:"
  for f in flashed.txt last-good.txt fails boot_good; do [ -f "$G/$f" ] && { echo "-- $f"; cat "$G/$f"; }; done
  [ ! -f "$G/queue.img" ] || echo "-- queued: $G/queue.img ($(sha "$G/queue.img" | cut -c1-12))"
  [ ! -f "$G/pause" ] || echo "-- PAUSED (out/laurel/guardian/pause exists)"
  echo "-- log"; tail -n 20 "$LOG" 2>/dev/null
}

case "${1:-}" in
note-flash) note_flash "$2" "${3:-flash}"; exit $? ;;
queue)
  [ -f "$2" ] || { echo "guardian: queue: no such image $2" >&2; exit 1; }
  sh "$REPO/scripts/laurel/android-guard.sh" boot-image "$2" || exit 3
  cp -f "$2" "$G/queue.img.new" && mv -f "$G/queue.img.new" "$G/queue.img"; [ ! -f "$2.stamp" ] || cp -f "$2.stamp" "$G/queue.img.stamp"; [ ! -f "$2.dualboot" ] || cp -f "$2.dualboot" "$G/queue.img.dualboot"
  printf 'source %s\nwhen %s\n' "$2" "$(date -u +%Y%m%dT%H%M%SZ)" > "$G/queue.txt"
  log "queued: $2 ($(sha "$2" | cut -c1-12)) goes to boot_b at the next fastboot"; exit 0 ;;
mark-good) mark_good; exit $? ;;
status) status; exit 0 ;;
"") ;;
*) sed -n 2,22p "$0"; exit 2 ;;
esac

# ---- the phone, read-only ----
fb_present() { timeout 5 fastboot devices 2>/dev/null | grep -q '[[:alnum:]]'; }
ios_present() { lsusb 2>/dev/null | grep -q '1209:0001'; }
# [V 2026-11-02] Another Android phone can be on the same computer: the Mi A3 by its ro.product.device, or nothing.
mi_a3() { for _s in $(timeout 5 adb devices 2>/dev/null | sed -n 's/\tdevice$//p'); do [ "$(timeout 5 adb -s "$_s" shell getprop ro.product.device 2>/dev/null | tr -d '\r')" = laurel_sprout ] && { echo "$_s"; return 0; }; done; return 1; }
ssh_up() { [ "$(timeout 10 sshpass -p "${IOS_PASSWORD:-alpine}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 root@192.168.7.2 uname -s 2>/dev/null)" = Darwin ]; }
pong() { timeout 4 "$TOOL" ctl ping 2>/dev/null | grep -q pong; }
lock_free() { flock -n "$PL" true 2>/dev/null; }
# the same lock as scripts/laurel/phone-lock.sh (file and .who), taken here so the functions run in this shell
take_lock() { exec 9>"$PL"; flock -w 10 9 || { exec 9>&-; return 1; }; echo "guardian since $(date +%H:%M:%S)" > "$PL.who"; }
drop_lock() { : > "$PL.who"; exec 9>&-; }
# [V phone 2026-11-02] after a button entry every second command of a session can fail: ask up to 4 times
fb_get() { for _t in 1 2 3 4; do _v=$(timeout 10 fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'); [ -z "$_v" ] || { echo "$_v"; return 0; }; done; return 1; }
wait_fb() { _c=0; until fb_present; do [ "$_c" -lt "$1" ] || return 1; sleep 2; _c=$((_c + 1)); done; }
fresh_session() { timeout 15 fastboot reboot bootloader >/dev/null 2>&1 || true; sleep 6; wait_fb 20; }

# ---- fastboot: flash or reboot, under the lock ----
# [V 2026-11-07 03:47-04:16] a write as the first command of a session worked, the second command of a session fails; [V 07:23, 07:29] a visit
# can be 18 s long: no getvar rounds, no reboot-bootloader round trip; every command is tried twice (the failing turn passes at once).
fb2() { timeout "$1" fastboot "$2" "$3" ${4:+"$4"} >/dev/null 2>&1 || { fb_present || return 2; timeout "$1" fastboot "$2" "$3" ${4:+"$4"} >/dev/null 2>&1; }; }
fb_recover() {
  p=$(timeout 4 fastboot getvar product 2>&1 | sed -n 's/^product: *//p' | tr -d '\r') || p=
  case "$p" in laurel_sprout|"") ;; *) log "fastboot: the phone says product '$p', not laurel_sprout: nothing done"; return 1 ;; esac
  fails=$(rec fails 0)
  img=; why=
  if [ -f "$G/queue.img" ]; then img=$G/queue.img; why="queued image"
  elif [ "$fails" -ge "$FAIL_LIMIT" ] && [ -f "$G/last-good.img" ] && [ "$(sha "$G/last-good.img")" != "$(sha "$G/flashed.img")" ]; then img=$G/last-good.img; why="$fails boots in a row failed: the last good image"
  elif [ "$fails" -ge "$FAIL_LIMIT" ]; then why="$fails boots in a row failed, no other image to try"
  fi
  if [ -n "$img" ] && ! sh "$REPO/scripts/laurel/android-guard.sh" boot-image "$img" >/dev/null 2>&1; then
    log "fastboot: the Android guard refuses $img: not flashed"; [ "$img" != "$G/queue.img" ] || mv -f "$G/queue.img" "$G/queue.refused.img"; img=
  fi
  flashed=none
  if [ -n "$img" ]; then
    _w=1
    while :; do
      if fb2 120 flash boot_b "$img"; then flashed=ok; break; fi
      fb_present || { log "fastboot: the phone left during the flash (try $_w)"; flashed=failed; break; }
      [ "$_w" -lt 3 ] || { log "fastboot: flash boot_b failed 3 times ($why)"; flashed=failed; break; }
      _w=$((_w + 1)); timeout 15 fastboot reboot bootloader >/dev/null 2>&1 || true; sleep 6; wait_fb 10 || { flashed=failed; break; }
    done
    if [ "$flashed" = ok ]; then
      note_flash "$img" "guardian ($why)" >/dev/null
      [ "$img" != "$G/queue.img" ] || { mv -f "$G/queue.img" "$G/queue.done.img"; rm -f "$G/queue.txt"; }
    fi
  fi
  # slot b active, retries back to 7
  if fb2 15 set_active b; then sa=ok; else sa=failed; fi
  # reboot; repeat until the phone leaves fastboot
  left=no; _r=0
  while [ "$_r" -lt 5 ]; do
    timeout 15 fastboot reboot >/dev/null 2>&1 || true
    sleep "$LEAVE_S"; fb_present || { left=yes; break; }
    _r=$((_r + 1))
  done
  set_rec boot_start "$(now)"; set_rec boot_good 0; set_rec ssh_seen 0
  if [ -n "$img" ]; then fl="$flashed ($why: $(basename "$img") $(sha "$img" | cut -c1-12))"; elif [ -n "$why" ]; then fl="none ($why)"; else fl="none (fails $fails of $FAIL_LIMIT: the image on boot_b boots again)"; fi
  log "fastboot (product '${p:-no answer}'): flash boot_b: $fl; set_active b: $sa; reboot: $( [ "$left" = yes ] && echo "the phone left fastboot" || echo "STILL IN FASTBOOT after 5 tries: only the keys help")"
  [ "$left" = yes ]
}

# ---- Android: the way back to slot b, under the lock ----
android_recover() {
  ser=$1
  r=$(timeout 15 adb -s "$ser" root 2>/dev/null | tr -d '\r' | head -c 80); sleep 3
  v=$(timeout 10 adb -s "$ser" shell 'cat /sys/kernel/debug/regmap/spmi0-00/registers 2>/dev/null | grep "^857:"' 2>/dev/null | tr -d '\r')
  case "$v" in
  857:*) log "android: PON 0x857 = ${v#857: } ($( [ "${v#857: }" = 00 ] && echo "the PMIC watchdog count did not survive into Android" || echo "ARMED: the count survived a reset: read docs/laurel_sprout/self-recovery.md, case D"))"; echo "$(date -u +%Y%m%dT%H%M%SZ) $v" >> "$G/pon-857.txt" ;;
  *) log "android: PON 0x857 not readable (adb root: '${r:-no answer}'; debugfs regmap: '${v:-nothing}')" ;;
  esac
  log "android: slot a: the way back: ios26-retry.sh FAST_SWITCH=1 (Android opens its data, boot_b + dtbo_b, slot b from fastboot)"
  if FAST_SWITCH=1 EXTRA_ARGS="$EXTRA" sh "$REPO/scripts/laurel/ios26-retry.sh" rw > "$REPO/logs/phone-guardian-retry.log" 2>&1; then
    log "android: ios26-retry.sh done: $(tail -n 1 "$REPO/logs/phone-guardian-retry.log")"
    set_rec boot_start "$(now)"; set_rec boot_good 0; set_rec ssh_seen 0
    return 0
  fi
  log "android: ios26-retry.sh failed: $(grep -m1 'STOP:' "$REPO/logs/phone-guardian-retry.log" || tail -n 1 "$REPO/logs/phone-guardian-retry.log"); now adb reboot bootloader, then the fastboot step (the last good image after $FAIL_LIMIT fails)"
  if ser=$(mi_a3); then timeout 20 adb -s "$ser" reboot bootloader >/dev/null 2>&1 || true; fi
  return 1
}

# ---- the loop ----
echo $$ > "$G/pid"       # `kill $(cat out/laurel/guardian/pid)` stops the loop (pkill -f matches the caller's own command line)
state=start; since=$(now); free_since=; nossh_last=0; good_at=0; none_said=0; android_since=
log "start: FREE_S=$FREE_S GOOD_S=$GOOD_S FAIL_LIMIT=$FAIL_LIMIT (fails now $(rec fails 0), last good: $( [ -f "$G/last-good.img" ] && sha "$G/last-good.img" | cut -c1-12 || echo none), on boot_b: $(sed -n 's/^sha256 //p' "$G/flashed.txt" 2>/dev/null | cut -c1-12))"
while :; do
  if fb_present; then s=fastboot
  elif ios_present; then s=ios
  elif ser=$(mi_a3) && [ "$(timeout 5 adb -s "$ser" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then s=android
  else s=none; fi
  if [ "$s" != "$state" ]; then
    t=$(( $(now) - since ))
    # a boot that ends in fastboot or Android before it was good: one more fail
    if [ "$s" = fastboot ] || [ "$s" = android ]; then
      if [ -n "$(rec boot_start)" ] && [ "$(rec boot_good 0)" = 0 ]; then
        f=$(( $(rec fails 0) + 1 )); set_rec fails "$f"
        log "boot failed: $s after $t s in state $state (SSH seen: $( [ "$(rec ssh_seen 0)" = 1 ] && echo yes || echo no)); fails in a row: $f"
      fi
    fi
    log "state: $s (was $state for $t s)"
    state=$s; since=$(now); free_since=; none_said=0; android_since=
  fi
  if [ -f "$G/pause" ]; then sleep "$TICK"; continue; fi
  case "$s" in
  fastboot)
    if lock_free; then
      [ -n "$free_since" ] || free_since=$(now)
      if [ $(( $(now) - free_since )) -ge "$FREE_S" ]; then
        if take_lock; then fb_recover || true; drop_lock; else log "fastboot: phone-lock taken meanwhile by $(cat "$PL.who" 2>/dev/null)"; fi
        free_since=; sleep "$TICK"
      fi
    else free_since=; fi ;;
  ios)
    if [ -f "$G/queue.img" ] && lock_free && [ $(( $(now) - nossh_last )) -ge 60 ] && pong; then
      nossh_last=$(now)
      log "ios: an image is queued and ctl answers: op10tool ctl bootloader (sync over SSH first when it answers)"
      timeout 15 sshpass -p "${IOS_PASSWORD:-alpine}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 root@192.168.7.2 sync >/dev/null 2>&1 || true
      timeout 10 "$TOOL" ctl bootloader >/dev/null 2>&1 || true
      sleep "$TICK"; continue
    fi
    if ssh_up; then
      [ "$(rec ssh_seen 0)" = 1 ] || { set_rec ssh_seen 1; log "ios: SSH up $(( $(now) - since )) s after USB"; good_at=$(now); }
      if [ "$(rec boot_good 0)" = 0 ] && [ $(( $(now) - good_at )) -ge "$GOOD_S" ]; then
        set_rec boot_good 1; set_rec fails 0
        log "ios: SSH for $GOOD_S s: this boot is good"; mark_good || true
      fi
      nossh_last=0
    else
      good_at=$(now)
      if [ $(( $(now) - since )) -ge "$NOSSH_S" ] && [ $(( $(now) - nossh_last )) -ge 300 ] && [ "$(rec ssh_seen 0)" = 0 ]; then
        nossh_last=$(now)
        if pong; then log "ios: no SSH for $(( $(now) - since )) s but ctl answers: waiting"
        else log "ios: no SSH and no pong for $(( $(now) - since )) s: op10tool ctl bootloader (reaches the phone only if its RX is alive)"; timeout 10 "$TOOL" ctl bootloader >/dev/null 2>&1 || true; fi
      fi
    fi ;;
  android)
    [ -n "$android_since" ] || android_since=$(now)
    if [ "${GUARDIAN_ANDROID:-1}" = 1 ] && [ $(( $(now) - android_since )) -ge "$ANDROID_WAIT_S" ] && lock_free; then
      android_since=$(now)
      if take_lock; then android_recover "$ser" || true; drop_lock; fi
    fi ;;
  none)
    if [ "$none_said" = 0 ] && [ $(( $(now) - since )) -ge 120 ]; then none_said=1; log "none: nothing on USB for 120 s: a boot in progress, or a hang before USB (the PMIC watchdog resets it in 62-102 s)"; fi ;;
  esac
  sleep "$TICK"
done
