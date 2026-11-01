# Mi A3 Wi-Fi (WCN3990 through the modem)

Area E, patches `patches/laurel/xnu/2400-2404`, on top of topaz 0113-0130 (TopazModem) and 0900
(en0 + Apple80211 + MiniIONetworkStack for wifid). Status 2026-11-01: [V] builds on laurel-int-1 (0 LSE),
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
7. WLFW (QMI 0x45): ind_register, host_cap, msa_info (MSA 0x53300000, 2 MiB, assigned to MSS/WLAN/WLAN_CE),
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
| MSA | wlan_msa_mem 0x53300000, 2 MiB: `qcom,wlan-msa-fixed-region` makes icnss use the region size (icnss.c:3767-3791), not `qcom,wlan-msa-memory` 0x100000 | 0x51900000, 1 MiB | 2401 |
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
| Modem pool | 0xE0000000-0xE1000000 (area A map, uefi-boot.md "Memory map": GPU 0xC0000000-0xE0000000, Mu reserves 0x80000000-0xE1000000, XNU 0xE1004000-0x1AD004000); one define, static_asserts (no GPU pool overlap, below 0xF0000000), boot check against [gPhysBase, +gPhysSize) | same base | 2401, 2404 |

## Firmware HL3.0 vs topaz [V source, I behaviour]

Downstream icnss (4.14) drives WLAN.HL.3.0.2 with ind_register, msa_mem_info, msa_ready, cap and the
dynamic feature mask; no host_cap, no BDF over QMI (the WLAN PD reads `bdwlan.*` from the modem file
system over tftp). Upstream ath10k (topaz's model) sends host_cap and BDF over QMI to every WCN3990
firmware HL2.0-HL3.x. 2402 makes the ath10k sequence not stall: host_cap without answer in 1 s ->
msa_info; no MSA_READY indication 1 s after cap -> board data; board data refused/missing -> wait for
FW_READY. WMI-TLV (ABI 1.53), CE layout, shadow registers, HTT v2 descriptors: the ath10k WCN3990 set
already in topaz; ath10k uses it for all WCN3990 firmware.

## Risks [I]

- Modem pool 0xE0000000-0xE1000000: area A owns the map (uefi-boot.md). Area F's audio code uses the same pool
  through topaz_pool_alloc / topaz_soc_map (one pool, shared allocator), not a second one at the same base.
  Overlap with XNU's RAM is checked at start (2404): `LAUREL MODEM POOL: off: ...`.
- Apps SMMU writes: the trinket hypervisor may ignore them (read-back -> Wi-Fi off) or abort (panic). topaz
  does the same on SM6225 and it works there.
- RPM: TopazRpm refuses the link when the GLINK FIFOs were used since boot (Mu/UEFI may use the RPM). Then
  the supply votes are refused and Wi-Fi turns off (`LAUREL WIFI: off: RPM refused ...`); the modem still boots.
- Modem PIL proxy votes (CX turbo, CXO, crypto bus) are not made; topaz does not make them either.
- EFS is read-only (rmtfs writes are dropped), as on topaz.
- Not booted yet: every number above the "[V]" rows needs the first boot log.

## Next

1. Boot with the coordinator's image; read the `TopazModem:` lines and the `LAUREL WIFI:` line (USB log).
2. If `modem boot: ... auth_and_reset refused`: check the PAS proxy votes (CX corner over RPM `rwcx`).
3. If `WLFW stuck`: the step tells which message; compare with icnss order (no host_cap).
4. If `on`: Settings > Wi-Fi lists networks (scan results also in `TopazModem: scan:` lines).

## Review fixes (2026-11-01, 2400-2404)

- 2400: FAT size in 64 bits, at most 0x0FFFFFF5 clusters, data area inside the GPT partition size
  (`sweet_ufs_part_info`), 1024-directory budget, a directory already on the scan path is skipped, 255-character
  paths, a directory that cannot be read is skipped, the cluster walk for the fragment count is capped; a WARNING
  line when the modem partition used is not the active slot's. The host model (`op10tool fatls`, `--part-bytes`,
  default 184320 KiB) has the same limits; `tools/op10tool/tests/fatls-test.sh` checks it on mkfs.fat FAT16/FAT32
  images (long names, 13-deep path, fragmented file, path over 255 characters, partition too small).
- 2401: MSA 2 MiB; refused RPM vote -> Wi-Fi off; `on` also after an earlier `off`; WLFW timers start again when
  WLFW restarts; pool define with static_asserts.
- 2403: rmtfs RW_IOVEC entries must lie inside their TLV.
- 2404 (shared with TopazAudio): one lock over every TrustZone call incl. the resume loop, SCM_V2_EBUSY retried
  (30 ms, 100 times); one lock over the SMMU stream setup; pool vs XNU RAM check. `topaz_part_fw_size/read` stay
  for TopazAudio (paths like `image/adsp.mdt`).

## Speed and 5 GHz (2026-11-01, patches 2405-2411, branch t3/laurel-wifi-5ghz-speed)

Owner: "Wi-Fi works but is not using 5 GHz properly, barely 8 Mbps to download." Status: [V] builds, [U] not run on the phone.

### Causes: band choice and data-path speed are separate limits

| # | Limit | Kind | Evidence | Fix |
| --- | --- | --- | --- | --- |
| 1 | Link is 11a/11g only: 54 Mbit/s at most, no A-MPDU, no QoS. Largest limit [I] | Speed | [V] `w_peer_assoc`: phy mode 11a/11g, no HT rates. `w_build_assoc_req`: no HT, VHT or WMM element. `htt_tx_frame`: TID 16 (non-QoS). `w_channel`: 20 MHz. ath10k has all of these (`ath10k_peer_assoc_h_ht/_vht/_phymode`, `ath10k_htt_tx_get_tid`) | 2405-2408 |
| 2 | Each wifid scan was 37 channels x 150 ms, also while joined | Speed | [V] `sta_scan` dropped its argument. [V log 05:30:37-05:30:58] joined, wifid asks 13 channels: the scan takes 8 s of each 13 s. Traffic in that scan: 46-101 msdus | 2409 |
| 3 | AP choice = strongest. wifid gives no AP ("any access point") | Band | [V] `w_join_begin`. [V log] one router (3c:6a:d2): channel 5 at -37 dBm, channel 44 at -41 dBm: 2.4 GHz wins at most distances. It joined 5220 MHz once [V 05:30:36]: 5 GHz itself works | 2409 |
| 4 | wifid got the first AP of the name, not the AP joined: wrong channel and band in iOS | Band (report only) | [V] `sta_join` matched by name. RSSI was frozen at join; RATE, MCS, PHY_MODE refused [V log] | 2411 |
| 5 | Tx queue 32 frames, a burst past it is dropped (upload) | Speed | [V] `topaz_wlan_transmit`; `net: so far ... dropped: 0 out, 0 in` [V log 16:59:51]: not hit in that run | 2410: 128 |

Estimate [I]: 54 Mbit/s without aggregation gives about 25 Mbit/s of TCP on a clear channel; a busy channel, a lower AP rate and scan
time bring it near 8 Mbit/s. No log has the owner's speed test with rates, so the share of each cause is not measured.

### Checked, not a cause

- [V] Polling: the loop runs 0.79-0.95 passes/ms (log: t= against wall clock). 16 CE1 messages and 16 Tx frames per pass give more
  than 100 Mbit/s [I]. Interrupts are not needed for this. Tx pump is 32 per pass now.
- [V] Copies: Rx 2, Tx 5, pool memory is Normal non-cacheable. At 8 Mbit/s this is no limit (`dropped: 0`); [I] it costs CPU above 100 Mbit/s.
  Not changed. No checksum offload or TSO: `ifnet_set_offload(ifp, 0)`, also [I] no limit at this speed.
- [V] Power save: `w_ps_off` before VDEV_START; now also after VDEV_UP.
- [V] Board id 0xff: the firmware has no id in OTP, so `w_start_bdf` takes the default file `bdwlan.bin`; [I] this is what it is for.
  `scripts/laurel/bdwlan-info.py`: all 31 files are 26328 bytes; `bdwlan.bin` has regulatory domain 0x809c, the others 0x0.
  [I] 0x809c = country flag + 156 = China: channels 36-64 and 149-165; channels 100-140 may be refused. New line `LAUREL WIFI: radio: ... regulatory`
  says what the firmware uses. Not changed: no evidence that it limits channel 44.
- [V] MAC 00:00:00:00:00:00: the MAC field in `bdwlan.bin` is zero. The vdev uses our own locally administered MAC. No effect on speed.
- [V] Scan is passive on 2.4 and 5 GHz: channels 44 and 161 are heard. Not 2.4 GHz only.
- [U] `wifid sets 383` (4104 bytes, refused): meaning unknown; appears before and after the join, data flows without it.
- [V] `rf_chains 1` in the log: 1 stream. Most we can reach: 433 Mbit/s PHY at VHT80 MCS 9.

### What the patches do

- 2405, 2407: `LaurelWifiPhy.h`, `LaurelWifiLink.h`: pure code, `scripts/laurel/wifi-phy-test.sh` runs it on the host (ASan + UBSan).
- 2406: phy, HT, VHT caps and regulatory from WMI SERVICE_READY; one line per feature. Kill switches: `wifi_ht=0`, `wifi_band=0`, `wifi_scanlimit=0`.
- 2408: VDEV_START with the AP's mode and width (VHT80/40/20, HT40/20, 20 MHz only on 2.4 GHz); assoc request with HT, VHT and WMM elements;
  PEER_ASSOC with flags, HT/VHT rates and A-MPDU limits; WMM parameters from the beacon; TID 0 for data, 7 for EAPOL; dynamic bandwidth.
  A join that fails with HT/VHT: that AP is legacy for the next join (one line). Beamforming is not offered (no vdev txbf setup).
- 2409: 5 GHz first if heard at -70 dBm or better and in the last minute; an AP where a legacy join failed comes last. The scan uses wifid's
  channels and dwell. While joined: dwell at most 110 ms, min rest 100 ms. Under traffic (100 frames/s or more): at most 1 scan in 60 s, other requests
  are answered with what was heard. Scan results stay 3 minutes (was 1): wifid now scans parts of the band.
- 2410: the status line; Rx rate and RSSI from the rx descriptor; Tx rate from WMI peer stats. 2411: real AP, RSSI, RATE, MCS, PHY_MODE for wifid.

### Expected lines

```
LAUREL WIFI: radio: phy 0x3, 1 rf chains, ht 0x..., vht 0x..., vht mcs 0x..., regulatory 0x809c, 5 GHz ...-... MHz
LAUREL WIFI: band choice: on: 5 GHz first when it is heard well
LAUREL WIFI: HT/VHT: on: 1 stream(s), VHT on 5 GHz
LAUREL WIFI: scan limit: on
LAUREL WIFI: band choice: 5 GHz of this name: 2.4 GHz -37 dBm, 5 GHz -41 dBm
LAUREL WIFI: join: 5220 MHz, 80 MHz wide (center 5210), phy mode 10, VHT QoS, 1 stream(s), AP: ht 1 vht 1 wmm 1
LAUREL WIFI: link 5 GHz ch 44 5220 MHz, 80 MHz VHT QoS 1x1 | rx VHT mcs 9 sgi 80 MHz 433.3 Mbps | tx 433 Mbps | RSSI -44 dBm | down 95.2 up 1.1 Mbps | frames rx ... tx ... fail 0 drop 0 nosnap 0 | scans 8 deferred 3
```

The `link` line: each 10 s under traffic, else each 60 s. `tx 0 Mbps ?`: the firmware gave no peer stats. `nosnap` above 0 under traffic: the Rx header
form differs from the code. The numbers above are the form, not results.

### Test

1. Router: same name on 2.4 and 5 GHz, 5 GHz on channel 36-48 at 80 MHz, WPA2. Start `scripts/debug/usblog.sh`. Join in Settings.
2. Read `band choice` and `join`. In Settings the network must work; open a speed test in Safari or another download. Read 3 `link` lines during the download.
3. Compare: `wifi_ht=0` (old link, new scan): gives the share of cause 1. `wifi_scanlimit=0`: the share of cause 2. `wifi_band=0`: old AP choice.
4. If a join fails or there is no data with HT: `HT/VHT: off for this AP` gives the state; `wifi_ht=0` is the fallback for the whole radio.

### Unproven until the phone test [U]

Firmware accepts PEER_ASSOC with HT/VHT at these values; it starts Tx A-MPDU by itself and answers the AP's ADDBA [I: ath10k "Firmware offloads Tx
aggregation"]; A-MSDU in this Rx path (ath10k: one native-wifi frame per subframe, no pad on WCN3990 in this tree [V source]); 80 MHz on channels marked
passive in our channel list; wifid accepts the new answers to RATE, MCS, PHY_MODE (layouts from old Apple headers + request sizes in the log [I]);
the Tx rate unit of peer stats (kbit/s [I]); real throughput.
