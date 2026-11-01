# Mi A3 (laurel_sprout) camera: hardware, path decision, step 1

Status 2026-11-01: step 1 (power + CCI + chip ID of all four cameras) is code, kernel patch 2770, built (249/249
patches, 0 LSE). Not run on the phone yet. The Camera app does not work yet: no frame path and no iOS side.
Labels: [V] read in a file or seen in a tool output (source given), [I] inference, [U] unknown.

## 1. Hardware

### Cameras (slots)

Slot = DT `cell-index` = Android camera id. Sources [V]: `external/laurel-kernel-los` DT
(`xiaomi/laurel_sprout/laurel_sprout-trinket-camera.dtsi` over `qcom/trinket-camera-sensor-qrd.dtsi`), the stock
vendor image (`/etc/camera/camera_config.xml`, `/lib/libmmcamera_laurus_<sensor>.so`) of V12.0.26.0.RFQMIXM, read by
`scripts/laurel/camera-inventory.sh` (output `out/laurel/camera/sensors.txt`, git-ignored).

| | Slot 0 | Slot 1 | Slot 2 | Slot 3 |
| --- | --- | --- | --- | --- |
| Role | rear main | rear depth (BACK_AUX) | front | rear ultrawide (BACK_AUX) |
| Sensor (module makers) | Sony IMX586 48 MP (qtech, sunny); IMX582 (qtech) in some units | GalaxyCore GC2375H 2 MP (qtech) or OmniVision OV02A10 (sunny) | Samsung S5KGD1 32 MP (ofilm, sunny) | Samsung S5K4H7 8 MP (qtech, sunny) |
| CCI master | M0 (gpio 37 SDA, 38 SCL) | M1 (gpio 39, 40) | M1 | M1 |
| 7-bit address | 0x1a | 0x17 (GC) / 0x3d (OV) | 0x2d | 0x10 |
| Chip ID @ register | 0x0586 (0x0582) @ 0x0016, 16-bit addr | 0x2375 @ 0xf0 / 0x2509 @ 0x02, 8-bit addr | 0x0841 @ 0x0000 | 0x487b @ 0x0000 |
| I2C speed (library) | 1 MHz | 400 kHz / 100 kHz | 1 MHz | 400 kHz |
| CSIPHY / CSID | 1 / 1 | 0 / 0 | 2 / 2 | 2 / 2 |
| Lanes (camera_config.xml) | 4 (mask 0x1f, assign 0x4320) | 1 (mask 0x3) | 4 | 4 |
| MCLK (pin, function) | MCLK0 gpio 34 (f1) | MCLK1 gpio 35 (f1) | MCLK2 gpio 36 (f1) | MCLK3 gpio 44 (f7) |
| MCLK in the library | 24 MHz | 24 MHz | 19.2 MHz | 24 MHz |
| Reset GPIO | 48 | 46 (power-down pin, active high) | 42 | 41 |
| Rails (GPIO-switched LDOs) | VIO 49, VANA 15, VDIG 14, VAF 123 | VANA 20 | VANA 20, VDIG 82 | VANA 20, VDIG 21 |
| VIO regulator | PM6125 L12A 1.8 V ("VREG VIO") | L12A | L12A | L12A |
| Other | actuator DW9800W (VAF), EEPROM, PMI632 flash | none | EEPROM; MIPI switch CUSTOM1 114 low, CUSTOM2 115 high | EEPROM; switch 114 low, 115 low |
| Modes (library) | 8000x6000, 4000x3000, 1920x1080 (4), 1280x720 @93 fps | not in the table form | 3280x2464, 1280x720 | 3264x2448, 1632x1224, 1920x1080 |

- [V] The QRD DT supplies (`cam_vana`/`cam_vdig` = PM8008 L1P-L5P) do not exist on the Mi A3: trinket.dtsi
  disables both PM8008 nodes, and the laurel DT replaces them with `qcom,gpio-vana/vdig/vio/vaf` pins. The power
  orders in the libraries use `GPIO VANA/VDIG/VIO/VAF` steps plus one `VREG VIO` step (= `cam_vio-supply` L12A).
  L12A has no other consumer in the DT.
- [V] Front and ultrawide share CSIPHY2 and CSID2 through an analog MIPI switch (CUSTOM1/CUSTOM2 = gpio 114/115):
  only one of the two can stream at a time.
- [V] Power-up orders (libraries; "+N" = ms after the step):
  rear: reset low +1, VIO gpio +1, VANA +1, VDIG +1, L12A, MCLK +1, VAF +1, reset high +11;
  depth GC2375H: reset high +1, L12A +10, VANA +10, MCLK +5, reset low +1; OV02A10: reset high +1, L12A +5, VANA +5,
  reset low +5, MCLK +10; front: reset low +1, VANA, VDIG +1, L12A +5, reset high +10, MCLK +1, CUSTOM1 low +1,
  CUSTOM2 high +1; ultrawide: reset low +1, VANA +1, VDIG +1, L12A +1, reset high +1, MCLK +10, CUSTOM1 low +1,
  CUSTOM2 low +1. Power-down orders: `sensors.txt`.
- [V] IMX586 library: one init table (531 register writes at `.data`+0x9f2c, starts with INCK 0x0136/0x0137 =
  0x1800 = 24 MHz) and 7 per-mode tables (86-95 writes each; mode 6 = 1280x720 at `.data`+0x7f368, 95 writes).
  Entries are `{u16 addr, u16 data, u32 delay}`. The S5K4H7 tables have 16-bit data (other entry form, not decoded).

### CAMSS blocks (SM6125 = "trinket", camera v2 / CAMSS gen1, the sdm660 type)

[V `qcom/trinket-camera.dtsi`, `qcom/trinket-gdsc.dtsi`, `drivers/clk/qcom/gcc-trinket.c`]

| Block | Address | IRQ (SPI) | Notes |
| --- | --- | --- | --- |
| CCI (I2C for sensors) | 0x5c0c000 | 207 | 2 masters; clocks camera_ahb 0x17008, camss_top_ahb 0x560a0, cci_ahb 0x52020, cci 0x5201c, RCG 0x52004 (37.5 MHz) |
| CSIPHY0/1/2 | 0x1628000 / 0x1629000 / 0x162a000 | 72 / 73 / 74 | `qcom,csiphy-v3.5` (3-phase PHY used as D-PHY); clk mux 0x5c00120 |
| CSID0-3 | 0x5c30000 + 0x400 n | 208-211 | `qcom,csid-v5.0`; vdd L18A 1.232 V |
| ISPIF | 0x5c31000 | 212 | `qcom,ispif-v3.0`, routes CSID -> VFE RDI/PIX |
| VFE0 / VFE1 | 0x5c10000 / 0x5c14000 | 214 / 215 | `qcom,vfe48`; VBIF 0x5c40000; GDSC vfe0 0x1454004 |
| CPP, JPEG | 0x5c04000, 0x5c1c000 | 206, 216 | not needed for raw frames |
| camss_top GDSC | 0x145607c | | every camera block is inside it |
| SMMU streams | VFE 0x420 (mask 0), 0x421 (mask 2); CPP 0x800; JPEG 0x820/0x821 | | apps SMMU, needed for VFE writes |
| MCLK0-3 RCG / branch | 0x51000 + 0x1c n / 0x51018 + 0x1c n | | 19.2 MHz TCXO, 24 MHz = GPLL9 M/N 1/24, 64 MHz |

Mainline Linux has no sm6125 CAMSS or CCI node [V `external/laurel-mainline`], but its sdm660 CAMSS code is the
same hardware generation [V downstream compatibles: csid-v5.0 = mainline `camss-csid-4-7.c` "CAMSS_660",
vfe48 = `camss-vfe-4-8.c`, ispif-v3.0 = `camss-ispif.c`, csiphy-v3.5 = `camss-csiphy-3ph-1-0.c`]; the CCI register
map and the trinket timing values equal mainline `i2c-qcom-cci.c` cci_v2 [V].

## 2. The Linux pipeline and the simplest frame path

Android (4.14): kernel `msm camera v2` (sensor power and CCI in the kernel; sensor tables, 3A, ISP tuning and the
whole ISP pipeline config in user space: mm-camera `libmmcamera_*`, chromatix libraries) [V file list in
`external/laurel-device-los/proprietary-files.txt`]. Mainline: `qcom-camss` + a sensor driver (V4L2).

The simplest path, without the ISP (RDI = raw dump interface):

```
sensor (mode table over CCI, streams RAW10 over MIPI D-PHY)
  -> CSIPHY n (lanes, settle count)  -> CSID n (RX: lane count, CSIPHY select; CID/VC/DT LUT, RAW10, RDI on)
  -> ISPIF (CSID n -> VFE0 RDI0, clock mux)  -> VFE0 RDI0 bus write master (raw, plain packing off = MIPI RAW10)
  -> frame buffer in memory (contiguous, below 4 GiB, SMMU stream 0x420 identity)
  -> demosaic + white balance + gamma on the CPU (negroni/HakiOS camera_isp.c) or on the GPU
```

CSID has a test pattern generator (TG: colour bars, `CAMSS_CSID_TG_*`), so CSID -> ISPIF -> VFE -> memory can be
brought up without a sensor first (mainline `camss-csid-4-7.c` does that). Frame sizes: 1280x720 RAW10 = 1.15 MB,
4000x3000 = 15 MB.

## 3. iOS side: what the Camera app needs

- [V negroni `docs/camera-plan.md`, `out/camera/ios-stack.txt` there] iOS 16 talks to Apple's ISP through
  `AppleH10CamIn` (94 user-client selectors), `applecamerad` and ISP firmware. Qualcomm CAMSS cannot stand in for it:
  the ISP firmware protocol is Apple-only [I, strong]. So the Apple path is out.
- [V `userland/camera/README.md`, negroni 0318] negroni's path (from HakiOS): a CFPlugIn bundle in mediaserverd
  (`NegroniCamera.driver`, loaded as an audio HAL plug-in) replaces `+[BWFigCaptureDeviceVendor
  sharedCaptureDeviceVendor]` and 7 more CMCapture methods (addresses for the 20H392 dyld cache, guarded by its UUID),
  makes a FigCaptureDevice/FigCaptureStream (`camera_device.c`, HakiOS, MIT) that reads RAW10 frames from a kernel
  device (`/dev/negronicam`, the HakiOS `/dev/hakios-camera` ABI: 120-byte `NCFRAME1` header + frame bytes, write =
  exposure/gain commands), runs a CPU ISP (`camera_isp.c`: black level, demosaic, grey-world AWB, colour matrix,
  gamma, scaler) and hands CVPixelBuffers to the capture graph; it also starts the capture servers that our root's
  `StartRecorderServer` = false leaves off. ADT `/arm-io/isp` `camera-rear` = 1 and `/product/camera` make
  MobileGestalt report `still-camera`, so SpringBoard shows Camera.app.
- [V] negroni status: built and host-checked, never run on the phone (its kernel side 0310-0318 also not run).
  HakiOS ran the same media library and ISP on its own phone [I from `external/hackios-scion/avf/CAMERA.md` "as on
  HakiOS's phone"]; HakiOS's kernel driver for the POCO X5 Pro (`external/hackios-umi/.../redwood_camera.c`) powers
  sensors, reads chip IDs and dumps CSID TPG / sensor frames through RDI + IFE-lite (a Spectra/Titan SoC, other
  registers than trinket).
- [V `docs/laurel_sprout/port-plan.md`, `rtc-statusbar.md`] laurel runs the same iOS 16.7.16 20H392 iPhone X root, so
  the negroni plug-in, its hook table and its cache-UUID guard apply without change [I: same dyld cache UUID
  8F970452-...; to check with `scripts/camera/check-cache.sh` on the laurel root].

What the app needs, in order: (1) the Camera icon (ADT nodes; only when a frame path exists, else the launch hangs:
negroni notes "hung Camera launch"); (2) the capture servers running; (3) a FigCaptureDevice with one stream whose
frames come at a steady rate (preview); (4) a still image from the same stream (photo: the plug-in encodes HEIC
through the software HEVC encoder). Video recording, focus, flash and the front camera come later.

## 4. Path decision

**Decision: RDI raw frames (no Qualcomm ISP, no CPP, no firmware) from the kernel, the negroni/HakiOS
mediaserverd plug-in + CPU ISP on the iOS side, same `NCFRAME1` device ABI.** Evidence:

- The trinket CAMSS needs no firmware for RDI (no ICP/A5 on this generation, unlike negroni's SM8450 ICP PAS 33)
  [V: trinket-camera.dtsi has no `qcom,cam-icp` / firmware node]; mainline sdm660 CAMSS does RDI dumps with plain
  register writes.
- The sensor init/mode tables are in the stock libraries (data, not code) [V section 1]: the kernel can take them
  at run time from a root copy of the vendor libraries (root step, like the GPU firmware: `gpu-firmware.sh`), so no
  blob goes into git and no Android user space is needed.
- The iOS side exists (negroni, built + host-checked) and keeps the ABI the kernel serves.

Rejected: Apple camera stack (ISP firmware protocol); Qualcomm VFE pixel path + CPP (needs the chromatix tuning
and the mm-camera ISP configuration in user space); UVC-style USB gadget (no host).

## 5. Steps

1. **Done (code, patch 2770): find the cameras.** Power, CCI, chip ID of each slot, one line. Section 6.
2. Capture path, rear IMX586 at 1280x720 (mode 6): MCLK 24 MHz (GPLL9 M/N 1/24), sensor init + mode 6 tables from
   `/usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_*.so` (root step `scripts/laurel/root-camera.sh`,
   to write; parser = `camera-sensors.py` logic in the kernel), CSIPHY1 D-PHY 4 lanes (settle count from the lane
   rate), CSID1 RX RAW10 VC0 DT 0x2b, ISPIF CSID1 -> VFE0 RDI0, VFE0 RDI0 write master into 3 buffers of 1.15 MB
   from a pool (the modem pool has 16 MiB shared with modem/audio/BT: take the GPU pool or a new 16 MiB camera pool
   in the reserved 0x80000000-0xC0000000 area, `uefi-boot.md` map), apps SMMU identity for streams 0x420/0x421
   (`topaz_smmu_identity`), VFE GDSC + vfe0/csi/cphy/ispif clocks, frame done by polling the VFE bus status. Self-
   check: the first frame arrives (sequence, line count). TPG first in the same code path when the sensor does not
   stream (the CSID TG is the CSID's own input, not a separate test path).
3. `/dev/negronicam`-compatible node (`NCFRAME1`, RAW10, bayer order of the mode, black level 64 [I]) + exposure /
   gain writes (IMX586 0x0202 coarse integration, 0x0204 analog gain).
4. iOS: build `userland/camera` for laurel (sensor 1 = rear), root step (plug-in + ADT `camera-rear`), test Camera.app
   preview + photo.
5. Later: front (S5KGD1, CSIPHY2 + switch), ultrawide, focus (DW9800W on M0), flash (PMI632), GPU demosaic.

## 6. Step 1 (patch 2770)

Files: `bsd/dev/laurel_cam_core.h` (tables + CCI command packing, pure, host-tested), `laurel_cam_hw.c` (camss_top
GDSC, GCC branches, CCI RCG 37.5 MHz, MCLK 19.2 MHz, TLMM, L12A over the RPM), `laurel_cam_cci.c` (CCI controller,
polled), `laurel_cam.c` (start, scan, line, sysctl), `laurel_cam.h`.

Order: wait for `topaz_soc_map` (RPM doorbell; no camera clock on while it waits), GDSC on, camera AHB, camss top
AHB, CCI RCG (GPLL0 early / 16; TCXO 19.2 MHz + cci_v1 timing if GPLL0 is not locked), CCI AHB + core, CCI pins
(func 1, pull-up); each branch must report on before the CCI is touched. CCI reset, timing of M0/M1. Per slot:
power-up list, chip ID of each candidate (write the register address, STOP, read 2 bytes; 400 kHz, OV02A10 100 kHz),
power-down list, rail and reset pins released (input, pull-down). Then the CCI status bits are masked, MCLKs off,
the CCI clocks, CCI RCG, AHB branches and the GDSC go back to the state the boot left. L12A is switched off after
each slot (camera-only rail). An RPM refusal of L12A is logged and the scan goes on (the ID read is the check).

MCLK is 19.2 MHz (TCXO, no PLL) for the ID read [I: I2C of these sensors works at any INCK in their range;
HakiOS did the same on redwood]. Step 2 changes to 24 MHz for streaming (the IMX586 tables set INCK = 24 MHz).

Expected lines (USB log `scripts/laurel/log-pull.sh` or the console):

```
LAUREL CAMERA: clk: camss_top GDSC on (was off), CCI 37500000 Hz, GDSC 0x8...
LAUREL CAMERA: cci: version 0x1..., 37500000 Hz
LAUREL CAMERA: rear: IMX586 chip ID 0x0586 at 0x1a (CCI M0), MCLK0
LAUREL CAMERA: depth: GC2375H chip ID 0x2375 at 0x17 (CCI M1), MCLK1          (or OV02A10 0x2509 at 0x3d)
LAUREL CAMERA: front: S5KGD1 chip ID 0x0841 at 0x2d (CCI M1), MCLK2
LAUREL CAMERA: ultrawide: S5K4H7 chip ID 0x487b at 0x10 (CCI M1), MCLK3
LAUREL CAMERA: on: rear IMX586 (0x1a id 0x0586), depth GC2375H (0x17 id 0x2375), front S5KGD1 (0x2d id 0x0841), ultrawide S5K4H7 (0x10 id 0x487b); CCI 37500000 Hz, MCLK 19.2 MHz; capture path: step 2
```

Failure lines: `LAUREL CAMERA: <slot>: no sensor: NACK at 0x1a` (no answer: rail, reset or MCLK wrong),
`... 0x1a id 0x....` (an unknown module: add it to the table), `LAUREL CAMERA: off: camss_top GDSC does not power on`,
`off: CCI clocks do not run`, `off: CCI reset does not finish`, `off: no sensor answered (...)`, `off: camera=0`.
`sysctl kern.laurel_camera` gives the result text.

Test (no root change; owner approval for the boot partition write):

1. `scripts/bg.sh cam-kernel scripts/laurel/kernel-linux.sh`, image as usual (`scripts/laurel/uefi-image.sh`). This
   ABL refuses `fastboot boot` (plan.md "Flashing"): flash `boot_b` with `scripts/laurel/flash-boot.sh` after the
   owner says yes.
2. Look for the lines above in the USB log; `sysctl kern.laurel_camera` over the USB shell.
3. Kill switch: boot-arg `camera=0` -> `LAUREL CAMERA: off: camera=0`, no camera register is touched.
4. Host test: `scripts/laurel/cam-test.sh` (69 checks; with `out/laurel/camera/sensors.txt` it compares every
   address and chip ID with the stock libraries).

## 7. Reproduce the inventory

```
scripts/bg.sh cam-inv scripts/laurel/camera-inventory.sh    # ~1 min: simg2img + debugfs + parser
cat out/laurel/camera/sensors.txt
```
