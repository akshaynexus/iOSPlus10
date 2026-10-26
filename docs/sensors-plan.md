# Motion and light sensors plan (2026-10-27, sensors research agent; research only)

Goal: accelerometer, gyroscope, magnetometer, proximity and ambient light on the iOS 16 port, so that
screen rotation, auto-brightness, raise-to-wake and the proximity screen-off work.

Marks: **[V]** seen in source, DT, ADT, firmware image, shared cache or vendor file. **[I]** inference.
**[U]** unknown, a test must decide. Nothing in this file ran on the phone. No patch exists yet.

Short answer:

- All five sensors sit on buses of the SLPI (sensor DSP, "SSC"). The APSS DT has no sensor bus.
- The shortest path that works is the stock path: boot the SLPI with PAS (as 0240 does for the ADSP),
  GLINK edge "dsps", QRTR, QMI service 400 (`sns_client`, protobuf). One extra piece has no template in
  our tree: the SLPI reads its registry and JSON configs from the HLOS file system through FastRPC
  (reverse RPC `apps_std`, served by `sscrpcd` on Android). We must serve these files.
- The SLPI path shares the PAS auth_and_reset step that fails for the ADSP today. So phase 0 is a
  2-3 day probe of the direct path (can the APSS read the SSC QUP with the SLPI off?). If yes, a direct
  LSM6DSO/AKM09918/TCS3701 driver avoids FastRPC; if no, the SLPI path is the only path.
- Parts on this phone (DT `oplus_sensor` + OnePlus enums): LSM6DSO (accel+gyro, SPI), AKM09918 (compass,
  I2C 0x0c), TCS3701 (ALS+prox, I2C).
- iOS side: kernel `IOHIDEventService` subclasses (as `NegroniHIDTouch`) with the usage pairs of the
  real iPhone X ADT. A userland `IOHIDUserDevice` daemon is not possible: our kernel has no IOHIDResource
  family.

## 1. Hardware path

### 1.1 Which chips (vendor files, OTA NE2211_16.0.3.530)

- [V] `odm.img:/etc/sensor/sensor_config.json`, project `"20847"` (the NE2211 is project 20847,
  docs/notes.md:1484; live.dts bootargs `oplusboot.prjname=20847`), `"sensor_arch": "qcom_sensor_see"`:

  | Android sensor | type | `module` (alternatives: second-source parts) |
  |---|---|---|
  | accelerometer | 1 | `icm4x6xx` (TDK ICM-4x6xx) or `lsm6dso` (ST LSM6DSO) |
  | gyroscope | 4 | `icm4x6xx` or `lsm6dso` (the same IMU chip) |
  | magnetic_field | 2 | `ak0991x` (AKM AK0991x) or `mmc56x3x` (Memsic MMC56x3) |
  | light | 5 | `tcs3701` (ams TCS3701, front, ALS + prox in one chip) |
  | proximity | 8 | `tcs3701` |
  | qti.sensor.rgb_rear | 33171052 | `tcs3408` (rear colour/flicker, not needed) |
  | qti.sensor.sar / sars | 33171025 / 33171029 | `sx933x` / `sx933x_down` (SAR, not needed) |

  Project `sku_13` adds a pressure sensor (`lps22hb|bosch_bmp380`).
- [V] The fitted parts come from the DT `oplus_sensor` node (out/live.dts:37015-37060) decoded with the OnePlus
  enums (OnePlusOSS `vendor/oplus/sensor/kernel/qcom/sensor/oplus_sensor_devinfo.h:44-101`, branch
  `oneplus/sm8450_b_16.0_oneplus_10_pro`): gsensor `sensor-name 0x10` = **LSM6DSO** (accel + gyro),
  msensor `0x01` = **AKM09918** (compass), lsensor/psensor `0x02` = **TCS3701** (ALS + prox). So the
  `lsm6dso_0`, `ak0991x_0` and `alsps` rows below are the ones that matter. (Confirm once with Android
  `dumpsys sensorservice`.)
- [V] Bus configuration (`odm.img:/etc/sensor/config/waipio_qrd_*.json`, the `*_platform.config` groups;
  the same values are in the registry of the persist dump, `persist.img:/sensors/registry/registry/`):

  | Chip | bus_type | bus_instance | slave_config | speed | IRQ (`dri_irq_num`, chip pin) | rails |
  |---|---|---|---|---|---|---|
  | icm4x6xx_0 | 1 (SPI) | 3 | 0 (CS 0) | 9600 kHz | 15, rising | `/pmic/client/sensor_vdd`, `sensor_vddio` |
  | lsm6dso_0 | 1 (SPI) | 3 | 0 | 9600 kHz | 15, level | the same |
  | ak0991x_0 | 0 (I2C) | 2 | 12 (0x0c) | 400 kHz | none (polled) | `sensor_vddio` |
  | mmc56x3x_0 | 0 (I2C) | 2 | 48 (0x30), I3C addr 20 | 100-400 kHz | none | `sensor_vddio` |
  | alsps (tcs3701) | 0 (I2C) | 5 | 70 | 400 kHz | 89, rising | `sensor_vdd`, `sensor_vddio` |

  `bus_instance` is the SSC QUP serial engine of the SLPI ([I]: SEE `sns_com_port` numbering), not an
  APSS QUP. bus_type 0 = I2C, 1 = SPI ([I] SEE `sns_bus_type`; matches the 9.6 MHz speed of the IMU).
- [V] Axis mapping in the registry: `icm4x6xx_0_platform.orient` = `+x +y +z`; `ak0991x_0_platform.orient`
  = `x:-y y:+x z:+z`. The persist dump holds factory calibration groups (`*.fac_cal.bias`,
  `*.fac_cal.corr_mat`, `alsps_platform.prox.fac_cal`, `alsps_platform.als.fac_cal`). The values are
  device data: do not copy them into git.
- [V] The SLPI image has drivers for every candidate part (strings of `slpi.b13`: `sns_icm4x6xx_sensor.c`,
  `sns_lsm6dso_sensor.c`, `sns_bmi26x_*`, `sns_ak0991x_sensor.c`, `sns_mmc56x3x_sensor.c`,
  `sns_alsps_sensor.c` with `[oplus_alsps]` messages, `sns_tilt_to_wake_sensor.c`, `sns_rotv_sensor.c`,
  `sns_device_orient` config, `sns_suid_sensor.c`, `sns_client_manager_qmi.c`). So the SLPI also gives
  fused sensors (rotation vector, gravity, tilt-to-wake) for free.
- [V] OnePlus DT node `oplus_sensor` (`compatible = "oplus,sensor-devinfo"`, out/live.dts:37015-37138):
  gsensor, msensor (soft-iron matrix `soft-mag-parameter`, 18 values), lsensor/psensor (`bus-number 2`,
  `irq-number 14`, prox thresholds), cct sensors. The Linux module only asks the hub for names
  (`sensor_set_cmd_to_hub(..., CUST_ACTION_GET_SENSOR_INFO)`, OnePlusOSS
  android_kernel_modules_and_devicetree_oneplus_sm8450 branch `oneplus/sm8450_b_16.0_oneplus_10_pro`,
  `vendor/oplus/sensor/kernel/oplus_sensor_devinfo/sensor_devinfo.c:775-810`). [I] The SLPI `devinfo`
  sensor reads these values; the prox/ALS tuning lives there.

### 1.2 No APSS bus carries a sensor

- [V] Enabled APSS GENI buses and their children (out/live.dts): i2c@984000 (p9415 wireless RX, hl7227,
  :14119-14164), i2c@990000 (touch, :14273-14438), i2c@994000 (rtc6226 FM, :14463-14496), i2c@a84000
  (hall ist8801/mxm1120, :14628-14690), i2c@a94000 (TFA9874 x2, :14853-14890), i2c@a98000 (fsa4480,
  :14914-14934). All `spi-geni` nodes are `disabled` (:14538-14554, :14939-14955, :15273-15289).
- [V] Linux `pinctrl-sm8450.c` (out/src/linux) has 211 GPIOs and no `ssc` function; the sensor pins
  are not main-TLMM pins ([I]: they are SSC TLMM pins inside the SSC block).
- [V] The SLPI image names its own buses: `/dev/qup_ssc`, `/dev/qup_ssc/11`, `/dev/qup_ssc/15`,
  `%s_QUP_%d_SE_%d`, rails `/vcs/vdd_ssc_int`, `/vcs/vdd_ssc_mx`, `+SSC_NOC`.

### 1.3 The SLPI remoteproc (live DT) and what we reuse

| Item | SLPI (sensors) | ADSP (0240-0248, for comparison) |
|---|---|---|
| Node | `remoteproc-slpi@02400000`, `qcom,waipio-slpi-pas`, live.dts:6431-6476 | `remoteproc-adsp@03000000`, :6295 |
| Carveout | `slpi_region@87F00000`: 0x87f00000 + 0x1a00000 (26 MiB), live.dts:124-128 | 0x85700000 + 0x2800000 |
| Mu memory map | inside "PIL Reserved" 0x85200000 + 0x1c200000 [V external/Mu-Silicium-negroni/Platforms/OnePlus/negroniPkg/Library/MemoryMapLib/MemoryMapLib.c:14] | the same row |
| PAS id | 12 [V out/src/linux/drivers/remoteproc/qcom_q6v5_pas.c:1382-1396 `sdm845_slpi_resource_init`, used for `qcom,sm8450-slpi-pas` at :1900] | 1 |
| Crash reason SMEM item | 424 (same struct) | 423 |
| AOP QMP load_state | `"slpi"` | `"adsp"` |
| Proxy rail votes | lcx, lmx (same as ADSP; DT cx/mx supplies 0x3f/0x40 = the ADSP's) | lcx, lmx |
| SMP2P | `qcom,smp2p-dsps`, `qcom,smem = <0x1e1 0x1ae>` = in 481 / out 430, remote pid 3, IPCC client 4 signal 2 (live.dts:15566-15600) | <443 429>, pid 2, client 3 |
| Extra SMP2P entry | `sleepstate` out / `sleepstate_see` in (:15588-15599, `qcom,smp2p_sleepstate` :10554) | none |
| GLINK edge | `glink-edge`, remote pid 3, `mbox-names = "dsps_smem"`, IPCC client 4 signal 0, `qcom,glink-label = "dsps"` (live.dts:6452-6461) | client 3, "lpass" |
| GLINK channels | `IPCRTR` (`qcom,net-id = 2`, `qcom,low-latency`, intents 5x0x800 3x0x2000 2x0x4400, `qcom,no-wake-svc = <0x190>`, :6462-6468), `fastrpcglink-apps-dsp` (:6470-6474) | `IPCRTR`, `adsp_apps`, PMIC_RTR... |
| Interrupts | wdog = PDC 9; fatal/ready/handover/stop-ack = SMP2P-in bits 0/1/2/3 (:6444-6445) | wdog PDC 6 |
| Firmware | `slpi.mdt` + `slpi.b00`-`b21`, `b23` (no b22: BSS 0x3f4000) in the modem FAT `image/` (out/firmware/adsp/LISTING.txt:442-465); servreg `slpir.jsn` (root_pd), `slpius.jsn` (sensor_pd), both `qmi_instance_id 90` | `adsp.*` |
| Load span | 23 ELF32 segments, p_paddr 0x88000000-0x89a00000 = 0x1a00000, flags 0x8000000 (relocatable) = exactly the carveout [V program headers of slpi.mdt] | |
| FastRPC | `qcom,msm_fastrpc`, `qcom,fastrpc-slpi-sensors-pdr` (:11960-11964); SLPI context banks `sdsprpc-smd` = apps SMMU SIDs 0x541, 0x542, 0x543, IOVA pool 0x80000000 + 0x78000000 (:12082-12105) | not used by us |
| HLOS client node | `qcom,msm-ssc-sensors` (`qcom,firmware-name = "slpi"`, rproc handle, :6520-6526): only the loader trigger | |

[V] QMI service 400 (0x190) is the SEE client service: the DT exempts it from wake (`qcom,no-wake-svc`).

Reuse from our kernel (all in `bsd/dev/negroni_adsp.c` and `negroni_audio.c`):

- [V] 0240 steps 1-8: SMEM `$TOC` and partitions, firmware area read + SHA-256, RPMh lcx/lmx votes,
  AOP QMP `load_state`, PAS init/mem-setup/auth-reset SMCs, carveout load, SMP2P item + IPCC kick, wait
  for ready/handover/fatal (patches/xnu/0240-negroni-adsp-boot.patch:21-58). The constants are fixed
  `#define`s for the ADSP (:98-150: `ADSP_MEM_PHYS`, `SMEM_ADSP 2`, items 423/429/443, `IPCC_CLIENT_LPASS 3`).
  Work: turn them into one descriptor struct `{name, pas_id, mem, size, smem_host, items, ipcc_client,
  load_state, area file prefix}` so ADSP and SLPI share one code path.
- [V] 0242 GLINK over SMEM (items 478/479/480 in the apps<->remote partition, version, OPEN, intents;
  0242:408-432) and 0274 `negroni_glink_open` (generic channel open). Same work: per-edge state.
- [V] 0243 QRTR control (HELLO, NEW_SERVER list) over the `IPCRTR` channel (0243:438-490). QMI framing:
  0266 `negroni_wlan_qmi.c` (WLFW over QRTR on MHI). Both need a transport hook to run on the SLPI edge.
- [V] 0248 crash watch (SMP2P fatal poll, stop bit, PAS shutdown) applies as is with the SLPI items.
- [V] Hardware status of that code: ADSP step 1 ran on the phone (SMEM OK, docs/notes.md:1565-1568). Per
  the main session (2026-10-27): the ADSP PAS boot now fails at auth_and_reset (SCM "interrupted" resume
  bound; a fix is in progress). PAS boot to "ready" is **not proven** for any DSP yet. The GPU zap PAS SMC works on the phone
  (notes.md:1569-1571). So the SLPI bring-up and the ADSP bring-up prove the same code; do the ADSP first
  or in the same image.

### 1.4 The stock Android stack (what the SLPI expects from the HLOS)

- [V] `vendor.img:/etc/sensors/hals.conf`: `sensors.dynamic_sensor_hal.so`, `sensors.ssc.so` (the SEE HAL:
  QMI `sns_client` over QRTR to the SLPI, protobuf messages).
- [V] `vendor.img:/etc/sensors/sns_reg_config` (version 3): `output=/mnt/vendor/persist/sensors/registry/registry`,
  `config=/odm/etc/sensor/config`, hw keys from `/sys/devices/soc0/{hw_platform,platform_subtype,
  platform_subtype_id,platform_version,soc_id,revision}`.
- [V] The SLPI reads these paths itself: `slpi.b13` strings `/vendor/etc/sensors/sns_reg_config`,
  `sns_registry_osa.c:fopen failed | tries=%d/%d | file=%s`, `fread`, `fwrite`, `readdir`; `slpi.b05`
  `/vendor/etc/sensors/config`. `slpi.b08` has the FastRPC reverse-RPC side: `apps_std`,
  `adsp_default_listener`, `adsp_default_listener_register`, `/dev/fastrpc-smd`.
- [I] The file calls go from the SLPI sensor PD to the HLOS through FastRPC (`apps_std` reverse RPC on the
  `fastrpcglink-apps-dsp` channel); on Android the `sscrpcd` daemon is the listener. postmarketOS needs
  `hexagonrpcd` for the same job on mainline Snapdragon phones. Without it the registry stays empty and
  the physical drivers do not register (they need `bus_type`/`bus_instance` from the registry).
- [V] `persist.img:/sensors/registry/registry/` is a complete, calibrated registry (one JSON file per group,
  319 entries; groups for every part in 1.1, plus `sns_tilt_to_wake`, `sns_rotv_platform`,
  `sns_device_orient_platform`, `sns_gyro_cal_*`, `sns_mag_cal_config`). [I] If we serve this directory
  read-only, the SLPI does not need the JSON parser path and gets the factory calibration.
- [I] Client protocol (Qualcomm SEE, as in the open `libssc` / `sns_client.proto`): QMI message 0x20
  carries `sns_client_request_msg` {suid, msg_id, request payload}; reports come as QMI indications
  (0x21 / jumbo 0x22). SUID lookup: request to the fixed SUID sensor (0xabababababababab twice) with
  `sns_suid_req {data_type: "accel", register_updates: true}` (msg 512), answer `sns_suid_event` (768).
  Stream: `sns_std_sensor_config {sample_rate}` (msg 513), events `sns_std_sensor_event {data[]}` (1025),
  physical config event 1026, attributes 1/128. Units: accel m/s^2, gyro rad/s, mag uT, ALS lux,
  prox near/far + raw. Message numbers must be checked against the SLPI answers [U].

## 2. Alternative without the SLPI (direct I2C/SPI from XNU)

Decision: **second choice, but test it early (phase 0 below)**. The SLPI path shares the unproven PAS
auth_and_reset step with the ADSP and needs a FastRPC file server. The direct path has no firmware
dependency, but every hardware fact it needs is unknown today. Facts for and against:

- For: only three parts to drive (LSM6DSO on SPI SE3 CS0, AKM09918 at I2C SE2 0x0c, TCS3701 on I2C SE5),
  all with public datasheets and Linux drivers (`st_lsm6dsx`, `ak8975` family, `tcs3472`-like ams code
  [I]); the SLPI stays off, so no FastRPC, no registry, no QMI.
- Against:

- [V] No DT node, address or pin for the SSC QUPs or SSC TLMM in the APSS DT (section 1.2). We do not
  know the register base of `qup_ssc` SE 2/3/5 on SM8450 [U].
- [I] The SSC block (QUP, TLMM, its clock controller) sits behind the SSC power domain and the SSC NOC
  (`+SSC_NOC`, `/vcs/vdd_ssc_int`, `/vcs/vdd_ssc_mx` in the SLPI image). TrustZone/Gunyah assign the SSC
  register space to the SLPI (xPU). An APSS access to a protected region gives a synchronous external
  abort or an NOC error that resets the SoC. Our kernel has seen Gunyah emulation on the apps SMMU
  (README-wifi.md:163), so the hypervisor is active.
- [U] The sensor rails `sensor_vdd` / `sensor_vddio` are PMIC LDOs the SLPI votes through its own RSC.
  The DT does not name them.
- [V] The touch driver shows what a direct driver costs when the pins ARE APSS pins: a bit-banged I2C on
  TLMM GPIOs (external/UniXNU-negroni/patches/xnu/0093-negroni-s3908-touch-gpio-i2c.patch, `gpio_i2c.h`,
  `tlmm_i2c.h`). For the sensors we would also need: an SPI master (9.6 MHz IMU), four chip drivers (IMU x2
  variants, mag x2 variants, TCS3701 ALS/prox with OnePlus tuning), our own calibration and fusion.
- Phase 0 probe (2-3 days, gate between the two paths): (1) find the SSC QUP and SSC TLMM bases in the
  SLPI image (its device config near the `%s_QUP_%d_SE_%d` strings) or in OnePlus/Qualcomm sources;
  (2) with the SLPI off and the lcx/lmx votes on (0240 step 3), read one QUP `GENI_HW_VERSION` word under
  the panic-over-USB console (0360). Result A: a sane version -> the APSS reaches the SSC; next find the
  SSC clock enables and the sensor LDOs, then write the SPI/I2C masters. Result B: abort/reset -> the
  SSC is xPU-protected; drop the direct path. Ask the owner first: a protected read can reset the SoC.
- Even with result A, the IRQ pins (`dri_irq_num` 15 / 89, `irq_is_chip_pin 1`) are SSC pins [I]; poll
  the chips first (IMU FIFO at 50 Hz, ALS/prox at 10 Hz).

## 3. The iOS side (iOS 16.7 20H392, iPhone X identity)

### 3.1 What the real iPhone X publishes

- [V] Real D22AP ADT (`~/op10-apple/d22ap.adt`, scripts/ios16/fetch-d22ap-adt.sh; read with
  `ipsw dtree ~/op10-apple/d22ap.adt`, lines 2483-2558 of the output): `/arm-io/aop/iop-aop-nub/` has

  | Node | device-usage-page | device-usage | Calibration properties (syscfg keys) |
  |---|---|---|---|
  | `accel` | 0xff00 | 3 | `accel-orientation` ARot, offsets AROC, sensitivity ASCl ... |
  | `gyro` | 0xff00 | 9 | `gyro-orientation` GRot, GSCl, GYTT ... |
  | `compass` | 0xff00 | 10 | `compass-orientation` (binary), CPAS, CSCM ... |
  | `prox` | 0xff00 | 8 | `prox-calibration` PxCl, `function-saca` |
  | `pressure` | 0x20 (Sensor page) | 0x31 | SPPO, PRTT |

  No `als` node on D22 ([V] no match for "als" in the dump). The AOP firmware (`iphone10baop`) runs the
  sensors on a real iPhone; the AP sees them as `AppleSPUHIDDevice` services ([V] strings
  `AppleSPUHIDDeviceClass` in AppleSPULib, `AppleSPUHIDDriver` in libMobileGestalt, `AppleSPUProfileDriver`
  in AppleSPUHIDStatistics).
- [V] Our ADT has no `aop` node: external/slop/tools/mkadt.py:214 builds `arm-io` itself and copies only
  `/product` from the D22AP tree (:65-84, :268).

### 3.2 Who consumes what

- [V] Rotation: backboardd gets the device orientation from CoreMotion, not from a HID orientation event:
  `/usr/libexec/backboardd` strings `@"CMDeviceOrientationManager"`, block type
  `v24@?0@"CMDeviceOrientation"8@"NSError"16`, `BKOrientationManager`. CoreMotion runs inside `locationd`.
  locationd's HID layer (`CLIoHidInterface`) opens `IOHIDServiceClient`s per usage pair
  ([V] CoreMotion strings `[CLIoHidInterface] New IOHIDServiceClientRef for usage pair {%d, %d} just became
  available.`, `[CLIoHidInterface] Device,hidUsagePage,%d,hidUsage,%d,...`) and sets the properties
  `ReportInterval` and `BatchInterval` ([V] locationd strings). So rotation needs: an accelerometer
  service that locationd accepts.
- [V] Raw accelerometer for apps: backboardd `BKAccelerometerInterface`, `BKAccelerometerClient`,
  `_handleAccelerometerRequestForPort:`; BackBoardHIDEventFoundation knows `kIOHIDEventTypeAccelerometer`.
- [V] Proximity: backboardd `BKHIDProximityEventProcessor`, `BKHIDUIDiscreteProximityServiceWrapper`,
  `_proximityServiceMatcher`, `send mode %{public}@/%d to proximity service %llX`,
  `send kAppleProxScreenUnlockedKey to service %llX`, `_lock_shouldIgnoreTouchesWhileObjectInProximity`.
  Clients ask through BackBoardServices `RequestProximityDetectionMode` / `BKSHIDServicesRequestProximityDetectionMode`
  ([V] ChatKit, TVLatency); SpringBoard has `SBProximitySensorManager`. So the call screen-off is: app
  requests a mode -> backboardd sets a property on the prox service -> the service sends
  `kIOHIDEventTypeProximity` events -> backboardd blanks the display and ignores touches. It is not
  BiometricKit.
- [V] Ambient light / auto-brightness: CoreBrightness (`CBALSService`, `CBALSEvent`, `_AABC`,
  `handleALSEvent:transitionParameters:`, `copyALSEventWithinTimeout:`,
  `Failed to copy kIOHIDEventTypeAmbientLightSensor event`, `newDevicePariMatchingDictionaryWithPage:andUsage:`)
  in backboardd; backboardd `BKHIDXXAmbientLightSensorExists`, `BKALSIntPeriod*`, `ALSRequiresProx`.
  CoreBrightness then drives the panel through our `AppleARMBacklight` (`IODisplayParameters`
  brightness, patches/xnu/README-brightness.md:61-87). So the ALS service needs `copyEvent()` for
  `kIOHIDEventTypeAmbientLightSensor` and pushed events.
- [V] MobileGestalt reads `IODeviceTree:/arm-io/aop/iop-aop-nub/als` and the keys `als`, `prox`,
  `compass`, `magnetometer`, `prox-calibration`, `compass-calibration` (libMobileGestalt strings).
  [I] Some capability answers (auto-brightness switch, proximity, compass) come from these ADT nodes.
- [V] Raise-to-wake on iPhone runs on the AOP (`CLSPUEclipseClient`, "Informing AOP about
  SignificantUserInteraction", `CLSPUHIDDriverInterface ... send command with reply to SPU`).
  [I] Without an SPU, CoreMotion's wake gesture is not there; see phase 3.

### 3.3 Decision: kernel IOHIDEventService subclasses

- [V] Our kernel already has a minimal `IOHIDEventService` + the unchanged IOHIDFamily-1915.140.3
  `IOHIDEventServiceUserClient`, `IOHIDEventServiceQueue`, `IOHIDEvent`
  (external/UniXNU-negroni/patches/xnu/0058-negroni-hid-event-services.patch: header :12121-12199,
  `start()` publishes Transport/Product/VendorID/PrimaryUsagePage/PrimaryUsage/DeviceUsagePairs/BuiltIn/
  `IOUserClientClass` at :20645-20694, `NegroniHIDTouch` :20947). `copyEvent()` and `setProperties()` are
  virtual, so a subclass can answer CoreBrightness and locationd.
- [V] `IOHIDEvent` already has `accelerometerEvent`, `gyroEvent`, `compassEvent`,
  `ambientLightSensorEvent` (lux + 4 channels, or colour space + 3 components), `proximityEvent`,
  `proximityEventWithProbability`, `orientationEvent` (0058:1084-1260, :2036).
- [V] HakiOS feeds touch to backboardd with a userland virtual HID service
  (`IOHIDVirtualServiceClientCallbacksV2`, `IOHIDEventSystemClientCreateWithType`; docs/references-2026-10-27.md
  section 1.1, HakiOS `inject.c:589-600`) and patches out CoreBrightness `-[BLControl waitForALSArrival]`
  (5 s wait for an ALS service, `inject.c:544-575`). [I] A virtual service lives in one event system
  client process; locationd and backboardd each have their own client, so it does not reach both. Keep
  it as a fallback for backboardd-only features.
- [V] A userland `IOHIDUserDeviceCreate` daemon needs the IOHIDResource family (IOHIDUserDevice) and
  IOHIDDevice/IOHIDEventDriver (report descriptor parser). The 0058 header says Apple's IOHIDFamily kext
  is not part of xnu and the class "does not parse HID report descriptors". So that path means porting
  IOHIDFamily: longer.
- Design: one `NegroniSensors` IOService (matched on IOResources like `NegroniHIDTouch`, 0058:12-28 of the
  KernelConfigTables hunk) creates five children `NegroniHIDAccel` (0xff00/3), `NegroniHIDGyro`
  (0xff00/9), `NegroniHIDCompass` (0xff00/10), `NegroniHIDProx` (0xff00/8), `NegroniHIDALS`
  (0xff00/4 [I]: IOHIDFamily `kHIDUsage_AppleVendor_AmbientLightSensor`; D22 has no node to copy).
  Each overrides `getPrimaryUsagePage/Usage`, `copyEvent` (last event), `setProperties` (log every key
  once; apply `ReportInterval`/`BatchInterval` in microseconds [I] to the SLPI sample rate; prox mode
  on/off), and dispatches events from the QMI indication thread.
- Units [I, to check on the phone]: iOS motion events are in g (accel), rad/s (gyro), uT (compass), as
  IOFixed 16.16. SEE gives m/s^2: divide by 9.80665. Sign: Android reports +g on the axis that points
  up; iOS reports -1 g on that axis (UIAccelerometer y = -1 when upright). Start with
  `ios = -android / g` per axis and prove it with the phone upright, then flat.
- Timestamps [I]: SEE timestamps are QTimer ticks (19.2 MHz). XNU `mach_absolute_time` on this port
  counts the same ARM generic timer. Pass them through unchanged; check one sample against
  `mach_absolute_time` at receive time.

## 4. Proximity and ALS specifics

- Proximity event: `IOHIDEvent::proximityEvent(ts, mask, level)`; mask
  `kIOHIDProximityDetectionLargeBodyContact` (or `...FaceApproach` [I]) when near, 0 when far. Send on
  every change and once when backboardd enables the mode. TCS3701 thresholds come from the SLPI
  (`psensor@0` DT values: low_step 300, high_step 400, low_limit 400, high_limit 600, live.dts:37051-37085).
- Prox mode: [U] the exact property key backboardd sets (strings show `ProximityDetectionMode`,
  `kAppleProxScreenUnlockedKey`, `ReceiverProximityReset`). The service logs each `setProperties` key
  with its value once (`NEGRONI SNS: prox property KEY = VALUE`), then we wire the stream on/off to it.
- ALS: `ambientLightSensorEvent(ts, lux, ch0..ch3)` for phase 2; CoreBrightness on a TrueTone device may
  want the colour form (`colorSpace` + XYZ) [I]; the SEE `rgb` sensor (`qti.sensor.rgb`, tcs3701) gives
  the channels for that in phase 3.
- Auto-brightness switch: Settings shows it when MobileGestalt reports an ALS [I]; add the
  `aop/iop-aop-nub/als` + `prox` + `accel` + `gyro` + `compass` nodes to our ADT (with the D22 usage
  properties; `als` usage 0xff00/4) through a script/patch in this repo (mkadt.py is in the slop
  submodule: no edits inside it). [I] Our kernel has no AOP driver, so a `device_type "aop"` node matches
  nothing.
- DisplayServices: no new keys; brightness goes through the existing AppleARMBacklight path
  (README-brightness.md). Test: `negronibl` log lines `backboardd sets N keys` change with room light.

## 5. Plan

### Phase 0: direct-path gate (2-3 days, section 2)

Find the SSC QUP base, read `GENI_HW_VERSION` once with the SLPI off. Boot-args of that proof:
`negronissc_probe=1 negronipanic=30 negronipanicreason=2`. Proof line:
`NEGRONI SSC: QUP SE3 hw_version 0x........` (result A) or a panic/reset log (result B). Result A: a
direct-driver phase replaces 1b-1d (SPI master + LSM6DSO, I2C master + AKM09918 + TCS3701, our own
calibration from the persist registry values), estimate 2-3 weeks. Result B: phase 1 as below.

### Phase 1: SLPI up, sensor data in the kernel log (estimate 3-5 weeks, most of it FastRPC)

1a. Firmware (host, 0.5 day). `scripts/sensors/extract-slpi-fw.sh`: `slpi.mdt`, `slpi.bNN`, `slpir.jsn`,
    `slpius.jsn` from the modem FAT (same source as scripts/audio/extract-adsp-fw.sh); the registry
    directory from `$BACKUP/partitions/persist.img.gz` (debugfs rdump `/sensors/registry`); the JSON
    configs and `sns_reg_config` from `odm.img`/`vendor.img` (payload-dumper-go + `dump.erofs --cat`).
    [V] The ADSP area (mkadsparea.py) holds 64 files and has ~19.3 MB in use; the SLPI adds 24 firmware
    files (~9.2 MB) plus ~330 registry/config files: they do not fit the 64-entry table. Use a pack file
    in an area (as the BT pack inside the WLAN area, patches/xnu/README-bluetooth.md:110-113) or a new
    "sensors" area before the WLAN area. Ask the owner before the userdata write.
1b. Kernel, SLPI PAS boot (3-5 days incl. boots). Generalize 0240/0242/0248 to a descriptor; boot-args
    `negronislpi=1 negronislpi_step=N` (1 survey, 2 area, 3 rails, 4 QMP, 5 PAS init id 12, 6 load
    0x87f00000, 7 SMP2P item 430 + IPCC client 4, 8 auth+reset and wait, 9 GLINK "dsps").
    Expected proof lines:
    - `NEGRONI SLPI: SMEM partition 0/3 at 0x..., no SLPI SMP2P item 481: the SLPI has not run since the reset`
    - `NEGRONI SLPI: TrustZone takes the carveout 0x87f00000 + 0x1a00000`
    - `NEGRONI SLPI: ready (slave-kernel bit 1) after N ms`, then `handover`
    - `NEGRONI SLPI: GLINK version 1, IPCRTR open, fastrpcglink-apps-dsp open`
    Risk: the AOP QMP mailbox has no lock between ADSP and SLPI users (README-battery note in
    notes.md:1019). Run the SLPI steps from the same thread as the ADSP steps, one DSP after the other.
1c. QRTR + SNS QMI (3-5 days). HELLO on the SLPI IPCRTR; record NEW_SERVER (expect service 400 = SNS
    client, plus servreg/ssctl); minimal protobuf encode/decode in C (varint, length-delimited, fixed32,
    float); SUID lookup for `accel`, `gyro`, `mag`, `ambient_light`, `proximity`.
    Proof: `NEGRONI SNS: server 400 v1 at node N port P`, `NEGRONI SNS: suid accel = 0x... (n=1)`.
    This step also measures the FastRPC need: without the registry [I] the SUID lookup answers no
    physical sensors (only virtual ones). Log the full SUID list.
1d. FastRPC file server (1.5-3 weeks; no template in our tree). On `fastrpcglink-apps-dsp`: the remote
    invoke protocol (`smq_invoke` messages), attach to the sensors PD, register as `adsp_default_listener`,
    answer `apps_std` calls (fopen/fread/fclose/fseek/flen/opendir/readdir/stat/fwrite) from an in-kernel
    read-only table: the registry directory, the JSON configs, `sns_reg_config`, and the `/sys/devices/soc0/*`
    values (`soc_id` 457 = SM8450 [I], `hw_platform` QRD [I: the JSON `config` filters list QRD/MTP]).
    Writes go to RAM and are dropped (log them). Buffers: the SLPI context banks are apps SMMU SIDs
    0x541-0x543; reuse the 0324/0325 apps-SMMU code (stage-1 context or bypass S2CR, README-wifi.md:161-163;
    owner approval: it writes the shared SMMU). Reference implementations to read: Linux `fastrpc.c`
    (out/src/linux/drivers/misc/fastrpc.c [I path]), postmarketOS `hexagonrpcd`.
    Proof: `NEGRONI FRPC: apps_std fopen /mnt/vendor/persist/sensors/registry/registry/icm4x6xx_0_platform.config -> ok`,
    then in 1c `NEGRONI SNS: suid accel ... (vendor tdk|st)`.
1e. Streams. Accel + gyro at 50 Hz, mag 50 Hz, prox and ALS on change.
    Proof: `NEGRONI SNS: accel 0.12 9.79 0.31 m/s^2` with the phone upright; flat gives z near 9.8.

First proof boot (fastboot boot, battery > 30 %, sensors area on userdata):
`negronislpi=1 negronislpi_step=8 negronipanic=30 negronipanicreason=2` (PAS boot only, no GLINK, no
`negroniadsp`). Next boot `negronislpi_step=9`, then `negronisns=1` (QRTR/QMI), then `negronifrpc=1`.

### Phase 2: iOS integration (1-1.5 weeks)

2a. `NegroniSensors` + five `IOHIDEventService` subclasses (section 3.3). Boot-arg `negronisensors_hid=1`.
    Proof: `hidutil list` (or `ioreg -c IOHIDEventService`) on the phone shows five new services with
    PrimaryUsagePage 65280 and usages 3/9/10/8/4; locationd logs
    `[CLIoHidInterface] New IOHIDServiceClientRef for usage pair {65280, 3}`; the kernel logs
    `NEGRONI SNS: accel property ReportInterval = ...`.
2b. ADT nodes (script in this repo, applied after mkadt.py): `arm-io/aop/iop-aop-nub/{accel,gyro,compass,prox,als}`
    with `device_type`, `device-usage-page`, `device-usage`.
2c. Rotation test: open Safari or Notes, turn the phone to landscape; `log stream` shows
    `BKOrientationManager` changes. If locationd ignores the service: its log names the usage pairs it
    wants (string `[CLIoHidInterface] Device,hidUsagePage,%d,hidUsage,%d`); adjust.
2d. Proximity test: a small tool calls `BKSHIDServicesRequestProximityDetectionMode` (or voice memo /
    Messages audio raise-to-listen); hand over the sensor turns the screen off.
2e. ALS test: Settings > Accessibility > Display > Auto-Brightness on; cover the sensor; the
    `AppleARMBacklight` value drops.

### Phase 3: calibration, colour ALS, raise-to-wake (1-2 weeks)

- Calibration: the served persist registry carries factory bias and matrices (section 1.1); the SLPI
  applies them. Verify with the phone flat (accel |z| = 1.00 g +- 0.02) and still (gyro < 0.01 rad/s).
  Gyro/mag runtime calibration: the SLPI `sns_gyro_cal`, `sns_mag_cal` sensors (registry groups present).
- Orientation axes: registry `orient` already maps chip axes to Android axes; our only conversion is
  Android -> iOS sign/units (section 3.3). The compass needs the same sign rule [I]; check with Compass.app.
- Colour ALS: `qti.sensor.rgb` -> ALS colour components for CoreBrightness (TrueTone) [I].
- Raise-to-wake: [U] whether iOS 16 offers it without an SPU. Option: subscribe to the SLPI
  `tilt_to_wake` sensor (`sns_tilt_to_wake.json` in vendor) and, on an event with the display off, wake
  the display through the path the power button uses (0060 keys driver) without a lock toggle. Needs
  care: a wrong wake drains the battery.
- Pocket / face-down detection: SLPI `pocket`, `sns_device_orient` (registry groups present) if needed.

### Risks

| Risk | Effect | Mitigation |
|---|---|---|
| PAS boot of a DSP not proven on this phone (ADSP fails at auth_and_reset today, fix in progress) | phase 1 blocked | phase 0 probe in parallel; the ADSP fix also fixes the SLPI |
| Sensor PD needs the servreg locator / PD mapper on QRTR (`slpius.jsn` sensor_pd) | sensor PD does not start | serve the locator answer (as planned for the ADSP charger PD, notes.md: `negroniadsp_step=10`) |
| FastRPC protocol size and SMMU mapping | 1d slips | read hexagonrpcd; first serve only `sns_reg_config` + registry; log every call |
| Second-source parts | wrong driver | the SLPI probes; our code uses SUIDs, not chip names |
| locationd/CoreMotion wants SPU-only interfaces (`CLSPUHIDDriverInterface`) | no rotation | log locationd; fallback: kernel `orientationEvent` + a backboardd-side check [U] |
| QMP mailbox shared with ADSP/charger code, no lock | AOP confusion | one thread for all QMP users |
| Battery drain from 50 Hz streams | power | stop streams when backboardd and locationd close the services; prox/ALS on change only |

## 6. How the evidence was collected (scratch only, nothing in git)

- SLPI firmware: `python3 -I scripts/audio/fatcopy.py out/firmware/modem/modem.img get image 'slpi*' DIR`,
  `strings` per segment.
- Vendor files: `payload-dumper-go -p vendor,odm,dsp $BACKUP/NE2211_16.0.3.530_EX01_full.zip` (run in
  tmux), `dump.erofs --ls|--cat --path=/etc/sensor/config/... odm.img`, `--path=/etc/sensors/... vendor.img`.
- Registry: `gunzip -c $BACKUP/partitions/persist.img.gz`, `debugfs -R "ls /sensors/registry/registry"`.
- iOS: `ipsw dyld str|macho --strings|--objc out/dsc/cache/dyld_shared_cache_arm64 ...` (CoreMotion,
  CoreBrightness, BackBoardHIDEventFoundation, libMobileGestalt); `python3 -I scripts/audio/hfs-extract.py
  ~/op10-apple/ios16-root.simg DIR /usr/libexec/backboardd /usr/libexec/locationd` + `strings`;
  `ipsw dtree ~/op10-apple/d22ap.adt`.
- IOHIDFamily-1915.140.3 `IOHIDEventDriver.cpp` (apple-oss-distributions/IOHIDFamily): accel/gyro/compass
  parse Sensor-page 0x20 data usages and the AppleVendorMotion page; prox uses `kHIDUsage_Csmr_Proximity`.
  Not used by our design (no report descriptors), listed for the usage names.
- Other ports: no sensor work in external/ (ios-flame HANDOFF.md:649,665 lists sensors as missing; no
  hackios sensor daemon or kext).
