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

## Stalls, page load, signal (2026-11-01, patches 2880-2886, branch t3/laurel-wifi-stall)

Owner on the phone: "fast.com and speedtest do not load fast enough, you made it worse, and the Wi-Fi signal level is wrong."
Log: `logs/laurel-boot-1907.txt`. Status: [V] builds, host test passes, [U] not run on the phone.
Labels: [V] read in source or the log, [I] inference, [U] unknown.

### What the log shows and what it cannot show

| Time | Event | Kind |
| --- | --- | --- |
| 19:14:20 | Join 5220 MHz VHT80 | [V] |
| 19:14:21-24 | Scan 93, 2.2 s, 39 msdus heard: starts 0.5 s after the join, when DHCP starts | [V scan], [I DHCP] |
| 19:14:24-27 | Safari, WebKit.Networking; first `connectx` lines at 19:14:27 (46 in that second) | [V] |
| 19:14:27-29 | Scan 94, 1.7 s, over Safari's first fetches. Reason: 100 frames/s or more was "traffic"; a page's start has fewer | [V] |
| 19:14:30-19:15:10 | 40 s at 20, 9.5, 5.2, 1.9 Mbps, with drop 0, fail 0, link 292-433 Mbps. CPU at 19:15:00: gold 93 %, silver 70 % | [V] |
| 19:15:09 | Scan 95 (0.44 s) during that load: 40 s after scan 94 | [V] |
| 19:15:10-27 | Burst, 179 Mbps in one window: 148853 Rx frames in 10 s = 14900 frames/s. Tx 3500 frames/s + 533 lost | [V] |
| 19:15:28 on | About 50 frames/s both ways; no more drops. 19:16:01: CPU gold 87 %, silver 82 % at 0.5 Mbps | [V] |

- [V] All 13715 `dropped out` = `tx_drop` = 13715: each is the 128-frame queue full in `topaz_wlan_transmit`. No other reason.
  Average frame out: 7829153 / 79271 = 99 bytes: nearly all TCP ACKs [I]. A lost ACK does little to a download; a lost SYN or DNS question costs 1 s or more.
- [I] Why the owner's "worse": before 2405-2411 the link was too slow to fill the queue (`dropped: 0 out` in the old log). Now a burst fills it, and it is one queue
  for all flows: a DNS question or a SYN of a new page is lost with the ACKs (13 % of frames in the burst). Scans at the start of a page are old, but they stayed.
- [I] The collapse after the burst: the end of the test (fast.com stops by itself), not a stall: frames go both ways without drops or failures. The log has no TCP
  counters, so this is not proven. The new `path` line proves or disproves it: retransmits and timeouts at a stall, none at the end of a test.
- [V code + log] The 16 s gap at 19:15:36 is the line's rule, not a stalled thread: the next line came only when `lw_busy` was true at the 10 s mark, else 60 s. The burst
  ended about 19:15:28; `SWEET FPS` at 19:15:30: 588 frames in 10 s, longest gap 53 ms. [U] The modem thread's own time: no `t=` line in that window. New field `gap max` shows it.
- [V] "179 Mbps at 90 % CPU" is not measured: the two CPU lines are at 19:15:00 (5 Mbps) and 19:16:01 (0.5 Mbps). No CPU line lies in the burst. The CPU is that busy without
  Wi-Fi traffic. New fields: `thread N %`, `N us a frame`.
- [I] Page load: from 19:14:30 to 19:15:10 the network was not full (1.9-20 Mbps, 179 possible in the same minute, drop 0), and the CPU was. The largest limit of that phase is
  likely not Wi-Fi: 8 WebContent starts in 34 s, `wifip2pd` started 16 times and `nanotimekitcompaniond` 14 times in 2 min 40 s (about every 10 s: a crash loop [I], not looked at here).
  Not shown by the log: JS and render time, DNS time, TLS time. So this remains an inference: the owner's report stands, and the next log can separate them.
- Not visible in this log [U]: DNS (`net_names` is off, no DNS counters), retransmits, IPv6 use, Happy Eyeballs delays. Checked, no sign of a problem: MTU: frames in average 1505 bytes
  (Rx full size works); `dropped ... 0 in` (no mbuf failures at Rx); `connectx() - failed necp_set_socket_domain_attributes` (255 lines) only says that a tracker note failed, the connect goes on
  (`uipc_socket.c`); `MiniIONetworkStack` is a registry stub for configd, no TCP in it; 179 Mbps shows that no TCP window limits it near that rate.

### Candidates for the Tx queue full

| Candidate | Result |
| --- | --- |
| 128-frame limit (2410) | [V] The place of all the drops. It is the symptom: the queue fills in 32 ms when its reader stops |
| CE ring full | [V] No: no `htc: send on ep` line in the log |
| HTT credits | [V] No: HTC endpoint without credit flow |
| Firmware failures | [V] No: `fail 0` |
| mbufs | [V] Rx no: `0 in`. Tx does not allocate |
| Scan | [V] No: no scan in the two windows with most drops |
| Tx A-MPDU not started | [U] The log has no count. `tx 433` says only the rate |
| 64 Tx slots, or Rx work in the same thread | [I] One of them. In the burst the reader moved 3500 frames/s: either 64 slots per 18 ms of completions, or 32 frames per 9 ms pass. The log cannot separate them. The new `wait slots ... q ...` fields can. Both are changed |

### What the patches do

- 2881: en0 uses the output-queue model of the kernel (`.start`, FQ-CoDel), as real drivers do; it was `IFNET_INIT_LEGACY`: every frame straight to the driver, returned 0 when dropped.
  A full radio queue makes the queue's thread wait (200 us steps); frames stay in the class queue; TCP gets EQFULL and flow control, not a lost frame; one flow's frames do not delay another's.
  Kill switch `wifi_txq=0` (old model, 128 frames, tail drop). If the interface cannot be made: same model, one line.
- 2882: Rx in parts: payload copied once, directly into the mbuf (was: stack, then mbuf). One `ifnet_input` per batch. Drops by reason. `path` line.
- 2883: Tx 2 full copies (mbuf -> queue, queue -> firmware slot; was 5: + static frame, + pump frame, + 802.11 frame). Queue without lock, 64 frames. 128 Tx slots (was 64). CE room is checked before a slot is taken (was: a failed send logged one line per frame).
- 2884: Rx ring 512 (was 256), 1 doorbell per batch. Rate and data RSSI only from unicast data of the AP joined. Beacons of that AP (WMI MGMT_RX, about 9/s in the log) in their own average.
- 2885: Rx and Tx take turns: 16 messages of each CE, then up to 32 Tx frames; up to 8 turns or 2 ms per pass (was 1 turn per pass). Scan rule: none in the first 30 s of a link; with 20 frames/s or more: at most 1 in 120 s; idle: 1 in 20 s. Others are answered from what was heard.
- 2886: RSSI_CHANGED event to iOS, RSSI_BOUNDS, log budget per kind.
- Not changed: checksum offload [I: about 1.5 us per frame, 2 % of a core at the burst's rate; not worth a wrong accept]. Non-cacheable reads of the Rx buffers: the largest remaining copy cost [I]: cached Rx buffers need cache maintenance, not safe to change without the phone.

### What iOS expects: read from iOS 16.7 20H392 (`scripts/debug/wifi-re.sh`, `wifi-xref.py`)

| Item | Verified [V] |
| --- | --- |
| RSSI (16) | IO80211 `Apple80211CopyValue` 0x1d3ec470c: 52 bytes in, version 1, +4 radios, +8 unit, +0xc first radio; radios = 1: RSSI_CTL_AGR = +0xc. The layout in the code is right. 52 bytes agree with the log |
| RATE (8), MCS (57) | Same function, shared case: the answer is the request's `req_val` (+0x14), a number. Code is right; error 6 in the log came before the join |
| RSSI_BOUNDS (106) | 0x1d3ec639c: 16 bytes in, first word 1; RSSI_MIN +4, RSSI_MAX +8, RSSI_THRESHOLD +0xc. wifid 0x10004b8c8: logs them, keeps the threshold as `SignalStrengthThreshold`. The values -95, -20, -80 are a choice [I]; the bars do not use them |
| CURRENT_NETWORK (103) | The 271 lines of 103 (`error 6`): the last at 19:09:51; the join was 19:14:20; the log budget of 800 ended at 19:09:57. ENXIO is right when not joined. [U] After the join: no line was left in the log; the new budget shows it |
| Bars | wifid 0x10003f65c: scaled = 0.5 + x / (2 sqrt(x*x + 450)), x = RSSI + 77.5. SBWiFiManager `_updateSignalStrengthFromRawRSSI:andScaledRSSI:`: bars = ceil(3 * scaled), 1 to 3. So 3 bars above -70 dBm, 2 above -85 dBm, else 1 (host test compares this with the formula) |
| Why the bars were wrong | wifid updates SCALED_RSSI (0x10005cd14) only from the link event and from event 39 RSSI_CHANGED (`eventArray`; dispatcher 0x1d3ed7f28 -> `__dispatchlqmChangedEvent`, wifid case 0x10004f3f0). The kernel never sent 39: the bars stayed at the value of the join's last frame. SpringBoard: `__WiFiDeviceLinkQualityChanged` |
| Event 39 data | At least 180 bytes; byte 0 valid, +4 int32 dBm -> key `RSSI`; all else behind valid bytes or flag bits, 0 here. wifid reads the others with GetValueIfPresent |

The signal: frames at 6 Mbps read -37/-38 dBm each time and the scan says -37; VHT data reads -47 to -60 at the same place [V log]. [I] the AP lowers power at high MCS. So iOS gets the beacon average (fresh for 3 s), then the data average, then the scan value.
At -37 and at -60 iOS draws 3 bars either way. The owner's "wrong" was either the frozen value or a number read from the mixed line [U: the owner has not said which].

### Expected lines

```
LAUREL WIFI: tx queue: on: output queue with flow control
apple80211: wifid gets 106 (RSSI_BOUNDS), value 0, 16 bytes: answered
apple80211: wifid gets 16 (RSSI), value 0, 52 bytes: answered          (after the join)
apple80211: wifid gets 8 (RATE) ... answered ; gets 57 (MCS) ... answered ; gets 103 (CURRENT_NETWORK) ... answered
LAUREL WIFI: link 5 GHz ch 44 5220 MHz, 80 MHz VHT QoS 1x1 | rx VHT mcs 9 sgi 80 MHz 433.3 Mbps | tx 433 Mbps | RSSI -38 dBm 3 bars (beacons -38, data -49, fw ..) | down 179.3 up 2.5 Mbps | frames rx .. tx .. fail 0 | drop 0 (full 0 down 0 big 0 nomem 0 queue 0 left 0, in 0) | wait slots .. ce .. q .., q max .., in air .. | thread ..%, pass max .. us, gap max .. ms, .. us a frame | nosnap 0 | scans 92 deferred 8
LAUREL WIFI: path | tcp sent .. retrans .. timeouts .. dup in .. | connects .. | dns asked .. answers .. | v4 out .. in .. | v6 out .. in .. | sender waited .. times
```

The numbers are the form, not results. How to read them:
`drop` with `full` above 0: only with `wifi_txq=0`. `queue`: FQ-CoDel dropped (normal at a low count). `left`: frames thrown away at a link loss.
`wait slots` high: the firmware is slow to complete frames: look at A-MPDU next. `wait q` high and `slots` 0: the thread cannot keep up. `gap max` above 20 ms: the modem thread was starved.
`rx legacy` no more between VHT values. `scans` does not rise in the first 30 s of a link.

### Test

1. Boot. Check `tx queue: on`. Join. `scans` must not rise for 30 s. Status bar: compare with the `bars` value of the line.
2. Open fast.com. Read `link` + `path` lines during the page (before the test starts) and during the test. `drop` stays 0 or low, `dns asked` near `answers`, `retrans` low.
3. After the test: does the page respond? If traffic falls with `timeouts` rising: a real stall. If without: the test has ended.
4. Page speed: if `down` is low with `thread` low, `wait` flat, `dns` answered, `retrans` low, while the page is slow: Wi-Fi is not the limit; look at the CPU (crash loops above, WebKit).
   Boot-arg `net_names=1` (exists) adds a line per DNS question and per TCP connect, with names.
5. Compare `wifi_txq=0` in the same test: it gives the share of the output queue. If en0 stops sending with `tx queue: on` (`sender waited` rising, `down` 0): boot with `wifi_txq=0` and report it.

### Unproven until the phone test [U]

The output-queue model on this kernel (`if_fake.c` uses the same KPI; no driver of ours has). Whether FQ-CoDel's limits fit. Whether the firmware accepts 512 Rx buffers and 128 Tx frames at once (ath10k `HTT_RX_RING_SIZE_MAX` is 2048 [V htt.h]; our HTT setup has 1056 Tx descriptors [V]).
That wifid and SpringBoard move the bars on event 39 ([V] by code, not seen running). The unit of `fw` in the line. Real throughput and whether pages load faster.

## No page loads (2026-11-01, branch t3/laurel-safari-net, `userland/ssh/laurelnet.c`, patch 2888)

Owner: "Wi-Fi is fine, but fast.com and speedtest don't load." Log: `logs/laurel-boot-2235.txt` (main checkout). Status: [V] builds, dry run PASS, [U] not run on the phone.

### Cause: the USB link took the default route and DNS from Wi-Fi

| Item | Evidence | Kind |
| --- | --- | --- |
| The root has a job that makes ue0 primary | `exec usbnetcfg` 22:35:51. Image of 21:57: job `dev.iosplus10.usbnetcfg up`; preferences: USB service first, router 192.168.7.1, DNS 1.1.1.1 8.8.8.8 (7z of the image). `usbnetcfg.c` waits for ue0, writes these keys, and adds the route by hand if ue0 is not primary | [V] |
| The tool came with the SSH step, after the good boot | Boots with Wi-Fi joined: 19:07: 0 `exec usbnetcfg`, 148 `connectx` lines, 179 Mbps. 22:08 and 22:35: 1 `exec usbnetcfg`, 0 `connectx` lines, in spite of Safari and its web processes | [V] |
| Nothing goes to en0 after the first minute | 22:38-22:47: `dns asked 0`, `connects 0`, `tcp sent 0` for all of the kernel. Safari started at 22:42:44 | [V] |
| The host does no NAT | No `/var/run/iosplus10-share.state`, so `share-internet.sh` is not on. An IP packet from 192.168.7.2 has no way back | [V] state file, [I] no return |
| ue0 was primary on the phone | IPMonitor's choice was not read: no SSH in that boot. `/private/var/log/iosplus10-usbnetcfg.log` has it. The `usbnetcfg down` test below decides it | [I] |
| Why TCP is 0, not only en0's | No name resolves (the questions go to 1.1.1.1 through ue0), so no connection starts. `tcp sent` is the whole kernel's, loopback too | [I] |

### Checked, not the cause

- Output queue (2881), `wifi_txq`: [V] frames still go each minute (`v6 out 4-12`, `v4 out 0-2`). `q max 4-5`, `wait slots 0 ce 0 q 0`, `sender waited 0`, drop 0, `queue 0`, `left 0`, `in air 0`. A stalled queue shows a rising `wait q`, and no frames.
  [V code] `ifnet_enqueue` wakes the start thread; `net_start` loops until `ifnet_dequeue` fails, keeps no state and never turns output off: nothing stays waiting after idle. A DNS frame in the queue would count at `net_tx_note` (`dns asked`) when it leaves; a frame cannot pass the v6 frames that left. [I] So `dns asked 0` means no DNS frame came to en0.
  Not yet shown: the queue under a real burst (no traffic crossed it after 19:07). `wifi_txq=0` stays the comparison, if a page is slow after this fix.
- Link: [V] VHT80 5 GHz, RSSI -30 to -41 dBm, fail 0, `v4 in` 90-123 frames a minute. The radio hears the AP.
- Safari's crashes: below. Web processes and MobileSafari stay up, and `CRASH webbookmarksd` was also in boot 19:07, when pages loaded [V].
- wifid: `sets 383`, `419`, `gets COUNTRY_CODE` REFUSED: [V] also in boot 19:07. `gets 103 CURRENT_NETWORK` answered while joined [V].
- Content filter, `nesessionmanager`, `symptomsd`: [V] no failure line. [U] no line says that they are well: they log to os_log only. `connectx` necp lines: they come only from a connect, and there was none.
- MTU: [V] 19:07 frames of 1505 bytes in average; no change since.

### dns asked 24 answers 6

[V] Only in the first minute (22:36:04-22:37:04), with `connects 1`, `tcp sent 6`, and `exec captiveagent` at 22:36:05. Then 0 for 10 minutes.
[I] A client bound to en0, as the captive check, uses en0's own DNS servers from DHCP or the router's RA, also when another service is primary. This explains why it was only this minute. [V] The same router gives this host's Wi-Fi a global IPv6 address, so v4 and v6 servers are likely. mDNSResponder asks more than one server, and asks again [I].
[U] The log cannot say which server had no answer, or if a question got none. Patch 2888 splits the count: `dns asked N (v6 N) answers N (v6 N)`. Boot-arg `net_names=1` gives each name.

### Crashes (`scripts/debug/crash-symbolize.sh`, 20H392 cache)

Both: uncaught exception: `abort` <- `demangling_terminate_handler` <- `_objc_terminate` <- `std::terminate` <- the first frame that may not throw. The stack under the throw is unwound, and the text goes to os_log, so the kernel line cannot say the reason.

| Crash | Frames | Result |
| --- | --- | --- |
| `com.apple.Safari[335]` 22:42:47, once | `dispatch_once` <- SafariCore `-[NSFileManager _safari_getMobileSafariContainerDirectoryURL:isContainerized:]` <- `safari_mobileSafariContainerDirectoryURL` | [V] A Safari helper, not MobileSafari (the name is the first 16 characters; History and SafeBrowsing start in that second; which one [U]; in boot 19:07 both ran without a crash). [V disassembly 0x1accd9938] the block: `sandbox_container_path_for_pid`; our kernel answers ENOENT (op 4); then `[[LSApplicationRecord alloc] initWithBundleIdentifier:@"com.apple.mobilesafari" allowPlaceholder:NO error:] dataContainerURL`; nil is handled with a log. [I] The throw is inside LaunchServices. Not traced. Effect on a page: [I] none; Safari history may not save |
| `webbookmarksd` every 56-108 s | `dispatch_mach_msg_async_reply_invoke` -> `dispatch_client_callout3` | [V] An uncaught exception in an XPC reply; 2 of these in boot 19:07 as well. Handler [U]: the frames are gone. Not a cause of this fault |

Text of both, now that SSH works: `scripts/net/phone-log.sh webbookmarksd`, or `... com.apple.Safari.History com.apple.Safari.SafeBrowsing.Service`; read `Terminating app due to uncaught exception`.

### What changed

- `root-add-ssh.py`: no `usbnetcfg` job at boot. USB service without router and DNS, rank Last, last in the order. `share-internet.sh` runs `usbnetcfg up` / `down` over SSH; `usbnetcfg` writes `PrimaryRank` Last ([V] the string and the Last/Never values are in `configd` 20H392), and no longer adds a route while another service is primary. `USBNET_INTERNET=1` at the root build: the job at boot, for a phone with no Wi-Fi.
- `laurelnet` (new): the status line. It wakes only when configd changes a key; no traffic. Kill switch `laurelnet=0`.
- 2888: `dns asked N (v6 N) answers N (v6 N)`.
- SSH: `docs/usb-network.md` "Login": repo key, stock password as fallback.

### Build [V]

Kernel on 7737e7d + this branch: `applied=299 known-skip=0 failed=0`, 0 LSE/RCpc, `printf-arg-check: OK`, 2 linker lines (stub rounds), sha256 8be3ddf608297eeb, series d2ddb8c409e44a87.
`userland/ssh/build.sh` (Linux): `laurelnet` and `usbnetcfg` built, signed, 0 instructions newer than ARMv8.0. `root-dry-run.sh`: PASS, 13 features installed, 0 missing, `USB network + SSH login PASS`. `build-honest-test.sh`: 60 of 60.
Host test (no phone): host dropbear + `phone-ssh.sh`: repo key logs in with `-s`; on a server without the key, the password path runs with no terminal and does not hang (`Permission denied (publickey,password)` for a wrong password).

### Expected lines

```
LAUREL NET: on: default route en0 via 192.168.1.1, v6 en0 via fe80::1, dns 2 servers 192.168.1.1 8.8.8.8, reachability yes (flags 0x2)
LAUREL WIFI: path | tcp sent 412 retrans 0 timeouts 0 dup in 0 | connects 22 | dns asked 18 (v6 6) answers 18 (v6 6) | v4 out .. in .. | v6 out .. in .. | sender waited 0 times
connectx() - failed necp_set_socket_domain_attributes       (as in boot 19:07: only a note, the connect goes on)
```

The numbers are the form, not results. No `exec usbnetcfg` line. Before the join: `LAUREL NET: on: default route none, v6 none, dns 0 servers, reachability no (flags 0x0)`.

### Owner's test

1. **No build, on the phone that runs now, cable in, Wi-Fi joined:** `scripts/laurel/phone-ssh.sh '/usr/local/bin/usbnetcfg show; /usr/local/bin/usbnetcfg down; /usr/local/bin/usbnetcfg show'`. Login: this script gives `alpine`. Read the first `State:/Network/Global/IPv4`: `PrimaryInterface` ue0 proves the cause. After `down`: en0. Then open fast.com. If the page loads: cause proven. The fix lasts until the next boot.
2. Rebuild: root (flash needs your approval) and kernel (for 2888 only). Boot, join. Read the `LAUREL NET:` line: `default route en0`. Open fast.com and speedtest.
3. If `default route en0` and a page does not load: read `path` next: `dns asked` above 0 with `answers` 0: DNS on Wi-Fi; `connects` above 0 and `tcp sent` low: TCP. Then boot with `wifi_txq=0` and compare, and add `net_names=1`.

### Unproven [U]

That ue0 was primary in boot 22:35 (test 1 decides it). That pages load at full speed on the output-queue model. That IPMonitor honours `PrimaryRank` Last under `share-internet.sh` ([V] configd has the key; not run). `laurelnet` has never run: it is built and signed, and `SCNetworkReachabilityGetFlags` on the zero address is [I] the usual app check.
