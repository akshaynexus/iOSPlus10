# Mi A3: kernel log and commands over USB (patch 2005)

The laurel kernel speaks the same USB protocol as negroni, so the negroni host tools work unchanged:
`scripts/debug/usblog.sh` (live log), `out/bin/op10tool ctl` (commands), `scripts/laurel/boot-test.sh`
(the automated flash -> boot -> capture -> back-to-fastboot loop).

## Wire protocol (negroni spec, `patches/xnu/README-reboot.md`, `docs/usb-network.md`)

| Item | Value |
| --- | --- |
| USB function | CDC-ECM, VID:PID 1209:0001, strings "iOSPlus10" / "Mi A3 iOS (USB Ethernet)" |
| Phone | `ue0`, 192.168.7.2/24, MAC 02:00:5e:77:ee:02 |
| Host | 192.168.7.1/24, ECM MAC 02:00:5e:77:ee:01 (usblog.sh finds the interface by it) |
| Live console | UDP to 192.168.7.1:5140 every 100 ms; since 2900 from byte 0 of the boot, after the first frame from 192.168.7.1 |
| Commands | UDP to 192.168.7.2:5141, one ASCII word per datagram, reply to the source port, only from 192.168.7.1 |

Commands: `ping` -> `pong`; `log` -> `ok log (N console bytes from byte 0)` (2900: everything again);
`reboot` / `bootloader` / `recovery` -> `ok <cmd>` then, 500 ms later, the IMEM restart reason of patch 2003
(`kern.laurel_reboot_mode`) + PSCI SYSTEM_RESET; `poweroff` -> PSCI SYSTEM_OFF; `panic` ->
`panic("requested over USB")`; `bootlog`, `bootlog read A C` (2900, `op10tool bootlog`); `settime S[.U]`, `time`
(2901). Unknown words (negroni's `usbstats`) get `error: unknown command`; usblog.sh tolerates that.

## Panic over USB

A panic ends in `laurel_usb_panic_hold()` (SweetPlatformExpert `kPEPanicDiagnosticsDone` /
`kPEPanicRestartCPU`): the panic text stays on the screen, the console ring from the last sent position
(at most 1 MiB; it holds the panic text, registers and backtrace) goes out as UDP 5140 datagrams, ARP is
answered by hand, and the command server still takes `ping`, `log`, `reboot`, `bootloader`, `recovery`,
`poweroff`. `op10tool ctl bootloader` therefore brings a panicked phone back to fastboot without buttons.
`laurelpanic=N` adds a timed reset after N s (default 0 = hold for ever). Without USB (not started,
`laurelpanicusb=0`, nested panic) the hold returns and XNU does what it did before.

## Self-check and kill switches (CLAUDE.md "No probes")

At start (`sweet_usb_probe()`, called from `sweet_ufs.c` without the topaz `sweethw=1` gate) the driver
reads GCC 0x1400000: usb30_prim GDSC (0x1a004) on, master (0x1a010) and cfg-noc (0x1a084) clocks on, then
DWC3 GSNPSID at 0x4e00000 (must be 0x5533xxxx) and GCTL not in host mode. ABL ran fastboot on this
controller, so all of this is true after a flash-and-reboot. Any failure: one line `LAUREL USB: off: <reason>`
and nothing else changes. Success: `LAUREL USB: on: ECM ue0 192.168.7.2, log udp ..., commands ... on, panic hold on`.
Kill switches: `laurelusb=0` (everything), `laurelctl=0` (commands), `laurelpanicusb=0` (panic hold),
`sweetusblog=0` (live log).

Mi A3 addresses (trinket-usb.dtsi, gcc-trinket.c): DWC3 0x4e00000 (size 0xcd00), QSCRATCH 0x4ef8800
(HS_PHY_CTRL VBUS override as on sweet), QUSB2 PHY 0x1613000, high-speed only, IRQ SPI 255 (polled, no IRQ).

## Host use

```sh
make usblog                                       # once; sudo password: tmux attach -t usblog (Ctrl-b d)
scripts/bg.sh laurel-test scripts/laurel/boot-test.sh   # phone in fastboot: flash, boot, capture, ctl bootloader
scripts/bg.sh -s laurel-test 40                   # result; the boot's lines: logs/laurel-boot-<time>.log
out/bin/op10tool ctl ping | bootloader | reboot | poweroff | panic | log
```

`boot-test.sh` env: `HOLD_S` (default 120 s of log after the link, stops early on a panic), `NOFLASH=1`,
`NOBACK=1`, `IMG=`. Exit codes: 0 log captured (a panic is reported in the output, not an error),
2 no USB interface (kernel did not reach the USB start; read the panel), 3 no pong.

## Patch 2007: power-up by the kernel, stage lines, attach thread (2026-11-01)

Why: the Mi A3 boots from `boot_b` after a full reset (`fastboot reboot`), so ABL never ran fastboot on the
controller; topaz always came from `fastboot boot`, which leaves the DWC3 powered and in device mode. The
2005/2006 self-check then turned USB off with one line that the wrapping panel overwrote, and the attach from
bsd_init was a silent no-op (so "no USB device at all" and no `LAUREL USB:` line on the photo of 00:40).

- Cold path (GDSC or master clock off at start): usb30_prim GDSC on (0x1a004, SW_COLLAPSE off, PWR_ON wait),
  RCG master 0x1a01c = GPLL0 600 MHz / 4.5 (133 MHz), RCG mock UTMI 0x1a034 = XO, the 7 branch clocks
  (cfg-noc 0x1a084, sys-noc 0x1a080, master 0x1a010, sleep 0x1a014, utmi 0x1a018, clkref 0x80278, ahb2phy 0x1d008),
  USB30_PRIM_BCR 0x1a000 reset, QUSB2 PHY init as phy-msm-qusb.c (TCSR clamp 0x3cb250 = 1, QUSB2PHY_PRIM_BCR
  0x1c000, POWERDOWN 0xb4, the trinket-usb.dtsi init sequence, TUNE2 high nibble from QFPROM 0x1b44258 bits 28:25,
  PLL lock in 0x38 bit 5), QSCRATCH GENERAL_CFG UTMI-as-pipe clock (no SS PHY), DCTL soft reset, GCTL device mode
  + DSBLCLKGTNG, GUSB2PHYCFG UTMI 8-bit TRDTIM 9 without SUSPHY/ENBLSLPM. The QUSB2 PHY of the SM6125 has the v1
  layout (TUNE1-5 0x80-0x90, TEST2 0x9c, POWERDOWN 0xb4, PLL_STATUS 0x38), not the v2 offsets 2005 printed.
- Warm path (`fastboot continue` / `boot`): as 2005/2006; the PHY is re-initialised only when its POWER_DOWN bit is set.
- Lines on the console: `LAUREL USB: at start:` (GDSC + 7 CBCRs), `power:`, `PHY at start:`, `PHY init:` /
  `PHY: kept`, `SWEET USB: DWC3 ...`, `core:` (cold), `SWEET USB: soft reset`, `running`, `LAUREL USB: on:`.
  Then `LAUREL USB: no host yet (N s): DSTS .. link .. speed .. events ..` every 10 s until the host configures the
  gadget, `LAUREL USB: raw|ue0 rx .. tx ..` every 30 s after. Every failure: `LAUREL USB: off: <reason>`, and bsd_init
  prints the reason once more after net_init_run (`... (no ue0)`), so it is on the panel after `mbinit: done`.
- `laurel_usb_net_attach()` starts a kernel thread for ue0 (ifnet, proto_plumb, 192.168.7.2); bsd_init never waits.
- `scripts/laurel/flash-boot.sh`: `BOOT=continue` (default, warm path) or `BOOT=reboot` (cold path).

Boot 2026-11-01 01:03 (image: kernel 2007, cpus=4 on the 8-core ADT, `fastboot continue` = warm path): "Resuming boot
OKAY", fastboot device gone at 01:03:18, no USB device on the host in 180 s (exit 2). Panel photo pending.

## Patches 2013 and 2014: timer-call service, kprintf in the USB log (2026-11-01 02:50)

Boot 02:28 (UEFI chain, image of commit ccb5eaa, panel photo + host `dmesg`): the kernel printed
`LAUREL USB: on: ...` and stopped after `SWEET: trust caches unavailable`; the host saw a high-speed device
(pull-up on, so Run/Stop and the VBUS override work) but every GET_DESCRIPTOR timed out (`-110`, then `-71`,
"unable to enumerate"). So the DWC3 connected and nobody served EP0: `ud_thread` (a kernel thread) never ran.
A kernel thread runs only when `kernel_bootstrap_thread` blocks and the timer interrupt delivers the wake-ups;
the same two conditions hold for `SweetCPU::startAll` (no `CPU_ON` line either) and bsd_init.

- **2013 timer-call service.** Until bsd_init attaches ue0 the controller is served by a `timer_call` every 1 ms
  (interrupt context, `ud_tc_func`): events, EP0, raw-mode frames (log, ARP, commands), `ud_ctl_poll`. It needs
  only the timer interrupt, not the scheduler. Inside the callback the code runs the panic-loop rules
  (`ud_nolock()`): no mutex, spin delays, `printf` into the console ring only (console I/O with interrupts off
  panics on arm64, `console_io_allowed`). `ud_thread` still prints the 10 s status line on the panel
  (`... events N, timer ticks M`) and takes the controller over at the ue0 attach (`ud_tc_stop`, line
  `LAUREL USB: timer service handed to ud_thread after N ticks`). Panic hold: unchanged (the callback stops
  itself when `ud_in_panic` is set).
- **Self-check** `laurel_usb_timer_check`, `STARTUP(LOCKDOWN, RANK_FIRST)` = right after the trust-cache line,
  interrupts enabled, before `PE_lockdown_iokit` (which waits for the CPU bring-up): waits up to 50 ms for the
  first tick. Panel line `LAUREL USB: timer service: on, first tick after N us (timer interrupt and GIC OK)`, or
  `LAUREL USB: timer service: NO tick in 50 ms: the timer interrupt does not reach this CPU: EL.. DAIF.. ISR..
  CNTV_CTL.. TVAL.. ICC SRE.. PMR.. IGRPEN1.. RPR.. CTLR.. | GICD_CTLR.. GICR WAKER.. ISENABLER0.. ISPENDR0..
  ISACTIVER0.. IGROUPR0.. prio.. intid..` (`sweet_gic_state()` in pe_fiq.c reads this CPU's redistributor). How
  to read it: `ISPENDR0` bit `intid` set + `ISR` bit 7 clear = the GIC holds the PPI (group/enable/priority/
  running-priority problem); `ISR` set + `DAIF` I bit set = masked at the PE; `CNTV_CTL` not 1 or TVAL positive
  = the timer is not armed; `RPR` below 0xFF = an active priority blocks (firmware leftover).
- `pe_init_fiq` (pe_fiq.c) also writes `ICC_AP1R0_EL1 = 0` on every CPU: a stale active priority left by the
  firmware cannot block the PPIs/SGIs. [I] Mu's `GicV3ExitBootServicesEvent` (Mu_Basecore ArmGicV3Dxe.c:718)
  disables the sources and the CPU interface and the distributor; it does not EOI, so this is a guard, not a
  known fix.
- **2014 kprintf in the ring.** `kprintf` is on and writes into the console ring only (`laurel_kputc_ring`,
  never the panel); `startup_debug` defaults to verbose under SWEET (`kernel_bootstrap: ...`,
  `kernel_bootstrap_thread: ...`, startup subsystem names) and `DEBUG_BSDINIT` is 1 (`bsd_init: calling ...`).
  The USB log of a hanging boot therefore ends with the last bootstrap step. Kill switch `laurelklog=0`.
  Expected sequence after `trust caches`: `kernel_bootstrap_thread: OSKextRemoveKextBootstrap`,
  `machine_lockdown`, `PE_lockdown_iokit` (waits in `ml_wait_max_cpus` for `SweetCPU::startAll`, which calls
  `ml_set_max_cpus` after all cores), then `bsd_init: calling ...`.

What the next boot shows, by case:

| Panel | USB on the host | Meaning |
| --- | --- | --- |
| `timer service: on, first tick after N us` and the host enumerates (usblog gets the ring) | log ends with the last `kernel_bootstrap_thread:`/`SWEET CPU:` line | the hang is in that step; interrupts work |
| `timer service: NO tick ...` | still "unable to enumerate" | the timer interrupt does not reach Silver CPU0 after Mu; the register values in the line say where (GIC vs CNTV vs DAIF) |
| `timer service: on` but no enumeration | - | EP0 is served; the fault is in the DWC3 setup itself (next: compare DEPCFG/TRB with ABL usbfn) |

## Patches 2900-2906: debug channel complete, calendar, generic negroni ports (2026-11-01, area I)

Built [V] 2026-11-01 04:40: `kernel-linux: topaz e477291, 226 patches, 25 of them laurel`, `apply-xnu: applied=226 known-skip=0 failed=0`, 0 LSE/RCpc.
NOT BOOTED (the coordinator tests). Numbers below marked [I] are computed, not seen on the phone.

### 2900 console head buffer, live log from byte 0, boot log (negroni 0367)

Why the early lines were missing [V code + usblog-20261101-001446.txt]: the raw stream (before the ue0 attach) sent the
ring from byte 0 but, after a 10 s wait, also when no frame from the host had come; the host gets its address only when
usblog.sh sees the interface, so those datagrams were dropped (the 03:59:59 boot starts at `Skywalk: ... PASSED`). The
ue0 log thread started at the last 64 KiB, and a failed `sock_send` lost its chunk (the position had already moved).
Now:
- The first 1 MiB of console text of every boot is kept in a head buffer that is never overwritten (`laurel_log_head`);
  bytes the 4 MiB ring lost come from it, a gap is one line `[LAUREL LOG: console bytes A..B were overwritten ...]`.
- Raw mode and ue0 mode send nothing until a frame from 192.168.7.1 came (ARP or IPv4: usblog's `settime`, its
  keepalive, or any `op10tool ctl` command), then from byte 0. A failed send keeps its bytes. In a panic the old 10 s
  fallback stays. `op10tool ctl log` resends all (head + ring).
- Host wait (review m10), what to expect: after the USB link comes up the phone sends no log datagram until the host
  shows itself with any frame from 192.168.7.1 (ARP request, IPv4: usblog.sh's `settime` and its 10 s keepalive
  broadcast do it within about 1 s of the address; `op10tool ctl ping` does it too). A host that only listens
  (`nc -ukl 5140` with no traffic) gets nothing until then. Before a panic there is no time-out; in the panic hold the
  log goes out after 10 s without a sign, as before. A resend (`ctl log`, up to 5 MiB) goes out in bursts that stop at
  half of the TX queue (64 of 128 frames) and pause 1 ms per 32 datagrams, so `pong` and `ok bootloader` are never
  dropped; `bootlog read` answers `error: busy (TX queue)` or `error: busy (UFS in use, ask again)` (op10tool asks again).
- Boot log: the negroni 0367 slot area at userdata block N-28673 (9216 blocks: superblock `NEGRBLOG`, 8 slots of one
  header + 4 MiB ring; same structs, so `out/bin/op10tool bootlog` works unchanged). Self-check: the HFS+ volume header
  (partition byte 1024) must end below the area ([I] root image 16 GiB = 4194304 blocks; userdata 110501 MiB, so the area
  starts near partition block 28259583); then a write
  gate opens for the area only (no ufsrw=1 needed). Negroni's second anchor (the WLAN area header) does not exist here.
  Header: boot counter, state, SpringBoard mark, kernel UUID/version, boot-args, the PM6125 PON reasons of this
  power-on (`gen2 pon=0x.. warm=0x....(..) poff=0x....(..) fault=0x.... off=0x.. s3=0x..`, why the previous boot
  ended). Flush every 1 s for 5 min, then 5 s, wear budget, 30 s heartbeat. Panic: one polled write before the USB
  panic hold (only if the UFS lock is free). Halt/restart and the USB reset/poweroff commands write the end state.
  `/dev/laurelbootlog` (root, 0400) for `scripts/laurel/phone-ssh.sh bootlog`; `scripts/laurel/log-pull.sh` reads the
  area over adb from another system. The topaz SWEETLOG area is written only when the boot log is off.
- Lines: `LAUREL BOOTLOG: on: area at partition block N-28673 (9216 blocks, HFS+ ends at 4194304), new superblock;
  boot 1 -> slot 0; PON gen2 pon=...` (first boot), later `... boot N -> slot M` + up to 3 `LAUREL BOOTLOG: earlier boot
  ...` lines; `LAUREL BOOTLOG: boot N reached SpringBoard (pid P) T s after start`; `LAUREL BOOTLOG: off: <reason>`.
  Kill switch `laurelbootlog=0`.

### 2901 calendar (negroni 0203 + 0212)

SweetPlatformExpert had no getUTCTimeOfDay: the calendar started at 1970. Now `bsd/dev/laurel_rtc.c`: PM6125 RTC_RW
(SID 0, peripheral 0x60; qpnp-rtc ctrl 0x6046 bit 7, seconds 0x6048..0x604b) over the arbiter v5 observer channel of
its own APID (trinket bases), never written; wall = RTC + offset; the offset of the last set (USB `settime`, timed,
date) in `/private/var/db/laurel_rtc`, applied in bsd_init before launchd; floor = the kernel build date.
Lines: `LAUREL CALENDAR: on: PM6125 RTC APID N, ctrl 0x80, counter C s; boot calendar ...` or `LAUREL CALENDAR: off:
<reason> (...)`; `LAUREL CALENDAR: /private/var/db/laurel_rtc: no saved offset yet` (first boot); `LAUREL CTL: ok
settime ...`. In raw mode usblog's settime gets `ok settime S (pending: set at the ue0 attach)` and the attach prints
`LAUREL CTL: settime from raw mode: ok settime ...`. Kill switch `laurelrtc=0`. TODO (review m9): move the RTC lane into sweet_spmi.c
after area D (2300) merges.

### 2902-2906

- 2902 (0204 bit 0): `DKIOCISSOLIDSTATE` = 1, line `LAUREL SSD: on: ...` at the HFS mount; `laurelssd=0`.
- 2903 (0222 + 0386): privileges 1002/1007 (platform binaries) and 12000 (entitlement), sandbox extension ops 5/6;
  line `LAUREL SANDBOX: privileges 1002/1007/12000 on, extension tokens on`, then `LAUREL SANDBOX: <proc> privilege N
  granted (first grant)`; `laurelsandbox=0`, `laurelsbext=0`. Expected: the `privilege 1002/1007/12000 denied` lines and
  tccd's ENOENT for op 5 go away; 10001/10003/1005/12001 stay denied (not in negroni either).
- 2904 (0220 + 0221-aks-passcode): SweetKeyStore.cpp = the negroni AppleKeyStore (selectors 8/15/23/30/31/32/40/42/87/
  100/105/115, "no passcode" lock state 0x6 / sls 3, quiet log, software keybag passcode). Line `LAUREL AKS:
  AppleKeyStore registered (unlocked, lock state 0x6, key wrap on, passcode on)`. Kill switch `laurelaks_passcode=0`; `laurelaks_reset=1` = recovery (exception, plan.md).
- 2905 (0361 poll, 0382 USB, 0366 reset): poll 200 us while frames move, 4 ms idle, 20 ms without a host, TX queue 128,
  ENDTRANSFER at bus reset. Line `LAUREL USB POLL: on: ...`; status line `LAUREL USB: ue0 rx .. tx .. frames, N polls`.
  Old behaviour: `laurelusb_poll=0` (line `LAUREL USB POLL: off: ...`), `laurelusb_resetend=0`.
- 2906 (0399): wired guard for buffer IOSurfaces: 55 % of max_mem = of the 2100 RAM window (3264 MiB -> 1795 MiB wired;
  768 MiB fallback -> 422 MiB); backboardd and SpringBoard exempt; the 2101 screen pool does not pass it. Line `LAUREL
  WIRED: on: buffer surfaces refused above 1795 MiB wired = 55% of max_mem 3264 MiB (the 2100 window); backboardd and
  SpringBoard exempt; ...` at the first buffer surface; `laurelwiredguard=0`.
- 2907 (review M2): sweet_spmi.c init once under a mutex (sp_ready published last), PON lane under a spinlock with
  interrupts off (try-lock in a panic: the PON access fails, the reset still runs). Only the init and the two PON
  functions change (area D 2300 edits the same file).
- Not ported: 0288 PSCI cpuidle (below), the 0361 RX ring / TX batch, the 0366 soft-reconnect watchdog, the non-USB
  parts of 0382 (display-dark polls of touch/keys/battery belong to those areas).

0288 facts for a later port [V trinket-pm.dtsi]: trinket uses qcom,lpm-levels, not PSCI idle-states. CPU levels: C1 wfi
(psci mode 0, residency 91 us), C3 "pc" (mode 3, is-reset, use-broadcast-timer, entry 290 / exit 376 / residency 1182
us). Cluster (shift 4): D1 l2-wfi 1, D3G l2-gdhs 2, D3 l2-pc 4 (Silver residency 7376 us, Gold 8094 us). System (shift
8): wfi 0, pc 3 (residency 15338 us). lpm-levels power_state = psci_id | is_reset << 30 | affinity << 24, so a CPU
power collapse is CPU_SUSPEND 0x40000003. The C3 state stops the local timer: a broadcast timer (the MMIO frame of
timer@f120000) must wake the core, and the resume path must re-init the GICR of the core (2015) and the Gold hand-off
(2016) must stay valid for the boot CPU 0x100.

### Host side

- `out/bin/op10tool bootlog [N]` (USB, a good boot), `scripts/laurel/phone-ssh.sh bootlog` (SSH), `scripts/laurel/log-pull.sh
  DIR` (adb from another system). `op10tool ctl log|time|settime|bootlog`.
- SSH: `userland/ssh/build.sh` builds on Linux now (docs/usb-network.md "Build (Linux x86_64)"); `scripts/laurel/root.sh`
  installs dropbear + tools when `out/ssh/ios` exists (SSH=0: none); `scripts/laurel/phone-ssh.sh` runs commands.
