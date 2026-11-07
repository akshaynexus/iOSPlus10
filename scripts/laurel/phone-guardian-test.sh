#!/bin/sh
# Host test of scripts/laurel/phone-guardian.sh with fake fastboot, adb, lsusb, ssh and op10tool (out/guardian-test/bin). The fake ABL fails every
# second command of a session, as the phone's does; `reboot bootloader` starts a fresh session. Every call is written to calls.txt. Result: PASS, exit 0.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
D=$REPO/out/guardian-test
rm -rf "${D:?}"; mkdir -p "$D/bin" "$D/repo/scripts/laurel" "$D/repo/out/laurel/guardian" "$D/repo/logs"
F=$D/fake
: > "$D/calls.txt"
echo none > "$F.state"          # none | fastboot | ios | ios-ssh | android | android-other
echo 0 > "$F.turn"
# ---- fakes ----
cat > "$D/bin/fastboot" <<SH
#!/bin/sh
echo "fastboot \$*" >> "$D/calls.txt"
st=\$(cat "$F.state")
case "\$1" in
devices) [ "\$st" = fastboot ] && echo "SERIALXYZ	fastboot"; exit 0 ;;
esac
[ "\$st" = fastboot ] || { echo "< waiting for any device >" >&2; sleep 1; exit 1; }
turn=\$(( \$(cat "$F.turn") + 1 )); echo \$turn > "$F.turn"
case "\$1 \${2:-}" in
"reboot bootloader") echo 0 > "$F.turn"; exit 0 ;;
"reboot ") echo ios > "$F.state"; exit 0 ;;
esac
# every second command of a session fails (the phone's ABL)
[ \$(( turn % 2 )) = 1 ] || { echo "FAILED (remote: 'GetVar Variable Not found')" >&2; exit 1; }
case "\$1 \${2:-}" in
"getvar product") echo "product: laurel_sprout" >&2 ;;
"getvar current-slot") echo "current-slot: \$(cat "$F.slot")" >&2 ;;
"set_active b") echo b > "$F.slot" ;;
"flash boot_b") cp "\$3" "$F.boot_b"; echo "Finished. Total time: 2.0s" >&2 ;;
*) echo "FAILED (remote: unknown command)" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$D/bin/adb" <<SH
#!/bin/sh
echo "adb \$*" >> "$D/calls.txt"
st=\$(cat "$F.state")
case "\$1" in
devices) echo "List of devices attached"; [ "\$st" = android ] && printf 'MIA3SERIAL\tdevice\n'; [ "\$st" = android-other ] && printf 'OP611FL1XX\tdevice\n'; exit 0 ;;
esac
[ "\$1" = -s ] || { echo "fake adb: every call must name a serial" >&2; exit 1; }
ser=\$2; shift 2
case "\$ser:\$1 \${2:-} \${3:-}" in
MIA3SERIAL:"shell getprop ro.product.device") echo laurel_sprout ;;
OP611FL1XX:"shell getprop ro.product.device") echo OP611FL1 ;;
OP611FL1XX:*) echo "OTHER PHONE TOUCHED: \$*" >> "$D/calls.txt"; exit 1 ;;
MIA3SERIAL:"shell getprop sys.boot_completed") echo 1 ;;
MIA3SERIAL:"root  ") echo "restarting adbd as root" ;;
MIA3SERIAL:"shell cat /sys/kernel/debug/regmap/spmi0-00/registers"*) echo "857: 00" ;;
MIA3SERIAL:"reboot bootloader ") echo fastboot > "$F.state"; echo 0 > "$F.turn" ;;
esac
exit 0
SH
cat > "$D/bin/lsusb" <<SH
#!/bin/sh
st=\$(cat "$F.state"); case "\$st" in ios*) echo "Bus 003 Device 017: ID 1209:0001 Generic pid.codes Test PID" ;; esac; exit 0
SH
cat > "$D/bin/sshpass" <<SH
#!/bin/sh
echo "ssh" >> "$D/calls.txt"; [ "\$(cat "$F.state")" = ios-ssh ] && echo Darwin; exit 0
SH
cat > "$D/bin/op10tool" <<SH
#!/bin/sh
echo "op10tool \$*" >> "$D/calls.txt"
case "\$2" in ping) [ -f "$F.pong" ] && { echo pong; exit 0; }; exit 1 ;; bootloader) echo fastboot > "$F.state"; echo 0 > "$F.turn"; exit 0 ;; esac; exit 1
SH
cat > "$D/bin/timeout" <<SH
#!/bin/sh
shift; exec "\$@"
SH
cat > "$D/repo/scripts/laurel/ios26-retry.sh" <<SH
#!/bin/sh
echo "ios26-retry FAST_SWITCH=\${FAST_SWITCH:-0} EXTRA_ARGS=\${EXTRA_ARGS:-} \$*" >> "$D/calls.txt"
[ "\${FAST_SWITCH:-0}" = 1 ] || exit 1
echo b > "$F.slot"; echo ios > "$F.state"; echo "done: iOS 26 is booting"
SH
cat > "$D/repo/scripts/laurel/android-guard.sh" <<SH
#!/bin/sh
echo "android-guard \$*" >> "$D/calls.txt"; case "\$2" in *refused*) exit 3 ;; esac; exit 0
SH
cat > "$D/repo/scripts/laurel/mark-kernel-good.sh" <<SH
#!/bin/sh
echo "mark-kernel-good \$*" >> "$D/calls.txt"; echo "mark-kernel-good: ok"
SH
chmod +x "$D"/bin/* "$D"/repo/scripts/laurel/*.sh
cp "$REPO/scripts/laurel/phone-guardian.sh" "$D/repo/scripts/laurel/"
G=$D/repo/out/laurel/guardian
LOG=$D/repo/logs/phone-guardian.log
printf 'image A' > "$D/imgA"; printf 'line=aaaa\nkernel_sha256=none\n' > "$D/imgA.stamp"
printf 'image B' > "$D/imgB"; printf 'line=bbbb\nkernel_sha256=none\n' > "$D/imgB.stamp"
echo b > "$F.slot"
PATH="$D/bin:$PATH"; export PATH
PHONE_LOCK=$D/phone.lock; export PHONE_LOCK
fails=0; checks=0
ok() { checks=$((checks + 1)); }
bad() { fails=$((fails + 1)); echo "FAIL: $*"; }
first_after_fresh() { awk '/^fastboot reboot bootloader$/ { f = 1; next } f && !/^fastboot devices$/ { print; exit }' "$D/calls.txt"; }
run_until() {   # run the loop until the log has the text or 60 s pass
  (cd "$D/repo" && exec env FREE_S=2 TICK=1 LEAVE_S=1 GOOD_S=3 NOSSH_S=4 ANDROID_WAIT_S=2 OP10TOOL="$D/bin/op10tool" sh scripts/laurel/phone-guardian.sh) > "$D/run.out" 2>&1 &
  pid=$!
  n=0; until grep -q -- "$1" "$LOG" 2>/dev/null || [ "$n" -ge 60 ]; do sleep 1; n=$((n + 1)); done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  { echo "== until '$1'"; cat "$LOG"; } >> "$D/all.log"
  grep -q -- "$1" "$LOG" || bad "no '$1' in the log within 60 s; log: $(tail -n 3 "$LOG")"
}
PL=$PHONE_LOCK

# 1. fastboot, nothing queued, no fails: no flash; set_active b as the first command of a fresh session; reboot; the phone leaves
: > "$D/calls.txt"; echo fastboot > "$F.state"
run_until "reboot: the phone left fastboot"
grep -q "flash boot_b: none (fails 0 of 3" "$LOG" && ok || bad "case 1: expected no flash: $(grep fastboot "$LOG" | tail -1)"
grep -q "^fastboot reboot bootloader" "$D/calls.txt" && bad "case 1: a reboot-bootloader round trip (a visit can be 18 s)" || ok
grep -q "set_active b: ok (try" "$LOG" && ok || bad "case 1: set_active not ok"
grep -q "^fastboot flash" "$D/calls.txt" && bad "case 1: a flash happened" || ok
[ "$(cat "$F.state")" = ios ] && ok || bad "case 1: the phone did not leave fastboot"

# 2. the lock is held: the guardian waits and does nothing
: > "$D/calls.txt"; : > "$LOG"; echo fastboot > "$F.state"
( exec 9>"$PL"; flock 9; sleep 8 ) & lp=$!
sleep 1
(cd "$D/repo" && exec env FREE_S=2 TICK=1 LEAVE_S=1 sh scripts/laurel/phone-guardian.sh) > "$D/run.out" 2>&1 & gp=$!
sleep 5; kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null || true; wait "$lp" 2>/dev/null || true
grep -q "^fastboot set_active\|^fastboot flash\|^fastboot reboot" "$D/calls.txt" && bad "case 2: acted while the lock was held" || ok

# 3. a queued image: flashed as the first command of a fresh session, the Android guard asked first, then noted as boot_b
: > "$D/calls.txt"; : > "$LOG"; echo fastboot > "$F.state"; rm -f "${G:?}"/*
(cd "$D/repo" && sh scripts/laurel/phone-guardian.sh queue "$D/imgA" >/dev/null)
[ -f "$G/queue.img" ] && ok || bad "case 3: queue not recorded"
run_until "reboot: the phone left fastboot"
[ "$(grep -c '^fastboot flash boot_b' "$D/calls.txt")" -le 2 ] && ok || bad "case 3: more than two flash tries"
grep -q "^android-guard boot-image" "$D/calls.txt" && ok || bad "case 3: the Android guard was not asked"
cmp -s "$F.boot_b" "$D/imgA" && ok || bad "case 3: boot_b is not image A"
[ ! -f "$G/queue.img" ] && [ "$(sed -n 's/^sha256 //p' "$G/flashed.txt")" = "$(sha256sum "$D/imgA" | cut -d' ' -f1)" ] && ok || bad "case 3: flashed record wrong"
grep -q "flash boot_b: ok (queued image" "$LOG" && ok || bad "case 3: log line: $(grep 'fastboot (slot' "$LOG")"

# 4. a good boot: SSH for GOOD_S: last-good = the flashed image, fails 0
: > "$D/calls.txt"; : > "$LOG"; echo ios-ssh > "$F.state"; echo 0 > "$G/boot_good"; echo 2 > "$G/fails"
run_until "this boot is good"
sleep 1
cmp -s "$G/last-good.img" "$D/imgA" && ok || bad "case 4: last-good is not image A"
[ "$(cat "$G/fails")" = 0 ] && ok || bad "case 4: fails not 0"

# 5. three failed boots in a row with a different image on boot_b: the last good image is flashed
: > "$D/calls.txt"; : > "$LOG"
(cd "$D/repo" && sh scripts/laurel/phone-guardian.sh note-flash "$D/imgB" test >/dev/null)
echo 3 > "$G/fails"; echo fastboot > "$F.state"; echo 0 > "$G/boot_good"; echo 1 > "$G/boot_start"
run_until "reboot: the phone left fastboot"
grep -q "boot failed: fastboot" "$LOG" && ok || bad "case 5: the failed boot was not counted"
grep -q "flash boot_b: ok ([0-9]* boots in a row failed: the last good image" "$LOG" && ok || bad "case 5: last good not flashed: $(grep 'fastboot (slot' "$LOG")"
cmp -s "$F.boot_b" "$D/imgA" && ok || bad "case 5: boot_b is not the last good image"
grep -q "^fastboot flash boot_b $G/last-good.img" "$D/calls.txt" && ok || bad "case 5: last good not flashed"

# 6. Android on slot a (and another phone on adb): PON 0x857 read, ios26-retry.sh FAST_SWITCH=1, the other phone never touched
: > "$D/calls.txt"; : > "$LOG"; echo android > "$F.state"; echo a > "$F.slot"
run_until "ios26-retry.sh done"
grep -q "PON 0x857 = 00" "$LOG" && ok || bad "case 6: no PON read: $(grep android "$LOG" | head -2)"
grep -q "^ios26-retry FAST_SWITCH=1 EXTRA_ARGS=ufsqueue=0 laurelucache=0 rw" "$D/calls.txt" && ok || bad "case 6: retry not called right: $(grep retry "$D/calls.txt")"
[ "$(cat "$F.state")" = ios ] && ok || bad "case 6: not back in iOS"
: > "$D/calls.txt"; : > "$LOG"; echo android-other > "$F.state"
(cd "$D/repo" && exec env TICK=1 sh scripts/laurel/phone-guardian.sh) > "$D/run.out" 2>&1 & gp=$!
sleep 4; kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null || true
grep -q "OTHER PHONE TOUCHED" "$D/calls.txt" && bad "case 6: the other phone got a command" || ok
grep -q "state: android" "$LOG" && bad "case 6: the other phone was taken for the Mi A3" || ok

# 8. iOS, ctl answers, an image queued: the guardian asks for fastboot itself and flashes it
: > "$D/calls.txt"; : > "$LOG"; echo ios > "$F.state"; touch "$F.pong"; rm -f "${G:?}"/queue.*
(cd "$D/repo" && sh scripts/laurel/phone-guardian.sh queue "$D/imgB" >/dev/null)
run_until "reboot: the phone left fastboot"
grep -q "^op10tool ctl bootloader" "$D/calls.txt" && ok || bad "case 8: no ctl bootloader"
cmp -s "$F.boot_b" "$D/imgB" && ok || bad "case 8: boot_b is not the queued image"
rm -f "$F.pong"

# 7. never: forbidden fastboot commands, and no serial in the log
grep -Eq "^fastboot (flashing|erase|oem|format|set_active a|flash (boot_a|dtbo_a|userdata|partition|modemst|fsg|persist|devinfo|vbmeta|gpt))" "$D/calls.txt" && bad "forbidden command" || ok
grep -q "SERIALXYZ\|MIA3SERIAL\|OP611FL1XX" "$LOG" && bad "a serial is in the log" || ok

echo "phone-guardian: $checks checks, $fails failures"
[ "$fails" = 0 ] && echo PASS
[ "$fails" = 0 ]
