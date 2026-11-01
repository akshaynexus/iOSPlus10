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
| Live console | UDP to 192.168.7.1:5140 every 100 ms, starts with the last 64 KiB of the console ring |
| Commands | UDP to 192.168.7.2:5141, one ASCII word per datagram, reply to the source port, only from 192.168.7.1 |

Commands: `ping` -> `pong`; `log` -> `ok log` (the last 64 KiB again); `reboot` / `bootloader` / `recovery`
-> `ok <cmd>` then, 500 ms later, the IMEM restart reason of patch 2003 (`kern.laurel_reboot_mode`) + PSCI
SYSTEM_RESET; `poweroff` -> PSCI SYSTEM_OFF; `panic` -> `panic("requested over USB")`; `settime <s>[.<frac>]` ->
`ok settime <s>.<us>`, then `LAUREL CTL: settime ...: clock set` (patch 2720; usblog.sh sends it at each interface up);
`time` -> `time <s> rtc <raw> offset <n> source ...` (2720, docs/laurel_sprout/rtc-statusbar.md). Unknown words
(e.g. negroni's `bootlog`, `usbstats`) get `error: unknown command`; usblog.sh tolerates that.
Not ported: 0367 `bootlog` (the userdata ring). topaz 0047 already writes the console ring to the end of
the UFS partition; a reader for it is future work.

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
