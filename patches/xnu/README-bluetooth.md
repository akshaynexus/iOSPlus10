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
