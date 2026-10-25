# QCA6490 Wi-Fi plan for iOS 16.7.16

Goal: a native kernel Wi-Fi driver for the NE2211 that iOS uses as `en0` (wifid, configd, the
Settings page). USB networking stays the debug path. Marks: **[V]** seen (source given),
**[I]** inference.

Status (2026-10-25): no Wi-Fi on the phone yet. The kernel has a step-by-step PCIe0 survey
(steps 1-9, slop) and our read-only step 10 (patch 0260). **Stage 1 (patch 0261) is written and
builds**: an ath11k-style MHI host that claims BAR0, picks and downloads the firmware over BHI +
BHIe, reaches mission mode (M0) and starts the IPCR channels 20/21. It runs with `negroniwlan=2`
on its own kernel thread, so a failure never blocks boot; no MSI (poll). Stages 5-10 of the survey
and all of stage 1 have never run on a phone. There is no QMI, WMI or HTT code yet (stage 2).
Firmware files are extracted (`scripts/wifi/extract-fw.sh`) and packed into a 32 MiB area
(`scripts/wifi/mkwlanarea.py`); the area is not written to the phone yet.

Stage 1 state [V = builds, I = untested on hardware]:
- [V] Five files compile and link in the local build (patch 0261 applied, no 02xx skipped).
  Files: `negroni_wlan.{c,h}`, `negroni_wlan_mhi.{c,h}`, `negroni_wlan_bhi.c`; plus the survey
  hand-over in `negroni_wifi.c` and the area read in `negroni_ufs.c`. Log lines and the area
  recipe: `patches/xnu/README-wifi.md` (0261 section).
- [V] Order matches Linux: the MMIO context setup runs after the BHI SBL download, not in PBL
  (op-kernel `mhi_ready_state_transition`, `pm.c:243` / `boot.c:546`).
- [I] The firmware choice (amss20.bin when SoC major 2, else amss.bin), the BHI 512 KiB SBL, the
  BHIe segment vector, the READY -> M0 handshake and the START_CHAN commands follow the ath11k /
  cnss2 / Linux-MHI references but have not run on the chip.
- [V] Review 2026-10-25 ([reviews/wifi-0261-2026-10-25.md](reviews/wifi-0261-2026-10-25.md)): the M0
  order now follows Linux (BHI SBL -> READY -> MMIO -> event rings -> M0 + wake -> EE SBL -> BHIe ->
  EE AMSS -> channels). Also fixed: an `ml_io_unmap` panic on every failure path, BAR0 not aligned to
  its size (now 0x60400000 for 2 MiB), unchecked chip offsets, DMA memory freed with bus master on,
  doorbell word order, SHA-256 mismatch not fatal. Builds: `out/kernel/local-20261025-121738`.

## Hardware facts

| Fact | Source |
|---|---|
| Chip: `qcom,cnss-qca6490` on PCIe0 (`qcom,wlan-rc-num = 0`), PCI ID 17cb:1103 expected | `out/live.dts:13840-13878`, `negroni_wifi.c` CHIP_ID [V] |
| Linux drives 17cb:1103 as `WCN6855_DEVICE_ID`; it picks hw2.0 / hw2.1 (or QCA2066 / QCA6698AQ) from TCSR_SOC_HW_VERSION and TCSR_SOC_HW_SUB_VER, read through BAR0. So "hw2.1" is not known for our chip until BAR0 is mapped | Linux `ath11k/pci.c` `ath11k_pci_probe` [V]; our chip version [I, unknown] |
| Supplies (DT, µV): aon pmr735a_s2 1012000, dig pm8350_s11 966000, io pm8350_s10 1800000, rfa1 pm8350c_s1 1900000-2100000, rfa2 pm8350_s12 1350000, **antenna switch pmr735a_l7 2800000** | `out/live.dts:13860-13871` + phandles 0xc4/0xae/0xc5/0xaf/0xb0/0xb1 [V] |
| Step 6 votes only the first five supplies; it does not vote `wlan-ant-switch` (L7 of PMR735A). Needed for RF, probably not for the PCIe link | `negroni_wifi.c` step_chip_on [V]; effect [I] |
| GPIOs: WLAN_EN 80, BT_EN 81, SW_CTRL 82, XO_CLK 204; PCIe0 PERST 94, WAKE 96 | `out/live.dts:13844-13858,20794-20795` [V] |
| PCIe0: `qcom,pci-msm`, PARF 0x1c00000, PHY 0x1c06000, DBI 0x60000000, config 0x60100000, memory window 0x60300000 + 0x3d00000; `qcom,boot-option = 1` (Android enumerates only when cnss asks) | `out/live.dts:20778-20819` [V] |
| MSI goes through the **GICv3 ITS** at 0x17140000: `msi-map` RID 0x100 (bus 1) -> ITS DeviceID 0x5981. The SPI-based `qcom,pcie0_msi@0x17110040` node is `status = "disabled"` | `out/live.dts:1327-1332,20793,20866-20873` [V] |
| Our XNU tree has GICv3 code but no ITS / LPI code (`git grep GITS_` finds nothing) | `out/kernel/xnu` [V] |
| Legacy INTx: INTA..INTD = GIC SPI 0x95..0x98, global int SPI 0x8c. ath11k asks only for MSI (`PCI_IRQ_MSI`, 32 vectors or 1); it has no INTx path | `out/live.dts:20788-20792` [V]; `ath11k/pci.c:438-460` `ath11k_pci_alloc_msi` [V] |
| DMA: PCIe0 is behind the apps SMMU: `iommu-map` RID 0x100 -> SID 0x1c01; the cnss IOVA pool is 0xa0000000 + 0x10000000; 32 MiB CMA `cnss_wlan_region` | `out/live.dts:20818,20846-20862,326-332` [V] |
| `qcom,wlan-cbc-enabled`: Android runs cold-boot calibration before mission mode | `out/live.dts:13853` [V] |

## Firmware (stock modem image)

`scripts/wifi/extract-fw.sh` copies the files from `image/` of the NON-HLOS (modem) FAT image.
The modem partition holds all WLAN firmware on this phone; there is no `wpss` file (that is the
WCN6750 design) [V: `out/firmware/wlan/LISTING.txt`].

| File | Use | Source |
|---|---|---|
| `amss.bin` (5609392 B), `amss20.bin` (5287936 B) | WLAN firmware, both `WLAN.HSP.2.0-01229`. Qualcomm cnss2 loads `amss20.bin` when the MHI device major version is 2, else `amss.bin` | strings [V]; cnss2 `pci.c` `cnss_pci_update_fw_name` (Xiaomi marble kernel) [V] |
| `m3.bin` (266684 B) | M3 firmware; the host gives it to the chip over QMI (`m3_info`) | ath11k `qmi.c` `ath11k_qmi_wlanfw_m3_info_send` [V] |
| `regdb.bin` | regulatory database (QMI BDF type REGDB) | ath11k `qmi.c` [V] |
| `bdwlan.eNN` (170 files, incl. `bdwlan.elf`) | board data, ELF. NN = QMI board id in hex; `bdwlan.elf` for board id 0xFF | cnss2 `qmi.c` `cnss_get_bdf_file_name` [V] |
| `bdwlang.eNN` (24 files) | board data for "GF" chips (QMI chip_id & 0x10) | cnss2 `qmi.c` `CHIP_ID_GF_MASK` [V] |
| `Data.msc`, `qca6490/Data20.msc` | firmware debug-message decode tables; not needed to run | [I] |

There is no `board-2.bin`. It is not needed: ath11k sends an ELF board file as BDF type ELF
(`ath11k_qmi_load_bdf_qmi` checks the ELF magic) [V]. Pick the file from the board id and chip id
of the QMI target capability [V cnss2]. Open question [I]: the Android `WLAN.HSP.2.0` firmware
expects the cnss2 + qcacld host; ath11k (our protocol reference) is tested with the
linux-firmware `WCN6855/hw2.x` builds. Feature mismatches in WMI are possible.

Firmware buffer source: the port already loads firmware from areas at the end of `userdata`
(slop 0103 GPU area, patch 0240 ADSP area, [audio-plan.md](audio-plan.md)) [V]. WLAN needs one
more area or a slot in an existing one: amss20.bin + m3.bin + one board file + regdb ≈ 5.6 MiB [V sizes].

## Stages and effort

Effort is focused engineering time after the local kernel build (`make kernel-local`), without
waiting for device tests. Ranges are honest guesses [I]: ath11k is far larger than the ath10k
driver that Sailfish ported (HAL SRNG rings, REO/WBM, HTT, QMI with many TLVs).

| Stage | Work and exit evidence | Effort [I] | Checks |
|---|---|---:|---|
| **0. Survey on the phone** | Boot once with `negroniwlan=1` (steps 1-10: supplies, link, ID, capabilities). Exit: `NEGRONI WIFI: 9 THE QCA6490 ANSWERS ON PCIe` and step 10 shows MSI/MSI-X. Owner approval needed (it writes GCC/TLMM/PCIe registers and powers the chip). | 1 day | `make usblog`: lines `NEGRONI WIFI: 5..10`, badge `WIFI OK 10` |
| **a. BAR, SMMU, interrupts** | Assign BAR0 in the 0x60300000 window, enable memory decode + bus master on the endpoint, map BAR0, read TCSR_SOC_HW_VERSION (hw2.0 / hw2.1). Set up an SMMU stream for SID 0x1c01 (bypass or a context bank; the GPU code in `negroni_adreno.c` already programs SMMU CB/SMR). Interrupts: start with polling of the MHI rings; MSI needs a GICv3 ITS driver (DeviceID 0x5981), new code for this XNU. | 1-2 weeks (polling); +1-2 weeks for ITS MSI | USB log: BAR0 value, soc_hw_version, a DMA test write seen by the chip |
| **b. MHI + firmware download** | MHI controller: BHI for the first 512 KiB (SBL), BHIe for the full image (ath11k `mhi.c`: `sbl_size = SZ_512K`, `seg_len = SZ_512K`, `fbc_download = true`), event/command rings, then EE AMSS and mission state. Firmware from a userdata area. | 1-2 weeks | USB log: MHI state, BHI status, EE changes, no reset loop |
| **c. QRTR + QMI (WLFW)** | QRTR over the MHI `IPCR` channels. WLFW sequence as in ath11k: server arrive -> `ind_register` + `host_cap` -> REQUEST_MEM indication -> `respond_mem` (host DMA memory for the firmware) -> FW_MEM_READY -> `target_cap` (board id, chip id) -> BDF + regdb download -> `m3_info` -> FW_READY -> `wlan_cfg` + mode. Cold-boot calibration may be needed (`qcom,wlan-cbc-enabled`). | 2-3 weeks | USB log: each QMI response result, board id, firmware version, FW_READY |
| **d. HTC/WMI/HTT, HAL rings, scan** | Copy engines, HTC services, WMI init/ready, HAL SRNG setup, HTT rings, RX/TX descriptors, then a passive scan. Use the hw params of the detected hw revision (`ath11k/core.c`). | 4-8 weeks | USB log: WMI ready, ring setup, scan results (BSS count) |
| **e. Apple80211 + en0, WPA2** | Port the Sailfish upper half: `0174` (frames to en0, kernel DHCP), `0175` + `0175-stage-ionetworking.sh` (IOEthernetController, configd names it en0), `0178` (GTK rekey, rejoin), `0179` (Apple80211 events and requests for wifid). WPA2-PSK/CCMP first; WPA3-SAE is separate work. | 2-4 weeks | SSH: `ifconfig en0`, `ioreg -r -c IOEthernetInterface`, DHCP, ping; the Settings page lists networks |
| **f. Power** | Radio off/on, suspend/resume, recovery after a firmware crash. | 1-2 weeks | repeat scan/join/traffic across sleep |

Total [I]: about 3-5 months of focused work for WPA2 Wi-Fi.

Sailfish (Pixel 1, QCA6174, ath10k) is the reference for the iOS side: its README says the
Settings page scans, joins WPA2 networks, gets DHCP and Safari loads pages
(`external/ios-sailfish/README.md:17,32,41`) [V]. Its transport (BMI, ath10k CE/HTT) does not
apply to QCA6490 (MHI, ath11k) [V: `0170`-`0172` patch headers]. Sailfish has no license file:
read it as a design reference; do not copy its code ([external-repos.md](external-repos.md)).

## Patch 0260 (this round)

`patches/xnu/0260-negroni-wlan-pcie-inventory.patch` adds step 10 and the boot-arg
`negroniwlan=1` (default 0). Details: `patches/xnu/README-wifi.md`.

## Patch 0261 (stage 1: MHI + firmware download)

`patches/xnu/0261-negroni-wlan-mhi-fw.patch`. The driver reuses the survey's PCIe0 handles, claims
BAR0 in the 0x60300000 iATU window, enables memory decode + bus master, reads TCSR_SOC_HW_VERSION
to pick the firmware, reads the firmware from the userdata area into a contiguous DMA pool, then:
BHI loads the first 512 KiB (SBL); the host programs the MHI contexts; BHIe loads the whole image
(FBC, 512 KiB-segment vector); the host drives READY -> M0 and starts IPCR channels 20 and 21. It
keeps the m3 buffer ready for stage 2. Boot-arg `negroniwlan=2`; time-out `negroniwlan_to` (ms, default 10000).
Full details and every log line: `patches/xnu/README-wifi.md`.

## Stage 2 plan (QRTR + QMI WLFW, then WMI/HTT, then en0)

Stage 1 leaves the chip in mission mode with the two IPCR channels up. Stage 2 adds, in order:

1. **QRTR on MHI 20/21.** Put receive buffers on channel 21 (in) and send on channel 20 (out) with
   transfer-ring elements and doorbells (the ring/doorbell code exists; add TX/RX buffer handling).
   Parse the QRTR header (version, type, src/dst node/port). The firmware is one QRTR node; the
   host is another. Keep polling (no MSI). [I] data event ring is ring 1.
2. **QMI WLFW.** Over QRTR to the WLFW service, follow ath11k `qmi.c`: server-arrive ->
   `ind_register` + `host_cap` -> REQUEST_MEM indication -> `respond_mem` (host DMA memory) ->
   FW_MEM_READY -> `target_cap` (board id, chip id) -> BDF download (pick `bdwlan.eNN` from the
   board id; regdb is a separate BDF type) -> `m3_info` (the m3 buffer from stage 1) -> FW_READY ->
   `wlan_cfg` + mode. Cold-boot calibration may be needed (`qcom,wlan-cbc-enabled`). Each QMI
   message is a little-endian TLV; log every response result.
3. **HTC / WMI / HTT, HAL rings.** Copy engines, HTC services, WMI init/ready, HAL SRNG rings, HTT
   setup, RX/TX descriptors, then a passive scan. Use the hw params of the detected hw revision
   (`ath11k/core.c`). This is the largest part.
4. **en0.** Port the Sailfish upper half (design reference only, `0174`/`0175`/`0178`/`0179`):
   frames to en0, IOEthernetController so configd names it en0, Apple80211 events/requests for
   wifid, WPA2-PSK/CCMP. Exit: `ifconfig en0`, DHCP, the Settings page scans and joins.

Effort and checks per stage: the table above (stages c, d, e).

## Firmware extraction (macOS and Linux)

```
scripts/bg.sh wifi-fw scripts/wifi/extract-fw.sh             # out/firmware/modem/modem.img, else the OTA
scripts/bg.sh wifi-fw scripts/wifi/extract-fw.sh --dump      # the partition dump modem_a.img.gz
scripts/bg.sh -s wifi-fw                                     # status + last lines of logs/wifi-fw.log
```

Needs `python3` and, for the OTA path, `payload-dumper-go` (macOS: `brew install
payload-dumper-go`; Linux: the release binary, [setup-linux.md](setup-linux.md)). Output:
`out/firmware/wlan/` (git-ignored) with `LISTING.txt` and `SHA256SUMS`; 198 files on
NE2211_16.0.3.530 (modem.img sha256 `bcd07e89...`) [V: logs/wifi-fw.log, 2026-10-25].
Never commit these files.

## References

- Linux ath11k: [pci.c](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/ath/ath11k/pci.c),
  [core.c](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/ath/ath11k/core.c) (hw params),
  [mhi.c](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/ath/ath11k/mhi.c),
  [qmi.c](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/ath/ath11k/qmi.c);
  MHI host: `drivers/bus/mhi/host/`.
- Qualcomm cnss2 (file names, board id rules): e.g. [Xiaomi marble kernel cnss2](https://github.com/Pzqqt/android_kernel_xiaomi_marble/tree/HEAD/drivers/net/wireless/cnss2) `pci.c`, `qmi.c`.
- Existing negroni PCIe code: `external/slop/negroni-ios/xnu/patches/0106` (survey), `0109`
  (cmd-db), `0120` (PCIe link), `0122-negroni-wifi-supply-votes` (RPMh votes).
