# Bluetooth kernel changes (0330-0349)

Plan and facts: [docs/bluetooth-plan.md](../../docs/bluetooth-plan.md).

## 0330-negroni-bt-uart-power.patch

Made in `out/kernel/tree-bt` (patched-tree.sh, full set) with `git add -N` + `git diff HEAD`.

Files:
- `bsd/dev/negroni_bt.c` (new): QCA6490 power sequence (btpower.c order) + GENI UART on QUP2 SE5, FIFO mode, polled.
- `bsd/dev/negroni_bt.h` (new): the seam for the HCI stage (UART read/write/baud/flow).
- `bsd/dev/negroni_bt_hci.c` (new): stub; a later patch replaces it.
- `bsd/dev/negroni_rpmh.c`: `negroni_rpmh_bt_enable()` (allow list smpb11 966, smpc1 1900, smpb12 1350, ldoe7 2800 mV;
  voltage + enable, no mode). Never votes off.
- `bsd/dev/negroni_ufs.c`: calls `negroni_bt_init()` after `negroni_adsp_init()`.
- `bsd/conf/files`: the two `.c` files.

Maps (all `ml_io_map_unmappable`, no io_submap): GCC 0x12c000/32 KiB + 0x160000/16 KiB, TLMM pins 76-83 (32 KiB) and 204
(16 KiB), QUP2 wrapper 16 KiB, SE5 16 KiB.

Boot-args: `negronibt=1|2` (default 0 = nothing), `negronibt_delay` (s, 3), `negronibt_noflow=1`, `negronibt_rfropen=1`,
`negronibt_aon_ms` (100), `negronibt_off=1`.

Expected log (all lines start `NEGRONI BT:`):

| Line | Meaning |
|---|---|
| `step 1 map ...` .. `step 8 RX idle bytes` | step markers |
| `2 GPIO76 CTS: cfg ...` (8 lines) | pin census before any write |
| `3 smpb11 966 mV: errno 0` (4 rails) | RPMh votes |
| `4 branches: wrap2 core on, core_2x on, m_ahb on, s_ahb on, s5 on` | GCC clocks run |
| `4 S5 RCG ... DFS on|off`, `4 DFS level N: ... Hz` | clock source |
| `5 QUP2 HW version ... SE5 FW revision ... (protocol 2 ...)` | UART firmware present |
| `6 UART 115200 8N1, flow control RTS/CTS, RX started` | UART ready |
| `7 BT_EN out 1 ..., SW_CTRL 1 (asserted ...)` | the BT side has power |
| `8 N bytes from the controller after power-on` | usually 0 |
| `negronibt=2: the HCI stage is not in this kernel` | stub |
| `stage A done` | thread end |
| `stop: ...` | the step that failed (QUP2 clocks off, no UART firmware, FIFO disabled, rail vote) |

Failure path: a failure after step 7 drives BT_EN low again (also `negronibt_off=1` at the end); a failure after
step 4 restores the GCC vote word when step 4 changed it. **Rails stay on:** the four rails are never voted off
(all shared; smpb12 is the UFS vccq parent; bergamota panicked after a rail-off vote).

Review fixes (2026-10-26): WLAN_EN is read as the pin level (IO bit 0), SW_CTRL is set to input before it is read,
the cold threshold is TEMP_THRESHOLD 5000 = 5 C.

Risk: the steps write GCC votes, TLMM (pins 76-82, 204), RPMh (4 rails) and SE5. Ask the owner before the first boot.
Not run on the phone.

## 0331-negroni-bt-hci.patch

Made in `out/kernel/tree-bt2` (patched-tree.sh up to 0331, on the committed 0330) with `git add -N` + `git diff HEAD`.
compile-one.sh clean for `negroni_bt_hci.c` and `negroni_bt.c`.

Files:
- `bsd/dev/negroni_bt_hci.c`: the HCI stage (replaces the stub). H4 framing, polled on the 0330 UART helpers.
- `bsd/dev/negroni_bt.h`: `negroni_bt_hci_run()` returns `int` (0 or errno).
- `bsd/dev/negroni_bt.c`: an HCI error goes to the 0330 failure path (BT_EN low, GCC vote restored).

Sources (read for the sequence and the frame formats; our own code): Linux `drivers/bluetooth/btqca.c`,
`btqca.h`, `hci_qca.c` (out/src/linux, `scripts/bt/fetch-sources.sh`). The hp* firmware names are the "HSP" family,
which Linux drives as `QCA_WCN6855` (soc_type >= WCN3991: EDL answers come in Command Complete events, not VSE).

Boot-args: `negronibt=2` (steps 9-11), `negronibt=3` (steps 9-19), `negronibt_to` (ms per wait, 2000, max 30000),
`negronibt_baud` (3000000; 115200 = no change; only QCA baud codes), `negronibt_ibs=1` (set the NVM in-band sleep
bit, tag 17 byte 0 bit 7, and tag 27 bit 0, as Linux does; default: the file's bits stay, because the host has no
IBS state machine).

| Step | Command (H4 bytes) | Wait for | Source |
|---|---|---|---|
| 9 HCI_RESET (ROM) | `01 03 0c 00` | CC op 0x0c03 status 0; a timeout is logged, the version decides | Core spec |
| 10 version | `01 00 fc 01 19` | CC `00 19 xx` + product u32, patch u16, ROM u16, SoC u32 (15 bytes); VSE `00 02 ...` also accepted | btqca.c:16-88 |
| 11 baud | RFR not ready, `01 48 fc 01 0e`, 10 ms, host UART 3000000, RFR follows FIFO; 100 ms for any answer; version again | version CC at 3 Mbaud | hci_qca.c:1342-1394, 1487-1579 |
| 12 firmware pack | WLAN area header -> `negroni-bt.bin` -> pack header | - | - |
| 13 rampatch | `hpbtfwNN.tlv` in `01 00 fc LL 1e SS <243 bytes>` segments; download mode 1/3: only the last (or short) segment is acked | CC `00 1e` (or VSE `00 04 rr`) | btqca.c:553-636, 460-526 |
| 14 board id | `01 00 fc 01 23` | CC `00 23 xx hi lo` -> `hpnvNN[g].bXX`, else `.bin` | btqca.c:193-234, 715-747; `.bin` fallback = qca_get_alt_nvm_file :270-289 (called at :570) |
| 15 NVM | tag 17 byte 1 = baud code of the host rate (0x0e); every segment acked | CC `00 1e` | btqca.c:363-450 |
| 16 logging off | `01 17 fc 02 14 00` | CC (failure logged, goes on) | btqca.c:638-657 |
| 17 HCI_RESET | `01 03 0c 00` | CC status 0 (fatal) | btqca.c:974 |
| 18 build label | `01 00 fc 01 20` | CC `00 20 len label` (failure logged) | btqca.c:91-152 |
| 19 BD address | `01 09 10 00` (HCI_Read_BD_ADDR, not a vendor command) | CC status + 6 bytes; compared with NVM tag 2 | btqca.c:683-713 |

ROM number for the file names: `rom = ((soc_ver & 0xf00) >> 4) | (soc_ver & 0xf)`, `soc_ver = soc_id << 16 | rom_ver`
(btqca.c:762-776); GF variant (`g`) when `(soc_id & 0xff00) == 0x1200` (btqca.h:54, btqca.c:731).

Expected log (all lines start `NEGRONI BT:`), after the 0330 lines:

| Line | Meaning |
|---|---|
| `HCI stage (patch 0331): negronibt=3, wait 2000 ms, baud 3000000, IBS bits as in the file` | start |
| `cmd 0x0c03 plen 0: 01 03 0c 00` | each command (first 16 bytes) |
| `evt 0x0e plen 4 (Command Complete op 0x0c03 status 0): 0e 04 01 03 0c 00` | each HCI event (first 16 bytes) = **proof** |
| `9 HCI_RESET: Command Complete status 0 after N ms at 115200 baud` | the ROM answers |
| `10 QCA product 0x00000013, SoC 0x..., ROM 0x0201, patch 0x..., ... firmware ROM 21` | [I] expected values from hpbtfw21.tlv (product 0x13, ROM build 0x0201) |
| `11 controller and host at 3000000 baud (code 0xe)` + `11 QCA product ...` | the link works at 3 Mbaud |
| `12 negroni-bt.bin at area byte 0x160d000, 1011646 bytes, 105 files` | pack found |
| `hpbtfw21.tlv 130620 bytes loaded, sha-256 OK` | firmware read |
| `13 hpbtfw21.tlv: TLV length 130616, ..., download mode 3, product 0x0013, ROM build 0x0201, patch 0x4c61` | header |
| `13 538 segments of <= 243 bytes sent, 1 acks, N ms, at 3000000 baud` | rampatch done |
| (step 13 takes long) | normal: about 0.45 s at 3 Mbaud. Worst case: 538 segments x up to 100 ms CTS stall each (the 0330 write limit) = about 54 s, then `TX stalled ...` = the controller holds CTS, not a hang |
| `14 board id 0x... -> hpnv21.bXX` | NVM name |
| `15 NVM tag 17 (HCI transport) before: 15 11 22 00 2e 00` / `after: byte 0 0x15, baud byte 0xe` | stock NVM asks 3.2 Mbaud (0x11); we use 3 M |
| `15 27 segments ..., 27 acks` | NVM done |
| `18 firmware build label "..."` | patched firmware runs |
| `19 BD address 00:00:00:00:5a:ad (= the NVM default: ...)` | [I] expected: no unique address in the NVM |
| `HCI stage done: firmware ROM 21 loaded, 3000000 baud` / `HCI stage end: ok (error 0, ...)` | success |
| `stop: step N ...` + `HCI stage end: FAILED` + `BT_EN low again (failure)` | failure path |

Firmware area layout (`scripts/bt/mkbtarea.sh`, `scripts/bt/mkbtpack.py`): the BT files are one more file of the
WLAN area, so the area keeps its place and size (userdata blocks N-19457 .. N-11266, N = 58672399):

- WLAN area (32 MiB, `NEGRWLAN`, unchanged format, scripts/wifi/mkwlanarea.py): entry `negroni-bt.bin` (199 files now).
- `negroni-bt.bin`: bytes 0..16383 = `NEGRBTFW` | u32 1 | u32 count | count x {name[48], u32 offset, u32 size,
  sha256[32]} (max 160; offset from the pack start); files from 16384, 64-byte aligned. 105 hp* files, 1011646 bytes.
- Kernel reads: area header (32 KiB) -> pack header (16 KiB) at entry offset -> file at entry offset + pack offset,
  through `negroni_ufs_wlan_area_read`; SHA-256 checked; files up to 512 KiB.
- Build: `scripts/bt/mkbtarea.sh` (writes out/firmware/wlan/negroni-bt.bin and out/firmware/wlan-area.bin).
  Write (ask the owner): `AREAS=1 scripts/ios16/root-simg.sh` or `AREAS=wlan CONFIRM=yes scripts/fw/write-areas.sh`
  (= `dd if=out/firmware/wlan-area.bin of=userdata bs=4096 seek=$((N-19457)) conv=notrunc,fsync`). A userdata
  flash without the areas (iOS flashed back) erases it; run mkbtarea.sh again after scripts/wifi/extract-fw.sh.

Test image: `scripts/bt/build-test-image.sh` -> `out/ios16-bt` (config args + `negronibt=3 negronipanic=30
negronipanicreason=2`). With no BT pack on the phone, step 12 stops (BT_EN low); steps 9-11 still give the proof.

Review fixes (2026-10-26): `h4_next` checks the deadline on every pass (a gap-free byte stream, e.g. noise at
3 Mbaud, can no longer extend a wait); the step 13 worst case and the NVM fallback reference above.

Risks [I]: the host baud change writes the SE clock while the RX command runs (0330 helper; Linux reprograms in
set_termios); 3.2 Mbaud (the stock NVM value) has no clock level within 2 % at 16x, so 3 Mbaud is used and the NVM
byte is rewritten; deep sleep (tag 27 bit 0 is already 1 in the stock NVM) may make the controller send IBS bytes
(logged; WAKE_IND is answered with WAKE_ACK); a skip-mode rampatch goes out back to back and relies on RTS/CTS.
Not run on the phone.

## Stage B: the iOS transport (0332, 0333, userland/bluetooth)

Made in `out/kernel/tree-btb` (patched-tree.sh up to 0332, i.e. on the committed 0330/0331) with `git add -N` +
`git diff HEAD`; 0333 is the next diff in the same tree. Facts and addresses: docs/bluetooth-plan.md section 4.

### What iOS 16 bluetoothd needs [V, 20H392 `usr/sbin/bluetoothd`, same binary as bergamota's: 0x100156160 matches]

| Need | Where | Our answer |
|---|---|---|
| a registry entry named `bluetooth` (or `marconi-bt`) with non-zero `local-mac-address`; the `BT_DEVICE_ADDRESS` env value is parsed, then zeroed | main 0x1000268a8-0x1000268f8 (sscanf, then `str wzr`/`strh wzr`), 0x1000269b4 (registry read) | ADT node `/arm-io/bluetooth` (`ADT_BT=1`, config `[adt.bluetooth]`), published by NegroniPlatformExpert |
| `/dev/cu.bluetooth` or `/dev/uart.bluetooth` or that registry entry, else "No bluetooth on this device", exit 0 | 0x100026af4-0x100026b68 | both: dev nodes (0332) + ADT node |
| transport: env `BT_HCI_TRANSPORT`, else ADT `transport-encoding` (3 = H4BC) | 0x100156160 (strtok ":" at 0x1001561e8) | env `H4BC:POSIX:com.apple.uart.bluetooth,3000000` (launchd job) + ADT 3 |
| POSIX driver: `socket(32,1,2)`, `CTLIOCGINFO` 0xc0644e03, `connect`; default name `com.apple.uart.sk.bluetooth` (Skywalk) | 0x100066bdc, 0x100066ce4, 0x100066d3c, 0x100066e30, 0x100066ca8 | plain kernel control `com.apple.uart.bluetooth` (0332) |
| termios as socket options: `getsockopt(2, 0x40487413)`, `setsockopt(2, 0x80487414, 72 B)`, result not checked; c_cflag 0x38b00 | 0x100066e70, 0x1000671c8, 0x100066ea4 | `ctl_getopt`/`ctl_setopt` (0332) |
| speed: device string ",N", else env `BT_BAUDRATE`, else ADT `transport-speed`, else 2400000 | 0x100066c38-0x100066c9c | 3000000 everywhere |
| the bluetoothd job: the port's 20H392 launchd cache has none (only BlueTool, bluetoothuiservice, bluetoothuserd) | launchd.plist cache [V] | `BT=1` root / `phone-bt.sh on` add it from /System/Library/LaunchDaemons/com.apple.bluetoothd.plist |
| `/dev/btwake` (H4BC), failure only logged | 0x100066b24 | no-op node (0332) |
| BlueTool over XPC: `RunBuiltinScript` boot/init; reply `result` 0 = ok, 10/13 = no platform/chipset | send 0x100272190-0x100272290, reply 0x10027249c (0x100272580 result, 0x10027261c firmware, 0x100272630 manufacturer), power-on loop 0x1003a6128 | BlueTool stand-in `negroni-bluetool` (userland) |
| manufacturer check | initCmdReadLocalVersionCB 0x10010bc6c keeps HCI ver/rev, LMP ver/subver (0x10010bcd4-0x10010bd10), not the manufacturer | none needed; `negronibt_mfr=15` rewrites it if a later check appears |

BlueTool [V, 20H392 `usr/sbin/BlueTool`]: built-in scripts are Broadcom `.hcd` only; `/etc/bluetool/<model|ProductHash>.<boot|init|deepsleep>.script`
overrides are read only when MobileGestalt `ReleaseType` is `Vendor` or `Internal` (0x100016054-0x100016280). Our root has no
`/etc/bluetool` and no `/usr/share/firmware/bluetooth` (hfs-extract: not found). So no "stub .hcd" route: a stand-in binary.
Its replies copy the stock ones (0x100042238 `result`; 0x100042410-0x1000424dc `result`, `manufacturer`, `firmware`; 0x100042670 `result`, `output`).

### 0332-negroni-bt-h4-transport.patch

Files: `bsd/dev/negroni_bt_h4.c` (new), `bsd/dev/negroni_bt_shim.c` (new, pass-through; 0333 replaces it),
`negroni_bt.h` (h4 + shim API), `negroni_bt.c` (`negronibt=4`: attach after the start delay, start after the HCI stage,
fail on a stage A/HCI error or `negronibt_off=1`), `negroni_bt_hci.c` (step 20), `bsd/conf/files`.

- Kernel control `com.apple.uart.bluetooth`: `CTL_FLAG_REG_SOCK_STREAM | CTL_FLAG_REG_EXTENDED` (not privileged: bluetoothd runs as
  mobile), send 64 KiB / receive 128 KiB, `TIOCGETA`/`TIOCSETA(W/F)` options, `ctl_rcvd` flow control.
- `/dev/uart.bluetooth`, `/dev/cu.bluetooth` (one char device, 0666): read/write raw H4, select/poll/kqueue, `TIOCGETA`/`TIOCSETA`,
  `FIONREAD`, `TIOCFLUSH`; `/dev/btwake` open/close do nothing (the kernel owns BT_EN).
- One client at a time (control or device, `EBUSY` else); a new client empties the queues.
- RX thread: polls the 0330 UART (no SE interrupt wired) every 1 ms for 200 ms after traffic, 5 ms up to 5 s, then 20 ms
  (msleep, woken by each send); RFR follows the RX FIFO, so a slow host stops the controller instead of losing bytes.
  RX throughput is bounded by the GENI RX FIFO depth per poll period. A send is a bounded busy-wait in the 0330 helper
  (delay(2) polls of the TX FIFO; limit = wire time + 100 ms for CTS).
- 0332 also changes the 0330 `rx_drain` (negroni_bt.c): a RX FIFO word is read only when the 4096-byte ring has room for
  its 4 bytes; else it stays in the FIFO and RFR holds the controller. Before, a long send (it drains RX while the RX
  thread waits for the UART) could overflow the ring and drop bytes without a log line. `h4_close` now wakes a blocked
  reader and select waiters.
  H4 framing (04/02/03/05), QCA in-band sleep bytes handled and never delivered (0xfd WAKE_IND -> 0xfc WAKE_ACK; 0xfe
  SLEEP_IND -> the next send first sends 0xfd and waits 3 x 100 ms for 0xfc, hci_qca.c:44-49). Queue 64 KiB; the UART is
  not read while less than one maximal packet + one read is free.
- TX: H4 framing of the user stream, each packet through the shim, then the UART (h4_uart lock). Before the chip is ready a
  send waits up to `negronibt_wait_ms` (30000); after a failure `EIO`.
- Termios: stored and logged; the line stays at the stage A rate (3 Mbaud) with RTS/CTS.
- Step 20 (in `negroni_bt_hci.c`): `local-mac-address` of `/arm-io/bluetooth` -> QCA `EDL_WRITE_BD_ADDR` 0xfc14 (display order,
  btqca.c:1005-1024), then Read_BD_ADDR again; failure only logged.

### 0333-negroni-bt-hci-shim.patch

`bsd/dev/negroni_bt_shim.c`. Every host command with OGF 0x3f is answered in the kernel (never sent: the QCA vendor space has
other meanings, e.g. 0xfc48 = baud rate, 0xfc00 = EDL patch, 0xfc14 = BD address). Intercepted opcodes:

| Opcode | Answer | Broadcom name / source |
|---|---|---|
| 0xfc01 | status 0 | Write_BD_ADDR (btbcm.c:155) |
| 0xfc18 | status 0 | Update_UART_Baud_Rate (hci_bcm.c:214); line not changed |
| 0xfc1c | status 0 | Write_SCO_PCM_Int_Param (btbcm.c:201) |
| 0xfc1e | status 0 | Write_PCM_Data_Format_Param |
| 0xfc27 | status 0 | Write_Sleep_Mode_Param (hci_bcm.c:399) |
| 0xfc2e | status 0 | Download_Minidriver (btbcm.c:223) |
| 0xfc45 | status 0 | Write_UART_Clock_Setting (hci_bcm.c:195) |
| 0xfc4c | status 0 | Write_RAM (.hcd record) |
| 0xfc4e | status 0 | Launch_RAM (.hcd end) |
| 0xfc6d | status 0 | Write_I2SPCM_Interface_Param |
| 0xfc1d, 0xfc5a, 0xfc6e, 0xfc79 | status 0x01 | Read_SCO_PCM_Int_Param, Read_USB_Product, Read_Controller_Features, Read_Verbose_Config_Version_Info (btbcm.c:173-379) |
| any other 0xfcXX (bluetoothd's 220 BD_VSC_* names, table 0x100804a20) | status 0x01 Unknown HCI Command | parsers run only on status 0 ("Unsupported command %!, ignoring error") |

Answer = `04 0e 04 01 <op lo> <op hi> <status>`. Controller events 0xff (QCA vendor/log) are not delivered. Read_Local_Version
Command Complete: logged once per client; manufacturer rewritten only with `negronibt_mfr=N`.

### Build (2026-10-26)

Kernel out/kernel/local-20261026-174538/kernel.development.negroni sha256 cfd8af00a5145843b011737cdf8a08a157d14f3ced415dd4a0aa944763bc904d (review fixes F1-F4 in; the first build local-20261026-132747 was a94e8f3c...)
(patch-report: 0330-0333 applied, only iobuffermemd_monterey, skywalk_sonoma, syntax_checker_sonoma, TrustCache skipped);
compile-one clean for negroni_bt_h4.c, negroni_bt_shim.c, negroni_bt_hci.c, negroni_bt.c. Userland (userland/bluetooth/build.sh):
negroni-bluetool c396870ead8a8d8b84ca4eaf8ba304a165b16126230794258d05951c97848d6a, hcitest
27ac94929885574b83bf5a0dfd003fccf70c6d191a504c1cd549ce9349cfff7f. No boot image (owner rule 2026-10-26: the main session builds
one combined image; scripts/bt/build-test-image.sh is the old 0331 recipe).

### Boot-args for stage B (add to the combined image)

`negronibt=4 negronipanic=30 negronipanicreason=2` (+ optional `negronibt_h4log=N` (300), `negronibt_wait_ms=MS` (30000),
`negronibt_shim=0|1|2` (1), `negronibt_mfr=N` (0)). The image also needs the ADT node: build the ADT with `ADT_BT=1`
(scripts/ios16/adt-extra.py), the WLAN area with the BT pack on the phone (0331), and a `BT=1` root or `scripts/bt/phone-bt.sh on`.

### Expected log (after the 0330/0331 lines)

| Line | Meaning |
|---|---|
| `h4 kernel control com.apple.uart.bluetooth: registered (error 0)` + `h4 /dev/uart.bluetooth ok, ...` | attach (before step 1) |
| `step 20 ...`, `20 BD address 02:00:5e:77:ee:11 ...`, `20 ADT address ... is the controller address now` | address set |
| `shim policy 1 ...`, `shim table 0xfc01 -> status 0x0: ...` | shim table |
| `h4 transport ready at 3000000 baud ...`, `h4 RX thread running ...` | chip handed over |
| `h4 control com.apple.uart.bluetooth connected (unit N) by bluetoothd[PID]; chip ready` | **bluetoothd opened the transport** |
| `h4 setsockopt: termios speed 3000000, c_cflag 0x38b00 (RTS/CTS flow control) ...` | bluetoothd's termios |
| `h4 tx cmd 0x0c03 plen 0: 01 03 0c 00` / `h4 rx evt 0x0e plen 4 (Command Complete op 0x0c03 status 0x0): ...` | **HCI traffic** |
| `shim Read_Local_Version: HCI .. manufacturer 0x001d (Qualcomm)` | stack init |
| `shim intercepted 0xfcXX ... -> local Command Complete status 0x1: ...` | Broadcom/Apple VSC answered |
| `h4 stats: ...` (every 60 s with traffic, and at disconnect) | counters |
| `h4 control connect from X refused: busy` | a second client (hcitest while bluetoothd runs) |

Userland lines (unified log, `scripts/bt/phone-bt.sh log`): bluetoothd "HCI Transport is set to H4BC", "Booting chipset",
"BlueTool finished running boot script"; negroni-bluetool "RunBuiltinScript "boot" -> result 0".

Risks [I]: bluetoothd's sandbox profile (the port's stand-in) may refuse the PF_SYSTEM socket; bluetoothd may need a chipset id
(set through virtual setters 0x10025a8e8/0x100285134, source not traced); the BTServer sandbox profile (or the port's
stand-in) may deny the PF_SYSTEM socket and refuse to power on; some status-0x01 VSC may be
fatal for bluetoothd (then add it to the table with status 0 and its return layout); polling at 1 ms costs CPU while traffic
flows (about 0.1 % per poll); IBS never seen on the bench (NVM IBS bit clear). Not run on the phone.

## 0334-negroni-bt-qup-clocks.patch (2026-10-27)

Made in `out/kernel/tree-bt3` (patched-tree.sh, full set) with `git diff HEAD`; applies on the 0333 state too
(`git apply --check`, rpmh hunk offset -11).

**Root cause of the stop at step 4** [V logs/usblog-everything-0363.txt 02:02:43]: `s_ahb OFF ... CBCR ... 0x80000002`.
0x80000002 = CLK_OFF (bit 31) + HW_CTL (bit 1). `gcc_qupv3_wrap_2_s_ahb_clk` and `_m_ahb_clk` have `hwcg_bit = 1`,
`halt_check = BRANCH_HALT_VOTED` [V out/src/linux drivers/clk/qcom/gcc-sm8450.c:2603-2631]. Linux does not check the
halt bit of a branch in hardware gating mode (`clk_branch_wait`, clk-branch.c:72): CLK_OFF reads 1 while the AHB is
idle. 0330 waited for CLK_OFF = 0 and stopped. The vote bits were written (wrap2 core, core_2x, m_ahb, s5 read on).
The same pattern stops 0350 (fingerprint) in the same boot: `clock wrap_1_s_ahb does not come on (CBCR 0x80000002)`.

Changes:
- `negroni_bt.c` step 4: `cbcr_state()` = on / hw-gated / OFF; only OFF of core, m_ahb, s_ahb stops.
- Step 4 first votes the RPMh BCM `QUP2` (Linux `geni_icc_enable` path `qup-core` = `qup2_core_master ->
  qup2_core_slave`, `bcm_qup2` keepalive, vote_scale 1, slave buswidth 4 [V sm8450.c:322, :761, :1373]) with
  avg = peak = 5000 kBps (`CORE_2X_100_MHZ`, op-kernel include/linux/qcom-geni-se.h:272). [I] The exact downstream
  UART value (`UART_CORE2X_VOTE`) is in a header we do not have; 5000 is the 100 MHz core_2x level. A failure is
  only logged (the core clocks already ran on the boot chain's vote). Never voted off.
- `negroni_rpmh.c`: `negroni_rpmh_qup_bcm(res, avg, peak, &data)`, QUP0/1/2 only, bcm-voter.c arithmetic
  (`bcm_div` round-up, vote_scale 1, 14-bit clamp, keepalive never 0), unit/width from the cmd-db aux data.
- Boot-args: `negronibt_bcm=0` skips the vote; `negronibt_bcm_kbps=N` (1..100000).
- `qup-config` (CNOC, BCM CN0) and `qup-memory` (DDR, only for SE DMA) are not voted: we use FIFO mode, and the
  config path served the 0330 register reads before.

SE firmware [V]: the OnePlus kernel (out/src/op-kernel) never loads GENI SE firmware; upstream Linux loads it only
when `GENI_FW_REVISION_RO` protocol is 0xff (invalid) and the wrapper has `firmware-name`
(qcom_geni_serial.c:1358-1368, qcom-geni-se.c:1564-1612); the SM8450 DT has no `firmware-name`. So the boot chain
(XBL, `qupfw` partition) loads it. [I strong] Step 5 shows protocol 2. If it shows 0xff, the next work is a
`geni_load_se_firmware` port (qupv3fw.elf from `qupfw_a`).

### Proof lines in order (negronibt=4) and what to read when a step fails

Kernel (`grep -a 'NEGRONI BT\|NEGRONI RPMH: BCM QUP' logs/usblog-*.txt`):

| # | Expected line | If it fails |
|---|---|---|
| 0 | `h4 kernel control com.apple.uart.bluetooth: registered (error 0)`, `h4 /dev/uart.bluetooth ok ...` | - |
| 3 | `3 smpb11 966 mV: errno 0` (4 rails) | RPMh busy/poisoned: earlier `NEGRONI RPMH` lines |
| 4a | `NEGRONI RPMH: BCM QUP2 addr=0x5.... unit=U width=W`, `... -> x X y Y, data ...`, `4 BCM QUP2 ... errno 0` | errno != 0 is not fatal; `no BCM QUP2 in cmd-db` = name differs |
| 4b | `4 branches: wrap2 core on, core_2x on, m_ahb on, s_ahb hw-gated (HW_CTL, not checked, as Linux), s5 on (... vote now 0x20f)` | `stop: ... a branch without HW_CTL reads CLK_OFF`: read the CBCR values |
| 5 | `5 QUP2 HW version 0x3....... (oversampling 16); SE5 FW revision 0x2.. (protocol 2, ...)`, `5 HW_PARAM_0 ...` | protocol 255: no firmware (loader needed); a hang or SError panic here: the AHB path or an XPU (negronipanic=30 shows the panic) |
| 6 | `6 pins 76-79 -> qup20: ...`, `baud 115200: table entry 0 = 7372800 Hz / 4 / 16`, `6 UART 115200 8N1, flow control RTS/CTS, RX started` | `no SE clock`: S5 RCG update; read the step 4 RCG line |
| 7 | `7 BT_EN out 1 ..., SW_CTRL 1 (asserted: the chip's BT side is up)` | SW_CTRL 0: power/XO; the HCI stage still runs |
| 8 | `8 N bytes from the controller after power-on` (often 0) | - |
| 9 | `HCI stage (patch 0331): negronibt=4, ...`, `evt 0x0e plen 4 (Command Complete op 0x0c03 status 0)`, `9 HCI_RESET: Command Complete status 0 ...` | no answer: `negronibt_noflow=1`, then `negronibt_rfropen=1`; check `GENI_IOS` (CTS) in the TX lines |
| 10 | `10 QCA product 0x00000013, SoC ..., ROM 0x0201, ... firmware ROM 21` | the version decides the file names |
| 11 | `11 controller and host at 3000000 baud (code 0xe)` + a second `10/11 QCA product` | `negronibt_baud=115200` isolates the baud change |
| 12 | `12 negroni-bt.bin at area byte ..., 1011646 bytes, 105 files` | the phone's WLAN area has 199 files [V same boot], so the pack is there |
| 13-15 | `13 ... segments ... acks`, `14 board id ... -> hpnv21...`, `15 ... acks` | TX stalled = CTS held by the controller |
| 17-20 | `18 firmware build label "..."`, `19 BD address ...`, `20 ADT address ... is the controller address now` | 18/20 failures are only logged |
| end | `HCI stage end: ok`, `stage A done`, `h4 transport ready at 3000000 baud ...`, `h4 RX thread running` | `HCI stage end: FAILED` + the `stop: step N` line |
| B | `h4 control com.apple.uart.bluetooth connected (unit 1) by bluetoothd[PID]; chip ready` | `chip FAILED` = one of the lines above failed |
| B | `h4 tx cmd 0x0c03 ...`, `h4 rx evt 0x0e ... status 0x0`, `shim Read_Local_Version: ... manufacturer 0x001d`, `shim intercepted 0xfcXX ...` | a bluetoothd crash: the last `h4 tx cmd` opcode; add it to the 0333 shim table |

Userland (`scripts/bt/phone-bt.sh log`). [V logs/phone-log-20261027-004129.txt, a boot without the kernel control]:
everything up to the transport already works: `Got local-mac-address`, keychain reads `_BTKCGetDataCopy found
keychain item ... result 0` and a write `_BTKCSetData ... updating` (securityd answers bluetoothd: bergamota's
"LeSecurityManager hit a keychain problem" did not happen here), `Booting chipset`, negroni-bluetool
`RunBuiltinScript "boot" -> result 0`, `BlueTool finished running boot script`, `Powering on chipset`, `init` script
result 0, `Starting bluetooth core stack`, `Searching for transport: "H4BC"` / `driver: "POSIX"`. That boot then
failed at `ioctl(CTLIOCGINFO, com.apple.uart.bluetooth) failed` -> `Bluetooth fatal error - crashing { reason=1201 }`
(1201 = transport init failed). With 0332 the control exists; with 0334 the chip should answer.
Next expected [I]: no CTLIOCGINFO error, HCI init traffic in the kernel log, then the stack state goes on and
Settings > Bluetooth shows the switch on. Pairing (headset/keyboard): watch `LeSecurityManager`, `SecItemAdd`,
`_BTKCSetData` lines (link keys go to the keychain).

## 0335-negroni-bt-power-follows-client.patch (2026-10-27)

Owner bug: "if I turn on Bluetooth I can't turn it off". Made in `out/kernel/tree-bt5` (full set incl. 0334).

Facts [V logs/usblog-20261026-233816.txt, kernel without 0334]:
- The transport logged "not usable (sends fail with EIO)". bluetoothd connected with "chip FAILED".
- After that, bluetoothd logged nothing more in the kernel log and did not crash. [I] Its power-on never ended (stack STACK_BUSY), so the toggle could not go off.
- The repeats at 02:02:43, 02:04:39 and 02:06:35 are whole phone reboots, not bluetoothd restarts. The evidence: "phone interface gone" lines at 02:03:33, 02:05:29 and 02:06:40, the launchd boot-args line again, and bluetoothd with pid 85 each time.

Changes:
- Dead chip (stage A or the HCI stage failed): each host command gets a local `04 0e 04 01 <op> 03` (Command Complete, status 0x03 Hardware Failure). The send no longer fails with EIO. Other packets are dropped. Boot-arg `negronibt_dead=0|1|2`: 0 = EIO (old behavior), 1 = default, 2 = refuse the client.
- Working chip: power follows the client. When the last client closes, a timer starts (`negronibt_off_ms`, default 3000). Then the power worker drives BT_EN low. The rails and the QUP2 clocks stay on.
- The next connect powers the chip on again. The steps are: line to 115200, the step 7 sequence, step 8, and the whole HCI stage with firmware. Sends wait during this time (`negronibt_wait_ms`). A failed power-on switches to the dead-chip answers.
- `negronibt_pwrfollow=0` keeps the chip on.
- The RX thread does not read the UART while the chip is off or powering on.

bluetoothd power state [V strings of 20H392 bluetoothd, phone-log-20261027-004129.txt]:
- The persisted switch is `defaultPoweredState` ("Default power state : %d", "Write default power state : %d").
- bluetoothd opens SCPreferences `com.apple.MobileBluetooth.SystemSettings` on `/Library/Preferences/SystemConfiguration/com.apple.radios.plist`. In that boot the file was empty (size=0), so the default was 1 (on).
- [I] `defaultPoweredState` is stored in that file.
- The power-off path: "Beginning asynchronous power shutdown", the stack terminates, then "Powering off chipset". [I] BlueTool then gets the `deepsleep` script. The script names in the binary are boot, init and deepsleep. negroni-bluetool answers result 0 and logs the name.
- [I] Whether bluetoothd closes the transport at power off is not known. The kernel line `control unit N disconnected` shows it. If bluetoothd does not close it, the chip stays on while the switch is off (the switch still works). The next step is then a kernel hook from negroni-bluetool's `deepsleep`.

Expected lines for an on/off/on test (negronibt=4, kernel with 0334 + 0335):

| Action | Kernel (`NEGRONI BT:`) | Unified log |
|---|---|---|
| boot | `h4 transport ready at 3000000 baud`, `h4 power worker running (off 3000 ms ...)`, `h4 control ... connected (unit N) by bluetoothd[P]; chip ready` (or `chip off: powering on` + `power on #1` if bluetoothd came more than 3 s later) | `Default power state : 1`, `Starting bluetooth core stack`, no `CTLIOCGINFO` error |
| switch off | [I] `h4 control unit N disconnected; power off follows ...`, then `power off: BT_EN low`, `h4 power off #1` | `Beginning asynchronous power shutdown`, `Powering off chipset`, negroni-bluetool `RunBuiltinScript "deepsleep"`, `Write default power state : 0` |
| switch on | `h4 control ... connected ...; chip off: powering on`, `h4 power on #1: a client is back`, `power on: line to 115200 ...`, the HCI stage lines 9-20, `power on: chip ready after N ms`, `h4 power on #1: transport ready again` | `Booting chipset`, `Powering on chipset`, `Starting bluetooth core stack` |
| dead chip | `h4 transport not usable: ... (commands get a local status 0x03 answer)`, `h4 dead chip: cmd 0x0c03 answered locally with status 0x03` | [I] a stack init error (`Stack_Init failed`) and the switch back to off, not a hang |
