# Mi A3: AirDrop over AWDL, AirPlay with no FairPlay and no PTP (2026-11-01, branch t3/laurel-airdrop-awdl)

Owner: "AirDrop was ported to Android phones, so it is possible: search the web and use its implementation; fix AirPlay properly."
Status: [V] kernel, daemon and root step build, host tests pass. **[U] nothing here has run on the phone.** Labels: [V] read in source, a binary or a log; [I] inference; [U] unknown.
This file reverses section 4 of `airplay-airdrop.md` ("Decision: no awdl0"). That decision rested on "monitor Tx is the only path". It is not.

## 1. Result

| Feature | State after this change | What decides it |
| --- | --- | --- |
| AirDrop with an iPhone or Mac in "Everyone for 10 Minutes" | **Implemented end to end, [U] not run.** IBSS vdev + `laurel-awdld` + `awdl0` + sharingd's own stack | `LAUREL AWDL:` lines, section 7 |
| AirDrop in "Contacts Only" | Not possible: needs a record signed by Apple. Google has the same limit | Section 2 |
| AWDL beside a joined en0 | Only with the AP on channel 6, 44 or 149, and after one good run alone. Else the line says why | Section 4 |
| AirPlay audio, third-party receiver | **New: legacy session forced.** No PTP, no FairPlay needed, [U] not run | `LAUREL AIRPLAY:` + a receiver |
| AirPlay to Apple TV, HomePod | [U] legacy RAOP path; fails if the receiver asks for FairPlay only | section 6 |
| Screen mirroring | Off with the legacy setting. The encoder was never the blocker: section 6 | `AIRPLAY_LEGACY=0` to try |
| wifip2pd | **Stays out.** It needs Apple80211 AWDL ioctls of Apple's driver. The daemon does its work: section 5 | |

## 2. What Android did: sources

| Fact | Evidence | Mark |
| --- | --- | --- |
| Google's text: "direct and peer-to-peer", works with "Everyone for 10 minutes", Rust. No transport is named | [Google security blog](https://blog.google/security/android-quick-share-support-for-airdrop-security/) | [V] text |
| **Transport is AWDL.** NetSPI's log of a Pixel 10 Pro receiving from a Mac: `Host: [fe80::5c8f:a4ff:fe8e:3e84%awdl0]:46127` and `User-Agent: AirDrop/1.0`, while the Pixel names its side `%mosey0`. Package `com.google.android.mosey`. BLE scan result: Apple 76 (0x4C), TLV 5, 18 bytes | [NetSPI report](https://www.netspi.com/wp-content/uploads/2025/11/google-feature-review-report.pdf) p. "Verification" | [V] text; [I] the Mac wrote `awdl0` in Host |
| Not Wi-Fi Aware: "works with iOS 15" (before iOS 26), strings mention AWDL; nobody has shown AirDrop on NAN | [Hacker News](https://news.ycombinator.com/item?id=46062504), [hada.io digest](https://news.hada.io/topic?id=24654) | [I]: comments, not a capture |
| Pixel 10 Wi-Fi is Broadcom | [ifanr](https://www.ifanr.com/1649528) | [I]: secondary |
| Broadcom firmware of Apple devices has an AWDL engine; BCM4360 firmware has none | [brcmfmac-awdl](https://github.com/andreanicassio/brcmfmac-awdl), [omdrop-bcm4360](https://github.com/bydash-xyz/omdrop-bcm4360) | [V] README |
| So Android is no proof for Qualcomm chips: Pixel may use a firmware engine. **The proof for "no firmware engine needed" is Owly** | below | [I] |

iOS 26 and Wi-Fi Aware: iOS 26 has a Wi-Fi Aware API for apps ([MacRumors](https://forums.macrumors.com/threads/ios-26-adding-two-new-wi-fi-features-allows-airdrop-and-airplay-alternatives.2459419/)). No source shows AirDrop on it. iOS 26 AirDrops to older devices, so AWDL stays [I]. **Answer: the peer's iOS version does not change this design; a recent iPhone in the EU uses AWDL for AirDrop as far as anybody has shown.** This firmware has NAN code (`NAN_Init`, `NAN_CreateNanVdev`, `NAN20_NDP` [V strings of `wlanmdsp.mbn`]), and nothing to do with it for AirDrop.

Other code:

| Project | Pin (`scripts/debug/awdl-sources.sh`) | What it needs of the radio | Firmware part |
| --- | --- | --- | --- |
| [t4t5/owly](https://github.com/t4t5/owly) (was omdrop-owl), MIT | 0f2ca408 | Raw action frames in and out, data frames on BSSID `00:25:00:ff:94:73`, **something that ACKs the phone**. Modes: shared (inject beside the station), exclusive (ad-hoc cell on AWDL's BSSID), active monitor | None: AWDL is all in `owly-awdl`, sans-IO. One channel is enough (`Presence::Fixed`, `Share`) |
| [seemoo-lab/owl](https://github.com/seemoo-lab/owl), GPL-3 | 0ee3263f | Active monitor + injection | None |
| [opendrop](https://github.com/seemoo-lab/opendrop), GPL-3 | 11fe7ba7 | AirDrop over HTTPS on an IPv6 interface | None |
| [omdrop-awdl](https://github.com/netmojo-systems/omdrop-awdl), brcmfmac-awdl | 46ed6e17, ab96d9d7 | Broadcom firmware's own engine | All of AWDL. Not this chip: 0 "awdl" strings in `wlanmdsp.mbn` [V] |
| [omdrop-bcm4360](https://github.com/bydash-xyz/omdrop-bcm4360) GPL-2 | 9c21284a | `wl` patched for raw Tx; a card's own MAC or "lost every ACK" | None |
| [omdrop-owl-windows](https://github.com/dantdmdarealguy/omdrop-owl-windows) GPL-3 | 441920466 | ESP32 promiscuous + raw Tx | None |
| [CrossDrop](https://github.com/jameschern/CrossDrop) | not pinned | README only: its own protocol, no AWDL. Points to [opendrop issue 9](https://github.com/seemoo-lab/opendrop/issues/9) for Android (root) | n/a |

Not read: the arXiv paper "Protocol Prying" (2606.26967): the fetch was refused by a safeguard. The repo `Hotelk52339/nethunter_kernel_google_redbull`: 404. No project "AirDrop on rooted Android with a custom kernel" was found; the nearest are the NetHunter injection kernels below.

Owly's table for Qualcomm [V `drivers.toml`]: AR9287 ath9k works; WCN6855 ath11k "can't create the monitor interface"; WCN7850 ath12k hears nothing in shared mode. All of them through mac80211 monitor interfaces. None tried a cell through its own WMI code.

## 3. WCN3990: each path in the firmware

Firmware `WLAN.HL.3.0.2.c1-00050-QCAHLSWMTPLZ-1`. `wlanmdsp.mbn` keeps function names as strings [V `out/awdl-re/wlanmdsp-strings.txt`, from the backup image].

**Correction: `promisc no, nan yes, nan-data no` in the last report were never measured.** `airplay-airdrop.md` section 6 says "the values are the form, not results", and no log has a `LAUREL AWDL` line (grep of `logs/*`: 0). How the kernel would derive them: `wmi_svc()` reads SERVICE_READY (4 bits a word, as ath10k `WMI_SERVICE_IS_ENABLED`) for ids below 128, `SERVICE_AVAILABLE` from 128: 145 `RX_PROMISC_ENABLE_SUPPORT`, 52 `NAN`, 96 `NAN_DATA`, 76 `MGMT_TX_WMI`, 123 `OFFCHAN_TX_WMI` [V fw-api `wmi_services.h`]. The next boot prints real bits.

| Path | Evidence | Verdict |
| --- | --- | --- |
| Vendor monitor device | `/* Monitor mode net_device_ops, doesnot Tx */`: a limit of the **host** driver, not of the firmware. NetHunter kernels add Tx | The old reason falls |
| Monitor vdev, Tx | [qcacld injection patch for WCN3990 (Poco F1)](https://github.com/DX4GREY/kernel_xiaomi_beryllium/pull/1), `wma_frame_inject.c`: firmware "unconditionally rejects management frames on MONITOR vdevs": `_wlan_send_mgmt_to_host` accepts AP, STA, IBSS, OCB. Names exist in our image [V strings] | No Tx. [V text, their RE; I same on our build] |
| Monitor vdev, Rx | `wal_rx_setup_monitor_mode`, `monitor_htt_tgt_rx_ll` [V strings]; qcacld sets raw Rx decap at **WMI INIT** (`wma_main.c:343`). [kimocoder list](https://github.com/kimocoder/qualcomm_android_monitor_mode) names beryllium (WCN3990) as working | Exists; needs another INIT: en0 would have to restart. Not used. Fallback for Rx only |
| WMI mgmt Tx on a started vdev with a self peer | Same patch: helper STA vdev, self peer, **no VDEV_UP** ("wlan_vdev_up asserts unless a BSS peer exists"), then `WMI_MGMT_TX_SEND`; aireplay-ng and mdk4 work with it. "firmware never sends TX-completion" there. A vdev command before create is done asserts: 150 ms pauses | **Used**, on an IBSS vdev. [V text; U our firmware] |
| HTT native-wifi Tx | Works for en0 now [V log]. In native wifi the host's 802.11 header goes out: AWDL data has To DS 0, From DS 0, addr3 BSSID, as IBSS data | **Used** on the vdev [I] |
| Raw HTT Tx | ath10k: only 10.x firmware (`RAW_MODE_SUPPORT`) [V] | Not needed |
| IBSS vdev | ath10k gives TLV firmware `NL80211_IFTYPE_ADHOC` and `ath10k_tlv_if_limit_ibss`: 1 STA + 1 IBSS on **one channel** ("not thoroughly tested") [V `mac.c`]. `wlan_smps_ap_ibss_send_action_frame`, `WIFI_IBSS_NAN_STALL` [V strings]. Owly: "an address to ACK for and a BSSID filter that passes AWDL" | **The path.** It gives ACK, the BSSID filter and per-peer data with no monitor. [U] on this firmware: never run |
| P2P GO/client + NoA | GO frames have From DS 1, client To DS 1: not AWDL's form; a fixed radio needs no schedule | No |
| NAN service | `NAN_CreateNanVdev` exists. Different frames, different clusters, no AirDrop on it | No |
| Offchan Tx, `WMI_SCAN_FILTER_PROMISCOUS` | Scan flags. Radio stays on its channel: not needed | Not used |
| Rx filter for 0x7f vendor actions | `wal_set_public_action_frame_filter`, `wal_set_allbcn_filter`, `wal_set_probe_req_filter` [V strings]: no vendor-action switch named. `WMI_PDEV_PARAM_RX_FILTER` meaning [U] | The cell's BSSID filter should pass them [I, Owly]. **Main unknown**: section 7 |

Decision: **a path exists, so it is implemented.** No firmware limit is proven. Two things only the phone can say: does VDEV_START of an IBSS vdev work; does the vdev pass broadcast action frames of its BSSID.

## 4. Implementation

```
iPhone  <--BLE, AWDL-->  WCN3990 firmware  --WMI/HTT-->  TopazModem.cpp (vdev 1, patch 2932)
                                                           | com.laurel.awdl (kern control)
sharingd, mDNSResponder <--IPv6--> awdl0 (Ethernet) <--> laurel-awdld (owly-awdl Node, MIT)
```

- **Kernel, patch 2932** (`LaurelWifiAwdlRadio.h`: pure, host-tested; `.inc`, `2.inc`, `3.inc`; `bsd/dev/laurel_awdl_ctl.c`). Steps: VDEV_CREATE type 3 -> 150 ms -> self PEER_CREATE -> 150 ms -> VDEV_START (HT20, `ADHOC_ALLOWED`, SSID `awdl`) -> START_RESP -> ATIM 0, beacon template, VDEV_UP with `00:25:00:ff:94:73`. Teardown: DOWN, STOP, wait VDEV_STOPPED, peers, VDEV_DELETE (the firmware asserts when a self peer goes first: patch notes). Per peer: PEER_CREATE, 150 ms, PEER_ASSOC (legacy + MCS 0-7, because an iPhone's unicast comes at HT rates: Owly `setup.rs`), AUTHORIZE. Tx action: 8 DMA slots in a ring, no wait for completion. Rx: action frames with AWDL's OUI and ADDBA requests; data by HTT `vdev` byte or BSSID.
- **en0 comes first.** `w_join_poll` waits for `ar_active()` to end: a join ends the cell first. PEER_STA_KICKOUT tears en0 down only for the AP's MAC (before: any peer). The radio uses vdev 1 only. Joined on the same channel: same channel spec as en0 (ath10k: one channel), and only after a good run alone.
- **`laurel-awdld`** (`userland/laurel/awdl`, Rust, 369 kB, no crates.io, links only libSystem). `run.rs`: when; `session.rs`: Node loop; `wifi.rs`: native wifi to Owly's form (QoS field + padding out; the firmware has split A-MSDUs); `proxy.rs`: Neighbor Advertisement for a peer (AWDL carries no ND, NET-2), `_airdrop._tcp` records for each valid peer (iPhone's mDNS does not reach a non-Apple node, DISC-5), drops RS and MLD; `policy.rs`: state file, channels, trigger.
- **Trigger:** sharingd's `DiscoverableMode` is Everyone (receive), or bluetoothd set an AirDrop advertisement in the last 120 s (send): kernel note in `lbt_local_answer` (HCI 0x2008/0x2037 with `FF 4C 00 05`). Not in use for 30 s with no peer: the vdev goes.
- **Channel:** 44, 149, 6 as in Owly's default order. No AWDL frame for 20 s: next channel.
- **Self-check, no fake state:** `awdl0` is made only after the first AWDL frame. `/private/var/db/laurel-awdl.state`: `trying-alone` before the first start, `alone-ok` after 10 s alive with no modem crash (`fw_fatal` in the status); the firmware refusing the vdev 3 times ends it until the next boot; a boot that finds `trying-*` stops the feature with one line (a firmware assert takes Wi-Fi until reboot, and en0 must not lose every boot). `rm` the file to try again.
- **Sharing:** `BrowseAllInterfaces` + `RegisterAllInterfaces` (already in the root) make sharingd browse and serve on all interfaces [V disasm, `docs/airdrop-plan.md`]. mediaserverd and sharingd run as `mobile` [V launchd.plist]. awdl0 has no `IFEF_AWDL`: nothing treats it as Apple's [I].

**Risk to Wi-Fi, stated plainly:** "a failure never touches Wi-Fi" holds for every failure the host can see. A firmware assert in VDEV_START would stop the modem until reboot; the driver has no restart. Limits: the first run needs AirDrop to be used and en0 not joined; the state file stops a second try. **The owner should do the first test on a boot where losing Wi-Fi until the next reboot is acceptable.** Kill switches: `awdl=0`, root `AWDL=0`.

## 5. wifip2pd

It controls AWDL by `APPLE80211_IOC_AWDL_*` on Apple's driver and events `APPLE80211_M_AWDL_*` (over 100 kinds, `docs/airdrop-plan.md` 1.1). The daemon replaces it: sharingd's AirDrop path needs none of it with the two preferences [V strings: `BrowseAllInterfaces`; I no other wait]. Other users of AWDL (Auto Unlock `_startAWDLWithInfo`, Handoff ranging) stay off. No self-check can bring wifip2pd back until those ioctls exist, so it stays out. [U] if sharingd itself wants a wifip2pd answer in some path: the log will show it.

## 6. AirPlay in 20H392

Disassembly: `scripts/debug/airplay-disasm.sh` + `airplay-xref.py` (strings on each adrp + add) [V addresses in AirPlaySender].

| Stage | Found | Fix |
| --- | --- | --- |
| Session choice | `endpoint_shouldUseLegacySenderSession` 0x1bf805f.. reads a once-value from `endpoint_getSessionProtocolOverrideString` 0x1bf809f1c: `APSSettingsCopyValue("sessionProtocolOverride")`, domain `com.apple.airplay` [V 0x1bf92985c]. `"legacy"`: "Using APSenderSessionLegacyAudio because of defaults write". `"airplay"`: the other. Else legacy speakers only | **`root-airplay-legacy.py`: managed preference `legacy`.** On by default, `AIRPLAY_LEGACY=0` |
| Clock | `endpoint_getPreferredNetworkClockType` 0x1bf807f..: PTP only if `PrimaryUsage` and "Receiver supports PTP"; else NTP. `APSNetworkClockNTPServerCreate`, "Client started senderNetworkClock NTP server on port" are in the legacy session | Legacy: no `IOTimeSyncDomain`. A stand-in for it is not needed for this path |
| Authentication | `sdpsession_ensureAuthenticated` 0x1bf760fe0: a receiver property: 1 RSA (`APAuthenticationClientRSACreate`, 0x1bf761088), 4 FairPlay (0x1bf7610d8), 8 MFi (0x1bf7610b0), else none | Third-party RAOP receivers ask RSA or none [I]: no fairplayd |
| FairPlay | `fairplayd.H2` stays out (locationd deadlock, flame HANDOFF 238-245). No `com_apple_driver_FairPlayIOKitUserClient`: Apple's kext is not in an open XNU, so no stand-in can make its keys [I] | Receivers that demand `/fp-setup`: stays impossible |
| Discovery | `_airplay._tcp`, `_raop._tcp` on en0. The USB route bug is gone in this base (`eff50d7`). `browser_skipBonjourUpdate`: "without pairing ID", "does not belong to this network", "found unpaired" are in `APBonjourCacheManager` [V] | [U] which applies: run log |
| Mirroring encoder | **Apple has a software H.264 encoder**: `H264VideoEncoder_CreateInstance`, `JVTLibCompEncodeFrame`, `com.apple.videotoolbox.videoencoder.h264.rtvc.sw` [V cache strings]. So no plug-in, no openh264 (BSD, no patent cover from source) or x264 (GPL): none is needed for the first try | The blocker is the screen source (`FigVirtualDisplay`, backboardd's GL path) [U] and `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` if asked [U]. Not implemented; `AIRPLAY_LEGACY=0` lets the owner see the failure |
| Route selection | `AirPlayMirroringModule`, `MediaControlsAudioModule` have no capability filter [V earlier] | Nothing to change |

The `LAUREL AIRPLAY` line now says `session legacy` and `hardware encoder no`, not "mirroring off: no H.264 encoder", which was wrong as a cause.

## 7. Lines and how to read them

The values are the form, not results.

```
LAUREL AWDL: firmware: WMI mgmt-tx yes, offchan-tx yes, promisc no, nan yes, nan-data no, ibss-ps yes; 0 AWDL frames in 12 scans, 0 on the vdev     (5 minutes after SERVICE_READY)
LAUREL AWDL: first AWDL frame heard in a scan (channel 44, subtype 0): the firmware passes them to the host
LAUREL AWDL: on: IBSS vdev up on channel 44, alone: no AWDL frame heard yet
LAUREL AWDL: on: AWDL node up on channel 44 (alone)
LAUREL AWDL: on: first AWDL frame heard on the vdev, channel 44, subtype 0: the firmware passes foreign action frames
LAUREL AWDL: on: interface awdl0 made
LAUREL AWDL: on: awdl0 up with its link-local address
LAUREL AWDL: on: AWDL peer aa:bb:cc:dd:ee:ff class 2: Johns-iPhone
LAUREL AWDL: off: the firmware refused VDEV_START of the IBSS vdev (3): en0 not touched
LAUREL AWDL: off: no VDEV_START answer in 2 s on this MHz (5220): en0 not touched
LAUREL AWDL: off: the firmware did not answer or the modem stopped during the start: Wi-Fi may be gone until the next boot; the state file keeps this off
LAUREL AWDL: off: the modem stopped while the AWDL vdev was on: Wi-Fi may be gone until the next boot
LAUREL AWDL: off: the firmware refused the IBSS vdev 3 times: off until the next boot
LAUREL AWDL: off: en0 needs the radio: a join or a change of AP comes first (5220): en0 not touched
LAUREL AWDL: off: en0 is joined on a channel that AWDL does not use (AWDL needs 6, 44 or 149), and only one channel is possible
LAUREL AWDL: off: the cell must run once with en0 not joined before it runs beside en0
LAUREL AWDL: off: the last start did not finish (trying-alone): the firmware may have stopped; `rm /private/var/db/laurel-awdl.state` tries again
LAUREL AWDL: off: AirDrop is not in use: rx 812 mgmt 40 data, tx 410 mgmt 35 data, full 0
LAUREL AWDL: off: boot-arg awdl=0
LAUREL AIRPLAY: on: en0 192.168.1.5, default route en0, _airplay._tcp 2, _raop._tcp 3 heard; sender up; session legacy; fp-setup off: no fairplayd; buffered audio off: no IOTimeSyncDomain; hardware encoder no
laurel-root: awdl: /usr/libexec/laurel-awdld installed (...), job com.laurel.awdl
```

| Log | Meaning | Next |
| --- | --- | --- |
| No `IBSS vdev up`; `TopazModem` modem crash line | Firmware assert on the IBSS vdev: **firmware limit shown**. Wi-Fi back at reboot; the state file keeps it off | Try subtype or STA helper vdev (qcacld's path) with Rx by monitor; report the crash line |
| `IBSS vdev up`, `0 on the vdev` with an iPhone in AirDrop near | The BSSID filter does not pass foreign action frames | Next tries, in order: `WMI_PDEV_PARAM_RX_FILTER` 0x55; `WMI_SCAN_FILTER_PROMISCOUS` single-channel scan; monitor vdev with raw decap (needs its own WMI INIT) |
| Frames heard, `AWDL peer ...` lines, iPhone does not list us | Our PSF/MIF do not reach it, or BLE/HTTPS fails. A second radio on a PC with `tcpdump -I` on channel 44 shows if our frames go out | Report `tx ... mgmt`; `oslogstream -g AirDrop sharingd` |
| Peer listed, transfer stalls | Data path: no-ACK cannot be set on HTT here (Owly uses it on fixed radios), retries delay; or `PEER_ASSOC` rates | `rx ... data` count; read the `LAUREL WIFI: link` line |

What would have to be true for AirDrop to complete, all [U]: (1) IBSS VDEV_START works on this firmware; (2) WMI mgmt Tx on it sends broadcast action frames with BSSID `00:25:00:ff:94:73`, unchanged; (3) the vdev passes foreign broadcast action frames up; (4) a firmware peer per AWDL peer passes HT data both ways, with ACK; (5) bluetoothd's legacy advertising sends sharingd's TLV 5, and sharingd asks for it with no `wifip2pd`; (6) sharingd's HTTPS works on awdl0 under `RegisterAllInterfaces`.

## 8. Test steps (owner; no flash without your approval)

Prepare: Build root with this branch (`build-all.sh`, then `root.sh`) and kernel. First boot: losing Wi-Fi until reboot must be acceptable.

1. Boot. `scripts/debug/usblog.sh`. **Do not join Wi-Fi** (forget the network, or be out of range). Read `LAUREL AWDL: firmware:` after 5 minutes: real service bits.
2. An iPhone beside the phone. On the Mi A3: AirDrop "Everyone for 10 Minutes". Expect `IBSS vdev up on channel 44`. No crash: 10 s later the state file says `alone-ok`: `scripts/laurel/phone-ssh.sh cat /private/var/db/laurel-awdl.state`.
3. On the iPhone open a photo's Share sheet. Expect `first AWDL frame heard on the vdev`, `awdl0 up`, `AWDL peer`. If 20 s pass with no frame: the next channel; the line repeats. Does the iPhone show "Mi A3" under AirDrop? Send the photo. Report.
4. Opposite direction: set the iPhone to "Everyone for 10 Minutes". On the Mi A3 open the Share sheet of a photo. Does the iPhone appear? (`ble_age` starts the radio.)
5. Join a network with the AP on channel 44, 149 or 6 (or set the router). Repeat 3. A router on another channel: the line says why, and en0 goes on.
6. Wi-Fi check: at any step, join a network: the cell ends first; `LAUREL WIFI: join` follows within about 1 s.
7. AirPlay: PC on the same LAN with `shairport-sync` (classic build, AP1). Read `LAUREL AIRPLAY: on: ... session legacy`. Control Center, music tile, AirPlay icon: is it listed? Play. `scripts/net/phone-log.sh -g AirPlay mediaserverd` shows `Using APSenderSessionLegacyAudio because of defaults write`, `Client started senderNetworkClock NTP server`. Then try an Apple TV or HomePod: report the `###` line.
8. To undo: `awdl=0` (boot-arg) or `AWDL=0`, `AIRPLAY_LEGACY=0` at the root build.

## 9. Build

Built [V] on merge ce31b60 (origin/laurel-sprout 2bb0c84 + this branch): kernel-linux.sh 308/308 patches, 0 failed, 0 LSE/RCpc, printf-arg-check OK, kernel.development.sweet.4k sha256 6c80416eb01a80e4. laurel-awdld 369 kB sha256 3baf40e673203252, links only libSystem, 0 instructions newer than ARMv8.0; laurel-airplay sha256 1b2ae1cfad5f6f4a. Host tests: `cargo test` 13 of 13, wifi-phy-test passed, build-honest-test 60 of 60, root-dry-run (FEATURES=0) PASS. Not run: the phone; the full root (`sudo`); `FEATURES=1` of the dry run.
The host test proves the daemon's use of owly-awdl; it says nothing of the radio.

Base: this branch started at `origin/laurel-int-1` (3c43cd1) because `origin/laurel-sprout` then lacked 2930/2931 and the USB route fix; it is now merged with `origin/laurel-sprout` 2bb0c84, which has both.
