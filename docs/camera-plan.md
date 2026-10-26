# Camera support: hardware facts and plan

Status (2026-10-26): levels 1-2 (camcc + CCI0, IMX789 power + chip ID) are code in patches 0310/0311,
built, not run on the phone (battery flat). Before that: offline inventory (stage 0). Target: iOS 16.7.16
(20H392, D22AP identity) on NE2211 / SM8450.
Marks: **[V]** seen (source given), **[I]** inference. Reviewed 2026-10-25
(`docs/reviews/codex-2026-10-25.md`, section 2a).

## How to reproduce (macOS and Linux)

| Step | Command | Output |
|---|---|---|
| tools | `scripts/setup/native-tools.sh` (dtc, erofs-utils, `fdt` in `out/venv`); `payload-dumper-go`: macOS `brew install payload-dumper-go`, Linux release binary (`docs/setup-linux.md`) | |
| Android side | `scripts/bg.sh camera-inv scripts/camera/inventory.sh` (reads `~/op10-backup`, extracts vendor/odm, ~2 GB) | `out/camera/{dt-table,modules,files}.txt`, `out/camera/dtbo/index.txt` |
| iOS side | `scripts/bg.sh camera-ios scripts/camera/ios-stack.sh` (macOS attaches `~/op10-apple/ios16-root.img` read-only; Linux: mount it first, command in the script header). Needs `ipsw`. | `out/camera/ios-stack.txt` |

`scripts/camera/camdt.py` resolves the DT phandles (regulator names, GPIO pins, clocks).
`scripts/camera/cammodule.py` reads the CAMX sensor module files. Its word positions inside
`sensorDriverData` and `resolutionData` are inferred (they give the known Sony/Samsung/OmniVision
chip IDs and addresses for all four modules); the power types use the kernel enum
`msm_camera_power_seq_type` [V, OnePlus camera-kernel, see Sources].

## Camera hardware (per DT slot)

Slot = `cell-index` of `qcom,cam-sensor` = `cameraId` of the CAMX module file [V both]. Live DT:
`~/op10-backup/device/live.dtb` (model "Waipio MTP with PM8010, wly"); `out/live.dts:22044-22578`
is the same DT as text. Addresses are 8-bit (CAMX form); the 7-bit form is in brackets.

| | Slot 0 | Slot 1 | Slot 2 | Slot 3 |
|---|---|---|---|---|
| Role (DT pinctrl names) | rear main (`rear_0`) | rear ultra-wide (`rear_1`) | front (`front`) | rear tele (`rear_2`) |
| Sensor (module file) | Sony IMX789 (`semco_imx789_MP`) | Samsung S5KJN1 (`qtech_s5kjn1sq03`) | Sony IMX615 (`qtech_imx615`) | OmniVision OV08A10 (`qtech_ov08a10`) |
| CCI bus / master | CCI0 (0xac15000) M0 | CCI0 M1 | CCI1 (0xac16000) M1 | CCI1 M0 |
| Sensor address | 0x34 (0x1a) | 0x20 (0x10) | 0x20 (0x10) | 0x6c (0x36) |
| Chip ID @ register | 0x0789 @ 0x0016 | 0x38e1 @ 0x0000 | 0x0615 @ 0x0016 | 0x0841 @ 0x300b (mask 0xffff) |
| CSIPHY (`csiphy-sd-index`) | 1 (0xace6000) | 2 (0xace8000) | 5 (0xacee000) | 0 (0xace4000) |
| PHY, lanes (`laneAssign`) | **C-PHY**, 3 trios (0x0210) | D-PHY, 4 lanes (0x3210) | D-PHY, 4 lanes (0x3210) | D-PHY, 2 lanes (0x0010) |
| Largest mode | 8000x6016 30 fps | 8160x6144 10 fps | 6560x4928 15 fps | 3264x2448 30 fps |
| MCLK (19.2 MHz) pin | MCLK0 gpio100 | MCLK1 gpio101 | MCLK3 gpio103 | MCLK2 gpio102 |
| Reset GPIO | gpio120 | gpio24 | gpio118 | gpio25 |
| VIO 1.8 V | pm8350c_l2 | pm8350c_l2 | pm8350c_l2 | pm8350c_l2 |
| VANA | pm8010i_l3 2.8-2.904 V | pm8010j_l3 2.8 V | pm8010i_l4 2.8-2.9 V | pm8010j_l4 2.8 V |
| VDIG | pm8010i_l1 1.104 V | pm8010j_l1 1.05-1.104 V | pm8010i_l2 1.056 V | pm8010j_l2 1.056-1.2 V |
| Other rails | custom1 pm8010i_l5 1.8 V, VAF pm8010i_l7 2.8-2.96 V | none | none | VAF pm8010j_l7 2.8-3.304 V |
| Actuator (AF) | AK7377 @ 0x18 | none (fixed focus) | none | AK7377 @ 0x1e |
| OIS | LC898128 @ 0x48 (DT `ois@0`, CCI0 M0) | none | none | LC898124 @ 0x7c (DT `ois@1`, **CCI0 M1**) |
| EEPROM | P24C128E @ 0xa0 | GT24P128C @ 0xa0 | GT24P64B @ 0xa8 | GT24P128E @ 0xa0 |
| Flash node | `camera-flash@0` | `camera-flash@1` | none | `camera-flash@2` |
| Power-up order (module file; "+N ms" = delay after the step) | VANA, VDIG, VIO, VAF, CUSTOM_REG1, RESET high +1 ms, MCLK +1 ms | RESET low +1 ms, VIO, VDIG +1 ms, VANA +1 ms, RESET high +1 ms, MCLK +10 ms | RESET low +1 ms, VANA, VDIG, VIO, MCLK +1 ms, RESET high +1 ms | VANA, VDIG, VAF, VIO, MCLK +1 ms, RESET high +1 ms |

Sources [V]: rails, GPIOs, CCI, CSIPHY, flash: `out/camera/dt-table.txt` (camdt.py on the live
DTB). Sensor, address, chip ID, lanes, modes, AF/OIS/EEPROM names and addresses, power order:
`out/camera/modules.txt` (cammodule.py on `/odm/lib64/camera/com.qti.sensormodule.waipio.*.bin`).
Cross-checks [V]: the DT companions match the module files in every slot (slots 0 and 3 have
actuator + OIS + VAF; slots 1 and 2 have EEPROM only); the DT `ois,name` (LC898128 / LC898124)
and the EEPROM names in `camera.ko` (vendor_dlkm: `imx789_p24c128e`, `ov08a10_gt24p128e`, plus
LC898128 flash routines) match the module files; `laneAssign` has as many lanes as the mode
tables. The OIS of slot 3 is on the other CCI controller (CCI0 M1), as the DT `ois-src` says;
this is not a parse error.

Other blocks [V `out/live.dts`, `out/camera/dt-table.txt`]:
- CCI pins: CCI0 M0 gpio110/111, M1 gpio112/113; CCI1 M0 gpio114/115, M1 gpio208/209. Each CCI
  has 100 kHz / 400 kHz / 1 MHz / custom timing nodes. All camera nodes depend on
  `cam_cc_titan_top_gdsc`; clocks come from camcc at 0xade0000 (MCLK0-3 = camcc ids 0x4c, 0x4e,
  0x50, 0x52). The port has no camcc clock code yet (no `ade0000`/camcc in `patches/xnu` or the
  slop patches); RPMh votes exist (`negroni_rpmh`, slop 0122 Wi-Fi supply votes).
- CSIPHY0-5 at 0xace4000 + n * 0x2000, CSID0-2 (0xacb7000, ...), IFE0-2, three
  `qcom,cam-tpg103` test pattern generators.
- Flash: PM8350C `flash_led@ee00` (SPMI): flash_0/1, torch_0/1, led_switch_2; all three flash
  nodes use the same channels.
- The front sensor node is named `com,cam-sensor2` (no "q"); its `compatible` is the normal
  `qcom,cam-sensor`. Match on `compatible`, not on node names.
- Stock `dtbo.img` has 12 entries. The production "wly" entries (00, 06, 07, 11) share one camera
  fragment set (`out/camera/dtbo/index.txt`); the EVB/preT0 entries differ (e.g. another
  custom1 rail for `ois@1`). The live DT has the production values.

### ICP firmware and secure world

- `/vendor/firmware`: `CAMERA_ICP.mdt` + `.b00`-`.b20`, `CAMERA_ICP.mbn`, `CAMERA_ICP.elf`, and
  `CAMERA_ICP_170.elf` / `_480.elf` (`out/camera/files.txt`) [V].
- The `.mdt`/`.mbn` have a hash segment with an attestation certificate chain (OPLUS strings) [V].
  The OnePlus driver (`cam_icp/icp_hw/lx7_hw/lx7_core.c`) loads `CAMERA_ICP.mdt` with
  `qcom_mdt_load` into the DT `memory-region` and starts it with
  `qcom_scm_pas_auth_and_reset(CAM_FW_PAS_ID)`, `CAM_FW_PAS_ID` = 33 (`lx7_core.h`) [V source].
  So TrustZone authenticates the ICP firmware. The port's ADSP loader (patch 0240, PAS id 1,
  untested) uses the same mechanism.
- The DT `qcom,lx7` node (0xac01000, `fw_name = "CAMERA_ICP"`, `nrt-device`) has
  `memory-region` = `camera_region@9f500000` (0x800000 bytes) [V `out/live.dts:184-188` and the
  lx7 node]. That region is the ICP firmware carve-out.
- `qcom,vmid-cp-camera-preview-ro` (`out/live.dts:13481`) is in the generic `qcom,secure-buffer`
  node; it names a VMID for secure buffers and is not linked to `camera_region` [V]. It matters
  only for the secure-camera mode [I].
- The ICP (LX7) runs the offline IPE/BPS processing (`nrt-device`, `compat-hw-name` lx7, ipe0,
  bps) [V DT]. A raw path CSIPHY -> CSID -> IFE RDI -> memory should not need it [I: upstream
  Linux CAMSS captures raw frames and has no ICP code].

### Linux references

- Mainline Linux (torvalds 5b0764a, 2026-10-23, `out/src/linux`) has CAMSS bindings for
  sm8250, sc8280xp, sm8550, sm8650, x1e80100 and others, but not for sm8450 [V tree listing].
  Use sm8550/sm8650 CAMSS as a register reference [I: nearest Titan generation]. C-PHY support
  in mainline CAMSS was not checked.
- The driver that matches this firmware: OnePlus `android_kernel_modules_and_devicetree_oneplus_sm8450`,
  `vendor/qcom/opensource/camera-kernel` (sparse clone `out/src/op-modules` from
  `scripts/audio/fetch-sources.sh`; read a file with `git -C out/src/op-modules show HEAD:<path>`).
- `external/hackios-xnu-kernel/xnu/files/bsd/dev/redwood_camera.c` is POCO X5 Pro / SM6375 work.
  Its I2C-first bring-up order is a useful example; its sensor data does not apply [V header].

## iOS capture path (20H392 root, `out/camera/ios-stack.txt`)

- [V] D22AP ADT: `isp,t8015` (A11 ISP), `AppleH10CamIn`, `camera-rear`, `camera-front`.
- [V] `/usr/sbin/applecamerad` exists. Its launchd job starts when `IOResources` gets the
  property `applecamerad = true` (IOKit matching launch event) and runs as `mobile`. Its strings
  show that it loads the ISP CPU firmware (`Load firmware from %s`, override path
  `/usr/local/share/firmware/isp/h10_isp_fw.bin`). [I] The AppleH10CamIn kext sets that property.
- [V] `mediaserverd` exists. `dietapplecamerad` and `dietappleh13camerad` have job plists but no
  binaries. There is no `cameracaptured` string in the shared cache. `corecaptured` matches
  `CCCapture` (CoreCapture driver logging), not a camera service [I for its purpose].
- [V] The capture plug-in is `H10ISP.mediacapture` (shared cache image; the folder
  `/System/Library/MediaCapture` in our root is empty), with `H10ISPServices.framework`.
  `CMCapture.framework/D22/` has `AVCaptureSession.plist` and `CameraSetup.plist`
  (`TuningParameters`). CMCapture's `BWFigCaptureDeviceVendor` looks up the camera driver service
  by class name (string "Cannot find AppleH13CamIn driver, cameraDriverService=%d"; the
  `AppleH10CamIn` string is in CMCapture and H10ISP.mediacapture).
- [I] Our kernel is built from XNU source and has no Apple kexts, so AppleH10CamIn and its user
  client do not exist. Stock capture (AVFoundation, Camera.app) needs an XNU service that looks
  like AppleH10CamIn to H10ISP.mediacapture and applecamerad: IORegistry properties, user-client
  selectors, shared memory, firmware handshake, frame metadata. This is reverse engineering of
  private interfaces. The user-client selectors are in the D22 kernelcache, not in the root (not
  checked here).
- [I] iOS has no third-party camera plug-in interface (CoreMediaIO DAL / camera extensions are
  macOS only). A custom device node plus our own app can show frames without AppleH10CamIn.

## Staged plan (levels, 2026-10-26)

Each level has one proof point: a log line that only the real hardware can give. Each level is a
boot-arg value of `negronicam` (default 0: no camera register access). Levels 1-2 are code
(patches 0310, 0311; `patches/xnu/README-camera.md`); levels 3-5 are a plan. The target is the
rear main sensor (slot 0, IMX789), as the owner asked. Line references: `out/live.dts` unless named.

| Level | Work | Proof point (exit condition) | Status |
|---|---|---|---|
| 0 | Offline inventory (`scripts/camera/`) | the table above | done |
| 1 | GCC camera clocks, camcc titan top GDSC, camcc AHB/CAMNOC/CCI0 clocks at 19.2 MHz TCXO, CCI0 reset | `NEGRONI CAM: level 1 OK: camcc + CCI0 up` after `CCI0 hw version 0x...` (not 0, not all ones) and `CCI0 reset done ack after N us` | code 0310, built, not run |
| 2 | Slot 0 power-up (5 RPMh rails, reset gpio120, MCLK0 19.2 MHz) in the module-file order, CCI0 M0 pins, chip-ID read, vendor power-down | `NEGRONI CAM: chip id 0x0789 (expected 0x0789, ...): MATCH` then `level 2 OK` | code 0311, built, not run |
| 3 | CSIPHY1 (C-PHY, 3 trios) + CSID + IFE RDI: one raw frame to memory, no ICP | a RAW10 buffer with a non-constant histogram; CSID packet counter > 0 | plan |
| 4 | ICP (LX7) firmware through TZ PAS id 33 | `qcom_scm_pas_auth_and_reset(33)` returns 0 and the ICP answers the HFI init | plan |
| 5 | iOS side: a camera service that applecamerad / CMCapture accept, or our own app | a frame visible in an app | plan |

### Level 1: CAMCC clocks + CCI0 (patch 0310) [V sources, I hardware result]

- [V] Clocks: every camcc source used has a 19.2 MHz TCXO entry (`camcc-waipio.c:955, 988, 1257, 1587, 1926`),
  so no camcc PLL is needed. The DT asks 37.5 MHz for the CCI (`out/live.dts:22056`, PLL0 even / 16,
  `camcc-waipio.c:989`); at 19.2 MHz the Linux 19.2 MHz standard-mode timing applies (`i2c-qcom-cci.c:255-265`).
  Linux selects that table for `qcom,sm8450-cci` (`i2c-qcom-cci.c:871`) when the clock is 19.2 MHz.
- [V] Order (camera-kernel `cam_cci_init` -> `cam_cpas_start` -> clocks): GCC `gcc_camera_ahb/xo` (critical,
  `gcc-waipio.c:1859-1915`), `hf_axi`/`sf_axi`; `cam_cc_gdsc_clk` (`camcc-waipio.c:3789`); titan top GDSC
  (0xadf31dc, `out/live.dts:1015-1024`, timeout 500 us, retain-regs; `gdsc-regulator.c:208-350`); RCGs to TCXO;
  CPAS branches in DT order (`out/live.dts:22720-22721`), then `cam_cc_cci_0_clk`; CCI version, reset
  (`CCI_RESET_CMD_RMSK` then 1, `cam_cci_soc.c`), IRQ masks, RD threshold 0x30 (not on v1.2.9), M0 timing.
- [I] No MMCX vote: the UEFI display keeps MMCX on; a vote from our DRV replaces the UEFI vote for the same DRV.
  If the GDSC does not turn on, step 3 stops with `GDSC did not power on (MMCX off?)`.
- [I] No `cam_ahb` interconnect vote: the config NoC is up for the display and UFS. A hang at step 3 or 4
  (first camcc or CCI access) means a missing NoC/clock vote.

### Level 2: rear main sensor power + chip ID (patch 0311) [V sources, I hardware result]

- [V] Rails, from the sensor node `qcom,cam-sensor0` (`out/live.dts:22204-22238`): `rgltr-min-voltage` =
  `rgltr-max-voltage` (22221-22222) = cam_vio 1800000, cam_vana 2800000, cam_v_custom1 1800000, cam_vdig 1104000,
  cam_vaf 2800000 uV; loads (22220) 600 mA, 600, 600, 1200, 600. RPMh nodes: ldoi3 2800000-2904000 (11708-11715),
  ldoi1 1104000 (11672-11681, HPM above 30 mA), ldoc2 1800000 (11083-11092, HPM above 10 mA), ldoi7
  2800000-2960000 (11771-11778), ldoi5 1800000 (11738-11747, HPM above 10 mA). ldoi3/ldoi7 have no
  `qcom,supported-modes`: no mode command. The code refuses a voltage that is not one fixed DT value inside the
  node range; `negroni_rpmh_cam_rail` accepts only these five resources with these values.
- [V] Order (module file, `out/camera/modules.txt:49-50`): up VANA, VDIG, VIO, VAF, CUSTOM_REG1 (+0 ms each),
  RESET high +1 ms, MCLK 19.2 MHz +1 ms; down MCLK off +1 ms, RESET low +1 ms, VAF, CUSTOM_REG1, VIO, VDIG, VANA.
  The kernel takes this order from the module file (no in-kernel IMX789 table; `oplus_cam_sensor_core.c` only
  tests `sensor_id == 0x789` at :201).
- [V] Pins: reset gpio120 requested output-low (`gpio-req-tbl-flags` 0, 22212), MCLK0 gpio100 function 1
  `cam_mclk` (`pinctrl-waipio.h:1735`), CCI0 gpio110/111 function 1 `cci_i2c` (:1747-1748), pull-up / 2 mA
  (`out/live.dts:4995-5008`); suspend states 5010-5023, 5945-5957, 6006-6018. As Android
  (`camera_io_init` after the power-up), the CCI pins turn active only after the rails.
- [V] Read (`cam_cci_core.c` `cam_cci_read`): queue 1: SET_PARAM (sid 0x1a), LOCK, WRITE_DISABLE_P 0x00 0x16,
  READ 2, UNLOCK; RD_DONE; FIFO word byte 0 is not data. Expected `chip id 0x0789`.
- [I] Failure path: every step marks what it turned on before the write; `cam_down` undoes only those, sensor in
  the vendor power-down order, then CCI IRQs, camcc branches (reverse), GDSC (only when it was off before),
  GCC AXI. All waits are bounded (GDSC 500 us, branch/RCG 500 us, CCI 100 ms, RPMh 100 ms per vote).

### Level 3: raw frame (plan) [I unless marked]

- [V] Blocks: CSIPHY1 at 0xace6000 (`qcom,csiphy-v2.1.0`, 21909-21932), CSID0-2 `qcom,csid680` (23485-23601),
  IFE `qcom,vfe680` (23530...), CPAS top 0xac13000 + CAMNOC 0xac19000 (22701-22729). Register sources: camera-kernel
  `cam_ife_csid680.h`, `cpastop_v680_*.h`, `cam_csiphy` 2.1.0 tables; mainline Linux drives CSID 680 / VFE 680 for
  x1e80100 (`camss.c:4309-4505`) and is a cleaner reference.
- [V] IMX789 is **C-PHY**, 3 trios (laneAssign 0x0210, `modules.txt:45`); mainline CAMSS csiphy-3ph code was not
  checked for C-PHY. A D-PHY sensor (slot 1 S5KJN1 4 lanes CSIPHY2, or slot 3 OV08A10 2 lanes CSIPHY0) is the
  easier first stream; the level-2 code takes a slot table, so another slot is a data change plus its DT lines.
- First the test pattern generator (`qcom,cam-tpg103`) -> CSID -> IFE RDI write master, which needs no sensor.
- DMA: IFE writes go through the apps SMMU (0x15000000, `out/live.dts:15350`), streams 0x800/0x820/0xc00/... mask
  0x460 (`msm_cam_smmu_ife`, 22583). Reuse the Wi-Fi 0263 `wlan_dma_path` pattern: read SMR/S2CR for the stream;
  bypass = physical addresses work; fault/translate = needs an SMMU context we own (Gunyah may own the SMMU).
- Sensor start: the IMX789 init + mode register tables are in `cam_sensor_settings.h:6017` (OnePlus kernel) and the
  module file; streaming on = register 0x0100 = 1 (Sony convention, [I] for this part).

### Level 4: ICP PAS (plan)

- [V] `lx7_core.c` loads `CAMERA_ICP.mdt` with `qcom_mdt_load` into `camera_region@9f500000` (0x800000,
  `out/live.dts:184`) and calls `qcom_scm_pas_auth_and_reset(33)` (`lx7_core.h` CAM_FW_PAS_ID).
- [V] On this phone under UEFI + Gunyah, PAS calls from EL1 are reachable: the GPU zap PAS auth-and-reset returns
  0 (`docs/notes.md:1259-1260`), and `PAS is supported (adsp)` returns answer 0 for id 1 (notes:1254-1257), which
  Linux never asks.
- [I] PAS 33 is not tested. TZ may require the carve-out to be assigned (`qcom_scm_assign_mem`) or protected by
  the hypervisor; plan: same 0240 steps (mdt + segments into the carve-out, init_image, mem_setup, auth_and_reset)
  under a separate boot-arg. Only IPE/BPS need the ICP; level 3 raw capture does not.

### Level 5: iOS side (plan) [I]

- Stock path: CMCapture `BWFigCaptureDeviceVendor` looks up the camera driver service by class name
  (`AppleH10CamIn` / `AppleH13CamIn` strings), and `applecamerad` starts on the IOResources property
  `applecamerad` and loads ISP firmware. A fake `AppleH10CamIn` IOService must answer the user-client selectors of
  the D22 kernelcache kext (not reversed yet) with ISP-firmware semantics (frame metadata, buffers, controls).
  That is the large reverse-engineering part.
- First realistic target: our own IOService ("NegroniCamera") with a user client that returns one raw/RGB frame
  (level 3 output, CPU debayer) and a small app that shows it; then decide between the AppleH10CamIn emulation and
  an app-only camera.

## Main risks

- C-PHY for the main sensor: a second CSIPHY mode to bring up [V lanes; I effort].
- IPE/BPS processing needs the signed ICP firmware through TZ PAS 33 [V]; plan the raw path without it.
- CAMX tuning (`com.qti.tuned.*.bin`) and the CAMX userland are Android binaries; colour, AE, AWB,
  noise reduction and HDR must be written new or left out [I].
- AppleH10CamIn emulation may need Apple ISP firmware semantics that do not map to Qualcomm IFE
  output [I].
- A wrong rail order or voltage can damage a module: use only the rails, values and order in the
  table above, and power down on every error path. 0311 encodes them twice (negroni_cam.c table with DT
  lines, negroni_rpmh.c whitelist) and refuses any other value.
- An RPMh timeout poisons the RPMh path for the boot (negroni_rpmh.c): the power-down votes are then refused and
  rails can stay on until reboot (`WARNING: rails still voted on`). Reboot the phone after such a log.

## Sources

- Local: `out/live.dts`, `out/camera/*` (from the scripts above), `~/op10-backup` (read-only),
  `out/src/op-modules` (OnePlus kernel modules, sm8450_b_16.0), `out/src/linux`.
- Web (product level only; the slot mapping above comes from the vendor files):
  [OnePlus 10 Pro specifications](https://www.oneplus.com/us/10-pro/specs),
  [Qualcomm camera overview](https://docs.qualcomm.com/bundle/publicresource/topics/80-80021-17/camera-overview.html),
  [Apple AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice),
  [Apple Core Media I/O](https://developer.apple.com/documentation/coremediaio).
