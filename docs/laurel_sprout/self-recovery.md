# Mi A3: self-recovery of the iOS 26 test loop (no key press)

Date: 2026-11-07. Owner's order: "if a panic happens it should go back to the fastboot mode once the logs are given ... this is not
sustainable for me to always wake up and put it to fastboot for you". Goal: after one more key press (the phone was in case B on kernel
6da502a), the loop never needs the owner's keys again.
Marks: [V] read in a log or code, or run on the host. [I] inference. [U] unknown until the phone shows it.

Pieces: kernel patches `patches/laurel/xnu/3090-laurel-panic-fastboot.patch` and `3091-laurel-usb-check.patch` (both kernels), the host
job `scripts/laurel/phone-guardian.sh`, and the PMIC watchdog of 3030 + mu 0202 now on by default (no `laurelpmicwdog=0` in the images).
Host tests: `scripts/laurel/usb-check-test.sh` (the rules of 3091 and the text of 3090, 23 checks [V PASS]), `scripts/laurel/phone-guardian-test.sh`
(the guardian against fake fastboot/adb/lsusb/ssh, 25 checks [V PASS]).

## 1. The cases, before and now

| Case | Before (2026-11-07 morning) | Now | Time to recover | Off switch |
|---|---|---|---|---|
| A. Panic (a bark on a stuck CPU, a lock panic, any panic) | the USB hold sent the log, `laurelpanic=30` or 2990 reset into a NORMAL boot; after 6 such boots ABL's retries of slot b ran out: Android, or a loop; keys | **3090**: the hold sends the log, waits 30 s for a host command (`op10tool ctl ...` keeps working), then resets into **fastboot**. The guardian sees fastboot, waits 20 s for a free phone-lock, `set_active b` (retries back to 7 [I]), `fastboot reboot`. After 3 boots in a row that did not reach SSH it flashes the last good image instead | panic + 30 s (bark: 20 s) + 20 s + about 15 s of fastboot work | `laurelpanicfb=0` (normal boot as before); `laurelpanic=N` the wait, `=0` for ever |
| B. USB gadget RX dies while iOS runs (3052 has the cause) | the log kept coming, no panic, no bark; `ctl` never arrived; keys | **3052** removes the cause. **3091** catches the next one: no frame from a configured host for 30 s (usblog.sh sends a keepalive every 10 s): 3 ARP asks of the host (2 s apart), RX endpoint re-armed + 1 ask, gadget restart (the host enumerates again, 20 s) + 1 ask, then `panic("LAUREL USB CHECK: RX dead ...")`, which is case A | at most about 60 s to the panic, then case A | `laurelusbcheck=0` |
| C. Early hang before USB (a bad patch at PE_init) | nothing; keys | the menu arms the PMIC count before the kernel (mu 0202): a hard reset by the PMIC 102 s after the jump, ABL takes one retry, the menu boots the same kernel again; from the second fail in a row the menu's default is the last good kernel (`ios-lastgood`, boot-menu.md section 10) when one is marked; after 7 fails ABL boots Android, and the guardian brings the phone back to slot b from Android (section 3) | 102 s per boot | `laurelpmicwdog=0` in EXTRA_ARGS |
| D. Total hang of all CPUs (the APSS bite does not reset here) | nothing; keys | the kernel's PMIC count (3030): no pet for 60 s + 2 s = hard reset by the PMIC, then as case C | 62 s + a boot | `laurelpmicwdog=0` |
| E. Fastboot fails every second command | scripts retried by hand | the guardian writes as the FIRST command of a fresh session (`fastboot reboot bootloader` first), one fresh session per write (flash, set_active), and reboots until the phone leaves fastboot (5 rounds) | | |
| Android after the retries ran out | a flash from Android by hand | the guardian: after 120 s on Android with the lock free: reads PON 0x857 (section 4), then `ios26-retry.sh FAST_SWITCH=1` (Android must open its data, boot_b + dtbo_b, slot b from fastboot, no Android boot in between); if that fails, `adb reboot bootloader` and the fastboot step with the last good image | about 5 min | file `out/laurel/guardian/pause`, or `GUARDIAN_ANDROID=0` |

What stays with the keys [I]: a phone that stops in fastboot with no host on the cable; a Mu that dies before the menu 7 times in a row with slot a not bootable (ABL stops in fastboot: the guardian handles that too, as long as the host is there); a dead cable.

## 2. Kernel: 3090 panic landing

`LAUREL PANIC LANDING: on: a panic holds 30 s for a host command (op10tool ctl ...), then resets into fastboot; no USB: fastboot after 30 s;
laurelpanicfb=0 for a normal boot, laurelpanic=N for the wait` at boot, after the PON self-check of 2018 (the fastboot mode is SOFT_RB_SPARE
reason 2 + a warm reset, the path `ctl bootloader` uses [V lands in fastboot on this phone]). No PON lane: `off`, a normal boot.

The three reset paths of a panic now set the mode `bootloader` (`laurel_panic_mode()`): the timed reset of the USB hold (`LAUREL PANIC: N s over: reset,
mode bootloader`), the reset of a panic with no USB hold (`LAUREL PANIC: no USB hold: reset in N s, mode bootloader`), the nested panic in the hold.
A USB command in the hold keeps its own mode. `laurelpanic` not given: 30 s (before: for ever); `laurelpanic=0`: for ever (bring-up); a bark keeps
its 20 s (2990). In the hold line: `LAUREL PANIC: holding 30 s for a host command (op10tool ctl bootloader|reboot|poweroff), then a reset into fastboot`.

## 3. Host: the guardian

`scripts/bg.sh phone-guardian scripts/laurel/phone-guardian.sh` (tmux, survives the agent session). Log: `logs/phone-guardian.log`, one line per
action and per state change. Records in `out/laurel/guardian/`: `flashed.img` + `flashed.txt` (what is on boot_b: every flasher calls
`phone-guardian.sh note-flash IMG WHO`: `ios26-fast-flash.sh`, `dual-boot.sh flash-slot-b`, the guardian itself), `last-good.img` (a boot that
reached SSH and kept it for 10 min), `fails` (boots in a row that ended in fastboot or Android before that), `queue.img` (`phone-guardian.sh queue IMG`:
an agent's new image, checked by `android-guard.sh`, flashed at the next fastboot), `pon-857.txt`, `pause`.

States, read-only, every 5 s: `fastboot devices` (no serial printed), `lsusb` 1209:0001 (iOS), adb only to the device whose `ro.product.device` is
`laurel_sprout` (the Nothing phone OP611FL1 on the same computer gets `getprop ro.product.device` and nothing else [V test]).

| State | Action |
|---|---|
| fastboot, phone-lock free for 20 s | takes the lock (the same flock as phone-lock.sh); `getvar product` must say laurel_sprout; the image: queued > last good after 3 fails > none; the flash as the first command of a fresh session, up to 4 sessions; `set_active b` in a fresh session (verified by `current-slot`, 3 tries); `fastboot reboot`, repeated from fresh sessions until the phone leaves (5 rounds, else `STILL IN FASTBOOT ... only the keys help`) |
| iOS, SSH | first SSH: `ios: SSH up N s after USB`; 10 min of SSH: `this boot is good`, last-good.img = flashed.img, fails = 0, `mark-kernel-good.sh` for the menu's entry when the kernel of the image's stamp is still on disk |
| iOS, no SSH for 5 min | `ctl ping`; no pong: one `ctl bootloader` per 5 min (reaches the phone only with a live RX; 3091 does the rest) |
| Android | section 1, last row |
| nothing on USB for 120 s | one line; the PMIC watchdog does the work |

Never: `fastboot flashing`, `erase`, `oem`, `set_active a`, any partition but `boot_b`, the GPT, userdata, a serial in the log [V test case 7].

## 4. The PMIC watchdog, on by default

Case D of watchdog.md section 15: `laurelpmicwdog=0` was in every image until the PON 0x857 check in Android (a count that survives a hard reset into
Android would reset Android 102 s into every boot). Now: the images carry no `laurelpmicwdog=0`. The check runs by itself: the first time the guardian
finds the phone on Android it reads `/sys/kernel/debug/regmap/spmi0-00/registers` line `857:` over root adb and logs `android: PON 0x857 = 00 (the PMIC
watchdog count did not survive into Android)` or `ARMED`; the value goes to `out/laurel/guardian/pon-857.txt`. [I] a hard reset (type 7) power-cycles
the PMIC's registers; [U] on this PM6125. Exposure if it survives: only the boot on which ABL's retries run out at the very moment of a PMIC reset
(every other path goes through the menu, which disarms a count it finds [V code]); the guardian then sees Android twice, 102 s apart, and the
second Android boot runs clean; its line says `ARMED`. If that line appears: put `laurelpmicwdog=0` back in `GUARDIAN_EXTRA_ARGS` and the flash scripts.

The PMIC reset lands in a normal boot (the menu), not in fastboot: the hard reset clears the SOFT_RB_SPARE reason [I], and a warm reset type would
keep the count armed into fastboot. The menu's last-good entry (mu 0202) and ABL's retries are the ladder for cases C and D; the guardian takes
over on Android.

## 5. What the phone must show (the one key press, then never)

1. Boot of the image with 3052 + 3090 + 3091: `LAUREL PANIC LANDING: on`, `LAUREL USB CHECK: on`, `LAUREL PMIC WDOG: on ... found armed, hard reset (the boot loader)`.
2. A panic (the next bark, or `op10tool ctl panic`): `LAUREL PANIC: holding 30 s ...`, `LAUREL PANIC: 30 s over: reset, mode bootloader`, `LAUREL REBOOT: PON SOFT_RB_SPARE ... (reason 2), warm reset`, then `guardian: state: fastboot`, `guardian: fastboot (slot b): ... set_active b: ok; reboot: the phone left fastboot`, then a boot.
3. 10 min of SSH: `guardian: ios: SSH for 600 s: this boot is good`, `last good image: ...`.
4. The menu after a `set_active b`: its notice line must not say `iOS failed N boots` (the retries are back at 7) [I ABL SetActiveSlot].
5. The next RX death, if any: `LAUREL USB CHECK: no frame from the host for 30 s: asking it by ARP`, then either `RX back after ...` or the panic.

## 6. Results on the phone

- [V `logs/phone-guardian.log`] 07:23:16 fastboot (the owner's keys), gone after 18 s with no command from the guardian (FREE_S was 20 s then); the phone booted the image on boot_b (ae838bd: 3052, no 3090/3091) and stood before launchd; 07:29:26 `ctl bootloader` (by the main agent): fastboot 07:29:33, gone after 18 s again; nothing on USB since 07:29:51. Both visits ended before any host command [V: no `fastboot (` line, and no `fastboot` process of ours].
- [V `logs/usblog-20261107-034407.txt` 07:25:13] `LAUREL PMIC WDOG: off: laurelpmicwdog=0; found off (S1 31 s S2 1 s type 1 enable 0x00): disarmed`: the PMIC watchdog was off and found disarmed at the boot right after the first 18 s visit, and that image's args had `laurelpmicwdog=0`, so the menu armed nothing [V code]. The suspicion that the PMIC count resets ABL's fastboot is not what happened [V]. 18 s matches no timer of ours (PMIC 62/102 s, APSS 20 s bite found `EN 0x0` at boot, 2955 Power-key hold 8.7 s needs the key). [U] what ends the visit: a `fastboot reboot` from another agent's shell is the simplest reading (the bench jobs and the two flash jobs of the other agents do not run fastboot [V their logs]); a 18 s ABL limit is unknown on this phone (visits of 03:47-04:16 lasted minutes).
- The guardian now acts within FREE_S = 3 s, with no `getvar` rounds and no `reboot bootloader` round trip (each command twice, the failing turn passes at once), and asks iOS for fastboot itself (`ctl bootloader`) when an image is queued and `ctl ping` answers.
- The disarm on the bootloader paths [V code]: `laurel_restart` (every `ctl` reset and every 3090 reset goes through it) calls `laurel_wdog_stop` and `laurel_pmic_wdog_stop("reset")` before the PSCI reset; the menu disarms a count it finds at its start (mu 0202). ABL cannot pet: a count that reaches fastboot would end it at 62 s (kernel) or 102 s (menu), not 18 s.
- 07:44: the phone is dark on USB (no fastboot, no iOS, no adb) since 07:29:51: a hang before USB on ae838bd, with the PMIC watchdog off in that image: case C with no way in from the host. The next key press lands in fastboot, where the guardian flashes the queued image (3052 + 3090 + 3091, PMIC watchdog on) within seconds.
