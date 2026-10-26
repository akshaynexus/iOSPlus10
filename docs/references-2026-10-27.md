# Reference repos: solutions we have not taken yet (2026-10-27)

Scope: the reference ports in `external/` and the newer HakiOS clone `out/src/hackios-next` (HEAD `8851317`,
2026-10-26; the reference pin `external/hackios-xnu-kernel` is the old `d82c64a`, see `docs/hackios-2026-10-26.md`).
Goal: per subsystem, what a reference does, which hardware path it uses, what we have, the gap, and the cost to take it.
Nothing was run on the phone. No file outside this document was changed.

Tags: [V] = read in the file at the cited line, or seen in our own data (`out/live.dts`, `out/dsc`, firmware
listings). [I] = inference or memory, not checked. HakiOS paths are relative to `out/src/hackios-next/`.

Repos read (HEAD): hackios-next `8851317`, hackios-xnu-userland `a79ff07`, slop `4a754c1`, ios-flame `745c434`,
bergamota `0826e48`, ios-sailfish `6f27e41`, ios-spes `2cd45c4`, ios-s9 `7b72f7c`, ios-apollo `1c1a199`,
ios-sweet(-upstream) `45263be`, UniXNU `74aa94d`, UniXNU-pong `ab74f07`, UniXNU-zeta `318b2ea`, UniXNU-ios26 `68c5134`,
UniXNU-negroni `f812002`, Chlorophyll `787338f`, metal2vulkan `720ef1ce`.

## 0. Summary

| Subsystem | Any reference has it working? | Best source | Our state |
|---|---|---|---|
| Sensors (accel/gyro/mag/prox/ALS) | **No** (every README lists sensors as missing) | none; our own HID event code (slop 0058) | nothing |
| Location | **No** (HakiOS denies `locationd`) | HakiOS modem boot + read-only RMTFS (`hakios.mpss.c`) for a later GNSS path | `locationd` runs, fairplayd dropped |
| Camera in Camera.app | **Yes, HakiOS** (`cam=5`: preview, AF, zoom, HEIC) | `camera_device.c` + `camera_isp.c` + `inject_media.c` | kernel levels 0-6 built, no iOS side |
| Wi-Fi in Settings | **Yes, HakiOS, ios-sailfish, ios-flame** | HakiOS `hakios.wlan.cpp` + `hakios.apple80211.c` + `wifi/lx` (real ath11k) | firmware/WMI/scan built (0260-0324), no data path, no iOS side |
| Bluetooth | **No** (bergamota: transport research, kernel ctl; HakiOS: "not yet") | bergamota `docs/BT_IOS_TRANSPORT.md` (we took it) | 0330-0333 + BlueTool stand-in built |
| Vibration | **Yes, HakiOS** (`haptic=5`) | `rc.jobs.haptic`, `rc.jobs.haptic2` (test plan) | same design built (0300-0303), not run |
| Mic | **Yes, HakiOS** (bottom mic only) | `hakios.mic.c` (codec side), `audio_plugin.c` "Codec" | planned only |
| Headset | **No** | none | not started |
| 120 Hz | partial (slop: no MG gate) | HakiOS `MiniIOMobileFramebuffer.cpp` `TimingElements` | TE/VRR built, no `TimingElements` |
| Battery UI | **Yes, HakiOS** (via ADSP battmgr) | `hakios.battery.cpp` (`AdapterDetails` with watts, PD status) | full key set built (0270-0278), not booted |

## 1. Sensors: gyroscope, accelerometer, compass, proximity, ambient light

### 1.1 What the references implement

- [V] No reference drives a motion, light or proximity sensor. ios-s9 `README.md`, ios-sweet `README.md`,
  ios-sailfish `README.md`, ios-flame `README.md`, bergamota `README.md` all list "sensors" under "not working".
  A grep for accelerometer/gyro/proximity/ambient/SLPI over every `NOTES.md` and source file gives no driver.
- [V] HakiOS only removes a wait: `userland/src/inject.c:544-575` replaces `-[BLControl waitForALSArrival]`
  (CoreBrightness, in backboardd) because it waits 5 s for an ALS HID service that never comes. Address check
  `0x1af043734` is for iOS 16.5 20F66 (`inject.c:574`).
- [V] HakiOS feeds touch to backboardd with a userland virtual HID service: `IOHIDVirtualServiceClientCallbacksV2`
  (`inject.c:589-600`) and `IOHIDEventSystemClientCreateWithType`. The same mechanism can carry sensor events from
  a userland daemon [I: not tried by anyone for sensors].
- [V] Our kernel already has the HID event classes for sensors: slop
  `negroni-ios/xnu/patches/0058-negroni-hid-event-services.patch:1086` `IOHIDEvent::accelerometerEvent`, `:1110`
  `gyroEvent`, `:1134` `compassEvent`, `:1158` `ambientLightSensorEvent`, `:1215` `proximityEvent`, `:2036`
  `orientationEvent`, plus an `IOHIDEventService` with `dispatchEvent` and `PrimaryUsagePage` properties
  (`:12182`, `:20671`).

### 1.2 What iOS expects [V strings, I behaviour]

- [V] The 20H392 shared cache (`out/dsc/cache/dyld_shared_cache_arm64.a2s`) has `AppleSPUHIDDeviceClass`,
  `AppleSPUHIDDriverClass`, `AppleSPUAccCompassPlugin(Factory)`, `AppleSPUDispCompassPlugin(Factory)`,
  `AppleSPUHIDStatistics`, and BackBoard `BKSAccelerometer` / `BKAccelerometer_server`.
  [V] No hit for `AppleEmbeddedAccelerometer`, `AppleProxShim`, `DeviceSupportsProMotion`.
- [I] So on the D22 identity the motion, compass, ALS and proximity sensors arrive as IOHID event services made by
  the SPU driver; backboardd (orientation through `BKSAccelerometer`, ALS through CoreBrightness, proximity for the
  call screen) and `locationd` (CoreMotion lives in locationd) match them by `PrimaryUsagePage`/`PrimaryUsage`
  (Apple vendor pages, e.g. 0xff0c for motion [I]). Plugins `AppleSPU*CompassPlugin` are IOHID service filter
  plugins that match properties of the SPU service [I]. Exact usage numbers and matching properties: read them from
  the D22 ADT/kernelcache and the IOHIDFamily open source before writing code.

### 1.3 Hardware path on SM8450 [V]

- All sensors hang on the SLPI (sensor DSP). AP side: `out/live.dts:6431-6474` `remoteproc-slpi@02400000`,
  `qcom,waipio-slpi-pas`, memory `slpi_region@87F00000` size 0x1a00000 (`:124-128`), GLINK edge remote-pid 3,
  label `dsps`, channel `IPCRTR` net-id 2, `qcom,no-wake-svc = <0x190>` (QMI service 400 = SNS client),
  channel `fastrpcglink-apps-dsp`; `qcom,msm-ssc-sensors` firmware `slpi` (`:6520-6526`).
- Linux: `out/src/linux/drivers/remoteproc/qcom_q6v5_pas.c:1382-1394` (`firmware_name "slpi.mdt"`, `pas_id 12`,
  proxy PDs lcx/lmx, `ssr_name "dsps"`) and `:1900` (`qcom,sm8450-slpi-pas` uses that table).
- Chips (`out/live.dts:37015-37060` `oplus,sensor-devinfo`, decoded with
  `out/src/op-modules` `vendor/oplus/sensor/kernel/qcom/sensor/oplus_sensor_devinfo.h:44-101`): gsensor
  `sensor-name 0x10` = LSM6DSO (accel + gyro), msensor `0x01` = AKM09918 (compass, soft-iron matrix in the DT),
  lsensor/psensor `0x02` = TCS3701 (ALS + proximity, bus 2, irq 14), plus CCT sensors. No AP-side I2C node for them.
- Firmware [V]: `out/firmware/adsp/LISTING.txt:442-465` `slpi.mdt` + `slpi.b00..b23` in the NON-HLOS image;
  `:7-8` `slpir.jsn`, `slpius.jsn` (servreg root PD + user PD).

### 1.4 What we have, and the gap

- [V] We have the pieces for a third DSP: ADSP PAS boot + SMP2P + GLINK over SMEM (0240, 0242), QRTR (0265 for
  WLAN, 0243 for ADSP), QMI encode/decode tables (0266), the HID event classes (slop 0058), and the firmware-area
  format (`scripts/fw/checkarea.py:16-21`, ADSP area 32 MiB).
- Gap: SLPI PAS 12 boot (a copy of the ADSP steps with the SLPI numbers), a GLINK edge for pid 3, a QRTR node,
  an SNS client (QMI service 400; the payloads are protobuf `sns_client_*` messages [I]), and one HID event service
  per sensor type.
- [I] Largest risk: the SSC registry and config (`/vendor/etc/sensors/config/*.json`, persist registry) are served to
  the SLPI from Android userland (`sscrpcd` over FastRPC, the `fastrpcglink-apps-dsp` channel). Without that service
  the SLPI may start with no physical sensor drivers. Check the SLPI log (SMEM item / QDSS) after a bare boot first.

### 1.5 Estimate

| Step | New code | Risk |
|---|---|---|
| S1 SLPI PAS boot + GLINK + QRTR HELLO, list services (copy of 0240/0242/0265 with SLPI numbers) | ~600 lines kernel | low: same method as ADSP |
| S2 SNS client: suid lookup, enable accel at 50 Hz, decode samples | ~1 500 lines (protobuf subset) | high: registry over FastRPC [I] |
| S3 `NegroniSensors` IOHIDEventService x5 (accel, gyro, compass, ALS, prox) | ~500 lines kernel | medium: usage pages and properties must match the SPU plugins |
| S0 (cheap, now) take HakiOS `waitForALSArrival` skip into our backboardd injection | ~40 lines | low; re-derive the 20H392 address |

No reference code to take for S1-S3.

## 2. Location services

### 2.1 What the references do [V]

- HakiOS removes `locationd`: `userland/mkjobs.py:216` `DENY = (... 'locationd', ...)` (same line in
  `external/hackios-xnu-userland/userland/mkjobs.py:216` and `external/UniXNU-pong/userland/mkjobs.py:216`).
- ios-flame `HANDOFF.md:238-245`: fairplayd.H2 relaunch loop blocks `-[CLMescalSigner initInSilo:]` and deadlocks
  locationd and every synchronous CoreLocation caller; fix = remove the fairplayd job. We already do this
  (`scripts/ios16/root-tweaks-extra.py:5-9,40`).
- No reference sets the Location Services switch, and none has GNSS.
- HakiOS starts the modem: `xnu/files/bsd/dev/hakios.mpss.c:1-60` (PAS image 4, SMP2P, GLINK `IPCRTR`, QRTR, QMI
  DMS/NAS), and serves RMTFS (QMI service 14) **from memory only**: `hakios.mpss.c:3526-3577` reads
  modemst1/modemst2/fsc/fsg once and never writes storage; `VMID_NAV 0x2b` for the shared buffer.

### 2.2 Hardware path

- [I] GNSS on SM8450 is in the modem (MPSS): QMI LOC service (0x10) over QRTR after the modem is up; it needs
  RMTFS (the four modem partitions), pd-mapper/servreg, and the `qcom,rmtfs_sharedmem` buffer with the NAV VMID.
- [V] `modem.mdt` is in our NON-HLOS listing (`out/firmware/adsp/LISTING.txt:421`), `modemr.jsn` too.
- [V] Our ADT already says `gps-capable` under `/product` (strings of `out/ios16/negroni.adt`).

### 2.3 What we have, and the gap

- [V] locationd runs without the fairplayd deadlock. [I] "Location Services: off" in Settings comes from the
  preference that Setup.app writes (key `LocationServicesEnabledIn7.0` in `com.apple.locationd.plist`, root
  preferences) because we skip Setup. Not verified: read the key name in 20H392 `locationd` before a root tweak.
- [I] With the switch on and Wi-Fi working, locationd can use Wi-Fi positioning (scan results from wifid, Apple's
  servers). That gives a position with no GNSS code. Needs Wi-Fi first (section 4).
- Gap for GNSS: modem boot (none in our tree), read-only RMTFS, QMI LOC client, and a feed into locationd. [I] The
  feed is the hard part: on a D22 locationd gets GNSS from the baseband stack (CommCenter/`BBLocation` or a GPS
  daemon); we have no source for that interface.

### 2.4 Estimate

| Step | Cost | Risk |
|---|---|---|
| L1 root tweak: Location Services on (one plist key) | ~20 lines Python in `root-tweaks-extra.py` | low; key name [I] |
| L2 Wi-Fi positioning | 0 new code after Wi-Fi works | Apple server access without activation [I] |
| L3 modem boot + read-only RMTFS (port of `hakios.mpss.c` steps 1-10 and its RMTFS part, ~6 400 lines on SM7325) | ~3 000-4 000 lines for SM8450 | high: IPA/modem differences; the modem partitions must stay read-only (owner rule) |
| L4 QMI LOC + locationd feed | unknown | very high: no reference |

## 3. Camera (Camera.app shows black)

### 3.1 What HakiOS implements [V]

- Status: `docs/ru/notes.md:34`: rear + front cameras in Camera.app, live preview, colours from the camera tuning,
  AF + tap to focus, zoom, HEIC stills; no video/Live Photo (the capture session audio path is missing).
- No AppleH10CamIn emulation. HakiOS replaces the **device vendor** of CMCapture inside mediaserverd:
  - `userland/src/inject_media.c:24-29,100-125`: hook of `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]`;
    when `/dev/hakios-camera` exists it returns
    `[[BWFigCaptureDeviceVendor alloc] initWithDeviceCreateFunction:hakios_camera_device_create]`.
  - `inject_media.c:485-505` the full hook table (each with the expected 20F66 address): portrait prewarm skipped,
    `BWAudioSourceNode start:`, video stabilisation off (no ISP processing session), still quality, `BWGNRNode`
    render, `BWNodeOutput emitSampleBuffer:`; `:536-560` constructor (mediaserverd only), HEVC encoder registered
    from `HEVCVideoEncoder_CreateInstance` + `VTRegisterVideoEncoderWithInfo` (`:420-424`) for HEIC.
  - `userland/src/camera_device.c:1-31`: a `FigCaptureDevice` with two `FigCaptureStream`s (CoreMedia derived
    objects, vtables as in H10ISP of 16.5): device `RequestStreams`/`RelinquishStreams`; stream `Start`, `Stop`,
    `AddAttachmentsToSampleBuffer`; frames go out through `VideoOutputHandlers` blocks as CVPixelBuffers; formats
    named as in CMCapture `D22/AVCaptureSession.plist` so presets resolve; `StillImageCaptureNow` = one full frame;
    contrast AF with tap window. 1 828 lines.
  - `userland/src/camera_isp.c` (1 033 lines, MIT): CPU ISP: black level, lens shading, white balance to the
    sensor's reference lights, AE gains, CCM, sRGB curve, bilinear demosaic, zoom.
  - Injection: launchd starts the listed jobs with `DYLD_INSERT_LIBRARIES` (`userland/src/inject.c:1-25`), allowed by
    their AMFI stand-in.
- Kernel ABI (`userland/src/hakios.camera.h:1-12,22-62`): `/dev/hakios-camera`; open = power up + stream, read =
  newest frame with a header (size, stride, RAW10, Bayer order, black level, sequence, time, exposure lines, line
  ns, focus), write = commands (`struct hakios_camera_command {command, bytes, a, b, c, d}`: exposure, gain, focus,
  sensor switch).
- ADT nodes that make iOS show and use the camera (`docs/ru/notes.md:1712-1722`): `/arm-io/isp` with only
  `camera-rear` = 1 (no `compatible`, no driver) -> MobileGestalt `still-camera`, `rear-facing-camera`;
  `/product/camera` with `flash` -> `camera-flash` (Control Center torch); `video-camera` with `cam=5`.
- Licence: `userland/src/*` MIT (`LICENSE:9-12`); `xnu/files/bsd/dev/hakios.camera.c` APSL 2.0 (SM7325 CAMSS, not
  needed: we have our own kernel side).

### 3.2 Hardware path

- HakiOS: CSID-lite/IFE-lite RDI 0 to memory, CPU ISP (`docs/hackios-2026-10-26.md` section 5).
- Ours [V]: CSID0 + IFE0 RDI0, IMX789 4000x3008 RAW10 over C-PHY (0315), ICP via PAS 33 (0316), not needed for this
  path.

### 3.3 What we have, and the gap

- [V] Kernel levels 0-6 built, not run (`patches/xnu/README-camera.md:121-205`). Frame access is one frame per read on
  `/dev/negronicam-tpg|-sensor` with a 64-byte `NCAMRAW1` header (`README-camera.md:184-189`).
- [V] Our plan picks "own NegroniCamera service + own capture app" first and an AppleH10CamIn subset later
  (`docs/camera-plan.md:283-300`). HakiOS proves a third way: stock Camera.app through a replaced device vendor, no
  ISP firmware protocol at all.
- [I] Why our Camera.app is black: `sharedCaptureDeviceVendor` returns nil (no H10ISP device), so the session has no
  input. The HakiOS hook is the exact fix.
- Gaps:
  1. Kernel: a streaming mode (ring of buffers, BUF_DONE IRQ or poll, newest-frame read), exposure/gain writes over
     CCI (IMX789 0x0202/0x0204 [I]), AK7377 AF position, sensor switch (rear main / front IMX615). Match the HakiOS
     header fields so `camera_device.c` needs few edits.
  2. Userland: port `camera_device.c` + `camera_isp.c` (MIT) into a `libnegroni.media.dylib`, port the hook part of
     `inject_media.c`; re-derive every expected address for 20H392 (our `out/dsc/20H392.a2s`). The table checks the
     address and leaves a method alone on mismatch, so a wrong address fails safe [V `inject_media.c:517-533`].
  3. ADT: `/arm-io/isp` `camera-rear` (and front), `/product/camera` (`flash` only when a torch driver exists).
  4. Tuning: HakiOS uses the camera module tuning (CCM, lens shading) of its own phone; ours must come from the
     OnePlus CAMX tuning files [I: format].

### 3.4 Estimate

| Item | Lines | Risk |
|---|---|---|
| kernel stream + controls (on 0315) | ~1 200 | medium: IRQ/ping-pong on IFE 680 |
| `camera_device.c` port | ~1 800 taken, ~200 changed | medium: CoreMedia vtable layout 16.5 vs 16.7 [I] |
| `camera_isp.c` port | ~1 000 taken | low (pure C); speed of a 12 Mpx CPU ISP: use binned 2000x1500 preview [I] |
| hooks + addresses | ~560 taken, ~30 addresses | medium |
| ADT nodes | ~20 TOML lines | low |

## 4. Wi-Fi

### 4.1 What HakiOS implements [V]

- Status (`docs/ru/notes.md:181-219`): WPA2-PSK join, DHCP, DNS, HTTPS, 55-90 Mbit/s; Settings shows the network,
  the scan list, the tick, the on/off switch, wrong-password message; join from Settings by touch proven on the phone.
  Missing: WPA3, open networks, power save.
- iOS side, in the kernel, no IONetworkingFamily:
  - `xnu/files/iokit/Kernel/hakios.wlan.cpp:1-24,107-130` (137 lines): two property-only classes named
    `IO80211Controller` and `IONetworkInterface`; the interface has `IOInterfaceName`/`BSD Name` = en0,
    `IOInterfaceNamePrefix`, `IOInterfaceType`, `IOInterfaceUnit`, `IOBuiltin`, `IOPrimaryInterface`,
    **`IO80211InterfaceRole = "Infrastructure"`** (wifid's match); the controller has `IOMACAddress`. No user client:
    IO80211.framework then says "Falling back to IOCTL path".
  - `xnu/files/bsd/dev/hakios.apple80211.c:1-32,47-48,295-439` (739 lines): `SIOCGA80211`/`SIOCSA80211`
    (0xc02869c9/0x802869c8) answered from the station layer: card caps (12), power (19), op mode (15), channels
    (27, 254, 207), assoc result (21), scan result (11), state (13), SSID (1), BSSID (9), channel (4), RSSI (16),
    auth type (2), driver/hardware names (43, 44); sets: associate (20), disassociate (22), power (19), scan (10);
    events = kernel events class 6 subclass 1 with the interface name in 16 bytes.
  - `xnu/files/bsd/dev/hakios.net.c:1-14,266` (428 lines): en0 by the BSD interface KPI (like `if_fake.c`), unknown
    ioctls go to the Apple80211 code when the link is a radio.
  - `xnu/files/bsd/dev/hakios.sta.c:1-18` (371 lines): one worker thread for scan/join requests, the standing
    network from a file, rejoin after the switch or a wrong password.
  - `userland/com.hakios.wifi.plist` + `userland/src/net_test.m`: a launchd job that asks configd to configure the
    interface.
- Driver: real Linux ath11k, unmodified, on FreeBSD LinuxKPI headers + their layer `wifi/lx` (MIT,
  `NOTICE:20-21`): `tools/mk-ath11k.sh:1-31,117` (Linux 7.0.14, FreeBSD 15.1; built files
  `core hal qmi ce hw fw htc wmi mac reg peer dp dp_rx dp_tx hal_rx hal_tx dbring p2p`), `wifi/lx/src/lx_base.c`
  (1 235: locks, work, memory, firmware), `lx_80211.c:1-24` (2 097: a mac80211/cfg80211 stand-in: regdomain, one
  STA, scan, open-system auth, assoc, keys, Ethernet frame mode), `lx_wpa.c:1-10` (523: SHA-1, HMAC, PBKDF2, PRF,
  AES unwrap, 4-way + group handshake, own code, tested), `lx_bus.c:1-24` (863: replaces ath11k `ahb.c` for the
  WCN6750), kernel glue `xnu/files/bsd/dev/hakios.lx.c` (582, APSL).
- ios-sailfish (QCA6174, ath10k-class, own driver) and ios-flame (WCN3990, userland `phone/wifi/wland.c` over
  `/dev/pmem`, 5 513 lines) reach the same iOS result with the same ioctl contract (flame 0123 takes HakiOS's
  `redwood_apple80211.c`).

### 4.2 Hardware path

- HakiOS: WCN6750 on the SoC (WPSS DSP, AHB), QMI WLFW over GLINK. Ours [V]: WCN6855 over PCIe + MHI, QMI WLFW over
  QRTR on MHI channel 21 (0261-0266), CE/HTC/WMI/scan built (0320-0324).

### 4.3 What we have, and the gap

- [V] Our iOS-side decision (`patches/xnu/README-wifi.md:434-445`) = the same ioctl contract, but with
  IONetworkingFamily staged into the kernel as sailfish does (`0175-stage-ionetworking.sh`). HakiOS shows the lighter
  way: two property-only registry classes (137 lines), no IONetworkingFamily.
- [V] Our remaining driver work is "about 7 000 lines" (`README-wifi.md:446`): join, a WPA2 supplicant (~1 500),
  HTT data path (~2 000), iOS glue (~2 300).
- Option A (take the iOS side only): `hakios.wlan.cpp` + `hakios.apple80211.c` + `hakios.net.c` + `hakios.sta.c`
  (~1 680 lines, APSL) on top of our own driver; replaces our planned ~2 300 lines of iOS glue. Also `lx_wpa.c`
  (523 lines, MIT) replaces our planned supplicant.
- Option B (take the driver too): build ath11k (`pci.c`, `pcic.c`, `mhi.c` instead of `ahb.c`) on `wifi/lx`.
  [I] ath11k `mhi.c` calls the Linux MHI host API (`drivers/bus/mhi/host`, GPL-2.0): we must provide that API on our
  own MHI code (0261-0264) instead of taking Linux's. [I] ath11k expects the linux-firmware WCN6855 layout
  (`amss.bin`, `m3.bin`, `board-2.bin`); our files are the Android cnss2/cld3 set (`bdwlan.elf`, `regdb.bin`, `m3.bin`):
  test whether the Android `amss` accepts the ath11k host first, or fetch the linux-firmware WCN6855 hw2.1 files.
- [I] B saves the HTT data path and join code (the largest part) and gives a tested driver; the cost is the LinuxKPI
  build in our kernel build (`xnu-deps` style, clang, ~150 MB + 253 MB source archives) and the PCI/MHI shim.

### 4.4 Estimate

| Option | Take | Write | Risk |
|---|---|---|---|
| A | 1 680 (APSL) + 523 (MIT) | ~3 500 (join, HTT) | medium |
| B | A + `wifi/lx` 4 827 (MIT) + `hakios.lx.c` 582 + ath11k (unmodified, fetched) | ~1 500 (PCI + MHI shim, firmware glue) | high at first (build system, firmware choice); lower in the long run |

License: HakiOS `xnu/files/**` is APSL 2.0 (`LICENSE:3-8`): keep the notices; our XNU patches are APSL anyway.
`wifi/lx` and `tools/` are MIT; ath11k is BSD-3-Clause-Clear (`mk-ath11k.sh` checks each file's SPDX).

## 5. Bluetooth

### 5.1 What the references implement [V]

- No reference has pairing. HakiOS: "Bluetooth" in the "not yet" column (`README.md` status table).
- bergamota `docs/BT_IOS_TRANSPORT.md:13-27` (295 lines): bluetoothd/BlueTool use a kernel control socket
  `com.apple.uart.bluetooth` (plain) or `.sk.` (Skywalk), H4BC transport (ADT `transport-encoding` 3), a registry entry
  named `bluetooth` with `local-mac-address`; BlueTool runs Broadcom scripts only. bergamota `NOTES.md:19-24`:
  `BT_DEVICE_ADDRESS` is always discarded (iOS 16 and 18), kernel ctl patch 0136; after the address checks were
  patched out, bluetoothd aborted with "LeSecurityManager hit a keychain problem" (`0xbd15dead`, main thread in
  `mach_msg` to securityd).
- bergamota `tools/sweetnet/bluetool-stub.c` (146), `hcitest.c` (273); patches 0118-0136 (WCN3990 UART, IBS, NVM).

### 5.2 What we have, and the gap

- [V] We took all of it already: 0330 power + UART, 0331 HCI/firmware, 0332 H4 transport (`com.apple.uart.bluetooth`,
  `/dev/uart.bluetooth`, `/dev/cu.bluetooth`, `/dev/btwake`, step 20 BD address), 0333 HCI shim for Broadcom vendor
  commands, `negroni-bluetool` stand-in, `ADT_BT=1` node (`patches/xnu/README-bluetooth.md:135-160`,
  `docs/bluetooth-plan.md:46-48`, `scripts/ios16/adt-extra.py:12-17`).
- Gap 1 [I, from bergamota]: the keychain for bluetoothd (LE security keys, link keys). HakiOS shows a keychain that
  works without SEP (`MiniAppleKeyStore.cpp`, `docs/ru/notes.md:175-180`); check that our 0220 (AKS no passcode)
  gives bluetoothd a working keychain before pairing tests.
- Gap 2 [I]: audio over BT (A2DP/HFP) needs bluetoothaudiod + a BT audio HAL device; no reference.
- Nothing new to take. Next action is the phone test of 0330-0333.

## 6. Vibration (haptics)

### 6.1 What HakiOS implements [V]

- `xnu/files/bsd/dev/hakios.haptic.c:25-40,661-700` (1 005 lines, APSL): Awinic AW86927 over I2C; `haptic=5` plays
  what iOS plays on the HAL "Actuator" device: a waveform shorter than 60 ms = tap (Android waveform 1), longer =
  loop waveform 11, gain from the waveform peak, cut at `HAPTIC_MAX_MS`.
- `userland/src/audio_plugin.c:26-28,220,967-1017`: HAL device UID "Actuator", one output channel, samples written
  to `/dev/hakios-haptic`.
- ADT: `/product/haptics` `closed-loop`, `supports-3rd-party-haptics` taken from the D22 device tree
  (`xnuloader/mkidentity.py:11-14,100`).
- Test plans: `userland/rc.jobs.haptic` (system sounds 1519/1520/1521/4095, CoreHaptics tap/vibration/3 taps and one
  longer than the 1 s limit, home-screen long press) and `rc.jobs.haptic2` (long press on an icon, Airplane Mode
  switch in Settings, Control Center brightness long press).

### 6.2 What we have, and the gap

- [V] Same design, different chip: PM8350B HV haptics (0300 direct play, 0301 `vibrator` service, 0302
  `/product/haptics` + `/dev/negroni-haptic` + NegroniAudio "Actuator", 0303 brake + hBoost wait)
  (`docs/notes.md:1987-2032`, `docs/haptics-plan.md` section 8). Built, not run.
- Gap: only the test. Take the two job lists as the phone test plan; our touch tool replaces `rwtouch`.
- [I] One difference to try if taps feel weak: HakiOS plays a fixed Android tap waveform per iOS tap; we map the
  envelope to direct-play amplitude. The PM8350B has pattern/FIFO modes for a fixed short tap.

### 6.3 Estimate

Test script ~60 lines (`scripts/haptics/`). No kernel code.

## 7. Audio: microphone and headset

### 7.1 What HakiOS implements [V]

- `xnu/files/bsd/dev/hakios.mic.c:1-40` (1 847 lines, APSL): main mic on SM7325 = analog mic on WCD938x ADC1 over
  SoundWire into TX macro decimator 1, codec DMA `TX_CDC_DMA_TX_3`, ADSP AFE/ASM (APR). Steps `mic=1..4`; `mic=4`
  opens the path only while iOS records (`/dev/hakios-mic`, 341 ms ring, `docs/ru/notes.md:392`).
- HAL device "Codec" with one input in `audio_plugin.c`. Voice Memos records (`docs/ru/notes.md:33`).
- Only the bottom mic. No headset. No capture-session audio for video (`inject_media.c` `BWAudioSourceNode`).

### 7.2 Hardware path on our phone [V `docs/audio-plan.md:305-314`]

- Built-in mics are DMIC3 + DMIC4 on the SoC TX macro; only the bias comes from the WCD938x. Headset = USB-C analog
  through `fsa4480` (I2C 0x42) + WCD938x HPH/AMIC2 + MBHC. ADSP side is AudioReach/GPR (not APR).

### 7.3 Gap and what to take

- Our NegroniAudio already has the "Codec" UID (`userland/audio/test-host.c:134`); the kernel mic path is planned
  only (`docs/audio-plan.md:376-379`).
- Take from `hakios.mic.c` as data, not code (APSL, APR-specific): the order of LPASS core/audio HW votes, TX macro
  clock start (`fs-gen-sequence`, MCLK), SoundWire master init (frame 50x2, auto-enumeration), WCD938x TX device
  enumeration and mic-bias setup. Our DSP side must be a GPR/AudioReach TX graph (like 0247 for RX).
- Headset: no reference. [I] fsa4480 switch + WCD938x RX + MBHC is a separate stage (~1 500 lines).

### 7.4 Estimate

Mic: ~1 500-2 000 lines kernel (DMIC TX macro + GPR TX graph + bias over SoundWire), ~100 lines in NegroniAudio.
Risk medium-high: SoundWire master bring-up is new for us. Headset: later.

## 8. 120 Hz

### 8.1 What the references do

- [V] slop `NOTES.md:3-13`: vsync timer 8333 us; "No MobileGestalt/ProMotion gate found in the 20H392 dyld shared
  cache". [V] Our grep of the 20H392 cache: no `DeviceSupportsProMotion` string.
- [V] HakiOS `xnu/files/iokit/Kernel/MiniIOMobileFramebuffer.cpp:329-379`: publishes `TimingElements` (one timing:
  `HorizontalAttributes`/`VerticalAttributes` with `SyncRate` and `PreciseSyncRate` = Hz << 16, `ColorModes`) and
  `ColorElements`, "the way CoreAnimation reads them"; rate from boot-arg `fb_hz` (`:79,154,187-189`, 1-240).
- [V] HakiOS `userland/rc.jobs.fps`: a fixed swipe/scroll sequence for frame-pacing measurement (`tools/frames.py`).

### 8.2 What we have, and the gap

- [V] We set `IOMFBDisplayRefresh` (0253, 0259) and `CA_HEARTBEAT_RATE=120` for backboardd
  (`scripts/ios16/root-tweaks-extra.py:30-35,68`); TE lock and VRR built (0259, `docs/display-refresh-plan.md`).
- [V] No patch of ours or of slop publishes `TimingElements` (grep over `patches/xnu` and slop patches).
- [I] Without a timing mode, `UIScreen.maximumFramesPerSecond` and the CADisplayLink cap may stay at 60 even when
  backboardd composites at 120. Add `TimingElements` with `SyncRate = 120 << 16` to NegroniFramebuffer and read
  `maximumFramesPerSecond` with a small probe.

### 8.3 Estimate

~80 lines kernel (port of `publishModes`, APSL) + a probe app. Risk low. Also take `rc.jobs.fps` as the 120 Hz
test sequence.

## 9. Battery: charging status and speed

### 9.1 What HakiOS implements [V]

- `xnu/files/iokit/Kernel/hakios.battery.cpp:1-20,100-185` (230 lines): `IOPMPowerSource`; values from the ADSP
  battery manager over pmic_glink (`hakios.adsp.c:2617-2654`: owner 32778, opcodes 0x30 battery / 0x32 USB, property
  numbers read on the phone with `battmgr=2`).
- `IsCharging` = external && PD `BATT_STATUS == 1` (charging); `FullyCharged` = status 4 or 100 %;
  `AdapterDetails` = `Watts` (USB V x I), `Current`, `AdapterVoltage`, `FamilyCode` from the PD's `USB_TYPE`
  (SDP 0xe0004000, DCP 0xe0004004, CDP 0xe0004005, Type-C 0xe0004009, PD 0xe000400a, else 0xe0004007),
  `IsWireless` false; `CycleCount`, `DesignCapacity`, `NominalChargeCapacity`, `AppleRawMaxCapacity` from the gauge.

### 9.2 What we have, and the gap

- [V] Our key set is larger (`patches/xnu/README-battery.md:131-148`), and 0274/0277 already talk to the same ADSP
  charger PD over `PMIC_RTR_ADSP_APPS` (`README-battery.md:442-495`, `:591-668`). Not booted.
- Gaps [V by comparison with README-battery.md:131-145]:
  1. `IsCharging` is a current heuristic (> 50 mA); HakiOS uses the PD charge status. Use the PD status when the
     GLINK path is up, keep the heuristic as fallback.
  2. `AdapterDetails` is fixed `0xe0004007` without `Watts`; take the HakiOS family-code table and the watts
     from USB voltage x current (the "charging speed" a UI or tool can show).
  3. `TimeRemaining`/`AvgTimeToFull` are 0xffff; [I] compute time to full from charge current and the gauge mAh.
- [I] SUPERVOOC (OnePlus charge pump) is outside the PD's standard USB types; expect PD/unknown family codes.

### 9.3 Estimate

~120 lines in NegroniBattery (APSL source as model, our own code). Risk low.

## 10. Extra found: flashlight

- [V] HakiOS `xnu/files/bsd/dev/hakios.torch.c` (763 lines), `/dev/hakios-torch`; `inject_media.c:14-23,100-140`
  gives FigFlashlight a vendor whose stream sets `TorchLevel`; `/product/camera` `flash` enables the Control Center
  button (`docs/ru/notes.md:1719`). [I] Our flash LED is the PM8350C flash block (SPMI); a driver is ~400 lines.

## 11. Repos with nothing new for these subsystems

- UniXNU, UniXNU-ios26, UniXNU-pong (SM8475), UniXNU-zeta, UniXNU-negroni: boot, UFS, display, touch, Adreno/Metal
  only (`external/UniXNU-pong/README_EN.md`, `drivers/` listing). Chlorophyll, metal2vulkan: GPU only.
- ios-s9, ios-apollo, ios-sweet: no Wi-Fi/BT/camera/sensors (README tables). ios-spes: modem + WLFW, iOS side not
  ported (`README.md`).

## 12. Take this next (ranked)

| # | Item | Take from | Put into | Size | Why first |
|---|---|---|---|---|---|
| 1 | Camera in Camera.app: device-vendor hook + FigCaptureDevice + CPU ISP | `out/src/hackios-next/userland/src/camera_device.c`, `camera_isp.c`, `camera_isp.h`, the hook part of `inject_media.c` (MIT) | new `userland/camera/` + a mediaserverd injection like `scripts/gpu/root-add-negronigl.sh`; kernel stream mode on 0315 (new patch 037x) with a `hakios.camera.h`-like header | ~3 400 taken, ~1 500 new | owner-visible; replaces the long AppleH10CamIn path in `docs/camera-plan.md:294` |
| 2 | Wi-Fi iOS side (registry classes + Apple80211 ioctls + en0 + station thread) and WPA2 code | `xnu/files/iokit/Kernel/hakios.wlan.cpp`, `bsd/dev/hakios.apple80211.c`, `hakios.net.c`, `hakios.sta.c` (APSL); `wifi/lx/src/lx_wpa.c` (MIT) | new patches after 0324; replace the IONetworkingFamily staging plan in `patches/xnu/README-wifi.md:434-445` | ~2 200 taken | proven on a phone with stock wifid; cuts ~3 800 of our 7 000 planned lines |
| 3 | Decide ath11k-on-LinuxKPI (option B) with a one-day spike: build `tools/mk-ath11k.sh` with `pci.c`/`mhi.c` against a stub MHI API | `tools/mk-ath11k.sh`, `wifi/lx/` | `out/` spike, then a doc | spike only | may remove the HTT/join work entirely |
| 4 | Battery: PD charge status, `AdapterDetails` watts + family codes | `xnu/files/iokit/Kernel/hakios.battery.cpp:100-185` | NegroniBattery (0271/0277 follow-up) | ~120 | small, owner asked for charging status/speed |
| 5 | 120 Hz mode: `TimingElements` with 120 Hz | `MiniIOMobileFramebuffer.cpp:329-379` | NegroniFramebuffer (new patch) + probe of `maximumFramesPerSecond`; `rc.jobs.fps` as test | ~80 | small; may lift a 60 fps cap [I] |
| 6 | Haptics phone test plan | `userland/rc.jobs.haptic`, `rc.jobs.haptic2` | `scripts/haptics/phone-test.sh` | ~60 | 0300-0303 are built and untested |
| 7 | Location Services switch on + Wi-Fi positioning | none (own) | `scripts/ios16/root-tweaks-extra.py` | ~20 | cheap once Wi-Fi works; key name [I] |
| 8 | ALS wait skip in backboardd | `userland/src/inject.c:544-575` | our backboardd injection (`scripts/gpu/stage-backboardd-gl.py` path) | ~40 | 5 s off every backboardd start [V for 16.5; re-check 20H392] |
| 9 | Sensors stage S1: SLPI PAS 12 boot + GLINK pid 3 + QRTR service list | our 0240/0242/0265 as model; `out/live.dts:6431-6474`; `qcom_q6v5_pas.c:1382-1394` | new `negroni_slpi.c` patch; `slpi.mdt/.bNN` into the ADSP firmware area | ~600 | first proof; decides if the registry blocker is real |
| 10 | Mic: DMIC TX path with GPR graph; read `hakios.mic.c` for the codec/SoundWire order | `xnu/files/bsd/dev/hakios.mic.c:1-40` (data only) | audio stage after 0247 | ~1 800 | needed for calls/Siri/video audio |
| 11 | Flashlight | `hakios.torch.c`, `inject_media.c:14-23` | own PM8350C flash driver + `/product/camera flash` | ~500 | small, visible |
| 12 | GNSS | `hakios.mpss.c` (modem boot, read-only RMTFS `:3526-3577`) | later | ~4 000+ | large; no reference for the locationd feed |

## 13. Open questions (to check before code)

1. [I] 20H392 addresses for every HakiOS hook (`inject_media.c`, `inject.c`): read them from `out/dsc/20H392.a2s`.
2. [I] CoreMedia derived-object vtable layout for `FigCaptureDevice`/`FigCaptureStream` in 16.7 vs 16.5.
3. [I] Usage pages, usages and properties the `AppleSPU*` plugins and backboardd/locationd match.
4. [I] Does the SLPI start its physical sensor drivers without the Android registry service?
5. [I] The locationd preference key for the Settings switch on 20H392.
6. [I] Can ath11k drive the Android WCN6855 firmware, or do we need the linux-firmware set?
