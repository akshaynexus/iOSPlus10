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
