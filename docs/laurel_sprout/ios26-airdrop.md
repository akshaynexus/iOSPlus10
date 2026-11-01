# Mi A3 iOS 26.5.2 23F84 (N104AP): AirDrop over AWDL and AirPlay (2026-11-02, branch t3/laurel-ios26-airdrop)

Status: **host only. Nothing here has run on the phone, in any iOS. The Wi-Fi firmware's behaviour for AWDL is unproven** (`airdrop-awdl.md` section 7: 6 unknowns). Marks: [V] read in a binary, source or log; [I] inference; [U] unknown.
iOS 26 itself has not booted on this phone (`ios26-kernel.md`, `ios26-userland.md`), and its wifid, bluetoothd and audio are not ported to this kernel. A path for wifid is listed in section 4.1. So this file gives the parts for AirDrop and AirPlay; it does not say that they work.

Tools: `scripts/debug/air-re-26.sh` (jobs, entitlements, strings, images, disassembly into `out/air-re-26/`, git-ignored), `scripts/debug/macho-xref.py` (who loads a string or sends a selector in a stripped daemon), `op10tool a64-dis` (cache images), `scripts/debug/air-re.sh` (20H392, same questions).

## 1. Audit of patch 2932 and laurel-awdld (lines as at 3e6c5b9)

No independent person had read this work. The question: is it safe for normal Wi-Fi?

**"Wi-Fi may be lost until reboot in that first boot" violated CLAUDE.md ("a failure turns off only that feature, never Wi-Fi"). It was also worse than the text said.**
Exact cause: `laurel-awdld` starts by itself (`run.rs:86-103`) when sharingd says Everyone or bluetoothd sets an AirDrop advertisement, with en0 idle. The first VDEV_CREATE/START of an IBSS vdev on this firmware has never run [U]. An assert in the modem makes `modem_watch` (`TopazModem.cpp`, branch `sk_last & 1`) call `laurel_wifi(false)`, `laurel_cell_off`, `laurel_ipa_off` and **return: the modem thread ends and nothing restarts it. So Wi-Fi AND cellular AND IPA stop until reboot**, not Wi-Fi alone (the doc named only Wi-Fi). No text told the user. The doc's answer was to ask the owner to choose a good boot; the code did not ask.

| # | Defect, file:line at 3e6c5b9 | Effect | Fix | Mark |
|---|---|---|---|---|
| 1 | The first start runs by itself: `run.rs:140-145`, `policy.rs:82` | Rule violation above | Gate: `policy::pick` gives `GATE_ALONE`/`GATE_SHARED` until the owner writes `/private/var/db/laurel-awdl.allow` (or `AWDL_FIRST_TRY=` at the root build). **By default nothing untested reaches the firmware** | [V code], test `by_default_nothing_untested_reaches_the_firmware` |
| 2 | `alone-ok` after 10 s, and a crash later keeps it: `session.rs:157-164` | An assert at PEER_CREATE, first Tx or teardown (all after 10 s) keeps `alone-ok`, so **every boot with AirDrop in use loses Wi-Fi and cellular again** | New sticky state `failed`; a modem stop with the vdev on, or within 10 s of its end, sets it | [V code], test `who_stopped_the_modem` |
| 3 | The first cell beside a **joined** en0 also ran by itself after `alone-ok`: `policy.rs:76-80` | A live connection lost on the first share sheet, with an AP on 6, 44 or 149 (common) | Its own gate (`shared`) | [V code] |
| 4 | `policy::everyone` searched for two words: `policy.rs:52-56` | sharingd keeps a key `EveryoneModeUpdateTime` after the mode ends [V 20H392 and 23F84 strings, 23F84 0x10024aaf4]. So after one use of Everyone the cell ran **for ever** in Contacts Only | A real binary plist read of `DiscoverableMode` | [V], test `contacts_only_after_everyone_is_not_everyone` |
| 5 | State file errors ignored, not atomic: `run.rs:32-37` | Read-only root or a panic in the write: no memory of a failure, so a crash every boot | Whole file + rename + fsync; no write = no start, one line | [V code] |
| 6 | Crash blamed on the wrong thing: `run.rs:156` read `fw_fatal` only after `trying` was written | A modem crash from another cause turned AWDL off for good | Status read before the start; `off_age_ms` in the status decides blame | [V code] |
| 7 | 6 s with no start = `End::Fatal`, `trying` kept: `run.rs:164-168`, while `ar_poll` waits for `!scanning` | A long wifid scan (max 20 s) with **no command sent** ended the feature for good | 30 s; before VDEV_START that is no sign of a sick firmware: state restored | [V code] |
| 8 | AWDL commands had no back-pressure on WMI: `ar_tx_pump` (patch:694-697), peers (patch:806) | WMI queue has 8 slots, then `htc_wmi_send` **drops the message**. An en0 key or join command could be the one dropped, beside a joined en0 | `lw_ar_wmi_room`: AWDL waits at half of the queue | [V code] |
| 9 | AWDL data could hold all Tx slots: patch:698-707 | A peer that does not ACK starves en0 | `lw_ar_tx_room`: half beside en0, 7/8 alone | [V code, I effect] |
| 10 | VDEV_START during a scan and a scan during the start: patch:790-796 | Untested order on a firmware that asserts easily; a join waits for `!scanning`, this did not | `lw_ar_holds_scan` both ways | [I risk] |
| 11 | Channel list never restored: patch:760-762 | The channel stayed non-passive with ADHOC_ALLOWED after the cell | `ar_chan_list(0)` at the end | [V code] |
| 12 | Vdev 1 frames could reach en0's IP stack in the teardown: patch:911 | Foreign frames in en0's stack for up to about 0.7 s | `lw_ar_data_route`: never | [V code] |
| 13 | WLAN PD restart not counted: `fw_fatal` is the modem only | `wlfw_arrive` shows that the PD can restart with the modem alive: the vdevs are gone | `fw_fatal` also on `w_arrivals > 1` | [V code; U what en0 does then] |
| 14 | awdl0 stayed UP after the session: `session.rs:165-175` | The stack sent into a queue with no radio under it | `ctl::if_down` at the end of each session | [V code] |

**Found safe [V code]:** a join ends the cell first (`w_join_poll` -> `ar_active`), at most about 0.7 s; `ar_mgmt_rx` takes only AWDL and ADDBA frames and only while up; `w_assoc_mgmt_rx` checks the AP's address, so a peer's deauth does not touch en0; PEER_STA_KICKOUT is limited to the AP; `ar_mgmt_tx` takes 16 KiB of a 16 MiB pool; kill switches `awdl=0`, `AWDL=0`; the socket is root only. The rule "glue" of 2932 on 12377 is only `bsd/conf/files`: harmless.

**Not fixed, stated plainly:** the gate moves the risk to the owner's chosen moment; it does not remove it. The rule "a failure never takes Wi-Fi" holds by default; after the owner allows a try, an assert still stops the modem until reboot. The real cure is a modem restart in `modem_watch` (PIL shutdown + load + GLINK and SMP2P reset): not written, large, and unprovable on a host. Then the gate could go. This also departs from "on by default" on purpose: the feature is on and says why it waits; two rules conflict and the owner's "never Wi-Fi" wins. Also: an **alone** cell shares its radio with wifid's scans when en0 is not joined (off its channel for seconds), so AirDrop will be weak then [I].

## 2. 23F84 against 20H392 [V static, unless marked]

| Item | iOS 16 20H392 | iOS 26 23F84 | Consequence |
|---|---|---|---|
| Media daemon | `mediaserverd` | **gone** (not in the tree). `audiomxd`, `airplayd` | Any check by that name fails |
| `com.apple.airplay.sender.xpc` | mediaserverd | **no job has it** (launchd.plist) | `laurel-airplay` said "no sender" on iOS 26: fixed |
| AirPlay services | mediaserverd | `com.apple.coremedia.routediscoverer.xpc`, `routingsessionmanager.xpc`, `airplay.agent.services`: audiomxd. `endpointmanager.xpc`, `airplay.endpoint.xpc`: airplayd. Both as `mobile` | Managed preferences of `mobile` still apply |
| `airplayd` | none | `/usr/libexec/airplayd`, on demand, links AirPlaySender, MediaExperience, APTransport. Entitled for `com.apple.DriverKit-AppleBCMWLAN` user clients | [U] what it does with no such driver |
| Session choice | `sessionProtocolOverride` | **same**: 0x226fe82c4 loads the key, compares `legacy`, `airplay`; `Using APSenderSessionLegacyAudio because of defaults write` at 0x227072650; domain string `com.apple.airplay` | `root-airplay-legacy.py` carries over |
| Clock | PTP if the receiver can | **same**: `Receiver supports PTP: %s, NTP forced: %s` 0x226fe5018; `sdpsession_startNetworkClock` NTP 0x226f5c758 | |
| Authentication | RSA, FairPlay, MFi | RSA and FairPlay clients there; MFi grew (7 -> 15 strings) | Same |
| Discovery | `_airplay._tcp`, `_raop._tcp` | same counts in APTransport; same "Ignoring device" filters | |
| sharingd prefs | `BrowseAllInterfaces`, `RegisterAllInterfaces` | **same**, domain `com.apple.Sharing` (0x1000113b8). New default: on if `SFDeviceIsVirtualMachine` | `root-airdrop-lan.py` carries over |
| Old stack | SDBonjourBrowser, SDAirDropClient, SDAirDropServer | **still there**: `-[SDBonjourBrowser getInterface:]` 0x10018f8f0, `-[SDAirDropServer startHTTPServer:]` 0x1001147cc, `-[SDAirDropPublisher publish]` 0x10008b014 | The prefs work on this stack |
| **New stack** | none | **Swift: `AirDropNW.*`, `SDAirDropBonjourBrowser`, `SDAirDropBonjourServer`, `SDAirDropSendConnection`, `SDAirDropReceiveService`, state machines, also an application-service path through rapportd (`com.apple.rapport.browse`, `RapportBrowseAgent`)** | **The prefs are not read there.** Which stack runs in which case: [U] from static reading |
| New stack, connect | | `NWParameters(tls:tcp:)`, **`requiredInterfaceSubtype = wifiAWDL`**, `includePeerToPeer` [V 0x1006ceadc, 0x1003ffe7c] | A plain Ethernet awdl0 (2932 as it was) **cannot carry a send** |
| New stack, server | | `NWListener`, `requiredInterface = nw_interface_create_with_name("awdl0")`; no such interface: error line, no required interface [V 0x1006d1108, 0x1006d9058] | Apple's awdl0 always exists: ours must too |
| New stack, browse | | `NWBrowser(.bonjourWithTXTRecord)`, `includePeerToPeer` [V 0x10052f8ec] | mDNSResponder: "call AWDL and NAN plugins since kDNSServiceFlagsIncludeAWDL" [V strings] |
| `wifiAWDL` in the kernel | | `if_functional_type()`: subfamily Wi-Fi + `IFEF_AWDL` [V 12377 `bsd/net/if.c:908`] | **Kernel need, done in 2932: typed awdl0**. `IFEF_AWDL` brings `IFEF_IPV6_ND6ALT`, so no ND: `nd6_alt_node_present` per peer, as Apple's driver |
| wifip2pd | Apple80211 ioctls on Apple's driver | Still (`Apple80211RawGet`...), now also `IO80211APIUserClient`, `IO80211P2PDaemonUserClient`, `com.apple.private.wifi.driverkit`; 450 WiFiAware strings | **Stays out.** No stand-in here |
| sharingd + wifip2pd | | New: entitlement `com.apple.wifip2pd`, `WiFiP2PAWDLStateMonitor` (0x1003e31f8, in the send state machine), `WiFiP2PSPITransactionRequestor` (single band for one Boop path) | [U] what the state machine does with no daemon. **Main risk for send** |
| Wi-Fi Aware | no | `WiFiAwareD2DPlugin.bundle`, `WiFiAware` framework, 0 WiFiAware strings in sharingd, 3 in mDNSResponder | sharingd has no direct use. A peer on Wi-Fi Aware only: this port cannot reach it |
| New AirDrop gates | HSA2 in the WiFiP2P bit | Manatee: `WiFiP2P bit is not set, ... Manatee: %@`; `Legacy browser should browse: ... ManateeAvailable` | [U] on a phone with no Apple ID: Everyone mode should not need it [I] |
| D2D encryption | | `-[SDStatusMonitor installD2DEncryptionMonitor]`: seen in the hotspot and advertiser state lines | [I] not on the AirDrop path |
| SystemOS cryptex | | Daemons are on the OS volume; AirPlaySender, CoreUtils, Sharing in the cache on SystemOS | Our files go on the root; the cache is not touched |
| launchd | cache `System/Library/xpc/launchd.plist` | **same form**, `LaunchDaemons` by path. A `.sig` file sits beside it; launchd 23F84 has no string for it [V strings; U no other check] | Job scripts carry over |
| Managed preferences path | `/private/var/Managed Preferences/` | same [V CoreFoundation strings] | |

Not traced, on purpose or for lack of need: rapportd beyond its strings (`NoAWDL`, `ForceAWDL`, `AWDLGuestDiscovery`: not needed for Everyone-mode AirDrop [I]), `CoreUtils`, `AirPlayReceiver` (a receiver on this phone: no work planned).

## 3. What changed in our code

- **Kernel, patch 2932** (still one patch; both series): section 1 + `LW_AR_IF_TYPED`: the daemon asks for a typed awdl0. **iOS 16 sends the same 7 bytes as before, so its awdl0 stays plain Ethernet.**
- **`laurel-awdld`**: one binary for both. `kern.osrelease` major >= 25: awdl0 typed and made at the daemon's start, down until the cell hears AWDL. Darwin below 25: as before. No system binary is patched, so no build id check applies.
- **`laurel-airplay`**: `kern.osrelease` >= 25 checks `com.apple.coremedia.routediscoverer.xpc` + `com.apple.airplay.endpoint.xpc`. Else as before.
- **Root step, entry point: `scripts/laurel/root-air-ios26.sh MOUNTED_ROOT`.** Idempotent [V test: no byte changes in a second run]. Refuses a root with no `audiomxd` job and a binary that is not plain arm64. Line in `usr/share/laurel/ios26-air-manifest`, and in `$MANIFEST` when set. Cdhashes in `usr/share/laurel/ios26-air-cdhashes`.
- **Branch `t3/laurel-ios26-needs`**: not on origin at the fetch of 2026-11-02; its local worktree is at 037cd81 with no root script. So the entry point is a proposal: no root build calls it yet.
- **Trust:** two new files, each with an ad hoc signature, in no Apple trust cache. Today's kernel has trust caches off and `sweet_amfi` takes every root binary (`ios26-kernel.md` section 3). A root build with a trust list must add the two cdhashes; each rebuild changes them. The launchd cache changes, and no cdhash covers it.

## 4. Kernel needs

Inside 2932, done: typed awdl0, alt neighbours. Outside 2931/2932:

1. **A modem restart** (section 1), to remove the gate. Not written.
2. **iOS 26 Apple80211 ABI for wifid:** `bsd/dev/redwood_apple80211.c` in our 12377 tree still has the iOS 16 sizes (5456, 1164, 592, 32 in its `_Static_assert` lines) [V]. No wifid means no `wirelessEnabled` in sharingd [I], so AirDrop and AirPlay need this first. Section 4.1 lists what fits. Not ported in this branch: no code taken.
3. iOS 26 Bluetooth for bluetoothd: nobody has it (below). Without it only the Everyone trigger and no BLE discovery by a peer [I].

### 4.1 IOS-26-Hot (`external/IOS-26-Hot`, d249939, MIT, read-only): what fits the Mi A3

It reports `en0` in native Settings on 23F84 with WCN3990, on SM8150 (RMX1931, iPhone 11 Pro donor). **Its results are self-reported: nobody here ran it.** Its en0 side has the same origin as ours: topaz 0900 (`redwood_net.c`, `redwood_apple80211.c`, `redwood_sta.c`, `RedwoodWLAN.cpp`, `MiniIONetworkStack.cpp`); all of these are in our 12377 tree [V `ls`]. The difference is below `redwood_sta`: its radio is a userland daemon (`wland`, `/dev/wlan`, `flame_sta.c`); ours is in the kernel (`TopazModem.cpp`, `topaz_sta.c`).

How wifid comes up there: the IOKit service has no user client on purpose, so IO80211 logs `Falling back to IOCTL path` and sends `SIOCGA80211`/`SIOCSA80211` on en0; `redwood_apple80211.c` answers. That string is in N104AP 23F84 IO80211 too (0x25cacca90) [V]. Patch 0145 gives the sizes of iOS 26, 0146 the split scan.

**Fits, on `redwood_apple80211.c` (a 12377-only patch, so iOS 16 stays as it is):**

| # | Item (their patch) | Checked here | Ours today |
|---|---|---|---|
| 1 | SCAN_REQ 5528 bytes, `scan_uuid` at 0x154c; a SCAN_RESULT must give the UUID back (0145) | [V size only] `mov w, #0x1598` in IO80211 N104AP 0x25ca8c874 | 5456: refused, EINVAL [V code] |
| 2 | SCAN_RESULT, CURRENT_NETWORK 2272 bytes, elements 2048 (0145) | [V size only] `#0x8e0`, 0x25ca79334 | 1164 |
| 3 | ASSOCIATE 908 bytes, auth fields 32-bit, what follows +4 (0145) | [V size only] `#0x38c`, 0x25ca95070 | 592 |
| 4 | Link event 44 bytes, new layout (0146) | [V] `cmp w2, #0x2c` at 0x25ca90a7c: the address their note gives, in our cache too | 32: the framework drops it [I] |
| 5 | CARD_CAPABILITIES 21 bytes; COUNTRY_CODE (51) answered; SETs answered 0: 365, 383, 473, 481, 483, 485, 512, 560, 564, 582 (0145, 0146) | [U] self-reported | 13 bytes, not answered. Their country is fixed to "IN": take the value from a check, not a copy |
| 6 | Split scan: a stage with no channel of the radio (6 GHz) ends at once with SCAN_DONE and 0 results, not EINVAL; frequency filter on results; `skip_radio` in `redwood_sta.{c,h}` (0146) | [U] self-reported cause: "aborts the whole scan" | `redwood_apple80211.c:544` gives EINVAL there [V] |
| 7 | noise, SNR in a result; hidden names only for a directed scan (0146) | [U] | not set |

**Already here [V]:** IOKit quiesce hold off (`IOStartIOKit.cpp:219`); ADT `/arm-io/wlan`, which launchd needs (`_LimitLoadToDeviceTree` of `com.apple.wifid`: `wlan`, `marconi-wifi`, ... [V 23F84 job]); `/chosen mac-address-wifi0`; background scan limits (2885).

**To check on our side, from their notes:** a Wi-Fi service for en0 in configd's `preferences.plist` (their note is from their iOS 16 stage); keychain wrap/unwrap for wifid's passwords: our AKS stand-in must match the 23F84 selector changes (`ios26-userland.md` section 8). I did not read their later keystore patches.

**Does not fit:** `phone/wifi/*` (`wland`, `radio.c`, `bridge.c`, `glink`, `qrtr_mux`, `pdmapper`, `rmtfs`, `servreg`, `scm`, `pmem`): a second radio stack in userland beside `TopazModem.cpp`. `flame_wlan.c`, `flame_sta.c` and the /dev/wlan protocol: use `topaz_sta.c`. Their active probe scan: our scan is passive on purpose ("nothing is transmitted", `scan_start`); take it only if hidden networks need it. The rest of 0146: CPU governor, GPU, SM8150 clocks. Their SM8150 fix for `wlan_pd` with LTE and audio (`pdmapper.c` TLV): another MPSS; read it only if our pd-mapper shows that failure.

**Audio:** `adspd` + `HotAudio.driver` drive SM8150 LPASS, Q6 services and MAX98937: another chip path than our WCD937x + `RedwoodAudio.driver`. No code fits. What it adds, self-reported: a CoreAudio HAL plug-in can load under 23F84 audiomxd. Ours has not been tried there.

**Bluetooth, AirDrop, AWDL:** it has none (its README lists Bluetooth as not working). It gives no evidence for awdl0, for section 1's firmware unknowns, or for iOS 26 bluetoothd. Hot's own patches have no typed awdl0 to compare with.

## 5. Tests and what they can not show

`scripts/laurel/wifi-phy-test.sh`, `cargo test` (policy, plist, proxy, wifi, `tests/two_nodes.rs`), `scripts/laurel/root-air-ios26-test.sh`, `scripts/laurel/ios26-injected-check.py BIN`, job self-tests, `build-honest-test.sh`, `root-dry-run.sh`.
They can not show: that the firmware accepts an IBSS vdev; that frames pass; that an iPhone sees us; that dyld, launchd or AMFI accept our binaries on iOS 26; that `IFEF_AWDL` with no wifip2pd behaves in mDNSResponder and sharingd (compile only); which sharingd stack runs; that BLE reaches `lw_ar_ble_airdrop` on iOS 26 bluetoothd. `two_nodes.rs` is two copies of our daemon's Node, not an Apple peer.

## 6. Owner steps (no flash without your go)

1. Lines to read: `LAUREL AWDL: off: the IBSS vdev has never run on this firmware...` is the default state.
2. When a boot with lost Wi-Fi and cellular is acceptable: `echo alone > /private/var/db/laurel-awdl.allow` (iOS 16 first: that boots today), then `airdrop-awdl.md` section 8.
3. After `alone-ok` and a real transfer: `echo shared > ...` for the cell beside en0.
4. `failed` in the state file: read the crash line; `rm /private/var/db/laurel-awdl.state` tries again, only after a change.

## 7. Build results

See `docs/plan.md`, section of this date.
