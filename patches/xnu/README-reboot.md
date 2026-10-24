# USB command server, reboot reason, power off (0210, 0211)

`0210-negroni-usb-command-server.patch` adds a small command server to the negroni USB Ethernet
(CDC-ECM) driver and a reboot-reason writer for the PMIC. The host sends one word over UDP and
the kernel answers, reboots (normal, fastboot, recovery) or panics. No SSH, no userland and no
button combination is necessary. NEGRONI machine config only (`ARM64_BOARD_CONFIG_NEGRONI`).

`0211-negroni-power-off.patch` makes the kernel halt/restart path work ("slide to power off" did
nothing) and adds the `poweroff` command. See "0211: power off and restart" below.

Base: branch `base` of `out/kernel/xnu`. Work branch: `reboot` in `out/kernel/wt-reboot`.
0210 = commit `0354535` = `git diff base` of its three files; it applies alone on `base`.
0211 = commit `a41baf1` = `git diff 0354535 a41baf1`; it needs 0210 first (the file name order
does that). Checked: `base` + 0210 + 0211 with `git apply` gives exactly `a41baf1`, and
0200-0202 and 0220-0223 then apply on top without errors. No other patch touches these files.

| File | Change |
|---|---|
| `bsd/dev/negroni_usb.c` | command server in the receive path, deferred reset/panic, boot-arg `negronictl` |
| `bsd/dev/negroni_reboot.c` (new) | SPMI read-modify-write of the reboot-reason byte, PSCI `SYSTEM_RESET` |
| `bsd/conf/files` | builds `negroni_reboot.c` |
| `iokit/Kernel/arm/NegroniPlatformExpert.cpp` (0211) | `PE_halt_restart` hook |

Host tool: `op10tool ctl` (`tools/op10tool/src/ctl.rs`).

## Commands

UDP to `192.168.7.2:5141`, one ASCII word per datagram. The kernel removes trailing white space
(`\n`, `\r`, space, tab, NUL). It replies to the source port of the request.

| Command | Kernel action | Reply |
|---|---|---|
| `ping` | none | `pong` |
| `reboot` | reboot reason 0 (normal), then PSCI `SYSTEM_RESET` after 500 ms | `ok reboot` |
| `bootloader` | reboot reason 2 (ABL fastboot), then reset after 500 ms | `ok bootloader` |
| `recovery` | reboot reason 1 (recovery), then reset after 500 ms | `ok recovery` |
| `poweroff` (0211) | `negroni_power_off()` after 500 ms (PSCI SYSTEM_OFF, see 0211) | `ok poweroff` |
| `panic` | `panic("requested over USB")` after 500 ms | `ok panic` |
| other | none | `error: unknown command` |

- If the kernel cannot write the reason, the reply is `ok bootloader (reason not set: plain reset)`
  (or `recovery`). The reset still occurs. The console log tells why (see "Log lines").
- After a reset or panic is scheduled, every command except `ping` gets `error: busy`.
- The kernel writes the reason when the command arrives. The reset or panic comes 500 ms later.
  In that time the reply and the console lines go out (the live log thread sends every 100 ms).
- `reboot` writes reason 0 only when the field is not 0 already. This removes a stale reason.

## Design

### Where the commands are received

The phone's `ue0` interface is a real BSD `ifnet`. ARP and ICMP echo are answered by the
normal network stack after `ifnet_input()`. The driver itself has no ARP or ICMP code.

The command server is in `ud_rx_done()`, before `ifnet_input()`. The driver thread `ud_thread`
(1 ms poll of the DWC3 event buffer) calls it for each received frame. `ud_ctl_input()` takes
the frame only when all of these are true:

- `negronictl` is not 0 and `ue0` exists,
- EtherType 0x0800, IPv4, IHL >= 5, protocol 17 (UDP),
- one whole datagram: MF = 0 and fragment offset = 0, IP total length fits in the frame,
- IP destination 192.168.7.2 and UDP destination port 5141.

All other frames go to the stack as before. A taken frame never goes to the stack, so the stack
sends no ICMP port unreachable for 5141. Then the server checks the frame:

- IP source must be 192.168.7.1. Other sources: the server logs and drops the frame.
- IP header checksum must be correct and the UDP length must fit. Otherwise: log, drop.
- Commands longer than 31 bytes get `error: unknown command`.

The UDP checksum of the request is not checked (USB has a CRC on each packet).

### Reply path

`ud_ctl_reply()` builds the reply frame directly: the destination MAC, IP address and port are
the source values of the request. The source is `02:00:5e:77:ee:02`, 192.168.7.2:5141. IPv4 has
DF set, TTL 64 and a correct header checksum. UDP has a correct checksum (pseudo header). The
frame goes into the driver's TX ring with `ud_if_output()`. The server uses no socket, no ARP
and no routing table. Thus `ping` and the resets also work when the network stack or userland
is stuck, while `ud_thread` runs.

### Deferred action

`ud_ctl_schedule()` records the action and a deadline (`clock_interval_to_deadline`, 500 ms).
`ud_ctl_poll()` runs in each `ud_thread` tick after the event loop. When the deadline is past,
it calls `panic("requested over USB")` or `negroni_reboot_reset()`. The thread does not sleep
for the delay: it continues to process USB events, so the TX ring empties and the log thread
sends the last console lines. All `ctl_*` fields belong to `ud_thread` only (no lock).

### Reboot reason (`negroni_reboot.c`)

Facts (Android DT of NE2211, verified before this work):

- The `qcom,reboot-reason` nvmem cell is in the PMK8350 SDAM block at 0x7100 (SPMI SID 0),
  byte offset 0x48. So the register is SID 0, 0x7148.
- The value is in bits 7:1 (`value << 1`). Bit 0 is not part of the field and is kept.
- Values: bootloader (fastboot) = 2, recovery = 1, normal = 0.
- ABL reads the cell after a normal PSCI `SYSTEM_RESET`.
- The IMEM `restart_reason` (0x146aa65c) does not select a mode on this phone. The patch does not
  write it.

SPMI PMIC arbiter version 7 (Linux `drivers/spmi/spmi-pmic-arb.c`, SM8450 `spmi@c400000`,
`qcom,ee = <0>`; the same addresses are in slop `docs/negroni.md`):

| Region | Address | Used for |
|---|---|---|
| core | 0x0c400000 (0x3000) | +0 version (0x7xxxxxxx required), +4 bits 10:0 APID count, +0x2000 + 4*APID map (bits 19:8 = PPID) |
| cnfg | 0x0c42d000 (0x1000 mapped) | owner table: +4*APID, bits 2:0 = the EE that may write |
| obsrvr | 0x0c440000 | read channel of an APID: +0x8000*EE + 0x20*APID |
| chnls | 0x0c500000 | read/write channel of an APID: +0x1000*APID |

Channel registers: CMD +0x00, STATUS +0x08 (bit 0 done; bits 1-3 failed, denied, dropped),
WDATA0 +0x10, RDATA0 +0x18. Command word: `opcode << 27 | (register & 0xff) << 4 | (bytes - 1)`.
EXT_READL = 1, EXT_WRITEL = 0.

`negroni_reboot_set_reason(reason)`:

1. At the first call: map core and cnfg, check the version, find the APID of PPID 0x071
   (SID 0, peripheral 0x71). Like Linux, take the first mapping, or the one that EE 0 owns.
2. If the owner table does not give that APID to EE 0: log, return -1 (no write). Linux refuses
   such a write too (`disallowed SPMI write`).
3. Map only the observer slot (one page) and the read/write channel page (0x1000) of that APID.
4. Read 0x7148 (EXT_READL on the observer channel).
5. New value = `(old & 0x01) | (reason << 1)`. If it is equal to the old value: done.
6. Write it (WDATA0, then EXT_WRITEL on the read/write channel), then read it again. The result
   must be equal to the new value.

Each transaction polls STATUS for up to 2000 x 1 us. Mapping failures and arbiter errors make
the function return -1. A failure is permanent for the boot (the mappings are `ml_io_map`, which
cannot be unmapped).

`negroni_reboot_reset()`: PSCI `SYSTEM_RESET` (0x84000009) with `smc #0`, the conduit that
`NegroniCPU.cpp` already uses for `CPU_ON`. If PSCI returns, the function logs the result and
returns.

The keys driver (`negroni_keys.c`) reads the same arbiter (core + observer, EE 0) on this phone
and works. That confirms the core and observer layout. The read/write channel and the owner
table are not tested on the phone yet. `negroni_spmi.c` (battery) uses other addresses (the
sweet/SM8150 v5 layout) and is not used here.

## Boot-args

| Boot-arg | Default | Effect |
|---|---|---|
| `negronictl=0` | on | disables the command server (frames for 5141 go to the stack again) |
| `negroniusb=2` | (required) | the USB device and `ue0` exist only with `negroniusb=2` |

Startup log line: `NEGRONI CTL: commands on udp 192.168.7.2:5141 on (boot-arg negronictl)`.

## Log lines

(Text as of 0211; 0210 alone prints `0x7148 a -> b (reason n)` instead of the `SDAM` lines.)

```
NEGRONI REBOOT: SPMI arbiter 0x7xxxxxxx, SDAM 0x7100 APID n (EE 0)      (at platform start, 0211)
NEGRONI REBOOT: power off = PSCI SYSTEM_OFF, panic = reset after 30 s (reason 0)
NEGRONI CTL: "ping" from 192.168.7.1:53122
NEGRONI CTL: "bootloader" from 192.168.7.1:53123
NEGRONI REBOOT: SDAM 0x7100 +0x48 0x00 -> 0x04
NEGRONI REBOOT: reboot reason 2
NEGRONI CTL: bootloader: reason 2 set, reset in 500 ms
NEGRONI CTL: PSCI SYSTEM_RESET
```

Failure lines: `SDAM 0x7100 APID n is owned by EE m, not EE 0: no write`,
`SDAM 0x7100 not in the SPMI APID map`, `unknown SPMI arbiter`, `SDAM 0x7100 read of +0x48 failed (rc)`,
`SDAM 0x7100 write of +0x48 ... failed (rc n, read back ...)`, `reason n not set`,
`datagram from a.b.c.d ignored (only 192.168.7.1)`, `malformed datagram ignored`,
`PSCI SYSTEM_RESET returned n`.

## Host tool

```sh
cargo build --release --manifest-path tools/op10tool/Cargo.toml --target-dir out/cargo
out/cargo/release/op10tool ctl ping                 # "pong from 192.168.7.2:5141 in 1.2 ms"
out/cargo/release/op10tool ctl bootloader           # ABL fastboot
out/cargo/release/op10tool ctl recovery
out/cargo/release/op10tool ctl reboot
out/cargo/release/op10tool ctl poweroff             # 0211
out/cargo/release/op10tool ctl panic
out/cargo/release/op10tool ctl ping --host 127.0.0.1   # other address (tests)
```

- For a 192.168.7.x host the tool binds to 192.168.7.1. If that address is not on this
  computer, it stops with a hint to start the USB link (`make usblog`).
- `ping` sends again every 500 ms and waits up to 2 s for `pong`. The first datagram can be lost
  while the computer resolves ARP.
- The other commands are sent once only (a reset must not occur two times). The tool waits up to
  2 s for `ok ...`. Exit code 1 for `error: ...` or no reply.
- An ICMP port unreachable gives the error "kernel without the command server, or negronictl=0".
  A kernel without 0210 gives this error.
- Without root: only `make usblog` (address setup) needs sudo. `op10tool ctl` does not.

## How to test (in order)

1. Kernel CI build with 0210. The build must include `negroni_reboot.o`.
2. `make boot-debug`, `make usblog` (tmux), `make flash-boot-debug CONFIRM=yes` (a temporary
   `fastboot boot`). In the live log look for `NEGRONI CTL: commands on udp ... on`.
3. `op10tool ctl ping`: expect `pong`. Also `ping 192.168.7.2` must work as before (stack path).
4. `op10tool ctl reboot`: the phone must reset. The previous slot boots (Android/Magisk in
   `boot_a`, because the iOS kernel came from `fastboot boot`).
5. Boot the debug image again. `op10tool ctl bootloader`. Look for
   `NEGRONI REBOOT: 0x7148 ... -> ... (reason 2)` in the log. Expect ABL fastboot
   (`fastboot devices` shows the phone). If Android boots instead, read the `NEGRONI REBOOT:` lines:
   - "owned by EE n" or "not in the APID map": the SPMI write is not possible from this EE.
   - "0x7148 a -> b (reason 2)" and no fastboot: ABL ignored the byte (other cell, or ABL
     clears it), not a kernel failure.
6. `op10tool ctl recovery`: expect OxygenOS recovery. In fastboot, `fastboot reboot recovery` is
   the known-good comparison.
7. `op10tool ctl panic`: expect the panic screen/log path (`panic("requested over USB")`). With a
   debug boot-arg that waits for a debugger, the phone stays in the panic state; use
   Volume Up + Volume Down + Power to leave it.
8. Boot with `negronictl=0`: `op10tool ctl ping` must report "refused" (ICMP port unreachable).

## Risks

- The SPMI write channel (chnls 0x0c500000) and the owner table (cnfg 0x0c42d000) are not tested
  on this phone. If the hypervisor does not map them for this VM, the first access can fault or
  hang `ud_thread` (no response to commands after `bootloader`/`recovery`; the phone then needs
  the button reset). `reboot` with a reason field of 0 also reads the cell (observer channel),
  but it does not write.
- The patch writes a PMIC register. It writes only bits 7:1 of SID 0 register 0x7148 (the
  Android reboot-reason cell), with a read-back check. It writes nothing else.
- `panic` is available to anyone on the USB link with address 192.168.7.1. The link is a cable
  to the developer's computer, so this is accepted. Use `negronictl=0` to disable.
- A held reason: if ABL does not clear the cell, a `bootloader` reason can stay for later resets
  (for example a watchdog reset). `op10tool ctl reboot` sets the field to 0 again; in fastboot,
  `fastboot reboot` also works.

## Verification done (no phone, no full kernel build)

- `negroni_usb.c` and `negroni_reboot.c` compile with clang in kernel mode with the exact BSD
  flags of the CI build (`out/kernel/buildtree/.../bsd/DEVELOPMENT/.CFLAGS`, paths changed to
  the worktree, `-Wall -Wextra` added, `-c -o /dev/null`). No new warnings (the one warning in
  `negroni_usb.c`, `ud_if_output` `-Wshorten-64-to-32`, is in `base`). The final link was not
  done.
- The patch applies to `base` with `git apply --check`.
- `op10tool ctl` built in release mode; `cargo clippy` gives no warning for `ctl.rs` or
  `main.rs` (the 4 clippy warnings are in `img2simg.rs` and `uefi.rs`, in older code).
  Tested on 127.0.0.1 against a fake UDP server: `pong`, `ok ...`, `error: busy`, timeout and
  ICMP refused give the expected output and exit codes.

## Sources

- ios-flame `xnu/patches/0089-flame-tools-usb.patch` (command server on UDP 5141 in
  `sweet_usb.c`, with a kernel socket; here the frame is taken in the receive path instead).
- slop `unixnu-negroni/package/BootResetCore.h` and `BootReset.c` (SM8550: arbiter v7 lookup, owner
  check, EXT_READL/EXT_WRITEL, reason cell 0x48 bits 7:1, PSCI reset). Adapted to the XNU tree.
- bergamota `docs/REBOOT_MODE.md`, patch 0137 (reason field written as `magic << 1`, owner
  check, log style).
- slop `negroni-ios/xnu/patches/0087-negroni-sm8450-keys.patch` and `docs/negroni.md` (negroni
  arbiter addresses).
- Linux `drivers/spmi/spmi-pmic-arb.c` (v7 offsets, owner table, command format).

## 0211: power off and restart

### Why "slide to power off" did nothing

The kernel path of a power off (all in this tree, nothing negroni-specific on the way):

1. SpringBoard asks backboardd/launchd to shut down. launchd stops the userland and calls
   `reboot(RB_HALT)` (not verified here: userland binaries were not checked).
2. `reboot()` (`bsd/kern/kern_xxx.c`): `suser()` and `mac_system_check_reboot()`. The negroni
   MAC policy (`bsd/kern/negroni_amfi.c`, 0221-0223) has no reboot hook. Then `reboot_kernel()`.
3. `reboot_kernel()` (`bsd/kern/kern_shutdown.c`): process exit, sync, unmount, `if_down_all()`,
   then `host_reboot(HOST_REBOOT_HALT)` -> `halt_all_cpus(FALSE)`
   (`osfmk/arm64/machine_routines.c`): prints `CPU halted`, `PEHaltRestart(kPEHaltCPU)`.
4. `PEHaltRestartInternal()` (`iokit/Kernel/IOPlatformExpert.cpp`) arms a 30 s timer, sends
   the IOKit shutdown notifications, then `gIOPlatform->haltRestart(kPEHaltCPU)`.
5. `NegroniPlatformExpert` does not override `haltRestart()`, and nothing set
   `PE_halt_restart`. So `IOPlatformExpert::haltRestart()` returned -1, `halt_all_cpus()` spun
   for ever, and 30 s later the timer panicked: `Halt/Restart Timed Out`. A restart
   (`MACH Reboot`, `kPERestartCPU`) and a panic restart (`kPEPanicRestartCPU`) had the same
   problem: there was no reset path at all.

Nothing in the negroni tree swallows the request. The missing part was the last step.

### What 0211 changes

- `NegroniPlatformExpert::start()` calls `negroni_reboot_prepare()` (boot-args, SPMI mappings, so
  the panic path needs no allocation) and sets `PE_halt_restart = negroni_halt_restart`.
- `negroni_halt_restart(type)`:

| Type | Action |
|---|---|
| `kPEHaltCPU` (also `kPEUPSDelayHaltCPU`, mapped by IOKit) | log `NEGRONI: power off`, sleep 300 ms (if the thread may block), `negroni_power_off()` |
| `kPERestartCPU` | log `NEGRONI: restart`, sleep 300 ms, reboot reason 0 (normal), PSCI `SYSTEM_RESET` |
| `kPEPanicRestartCPU` | `negroni_panic_restart()`: panic text stays on the screen `negronipanic` s (default 30), then reason `negronipanicreason` (default 0) and reset; `negronipanic=0` stays on the panic screen for ever |
| `kPEPanicBegin` | marks the panic: a later `kPEHaltCPU`/`kPERestartCPU` goes to `negroni_panic_restart()` (the panic path calls `halt_all_cpus(TRUE)` after a refused panic restart) |
| all other types (panic callouts) | nothing, return 0 |

- If a method fails, the handler returns -1 and `halt_all_cpus()` spins as before (logged).
- The 300 ms sleep lets the USB log thread send the last lines. `negroni_reboot_settle()`
  sleeps only when `preemption_enabled()` and not in interrupt context; otherwise it returns.
- USB live log during shutdown: `if_down_all()` takes `ue0` down, so `sock_send()` fails.
  The log thread then sends the same datagram as a raw frame (`ud_udp_send()`, the 0210 reply
  builder, now shared) to the host MAC `02:00:5e:77:ee:01` (the ECM iMACAddress), 192.168.7.1:5140.
  The frames go on the TX ring directly, without the stack. The same fallback also sends lines
  that were lost before (0210 dropped a chunk when `sock_send()` failed).
- `poweroff` in the command server: `ok poweroff`, then `negroni_power_off()` after 500 ms. Like
  `reboot`, this is a hard power off: no sync, no unmount.

### Power off methods (boot-arg `negronipoweroff`, default 0)

| Value | Method |
|---|---|
| 0 | PSCI `SYSTEM_OFF` (0x84000008, `smc #0`). If it returns: log, no fallback. |
| 1 | `SYSTEM_OFF`; if it returns, the PMIC fallback |
| 2 | the PMIC fallback only |

PSCI `SYSTEM_OFF` is the first choice. The NE2211 DT has `psci { compatible = "arm,psci-1.0";
method = "smc"; }`. Mainline Linux on SM8450 also powers off with `SYSTEM_OFF` only: its
`qcom,pmk8350-pwrkey` data has `supports_ps_hold_poff_config = false`, so it never writes the
PMIC PS_HOLD configuration on this PMIC generation. TZ (or Gunyah, which forwards the HLOS
VM's PSCI calls) does the PMIC part. `SYSTEM_OFF` is not tested on this phone yet.

PMIC fallback (only if `SYSTEM_OFF` is refused, behind the boot-arg): the downstream
`msm-poweroff` method. Set the PS_HOLD reset type of PMK8350 PON_PBS to SHUTDOWN, then let the
SoC drop PS_HOLD with PSCI `SYSTEM_RESET`. The PMIC then powers off instead of a restart.

- Peripheral: PMK8350 (SID 0) PON_PBS at 0x0800 (NE2211 DT: `pon_pbs@800`,
  `qcom,qpnp-power-on`, `qcom,system-reset`; the keys use `pon_hlos@1300`). PPID 0x008. The
  owner table must give it to EE 0, as for the SDAM.
- Check before any write: 0x0804 (type) = 0x01 (PON) and 0x0805 (subtype) = 0x08 (GEN3 PBS).
  Another value: no write, log `not PON GEN3 PBS`.
- Sequence (downstream `qpnp-power-on.c` `qpnp_pon_reset_config()`, mainline
  `pm8941-pwrkey.c` register names):
  1. `PS_HOLD_RST_CTL2` 0x085b bit 7 (`RESET_EN`) = 0
  2. wait 500 us (10 sleep-clock cycles)
  3. `PS_HOLD_RST_CTL` 0x085a bits 3:0 = 4 (SHUTDOWN; 1 = warm reset, 7 = hard reset)
  4. `PS_HOLD_RST_CTL2` 0x085b bit 7 = 1 (also when step 3 failed, so a reset still works)
  5. reboot reason 0, PSCI `SYSTEM_RESET`
- Each write is a read-modify-write with a read-back check.
- Not verified: the offsets 0x5a/0x5b are the GEN1/GEN2 PON layout; that GEN3 PON_PBS uses the same
  offsets is an assumption (downstream uses them on the `qcom,system-reset` device). Also TZ can
  set its own PS_HOLD type for `SYSTEM_RESET`; then the fallback gives a restart, not a power
  off. The SoC PS_HOLD register (MPM, `qcom,pshold` on SDM845 at 0x0c264000) is not in the
  NE2211 DT and is protected on this SoC generation, so the kernel does not write it directly.

### Boot-args (0211)

| Boot-arg | Default | Effect |
|---|---|---|
| `negronipoweroff=0/1/2` | 0 | power off method (table above) |
| `negronipanic=N` | 30 | after a panic: reset after N s; 0 = stay on the panic screen |
| `negronipanicreason=N` | 0 | reboot reason for the panic reset (2 = fastboot, for `fastboot boot` work) |

Before 0211 a panic stayed on the screen for ever. Use `negronipanic=0` for the old behavior.

### Log lines (0211)

```
NEGRONI: platform expert registered, halt/restart hook set
NEGRONI REBOOT: power off = PSCI SYSTEM_OFF, panic = reset after 30 s (reason 0)
CPU halted
NEGRONI: power off
NEGRONI REBOOT: PSCI SYSTEM_OFF
NEGRONI REBOOT: PSCI SYSTEM_OFF returned -n           (only if refused)
NEGRONI REBOOT: no power off (boot-arg negronipoweroff=1 tries the PMIC)
NEGRONI REBOOT: PMIC power off: PS_HOLD reset type SHUTDOWN, then PSCI SYSTEM_RESET
NEGRONI REBOOT: PON_PBS 0x0800 +0x5b 0x80 -> 0x00
MACH Reboot
NEGRONI: restart
NEGRONI REBOOT: panic: reset in 30 s (boot-arg negronipanic), reason 0
```

PSCI return codes: -1 NOT_SUPPORTED, -2 INVALID_PARAMETERS, -3 DENIED.

### How to test 0211 (in order, after the 0210 tests)

1. Boot the debug image, `make usblog`. Look for `halt/restart hook set` and the
   `power off = ...` line.
2. `op10tool ctl poweroff`: expect the phone to switch off (screen off, no USB). Turn it on with
   the power key. If the log shows `SYSTEM_OFF returned`, note the code, boot with
   `negronipoweroff=1` and do it again.
3. "Slide to power off" on the phone: the log must show `CPU halted`, `NEGRONI: power off`,
   `PSCI SYSTEM_OFF`. If `CPU halted` does not come, the request did not reach the kernel
   (a userland problem: read the launchd/SpringBoard lines before it).
4. A restart from userland (`ssh root@192.168.7.2 reboot`, `scripts/net/ssh-phone.sh`): log
   `MACH Reboot`, `NEGRONI: restart`, then a reset.
5. `op10tool ctl panic`: panic text on the screen, after 30 s a reset. With `negronipanic=0`:
   no reset. With `negronipanicreason=2`: the reset goes to fastboot.

### Risks (0211)

- A panic now resets after 30 s (before: the phone stayed on the panic screen). Photos of the
  panic screen must be taken in that time, or use `negronipanic=0`.
- `SYSTEM_OFF` behavior under Gunyah/TZ is not known yet. If it returns, the default only logs.
- The PMIC fallback writes PON_PBS registers with offsets that are not verified for GEN3; it is
  off by default and refuses to write if the type/subtype check fails.
- `negroni_reboot_prepare()` maps the SPMI windows at platform start; the 0210 lazy mapping stays
  for calls that come earlier. The mappings have no lock: the callers do not run at the same time.

### Verification done (0211, no phone)

- `negroni_reboot.c`, `negroni_usb.c`: clang kernel-mode compile with the CI BSD flags and
  `-Wall -Wextra`, no new warnings. `NegroniPlatformExpert.cpp`: clang++ with the CI global flags +
  iokit flags (`-DIOKIT_KERNEL_PRIVATE ...`, `-fapple-kext`); no errors, only the
  `OSDefineMetaClassAndStructors` macro warnings that every IOKit class gets with this clang; `nm`
  shows `_PE_halt_restart` and the `negroni_*` calls. No link.
- `op10tool ctl poweroff`: tested on 127.0.0.1 only. No packet went to 192.168.7.2.
