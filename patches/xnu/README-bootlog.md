# Boot log on userdata (0367)

`0367-negroni-bootlog.patch` keeps the console of the last 8 boots on the phone's own disk. A boot
that loses the USB link, hangs or resets is then readable on the next good boot. The USB live log
(UDP 5140) is no longer the only debug channel. NEGRONI machine config only. It applies last (after
0366), on top of 0047/0069/0121 (slop: console ring and partition log) and 0360 (panic over USB).

**Owner policy note:** with 0367 the kernel writes userdata on EVERY boot, also without `ufsrw=1`.
Only the gated boot log area (N-28673 .. N-19458) is written; root writes still need `ufsrw=1`.
`negronilog=0` turns the boot log off (no write at all). Opus review 2026-10-27: ACCEPT with
conditions F1-F7, all applied (see "Review fixes").

| File | Change |
|---|---|
| `bsd/dev/negroni_bootlog_core.h` (new) | pure checks shared with the host test: partition bounds, log window, HFS+ end, area start, ctl number parser, CRC-32 |
| `bsd/dev/negroni_ufs.c` | boot log area, slot per boot, flush thread (1 s), panic write (polled, no lock), end marks, SpringBoard mark, `/dev/negronibootlog`, area read for ctl; writes only inside the area (`ufs_log_write_blocks`), also without `ufsrw=1` |
| `bsd/dev/negroni_reboot.c` | PMIC PON log summary line (`negroni_reboot_pon_summary()`); end marks in the panic hold loop |
| `bsd/dev/negroni_usb.c` | ctl commands `bootlog`, `bootlog read A C`; end marks for the `reboot`/`bootloader`/`recovery`/`poweroff` commands |
| `iokit/Kernel/arm/NegroniPlatformExpert.cpp` | end marks for halt (power off) and restart |

## Area layout (userdata, 4096-byte blocks, N = partition size)

| Blocks | Size | Content |
|---|---|---|
| N-1025 .. N-1 | 4 MiB + 4 KiB | old console log "SWEETLOG" (not written since 0367; left as it is) |
| N-3073 .. N-1026 | 8 MiB | GPU firmware area |
| N-11265 .. N-3074 | 32 MiB | ADSP firmware area |
| N-19457 .. N-11266 | 32 MiB | WLAN firmware area |
| **N-28673 .. N-19458** | **36 MiB** | **boot log area (new)** |
| 0 .. HFS+ end | 16 GiB today | HFS+ root (4194304 blocks; ends far below N-28673) |

NE2211: N = 58672399, so the boot log area is blocks 58643726 .. 58652941. The HFS+ root ends at
block 4194304.

Inside the area (block numbers relative to the area start):

| Area block | Content |
|---|---|
| 0 | superblock: `"NEGRBLOG"`, u32 version 1, slots 8, slot blocks 1025, area blocks 9216, ring size 4194304, from_end 28673, CRC-32 (36 bytes) |
| 1 + i*1025 | slot i header (`struct nbl_slot`, 1932 bytes, `"NEGRBOOT"`, CRC-32 at byte 1928) |
| 2 + i*1025 .. 1025 + i*1025 | slot i console ring, 4 MiB: console byte n of that boot is at ring offset n % 4 MiB |
| 8201 .. 9215 | reserved (unused) |

Slot header fields (little endian): boot counter, state (1 running, 2 panic, 3 halt, 4 restart),
flags (bit 0 SpringBoard ran, bit 1 panic log written), ring size, flush interval, console bytes of
the boot, flush count, calendar time of the start and the last flush (phone clock, can be wrong
before `op10tool ctl settime`), uptime of the last flush, of SpringBoard and of the end, kernel UUID,
kernel version string, boot-args, PMIC PON log summary of this power-on, end text (first panic line,
`halt (power off)`, `restart (reboot)`, `reset (USB command bootloader)`, ...).

## Behavior

1. At the UFS driver start (before the root mount, the earliest point where the disk can be
   written), the kernel reads the HFS+ volume header (byte 1024 of the partition: signature
   `H+`/`HX`, block size, total blocks). If the volume does not end at or below N-28673, or the
   header is not HFS+, the boot log stays off.
2. Layout anchor: block N-19457 (right after the area) must start with the WLAN firmware area magic
   `NEGRWLAN`, or the area must already hold our superblock. Else the log stays off
   (`... layout not proven, off`). Only after checks 1 and 2 does the write gate accept the area;
   any later setup error closes it again. Nothing outside the area is ever written by this code.
   Today's phone has the WLAN area [V notes: `firmware area has 199 files`].
3. Superblock missing or of another layout: the kernel zeroes the 8 slot headers, then writes a new
   superblock (all slots count as empty).
4. Slot of this boot = the slot after the slot with the highest valid boot counter; boot counter + 1.
   The header is written at once (state running). Console lines:
   `NEGRONI BOOTLOG: area at block ... ; boot B -> slot S` and one line for each of the 3 boots before.
5. Flush thread (wear budget): new text is flushed every `ufslogsecs` s (default now 1, was 10) in
   the first 5 min of uptime, then at most every 5 s. If more than 256 KiB went out in a 10 s window
   (not counting the first flush, the backlog since kernel start), every 10 s for the next 20 s
   (line `NEGRONI BOOTLOG: N KiB in 10 s: flushes every 10 s for a while`). A quiet console: header
   only, every 30 s. Each flush: changed ring blocks, header, SYNCHRONIZE CACHE.
6. SpringBoard: the flush thread looks for the process once per second until it runs; then flag +
   uptime, line `NEGRONI BOOTLOG: boot B reached SpringBoard (pid P) X s after start`.
7. Panic: `negroni_log_panic()` (model_dep.c, after the backtraces) appends the panic log to the ring
   (as before). Then it tries the UFS lock once. If the lock is held and `ufsrw=1` (a CPU that was not
   stopped could be in a root write with the shared bounce buffer), no disk write
   (`NEGRONI BOOTLOG: UFS busy at the panic (ufsrw=1): no panic write to the disk`; USB still works).
   Otherwise, polled (spins on the counter, no `delay()`, no printf, 1 s
   command timeout): waits up to 200 ms for a command still in slot 0 (clears it if it does not end),
   writes the ring, a header with state panic + the first panic line, SYNCHRONIZE CACHE. Line on the
   panic screen: `NEGRONI BOOTLOG: panic log of boot B written to slot S: ok`. Then 0360's USB panic
   mode runs as before. A reset from the panic hold loop (USB command or `negronipanic=N`) adds
   `/ then: reset ...` to the end text.
8. Halt / restart (`kPEHaltCPU` / `kPERestartCPU`) and the USB `reboot`/`bootloader`/`recovery`/
   `poweroff` commands write the end state (halt / restart) and the last console text.
9. Reset or hang without any of the above: the slot keeps state "running"; its last flush uptime
   tells when the kernel was last alive (+- 1 s in the first 5 min, +- 5-10 s later, +- 30 s with a
   quiet console).

## Reset detector (PMIC PON log)

0214 already prints the PMIC PON log (SDAM 0x7400) at boot (`NEGRONI PON LOG:` lines). 0367 adds one
summary line, `NEGRONI PON LOG: summary: pon=PS_HOLD reset=PS_HOLD type=HARD_RESET ...`, and stores it
in the slot header. It holds the last PON trigger and the reset entries logged before it (so they
describe how the PREVIOUS boot ended):

| Entry | Meaning |
|---|---|
| `reset=PS_HOLD` | the SoC dropped PS_HOLD: PSCI SYSTEM_RESET (our reboot) or TZ after an APSS watchdog bite |
| `reset=PMIC_WATCHDOG_S2` | the PMIC watchdog fired |
| `reset=KPDPWR_N_S2` / `RESIN_N_S2` / `KPDPWR_N_AND_RESIN_N_S2` | power key / volume-down long press |
| `pon=KPDPWR_N` without `reset=` | power on by key after a power off |
| `pon=USB_CHARGER` | power on by the charger |
| `type=` | the PS_HOLD reset type (WARM_RESET, HARD_RESET, SHUTDOWN, ...) |
| `fault12=` / `fault3=` | PMIC fault reasons (non-zero only) |

[I] The PON log has no field that tells a PSCI reset from a TZ watchdog bite: both are `PS_HOLD`.
The boot log tells them apart: a PSCI reset by our code writes an end mark; a watchdog bite does not.
[I] The order "reset entries, then PON_TRIGGER" per cycle is from downstream pmic-pon-log.c; not yet
checked against a real log of this phone (the raw `NEGRONI PON LOG:` lines are still printed).

## Read back

| Way | Command | When |
|---|---|---|
| USB command server | `out/bin/op10tool ctl bootlog` (one line: area, slot, this boot) | good boot, USB link up |
| USB command server | `out/bin/op10tool bootlog [N]` or `make bootlog` (all 8) | good boot, USB link up |
| SSH | `scripts/debug/bootlog-ssh.sh [N]` (dd of `/dev/negronibootlog`, then `op10tool bootlog --file`) | good boot with SSH |
| any dump | `out/bin/op10tool bootlog --file AREA.bin` (a dd of userdata from block N-28673, 8201 blocks) | e.g. from a recovery |

`op10tool bootlog` writes `logs/bootlog-<boot>.txt` per boot (a `#` header with every header field,
then the console text in order) and prints per boot: start time, last uptime, SpringBoard yes/no,
end (`PANIC: <first line>` / `reset without panic (no end mark; last flush at uptime X s)` /
`clean halt|restart: <text>` / `still running (this boot)`), the next power-on's PON summary for a
reset without panic, and the last 5 lines. It names the kernel build when a file in
`out/kernel/*/kernel.*` has the same LC_UUID.

UDP protocol (port 5141, source 192.168.7.1 only, as 0210):
- `bootlog` -> `bootlog v1 area <first block> blocks 9216 slots 8 slotblocks 1025 boot <B> slot <S>
  state <st> secs <n> hfsend <blocks> running <0|1>` or `error: no boot log on this boot ...`
- `bootlog read A C` (C 1..4) -> 4*C datagrams `"NBLD" | u32 area block | u32 byte offset | u32
  1024 | 1024 bytes`; errors as text (`error: bootlog read A C: <errno>`). The host keeps 4 requests
  in flight; after 250 ms it asks again for each missing block alone, 12 tries (the phone TX queue
  may drop datagrams).

`/dev/negronibootlog`: character device, root:wheel 0400, read only; offset = area byte offset.

## Boot-args

| Boot-arg | Default | Effect |
|---|---|---|
| `negronilog=0` | 1 | no boot log (no area write at all) |
| `ufslogsecs=N` | 1 | flush interval 1..60 s (was 10); after 5 min at least 5 s, under load 10 s |

`ufsrw` is not needed: the log writes only inside its area.

## What the main session must rebuild

1. Kernel: done by this patch's build (path below). The image build uses it (`out/kernel/kernel.macho`).
2. Boot image (`scripts/ios16/build.sh payload` + `boot`): needed to boot the new kernel. No boot-arg
   change is needed.
3. Root / userdata: NOT needed for the boot log to work. The area lies in today's DONT_CARE space
   above the HFS+ end; the kernel writes the superblock itself. For a future userdata flash,
   `AREAS=1 scripts/ios16/root-simg.sh` now refuses a root that reaches N-28673 and embeds the
   superblock at N-28673 (needs the new `out/bin/op10tool`).

## Test (owner, after a boot image with this kernel)

1. `make usblog` (sudo, tmux). Boot the image (RAM boot is fine). Look for
   `NEGRONI BOOTLOG: area at block 58643726 (9216 blocks, HFS+ ends at 4194304, anchor NEGRWLAN), new superblock; boot 1 -> slot 0`
   (first boot) and `NEGRONI PON LOG: summary: ...`.
2. Wait for `NEGRONI BOOTLOG: boot 1 reached SpringBoard ...`. `out/bin/op10tool ctl bootlog` ->
   `bootlog v1 area 58643726 ... boot 1 slot 0 state running ...`.
3. `out/bin/op10tool ctl panic`. Panic screen line: `NEGRONI BOOTLOG: panic log of boot 1 written to slot 0: ok`.
4. `out/bin/op10tool ctl reboot` (panic mode command), or a power key reset if USB is gone.
5. After the next boot: console shows `NEGRONI BOOTLOG: earlier boot 1 (slot 0): panic, ...`.
   Run `make bootlog` (or `out/bin/op10tool bootlog`). Expect
   `boot 1 slot 0 ... end: PANIC: panic(cpu N caller ...): requested over USB / then: reset (USB command in panic mode)`
   and `logs/bootlog-1.txt` with `NEGRONI LOG: panic log follows` ... `end of panic log`.
6. Optional: SSH path `scripts/debug/bootlog-ssh.sh` gives the same summary.
7. Optional reset test: hold power + volume down until the phone resets; next boot shows the slot as
   `reset without panic` and the next power-on summary with `reset=KPDPWR_N_AND_RESIN_N_S2` (or similar).

Host-only tests:
- `scripts/kernel/test-bootlog-core.sh`: the kernel's `negroni_bootlog_core.h`, taken from the patch,
  against `tools/bootlog-core-test/bootlog_core_test.c` (write gate edges: partition ends, 32-bit LBA,
  window edges incl. the WLAN area start, closed/inverted window; HFS+ end incl. HFSX, rounding, a
  volume one block into the area, non-HFS headers; area start; ctl number parser incl. 10 digits;
  CRC-32 = zlib). [V] 65 checks, 0 failed.
- `tools/op10tool/tests/bootlog-test.sh`: the host parser (fake area from
  `tools/op10tool/tests/bootlog-fake.py`; UDP path with 10 % loss via `bootlog-fake-server.py`).

## Review fixes (Opus review 2026-10-27, ACCEPT with conditions)

| # | Fix |
|---|---|
| F1 | wear budget: 1 s only in the first 5 min, then 5 s; > 256 KiB in 10 s -> 10 s; idle heartbeat 30 s (was 5 s) |
| F2 | layout anchor before the gate opens: `NEGRWLAN` at N-19457, or our superblock already in place |
| F3 | the caller closes the gate (`ufs_log_lo = ufs_log_hi = 0`) on every setup error |
| F4 | `_Static_assert`: NBL_FROM_END == 28673, area 9216 blocks, 8201 used blocks (host tools hard-code them) |
| F5 | panic path: UFS lock tried once; held + `ufsrw=1` -> no disk write |
| F6 | `scripts/fw/write-areas.sh` also requires HFS+ end <= N-28673 |
| F7 | string fields of the slot headers read at boot are NUL-terminated before printf |
| notes | 8 slot headers zeroed with a new superblock; `negroni_bootlog_end` returns in interrupt context, its callers (halt/restart hook, ud_thread) run with preemption on, the try-lock loop is a guard only; core checks moved to a host-tested header; slop's `tools/negroni-log-pull.sh` (SWEETLOG reader) is obsolete for kernels with 0367 |

## Risks

- [I] Up to one SYNCHRONIZE CACHE per second in the first 5 min, then at most one per 5 s (30 s when
  quiet). If the root feels slower: `ufslogsecs=5`.
- [I] The panic write uses the UFS host after the other CPUs stopped. If the panic came from inside
  the UFS code, the write can fail (at most about 1 s per command, stop at the first error); the USB
  panic mode then starts as before.
- [I] Not run on the phone. Kernel compiled only.
