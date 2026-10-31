# Bluetooth on the Mi A3 (laurel 2600)

Patch: `patches/laurel/xnu/2600-laurel-bluetooth-wcn3990.patch` (range 2600-2699 is this area).
Status: builds (kernel-linux.sh, 228/228 patches, 0 LSE). **Not tested on the phone yet.**
[V] = read in source, [I] = inference.

## Files (one step per file, each < 310 lines)

| File | Step |
| --- | --- |
| `bsd/dev/laurel_bt.h` | shared declarations |
| `bsd/dev/laurel_bt_geni.h` | QUP1 SE9 addresses, GENI registers, UART state (private to clk + uart) |
| `bsd/dev/laurel_bt_clk.c` | mappings, GCC votes, s4 RCG / DFS levels, pins, GENI FIFO mode, self-check |
| `bsd/dev/laurel_bt_uart.c` | baud (DFS level or RCG table), FIFO TX/RX, flow control |
| `bsd/dev/laurel_bt_power.c` | rails over the RPM, power pulses |
| `bsd/dev/laurel_bt_fat.c` | FAT12/16 reader of `bluetooth_b` / `bluetooth_a` (read-only) |
| `bsd/dev/laurel_bt_fw.c` | rampatch + NVM download, NVM speed tag |
| `bsd/dev/laurel_bt_h4.c` | H4 framing, QCA vendor-event parsers, answers for bluetoothd |
| `bsd/dev/laurel_bt_hci.c` | bring-up HCI: EDL version, speed change, reset, BD_ADDR |
| `bsd/dev/laurel_bt_ios.c` | transport core: RX thread, queue, TX framing, in-band sleep |
| `bsd/dev/laurel_bt_ctl.c` | kernel control `com.apple.uart.bluetooth` |
| `bsd/dev/laurel_bt_dev.c` | `/dev/uart.bluetooth`, `/dev/cu.bluetooth`, `/dev/btwake` |
| `bsd/dev/laurel_bt.c` | STARTUP hook, kill switch, threads, the result line |
| `iokit/Kernel/arm/LaurelBluetooth.cpp` | ADT nub: address in use, hidden when off |

Conf lines: `bsd/conf/files` after `laurel_reboot.c`, `iokit/conf/files.arm64` after `TopazRpm.cpp` (both
anchors exist before 2700, which applies after 2600).

Syntax check of one file in a few seconds: `scripts/laurel/kcheck.sh bsd/dev/laurel_bt_uart.c` (records the
compiler line once: `scripts/bg.sh kcheck scripts/laurel/kcheck.sh --record`).
Edit loop: change the files in `out/laurel-kernel/xnu-src/...`, copy them to a `b/` tree next to an `a/` tree of
the two conf files, `diff -ruN a b` below the description paragraph of the patch. `kernel-linux.sh` clones the
xnu tree again on every run: make the patch first.

## Hardware [V external/laurel-kernel-los]

- `trinket.dtsi:2048` `bt_wcn3990` (qca,wcn3990): vdd-io L9 1.7-1.9 V, vdd-core L17 1.304 V, vdd-pa L23 3.0-3.4 V,
  vdd-xtal L16 1.7-1.9 V. No BT_EN pin: power by rails + UART pulses.
- `trinket-qupv3.dtsi:252` `qupv3_se9_4uart` @ 0x4c90000, SPI 312, clocks GCC_QUPV3_WRAP1_S4_CLK + wrap 1
  m/s AHB; wrapper qupv3_1 @ 0x4cc0000 (QUP_HW_VER +4).
- `gcc-trinket.c` (GCC 0x1400000): s4 RCG 0x39608 (DFS_ENABLE_RCG: DFSR +0x14, PERF +0x1c, M +0x5c, N +0x9c);
  vote reg 0x7900c: bit 18 core_2x (CBCR 0x39014), 19 core (0x3900c), 20 m_ahb (0x39004), 21 s_ahb (0x39008,
  hwcg), 26 s4 (0x39604). Parents: XO 19.2 MHz, GPLL0 early 600, GPLL0 aux2 300, GPLL6 384 MHz.
- Pins GPIO 10 CTS, 11 RTS, 12 TX, 13 RX; tile EAST (TLMM 0x400000 + 0x900000); function qup14 = 1; CTS/RX no
  pull, RTS pull-down, TX pull-up, 2 mA.
- `msm_geni_serial.c`: UART_OVERSAMPLING 32; start_rx uses RFR_OPEN (we use param 0: RFR follows the
  watermark, polled, so no byte is lost).

## Bring-up (laurel_bt.c thread, Linux hci_qca.c / btqca.c order)

1. Wait for UFS (`sweet_ufs_read_part("bluetooth_b")` not EAGAIN, up to 180 s).
2. Rails: `topaz_soc_map()` (maps APCS, the RPM doorbell), then `topaz_rpm_write(set 0 and 1, "ldoa", n, "uv"/"swen")`
   for L9 1.8 V, L16 1.8 V, L17 1.304 V, L23 3.0 V. A refusal is logged and the bring-up goes on (the rails can be on
   from the bootloader); the EDL version answer is the check.
3. UART: votes, CBCR checks, DFS levels, SE9 firmware = UART (protocol 2), FIFO interface on, pins, GENI FIFO mode,
   115200 8N1 RTS/CTS.
4. Power: 0xC0 at 2400 baud, 0xFC at 115200 (flow control off for each pulse), 100 ms boot.
5. EDL version `0xfc00 {0x19}` -> vendor event `04 ff len 00 02 product patch rom soc` (3 tries).
6. Speed: host clock checked first; flow off, `0xfc48 {14}`, 10 ms, host 3000000, flow on, vendor event within 100 ms.
7. Firmware from the phone (FAT16, `/image/crbtfw21.tlv`, `/image/crnv21.bin`, name from ROM 0x0201 -> 21):
   whole files in 243-byte EDL segments `0xfc00 {0x1e, len, bytes}`, answer `04 ff 03 00 04 result`; rampatch
   mode 1/3 = only the last segment is answered; NVM tag 17 byte 2 = speed index 14. Product mismatch = off;
   ROM build mismatch = logged only (as Linux).
8. HCI reset 0x0c03.
9. BD_ADDR: the chip's own (Read BD_ADDR 0x1009) when valid and not the NVM tag 2 default; else the ADT
   `local-mac-address` with `0xfc14` (display order, btqca.c qca_set_bdaddr) + read back. The address in use goes to
   the ADT nub.
10. The transport goes ready; one line.

Firmware is read at run time from the phone; it is never in git.

## Log lines

- `LAUREL BT: on: WCN3990 product 0x000a rom 0x0201, crbtfw21.tlv + crnv21.bin, 3000000 baud, BD_ADDR ..` [expected,
  not seen yet]
- `LAUREL BT: off: <reason>`, e.g. `no EDL version answer (chip not powered?)`, `QUP1 SE9 has no UART firmware`,
  `QUP1 core/AHB clocks do not run`, `file not in the partition`, `laurelbt=0`.
- Step lines: `LAUREL BT: clk: ...`, `geni: ...`, `uart: ...`, `power: ...`, `chip: ...`, `fw: ...`, `ios: client ...`.

Kill switch: `laurelbt=0`. Off = `/dev` nodes removed, ADT nub hidden, connects refused (ENXIO). USB, UFS, Wi-Fi
and the boot are not touched.

## iOS side (negroni path, not apollo: topaz has no sweetinject)

- Kernel control `com.apple.uart.bluetooth` (SOCK_STREAM, not privileged), TIOCGETA/TIOCSETA socket options
  (stored only; the line stays at 3000000 RTS/CTS). `/dev/uart.bluetooth`, `/dev/cu.bluetooth` (raw H4, select,
  FIONREAD), `/dev/btwake` (no-op). One client at a time; made after the root mount; sends wait up to 60 s for the
  bring-up.
- Answers in the kernel (negroni 0336/0337): every OGF 0x3f vendor command (Broadcom meanings) gets a Command Complete
  and never reaches the WCN3990; 0x0c5a/0x0c5b when the chip's mask lacks them; 0x204a; 0x0c6d / 0x2007 errors
  -> status 0; Write LE Host Support Simultaneous_LE_Host -> 0.
- In-band sleep: SLEEP_IND/WAKE_IND/WAKE_ACK stay in the kernel; a send after SLEEP_IND sends WAKE_IND first.
- ADT `/arm-io/bluetooth` (`scripts/laurel/mkadt.py`): local-mac-address 02:4c:41:33:42:54 (synthetic fallback),
  transport-encoding 3, transport-speed 3000000, vendor/product id as negroni.
- Userland: `userland/laurel/bt/build.sh` (Linux: theos + .tbd stub + ldid; macOS: Xcode) builds the BlueTool
  stand-in from `userland/bluetooth/negroni-bluetool.c` with the WCN3990 firmware string ->
  `out/laurel/bt/negroni-bluetool`. `scripts/laurel/root-bt.sh` (called by `root.sh`, `BT=0` skips) installs it and
  turns the bluetoothd job on (`scripts/bt/bt-launchd.py on`).

## Not done / differences from negroni

- No power-follows-client (negroni 0335): the chip stays on; the Settings switch goes through bluetoothd only.
- No 0338 (LE legacy -> extended).
- No hcitest on the root (a test-only tool).

## Risks

- TopazRpm refuses when Mu or ABL used the RPM FIFOs ("FIFOs used since boot"): then only the boot state of
  the rails counts. If L17/L23 are off, the result is `off: no EDL version answer`.
- `topaz_soc_map()` waits up to 60 s for the modem partition (TopazModem's probe); the apcs mapping is made either way.
- The DFS levels that XBL left in the s4 RCG are not known: 3000000 baud needs a 96 MHz level (oversampling 32).
  Without one: `off: no QUP clock for the speed` (the chip is not told to change speed).
- SE9 may hold no UART firmware if XBL did not load it (`off: QUP1 SE9 has no UART firmware`).
- Area audio (`t3/laurel-audio-speaker-adsp` root-audio.sh) moves BTAudioHALPlugin.driver to HAL.disabled; with
  Bluetooth audio it may have to stay (negroni: `BTAUDIO=1`). Merge note: both root.sh hooks go after the
  boldtext line.
- Polled RX: throughput is bounded by the RX FIFO per poll (RFR holds the chip; no loss).
