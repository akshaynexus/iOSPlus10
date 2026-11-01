# Mi A3: AirPlay and AirDrop (2026-11-01, branch t3/laurel-airplay-airdrop)

Owner: "AirPlay and AirDrop both aren't working: enable or fix them." iOS 16.7.16 20H392, WCN3990, firmware `WLAN.HL.3.0.2.c1-00050-QCAHLSWMTPLZ-1`.
Status: [V] builds, host tests and dry run pass. [U] not run on the phone. Labels: [V] read in source, a binary or a log; [I] inference; [U] unknown.
Tools: `scripts/debug/air-re.sh` reads the Apple files into `out/air-re/` (git-ignored). Log: `logs/laurel-boot-2235.txt` (main checkout).

## 1. Result

| Feature | State after this change | What decides it |
| --- | --- | --- |
| AirPlay audio to a receiver on the LAN | [U] no blocker found in the code; **no fix was possible without a run log** | `LAUREL AIRPLAY:` line, then section 7 |
| AirPlay video by URL (a video app sends the link) | [U] same discovery path; needs no encoder [I] | same |
| Screen mirroring | **Off.** No `AppleAVE2Driver`, so no H.264 encoder of the normal path | section 3 |
| Apple TV / HomePod | [I] likely fail at `/fp-setup` or at PTP | section 3 |
| AWDL, awdl0, `wifip2pd` | **Off.** `LAUREL AWDL: off: ...` No AWDL data path on this hardware and driver | section 4 |
| AirDrop with an iPhone or a Mac in its normal state | **Not possible now**: they use AWDL | section 4 |
| AirDrop on en0, with opendrop on a PC or another phone of this port | New, on by default, [U] not run | section 5 |

What this change does not do: it does not make AirDrop work with iPhones. It does not make mirroring work. It adds no AirPlay code path: Apple's sender is already in the root and already runs.

## 2. AirPlay: what iOS needs, stage by stage

The sender lives in `mediaserverd`: its job has the Mach services `com.apple.airplay.sender.xpc`, `com.apple.airplay.receiver.services`, `com.apple.airplay.apsynccontroller.xpc` [V launchd.plist]. No `airplayd`: no such job, no `/usr/libexec/airplayd`, no `exec` in the log [V].

| Stage | Needs | On the Mi A3 | Mark |
| --- | --- | --- | --- |
| Discovery | `APBrowser` + `APBonjourBrowser` in APTransport: `_airplay._tcp`, `_raop._tcp`, also AWDL and NAN variants | `mediaserverd` asks en0 for its media at 22:35:56 and 22:36:04 (`net: en0 is asked 0xc02c6938`, SIOCGIFMEDIA): the code looks at en0. [I] that is the AirPlay network code; the log does not name the caller | [V] asks, [I] who |
| mDNS | `mDNSResponder` up; en0 with multicast | `exec mDNSResponder` 22:35:57, `privilege 10001 granted` 22:35:58. en0: `IFF_MULTICAST`, `SIOCADDMULTI` accepted (`redwood_net.c`), subfamily Wi-Fi, `IFM_IEEE80211`. `v4 in` 114-119 per minute with `tcp sent 0`: broadcast or multicast arrives [I] | [V] code, [I] traffic |
| Route on en0 | IPv4 on en0 | `exec usbnetcfg` in this boot made ue0 first: `dns asked 0`, `connects 0` after the first minute. Agent t3/laurel-safari-net found and fixed this (`wifi.md` "No page loads"). A receiver on the LAN is on-link, so discovery may still work [I]. **Test AirPlay on a root with that fix** | [V] log, [I] effect |
| Solo / P2P | `browser_queryP2PSoloSupport`, WiFiPeerToPeer | `Query for Solo support failed` is only a log line [V string]; [I] the browse goes on without it | [I] |
| Filters | `browser_skipBonjourUpdate` | `NAT present between devices. Ignoring device`, `Ignoring device found unpaired`, `that does not belong to this network`: a receiver can be heard and still not listed [V strings] | [U] which applies |
| Pairing | `/pair-setup`, `/pair-verify`: CoreUtils, keychain groups `com.apple.airplay`, `com.apple.airplay.pairing` | The keychain works through AKS stand-ins here; not tried for AirPlay | [U] |
| Authentication | `APAuthenticationClientFairPlay`, `/fp-setup`, `### FP-Setup failed`; also `APAuthenticationClientMFi`, `...RSA` | `fairplayd.H2` is out (`system-features.md`); the kernel has no `com_apple_driver_FairPlayIOKitUserClient` (HackiOS `mkjobs.py`) | [V] missing, [I] effect |
| Clock | `APSNetworkClockPTP`, `APSRealTimePTPClockCreate failed`; CoreMedia names `IOTimeSyncDomain` | No `IOTimeSync` class in our kernel tree: grep 0 | [V] missing, [I] effect on buffered audio |
| Audio route | HAL plug-in `AirPlayHalogen.driver` | In `/System/Library/Audio/Plug-Ins/HAL` beside `RedwoodAudio.driver`; `root-audio.sh` does not move it | [V] file, [U] loaded |
| Control Center | `AirPlayMirroringModule.bundle`, `MediaControlsAudioModule.bundle` | `UIRequiredDeviceCapabilities` is `arm64` only: no MobileGestalt key hides these buttons [V Info.plist] | [V] |
| MobileGestalt | `_MobileGestalt_get_airplayMirroringCapability` exists | `AirPlayCapability` from the task text: no such key found (MD5 hash not in libMobileGestalt; the hash of `AirDropCapability` is found). The value on this phone is not logged | [V] search, [U] value |

Finding: **I found no static blocker for discovery and audio on en0.** The USB log has no `mediaserverd` os_log lines, so it cannot show where AirPlay stops. So this change adds the check, and section 7 reads the real log. I did not guess a fix.

### Why no key or preference was changed

Each candidate fix would be a guess: a MobileGestalt key that no code path needs, or `fairplayd` back. `fairplayd` back is a known harm: requests queue for ever and locationd deadlocks (`system-features.md`, flame HANDOFF 238-245). So it stays out.

## 3. Out of reach for AirPlay, with the reason

| What | Why | Way forward |
| --- | --- | --- |
| Mirroring | `AppleVideoEncoder.bundle` (`AVE_CreateInstance`, `H264VideoEncoderVA_DriverCreate`) talks to `AppleAVE2Driver` / `AppleAVEDriver`: `AppleAVEVA ERROR: kAVEUserClientOpen failed` [V strings]. No such driver here. The SM6125 Venus encoder has no driver | The HEVC decoder precedent (`hevc.md`: software in an empty VideoToolbox slot) shows a route: a software H.264 encoder as a VideoEncoder bundle. VideoToolbox names `com.apple.videotoolbox.videoencoder.h264.rtvc.sw` [V string]; whether AirPlay can select it is [U]. Also needed: a virtual display in backboardd's redwood GL path [U]. Large, separate work. CPU on Kryo 260 at 720x1560 is [U] |
| Receivers that ask for `/fp-setup` | No FairPlay hardware path, no user client | None known [I] |
| PTP buffered audio | No `IOTimeSyncDomain` | [U] a kernel class would be new work, only if the log shows that it blocks |
| AirPlay over AWDL (no shared network) | No AWDL | section 4 |

## 4. AirDrop: AWDL on this hardware

### What AWDL needs

Discovery by BLE, then AWDL on `awdl0`: PSF and MIF action frames, election, 16 TU availability windows, channels 6, 44, 149, and **802.11 data frames** with BSSID `00:25:00:ff:94:73` both ways [V `external/owl/src/frame.h`, `docs/airdrop-plan.md`].

### Evidence

| Question | Answer | Mark, source |
| --- | --- | --- |
| What OWL needs | "Wi-Fi card with *active* monitor mode ... frame injection", Atheros AR9280 recommended | [V] `external/owl/README.md` |
| Monitor Tx in the vendor driver for this chip | `/* Monitor mode net_device_ops, doesnot Tx and most of operations. */`: no `ndo_start_xmit` | [V] qcacld-3.0 `core/hdd/src/wlan_hdd_main.c` in `laurel-kernel-los` |
| Injection by firmware, upstream | Michal Kazior: "official firmware doesn't support injecting packets via monitor vdev. This is a firmware limitation." | [V text] [ath10k list, 12 May 2015](https://lists.infradead.org/pipermail/ath10k/2015-May/005209.html): older chips; [I] for WCN3990 |
| Monitor at all on WCN3990, upstream | Kalle Valo: "I doubt that WCN3990 firmware supports monitor mode, though just guessing here."; Mohammad Rasim: qcacld-3.0 commits "did contain hints that monitor mode" and "packet injection should work" | [V text; both are guesses, not tests] [ath10k list, 12 Aug 2024](https://lists.infradead.org/pipermail/ath10k/2024-August/016001.html) |
| Monitor Rx in the vendor driver | Exists: `FEATURE_MONITOR_MODE_SUPPORT`, `hdd_mon_rx_packet_cbk`. Firmware bits on our image not known | [V] source, [U] our firmware |
| Action frames Tx | `WMI_SERVICE_MGMT_TX_WMI` 76, `OFFCHAN_TX_WMI` 123. The join already sends auth and assoc through WMI. A foreign BSSID is [U] | [V] ids, `LAUREL AWDL` line prints the bits |
| AWDL frames Rx without monitor | `MGMT_RX` brings beacons in scans [V log]. Action frames of a foreign BSSID: [U]. `WMI_SCAN_FILTER_PROMISCOUS` 0x100 and `RX_PROMISC_ENABLE_SUPPORT` 145 exist in fw-api; [U] on our image | self-check counts them |
| AWDL data frames | Normal paths need a firmware peer on a vdev; HTT Rx from an unknown peer: [U]. IBSS vdev: ath10k lists `ADHOC` for TLV firmware; with this BSSID, foreign peers and no IBSS beacons: untested anywhere that I found | **the blocker** [I] |
| Timing | Firmware owns the radio. Channel changes only through scans (dwell 110-150 ms here) or a vdev; one thread polled about 1 ms. OWL can stay on one channel | [V] code, [I] effect |
| NAN | `gEnableNanSupport=1` in the stock `WCNSS_qcom_cfg.ini`. NAN frames are not AWDL frames | [V] file, [I] no help |
| What wifip2pd looks for | IOService property `IO80211VirtualInterfaceRole` (`AirLink`), `IOPropertyExistsMatch`, `because there is no AWDL interface`, `Unable to create AWDLInterface for`, 158 `apple80211` strings | [V] strings, `docs/airdrop-plan.md` 1.1 |
| wifip2pd job | Stock plist: only `MachServices` `com.apple.wifip2pd`, `EnablePressuredExit`; **no KeepAlive**. So launchd does not restart it by itself: a client asks again. [I] the 10 s gap is launchd's throttle | [V] plist, [I] gap |
| Negroni's code | Patch 0347: 2230 lines for WCN6855: PSF, MIF, election, peer table, only while en0 idle. **Compiled, never run.** No data path. wifip2pd: only `AWDL_SYNC_ENABLED` answered | [V] `patches/xnu/README-wifi.md` |
| BLE | `laurel_bt_h4.c` lets LE commands through; `0x204a` answered with size 0, so bluetoothd stays on legacy advertising. Not checked: does sharingd start the advertisement. Bluetooth was connected in this boot (`client control connected`) | [V] code, [U] run |

### Decision: no awdl0

OWL as it stands cannot run: no monitor Tx. A port of negroni's engine would send action frames, but with no data path **no AirDrop can complete**. An awdl0 that carries nothing is worse than none: `mDNSResponder` and `wifip2pd` would use a dead interface [I], and the engine runs only while en0 is idle, so it does nothing in normal use. It would be over 2000 lines of kernel code on the daily Wi-Fi thread with no result for the owner. So I did not port it.

This is **not a proof** that the firmware cannot do AWDL. The firmware's answers on foreign action frames and on IBSS with this BSSID need a phone. The self-check gives the first of these at no risk.

### Kernel: patches 2930, 2931

`LAUREL AWDL` looks at the frames that en0's scans already bring. It sends no command and no frame, so it cannot touch Wi-Fi. Kill switch `awdl=0`. Own rule: the line stays `off` until a data path exists. `wifip2pd` stays out of the root until the line can say `on` (`root-tweaks-perf.py`), so no restart loop. No sysctl, no gate job: nothing could turn it on today.

When to look again: if `first AWDL frame heard` appears, then Rx works. Next step: one IBSS vdev with BSSID `00:25:00:ff:94:73` and a peer, on channel 6, while en0 is idle; a Mac as the other side. If that fails, AWDL is closed on this firmware. Then wifip2pd's AWDL requests (`docs/airdrop-plan.md` section 4, step 6), weeks of work [I].

## 5. The alternative: AirDrop on en0

iOS requires AWDL by default, but sharingd has two preferences [V disasm `out/air-re/sharingd.s`]: `BrowseAllInterfaces` 0x1000ca734 (default = `EnableDemoMode`, false) and `RegisterAllInterfaces` 0x1001b2a00 (default false). `root-airdrop-lan.py` sets both as managed preferences: `/private/var/Managed Preferences/mobile/com.apple.Sharing.plist`. `AIRDROP_LAN=0` skips this. `EnableDemoMode` is not set: its other effects are unknown.

| Peer | Works? |
| --- | --- |
| opendrop on a PC in the same LAN (`opendrop find -i wlan0`, `opendrop receive -i wlan0`) | [U] the design fits: opendrop speaks `_airdrop._tcp` on any interface [I]; TLS with "Everyone" |
| Another phone of this port | [U] |
| Mac with the `BrowseAllInterfaces` setting of its own | [U] on current macOS |
| iPhone or Mac in its normal state | No: they browse on AWDL only [I, public protocol work] |

Cost: while AirDrop is not "Receiving Off", sharingd's HTTPS server also listens on the LAN. It still asks before it takes a file [I].

## 6. Lines

```
LAUREL AWDL: off: boot-arg awdl=0
LAUREL AWDL: off: first AWDL frame heard (channel 6, subtype 0): the firmware passes them to the host; no data path yet
LAUREL AWDL: off: no AWDL data path: the vendor driver's monitor device has no Tx, OWL needs it; WMI mgmt-tx yes, offchan-tx yes, promisc no, nan yes, nan-data no; 0 AWDL frames in 12 scans; wifip2pd stays out
LAUREL AIRPLAY: off: boot-arg airplay=0
LAUREL AIRPLAY: off: no IPv4 on en0 yet: AirPlay here needs infrastructure Wi-Fi (no awdl0)
LAUREL AIRPLAY: off: mDNSResponder refused the browse: error -65537
LAUREL AIRPLAY: off: no com.apple.airplay.sender.xpc: mediaserverd has no AirPlay sender
LAUREL AIRPLAY: off: no receiver heard on en0 (192.168.1.5, default route en0) in 15 s: _airplay._tcp 0, _raop._tcp 0
LAUREL AIRPLAY: on: en0 192.168.1.5, default route en0, _airplay._tcp 2, _raop._tcp 3 heard; sender up; fp-setup off: no fairplayd; buffered audio off: no IOTimeSyncDomain; mirroring off: no AppleAVE2Driver (H.264 encoder)
```

The values are the form, not results. The summary comes 5 minutes after WMI SERVICE_READY. `0 AWDL frames` means something only with an Apple device near, with its AirDrop sheet open: without one it proves nothing. `on` on the AirPlay line says "receivers heard, sender up"; it does not say that a stream plays. Job `com.laurel.airplay`: once at boot, no KeepAlive, 3 tries 5 minutes apart; root-owned, reads only. Kill switch `airplay=0`, root build switch `AIRPLAY=0`.

## 7. Test steps

1. Build a root with `t3/laurel-safari-net` merged (ue0 must not be first). Boot. `scripts/debug/usblog.sh`. Join Wi-Fi. Put an AirPlay receiver on the LAN (Apple TV, HomePod, or a PC with shairport-sync) and an iPhone with its AirDrop sheet open beside the phone.
2. Read `LAUREL AIRPLAY:`. `off: no receiver heard`: check that the receiver and the phone share a LAN, then look for mDNS on the PC: `tcpdump -i wlan0 port 5353` must show queries from the phone. No queries: the fault is on the phone (`LAUREL WIFI: path`, `v4 out`).
3. `on`: open Control Center, press the AirPlay icon on the music tile. Are receivers listed? Choose one and play music. At the same time run `scripts/net/phone-log.sh -g AirPlay mediaserverd` and keep the log: lines with `###`, `FP-Setup failed`, `APSRealTimePTPClockCreate failed`, `Ignoring device`, `does not belong` give the next fix. Report: receiver type, listed or not, sound or not.
4. Press Screen Mirroring: the list should open; choosing a receiver should fail. The log line gives the encoder failure [I].
5. Read `LAUREL AWDL:` after 5 minutes. Report the bits and the frame count. `first AWDL frame heard`: tell me; section 4 "When to look again".
6. Open the Share sheet of a photo, with opendrop running on a PC on the same LAN (`opendrop receive -i wlan0`). Does the PC appear under AirDrop? In the opposite direction: `opendrop find -i wlan0`. Set AirDrop to "Everyone for 10 Minutes" first. To undo: `AIRDROP_LAN=0` at the root build.
7. `top` or `LAUREL CPU TOP`: no `wifip2pd` line; `laurel-airplay` is gone after its result.

## 8. Build results

Built [V] on merge 6c1a1c6238 (base origin/laurel-sprout cad5efb): kernel-linux.sh 303/303 patches (102 laurel), 0 failed, 0 LSE/RCpc, printf-arg-check OK, 2 linker lines (stub rounds), kernel.development.sweet.4k sha256 703751fd0ee8443d, armv80-check 21 (same count as before). laurel-airplay sha256 682a7464ab4b8bce, 0 instructions newer than ARMv8.0, no warnings. wifi-phy-test passed; root-airplay-job and root-airdrop-lan self-tests passed; build-honest-test 60 of 60; root-dry-run (FEATURES=0) PASS. Full root not built: needs sudo.
Not run: the phone, the full root (`sudo`), `FEATURES=1` of the dry run (this worktree has no other stages).
