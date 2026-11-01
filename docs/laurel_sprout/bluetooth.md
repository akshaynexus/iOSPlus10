# Bluetooth on the Mi A3 (laurel 2600)

Patch: `patches/laurel/xnu/2600-laurel-bluetooth-wcn3990.patch` (range 2600-2699 is this area).
Status: first boot 2026-11-01 05:52 stopped at `off: QUP1 SE9 FIFO interface is off (GSI only)`; fix in this patch
(section "SE9 left in GSI mode"). Fix not booted yet.
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
the two conf files, `diff -ruN a b` below the description paragraph of the patch. For new files only:
`scripts/laurel/patch-refresh-new.py PATCH TREE bsd/dev/laurel_bt_clk.c ...` replaces their hunks in place. `kernel-linux.sh` clones the
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
3. UART: votes, CBCR checks, DFS levels, SE9 firmware = UART (protocol 2), FIFO interface on (clear
   SE_FIFO_IF_DISABLE when the boot left GSI, read back), pins, GENI FIFO mode,
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

## SE9 left in GSI mode (boot 2026-11-01 05:52)

Seen [V logs/usblog-20261101-001446.txt, 05:52:35-05:52:41]:

```
LAUREL BT: power: L9 1.8 V, L16 1.8 V, L17 1.304 V, L23 3.0 V on
LAUREL BT: clk: vote 0x4020 -> 0x43c4020, s4 RCG cfg 0x100000, DFS off (0 levels, top 0 Hz)
LAUREL BT: geni: QUP 0x20000000 (oversampling 32), SE9 FW 0x20c, FIFO 16/32 words
LAUREL BT: off: QUP1 SE9 FIFO interface is off (GSI only)
```

- [V] The firmware in SE9 is UART (0x20c: protocol 2, version 0x0c). No firmware load is necessary.
- [V Linux 6.18 external/laurel-mainline drivers/soc/qcom/qcom-geni-se.c] `GENI_IF_DISABLE_RO` (0x64) only shows the
  writable `SE_FIFO_IF_DISABLE` (SE + 0x2008, bit 0). `geni_load_se_fw` writes it last: clear for FIFO, set for GSI,
  after `geni_configure_xfer_mode` (FIFO: `SE_GENI_DMA_MODE_EN` bit 0 = 0, `SE_GSI_EVENT_EN` = 0) and `SE_DMA_IF_EN`
  (0x2004) bit 0 = 1. `geni_load_se_firmware` always uses FIFO for UART. So the bit is a soft setting (case a), not a
  GSI-only firmware.
- [V 4.14 external/laurel-kernel-los] `msm_geni_serial.c` (`qcom,msm-geni-serial-hs`, SE9 `qupv3_se9_4uart`) never reads
  the bit and uses SE_DMA for the BT port (`xfer_mode = SE_DMA`, console = FIFO). Only `spi-geni-qcom.c` reads it
  (FIFO off -> GSI only). There is no GSI path for the UART in either kernel.
- [I] The boot (XBL QUP loader or the UEFI GpiDxe/I2CDxe that Mu runs) leaves SE9 for GSI. Which one is not known.
- Fix (`laurel_bt_clk.c` `fifo_if_on`, between the GENI check and the pins): when the RO bit is set, cancel the
  sequencers, DMA mode off, GSI events off, DMA_IF_EN on, clear SE_FIFO_IF_DISABLE, read the RO bit again. Bit still set
  = `off: QUP1 SE9 FIFO interface stays off (GSI only)` (only Bluetooth). Line: `geni: FIFO interface was off ...`.
- [I] Risk: if a TrustZone xPU protects SE + 0x2000, the write is ignored (then the self-check turns BT off) or gives a
  bus error. Linux writes the same register from the HLOS on other SoCs. Kill switch `laurelbt=0` skips all of BT.
- Clock for 3000000 baud [V gcc-trinket.c, laurel_bt_uart.c]: DFS is off, so `lbt_uart_set_baud` uses the Linux table
  (`ftbl_gcc_qupv3_wrap0_s0_clk_src`). 3000000 x 32 = 96 MHz = table entry `F(96000000, P_GPLL0_OUT_AUX2, 1, 8, 25)`
  (GPLL0 aux2 300 MHz x 8/25, src 2 in `gcc_parent_map_1`), divider 1, exact. 115200 x 32 = 7.3728 MHz (entry 1,
  divider 1). `lbt_hci_speed` programs 96 MHz and back before it sends 0xfc48 (a stuck RCG update = `off: no QUP clock
  for the speed`, the chip keeps 115200). [I] 96 MHz needs the CX corner LOW (`rate_max` LOWER 75 MHz); no CX vote is
  made, the boot corner is used.

## Log lines

- `LAUREL BT: on: WCN3990 product 0x000a rom 0x0201, crbtfw21.tlv + crnv21.bin, 3000000 baud, BD_ADDR ..` [expected,
  not seen yet]
- `LAUREL BT: geni: FIFO interface was off (GSI from boot): FIFO_IF_DISABLE 0x1 -> 0, DMA_IF_EN 0x1, RO 0` [expected;
  only when the boot left GSI]. A RO value with bit 0 set = `off: QUP1 SE9 FIFO interface stays off (GSI only)`.
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
- [V boot 05:52] DFS is off in the s4 RCG: the RCG table path is used (96 MHz for 3000000 baud, section above).
- [V boot 05:52] SE9 holds UART firmware 0x20c, but in GSI mode: fixed by `fifo_if_on` (section above).
- Area audio (`t3/laurel-audio-speaker-adsp` root-audio.sh) moves BTAudioHALPlugin.driver to HAL.disabled; with
  Bluetooth audio it may have to stay (negroni: `BTAUDIO=1`). Merge note: both root.sh hooks go after the
  boldtext line.
- Polled RX: throughput is bounded by the RX FIFO per poll (RFR holds the chip; no loss).
