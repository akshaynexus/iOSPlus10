# Camera support: hardware facts and plan

Status (2026-10-26, evening): levels 1-6 are code (patches 0310-0316: camcc + CCI0, IMX789 power + chip ID,
votes + CPAS/CAMNOC + SMMU check, capture clocks + CSIPHY1 C-PHY + sensor stream, CSID/IFE RDI raw frame to
memory from the TPG and from the IMX789, ICP PAS 33 + HFI), built, not run on the phone. The iOS side (level 7)
is a design (section "iOS capture service"). Before that: offline inventory (stage 0). Target: iOS 16.7.16
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
boot-arg value of `negronicam` (default 0: no camera register access). Levels 1-6 are code
(patches 0310-0316; `patches/xnu/README-camera.md`); level 7 (iOS) is a design. The level numbers here are the
`negronicam` values (until 2026-10-26 afternoon this table had raw frame = 3, ICP = 4, iOS = 5). The target is the
rear main sensor (slot 0, IMX789), as the owner asked. Line references: `out/live.dts` unless named.

| Level | Work | Proof point (exit condition) | Status |
|---|---|---|---|
| 0 | Offline inventory (`scripts/camera/`) | the table above | done |
| 1 | GCC camera clocks, camcc titan top GDSC, camcc AHB/CAMNOC/CCI0 clocks at 19.2 MHz TCXO, CCI0 reset | `NEGRONI CAM: level 1 OK: camcc + CCI0 up` after `CCI0 hw version 0x...` (not 0, not all ones) and `CCI0 reset done ack after N us` | code 0310, built, not run |
| 2 | Slot 0 power-up (5 RPMh rails, reset gpio120, MCLK0 19.2 MHz) in the module-file order, CCI0 M0 pins, chip-ID read, vendor power-down | `NEGRONI CAM: chip id 0x0789 (expected 0x0789, ...): MATCH` then `level 2 OK` | code 0311, built, not run |
| 0 (all) | RPMh MMCX NOM + camera NoC BCM votes (CN0, MM1, MM0, SH0, MC0) before the first camcc access | `step 1 rpmh mmcx + camera noc votes ... ok` | code 0312, built, not run |
| 3 | CPAS top + CAMNOC (version, IFE_RDI_WR QoS, error logger), apps-SMMU state of the IFE/ICP streams | `level 3 OK: CPAS/CAMNOC up, IFE DMA bypass, ...` | code 0312, built, not run |
| 4 | camcc PLL0/PLL3 + capture clocks + IFE0 GDSC, CSIPHY1 C-PHY 3 trios, IMX789 FTM table + stream on | trio status `normal`; `IMX789 frame counter ...: MOVES` | code 0313/0314, built, not run |
| 5 | CSID0 + IFE0 RDI0 -> memory: one TPG13 frame, then one IMX789 frame; device nodes + PNG script | `FRAME DONE`, `TPG/SENSOR frame sanity: PASS` | code 0315, built, not run |
| 6 | ICP (LX7) firmware through TZ PAS id 33, HFI init, SYS_INIT | `ICP READY: HFI init response SUCCESS`, `HFI_MSG_SYS_INIT_DONE` | code 0316, built, not run |
| 7 | iOS side: own NegroniCamera IOService + capture app (first), AppleH10CamIn emulation (later) | a frame visible in an app | design (below) |

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

### Votes (patch 0312) [V sources, I hardware result]

- [V] DT: `qcom,cam-cpas` interconnect `cam_ahb` <0x9f 0x02 0xa0 0x204> (live.dts:22712-22713, gem_noc apps ->
  config_noc camera cfg); `cam_hf_0` <0x329 0x10 0x43 0x200> (live.dts:22740-22748, mmss_noc camnoc_hf -> mc_virt
  ebi); `camnoc-axi-min-ib-bw` 3e9 B/s (live.dts:22724). BCMs of the nodes from Linux `sm8450.c` (out/src/linux):
  qhs_camera_cfg in CN0 (enable mask), qnm_camnoc_hf/sf in MM1 (enable mask), qns_mem_noc_hf in MM0, qns_llcc in SH0,
  ebi in MC0. Vote math = Linux `bcm-voter.c:95-116` (enable-mask BCMs: x = 0, y = 1, :99-101) with the cmd-db aux unit/width; data word = `tcs.h` BCM_TCS_CMD.
- [V] The titan GDSC parent is `pm8350c_s2_mmcx_voter_level` (mmcx.lvl, live.dts:10766-10773).
- [I] Level choice: MMCX NOM (256), BCM avg 1 GB/s, peak 3 GB/s. A vote from our DRV replaces our DRV's previous vote
  (the UEFI's, if it used the same DRV), so the values are chosen at or above the display need; the votes stay.

### Level 3: CPAS + SMMU (patch 0312)

- [V] CPAS top 0xac13000 (+0 camera version, expected 0x60800; +4 cpas version; +8 capability,
  cam_cpastop_hw.c:298-330), CAMNOC 0xac19000 (cpastop_v680_110.h: SBM, IFE_RDI_WR QoS, err logger, qchannel 0x5c/0x60).
- [V] SMMU: apps-smmu 0x15000000 (live.dts:15350-15361, skip-init, 0x78 SMRs); IFE SIDs 0x800.. mask 0x460
  (live.dts:22589), ICP 0x2000.. (22629). The check is the Wi-Fi 0263 logic; `negronicam_smmu=2` adds one SMR per
  group. [I] Whether the boot chain leaves the camera streams in bypass is the main unknown of level 5.
- [V] `expanded_memory` is absent from `qcom,cam_smmu`: the WM image address is a 32-bit IOVA (bus_ver3.c:3615-3636),
  so the buffers are below 4 GiB.

### Level 4: capture clocks, CSIPHY1, sensor stream (patches 0313, 0314)

- [V] Clocks: PLL0 1200 MHz (camcc-waipio.c:72-81), PLL3 864 MHz (:321-329), Lucid EVO sequence clk-alpha-pll.c
  :2969-3105; the PLL calibrates at ~1.3 GHz and needs >= SVS_L1 on its rail (:3155-3160); `mxc.lvl` is voted NOM
  (256) because gpu_cc_pll0 is on the same vdd_mxc up to NOMINAL 1750 MHz (gpucc-waipio.c:98-110) and our vote replaces
  any boot vote of this DRV. Rates as the
  DT: CSIPHY1 400 MHz (live.dts:21912), CSID 400 MHz (23491), IFE0 432 MHz lowsvs (23517). IFE0 GDSC 0xadf1004 (933-942).
- [V] CSIPHY v2.1.0 START order cam_csiphy_core.c:2379-2451; tables cam_csiphy_2_1_0_hwreg.h (37 regs per trio,
  data-rate entries, irq regs, reset exit 0x0e + 3048 us). Lane enable 0x2a for laneAssign 0x0210.
- [V] CSIPHY rails pm8350_l5/l6 are shared with the UFS PHY (live.dts:10429-10430): on, not voted.
- [I] Settle count 52 = module-file mode 1 value used as a count (D-PHY module values 26-40 fit the THS-SETTLE window
  only as timer counts). Data rate: FTM PLL gives ~823 MSps per trio -> data-rate entry 0 (<= 1.2 GSps).
- [V] Sensor table: OnePlus FTM table `cam_sensor_settings.h:6017-6141` (116 writes, ends with 0x0100 = 1), used by
  `cam_ftm_power_up` (oplus_cam_sensor_core.c:239-289, :441-449) after the power-up alone. Mode [I, SMIA map]:
  4000x3008 RAW10, 2x2 binning, 3 trios, frame length 3134, line length 37344 (= 30 fps at 3512 Mpix/s VT).
  The module file `resolutionData` mode 1 is also 4000x3008 30 fps (settle 52, 750.45 MHz output pixel clock).
- [I] Proof: SMIA frame counter 0x0005 moves.

### Level 5: raw frame (patch 0315)

- [V] CSID 680: Linux camss-csid-680.c (reset, RX cfg, RDI cfg, RUP/AUP bits 4+n/20+n, BUF_DONE bit 14+n) and
  camera-kernel cam_ife_csid680.h (offsets, TPG mux shifts 27/28, phy type shift 24). CSID top IO_PATH_CFG0 = 0x101.
- [V] VFE 680: RDI0 = bus client 24 at 0x2600 (cam_vfe680.h:1599-1628, Linux camss-vfe-680.c:41-58); RDI MIPI RAW10
  frame-based WM (bus_ver3.c:856-870: width 0xffff, height 0, en_cfg 1 << 16 | 1, packer PLAIN_128).
- [V] TPG 1.3 (tpg_hw_v_1_3.c): 640x480 RAW10 colour bars, 4 D-PHY lanes, CSID TPG mux 1 (tpg13, phy-id 0).
- [I] Order: TPG frame first (no sensor dependency: proves CSID, IFE, CAMNOC, SMMU, memory), then the sensor frame.
- Output: `/dev/negronicam-tpg`, `/dev/negronicam-sensor`; `scripts/camera/pull-frame.sh` + `raw-to-png.py`.

### Level 6: ICP PAS + HFI (patch 0316)

- [V] HFI queue header = 14 fields + 15 x 15 dummy words = 239 words, 956 bytes; queue table 24 + 4 x 956 = 3848
  bytes (hfi_reg.h:216-247).
- [V] `lx7_core.c:528-663` (mdt load into memory-region, `qcom_scm_pas_auth_and_reset(33)`), `hfi.c` cam_hfi_init
  (queue table, GP registers at CSR + 0x20, INIT_REQUEST, poll INIT_RESPONSE 1.5 s), CAM_ICP_SEND_INIT ->
  HFI_CMD_SYS_INIT 0x10001, answer HFI_MSG_SYS_INIT_DONE 0x20001.
- [V] CAMERA_ICP.mdt: 21 program headers, segment 0 = ELF headers (0x2d4), segment 20 = hash (0x10b8), mdt = both
  packed (5004 bytes); load span 0..0x700000 relocatable -> PAS mem setup with camera_region 0x9f500000 + 0x800000
  (live.dts:184-188; inside the UEFI "PIL Reserved" map entry, Mu-Silicium negroniPkg MemoryMapLib.c:14).
- [I] HFI addresses are physical (ICP stream bypass). Android gives IOVAs inside the DT windows (shared 0x800000,
  fw_uncached 0x10400000, io 0x10c00000; live.dts:22646-22669); the firmware may check them. If the init response
  fails, the next step is an ICP SMMU context with those IOVAs.

## iOS capture service (level 7, design) [V = out/camera/ios-re, 2026-10-26; I = design]

What the stock stack asks from the kernel (D22 kernelcache 20H392 + H10ISP.mediacapture disassembly, files in
`out/camera/ios-re/` (git-ignored; `selectors.txt` = the joined table, `kext-dispatch.txt` = the kernel table):

- [V] Class name `AppleH10CamIn` (kext com.apple.driver.AppleH10CameraInterface). H10ISP.mediacapture matches it
  (IOServiceMatching + IOServiceAddMatchingNotification), opens it with IOServiceOpen type 42 (0x2a), then calls
  selector 3 (open, 1 scalar) and 38 (GetVersion). Events come back through IOServiceAddInterestNotification
  (messageClient) and through IOConnectCallAsyncMethod wake ports (frame and work-item Mach messages).
- [V] The user client has 94 selectors (IOExternalMethodDispatch table at 0xfffffff006f3c768, 24-byte entries).
  The ones a start needs: 3 open, 4 close, 5 IsPowered (1 out), 38 GetVersion (1 out), 39 GetNumChannels (1 out),
  61 IsFirmwareLoaded (1 out), 15 GetCameraStatus (24-byte out), 7/26/79 firmware load (3 scalars), 9 forget,
  11/12 power on/off, 62 EnableFirmwareChannels, 35 EnableFastISPClock, 30 sensor clock, 52/53 reserve/release
  channel, 14 GetModuleParams (1688-byte out), 31 GetSensorConfigInfo (160-byte out), 55 calibration, 58/59
  StartCamera/StopCamera (channel). Capture: 6 SendBuffers (async, 0x38-byte entries with IOSurface IDs), 10
  SendCommand (pointer, size, 2 scalars: binary ISP-firmware command packets, 573 call sites; exposure, AF, AE,
  scaler, face detection), 41/42 GeneralProcess (952/1144-byte structs), 43-46/50 firmware work-processor upcalls.
- [V] Registry: CMCapture needs property `FirmwareLoaded` = true; H10ISP reads `sensor-type` (platform info,
  defaults to 0 when missing). The kext publishes IOResources `applecamerad` = true (kernel code at
  0xfffffff006616c6c), which is the launchd trigger of `/usr/sbin/applecamerad`. The sandbox kext ties the user client
  to applecamerad (our XNU has no sandbox kext).
- [I] The 94 selectors are not the hard part: selector 10 carries the private A11 ISP firmware protocol, and frames
  must come back as IOSurfaces with Apple ISP metadata. Emulating it means answering firmware opcodes and producing
  ISP output (debayer, tone, statistics) from Qualcomm raw frames. No public source documents the packets.

Design (realistic path):

1. Kernel: `NegroniCamera` IOService (own class name, not AppleH10CamIn), published when level 5 works. Properties:
   sensor list (slot, size, format). User client (few selectors): 0 open/power on (runs levels 0-4 for a slot),
   1 start stream (CSID/IFE RDI with a ring of N buffers, ping-pong WM addresses on each BUF_DONE; the CSID IRQ
   SPI 0x1d0 (live.dts:23497) instead of polling), 2 stop, 3 set exposure/gain (sensor registers 0x0202/0x0204 over
   CCI), 4 power off. Memory: an IOBufferMemoryDescriptor ring below 4 GiB mapped into the app
   (clientMemoryForType); frame-ready notification by an async method with a wake port.
2. Userland: a small capture app (our root, like the Metal test apps): debayer on the GPU (Metal compute shader on
   the Adreno path when it is stable, CPU NEON otherwise), gray-world white balance, gamma; show in a CAMetalLayer;
   save a DNG/PNG. Optional: AF via the AK7377 actuator (CCI0, 0x18) and exposure control in the app.
3. Later, only if wanted: an `AppleH10CamIn` subset so applecamerad starts and CMCapture builds a device
   (publishResource("applecamerad"), FirmwareLoaded, selectors above with canned answers). Real AVCaptureSession
   frames need the selector-10 protocol: a long reverse-engineering task with an uncertain end. ICP/IPE/BPS
   (level 6) could do the ISP work on the Qualcomm side, but its packet formats are CAMX-private too.

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
  `out/src/op-modules` (OnePlus kernel modules, sm8450_b_16.0), `out/src/op-kernel`, `out/src/linux`. These are sparse
  clones: the camera-kernel files (cam_cpas, cam_csiphy, cam_isp, cam_icp, cam_tpg, oplus sensor settings), the clock
  files (camcc-waipio.c, clk-alpha-pll.c, gpucc-waipio.c), Linux camss, interconnect sm8450.c, bcm-voter.c and
  include/soc/qcom/tcs.h were read from the git objects (`git -C <clone> show HEAD:<path>`), not from the checkout.
- Web (product level only; the slot mapping above comes from the vendor files):
  [OnePlus 10 Pro specifications](https://www.oneplus.com/us/10-pro/specs),
  [Qualcomm camera overview](https://docs.qualcomm.com/bundle/publicresource/topics/80-80021-17/camera-overview.html),
  [Apple AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice),
  [Apple Core Media I/O](https://developer.apple.com/documentation/coremediaio).
