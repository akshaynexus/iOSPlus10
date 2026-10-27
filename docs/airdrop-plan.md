# AirDrop plan (iOS 16.7.16 20H392 on the NE2211)

Goal: AirDrop between this phone and real Apple devices (send and receive).
Marks: **[V]** seen (source given), **[I]** inference, **[U]** unknown (a test must answer it).

Status (2026-10-27): patch 0347 grew from the AWDL probe into the **in-kernel AWDL engine** (path A): a kernel port of
seemoo-lab/owl (GPL-3.0, pin `0ee3263f`) in `bsd/dev/negroni_awdl_owl.{c,h}`, driven by `bsd/dev/negroni_awdl.c` on the
Wi-Fi driver thread. It parks on channel 6 only while en0 is idle, sends PSF (110 TU)/MIF by `WMI_MGMT_TX_SEND` from its
own DMA slots, parses RX AWDL frames into a peer table, runs the master election, and gates awdl0/AirLink on the first
received AWDL frame (NO PROBES). Default on; kill switch `negroniawdl=0`. **[V] it compiles** (full local build
`out/kernel/local-20261027-132548/kernel.development.negroni, sha256 6eb97ddfbd540f11c20088b612b1ccd7b0194874a374c3568f10f8e8ac6af7f2 (all patches 0200-0386 applied, none skipped)`). **[U] it has not run on the phone** (no-phone task), so the firmware questions in section 2 stay open
(does WCN6855 send our offchan action frames, does it pass foreign AWDL frames to the host). Steps 2-5 below now exist in
code and wait for a phone test; steps 6-7 (wifip2pd answers beyond SYNC_ENABLED, mDNS, transfer) are next.

## 1. What AirDrop needs on iOS 16

AirDrop = discovery over Bluetooth LE + transfer over AWDL (Apple Wireless Direct Link). The chain:

1. Sender: sharingd sends a BLE AirDrop advertisement (contact hashes). Receivers that are visible
   ("Contacts Only" / "Everyone for 10 Minutes") see it and start AWDL. [I: public protocol work,
   Stute et al. 2019 "A Billion Open Interfaces for Eve and Mallory"]
2. wifip2pd starts AWDL on `awdl0`: synchronization (PSF/MIF action frames, availability windows),
   master election, channel sequence. On Apple hardware the Wi-Fi firmware does the timing. [I]
3. Both sides get IPv6 link-local on `awdl0`. mDNSResponder browses `_airdrop._tcp` on `awdl0`
   (also through its D2D plug-in, which carries Bonjour records inside AWDL frames). [V strings]
4. The sender connects with HTTPS (TLS, Apple ID certificates or self-signed in "Everyone") to the
   receiver's AirDrop server: `/Discover`, `/Ask`, `/Upload`. [I: opendrop implements this]

### 1.1 Who does what (20H392 binaries, out/research/airdrop, out/research/wifid; Apple files, git-ignored)

| Part | What we saw | Mark |
|---|---|---|
| `IO80211.framework` `__isVirtualInterface` (0x1d3ed3bf0) | reads the registry property `IO80211VirtualInterfaceRole` and compares it with `"AirLink"` (= AWDL), `"WiFi-Aware Discovery"`, `"WiFi-Aware Discovery+Data"`, `"WiFi-Aware Data"`, `"SoftAP"` | [V disasm] |
| `IO80211.framework` `Apple80211BindToInterfaceWithService` | `IOServiceOpen` first (user client); on failure the ioctl path with `IOInterfaceName` (same as en0 today) | [V disasm] |
| `IO80211.framework` | strings `unsupported %s ioctl on awdl0 for %s[%d]`, `unsupported get for %s on awdl0` | [V strings] |
| `/usr/libexec/wifip2pd` (Swift, CoreP2P) | owns AWDL and NAN. Imports `Apple80211BindToInterfaceWithService`, `Apple80211RawGet/RawSet`, `Apple80211RawP2PEventMonitoringInit`, `IOServiceAddMatchingNotification`, `IORegistryEntryCreateCFProperty`, `if_nametoindex`, `getifaddrs`. Strings: `IO80211VirtualInterfaceRole`, `IOPropertyExistsMatch`, `IOInterfaceName`, `because there is no AWDL interface`, `because its not a WiFi interface`, `because no interface index found`, `Unable to create AWDLInterface for` | [V strings, imports] |
| wifip2pd and awdl0 | wifip2pd does **not** create awdl0. It creates only the NAN data interface and the "companion low latency" interfaces (`llw0`, `llw1`, `APPLE80211_IOC_COMPANION_SKYWALK_IF_CREATE` 293). On Apple hardware the Wi-Fi driver makes awdl0 at start. | [V strings; I: "driver makes it" from macOS behaviour] |
| wifip2pd and the driver | AWDL control = Apple80211 requests on awdl0: `APPLE80211_IOC_AWDL_*` (116-168, 201-225, 341: sync params, sync enabled, service params, election, channel sequence, BSSID, OUI, master channel, peer database, statistics, ...), event codes `APPLE80211_M_AWDL_*` (availability window start, sync state, action frame RX, ...). Structure names in wifip2pd: `apple80211_awdl_sync_channel_sequence`, `apple80211_awdl_srv_info`, `apple80211_awdl_strategy`, ... | [V strings, out/research/wifid/ioctl_names.txt, event_names.txt] |
| `mDNSResponder` | `IOPropertyMatch` `IO80211VirtualInterfaceRole` = `AirLink`; `getExtendedFlags: SIOCGIFEFLAGS` (IFEF_AWDL); D2D plug-in (`D2D_start_advertising_interface`) | [V strings] |
| XNU | `IFEF_AWDL` 0x00100000; `ifnet_set_eflags(ifp, IFEF_AWDL, IFEF_AWDL)` also sets `IFEF_LOCALNET_PRIVATE`, `IFEF_IPV6_ND6ALT`, `IFEF_RESTRICTED_RECV` (`IFEF_AWDL_MASK`, bsd/net/if_private.h, kpi_interface.c:698-740) | [V source] |
| `/usr/libexec/sharingd` | AirDrop. `awdl0` interface index lookup (`awdlInterfaceIndex: getifaddrs failed`); `Bonjour browser failed to find awdl0 interface`; HTTP server bound to awdl0 (`kCFHTTPServerBoundInterfaceIdentifier`) unless `registerAllInterfaces`/`enableDemoMode` (then `kCFHTTPServerAllInterfacesIdentifier`) | [V disasm 0x1000b4c4c] |
| sharingd pref `BrowseAllInterfaces` | bool, domain `com.apple.Sharing` (managed prefs path `/private/var/Managed Preferences/mobile/com.apple.Sharing` first), default = `EnableDemoMode` (false); read once and cached. When true, the AirDrop browser skips the awdl0 lookup and browses on all interfaces | [V disasm 0x1000ca704, 0x10011d140] |
| Bluetooth | sharingd checks Bluetooth and Wi-Fi state (`errorCodeForBluetoothEnabled:wifiEnabled:...`); BLE advertising goes through bluetoothd -> our H4 shim; 0338 translates legacy advertising commands to the extended ones | [V strings, README-bluetooth.md 0338] |
| Phone now | `wifip2pd` restarts every 10 s (no AWDL/P2P interface) | [V t21 log, README-wifi.md 0345] |

### 1.2 What the driver must give iOS for AWDL

1. A BSD interface `awdl0` with `IFEF_AWDL`, Ethernet framing, 802.11 media (SIOCGIFMEDIA), its own
   random MAC, IPv6 link-local, multicast (mDNS ff02::fb).
2. An IOService under the IO80211Controller with `IO80211VirtualInterfaceRole` = `AirLink`,
   `IOInterfaceName` = `awdl0`, `BSD Name`, `IOMACAddress` (wifip2pd and mDNSResponder match it).
3. Answers to the `APPLE80211_IOC_AWDL_*` requests on awdl0 (wifip2pd), and the `APPLE80211_M_AWDL_*`
   events (class 6, interface name "awdl0"). The exact list and order are **[U]**: patch 0347 bit 1
   logs them.
4. The AWDL engine: PSF/MIF action frames, election, availability windows, channel sequence, the
   AWDL data frames (802.11 data, BSSID 00:25:00:ff:94:73, LLC/SNAP with OUI 00:17:f2), and the
   peer table (MAC <-> IPv6 link-local).

## 2. What the WCN6855 firmware can do (our driver: WMI TLV, ath11k style)

| Need | Firmware / WMI | Mark |
|---|---|---|
| Send any management frame | `WMI_MGMT_TX_SEND_CMDID` (0x7008); we use it already for AUTH/ASSOC (0327) | [V code; join test running] |
| Send a data frame off-channel | `WMI_OFFCHAN_DATA_TX_SEND_CMDID` (0x7009), service `OFFCHAN_TX_WMI` 123 | [V ath11k wmi.h; U firmware bit] |
| Stay on a channel (listen) | a single-channel scan = remain-on-channel (ath11k `ath11k_mac_op_remain_on_channel`), flags `WMI_SCAN_OFFCHAN_MGMT_TX` 0x2000 | [V ath11k mac.c:9706, wmi.h:3325] |
| Receive management frames | `WMI_MGMT_RX_EVENTID` (0x7001); we get beacons in every scan. Whether the firmware passes **action** frames of a foreign BSSID (AWDL) is **[U]**: patch 0347 bit 0 tells | [V beacons; U action] |
| Monitor mode / promiscuous RX | ath11k WCN6855: `supports_monitor = false`, `rxdma1_enable = false`; service `RX_PROMISC_ENABLE_SUPPORT` 145 is unknown for our firmware | [V ath11k core.c; U bit] |
| Second vdev | `WMI_VDEV_CREATE` types AP/STA/IBSS/MONITOR, subtypes P2P_DEVICE/CLIENT/GO; ath11k WCN6855 `interface_modes`: STA, AP, P2P_DEVICE, P2P_CLIENT, P2P_GO | [V ath11k] |
| NAN (close to AWDL: discovery windows, clusters) | services `NAN` 52, `NAN_DATA` 96, `WMI_NAN_CMDID`; the Android firmware (qcacld) supports Wi-Fi Aware on many SM8450 phones. NAN frames are **not** AWDL frames: NAN does not help AirDrop directly | [V ath11k ids; U our firmware bits] |
| AWDL data frames | AWDL data = IBSS-style 802.11 data (ToDS 0, FromDS 0, addr3 = BSSID 00:25:00:ff:94:73). Ideas: an IBSS vdev (type 3) with that BSSID + a peer per AWDL peer; or raw TX encap. Both **[U]** for WCN6855 | [I] |
| Timing | the firmware owns the channel; the host cannot hop 16 TU slots quickly. OWL also works on **one** channel (6 or 149) and advertises a channel sequence that stays there; Apple peers come to it | [I: OWL design] |

Our WMI service bitmap is parsed (`negroni_wlan_wmi.c` `svc_map`) but was never printed; the log only
says `services 0..383 avail yes` [V usblog 12:11:49]. Patch 0347 prints the bits that matter.

## 3. Paths, ranked

| Rank | Path | What | Effort | Risk |
|---|---|---|---|---|
| 1 | **B: AWDL in userland (OWL port) + a thin kernel raw path** | Kernel: awdl0 + AirLink IOService (0347 bit 1 is the start), a raw path (TX mgmt/data frames, RX mgmt/data frames with a timestamp, remain-on-channel on 6/149), awdl0 packets to/from user space (kernel control socket), Apple80211 AWDL requests forwarded to the daemon. User space: `negroni-awdld` = OWL's protocol core (election, sync, channel sequence, frame build/parse, peers) + our I/O backend, deployed over SSH, restartable. Then opendrop-style tests | 3-5 weeks | medium: the firmware RX filter and the data path are [U]; userland timing is coarse (OWL works with it on Linux) |
| 2 | A: AWDL in the kernel (OWL design in the kernel) | Same engine inside the kernel thread, frames straight to WMI. Better timing, but every change = kernel build + boot | 4-6 weeks | medium-high: a bug panics the phone; slower test loop |
| 3 | C: BLE + infrastructure Wi-Fi only (no AWDL) | `BrowseAllInterfaces=1` in `com.apple.Sharing` makes our sharingd browse `_airdrop._tcp` on en0; the AirDrop server listens on all interfaces only with `EnableDemoMode`/`registerAllInterfaces` [I]. Works only with peers that also browse on infrastructure (a Mac with the same pref [U on current macOS], or a second phone of ours, or opendrop on a PC in the same LAN). Real iPhones always use AWDL | days | low; but it does not give AirDrop with iPhones |

Recommendation: do C as a cheap side test (it needs only Wi-Fi join + a pref) and go for B. Path B
re-uses all of 0347. If the firmware cannot carry AWDL data frames (the main [U]), the fallback is
AirDrop-over-infrastructure (C) plus BLE.

### License note (owner decision 2026-10-27)

GPL code may be used directly (kernel patches and userland), if the license is kept: the upstream
LICENSE/COPYING next to the ported code (or an SPDX line + the original copyright in each new file),
the source repo + commit pinned in the README, and the attributions kept.

| Project | License | Pin (2026-10-27 HEAD) | Use |
|---|---|---|---|
| seemoo-lab/owl | GPL-3.0 | `0ee3263f944ea721c355f826aa90d636d012a512` | path B/A engine (port `src/`: election, sync, schedule, frame, rx/tx, peers) |
| seemoo-lab/opendrop | GPL-3.0 | `11fe7ba7861093b302bc0637e8cb10adf2d29337` | AirDrop protocol test peer (runs on a Linux PC with an AWDL-capable card via OWL) |

Patch 0347 copies no code from either (design reference only).

## 4. Steps

| Step | What | Test | State |
|---|---|---|---|
| 1 | **0347 AWDL probe** (`negroniawdl`, default 0): bit 0 = WMI service bits + management-frame classification (AWDL PSF/MIF, NAN SDF); bit 1 = observer awdl0 + AirLink IOService, all Apple80211 requests on awdl0 logged and refused | see section 5 | builds; not run |
| 2 | Raw TX proof: remain-on-channel on 6 (2437 MHz) or 149 (5745 MHz) while not joined, one AWDL PSF by `WMI_MGMT_TX_SEND`, log the TX completion status; a Mac/iPhone nearby with `tcpdump` or Wireless Diagnostics sniffer sees it | Mac sniffer on channel 6 | after step 1 shows action-frame RX |
| 3 | Kernel raw path for user space (kernel control socket): RX mgmt (+ TSF/time), TX mgmt, ROC on/off, awdl0 packet in/out | a small CLI on the phone prints received AWDL frames | |
| 4 | `negroni-awdld` (OWL port, GPL-3, `tools/` or `userland/`, license file + pin): sync + election on one channel, PSF/MIF TX at the AW times | an iPhone/Mac AWDL peer table lists our phone (macOS `awdl` log / `sudo wdutil`) | |
| 5 | Data path: IBSS-style vdev with BSSID 00:25:00:ff:94:73 (or off-channel data TX) + RX of AWDL data frames; awdl0 IPv6 ping to a Mac | `ping6 fe80::...%awdl0` | |
| 6 | wifip2pd: answer the AWDL requests that step 1 logged (forward to the daemon), post AWDL events; mDNS `_airdrop._tcp` on awdl0 | AirDrop sheet on an iPhone shows our phone | |
| 7 | AirDrop transfer both ways | send a photo | |

## 5. Test of step 1 (0347)

Image: the normal Wi-Fi image (`scripts/ios16/variants/everything.args`) plus `negroniawdl=3`. RAM boot
(`fastboot boot`) is enough. Before the boot: put an iPhone or a Mac near the phone and open its
AirDrop / share sheet (or Finder > AirDrop on a Mac): this keeps its AWDL active on channel 6/149/44.

1. Boot. Wait for `NEGRONI WLAN iOS: en0 attached`.
2. Read `NEGRONI AWDL: WMI services for AWDL/NAN: NAN 52 yes|no, ...` (one line).
3. Unlock, open **Settings > Wi-Fi** for 60 s (wifid scans; every scan visits channels 6, 44, 149 for
   150 ms each). Keep the Apple device's AirDrop sheet open.
4. Read `NEGRONI AWDL: RX AWDL PSF|MIF ... BSSID 00:25:00:ff:94:73 (AWDL), 2437|5745 MHz ...`,
   `NEGRONI AWDL: new AWDL peer N`, and every 60 s `NEGRONI AWDL: RX summary: ...`.
5. 120 s after awdl0: `NEGRONI AWDL: awdl0 Apple80211 summary: K request kinds, N requests` + one
   line per kind (which daemon asked: `first from wifip2pd`).
6. Read-only checks over SSH (`scripts/net/ssh-phone.sh`): `ifconfig awdl0` (flags, eflags not shown),
   `ps ax | grep wifip2pd` (does it stay up now?).

How to read it:
- AWDL frames counted: the firmware passes foreign action frames to the host. Path B is open.
- Action frames 0 but beacons many, with the Apple device's AWDL active: the firmware filters action
  frames in scans. Next: a remain-on-channel scan with the P2P flags, or a P2P_DEVICE vdev.
- No `awdl0 Apple80211` lines: wifip2pd did not bind. Then read its log (`log stream --process
  wifip2pd` is not possible over our SSH; use the USB log of the restarts) and check the property
  match (IOPropertyExistsMatch vs IOPropertyMatch).
- New awdl0 request kinds: the work list for step 6.

Risk of `negroniawdl=2|3` [I]: awdl0 with IFEF_AWDL makes mDNSResponder and wifip2pd use it; nothing
can be sent (TX is dropped, media never ACTIVE). If Settings or sharingd misbehave, boot without the
arg. Bit 0 only reads frames the driver already receives.
