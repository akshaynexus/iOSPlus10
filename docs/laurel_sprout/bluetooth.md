# Bluetooth on the Mi A3 (laurel 2600)

Patch: `patches/laurel/xnu/2600-laurel-bluetooth-wcn3990.patch` (range 2600-2699 is this area).
Status: boot 2026-11-01 05:52 stopped at `off: QUP1 SE9 FIFO interface is off (GSI only)`. Boot 06:07 (228d505,
writes to SE + 0x2004/0x2008) stopped after the `geni:` line. Now: SE DMA mode, no access to SE + 0x2000..0x2008
(section "SE9 left in GSI mode"). SE DMA not booted yet.
[V] = read in source, [I] = inference.

## Files (one step per file, each < 310 lines)

| File | Step |
| --- | --- |
| `bsd/dev/laurel_bt.h` | shared declarations |
| `bsd/dev/laurel_bt_geni.h` | QUP1 SE9 addresses, GENI registers, UART state (private to clk + uart) |
| `bsd/dev/laurel_bt_clk.c` | mappings, GCC votes, s4 RCG / DFS levels, pins, GENI FIFO or SE DMA mode, self-check |
| `bsd/dev/laurel_bt_uart.c` | baud (DFS level or RCG table), FIFO TX/RX, flow control |
| `bsd/dev/laurel_bt_dma.c` | SE DMA TX/RX (boot left the FIFO interface off): SMMU stream 0x143, pool buffers |
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
3. UART: votes, CBCR checks, DFS levels, SE9 firmware = UART (protocol 2), mode from GENI_IF_DISABLE_RO bit 0
   (0 = FIFO, 1 = SE DMA: apps SMMU identity for stream 0x143, 4 KiB TX + 2 KiB RX buffers in the modem pool),
   pins, 115200 8N1 RTS/CTS, RX command (DMA mode: the RX transfer is armed first).
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
- [V] QUP_HW_VER 0x20000000 = QUP v2.0 (major 31:28 = 2, minor 27:16 = 0).

Boot 06:07 (commit 228d505, `fifo_if_on`: reads SE + 0x2008 / 0x2004 first, then writes them) [V
logs/usblog-20261101-001446.txt 06:07:26-06:11:27]: the `geni:` line, then no other `LAUREL BT` step line for 4 min
(no `geni: FIFO interface was off`, no `uart:`, no `on:` / `off:`). No panic. bluetoothd ran and
`ios: client control connected` came (the attach thread is separate). [I] The BT thread stopped at an access in
`fifo_if_on`, most likely the first read of SE + 0x2008 (a register that this QUP version does not decode, or that
an xPU guards: the CPU stalls, as in the TrustZone hang of 2153). The boots at 06:12 and 06:17 show no BT step line at
all (only `ios:` lines, and no TopazRpm/THERMAL lines either): their early log is incomplete; no fact from them.

Source facts:
- [V Linux 6.18 external/laurel-mainline qcom-geni-se.c] SE_DMA_IF_EN (0x2004) and SE_FIFO_IF_DISABLE (0x2008) are
  written only in `geni_load_se_fw`. `qcom_geni_serial_port_setup` calls `geni_load_se_firmware` only when
  GENI_FW_REVISION shows no protocol (`GENI_SE_INVALID_PROTO`): SoCs where the HLOS loads the SE firmware. SE9 has
  firmware, so mainline would never touch the two registers here.
- [V 4.14 external/laurel-kernel-los] `include/linux/qcom-geni-se.h`, `qcom-geni-se.c`, `msm_geni_serial.c`,
  `spi-geni-qcom.c`, `i2c-qcom-geni.c` have no register above 0xE40 (SE_DMA_DEBUG_REG0). Nothing writes 0x2004/0x2008.
- [V 4.14] The BT port (`qcom,msm-geni-serial-hs`, not the console) is always SE_DMA (`msm_geni_serial_port_setup`:
  `xfer_mode = SE_DMA`, packing 8 bits x 4, RX buffer 2048 = DMA_RX_BUF_SIZE, UART_RX_STALE_CNT = 10 x 16 bits).
  TX: `setup_tx` (UART_TX_TRANS_LEN, M_CMD UART_START_TX) + `geni_se_tx_dma_prep` (TX_IRQ_EN_SET 7, PTR_L/H 0xc30/0xc34,
  ATTR 1 = EOT 0xc38, LEN 0xc3c); done = SE_DMA_TX_IRQ_STAT 0xc40 bit 0 TX_DMA_DONE. RX: `geni_se_rx_dma_start`
  (RX_IRQ_EN_SET 7, PTR 0xd30/0xd34, ATTR 0, LEN 0xd3c) before UART_START_READ; a transfer ends with RX_DMA_DONE (bit 0)
  or RX_EOT (bit 1) of 0xd40 when the line is idle for the stale count; bytes = SE_DMA_RX_LEN_IN 0xd54; the ISR re-arms
  with the same buffer, the read command stays active. Bit 2 = SBE (bus error). Error path: FSM_RST 0xc58 / 0xd58, wait
  RESET_DONE bit 3. `geni_se_select_dma_mode`: GSI_EVENT_EN 0, IRQ clears, SE_IRQ_EN all, GENI_DMA_MODE_EN bit 0 = 1.
- [V 4.14] `spi-geni-qcom.c` and `i2c-qcom-geni.c` read GENI_IF_FIFO_DISABLE_RO: bit set = they use GSI only (they never
  pick SE_DMA then). The UART driver never reads it. [I] The FIFO interface bit gates CPU access to the FIFO registers
  (0x700/0x780); SE DMA uses the DMA interface, which GSI also needs. Same boot chain as Android (XBL + ABL; our Mu
  build has no QUP DXE), where the 4.14 BT port works in SE_DMA, so SE_DMA very likely works with the bit set. Not
  seen on this phone yet: the self-check below decides.
- [V trinket-qupv3.dtsi:231] `qupv3_1` (QUP1 wrapper 0x4cc0000): `qcom,iommu-s1-bypass`, context
  `iommus = <&apps_smmu 0x143 0x0>`: QUP1 DMA goes through the apps SMMU with stream 0x143.
- [V boot log 05:52:01 / 06:07:26] `TopazModem: smmu: sCR0 00270406`: bit 10 USFCFG = 1, an unmatched stream faults. So
  stream 0x143 needs an SMR + identity context: `topaz_smmu_identity(0x143, 0, ...)`, the same call that gives WLAN 0x80
  and audio 0x41 `-> OK` on this phone.

Fix (`laurel_bt_clk.c` + new `laurel_bt_dma.c`):
- `fifo_if_on` is removed. No access to SE + 0x2000..0x2008 any more; only registers of the 4.14 driver.
- GENI_IF_DISABLE_RO bit 0 = 0: FIFO mode as before. Bit 0 = 1: SE DMA mode (`geni_setup` sets GENI_DMA_MODE_EN bit 0).
- `lbt_dma_init`: SMMU identity for 0x143 (else `off: apps SMMU: no identity stream for QUP1 (sid 0x143): SE DMA not
  possible`); 4 KiB TX + 2 KiB RX from `topaz_pool_alloc` (modem pool 0xE0000000: contiguous, Normal NC, below 4 GiB, no
  cache maintenance; else `off: no memory for SE DMA (modem pool off)`); an engine left active by the boot is reset.
- TX: copy, dsb, TRANS_LEN + UART_START_TX, DMA PTR/ATTR/LEN; wait for TX_DMA_DONE and the end of the M command (the
  last stop bit is out: needed before a baud change); the wait has the wire time + 100 ms limit; RX is polled meanwhile.
- RX: one 2 KiB transfer armed; each read polls 0xd40: DONE/EOT -> LEN_IN bytes to the ring when it has room (else the
  transfer waits, the RX FIFO fills, RFR stops the chip), clear, re-arm; the read command is started again if it ended.
- Self-check: SBE on TX or RX, or a TX that does not finish while CTS is ignored (the 0xC0/0xFC power pulses), sets the
  fault; the power-pulse and EDL-version failures then give it as the off reason, e.g.
  `off: SE DMA TX does not finish with CTS ignored (SE DMA blocked?)` or `off: TX bus error (QUP1 stream 0x143 blocked by
  the SMMU?)`. The EDL version answer stays the end-to-end check. Only Bluetooth turns off; `laurelbt=0` skips all of BT.
- Clock for 3000000 baud [V gcc-trinket.c, laurel_bt_uart.c]: DFS is off, so `lbt_uart_set_baud` uses the Linux table
  (`ftbl_gcc_qupv3_wrap0_s0_clk_src`). 3000000 x 32 = 96 MHz = table entry `F(96000000, P_GPLL0_OUT_AUX2, 1, 8, 25)`
  (GPLL0 aux2 300 MHz x 8/25, src 2 in `gcc_parent_map_1`), divider 1, exact. 115200 x 32 = 7.3728 MHz (entry 1,
  divider 1). `lbt_hci_speed` programs 96 MHz and back before it sends 0xfc48 (a stuck RCG update = `off: no QUP clock
  for the speed`, the chip keeps 115200). [I] 96 MHz needs the CX corner LOW (`rate_max` LOWER 75 MHz); no CX vote is
  made, the boot corner is used.

## Log lines

- `LAUREL BT: on: WCN3990 product 0x000a rom 0x0201, crbtfw21.tlv + crnv21.bin, 3000000 baud, BD_ADDR ..` [expected,
  not seen yet]
- SE DMA mode [expected, not seen yet], in this order:
  `TopazModem: smmu: QUP1 Bluetooth identity (sid 143 mask 0) CB.. SMR..: SMR 80000143 S2CR 0000000. ... -> OK`,
  `LAUREL BT: geni: FIFO interface off (boot left GSI): SE DMA mode, SMMU sid 0x143, buffers 0xe....000 (TX 4096, RX
  2048), debug 0x.. -> 0x..`, `LAUREL BT: uart: 115200 8N1 RTS/CTS, SE DMA, RX on (status 0x....)`, then `chip:` and
  `on:`. FIFO mode: the `uart:` line says `FIFO`.
- `LAUREL BT: uart: DMA: <fault> (stat .., debug .., status ..)`: the first SE DMA fault (once), then `off: <fault>`.
- `LAUREL BT: uart: DMA TX of N bytes stalled (stat .., status .., CTS used|ignored)`: a TX limit was reached.
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
- [V boot 05:52] SE9 holds UART firmware 0x20c, but the FIFO interface is off: SE DMA mode (section above).
- [I] SE DMA with the FIFO interface off is not seen yet. If the engine is blocked: `off: SE DMA TX does not finish
  with CTS ignored ...` (BT only). The next step would then be GPI (GSI) DMA, which no Linux UART driver has.
- [I] SE_IRQ_EN and the DMA IRQ enables are set as in Linux; SPI 312 is not enabled in the GIC (polled), so no
  interrupt comes.
- Area audio (`t3/laurel-audio-speaker-adsp` root-audio.sh) moves BTAudioHALPlugin.driver to HAL.disabled; with
  Bluetooth audio it may have to stay (negroni: `BTAUDIO=1`). Merge note: both root.sh hooks go after the
  boldtext line.
- Polled RX: FIFO mode: bounded by the RX FIFO per poll; SE DMA mode: 2 KiB per poll (RFR holds the chip; no loss).

## Chip and firmware names (phone, 2026-11-01 06:36)

- [V log] SE DMA works: `LAUREL BT: chip: product 0x000f patch 0x0001 rom 0x0102 soc 0x40070120`, then
  `fw: crbtfw12.tlv: file not in the partition`. The driver took the number from the ROM field.
- [V BTFM.bin of V12.0.26.0.RFQMIXM, mdir] /image has apbtfw10/11.tlv, apnv10/11.bin, crbtfw11/20/21.tlv, crnv11/20/21.bin,
  cmbtfw10-12.tlv, cmnv10-12.bin.
- [WRONG, see the 07:19 section below] [Linux btqca qca_uart_setup] the number is ((soc & 0xf00) >> 4) | (soc & 0xf) = 0x10 for soc 0x40070120; the `ap` prefix
  is WCN3988. So the Mi A3 chip is a WCN3988 [I from the files present], not a WCN3990.
- Fix (2600, laurel_bt_fw.c): number from the SoC version; crbtfw%02x first, then apbtfw%02x + apnv%02x. patch_check still
  checks the rampatch against the chip.

## The chip is WCN3950 family: cmbtfw12.tlv + cmnv12.bin (boot 2026-11-01 07:19, laurel 2601 in patch 2600)

- [V log 07:19:32] `LAUREL BT: chip: product 0x000f patch 0x0001 rom 0x0102 soc 0x40070120`, then
  `LAUREL BT: off: the rampatch is for another product` (apbtfw10.tlv, picked by the 06:36 fix above).
- [V BTFM.bin headers, `scripts/laurel/bt-fw-test.sh`; rampatch = Linux `struct tlv_type_patch`, product at byte 16,
  ROM build at byte 18]: apbtfw10.tlv product 0x000a ROM build 0x0200; crbtfw20.tlv 0x000a/0x0200; crbtfw21.tlv and
  apbtfw11.tlv 0x000a/0x0201; cmbtfw10/11/12.tlv product 0x000f, ROM build 0x0100/0x0101/0x0102. Only **cmbtfw12.tlv**
  matches the chip (product 0x000f, ROM 0x0102).
- [V Linux btqca.c qca_uart_setup, laurel-mainline] `soc_ver = (soc_id << 16) | rom_ver`, so its low 16 bits are the
  **ROM version** (0x0102), not the SoC id. The 06:36 note above read it wrongly. Number: WCN3950 / WCN3990 / WCN3991
  `((rom & 0xf00) >> 4) | (rom & 0xf)` = 0x12; WCN3988 `>> 5`; WCN3998 `((rom & 0xf000) >> 7) | (rom & 0xf)`. Prefix:
  `cm` = WCN3950 (product 0x0f; NVM `cmnv%02x` + `t`/`s` for soc 0x40074130/0x40075130), `cr` = WCN3990/1/8, `ap` =
  WCN3988. soc 0x40070120 is neither WCN3950 `t` nor `s`: `cmnv12.bin`. WCN3950 is below WCN3991 in Linux's enum: the
  version answer has no extra byte (our parse is right) and the transport is the WCN399x one (power pulses, speeds).
- [V Linux qca_tlv_check_data] Linux checks nothing in the rampatch header (it only reads the download mode). We keep a
  product check (a rampatch of another family never goes to this chip) and prefer an exact ROM build.
- Fix (`laurel_bt_fw.c`): every candidate (cm, cr, ap, WCN3998 cr) that exists in the partition is read once; its header
  picks it: first product + ROM build match, else first product match (`sent anyway, as Linux does`). No match:
  `off: no rampatch for this product in the firmware partition`, names tried in the line. TLV sanity: TLV length = size
  - 4, total size <= TLV length, data length < total size.
- NVM tag 17 (HCI transport). [V files] crnv21/apnv10: `82 01 11 08 04 ..`: byte 2 = 0x11 = speed index 3200000 (Linux
  writes byte 2 below WCN3991, byte 1 from WCN3991). cmnv12.bin: `15 11 22 00 2e 00`: byte 1 = 0x11 (a speed index),
  byte 2 = 0x22 (none; the table ends at 0x12). [I] the WCN3950 file puts the speed in byte 1; Linux writes byte 2 for
  WCN3950 (it then also sets the speed with a command). Here the chip must come out of the NVM at our speed (HCI reset at
  3000000 follows), so the speed goes to Linux's byte when that byte holds a speed index, else to the other byte when that
  one does (a log line says so); neither: the NVM is refused.
- Host test [V 2026-11-01]: `scripts/laurel/bt-fw-test.sh` builds `laurel_bt_fw.c` from the patch with stubs and runs it on
  the stock files: Mi A3 chip -> `cmbtfw12.tlv + cmnv12.bin`, NVM tag 17 sent as `15 0e 22 00 2e 00`; WCN3990 (0x000a,
  0x0201) -> `crbtfw21.tlv + crnv21.bin`, `82 01 0e ..`; unknown product -> off.
- Expected on the phone [not seen yet]: `LAUREL BT: fw: cmbtfw12.tlv 43991 bytes from bluetooth_b, product 0x000f ROM
  build 0x0102 patch 0x0002, mode 3`, `fw: NVM tag 17 byte 2 is 0x22 (no speed index), byte 1 is 0x11: the speed goes
  there`, `fw: cmnv12.bin 2564 bytes from bluetooth_b, speed index 14 in tag 17 byte 1`, then
  `on: WCN39xx product 0x000f rom 0x0102, cmbtfw12.tlv + cmnv12.bin, 3000000 baud, BD_ADDR ..`.
