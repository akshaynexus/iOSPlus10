# Wi-Fi kernel changes (0260-0269)

Plan, hardware facts and stages: [docs/wifi-plan.md](../../docs/wifi-plan.md).

## 0260-negroni-wlan-pcie-inventory.patch

File: `bsd/dev/negroni_wifi.c` (the slop survey: 0106 steps 1-4, 0109 cmd-db, 0120 PCIe link
steps 5-9, 0122 RPMh supply votes). Made in `out/kernel/wt-wifi` (branch `wifi`) with
`git diff base -- bsd/dev/negroni_wifi.c`.

- New step 10 `step_pci_caps`: reads the endpoint's command/status (0x04), BAR0 (0x10) and walks
  the capability list (pointer 0x34; ID 0x05 MSI, 0x11 MSI-X). It prints `NEGRONI WIFI: 10 ...`.
  It only reads (`rd`); it writes no config register, assigns no BAR and enables no vector.
- It runs only after step 9 found 17cb:1103 (step 9 returns false on another ID, the loop stops).
- New boot-arg `negroniwlan=1` (default 0): runs steps 1..10. Same as `negroniwifi=10`. The Volume
  Up probe menu (`negroni_keys.c`, max 4 Wi-Fi steps) still wins when it runs.
- The normal config keeps `negroniwifi=4` (steps 1-4 read only, `config/negroni-ne2211.toml`).

Risk: `negroniwlan=1` runs the existing write steps 5-8 (GCC GDSC and clocks, five RPMh supply
votes, WLAN_EN high, PCIe PHY + root port + iATU, PERST release, link training). These steps have
never run on a phone [V: no `NEGRONI WIFI` line in `logs/usblog-*.txt`; slop NOTES:805 "no
supply/link/chip response tested"]. Ask the owner before the first boot with it.

Expected log on success: `NEGRONI WIFI: 8 link UP`, `NEGRONI WIFI: 9 bus 1 device 17cb:1103`,
`NEGRONI WIFI: 10 BAR0 ...`, `NEGRONI WIFI: 10 interrupt inventory: MSI present, ...`, badge
`WIFI OK 10`.

Build: applies on `base` in name order with all committed `patches/xnu/0*.patch` and links in
the local Xcode 15.4 kernel build (see `docs/reviews/codex-2026-10-25.md`). Not run on the phone.

## License boundary

- Protocol reference: Linux `ath11k` (BSD-3-Clause-Clear) and `drivers/bus/mhi` (GPL-2.0); we read
  them, we do not copy them.
- iOS interface reference: `external/ios-sailfish/xnu/patches/0174`, `0175`, `0178`, `0179`
  (no license file: design only).
- Step 10 is new code; it uses only PCI-spec offsets.
