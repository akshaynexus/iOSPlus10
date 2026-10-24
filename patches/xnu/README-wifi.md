# Wi-Fi kernel changes

This series starts a native PCIe/MHI driver for the NE2211 QCA6490-class
WLAN. The intended iOS interface is `en0`, backed by an Apple80211-compatible
IOKit/network interface.

## Patch 0260

`0260-negroni-wlan-pcie-inventory.patch` adds a separate opt-in boot argument,
`negroniwlan=1`. It runs the existing PCIe power/link steps and checks the
endpoint's PCI ID, BAR0 value, and MSI/MSI-X capability list. The capability
scan does not change PCI config space or enable vectors. Default behavior is
unchanged; the normal `negroniwifi=4` survey remains read-only.

The source syntax-checks against `out/kernel/buildtree` with the existing
warnings noted in `docs/notes.md`. This patch is **untested on the phone**.
Do not treat BAR0 as a mapped register window: no endpoint BAR is assigned,
and XNU has no verified WLAN MSI route yet.

## Protocol references and license boundary

- PCI/MHI/QCA protocol reference: Linux `ath11k` and `drivers/bus/mhi`, linked
  from [the staged plan](../../docs/wifi-plan.md).
- Interface and WPA2 design reference: `external/ios-sailfish/xnu/patches/0172*`
  through `0175*`; Sailfish targets QCA6174, so its transport code is not
  reusable for QCA6490.
- Existing Negroni survey and PCIe bring-up context:
  `external/slop/negroni-ios/xnu/patches/0106*`, `0109*`, `0120*`, `0122*`.

The new inventory logic is independently written. The external references do
not carry a license file; this patch does not copy their implementation.

## Follow-up

Before MHI/BHI firmware download, establish BAR sizing/assignment and mapping,
DMA address/cache rules, and a safe firmware-buffer source. Then bring up MHI
BHI/BHIe, QMI/QRTR, WMI/HTC/HTT, and finally the Apple80211 interface. See
`docs/wifi-plan.md` for stages, effort and log checks.
