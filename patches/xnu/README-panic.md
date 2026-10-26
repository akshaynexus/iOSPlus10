# Panic over USB, ctl after a panic, timed panic reset (0360)

`0360-negroni-panic-usb.patch` keeps the USB link alive after a kernel panic. The panic log goes
to the live log (UDP 5140), the command server (UDP 5141) still takes `ping`, `log`, `reboot`,
`bootloader`, `recovery` and `poweroff`, and `negronipanic=N` now resets after N s.
NEGRONI machine config only. It applies last (after 0353), on top of 0210-0214, 0234, 0244, 0282.

| File | Change |
|---|---|
| `bsd/dev/negroni_usb.c` | panic mode: polled DWC3 events, ARP, ctl, TX of the console ring; `log` command; per-event ack |
| `bsd/dev/negroni_reboot.c` | new `negroni_panic_restart()` hold loop; spin delays (no WFE) in the SPMI/PON code |
| `bsd/dev/negroni_ufs.c` | the panic log (registers, backtrace) goes into the console ring also without the partition log |
| `iokit/Kernel/arm/NegroniPlatformExpert.cpp` | `kPEPanicDiagnosticsDone` enters the hold loop |

## Why `negronipanic=30` did not reset (2026-10-26 panics)

- [V, code] The image had `debug=0xc` (DB_NMI 0x4 + DB_KPRT 0x8). In `osfmk/kern/debug.c`
  (`debug_init`), DB_NMI sets `panicDebugging = TRUE` on arm64.
- [V, code] `debugger_collect_diagnostics()` then never calls `kdp_machine_reboot_type(kPEPanicRestartCPU)`:
  it calls `PEHaltRestart(kPEPanicDiagnosticsDone)`, `panic_spin_shmcon()` ("handshake structure not
  initialized" on the screen comes from the kdp shmem stage, `osfmk/kdp/output_stages/out_shmem.c`), and
  then `panic_spin_forever()`. So `negroni_halt_restart(kPEPanicRestartCPU)` and
  `negroni_panic_restart()` never ran. No reset code ran at all.
- [I] Second risk, also removed: the old loop waited with `delay(1000000)`. In panic context
  `delay()` spins with WFE (`machine_delay_until`), which depends on the timer event stream. A
  busy wait on `mach_absolute_time()` does not.
- Fix: the platform expert hook also takes `kPEPanicDiagnosticsDone` (sent in every panic, after
  SavePanicInfo, whatever `panicDebugging` is) and runs `negroni_panic_restart()` there.
  `kPEPanicRestartCPU` still goes there too (for `debug=0` boot-args).

## Hold loop (`negroni_panic_restart()`, never returns)

1. `nr_in_panic = true`: `printf` in negroni_reboot.c becomes `kdb_printf` (console only, no
   os_log); `nr_wait()` and the PON 500 us wait spin on the counter.
2. `negroni_usb_panic_begin()` (first entry only).
3. One screen line: `NEGRONI PANIC: staying on the panic screen (negronipanic=0); reset with: op10tool ctl bootloader`
   or `NEGRONI PANIC: reset in 30 s (boot-arg negronipanic), reason 2`.
4. Busy loop: `negroni_usb_panic_service()`; a command (reset/power off) runs 500 ms after it arrived;
   at the `negronipanic` deadline `negroni_reboot(negronipanicreason)` (SPMI reason write + PSCI
   SYSTEM_RESET, the same primitives as before: register writes and an SMC, no lock, no thread).
   If a reset returns, the loop prints `reset failed` and continues (ctl still works).
5. A nested entry (a panic inside the loop or the USB code: xnu runs the diagnostics again and
   comes back here) skips USB and keeps only the timed reset.

Default `negronipanic=0`: the panic text stays on the screen for ever (owner's choice), and ctl works.

## USB panic mode (`negroni_usb.c`)

`negroni_usb_panic_begin()` returns false (no USB, silent) when `negroniusb=2` was not set, the
gadget did not start, or `negronipanicusb=0`. Otherwise it sets `ud_in_panic`. From then on:

- No lock, no mbuf allocation/free, no sleep, no os_log. `ud_thread` and `ud_log_thread` stop
  touching the controller (they only sleep, in case a CPU was not halted). printf in
  negroni_usb.c goes to the console ring only (sent over USB, not drawn on the panic screen).
- Events: `GEVNTCOUNT` is polled; each event is acked before it is handled (also in `ud_thread`
  now, so a panic inside `ud_event()` leaves the count and `evt_pos` in step). ep0 enumeration
  works, so a host that connects after the panic gets the link; `ud_link_event()` (dlil) is skipped.
- RX: ARP requests for 192.168.7.2 get a reply (the network stack is dead, and the host must
  resolve the phone MAC to send a command). UDP to 5141 from 192.168.7.1: the commands below.
- TX: one frame on the IN endpoint at a time, built in the DMA TX buffer. Order: command and ARP
  replies; the log/ctl frames that were still on the TX ring before the panic (copied, not
  freed); then the console ring as UDP 192.168.7.2:5140 -> 192.168.7.1:5140 (host MAC
  02:00:5e:77:ee:01), 1400 bytes per frame, at most one frame per 1 ms.
- The console ring flush starts where `ud_log_thread` stopped (`ud_log_sent`; at most the last
  1 MiB). It contains the console text, the panic string and, from `negroni_log_panic()`
  (model_dep.c), the full panic log between `NEGRONI LOG: panic log follows` and
  `NEGRONI LOG: end of panic log` (registers, backtrace, loaded kexts).
- The ring flush (not the replies) waits until a frame from 192.168.7.1 arrives after the
  (re)configuration (usblog.sh sends `settime` when the link comes up), or 10 s. Before the panic,
  any received frame counts. Thus the text does not go out before the Mac has its address.
- A frame that the host does not take in 2 s: ENDTRANSFER (ForceRM) on the IN endpoint, 100 us,
  the same frame again. No text is lost while the cable or the host is away; nothing blocks.

### Commands in panic mode (UDP 5141, same rules as 0210: source 192.168.7.1, `negronictl` on)

| Command | Reply | Action |
|---|---|---|
| `ping` | `pong (panic)` | none |
| `log` | `ok log (panic)` | console ring sent again from 64 KiB back |
| `reboot` / `recovery` / `bootloader` | `ok <cmd> (panic)` | reason 0 / 1 / 2, PSCI SYSTEM_RESET after 500 ms |
| `poweroff` | `ok poweroff (panic)` | `negroni_power_off()` after 500 ms |
| `panic` | `error: already in panic` | none |
| other (also `settime`, `time`) | `error: panic mode: ping log reboot bootloader recovery poweroff` | none |

While an action waits for its 500 ms, a second reset command gets `error: busy`. Log lines (USB
only): `NEGRONI PANIC CTL: "bootloader" -> ok bootloader (panic)`. Screen lines: the start line,
`NEGRONI PANIC: reset, reason 2 (USB command)`, and the `NEGRONI REBOOT:` lines of the reason write.

`log` also works without a panic (0360 adds it to the normal command server: `ud_log_thread`
sends the last 64 KiB again; reply `ok log`).

## Boot-args

| Boot-arg | Default | Effect |
|---|---|---|
| `negronipanic=N` | 0 | reset N s after the panic (now also with `debug=0x4`); 0 = stay |
| `negronipanicreason=N` | 0 | reason of that reset (2 = ABL fastboot) |
| `negronipanicusb=0` | 1 | no USB in the panic hold loop (only the screen and the timed reset) |
| `negronictl=0` | on | no commands (also in panic mode; ARP replies and the log still go out) |

## Host-side test (next panic)

1. `make usblog` (tmux `usblog`, sudo; writes `logs/usblog-<date>.txt`). Leave it running.
2. Boot the image. Look for `NEGRONI CTL: commands on udp 192.168.7.2:5141 on`.
   Optional: `out/bin/op10tool ctl ping` -> `pong`; `out/bin/op10tool ctl log` -> `ok log`.
3. Force a panic if none comes: `out/bin/op10tool ctl panic`.
4. Expect in the usblog file: the panic text, `NEGRONI LOG: panic log follows` ... `end of panic
   log`, then `NEGRONI PANIC: USB configured: console ring N bytes to send ...` and
   `NEGRONI PANIC: staying on the panic screen ...`.
5. `out/bin/op10tool ctl ping` -> `pong (panic) from 192.168.7.2:5141 in ... ms`.
6. If the text did not arrive: `out/bin/op10tool ctl log` (sends the last 64 KiB again).
7. `out/bin/op10tool ctl bootloader` -> `ok bootloader (panic)`; `fastboot devices` within a few s.
8. With `negronipanic=30 negronipanicreason=2`: no command; ABL fastboot 30 s after the panic.

If nothing at all arrives: check on the Mac that the interface with MAC 02:00:5e:77:ee:01 exists
(`ifconfig -a | grep -B3 02:00:5e:77:ee:01`) and has 192.168.7.1. Without the interface the phone
was never enumerated (cable, port); the kernel side cannot help that.

## Not verified (no phone during the work)

- Everything on the device: the polled enumeration, ARP reply, ENDTRANSFER restart, the reset from the
  hold loop. Compile and link only.
- That every panic sends `kPEPanicDiagnosticsDone`: true for the normal panic path of this xnu
  (8796.141.3, `debugger_collect_diagnostics`). The nested-panic "Stage 1/2 bailout" paths with
  `panicDebugging` still spin (they do not call the platform expert again).
- A panic before `NegroniPlatformExpert::start()` (no halt/restart hook yet) still stays for ever.
- A panic while the panicking CPU held the TX ring half updated: the ring is read without a lock;
  a bad entry is skipped by the length/UDP checks.

## Review notes (Fable, 2026-10-27; verdict ACCEPT)

- [V] A userspace forced-reset panic (`reboot(RB_PANIC|RB_PANIC_FORCERESET)`, DEBUGGER_OPTION_PANICLOGANDREBOOT,
  debug.c:1319) also reaches the hold loop now and waits `negronipanic` seconds (default: for ever) instead of
  resetting at once. No caller on the phone today; if one appears, pass the forced flag and reset immediately.
- [V] `op10tool ctl log` resends the last 64 KiB of the console ring (works in the normal server too).
- [I] A frame half sent before the panic is resent after 2 s with the remaining length (`t[2] & 0xffffff` is the
  remaining BUFSIZ): a short frame the host drops; up to 1400 bytes can be lost on a bus reset (re-enumeration), not
  on a timeout. A host that takes the frame exactly at the 2 s mark loses one frame (logged, self-recovering). The
  longest error reply is 63 bytes = text[64]-1.
- [V] ud_thread acks each event before handling it: if a CPU halts between the ack and the handler, that one event
  is lost (TX recovers by the 2 s timeout; a lost ep0 event needs a host re-enumeration).
