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
SYSTEM_RESET; `poweroff` -> PSCI SYSTEM_OFF; `panic` -> `panic("requested over USB")`. Unknown words
(e.g. negroni's `settime`, `bootlog`, `usbstats`) get `error: unknown command`; usblog.sh tolerates that.
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
