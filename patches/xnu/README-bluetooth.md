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
