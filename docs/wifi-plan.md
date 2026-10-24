# QCA6490 Wi-Fi plan for iOS 16.7.16

Target: NE2211 / SM8450, Qualcomm QCA6490-class WLAN on PCIe0. Linux identifies
PCI ID `17cb:1103` as WCN6855; the current port uses the WCN6855 hw2.1 ath11k
profile as its starting point. The goal is a native kernel interface that iOS
uses as `en0`; USB networking remains a separate debug path.

## Current evidence

- The existing survey patch reads the PCIe0 clock/pin/cmd-db state at steps 1–4.
- Steps 5–8 vote PCIe clocks and Wi-Fi supplies, release reset, initialize the
  SM8450 PCIe PHY/root port, and wait for DLLLA. Step 9 reads endpoint ID, class,
  BAR0 and BAR1. These are code paths; no NE2211 runtime result is recorded in
  this repo as of 2026-10-24.
- The current code does not program an endpoint BAR, establish a host virtual
  mapping for the WLAN register aperture, or enable MSI/MSI-X. New step 10 only
  inventories the BAR value and interrupt capability list. It does not alter
  endpoint config space.
- `negroniwifi=4` is already in the normal config and is read-only. The active
  stage (a) probe is separately guarded by `negroniwlan=1` and has not been run.
- Linux ath11k maps WCN6855 hw2.1 to its PCI/MHI path; the Linux source is the
  protocol reference, not code copied into this port. See the Linux
  [ath11k PCI driver](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/ath/ath11k/pci.c),
  [WCN6855 hardware parameters](https://github.com/torvalds/linux/blob/master/drivers/net/wireless/ath/ath11k/core.c),
  and [MHI interface](https://github.com/torvalds/linux/blob/master/include/linux/mhi.h).
- Sailfish provides a tested upper-layer design for its different QCA6174 chip:
  Apple80211-facing IOKit interface, scan/connect state, EAPOL handling and
  WPA2-PSK handshake. Reuse the design only; it does not establish ath11k/MHI
  compatibility. See `external/ios-sailfish/xnu/patches/0172*` through `0175*`.

## Stages and estimates

Effort is engineering time after a usable XNU build is available. Estimates do
not include time waiting for Xcode 15 CI or collecting a device log.

| Stage | Work and exit evidence | Effort | USB kernel log / SSH checks |
|---|---|---:|---|
| **a. PCIe link, BAR, interrupts** | Confirm safe supply/clock sequence, `17cb:1103`, link speed/width, BAR sizing and a stable CPU mapping; route MSI/MSI-X or document a working poll/INTx fallback. Existing code reaches link training and reads ID/BAR; BAR assignment and interrupt delivery remain unimplemented. | 2–4 days | USB log: `NEGRONI WIFI: 8 link UP`, endpoint ID, BAR values, MSI/MSI-X capability, then register read/write sanity checks. SSH: `ioreg -l` for the WLAN service and `ifconfig` only after a real interface is published. |
| **b. MHI and SBL firmware** | Build MHI controller state from the device registers; establish DMA-safe buffers and interrupts; load the SBL image with BHI/BHIe and observe transition from RESET to SBL/RDDM/mission-ready. Firmware bytes are extracted by `scripts/wifi/extract-fw.sh`. Current code does not initialize MHI or issue BHI. | 4–7 days | USB log: MHI version/state, BHI error/status, transfer completion, execution environment and timeout detail. SSH: service remains attached; kernel log shows state transition and no reset loop. |
| **c. QMI/QRTR and calibration** | Bring up QRTR-over-MHI; implement WLFW QMI service registration; provide AMSS, board data and calibration; complete `msa_ready`, board download, `cal_report`, `FW_READY`, and mission mode. Stock image contains `amss.bin`, `m3.bin`, `regdb.bin`, and `bdwlan.*`; no `board-2.bin` is listed, so generate or convert board data only after confirming format. | 5–8 days | USB log: QRTR node/service IDs, QMI transaction results, board/cal transfer sizes, firmware-ready indication. SSH: radio service status and firmware version; no interface is expected yet. |
| **d. WMI/HTC/HTT data path and scan** | Implement boot-time WMI control, HTC services, HTT rings, DMA ownership/cache handling, management/data RX/TX and passive scan. Match the exact WCN6855 hw2.1 hardware parameters. | 1–2 weeks | USB log: target capabilities, WMI ready, HTC service map, ring setup, scan start/completion, BSS count and RX/TX completion counters. SSH: `ioreg` sees radio; scan results appear through the kernel interface diagnostics. |
| **e. Apple80211 interface, connect and security** | Publish the interface in the form iOS expects, with `en0` naming and Apple80211 selectors consumed by `wifid`/MobileWiFi. Reuse Sailfish's IOKit/network interface design. Start with WPA2-PSK/CCMP and the existing kernel-side EAPOL handshake model. Add WPA3-SAE only with a defined iOS userland/key-management contract; do not claim WPA3 from the WPA2 path. | 1–3 weeks | USB log: IOKit match, interface attach, scan/join and EAPOL/key-install events. SSH: `ioreg -r -c IOEthernetInterface`, `ifconfig en0`, `networksetup -listallhardwareports`, then DHCP/route/DNS and reachability. |
| **f. Power and suspend** | Add safe radio power-down, wake, suspend/resume, runtime power management and error recovery after steady-state traffic is proven. Keep board rails and reset sequencing aligned with SM8450 and QCA firmware behavior. | 4–7 days | USB log: suspend entry/exit, wake reason, MHI state restore and bounded recovery after link loss. SSH: repeat scan/connect/traffic across sleep/wake and check that `en0` remains attached. |

## Patch scope in this round

`0260-negroni-wlan-pcie-inventory.patch` adds the opt-in `negroniwlan=1`
path. It runs existing steps 1–9 and reads PCI BAR0 and the standard MSI/MSI-X
capability list. It does not enable an interrupt, assign BARs, or download
firmware. The source and patch are marked untested on hardware. Stage (b) is
planned, not implemented: XNU needs a verified BAR/DMA mapping and a firmware
buffer source before a BHI DMA transfer is safe. The current port has not
validated those prerequisites.

## iOS upper-half integration

The long-term interface is a kernel-owned `IOEthernetController`/`IOEthernetInterface`
plus Apple80211 behavior that `wifid` recognizes as `en0`. A plain `ifnet` does
not make a working Wi-Fi device: scan, association, keys, link state and
network-service matching must all agree. Sailfish supports the proposed
interface and WPA2 shape, but its QCA6174 firmware protocol cannot be reused for
QCA6490. Stage WPA2-PSK/CCMP first; treat WPA3 as a separate capability that
requires a tested SAE path and userland integration.

## Firmware extraction

Run `scripts/wifi/extract-fw.sh` directly for a quick local image, or use
`scripts/bg.sh wifi-fw scripts/wifi/extract-fw.sh` for OTA payload extraction.
The script uses `payload-dumper-go` and the repo's read-only `fatcopy.py` reader.
Firmware and checksums are written under ignored `out/firmware/wlan/` and must
not be committed. Check `SHA256SUMS` before using firmware in later stages.
