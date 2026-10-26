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
