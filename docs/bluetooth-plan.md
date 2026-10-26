# Bluetooth (QCA6490) plan

Goal (owner): Bluetooth from the original OnePlus firmware and kernel, as patches and add-ons.
Patch range: `patches/xnu/0330-0349`. Wi-Fi (PCIe/MHI side of the same chip) is a separate track
(`docs/wifi-plan.md`, 0260-0269).

Tags: **[V]** = checked in the named file; **[I]** = inference, not tested on the phone.

## 1. Hardware facts

| Item | Value | Source |
|---|---|---|
| Chip | QCA6490 combo; BT node `bt_qca6490`, compatible `qcom,qca6490` | [V] out/live.dts:13506 |
| UART | `qcom,qup_uart@894000`, `qcom,msm-geni-serial-hs`, reg 0x894000/0x4000, alias `hsuart0`, `qupv3_se20_4uart` = QUP wrapper 2 SE5 | [V] live.dts:15293, :443, :38696 |
| QUP wrapper | `qcom,qupv3_2_geni_se@8c0000` (reg 0x8c0000/0x2000), interconnect `qup-core` etc. | [V] live.dts:14959 |
| UART clocks | GCC 130 `GCC_QUPV3_WRAP2_S5_CLK`, 138 `..WRAP_2_M_AHB`, 139 `..WRAP_2_S_AHB` | [V] live.dts:15299, out/src/op-kernel include/dt-bindings/clock/qcom,gcc-waipio.h:142,150,151 |
| GCC registers | vote 0x62010 (bit 0 core, 1 s_ahb, 2 m_ahb, 3 core_2x, 9 s5); S5 RCG 0x2e618 (DFS-capable); CBCRs 0x2e004/0x2e008/0x2e610/0x33280/0x3328c | [V] out/src/linux drivers/clk/qcom/gcc-sm8450.c:978, :2391-2420, :2507-2520 |
| SE clock table | 7.3728/14.7456/19.2/29.4912/32/48/64/75/80/96/100 MHz (no 51.2/102.4: 3.2 Mbaud has no exact level at 16x) | [V] op-kernel drivers/clk/qcom/gcc-waipio.c:776-789 |
| UART pins | CTS 76, RTS 77, TX 78, RX 79, function `qup20` (= 1); active: CTS no pull, RTS pull-down, TX pull-up, RX no pull, 2 mA | [V] live.dts:3187-3310, linux pinctrl-sm8450.c:1489-1492 |
| Wake byte | `qcom,wakeup-byte = 0xfd` (in-band sleep WAKE_IND) | [V] live.dts:15305 |
| GPIOs | BT_EN 81 (`qcom,bt-reset-gpio`), WLAN_EN 80, SW_CTRL 82, XO_CLK 204 (eGPIO) | [V] live.dts:13510-13513 |
| BT_EN default | `bt_en_sleep`: gpio, 2 mA, output-low, pull-down | [V] live.dts:1540 |
| Rails | aon/dig `pm8350_s11` (smpb11) 966 mV; rfa1 `pm8350c_s1` (smpc1) 1900 mV; rfa2 `pm8350_s12` (smpb12) 1350 mV; asd `pmr735a_l7` (ldoe7) 2800 mV; iPA `s3e` via AOP QMP (`qcom,vreg_ipa`) | [V] live.dts:13516-13525 + regulator nodes (phandles 0xae/0xaf/0xb0/0xb1) |
| Power sequence | BT_EN low, 50 ms; if WLAN_EN low wait 100 ms (500 ms below TEMP_THRESHOLD 5000 = 5 C); XO_CLK high 100-200 us, BT_EN high, XO_CLK low after 4-6 ms; 50 ms; read SW_CTRL | [V] op-kernel drivers/bluetooth/btpower.c:538-700 |
| QUP firmware | SE protocol firmware is loaded by the boot chain (partition `qupfw_a` exists in the dump); the kernel checks `GENI_FW_REVISION_RO` (protocol 2 = UART) | [V] ~/op10-backup/partitions/qupfw_a.img.gz; [I] that SE5 has UART firmware |

## 2. Firmware

- Source: the stock `bluetooth` partition (FAT16, Android mounts it at `/vendor/bt_firmware`; files in `image/`)
  [V `scripts/bt/fetch-firmware.sh`, from `~/op10-backup/partitions/bluetooth_a.img.gz`].
- 105 files: `hpbtfw20.tlv` (201560 B), `hpbtfw21.tlv` (130620 B), `hpbtfw20.ver`, and NVM files
  `hpnv20*.b*`, `hpnv21*.b*`, `hpnv21g*` (GF variant), `.bin` = default [V out/bt/firmware/LISTING.txt].
- sha256 [V]: hpbtfw21.tlv 5692eaf4...e1594, hpnv21.bin cec9f60b...6d6d7 (full list: out/bt/firmware/SHA256SUMS).
- `hpbtfw21.tlv`: TLV type 1 (patch), download mode 3, product 0x0013, ROM build 0x0201 [V header bytes].
  `hpnv21.bin`: TLV type 2, 66 tags; tag 17 (HCI transport) = `15 11 22 00 2e 00`, tag 2 (BD address) placeholder [V].
- File naming and download are in Linux `drivers/bluetooth/btqca.c` (`qca_uart_setup` :749,
  `qca_get_nvm_name_by_board` :715, `qca_tlv_check_data` :291) and `hci_qca.c` (`qca_setup` :1911).
- License: Qualcomm proprietary, no redistribution right. Keep it out of git (out/ is ignored [V `git check-ignore`]).

## 3. Staged plan

| Stage | What | Status |
|---|---|---|
| A1 (0330) | `negronibt=1`: map, pin census, 4 rail votes, GCC clocks, GENI firmware/FIFO check, UART 115200 FIFO mode, BT_EN power sequence, RX idle bytes | code + build done, not run on the phone |
| A2 (0331) | `negronibt=2`: H4, HCI_RESET, EDL version, 3 Mbaud. `negronibt=3`: + rampatch/NVM download from the BT pack in the WLAN area, reset, build label, BD address | code + build done (patches/xnu/README-bluetooth.md), not run on the phone |
| B1 (0332) | `negronibt=4`: step 20 (ADT BD address -> 0xfc14), kernel control `com.apple.uart.bluetooth`, `/dev/uart.bluetooth`, `/dev/cu.bluetooth`, `/dev/btwake`, RX thread with IBS | code + full kernel build (README-bluetooth.md stage B), not run on the phone |
| B2 (0333) | HCI shim: every host OGF 0x3f command answered in the kernel (Broadcom write commands status 0, others 0x01), QCA vendor events dropped | code + build, not run |
| B3 (userland) | `negroni-bluetool` (BlueTool stand-in), `hcitest`; `BT=1` root (scripts/bt/root-add-bt.sh) or `scripts/bt/phone-bt.sh on`; ADT node with `ADT_BT=1` | built (out/bt/userland), not run |
| A1 fix (0334) | step 4: hardware-gated AHB branches (CBCR HW_CTL) count as running, as Linux clk_branch_wait; RPMh BCM QUP2 vote (qup-core). Root cause of the everything-boot stop (s_ahb CBCR 0x80000002) | code + build 2026-10-27, not run |

Firmware for stage A2 [V scripts]: one file `negroni-bt.bin` (pack: `NEGRBTFW` header + 105 hp* files) inside the
WLAN firmware area (userdata blocks N-19457 .. N-11266, same format, 199 files); `scripts/bt/mkbtarea.sh` builds it.
No new userdata area. Layout: patches/xnu/README-bluetooth.md section 0331.

## 4. iOS side (20H392)

- [V strings, out/bt/ios/usr/sbin/bluetoothd]: `/dev/cu.bluetooth`, `/dev/uart.bluetooth`, `com.apple.uart.sk.bluetooth`,
  `transport-encoding`, `transport-speed`, `BT_HCI_TRANSPORT`, "Couldn't find a platform / chipset / firmware combination",
  `legacyBCMChipsets`, `modernBCMChipsets`. BlueTool holds Broadcom `.hcd` boot scripts only (BCM4350/4345/4357 rows).
- Prior art [V external/bergamota/docs/BT_IOS_TRANSPORT.md, design reference only: no license file]: on A11 bluetoothd uses
  H4 over a kernel control socket (`com.apple.uart.bluetooth` / `.sk.`), reads `local-mac-address`, `transport-encoding`,
  `transport-speed` from a registry entry named `bluetooth`, and asks BlueTool over XPC to boot the chip. Bergamota
  (WCN3990 on SDM845) did the chip boot in the kernel, a BlueTool stub, and `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000`.
  Their lessons: never vote shared rails off (panic); the controller uses in-band sleep after the firmware; the NVM baud byte
  position differs per chip.
- [I] Realistic path: kernel boots the chip (stage A), then stage B = an ADT `bluetooth` node + a kernel control socket +
  a BlueTool stub. Risk: bluetoothd's Apple/Broadcom vendor commands on a Qualcomm controller (manufacturer 0x001d).
  Nobody has shown stock bluetoothd working on a Qualcomm chip.

### 4.1 Stage B design (2026-10-26, verified in the 20H392 binaries; addresses in README-bluetooth.md stage B)

- [V] bluetoothd = H4 over a kernel control (POSIX driver 0x100066bdc). The plain name `com.apple.uart.bluetooth` is chosen with
  the job env `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000`; the default `.sk.` name needs Skywalk.
- [V] It starts only with a registry entry `bluetooth` that has a non-zero `local-mac-address` (env address discarded at
  0x1000268f4) -> ADT node `/arm-io/bluetooth` (`ADT_BT=1`, values in config `[adt.bluetooth]`).
- [V] Chip boot is BlueTool's job (XPC `RunBuiltinScript`); BlueTool knows Broadcom only and its override scripts need
  ReleaseType Vendor/Internal -> `negroni-bluetool` answers `result 0` (the kernel booted the chip).
- [V] Stack init keeps no manufacturer (0x10010bcd4-0x10010bd10): no Broadcom-manufacturer check found on that path.
  [I] The chipset id (virtual setters 0x10025a8e8 / 0x100285134) has an unknown source; it may matter later (LE features).
- [V] OGF 0x3f overlaps: Broadcom/Apple VSC numbers mean other things on the QCA (0xfc48 baud) -> the 0333 shim answers all
  of them in the kernel. [I] A status 0x01 for some VSC may still stop bluetoothd: the log names each opcode.
- Kernel boot-args: `negronibt=4 negronipanic=30 negronipanicreason=2` (README-bluetooth.md "Boot-args for stage B").

## 5. Next steps

0. (2026-10-27) [V] The everything boot (logs/usblog-everything-0363.txt) stopped at step 4 because s_ahb is a
   hardware-gated branch (CBCR 0x80000002); 0334 fixes the check. [V] The WLAN area on the phone holds the BT pack
   (199 files); the ADT `bluetooth` node, the bluetoothd job, negroni-bluetool and the keychain work
   (logs/phone-log-20261027-004129.txt). Next boot: a kernel with 0334, `negronibt=4`; the proof table is in
   patches/xnu/README-bluetooth.md "0334".

1. Owner approval, then write `out/firmware/wlan-area.bin` (with the BT pack) and boot `out/ios16-bt` (`negronibt=3`).
   Expect `step 5` protocol 2, `step 7 ... SW_CTRL 1`, `9 HCI_RESET: Command Complete status 0`, `10 QCA product ...`,
   `13 ... 1 acks`, `15 ... 27 acks`, `19 BD address ...`.
2. If step 9/10 time out: check `8 N bytes` and the RX buffer dump in the "no answer" line; try `negronibt_noflow=1`,
   `negronibt_rfropen=1`; `negronibt_baud=115200` isolates the baud change.
3. Stage B (owner approval, combined image with `negronibt=4`, `ADT_BT=1`, a `BT=1` root or `scripts/bt/phone-bt.sh on`):
   first `scripts/bt/phone-bt.sh test` (hcitest: HCI_Reset CC status 0, Read_Local_Version, Read_BD_ADDR = 02:00:5e:77:ee:11
   reversed, 0xfc79 answered by the shim), then bluetoothd (`h4 control ... connected by bluetoothd`, `phone-bt.sh log`),
   then Settings > Bluetooth (toggle, scan). Audio (BTAudioHALPlugin back: BTAUDIO=1) later.
