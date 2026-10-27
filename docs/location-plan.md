# Location services plan (2026-10-27, location research agent; research only)

Owner: "location services are off". Question: what is the shortest working path to a location fix on
this port (iOS 16.7.16 20H392, D22 userland, SM8450)?

Marks: **[V]** seen in a log, DT, ADT, firmware image, root image, shared cache or source. **[I]** inference.
**[U]** unknown, a test must decide. Nothing in this file ran on the phone. Section 5 (added 2026-10-27, location
userland agent) describes the L0/L1 code: `userland/location/`, `scripts/location/`, an optional root tweak.
It is built on the Mac only; no phone test yet. Section 6 (2026-10-27, location iOS agent) has the live phone results:
L0 works (switch on, default on in the root), L1 works, Wi-Fi positioning is blocked by the kernel scan while joined, and
the negroni-locd input interface for a later kernel GNSS source.

## Short answer

- Update 2026-10-27 (section 6): the switch is on and works (`BigSwitch 1`); simulated fixes work; Wi-Fi positioning waits
  for a kernel scan while Wi-Fi is joined (locationd drops 63 of 64 APs as older than 5 s).
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
- Fallback for L0 (only if the Settings switch does not work): `negroni-locd enable` calls
  `[CLLocationManager setLocationServicesEnabled:YES]` (entitlement `com.apple.locationd.status` [I]), or the
  root tweak `LOCATION_SWITCH=1` writes the key (section 5.3: the read is [V], the file path is [I]).

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

## 5. L0 + L1 implementation (2026-10-27, location userland agent; Mac build only, no phone test)

### 5.1 What locationd checks (20H392 `out/research/location/usr/libexec/locationd`)

- [V] Simulation service entitlement: the connection handler calls
  `[connection valueForEntitlement:@"com.apple.locationd.simulation"]`, checks `isKindOfClass:` NSNumber and
  `boolValue`; only then it sets up the exported interface. Else it logs `unentitled client attempting to
  simulate location` and refuses. (Code at `0x10084e194..0x10084e2e0`; CFString `0x101bf4f38`; selector refs
  `valueForEntitlement:` and `boolValue` resolved from the binary.) No other check in that path; no Developer
  Mode string in `locationd`.
- [V] The listener is made in the function at `0x10084cabc` (`Beginning Simulation Service`, `NSXPCListener`
  with `com.apple.locationd.simulation`). [V] That log line is in none of our `logs/phone-log-*.txt`.
  [U] So the listener may start only on demand or under a condition we did not find. If `negroni-locd set`
  hangs or has no effect, this is the first suspect.
- [V] Switch read: the function at `0x1001b33c8` calls `CFPreferencesCopyValue(CFSTR("LocationServicesEnabledIn8.0"),
  CFSTR("com.apple.locationd"), CFSTR("mobile"), kCFPreferencesAnyHost)` (GOT binds resolved with
  `dyld_info -fixups`); CFBoolean true or a non-zero CFNumber = on. It caches the result in a global.
- [I] `com.apple.locationd.bigswitch` is used as a notification name (passed to a C call next to a log line),
  not as an entitlement.
- [V] CoreLocation 20H392 (`ipsw class-dump` of `out/dsc/cache`): `CLSimulationManager` has `init`, `flush`,
  `appendSimulatedLocation:`, `clearSimulatedLocations`, `startLocationSimulation`, `stopLocationSimulation`,
  `setLocationDeliveryBehavior:(unsigned char)`, `setLocationRepeatBehavior:(unsigned char)`,
  `setWifiScanResults:`, `startWifiSimulation`, and holds an `NSXPCConnection`.
- [V] `libobjc` in the 20H392 cache exports `objc_retain_x*`/`objc_release_x*`, which the Xcode build imports.

### 5.2 Files

| File | What |
|---|---|
| `userland/location/negroni-locd.m` | the daemon/CLI (Objective-C, ARC; CoreLocation by `dlopen`, classes by name) |
| `userland/location/entitlements.plist` | `platform-application`, `com.apple.private.security.no-sandbox`, `com.apple.locationd.simulation` [V], `com.apple.locationd.authorizeapplications` [V, for `enable`/`disable`, section 6.1], `com.apple.locationd.status` (not needed by the SPI; kept, Preferences.app has it too) |
| `userland/location/com.iosplus10.negroni-locd.plist` | launchd job `listen 5155`; not loaded unless `LOCD_JOB=1`; `KeepAlive` = `SuccessfulExit` false (`stop` and a missing CoreLocation class exit 0, so no restart loop) |
| `userland/location/build.sh` | build + checks + ad hoc sign -> `out/location/userland/` |
| `scripts/location/phone-location.sh` | live phone over SSH: push, remove, set, hold, listen, stream, stop, enable, disable, status, log |
| `scripts/location/root-add-locd.sh` | root image hook: `LOCD=1` (binary), `LOCD_JOB=1` (launchd job); `root-finish.sh` calls it (default off); `root-update.sh` hook `location` |
| `scripts/ios16/root-tweaks-extra.py` item 7 | L0 switch key in the root (default on since section 6; `LOCATION_SWITCH=0` leaves the root as is) |

`negroni-locd` commands (options before the command):

- `set LAT LON [ACC]`: `stopLocationSimulation`, `clearSimulatedLocations`, `appendSimulatedLocation:`
  (a `CLLocation` with the time now, ACC m, default 10), `flush`, `startLocationSimulation`, `flush`, exit.
  [I] call order (as Xcode's device location simulation is said to do).
- `hold LAT LON [ACC]`: the same, then again every `-r SEC` (default 1) with a new timestamp, until SIGTERM.
- `listen [PORT]`: UDP on `-a ADDR` (default 192.168.7.2:5155), only from `-s ADDR` (default 192.168.7.1; `any`).
  Each datagram: lines `LAT LON [ACC]` or `stop`; the last valid line wins. The last position is sent again every
  `-r SEC`. Bind failures retry every 5 s (the USB address comes late at boot).
- `stop`: SIGTERM to the `hold`/`listen` process (pid file `/private/var/run/negroni-locd.pid`), then stop + clear.
- `enable` / `disable` / `status`: `+[CLLocationManager setLocationServicesEnabled:]`, `+locationServicesEnabled`.
- `-b` runs `hold`/`listen` in the background (log `/private/var/log/iosplus10-negroni-locd.log`); on exit the
  simulation stops unless `-k`. Every line also goes to os_log (subsystem `dev.iosplus10.negroni-locd`).
  `-b` forks after the argument checks and before CoreLocation/XPC are used. `stop` acts only on a pid whose
  process name is `negroni-locd` (stale pid file). `-r` accepts 0..3600.

Build (macOS + Xcode, seconds): `userland/location/build.sh`. Result 2026-10-27: arm64, minos 16.0, links only
Foundation/libobjc/libSystem/CoreFoundation, entitlements as above, sha256 in `out/location/userland/SHA256SUMS`.
A macOS build of the same source passed a local smoke test (argument errors, UDP lines, `bad line ignored`,
`stop`, SIGTERM) with 127.0.0.1; that says nothing about locationd on the phone.

### 5.3 L0 root tweak

`root-tweaks-extra.py` item 7 (so `root-finish.sh` and the `tweaks` hook of `sudo scripts/ios16/root-update.sh IN OUT
tweaks`) merges `LocationServicesEnabledIn8.0 = true` into `/private/var/mobile/Library/Preferences/com.apple.locationd.plist`
(binary plist, owner 501:501, 0600, the same helper as the FBLaunchWatchdogScale preference). The read is [V] (5.1); the
file is [V] since section 6.1 (cfprefsd wrote the key there). Default on since section 6; `LOCATION_SWITCH=0` leaves the root
as it is (log line `location: off: LOCATION_SWITCH=0, ...`). A root change needs a new root image (not done here).

### 5.4 Test steps (phone with SSH, `rootrw=1`)

1. L0: Settings > Privacy & Security > Location Services: on (or `scripts/location/phone-location.sh enable`
   after step 2). Keep `scripts/location/phone-location.sh log` open. Expect `#Actor
   handleLocationServicesStatusChange ... 1` and `isLocationServicesEnabled":1`; `status` prints
   `locationServicesEnabled 1`.
2. `userland/location/build.sh`, then `scripts/location/phone-location.sh push`.
3. `scripts/location/phone-location.sh set 48.8584 2.2945 10`. Expect in the log: no `unentitled client
   attempting to simulate location`; `Setting simulation to 1 for all location providers` /
   `Simulation is now ...`; `ClxSimulated, Fix, 1, ll, 48.858...`.
4. Open Maps: blue dot at the Eiffel Tower. If the dot goes away after the CLI exits, use
   `phone-location.sh hold 48.8584 2.2945 10` ([U] whether the simulation survives the client's exit).
5. Stream from the Mac: `scripts/location/phone-location.sh stream LAT LON 10` (Ctrl-C ends the Mac side),
   or `phone-location.sh listen` and own UDP lines to 192.168.7.2:5155.
6. `scripts/location/phone-location.sh stop`; the dot goes away (or stays as the last known fix [I]).
7. Boot test (optional, later): a root with `LOCD=1 LOCD_JOB=1` (and `LOCATION_SWITCH=1`) starts the listener.

### 5.5 Risks

- [U] The simulation listener may not be up (5.1); then `set` has no effect or `flush` waits. Look for
  `Beginning Simulation Service` after the first `set`.
- [U] The call order and the default delivery/repeat behaviour (we do not set them) may give one fix only, or a
  replay. `hold`/`listen` resend every second to cover this.
- Resolved (section 6.1): `enable` needs `com.apple.locationd.authorizeapplications`, not `com.apple.locationd.status`.
- [I] Some consumers drop simulated fixes (`location is simulated, rejecting`): country code, harvesting.
- The UDP listener takes positions from 192.168.7.1 only by default; with `-a 0.0.0.0 -s any` any host on any
  network can move the phone's position.

## 6. Live phone results (2026-10-27, location iOS agent; iOS up over USB, no reboot, no flash)

### 6.1 L0: the switch

- [V] Before: `negroni-locd enable` printed `setLocationServicesEnabled:1 sent` but `locationServicesEnabled 0`. locationd
  logged `CL: _CLDaemonSetLocationServicesEnabled (Fallback)` and `#Spi, connecting process isn't entitled, they shall not
  pass`; CoreLocation logged `#Spi, CLInternalSetLocationServicesEnabled failed`.
- [V] Cause: the SPI handler (locationd 20H392, function at 0x1012d42a0: `valueForEntitlement:` on the CFString at
  0x101c0a418, `isKindOfClass:` NSNumber, `boolValue`) wants `com.apple.locationd.authorizeapplications`. The CFString
  was read from the binary (chained-fixup target 0x18e88fc). `com.apple.locationd.status` is checked by other handlers.
  `/Applications/Preferences.app/Preferences` on the phone has `authorizeapplications`, `status`, `effective_bundle`,
  `defaults_access`, `usage_oracle`.
- [V] After the entitlement: `#Spi, [mobile]/usr/local/bin/negroni-locd is setting location services to enabled`,
  `"property":"locationServicesEnabledStatus", "old":0, "new":1`, `#authsync sending kNotificationLocationServicesStatus`,
  `"BigSwitch":1` for every client (Maps, Weather, the location bundles), no more `location disabled system-wide`.
  `disable` then `enable` works both ways.
- [V] cfprefsd wrote `LocationServicesEnabledIn8.0 = true` to `/private/var/mobile/Library/Preferences/com.apple.locationd.plist`
  (501:501, 0600). After `kill` of locationd, the new locationd read it: 400 `"BigSwitch":1` lines, 0 with 0.
- [I] The Settings toggle (Privacy & Security > Location Services) calls the same SPI with the same entitlement, so it works
  too; it was not tapped in this session.
- The root tweak (item 7) is default on now. The live phone has the switch on.
- [U] Which GNSS device locationd builds: no `Eureka`/`CLGnss...Device`/`ClxGps` line in 2 min with the switch on (only
  `#Manufacturing service complete ... CLGnssProvider`). A fine-accuracy client (Maps) must ask first.

### 6.2 L1: simulation

- [V] `negroni-locd set 48.8584 2.2945 10`: `Simulation start request received`, `Setting simulation to 1 for all location
  providers`, then `@ClxSimulated, Fix, 1, ll, <private>, <private>, acc, 10.00` once per second. No `Beginning Simulation
  Service` line is needed: the listener is on demand. `stop` ends it.
- [V] The course of a simulated fix is not passed on: a fix with course 90 logs `course, -1.0`.

### 6.3 L2: Wi-Fi positioning

- [V] Internet: ue0 is the primary interface (router 192.168.7.1, DNS 1.1.1.1, 8.8.8.8); `nc -z gs-loc.apple.com 443` works.
- [V] Apple's location server answers this not-activated phone: `@AlsFlow, request, tag, 0, wifi, 1, surrounding, 100`,
  CFNetwork `status 200`, `transaction_duration_ms=855`, interface ue0, `@AlsFlow, reply, tag, 0, wifi, rtt, 0.9, aps, 1`.
- [V] wifid scans for locationd: `Async scan requested by "locationd"`, `found 64 networks`; locationd gets
  `WifiMgr, onWiFiDeviceClientScanCallback, error, 0, valid, 1, count, 64`.
- [V] Blocker: `WifiScan, addAps, scan, returned, 64, unique, 1, insert, 1, keep, 0, error, 0, stale, 63`. Debug lines
  (`oslogstream -l -g "WifiScan, add" locationd`): `WifiScan, addAp, 2, stale, <private>, age, 368.709s, max 5.000s`, and
  19 s later the same APs at 387 s. locationd keeps only APs younger than 5 s.
- [V] Why: Wi-Fi is joined (`JOIN associated (SSID of 15 bytes) AID 2` at 19:36:45). `negroni_wlan_scan()` (patch 0326)
  returns EBUSY when the link state is not IDLE/SCANNING; `nwios_scan()` (0340) then answers with the last list:
  `NEGRONI WLAN iOS: scan refused by the driver (error 16): answering with the last list` (77 times in
  logs/usblog-20261027-171256.txt). The ages are right (0341 `age_ms` = now - `seen_ms`), but no BSS except the joined
  one gets a new `seen_ms`. The one fresh AP is not in Apple's database (`AlsWifi, unknown`), so `@ClxWifi, Fix, 0, ll, N/A`.
- Not fixable on the iOS side: locationd's 5 s limit is in its code; a fake list through `setWifiScanResults:` would need
  fresh data from the same kernel. No code was added for L2; the kernel line above is the one "off" line.
- Fix (kernel Wi-Fi, not this session): scan while joined. ath11k sends WMI_START_SCAN on the STA vdev while
  associated (firmware does the off-channel dwell and returns to the home channel); our driver can let
  `negroni_wlan_scan()` go on in the joined state with the scan state machine not touching `g_link.state`. Test: with Wi-Fi
  joined, `stale` in `WifiScan, addAps` drops from 63 to ~0 and `@ClxWifi, Fix, 1` follows. [I] With Wi-Fi not joined the
  driver scans for real (state IDLE), so a fix should come then already; not tested (other agents use Wi-Fi now).

### 6.4 negroni-locd input interface (for a later kernel GNSS source)

The modem GNSS work (path C) is another agent's. Nothing is agreed; negroni-locd only keeps one clean input:

- Record: `struct nl_fix { lat, lon, hacc, alt, vacc, speed, course }` (degrees WGS-84, m, m, m, m/s, degrees; `vacc -1` =
  no altitude, `speed`/`course -1` = unknown). Every source fills it; `fix_deliver()` is the only output (a `CLLocation` with
  the delivery time into `CLSimulationManager`). Fixes reach apps as `isSimulatedBySoftware = 1`.
- Text form, one fix per line: `LAT LON [HACC [ALT VACC [SPEED COURSE]]]` (2, 3, 5 or 7 fields, spaces or tabs), or `stop`.
  Range checks: LAT -90..90, LON -180..180, 0 < HACC <= 100000, VACC -1 or 0 < VACC <= 100000 with ALT -1000..100000,
  SPEED -1 or 0..1000, COURSE -1 or 0..360. Bad lines are logged (`bad line ignored`) and dropped.
- Today's transport: UDP `listen` (192.168.7.2:5155 from 192.168.7.1). [V] `12.9716 77.5946 25 920 15 1.5 90` gives
  `ClxSimulated, Fix, 1, ... acc, 25.00`.
- For a kernel source, the simplest contract: the kernel gives the same text lines (a character device or a sysctl
  string), one line per new fix, only when the fix is valid and fresh; negroni-locd gets a second reader for it that
  feeds `parse_fix()` -> `fix_deliver()`. With no source present it turns off with one log line (no-probes rule). The
  time of the fix stays the delivery time (CoreLocation's simulation takes the `CLLocation` as given; a source must not
  send old fixes).

