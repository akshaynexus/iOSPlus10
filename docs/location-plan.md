# Location services plan (2026-10-27, location research agent; research only)

Owner: "location services are off". Question: what is the shortest working path to a location fix on
this port (iOS 16.7.16 20H392, D22 userland, SM8450)?

Marks: **[V]** seen in a log, DT, ADT, firmware image, root image, shared cache or source. **[I]** inference.
**[U]** unknown, a test must decide. Nothing in this file ran on the phone. No patch and no script exist yet.

## Short answer

- [V] `locationd` runs and does not crash. It denies every client with `location disabled system-wide`
  (`BigSwitch 0`, `isLocationServicesEnabled 0`). So "off" is the switch (a preference), not a missing
  driver. Step L0 (switch on) costs nothing.
- [V] With the switch on there is still no position source. The D22 ADT says `baseband-chipset = 'mav17'`
  (Qualcomm MDM9655). On that hardware `locationd` gets GNSS from the baseband ("Eureka":
  `CLEurekaController`, QMI **PDS** over Apple's baseband transport), not from a GPS chip on a UART.
  We cannot copy that transport. Wi-Fi positioning needs wifid scans (blocked today) and internet.
- [V] `locationd` has a simulation service (`com.apple.locationd.simulation`) and the shared cache has
  `CLSimulationManager` with `appendSimulatedLocation:`, `startLocationSimulation`, `setWifiScanResults:`,
  `startWifiSimulation`. Our ad hoc signed daemons can carry any entitlement. **This is the injection
  point for every path**: one small daemon `negroni-locd` feeds positions (or Wi-Fi scan lists) into
  `locationd`. No fake GPS kext, no fake baseband.
- Recommended order: **L0** switch on -> **L1** `negroni-locd` with a position from the Mac (proves the
  iOS side, 1-2 days) -> **L2** Wi-Fi positioning (free after the Wi-Fi fix, or through
  `setWifiScanResults:` with the kernel's own scan list) -> **L3** real GNSS: modem (MPSS) boot in low
  power mode + read-only RMTFS + QMI LOC (service 0x10) -> `negroni-locd` (weeks).
- [V] The NE2211 has no standalone GNSS chip: `out/live.dts`, `dtbo.img`, `vendor_boot.img` have no
  `gnss`/`gps`/`qcom,loc` node. GNSS is in the modem.

## 1. iOS side

### 1.1 What the logs show

- [V] `logs/phone-log-20261027-004129.txt` (982 346 lines, full unified log of one boot):
  - `locationd[62]` runs for the whole boot; no crash, no exit, no restart. The only fault line is
    `Error occurred, no mib to monotonic clock conversion` (11 times).
  - `location disabled system-wide, denying executable com.apple.WebKit.WebContent` (93),
    `... com.apple.audio.toolbox.reporting.service` (107); `BigSwitch 0` in every
    `computing freshAuthorizationContext`; `client not currently authorized for location; sending error`
    for Maps.
  - `updateHarvestingAllowed ... "isLocationServicesEnabled":0, ... "isGpsControllerSimulationEnabled":0,
    "isLocationControllerSimulationEnabled":0`.
  - No `Eureka`, `CLGnss`, `gpsd` or `ClxGps` line: with the switch off, `locationd` never starts GNSS.
- [V] The USB logs (`logs/usblog-*.txt`) show 26 `exec locationd` lines (one per boot) and one
  `process locationd[64] crossed thread count high watermark (32)` (not a crash). No locationd panic.
- [V] `fairplayd` deadlock is already fixed (`scripts/ios16/root-tweaks-extra.py`, ios-flame
  HANDOFF.md:238-245); without it `locationd` would hang in `CLMescalSigner`.
- [V] `exec CommCenter`, `exec wifid`, `exec geod` are in `logs/usblog-20261027-060101.txt`. `gpsd`
  (launchd job `com.apple.gpsd`, on demand) never starts.

### 1.2 Greyed or off?

- [V] The daemon side is "off" (the switch preference), not "unsupported". Our ADT has
  `/product gps-capable = 0x1` and `baseband-chipset = 'mav17'` (from the real D22 ADT,
  `~/op10-apple/d22ap.adt`).
- [U] We do not know if the Settings switch is greyed. A greyed switch comes from a restriction profile
  or Screen Time, not from a missing driver [I]. First test (L0): open Settings > Privacy & Security >
  Location Services and look.
- [V] Strings in 20H392 `locationd`: preference keys `LocationServicesEnabledIn8.0`, `BigSwitchEnabled`,
  `BigSwitchState`; SPI `-[CLInternalService setLocationServicesEnabled:replyBlock:]`; the CoreLocation
  class method `setLocationServicesEnabled:` is in the shared cache.
- [V] The log shows `locationd` reads the domain `com.apple.locationd` as `User: mobile` and as
  `kCFPreferencesAnyUser, ByHost: Yes`. [I] Setup.app writes the switch on a real phone; we skip Setup,
  so the key is absent and the default is off.
- Fallback for L0 (only if the Settings switch does not work): call
  `[CLLocationManager setLocationServicesEnabled:YES]` from `negroni-locd` (entitlement to find:
  `com.apple.locationd.status` or `com.apple.locationd.preauthorized` [I]). This is better than a root
  tweak that writes a plist, because the file path and ByHost form are [I].

### 1.3 GNSS stack in locationd (20H392)

- [V] `locationd` (30.9 MB) has two GNSS device classes plus a fallback:
  - `CLGnssDaemonDevice` -> `gpsd` over the mach service `com.apple.gpsd` (protobuf
    `proto.gpsd.Request/Indication`, `SetPvtmReport`, `SetNmeaHandler`). `gpsd` (2.5 MB) drives a
    Broadcom-type chip through `/dev/cu.gps` (`GnssHalCommUart.mm`) or SPI (`GnssHalCommSpi.mm`) and a
    GPIO IOService (`#gpio,IOServiceOpen failed`). This is for newer iPhones.
  - `CLEurekaController` -> `CLQmiController`, `CLQmiPdsMessageDefs.h`, `CLEurekaModemController`:
    QMI PDS to a Qualcomm baseband (strings `isMav21andNewerGnss`, `mav22`). Log names
    `ClxGps, state, 1, Eureka` and `ClxGps, state, 1, GnssDaemonDevice/gpsd`.
  - `CLGnssUnknownDevice` (`#Warning,Constructing CLGnssUnknownDevice`) when there is neither.
- [V] `locationd` links `libQMIParserDynamic`, `libPCITransport`, `libARI`, `libTelephonyBasebandDynamic`,
  `CoreTelephony`. [I] For mav17 the QMI goes over the Apple baseband PCIe transport (ADT
  `/arm-io/.../baseband-pcie`, `/baseband` with `compatible = 'baseband,n41'` in the real D22 ADT). We have
  no such transport, and [I] the SM8450 modem offers QMI LOC, not the old QMI PDS.
- [U] Which device `locationd` builds on our port (the selection is in code, not a string we found).
  Test L0 shows it: look for `CLEurekaController created`, `#gpsd,CLGnssDaemonDevice ctor` or
  `Constructing CLGnssUnknownDevice` after Maps asks for a location.
- Conclusion [I]: a fake `gpsd` or a fake Eureka/PDS baseband is the most work for the least gain.
  Use the simulation service instead (1.5).

### 1.4 Wi-Fi positioning

- [V] `locationd` has `CLWifiScanner`, `CLOldWifiScanner`, `@WifiFlow, scanreq ...`,
  `#wlan,onWifiNotification,scanResult`, and links `MobileWiFi`. It asks wifid for scans and sends the
  BSSIDs to Apple's location server [I: `gs-loc.apple.com` WLOC]; it also caches Wi-Fi tiles.
- [V] Today wifid sends no scan request (docs/plan.md TODO 1). So `locationd` gets no scan list either.
- [V] iOS has internet over USB (docs/usb-network.md: Mac NAT, `scripts/net/share-internet.sh`). [I] So a
  Wi-Fi fix is possible on the cable before Wi-Fi join works, if the scan list reaches `locationd`.
- [I] A coarse fix from Wi-Fi alone: yes, once (a) the switch is on, (b) `locationd` gets a scan list,
  (c) the WLOC request reaches Apple. [U] Apple may refuse WLOC from a device that is not activated;
  test it.
- [V] Bypass for (b): `CLSimulationManager setWifiScanResults:` + `startWifiSimulation`. [I] It feeds a
  scan list into the same Wi-Fi pipeline. The kernel driver already sees beacons (t23: 19 BSS from its
  own passive scan). The dictionary format of the list is [U] (read `-[CLSimulationManager
  setWifiScanResults:]` in the cache).

### 1.5 The injection point: location simulation

- [V] launchd plist `com.apple.locationd.plist` has the mach service `com.apple.locationd.simulation`.
- [V] Shared cache `out/dsc/cache` strings: `CLSimulationManager`, selectors `appendSimulatedLocation:`,
  `appendSimulatedLocations:`, `clearSimulatedLocations`, `startLocationSimulation`,
  `stopLocationSimulation`, `setLocationDeliveryBehavior:`, `setLocationRepeatBehavior:`,
  `setLocationInterval:`, `setLocationDistance:`, `loadScenarioFromURL:`, `setWifiScanResults:`,
  `startWifiSimulation`, `setSimulatedWifiPower:`, `setSimulatedCell:`, `startCellSimulation`.
- [V] `locationd` strings: entitlement-like `com.apple.locationd.simulation`, `CLSimulatedLocationProvider`,
  `Beginning Simulation Service`, `ClxSimulated, Fix, 1, ll, ...`, setting `AllowSimulatedLocations`,
  `location is simulated, rejecting` (some internal consumers drop simulated fixes [I]: country code /
  regulatory, harvesting).
- [V] Our daemons are ad hoc signed with any entitlement (`userland/fp/build.sh`, `codesign -s -
  --entitlements`; AMFI patches, README-aks-amfi.md). No Developer Mode string in `locationd` [V]; [U] if
  CoreLocation checks Developer Mode on the client side.
- [I] Apps see `CLLocation.sourceInformation.isSimulatedBySoftware = YES`. Maps, Weather, Safari accept
  it. A few apps reject it. This is acceptable for a port.

## 2. Hardware side (SM8450, NE2211)

### 2.1 Where GNSS is

- [V] No GNSS node in `out/live.dts`, no `gnss`/`gps` string in `~/op10-backup/images/dtbo.img` or
  `vendor_boot.img`. GNSS is the modem's (MPSS) engine; the RF is in the modem's transceiver [I].
- [V] Modem node `remoteproc-mss@04080000` (`out/live.dts:6528`): `compatible = "qcom,waipio-modem-pas"`,
  supplies cx/mx (level 0x180 = 384), `qcom,qmp`, interconnects, `memory-region = <mpss_region, CMA>`,
  interrupts wdog/fatal/handover/ready/stop-ack/shutdown-ack, `qcom,smem-states` stop,
  glink-edge `qcom,remote-pid = <1>`, `mboxes = <&ipcc 2 0>` (IPCC client 2, signal 0), channels
  `IPCRTR` and `DS`.
- [V] Carveout `mpss_region@8bc00000`, size 0x13200000 (306 MiB) (`out/live.dts:172`).
- [V] SMP2P modem: `qcom,smem = <435 428>`, `mboxes = <&ipcc 2 2>`, local-pid 0, remote-pid 1
  (`out/live.dts:15639`).
- [V] Linux `qcom_q6v5_pas.c` `sm8450_mpss_resource`: `pas_id = 4`, `firmware_name = "modem.mdt"`,
  `crash_reason_smem = 421`, `minidump_id = 3`, `decrypt_shutdown = true`, proxy PDs `cx`, `mss`,
  `load_state = "modem"`, `ssctl_id = 0x12` (`out/src/linux/drivers/remoteproc/qcom_q6v5_pas.c:1548`).
- [V] IPA: `qcom,ipa@3e00000`, `ipa_fws` PAS id 15 (disabled node), `ipa_fw_region@8b900000`.
- [V] RMTFS buffer: `qcom,rmtfs_sharedmem@0` (`compatible = "qcom,sharedmem-uio"`, size 0x280000,
  client-id 1, dynamic address) (`out/live.dts:10411`).

### 2.2 Firmware

- [V] `out/firmware/modem/modem.img` (FAT, from `modem_a`): `image/modem.mdt` + `modem.b00..b31`
  (30 files, 111 956 268 bytes = 106.8 MiB), `modemr.jsn` (servreg domains), `modem_pr/so/*.mbn`
  (56 files, 45.8 MB, served to the modem over TFTP), `modem_pr/mcfg/configs`.
- [V] The firmware areas today: gpu 8 MiB, adsp 32 MiB, wlan 32 MiB at the end of userdata
  (`scripts/fw/build-areas.sh`). The modem needs a new area of ~160 MiB (image + modem_pr), or the
  kernel reads the files from the root file system (HakiOS reads `/fw/image` on its root) [I].
- [V] The modem file systems are `modemst1`, `modemst2`, `fsg`, `fsc` (backups in
  `~/op10-backup/partitions/`). Owner rule: never write them. So RMTFS must be read-only, writes kept in
  RAM for the boot (HakiOS does this, `hakios.mpss.c:3525+`).

### 2.3 What the modem needs before QMI LOC answers

From HakiOS (POCO X5 Pro, SM7325) `out/src/hackios-next/xnu/files/bsd/dev/hakios.mpss.c` (6 395 lines)
and `docs/ru/cellular.md` [V for SM7325, I for SM8450]:

1. PAS: init image (4), mem setup, write segments, RPMh cx/mss votes, AOP QMP `load_state modem on`,
   auth and reset, SMP2P ready/handover. Same steps as our ADSP (0240, proven `THE ADSP IS UP`) and SLPI
   (0376) code with the modem values.
2. GLINK edge `mpss` (IPCC 2) + `IPCRTR` + QRTR (we have QRTR code twice: Wi-Fi 0265 over MHI, SLPI 0376
   over GLINK).
3. Services the modem asks the HLOS for, else it stalls or crashes:
   - RMTFS (QMI 14) on the shared buffer; the buffer must be given to the modem with an SCM
     memory-assign call (HakiOS uses VMID_NAV 0x2b on SM7325). [V] Our tree has no SCM assign call
     (grep of `patches/xnu`): new code.
   - servreg locator (QMI 64) answered from `modemr.jsn`.
   - TFTP over QRTR (QMI 4096) for `modem_pr/so/*.mbn` and a scratch `/readwrite`.
4. [V SM7325] HakiOS: after DMS "online" the modem crashed in `enl2_dl` (LTE downlink) until they ran the
   IPA (firmware, clock, SMMU streams, INIT_DRIVER). [I] For GNSS only we keep the modem in low power
   mode (never send DMS online, no SIM, no network). [I] Qualcomm GNSS works in airplane mode on Android,
   so standalone GNSS should run in LPM without the IPA. [U] if the SM8450 modem waits for the IPA SMP2P
   entry even in LPM.
5. QMI LOC (service 0x10) client [I message IDs, check against libqmi `qmi-service-loc.json`]: register
   events (0x21: position report, NMEA, engine state), set operation mode standalone (0x4A), start
   (0x22, fix interval 1000 ms), then indications position report (0x24) and NMEA (0x26). Stop (0x23).
   Cold start without assistance (no XTRA): [I] 30 s to several minutes outdoors.

## 3. Path ranking

### A. L0 + L1: switch on, then a position from the Mac (cheapest; proves the iOS side)

- Steps:
  1. L0: owner opens Settings > Privacy & Security > Location Services and turns it on. Capture the log
     (`scripts/net/ssh-phone.sh` + `oslogstream`, or `make bootlog`). Expect
     `#Actor handleLocationServicesStatusChange ... 1` and `isLocationServicesEnabled 1`. Open Maps.
     Read which GNSS device `locationd` builds (1.3) and that it does not hang or crash.
  2. L1: new `userland/location/negroni-locd.m` (Objective-C, iPhoneOS SDK, ad hoc signed, entitlements
     `com.apple.locationd.simulation`, `platform-application`, no-sandbox): `CLSimulationManager`
     `clearSimulatedLocations`, `appendSimulatedLocation:` (CLLocation from `lat lon acc`),
     `setLocationDeliveryBehavior:`, `startLocationSimulation`; input from argv or a UNIX socket /
     TCP port on ue0 (the Mac sends its own position or a fixed one). `userland/location/build.sh`,
     install from `scripts/ios16/root-finish.sh` (as negroni-fpd).
- Effort: L0 none; L1 ~200-300 lines + build script, 1-2 days.
- Risks: [U] the simulation service may check an entitlement with another name (read
  `locationd`'s simulation silo check); [U] Developer Mode check in CoreLocation; simulated fixes are
  dropped by a few consumers (`location is simulated, rejecting`).
- Build: userland daemon + root tweak (install). No kernel patch.
- First test: on the phone over ssh `negroni-locd 48.8584 2.2945 10`; open Maps; expect the blue dot at
  that position and `ClxSimulated, Fix, 1` in the log.

### B. Wi-Fi positioning (coarse fix, ~20-100 m [I]; needs internet)

- B1 (no new code): after Wi-Fi TODO 1 is fixed (wifid scans), turn the switch on, keep internet (Wi-Fi
  join or USB NAT). `locationd` scans and asks Apple.
- B2 (before the wifid fix): kernel exports its scan list (BSSID, RSSI, channel; new sysctl in the WLAN
  driver), `negroni-locd` passes it to `setWifiScanResults:` + `startWifiSimulation`, internet over USB.
- Effort: B1 0; B2 ~1 day kernel (sysctl over the existing scan table) + ~1 day daemon.
- Risks: [U] WLOC answers a not-activated device; [U] the dictionary format of `setWifiScanResults:`;
  only works near known access points and with internet.
- First test: B1: Settings > Wi-Fi shows networks, then Maps; log `@WifiFlow, scanreply, aps, N`. B2:
  `negroni-locd --wifi` and the same log line.

### C. Real GNSS: modem in LPM + QMI LOC -> negroni-locd (the only real fix outdoors)

- Steps:
  1. Firmware: `scripts/modem/extract-fw.sh` (modem.mdt/bNN, modemr.jsn, modem_pr) and a modem area
     (`mkmodemarea.py`, new userdata area ~160 MiB; owner approval for the write) or a root copy.
  2. Kernel `negroni_mpss.c` (copy of the ADSP/SLPI PAS file with the 2.1 values): steps 0-8 PAS boot,
     crash watch (0248 style), `negronimpss=N` levels, default off.
  3. GLINK `mpss` + QRTR (reuse the SLPI step 9-10 code); log NEW_SERVER (expect 0x10 LOC, 14 RMTFS
     lookups, 64, 4096).
  4. Read-only RMTFS (QMI 14) over UFS reads of modemst1/modemst2/fsg/fsc, writes in RAM; SCM
     memory-assign for the buffer; servreg locator; TFTP read-only for `modem_pr`.
  5. QMI LOC client in the kernel (we have the QMI encoder from WLFW 0266); fixes to a sysctl or a
     character device (`/dev/negroni_gnss`: lat, lon, alt, accuracy, speed, course, time, NMEA).
  6. `negroni-locd` reads it and calls `appendSimulatedLocation:` once per second.
- Effort: [I] 3 000-4 500 kernel lines (HakiOS mpss without IPA/DMS/NAS/WDS is ~3 500 on SM7325), 3-5
  weeks with phone tests. Daemon part: shared with L1.
- Risks: [U] auth and reset for PAS 4 (the ADSP's works); [U] modem wants the IPA even in LPM; RMTFS must
  never write the unique partitions (code review gate); SCM assign through Gunyah (new call); a modem
  crash may reset the SoC [I] (keep the USB watchdogs 0371/0375; test only with `fastboot boot`);
  power draw of a running modem; GNSS cold start time without XTRA.
- First test: `negronimpss=1` (PAS steps only, stop after ready) in a RAM boot; expect the SMP2P ready
  bit and a clean PAS shutdown. Then `=2` (GLINK + QRTR): list of NEW_SERVER lines, with service 0x10.

### D. Rejected

- A fake `gpsd` (`com.apple.gpsd` protobuf) or a fake Eureka/PDS baseband: D22 uses Eureka [V strings +
  ADT mav17], the transport is Apple's baseband PCIe stack, and the SM8450 modem speaks LOC, not PDS [I].
  More work than C step 6, no gain.
- iAP2 accessory location (`CLAccessoryLocationProvider` [V]): needs accessoryd/iAP2 and MFi auth.
- Cell-ID positioning: needs a registered modem (IPA, SIM, NAS), far more than C.

### Ranking

| Path | Gives | Effort | Needs first | Recommended |
|---|---|---|---|---|
| L0 switch on | apps may ask; no fix | 0 | nothing | now (owner, Settings) |
| L1 Mac/fixed position via `negroni-locd` | a working blue dot (simulated) | 1-2 days | L0 | next |
| B1 Wi-Fi via wifid | coarse real fix | 0 | Wi-Fi TODO 1, internet | when Wi-Fi works |
| B2 Wi-Fi via `setWifiScanResults:` | coarse real fix | ~2 days | L1, kernel scan list, USB internet | optional |
| C modem GNSS | real fix outdoors | 3-5 weeks | L1, owner approval for the modem area | later |

## 4. Files

- `out/research/location/` (git-ignored; Apple binaries, never commit): `usr/libexec/locationd`,
  `usr/libexec/gpsd`, `System/Library/LaunchDaemons/`, `System/Library/LocationBundles/`. Made with
  `python3 -I scripts/audio/hfs-extract.py ~/op10-apple/ios16-root.simg out/research/location
  /System/Library/LaunchDaemons /usr/libexec/locationd /usr/libexec/gpsd` (create `usr/libexec` first:
  the tool does not make parent folders for single files).
- ADT dumps: `adt.dump(adt.parse(adt.load(path)))` with `external/slop/negroni-ios/tools/adt.py` on
  `~/op10-apple/d22ap.adt` and `out/ios16/negroni.adt`.
- Shared cache: `out/dsc/cache/dyld_shared_cache_arm64*` (`strings` for `CLSimulationManager`).
- HakiOS modem reference: `out/src/hackios-next/xnu/files/bsd/dev/hakios.mpss.c`,
  `out/src/hackios-next/docs/cellular.md`, `docs/ru/cellular.md`.
- Earlier notes: `docs/references-2026-10-27.md` section 2 (L1-L4 estimate; this file replaces the
  "feed is the hard part" item with the simulation service).
