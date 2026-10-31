# Mi A3 Wi-Fi (WCN3990 through the modem)

Area E, patches `patches/laurel/xnu/2400-2402`, on top of topaz 0113-0130 (TopazModem) and 0900
(en0 + Apple80211 + MiniIONetworkStack for wifid). Status 2026-11-01: [V] builds (221 patches, 0 LSE),
[U] not booted.

Labels: [V] read in source or measured on the host, [I] inference, [U] unknown.

## Chain

1. `topaz_modem_init` (from `AppleCLCD::start`) starts the modem thread. On by default; kill switches
   `modem=0` (nothing starts) and `wifi=0` (the modem boots, the radio stays off).
2. `topaz_soc_map` -> 2400 `fw_pick`: waits for sweet_ufs, reads the GPT attribute bit 50 (A/B active)
   of `boot_a`/`boot_b`, mounts `modem_<active>` (then the other slot, then `modem`) as FAT16/FAT32 and
   builds the path index (long names, lowercase, `image/modem.mdt`). It must hold `image/modem.mdt`.
3. Apps SMMU: identity context bank for the WLAN stream 0x80 mask 1 (read back; failure = Wi-Fi off).
4. 2401: RPM SMD votes for the WCN3990 supplies (as icnss): `ldoa` 8 0.64 V, 16 1.8 V, 17 1.304 V,
   23 3.0 V, keys `uv` + `swen`, active and sleep set. Refused votes are logged, not fatal.
5. TrustZone PAS 4: init_image (metadata + hash from `modem.b01`), mem_setup, segments
   `modem.bNN` into the carve-out 0x4b000000+0x7e00000, auth_and_reset.
6. SMP2P 435/428 (bit 14): READY, IPA power answer; GLINK IPCRTR over SMEM (bit 12); QRTR; our
   pd-mapper / tftp (files from the FAT index, `/readwrite` in RAM) / rmtfs (modemst1, modemst2, fsc,
   fsg read-only, writes not kept).
7. WLFW (QMI 0x45): ind_register, host_cap, msa_info (MSA 0x53300000, 1 MiB, assigned to MSS/WLAN/WLAN_CE),
   msa_ready, cap (board id), board data `bdwlan.bNN`/`.NNN`/`.bin`, cal_report, FW_READY, wlan_cfg,
   mission mode. 2402 fallbacks for WLAN.HL.3.0.2 (below).
8. Copy engines at 0xC800000+0x240000 (polled), HTC, WMI-TLV READY -> `LAUREL WIFI: on`, HTT, passive
   scan, then 0900/topaz_sta: en0 + Apple80211 for wifid (the ADT has the `wlan` node: `scripts/laurel/mkadt.py`).

## Expected log lines

```
TopazModem: firmware: modem_b (active slot b): FAT16, 4096-byte sectors, 16 KiB clusters, 420 files (0 fragmented)
TopazModem: smmu: WLAN identity (sid 80 mask 1) CB.. SMR..: ... -> OK
TopazModem: wlan: RPM L8A 640000 uV on: OK          (x4)
TopazModem: phdrs=31 hash=1 region 4b000000..52e00000 relocate=1
TopazModem: init_image / mem_setup / segments loaded / auth_and_reset: ret=0 res=0
TopazModem: modem is up (MODEM READY)
TopazModem: wlfw: chip_id .. family .., board_id .., fw_version ..
TopazModem: *** WLAN FIRMWARE READY ***, *** WLAN ON (mission mode) ***, *** WMI READY (fw MAC ..) ***
LAUREL WIFI: on: modem up, WLFW ready, board id 0x.., MAC ..:..:..:..:..:.. (modem_b)
```

The summary line on the host: `scripts/laurel/modem-fw-check.sh` (op10tool `fatls`, same parser as the
kernel) prints it for the stock `NON-HLOS.bin` [V]: FAT16, 4096-byte sectors, 16 KiB clusters, 420 files,
0 fragmented; `modem.mdt` 9100 bytes, `wlanmdsp.mbn` 3686084 bytes, board files `bdwlan.bin`, `.b0a-.b0f`,
`.102-.10f`, `.202`, `.203`.

`LAUREL WIFI: off: <reason>` names the first failure: firmware partition / FAT, apps SMMU, each PAS step
(ret/res), modem.mdt layout outside the carve-out, modem crash reason (SMEM 421), modem not READY in 60 s,
no WLFW service in 30 s, WLFW stuck at a step (60 s), no WMI READY 30 s after mission mode.

## Mi A3 values, checked against `external/laurel-kernel-los/.../qcom/trinket.dtsi` [V]

| Item | Mi A3 | topaz | Change |
| --- | --- | --- | --- |
| Modem carve-out | pil_modem_mem 0x4b000000+0x7e00000; our modem.mdt loads 0x4b000000..0x52e00000 | 0x4ab00000+0x6900000 | 2401 |
| MSA | wlan_msa_mem 0x53300000 (2 MiB), icnss `qcom,wlan-msa-memory` 0x100000 | 0x51900000, 1 MiB | 2401 |
| WLAN SMMU stream | apps_smmu 0x80 mask 1 | 0x1a0 mask 1 | 2401 |
| WLAN supplies | L8A cx-mx 0.64 V, L16A 1.8 V, L17A 1.304 V, L23A 3.0-3.312 V (PM6125, RPM SMD, set 3) | none voted | 2401 |
| Firmware partition | modem_b (active slot b), FAT16 4 KiB sectors | modem_a, offset table | 2400 |
| Firmware | WLAN.HL.3.0.2-00215, MPSS.AT.4.3.1 (NON-HLOS verinfo) | HyperOS 2.0.208 | 2402 |
| SMEM / TCSR mutex | 0x46000000 (2 MiB) / 0x340000, hwlock 3 | same | none |
| APCS IPC | 0x0F111000: SMP2P modem bit 14 (SPI 70), GLINK modem bit 12 (SPI 68), RPM bit 0 | same | none |
| Apps SMMU | 0xC600000 (qsmmu-v500) | same | none |
| WLAN CE | 0xC800000 (+0x240000 CE regs), SPI 358-369 (not used: polled) | same base | none |
| RPM | rpm-glink, msg RAM 0x45F0000 (0x7000), "rpm_requests" | same | none |
| PAS id | 4 (pil-tz-generic, qcom,mss@6080000) | 4 | none |
| rmtfs | modemst1, modemst2, fsc, fsg (no slot suffix); sharedmem 0x200000 + guard | buffer 0x300000 | none (bigger buffer is fine) |
| Modem pool | 0xE0000000+16 MiB (bank C 0xC0000000-0x1C0000000, not in the kernel window 0x81000000+0x30000000) | same | none [I] |

## Firmware HL3.0 vs topaz [V source, I behaviour]

Downstream icnss (4.14) drives WLAN.HL.3.0.2 with ind_register, msa_mem_info, msa_ready, cap and the
dynamic feature mask; no host_cap, no BDF over QMI (the WLAN PD reads `bdwlan.*` from the modem file
system over tftp). Upstream ath10k (topaz's model) sends host_cap and BDF over QMI to every WCN3990
firmware HL2.0-HL3.x. 2402 makes the ath10k sequence not stall: host_cap without answer in 1 s ->
msa_info; no MSA_READY indication 1 s after cap -> board data; board data refused/missing -> wait for
FW_READY. WMI-TLV (ABI 1.53), CE layout, shadow registers, HTT v2 descriptors: the ath10k WCN3990 set
already in topaz; ath10k uses it for all WCN3990 firmware.

## Risks [I]

- Modem pool 0xE0000000-0xE1000000: no other driver may use it. topaz's GPU pool 0x90000000+1 GiB lies
  inside the Mi A3 kernel window; if the GPU area moves it to bank C, it must avoid this range.
- Apps SMMU writes: the trinket hypervisor may ignore them (read-back -> Wi-Fi off) or abort (panic). topaz
  does the same on SM6225 and it works there.
- RPM: TopazRpm refuses the link when the GLINK FIFOs were used since boot (Mu/UEFI may use the RPM). Then
  the supply votes are refused (logged) and the chip may be unpowered (WLFW stuck or modem crash).
- Modem PIL proxy votes (CX turbo, CXO, crypto bus) are not made; topaz does not make them either.
- EFS is read-only (rmtfs writes are dropped), as on topaz.
- Not booted yet: every number above the "[V]" rows needs the first boot log.

## Next

1. Boot with the coordinator's image; read the `TopazModem:` lines and the `LAUREL WIFI:` line (USB log).
2. If `modem boot: ... auth_and_reset refused`: check the PAS proxy votes (CX corner over RPM `rwcx`).
3. If `WLFW stuck`: the step tells which message; compare with icnss order (no host_cap).
4. If `on`: Settings > Wi-Fi lists networks (scan results also in `TopazModem: scan:` lines).
