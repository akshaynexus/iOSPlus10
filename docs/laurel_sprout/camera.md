# Mi A3 (laurel_sprout) camera: hardware, path decision, step 1

Status 2026-11-01: step 1 (power + CCI + chip ID of all four cameras) is code, kernel patch 2770, built (249/249
patches, 0 LSE). **2026-11-01 18:40: the Camera app ran on the phone; quality work after that: section 10.** **Boot 20:02: crash loop without Metal, photo path, black frames: section 11.** **Why a streaming sensor shows no light, self-check of the signal: section 12.** Step 2 (rear IMX586 RDI raw frames 1280x720, fps line, `camframe` picture over USB) is code, kernel
patch 2771, built (252/252 patches, 0 LSE), host-tested (section 8). Steps 3 + 4 (`/dev/negronicam`, mediaserverd plug-in, root step, ADT nodes) are code,
kernel patch 2772 + 2903, built (259/259 patches, 0 LSE), host-tested (section 9). **None of this ran on the phone yet.**
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
  Correction (step 2, [V] `scripts/laurel/camera-tables.py`): mode 6 starts at `.data`+0x7f370 and has **94** writes; the
  95th "write" {0x0001, 0} at 0x7f368 is the trailer of the table before it (data_type 1, delay 0). Full layout: section 8.

### CAMSS blocks (SM6125 = "trinket", camera v2 / CAMSS gen1, the sdm660 type)

[V `qcom/trinket-camera.dtsi`, `qcom/trinket-gdsc.dtsi`, `drivers/clk/qcom/gcc-trinket.c`]

| Block | Address | IRQ (SPI) | Notes |
| --- | --- | --- | --- |
| CCI (I2C for sensors) | 0x5c0c000 | 207 | 2 masters; clocks camera_ahb 0x17008, camss_top_ahb 0x560a0, cci_ahb 0x52020, cci 0x5201c, RCG 0x52004 (37.5 MHz) |
| CSIPHY0/1/2 | 0x1628000 / 0x1629000 / 0x162a000 | 72 / 73 / 74 | `qcom,csiphy-v3.5` (3-phase PHY used as D-PHY); clk mux 0x5c00120 + 4n (CSIPHY1: 0x5c00124) |
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
2. **Done (code, patch 2771, section 8):** capture path, rear IMX586 at 1280x720 (mode 6). Plan was: MCLK 24 MHz (GPLL9 M/N 1/24), sensor init + mode 6 tables from
   `/usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_*.so` (root step `scripts/laurel/root-camera.sh`,
   to write; parser = `camera-sensors.py` logic in the kernel), CSIPHY1 D-PHY 4 lanes (settle count from the lane
   rate), CSID1 RX RAW10 VC0 DT 0x2b, ISPIF CSID1 -> VFE0 RDI0, VFE0 RDI0 write master into 3 buffers of 1.15 MB
   from a pool (the modem pool has 16 MiB shared with modem/audio/BT: take the GPU pool or a new 16 MiB camera pool
   in the reserved 0x80000000-0xC0000000 area, `uefi-boot.md` map), apps SMMU identity for streams 0x420/0x421
   (`topaz_smmu_identity`), VFE GDSC + vfe0/csi/cphy/ispif clocks, frame done by polling the VFE bus status. Self-
   check: the first frame arrives (sequence, line count). TPG first in the same code path when the sensor does not
   stream (the CSID TG is the CSID's own input, not a separate test path).
3. **Done (code, patch 2772, section 9):** `/dev/negronicam` (`NCFRAME1`, RAW10, Bayer of the mode, black level 64 [I]), session
   only while a client reads, exposure + gain + frame length writes (IMX586 0x0202, 0x0204, 0x0340).
4. **Done (code, section 9):** `userland/laurel/camera/build.sh` builds the plug-in on Linux, `root-camera.sh` installs it, `mkadt.py`
   adds the camera nodes. Test: Camera.app preview + photo.
5. Later: front (S5KGD1, CSIPHY2 + switch: section 9), ultrawide, flash (PMI632), EEPROM calibration (AF, LSC, AWB), GPU demosaic. Focus: section 10.

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

## 8. Step 2 (patch 2771): rear RDI raw frames, fps line, picture over USB

Status 2026-11-01: code, built (252/252 patches, 0 LSE, kernel sha256 dcbae3a4...), host tests pass. **Not run on the
phone.** Labels as above: [V] seen in a file or tool output, [I] inference.

### Files (kernel, `bsd/dev/`, each < 300 lines, each `scripts/laurel/kcheck.sh` OK)

| File | Content |
| --- | --- |
| `laurel_cam_lib.h` | stock sensor library parser (pure, host-tested): ELF32 `.data`, tables, modes, CSI parameters, CCI bursts |
| `laurel_cam_rdi.h` | pure helpers: CSID lane word, CSIPHY lane mask/enable/blocks, settle scaling, RAW10, AE, read protocol |
| `laurel_cam_clk.c` | VFE0/VFE1 GDSCs, PLL choice, 5 RCGs, 18 branches + throttle vote, full restore |
| `laurel_cam_csi.c` | CSIPHY1 D-PHY lane sequence, CSID1 RX or test generator, CSID counters |
| `laurel_cam_ispif.c` | ISPIF reset/init, CSID1 -> VFE0 RDI0, frame-boundary enable/disable |
| `laurel_cam_vfe.c` | VFE0 reset, VBIF, QoS/DS, RDI0 -> WM0 frame-based ping-pong, polled status, halt |
| `laurel_cam_sensor.c` | library file from the root, MCLK 24 MHz, power-up, chip ID, init + mode tables, exposure, stream on/off |
| `laurel_cam_stream.c` | one capture run (bring-up order, frame loop, AE, TPG fallback, teardown), sysctl `kern.laurel_camera_stream` |
| `laurel_cam_ctl.c` | stream thread (root wait, buffers, SMMU), USB commands `camframe` / `caminfo` / `camread` |
| `laurel_cam_st.h` | state shared by stream.c and ctl.c |
| changed: `laurel_cam.c` (start of step 2 after the scan, `lcam_power`), `laurel_cam_hw.c` (MCLK 24 MHz, exports), `laurel_cam.h`, `sweet_usb.c` (camera commands, binary reply), `bsd/conf/files` | |

### Sensor tables at run time [V]

The kernel holds no register table. `/usr/share/firmware/laurel-camera/libmmcamera_laurus_{imx586_qtech,imx586_sunny,
imx582_qtech}.so` (root step `scripts/laurel/root-camera.sh`, called by `root.sh`, `CAMERA=0` skips; the files come
from `scripts/laurel/camera-inventory.sh`, never in git). `sensor_lib_t` layout in `.data`, the same in all three files:

| Offset | Content |
| --- | --- |
| 0x0000 / 0x20 / 0x30 | name[32] / slave (8-bit) / chip ID register + chip ID |
| 0x5fa4 | output format 0, connection 1 (MIPI), raw 1 (10-bit), filter 3 (RGGB [I: mm-camera enum BGGR, GBRG, GRBG, RGGB]) |
| 0x5fb4 | output registers 0x034c/0x034e/0x0342/0x0340, exposure 0x0202, gain 0x0204, vert_offset 48 (0x5fcc) |
| 0x9f2c | init table: 3000 x {u16 addr, u16 data, u32 delay}, then u16 size (0 in the file), u32 addr_type 2, u32 data_type 1, u32 delay |
| 0x5c090 + k x 0x5dd0 | resolution table k (same form) |
| 0xae1f0 | u32 mode count (7), then 0x60-byte records: x, y, line_length, frame_length, vt_pixel_clk at +12, op_pixel_clk u64 at +0x58 |
| 0xae740 | lanes 4, settle 0x13, 3-phase 0 |
| 0xae744 + k x 0x104 | CID LUT: count 1, {cid 0, dt 0x2b, decode 2} |

IMX586 qtech = sunny: init 531 writes (239 CCI bursts of consecutive registers), mode 6 94 writes (39 bursts); IMX582
qtech: 408 / 114. Mode 6 sets RAW10 (0x0112/0x0113 = 0x0a), 4 lanes (0x0114 = 3), line 5376, frame 780 lines,
exposure 732 lines, analog gain code 0x70. `cam-test.sh` compares the C parser with `camera-tables.py` byte for byte.

### Hardware sequence (values: research of 2026-11-01, downstream camera_v2 first, mainline camss cross-check)

1. `lcam_hw_on` (step 1: camss_top GDSC, AHB, CCI), CCI reset.
2. `lcam_sclk_on`: PLLs voted, used only when locked: GPLL4 -> CSIPHY timer + csiphy source 268.8 MHz (Android's rate,
   settle 0x13 unchanged) and VFE 403.2 MHz; else timer 200 MHz from GPLL0 (settle scaled to 0x0e) and VFE from GPLL8
   480 / GPLL9 576 / GPLL6 256 MHz. CSID1 200 MHz (GPLL0 / 3). VFE0 + VFE1 GDSCs (ISPIF reset covers both). 18 branches,
   each checked with CLK_OFF (ahb2phy_csi has hardware gating: no check). throttle_rt_axi vote 0x79004 bit 26.
3. Sensor: MCLK0 24 MHz (GPLL9 main / 24 M/N: M 1, N ~23, D ~24, CFG src 2 hid 1 dual edge; GPLL9 not locked = 19.2 MHz
   + line), step 1 power-up list, chip ID again, init + mode tables, `0x0100 = 0` (LP-11).
4. VFE0: reset 0x3f7 (RESET_ACK bit 31), VBIF 0x124/0xac/0xd0, BUS_CFG 0x101, QoS 0xfff8fff8 x 8, DS 0xcccc0011 x 16 +
   0x110, WM0 ADDR_CFG 0x2 (frame based, period 1), pattern 1, subsample all, UB 682, PING/PONG = buffers 0/1, masks,
   RDI_CFG_0 7, XBAR WM0 <- RDI0 (0xc << 8), WM0 on (0xcec = 2), reload, REG_UPDATE 0x2.
5. ISPIF: reset 0x000f1fff (bit 27), init values, RDI mux 0x5c00028 = CSID1, INPUT_SEL bits 5:4 = 1, CID mask 1, IRQ group
   0x02492000, INTF_CMD_0 = 0xfffffdff (RDI0 enable at frame boundary).
6. CSID1: reset 0x7ffff (bit 11), CORE_CTRL_0 0x32103, CORE_CTRL_1 (1 << 17) | 0xf (HW version >= 0x30000000), LUT VC0 0x2b,
   CID0 cfg 0x23.
7. CSIPHY1: reset 0x800, mux 0x5c00124 = 1, 0x814 = 0xd5, 0x818 = 1, per lane (D0, CLK, D1, D2, D3) the msm_csiphy
   2-phase values, settle in cfg3, IRQ masks 0x82c..0x854, clear.
8. Exposure (AE state), stream on, frames for 2 s (self-check) / 1.5 s (`camframe`): WM0 ping-pong done -> the finished
   buffer leaves the VFE, the spare one goes in (3 buffers: 2 in the VFE, the latest kept out); REG_UPDATE at each RDI0
   reg update; AE every 4 frames (mean of 2304 samples, target 180 above black 64, exposure first, gain up to 16x).
9. Stream off, VFE stop + bus halt, ISPIF stop, CSID reset, CSIPHY off, sensor power-down, clocks back, CCI off, GDSC back.

Buffers: 3 x 1,152,000 bytes (1600 x 720) from the GPU pool (`topaz_gpu_pool_alloc`: contiguous, below 4 GiB, Normal
NC, so no cache maintenance). gpu=0 or no pool in the ADT = `off: no frame buffer ...`. SMMU: `topaz_smmu_identity(0x420, 0)`
and `(0x421, 2)`. No interrupt line: the status words are polled every 1 ms (a frame takes 10.7 ms at 93.5 fps).

### Lines (USB log / console)

```
LAUREL CAMERA: on: rear IMX586 (0x1a id 0x0586), ...; CCI 37500000 Hz, MCLK 19.2 MHz; capture path: rear RDI (stream line follows)
LAUREL CAMERA: sensor: laurus_imx586_qtech from libmmcamera_laurus_imx586_qtech.so: init + mode 6 in 278 CCI writes, MCLK 24000000 Hz
LAUREL CAMERA: rear stream: 1280x720 RAW10 at 93.5 fps, frame 186 (kept for camframe), mean 240, exposure 732 lines gain 4.00x, VFE errors 0 (0); libmmcamera_laurus_imx586_qtech.so, MCLK 24000000 Hz, CSIPHY1 4 lanes settle 0x13 (timer 268 MHz), VFE 403 MHz, buffers 0xc...
```

(numbers [I]: 93.5 fps from the mode table; the frame count is about 2 s x fps.) Failure lines:
`rear stream: off: no /usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_*.so (root step root-camera.sh)`,
`off: no frame buffer below 4 GiB from the GPU pool (...)`, `off: apps SMMU: ...`, `off: VFE0 reset does not finish`,
`off: ISPIF reset does not finish`, `off: CSID reset does not finish`, `off: a camera branch clock does not run` (with a
`clk: <name> CBCR ...` line), `off: no PLL for the VFE clock is locked`, `off: no chip ID answer after the power-up`, and
`off: no frame from the sensor in 1 s (CSID packets N ECC E CRC C irq .., CSIPHY status .., ISPIF .., VFE ...); CSID test
pattern: K frames at F fps (...)`. How to read the last one: CSID packets 0 = nothing on the lanes (sensor not
streaming, CSIPHY settle/lanes); packets > 0 but no frame = CSID/ISPIF/VFE; test pattern frames > 0 = the back end and
the memory path work. Possible cause not handled [I]: the VFE AXI path needs a bus vote (DT msm-bus MASTER_VFE ->
EBI, 100 MB/s; no RPM-SMD bus voter in this kernel): no ping-pong done + no halt ack points there.

### Picture on the host

```
make usblog                              # USB link (once)
scripts/laurel/cam-frame.sh              # new 1.5 s capture, read, logs/camera/camframe-genN.raw10 + .png
scripts/laurel/cam-frame.sh --raw logs/camera/camframe-gen2.raw10 --bayer BGGR   # convert again, other Bayer order
```

`op10tool camframe` (tools/op10tool/src/camframe.rs): `caminfo`, `camframe`, polls until a new generation is ready,
then `camread G O` with 32 requests in flight and resends after 300 ms (823 parts per frame). PNG: RAW10 unpack, black
64, bilinear demosaic, grey-world white balance (gains 1..4), 99th percentile -> white, sRGB gamma. A test-pattern frame
(`bayer TPG`) is shown grey. Host tests: `scripts/laurel/cam-test.sh` (69 + 31 checks, C = Python tables),
`scripts/laurel/cam-frame-test.sh` (mock phone with 5 % loss: byte-equal frame, PNG).

### Test steps (owner approval for the boot partition write; root rebuild for the tables)

1. `scripts/laurel/camera-inventory.sh` (stock vendor image -> `out/laurel/camera/lib`), then the root with the tables:
   `scripts/bg.sh laurel-root sudo scripts/laurel/root.sh` (root-camera.sh runs in step 2) and flash userdata as usual.
2. `scripts/bg.sh cam-kernel scripts/laurel/kernel-linux.sh`, image (`scripts/laurel/uefi-image.sh`), flash with
   `scripts/laurel/flash-boot.sh` after the owner says yes.
3. USB log: the `LAUREL CAMERA: rear stream:` line about 2 s after the root mount; `sysctl kern.laurel_camera_stream`.
4. `scripts/laurel/cam-frame.sh`: look at the PNG. Wrong colours: `--raw ... --bayer BGGR|GRBG|GBRG`. Dark or white: the
   AE state is in `caminfo` (exposure lines, gain x1024).
5. Kill switch `camera=0` (step 1 and step 2).

### Open points

- [U] GPLL4/GPLL9 lock state at boot on this phone (the clock lines and the stream line show which path ran).
- [U] Bus vote for the VFE writes (see above). [U] CSID1 HW version (CORE_CTRL_1 is written only from 0x30000000).
- [I] Bayer order RGGB from the library enum; check on the first picture.
- The ext4 reader of branch t3/laurel-cellular-ipa2 (`laurel_ext4.c`, WIP, in a patch also numbered 2770: a number
  clash to fix at merge) could read the libraries straight from the vendor partition and drop the root step.

## 9. Steps 3 + 4: `/dev/negronicam` and the Camera app (patch 2772, 2903, plug-in, root step, ADT)

Status 2026-11-01: code, built, host tests pass. **Not run on the phone: every statement about the phone in this section is [I].**

### Why the app did not open (log `logs/usblog-20261101-001446.txt`, from 15:28:00)

[V] in the log:
- 15:30:57 tap at 264,860, then `exec Camera`. The same at 07:49:58. No `CRASH Camera` line in the whole log: the process runs and
  stays. No line with `|Camera|`, `IOK Camera`, `SWEET AKS: Camera`, or `NMTL[... Camera]`.
- No `cameracaptured` process and no line from it: iOS 16 has none, the capture servers are part of mediaserverd [V negroni].
- `mediaserverd` starts at 15:27:18; no line of it after the tap. No plug-in line (`negroni: camera`).
- `IOK SpringBoard: path IODeviceTree:/arm-io/isp -> none`, `.../product/camera -> none`. The ADT has no camera nodes.
- Kernel: `LAUREL CAMERA: on: ...; capture path: step 2`: this boot had only 2770 (chip IDs). No `rear stream` line, no `/dev/negronicam`.

[V] on the root: topaz `sweet-root-tweaks.py` line 120 sets `StartRecorderServer` false; the stock mediaserverd job has
`com.apple.coremedia.capturesource` + `capturesession` in MachServices, so launchd holds these names and nobody serves them.

Cause [I, strong: the same signs and the same root setting as negroni, whose stackshots show the chain, `docs/camera-ios-2026-10-27.md`
section 8]: `-[AVCaptureSession init]` in Camera sends its first XPC message to `com.apple.coremedia.capturesource` and waits for ever;
the main thread waits on the same `dispatch_once` in `didFinishLaunching`; so no window comes. Not a crash, and not the camera hardware.

### What had to change, chain from negroni, one line each

| Blocker on negroni | State on the Mi A3 |
| --- | --- |
| No capture servers (`StartRecorderServer` false) | plug-in starts them after its hooks, without the Metal shader preload (`media_hooks.c`) |
| No device vendor (no AppleH10CamIn) | hook 1 of the table; `scripts/laurel/camera-cache-check.sh` PASS on the 20H392 dmg: UUID 8F970452-..., 9 hooks, 57 OK lines; 126 imports OK |
| tccd: `Failed to issue Sandbox Extension` -> -11852 "not authorized" | topaz sandbox ops 5/6 gave ENOENT [V 0050]: patch 2903 (same file as branch t3/laurel-kernel-infra-ports, so a later merge is clean) |
| `DisplayPipePlaneBaseAlignment` number -> uncaught exception | patch 2002 + the plug-in's seed |
| Plane bytesPerRow 0 | patch 2001 |
| Preview in a Metal window server | Mi A3 backboardd is GL: `eagl.c` `surface_to_texture` copies each plane of a 420f surface into a texture [V source; I that CoreAnimation's GL path draws it, HakiOS's path]. No Metal in the plug-in or the ISP. The bundle does not depend on t3/laurel-metal-everywhere |
| No camera nodes in the ADT | `mkadt.py` `camera_nodes`: `/arm-io/isp` `camera-rear` = 1, `/product/camera`; `CAMERA=0` skips |

### Kernel (patch 2772; each file < 300 lines, kcheck OK)

| File | Content |
| --- | --- |
| `laurel_cam_dev.h` | pure, host-tested: NCFRAME1 layout, Bayer map, line time, 30 fps frame length, limits, gain code, ring of 3 buffers |
| `laurel_cam_dev.c` | cdev: open/close/read/write, node root:mobile 0660 |
| `laurel_cam_sess.c` | one session on the stream thread |
| changed | `laurel_cam_stream.c` (`lcam_stream_up/down` split out of `lcam_capture`), `laurel_cam_sensor.c` (`lcam_sensor_frame_exposure`: 0x0340 + 0x0202 + 0x0204 in one group hold), `laurel_cam_ctl.c` (node before the self-check, session loop) |

- The node comes after the tables and buffers, before the 2 s self-check, so mediaserverd sees it. A self-check without a frame removes
  it (`/dev/negronicam: off: ...`); the plug-in then refuses the device at once: Camera opens with no picture, no hang [I].
- A session: first read -> bring-up of 2771; last close or 3 s without a read -> all off (sensor power-down, CSI, VFE, clocks, GDSC). The
  camera has no power otherwise. `camframe` still works when no session runs. A fault (no frame for 1 s) answers EIO until reboot and
  touches nothing else. Kill switch `camera=0` (no node).
- Numbers [V library, **wrong: section 10**, the library's clock is not the real one: line 5333 ns, 240 fps]: line 5376 at 392 MHz = 13714 ns. Mode 6 is 780 lines = 93.5 fps, 10 ms maximum exposure. A session sets frame
  length 2431 lines = 30 fps, maximum 9724 lines (7.5 fps); the margin is 48 lines.
- Bayer: library filter 3 -> header 0 (RGGB) [I: enum]. Black 64 [I]. Android mount angle 90 for the rear [V camera_config.xml], so no half
  turn [I]; `/var/db/negronicam/turned` turns the picture if that is wrong.

**Delivery: read(), not mmap.** The ask was "mapped buffers". `mmap` of a character device gives ENODEV in this XNU [V `kern_mman.c:546`],
the NCFRAME1 client uses read(), and the buffers are Normal NC: a client that reads them in place reads uncached [I: slower than one
copy to cached memory]. read() copies from the kernel's mapped buffers; a buffer under copy does not go back to the VFE, so no torn frame.

**Front camera: not done.** The S5KGD1 tables do not parse: trailer data_type 2 (16-bit data) [V `camera-tables.py`: `table at 0x9f2c: trailer 2/2`],
and its 1280x720 entry says 5.2 fps. It also needs CSIPHY2/CSID2 in code that has CSIPHY1/CSID1 fixed. No `camera-front` in the ADT;
the SENSOR command answers ENODEV for others than 1.

### iOS side

- `userland/laurel/camera/build.sh`: native Linux build of `userland/camera` with `-DLAUREL_CAMERA` (no fork of the sources): theos clang +
  ld64 + MacOSX13.3 headers (+ one stub header, `sdk-stub/`) + text stubs + ldid. 163552 bytes, arm64, minos 16.0, sha256 74f50430...
  `LAUREL_CAMERA` changes: line prefix `LAUREL CAMERA: ios:`, IMX586 names, HEVC encoder registered also when the node comes later,
  8-bit bilinear preview (below).
- ISP: identity colour matrix (no Mi A3 tuning file), grey-world white balance, AE in `camera_isp.c`, all CPU, Metal-free.
- Preview [V host test, I on the phone]: the frame has 640x360 cells; 4:3 uses 480x360. The graph asked 1504x1128 on negroni. The float path
  per output pixel is too slow here, so the cells go through the colour pipe once, then 8-bit bilinear (`isp_render_cells`,
  `isp_scale_nv12`). Photo: 4032x3024 output from 960x720 pixels, so it is soft: the frame mode is 1280x720.
- `scripts/laurel/root-camera.sh` (root.sh, `CAMERA=0` skips): tables, plug-in in `/System/Library/Audio/Plug-Ins/HAL`, `/var/db/negronicam`,
  MobileGestalt cache out, check of the mediaserverd job. No entitlements in the bundle: mediaserverd (user mobile [V plist]) has its own; the
  app's TCC entitlement is stock. `StartRecorderServer` stays false.

### Build and host test [V]

- `scripts/bg.sh camapp-kernel scripts/laurel/kernel-linux.sh`: 259/259 patches, 0 LSE, no warning in the camera files, sha256 04a59dd9...
- `scripts/laurel/cam-test.sh`: all old checks + `cam3_test`: 2543 checks, 0 failed. Mock NCFRAME1 client with the plug-in's own header (layout
  compared at compile time) and ISP; each Bayer order; ring (never torn), limits, AE closes (green 141, target 144), green and blue bars
  right, 8-bit preview within 6 steps of the float one away from edges.
- `scripts/laurel/camera-cache-check.sh` PASS (section above). Only on a host: no XNU, no CMCapture, no real sensor ran.

### Expected lines (USB log; grep -a `LAUREL CAMERA`) [I]

```
LAUREL CAMERA: /dev/negronicam: on: rear IMX586 1280x720 RAW10, Bayer RGGB, black 64; open + read starts the camera, the last close stops it
LAUREL CAMERA: rear stream: 1280x720 RAW10 at 93.5 fps, frame 186 (kept for camframe), ...
LAUREL SANDBOX: privileges 1002/1007/12000 on, extension tokens on
LAUREL CAMERA: ios hooks: in mediaserverd (pid N), cache 20H392, slide 0x..., /dev/negronicam there
LAUREL CAMERA: ios hooks: ... replaced (k of 9)                                  (9 lines; "left alone" = report it)
LAUREL CAMERA: ios hooks: capture servers started (6 of 6, shader preload skipped): ...
-- open Camera --
LAUREL CAMERA: ios hooks: the camera's device vendor made (camera_device.c) (/dev/negronicam there)
LAUREL CAMERA: ios: the device made: one stream, the back camera (IMX586, /dev/negronicam)
LAUREL CAMERA: ios session: start (rear IMX586 1280x720, line 13714 ns, frame 2431 lines = 29 fps)
LAUREL CAMERA: ios: frames of 1280x720 from the kernel (the Back Camera)
LAUREL CAMERA: ios: stream: the graph starts the stream (format N)
LAUREL CAMERA: ios: PrimaryScaler: the first picture given (WxH 420f)
LAUREL CAMERA: ios session: 30 frames in N ms, ...
-- shutter --
LAUREL CAMERA: ios: StillImage: 4032x3024 made of every pixel in N ms
LAUREL CAMERA: ios: the photograph is given (1 so far)
LAUREL CAMERA: ios hooks: a photograph of 4032x3024 encoded in N ms
-- close Camera --
LAUREL CAMERA: rear stream: ios session: end (closed) after N frames, ...
```

How to read a stop: no `ios hooks:` line = the HAL did not load the bundle. `capture servers NOT started` = the reason is in the line.
`Failed to issue Sandbox Extension` or `-11852` = 2903 not in the kernel. `UNCAUGHT EXCEPTION` + `throw stack:` = report them. `ios session: no frame`
= CSID/VFE numbers in the line, section 8. Preview black with frames running = backboardd planar path: look for `redwood-gl: a new kind of texture`.

### Test steps (owner approval for each partition write)

1. `scripts/bg.sh cam-inv scripts/laurel/camera-inventory.sh` (only when `out/laurel/camera/lib` is empty), `scripts/bg.sh laurel-kernel scripts/laurel/kernel-linux.sh`,
   `userland/laurel/camera/build.sh`.
2. Root: `scripts/bg.sh laurel-root sudo scripts/laurel/root.sh`, flash userdata as usual. Boot image: `scripts/laurel/uefi-image.sh` (new kernel, new ADT), `scripts/laurel/flash-boot.sh`.
3. Open Camera. Compare the lines above. Expected result [I]: preview from the rear camera, shutter saves a photo.
4. Wrong colours: `scripts/laurel/cam-frame.sh` after the app closes (`camframe`), `--bayer`; `caminfo` shows the exposure. Upside down: `touch /var/db/negronicam/turned`, restart mediaserverd.
5. mediaserverd crash loop (audio goes too): `touch /var/db/negronicam/off` over the USB shell or `camera=0` plus a root without the plug-in (`CAMERA=0`).

### Open points [I]

- The whole iOS chain: Camera on GL only: an app part that needs Metal has only the gate's list (`NMTL ... not listed`): AegirPoster dies this way today, Camera did not get so far.
- Backboardd refill of 2.5 MB planes per frame through glTexImage2D (BGRA 11 MB took 120-145 ms, `eagl.c`): UI may drop while the camera runs. Next if so: BGRA preview for zero copy.
- CPU load of 30 fps ISP on this SoC; the 2 s self-check at each boot stays.
- Graph with a 16:9 sensor under a 4:3 format name: the format table stays the iPhone X names; the ISP crops.

## 10. Camera quality after the first working boot (patch 2773, plug-in, root step; 2026-11-01)

Owner, boot 18:40: "Camera is working but quite buggy and no proper focus or clarity." Log: `logs/laurel-boot-1840.txt` and `usblog-20261101-165828.txt`.
Status: code, built, host-tested. **Not run on the phone: every statement about the phone's behaviour with these changes is [I].**

### What the log shows [V] and the cause

| Sign in the log | Cause | Fix |
| --- | --- | --- |
| `rear stream: ... at 234.0 fps` where the table said 93.5; 370 frames in 10 s at frame 4862 | The library's `vt_pixel_clk` is not the clock. INCK / 0x0305 x 0x0306-7 / 0x0303 / 0x0301 x 8 over line x frame gives whole rates for all 7 modes: 15, 30, 60, 90, 120, 30, 240 fps [V host test, both libraries]. Mode 6 is the 240 fps mode. So line = 5333 ns, not 13714 ns: AE's "66 ms" was 26 ms and the session ran at 77 fps, not 30 | `lcam_mode_vt_hz` (`laurel_cam_mode.h`), checked by `cam4_test` |
| `low swap: killing largest compressed process with pid 28 (mediaserverd) and size 2689 MB` 18:43:56, pid 321 2485 MB 18:46:25; Camera drops, mediaserverd restarts | **Not in the plug-in's frame path, and not per frame: section "The memory of mediaserverd" below.** [I] CMCapture or Metal inside mediaserverd; the allocation is [U] | Later: Metal stays, memory guard (metal.md section 12); line `memory at frame N: footprint, malloc, by VM tag, Metal counts` |
| `Data/Stack execution not permitted ... mediaserverd[pid 403]`, pc = far = 0x1e9440158, 18:46:30 | [V] lr 0x101971560 = bundle base 0x101964000 + 0xd560: just after the `blr x8` of the PixelBufferHandler call in `deliver`. The block's invoke word was a data pointer. Why is [U]; it came 4 s after a low-swap kill | `handler_alive`: the block's class word is checked; a dead handler gives `off:` for this output, not a crash |
| `16 read over`, `70 read over` of 369 | A frame that ended while the reader copied was written over | 4 buffers, no frame lost to a copy (host test) |
| `mean 64`, `green 0 above black` at 4814 lines and gain 16x in every session, `digital 4.00x` | **Not explained [U].** The stock exposure writer does the same writes (`fill_exposure_array` disassembled: group hold, 0x0340, 0x0202, 0x0204, then digital gain): the registers are right. Rail GPIOs and tiles equal the DT [V]. The real exposure was 2.57x shorter, far less than the gap. Candidates: scene or lens covered (the log has no picture), VANA rail input [I] | Lines now say levels above black: mean, 1 % over, top. AE does not start from a dark self-check any more. Next boot tells: `top` near 0 at full exposure = no light on the sensor (rail or cover); `top` high = the mean is only a dark room |
| `frame 2: exposure 10.0 ms, gain 16.0x` at each session start | The session took the gain of the dark self-check | Start 16 ms x 2, or the last session's exposure |
| Exposure pinned, overshoot | The header said a new exposure at once, the sensor applies it 2 frames later [I]; AE waited for ever for a value the kernel clamped | The header follows the sensor (2 frames); AE waits at most 8 frames |
| `... found 0 (first word 0), expected 0x1a218a970; left alone` | [V] the method is in the cache (check-cache OK) but `class_getInstanceMethod` finds nothing at run time. A better log of a trap that did not happen. Harmless | One line: `is not found by name: the graph-stop log stays stock (not a fault)` |
| `no colour tuning for the imx586` | None was made | `scripts/laurel/camera-tuning.py` at the root step |
| `the first picture given (1504x1128)`: preview from 480x360 cells | Mode 6: 4:3 crop 960x720, 48 % of the sensor each way (2.1x zoom), magnified 3.1x | Section below |

| 19:08:11 `ios session: no frame for 1001 ms (CSID packets 62988 ... VFE ... status 0 0 ...)`, then EIO until reboot | [V] sensor and CSID still run, the VFE has no status bit. [I] the polled chain of RDI reg updates ended ("pseudo SOF": each is asked for when the last is seen). Why at that moment is [U]; it came with backboardd's first GPU frame | `lcam_vfe_kick` after 100 ms, receive path restart after 1 s, 3 times; only then the fault |

Stays unknown [U]: `stream: stop (0 frames, 0 pictures given)` 18:45:14 and 18:46:10 (a device was made and the graph stopped before it asked for streams: no error line); which of the above the owner meant by "buggy"; no shutter press in the log (no `StillImage` line), so the photo path has never run on this phone.
`set (not used)` left: ExposureBias, RegionOfInterestForCameraControls (no spot metering), TemporalNoiseReduction, FaceDetection. The `an output not here` lines (Raw, Depth, ...) are as expected. Flashlight: branch t3/laurel-torch-bl-fix.

### The memory of mediaserverd: the estimate of 4-5 MiB per frame is rejected

[V] numbers (`logs/usblog-20261101-165828.txt`):

| Time | Process, session | Frames | Memory |
| --- | --- | --- | --- |
| 18:41:10 | pid 28, no graph; Metal gate still closed (it opens 18:43:06) | 179 | footprint 15 MiB after it (NMTL line 18:43:47) |
| 18:43:47-56 | pid 28, graph + first pictures, Metal device 18:43:50 | 299 | 2689 MB compressed, killed |
| 18:43:58-44:08 | pid 321, 0 pictures given, Metal device 18:44:02 | 349 | not said |
| 18:46:19-25 | pid 321, pictures, 175 frames | 175 | 2485 MB compressed in all, killed |
| 19:34:56 | later boot, no graph, before the gate | 197 | no kill |

- 2689 / (179 + 299) = 5.6 and 2485 / (349 + 175) = 4.7 MiB look like the estimate. But the first 179 frames kept nothing [V], so a constant rate per frame does not fit: pid 28's second session alone is at least 9.0 MiB per frame read (14 from the first surfaces at 18:43:50, about 190 frames). 9 s from 15 MiB to 2.6 GB is about 300 MB/s.
- [V] Both kills come at about the same size, whatever the frame count (299 and 524 frames in those processes). Expected: "low swap" is a limit of the compressor. So the size says nothing about a per-frame rate. Growth could also be one large allocation at the start of the graph (for example shader or library work). The log cannot tell these apart [U].
- **Not IOSurfaces** [V]: the kernel logs only the first 64 surface creates of a boot (patch 0046), and that limit was reached at 18:43:56, so counting those lines says nothing (an earlier version of this section did that: wrong). The surface numbers in `SSDROP` lines go on: from 1038 to at most 1070 across the 175 frames of 18:46:19-26, for all processes. Under 0.2 surfaces a frame, about 83 MB at most. Also, the surfaces are memory of `kernel_task` (patch 2101), not compressed memory of mediaserverd.
- **Not the plug-in's frame path** [V host, mock]: `scripts/laurel/cam-leak-test.sh` runs the real `camera_device.c` + `camera_isp.c` over a mock of CoreFoundation, CoreVideo and `/dev/negronicam`, plain and with AddressSanitizer, on the current sources and on those of the phone at 18:40 (`OLD=9718fa2`; `userland/camera` last changed there 15:59): 600 frames without a graph: heap +0 bytes. 600 pictures with a graph that keeps 4 buffers: +2880 bytes in all (18:40 sources), objects +0, buffers +0, nothing left after the stop, no leak or use after free. **A mock is not CMCapture: this tests our retains and releases only.** Hooks: `emit_sample_buffer` and `gnr_render` allocate nothing [V source].
- Small true leaks found and fixed on the way, none near that size: `static __thread` buffers of the photograph path (about 1 MB per photograph when dispatch threads end), 12 KB of tuning per stream start, and my own `isp_finish_rows` buffer.
- What remains: the growth needs the graph and comes with Metal listed in each case in the log. Neither was ever off alone. The next boot decides: `memory at frame N: footprint F MB, malloc M MB; by VM tag: ...`. Flat = solved. Still growing with no `NMTL[n mediaserverd]` lines = not Metal, and the tag names the allocator.

### Modes

| Session mode | Table | Frame | Part of the sensor | Rate | Use |
| --- | --- | --- | --- | --- | --- |
| window | mode 2 + CCS window registers | 1920x1440, 3.46 MB | 96 % x 96 % | 30 fps (shortest frame 1722 lines = 45 fps) | preview |
| 1080 | mode 2 stock | 1920x1080 | 96 % x 72 % | 60 max | first fallback |
| 720 | mode 6 stock | 1280x720 | 64 % x 48 % | 240 max | last fallback ([V] it ran on the phone) |
| still | mode 1 stock | 4000x3000, 15 MB | all | 30 | photograph |

Not used: mode 0 (8000x6000): 60 MB a frame, CSID above 200 MHz (8 Gbit/s needs about 250 MHz by the mainline rule), and its remosaic wants the module's QSC data [I]; modes 3-5: more bandwidth for the same picture.
- Window: mode 2 line rate fits [V calc, host test]: 1920 x 10 / 4 lanes at 410 Mbit/s = 11.7 us < line 12.8 us. Registers are the standard CCS ones: Y start 0, Y end 5999, crop Y 30, height 1440, output 1440, frame 1722. **[I] The sensor takes this window: nothing tested it.** Self-check at boot: the frame's last line is written and the line after it is not (`lcam_tail_check`); no frames or another size falls to the next mode with the line `preview: mode N: off: ...`.
- Photograph: shutter -> `MODE 1`: stream off, path off, mode table, path on, exposure scaled by the line times, stream on, no power-down, the lens stays. The plug-in takes the second frame, at the zoom that shows the preview's framing, `MODE 0`. No frames in 1 s: `photograph mode: off: no frames: photographs from the preview frames`, session goes on. [U] the AXI bus at 460 MB/s while lines arrive (no bus vote in this kernel): `ios session: mode 3 after N frames, VFE errors E` tells.
- Buffers: 4 x 15.06 MB from the GPU pool (60 of 512 MiB, for good, at boot). No such room: `photograph mode: off: no 4 x N bytes in the GPU pool`, preview-size buffers.

### Focus [V library data, I on the phone]

DW9800W, 7-bit 0x0c on CCI M0, VAF gpio 123 (power list). `libactuator_dw9800.so` (sunny: `02=02 06=80 07=5e`, initial 381) or `libactuator_laurus_dw9800w_qtech.so` (qtech: `02=02 06=40 07=7a`, initial 150), chosen by the depth camera the scan found (camera_config.xml pairs them; this phone: OV02A10 = sunny [V log]). Position: register 3, 2 bytes, 10 bits. Range 48..960: the module's calibration is in its EEPROM (0x51, 8022 bytes) and is not read, so the search covers the whole stroke. The lens is set down in steps before power-off.
Plug-in: `af_frame` (HakiOS, contrast on the green block means, already there) gets the range from the frames. First sweep at frame 20, continuous watch after, tap = `AutoFocusNow` + `AFWindowParams`. Metadata: `AFStatus` 2 during a sweep and its fine search (CMCapture holds a photograph back while it lasts [V HakiOS comment on `_stillImageCaptureInProgressSubstate...`]), 1 while it climbs, 0 at rest; `AFLocked`. From the shutter to the end of the photograph the lens does not move. **[U] Whether AVFoundation's `isAdjustingFocus` follows AFStatus: not seen in the cache's method names; no KVO test here.**

### ISP

- Black 64 as before (the chromatix was not read for it [I]). Lens shading and colour matrices from the phone's own `libchromatix_laurus_imx586_{sunny,qtech}_{common,default_preview}.so`, file `camera-imx586-{sunny,qtech}.isp` in the bundle, made at the root step, never in git. Sunny: 3 shading sets (corners x3.3 to x4.3), 6 matrices with the colour temperature limits of the file. The order of matrices and shading sets by colour temperature is [I]. No file: a fixed middle matrix of that tuning, no shading. The grid spans the whole sensor: `lsc_u/v` keep it right on a frame that shows a part.
- White balance: grey world as before (no reference points parsed).
- Photograph: 5x5 Malvar-He-Cutler demosaic on lens-shaded raw (`camera_still.c`), chroma [1 2 1] each way (twice over 8x gain), luma sharpened with coring that grows with the gain.
- Preview: cells of the window (960x720) -> 8-bit bilinear -> luma sharpen, chroma only over 8x. CPU only (the camera's own ISP; the filter strip uses Metal in mediaserverd: metal.md section 12).

### Build and host test [V]

`scripts/laurel/kernel-linux.sh` (job camq-kernel): see `docs/notes.md`. `scripts/laurel/cam-test.sh`: + `cam4_test`: frame rates of all modes in both libraries, window numbers, motor data in both libraries, demosaic (flat grey in 4 orders, colour bars), shading on a part, finish, AE release, tuning file through the plug-in's loader. Only on a host: no sensor, XNU or CMCapture ran.
`scripts/laurel/cam-leak-test.sh` (tmux, about 2 min): the memory test above, plus the whole photograph and tap flow against a mock kernel: 3 photographs (mode out and back, lens still, 4032 wide), first sweep and tap end within 4 DAC steps of the sharpest (604 for 600), AFStatus 2 in the scan and 0 after.
`camera-inventory.sh` must run again: it now also takes the actuator and chromatix files. The patch: `scripts/laurel/camera-patch.sh BASE WORK`.

### Expected lines [I]

```
LAUREL CAMERA: focus: libactuator_dw9800.so: DW9800 at 0xc, init 3 writes, initial code 381, 481 steps
LAUREL CAMERA: sensor: session mode 0: table 2, 1920x1440, line 12800 ns at 420 MHz, shortest frame 1722 lines = 45 fps, 7680x5760 of the sensor
LAUREL CAMERA: sensor: session mode 3: table 1, 4000x3000, line 10840 ns at 828 MHz, shortest frame 3074 lines = 30 fps, 8000x6000 of the sensor
LAUREL CAMERA: rear stream: 1920x1440 RAW10 at 44.9 fps, frame N (kept for camframe), above black: mean M, 1% over B, top T; exposure ...
-- open Camera --
LAUREL CAMERA: ios session: start (rear IMX586 1920x1440, line 12800 ns, frame 2604 lines = 30 fps, photograph mode on)
LAUREL CAMERA: focus: on: DAC 48..960, at 381, control 0x2
LAUREL CAMERA: ios: the imx586's colour tuning from .../camera-imx586-sunny.isp: 1 colour matrices' lights, 1 lens shadings'
LAUREL CAMERA: ios: memory at frame 60: footprint N MB, malloc M MB; by VM tag: T n MB, ...      (again each 300 frames; must stay flat, about 100 MB [I])
LAUREL CAMERA: ios session: 30 frames in 1000 ms, 30 read, 1920x1440 exposure ...; above black: mean M, 1% over B, top T; VFE errors 0 (0)
LAUREL CAMERA: ios: focus: sweep: 48 0.0012 ...
LAUREL CAMERA: ios: focus: the lens at N after K moves (sharpness S)
-- shutter --
LAUREL CAMERA: ios: a photograph: the lens stays at N, the photograph mode asked for
LAUREL CAMERA: ios session: mode 0 after N frames, VFE errors 0 (0): to mode 3
LAUREL CAMERA: ios: StillImage: 4032x3024 made of every pixel in N ms
LAUREL CAMERA: ios: the photograph is given (1 so far, 4000x3000 frame, level x1.00)
LAUREL CAMERA: ios hooks: a photograph of 4032x3024 encoded in N ms
LAUREL CAMERA: ios session: mode 3 after 2 frames, VFE errors 0 (0): to mode 0
```

No `low swap: ... mediaserverd`. (`NMTL[n mediaserverd]` lines are expected since metal.md section 12.)
Bad signs: `focus: off: ...`; `preview: mode 0: off: ...` (the window failed); `photograph mode: off: ...`; `off: the graph's handler` (the old crash, stopped); `frames of 1280x720` (both 1920 modes failed); a crash at graph build with no Metal device (undo: below).

### Test steps (owner approval for each partition write)

1. `scripts/bg.sh cam-inv scripts/laurel/camera-inventory.sh` (new files), then the kernel, `userland/laurel/camera/build.sh`, and `scripts/laurel/gpu-userland.sh` (the gate).
2. **Root and boot image: both.** Root: new plug-in, tuning files, actuator libraries, gate (`sudo scripts/laurel/root.sh`, flash userdata). Boot image: new kernel (`uefi-image.sh`, `flash-boot.sh`).
3. Open Camera in a lit room, lens free. Compare the lines. Read `top` first.
4. Tap on near and far objects: `focus: sweep` lines, picture sharp. Shutter: a photo; open it in Photos.
5. Leave the preview on for 2 minutes: footprint flat, no `low swap`.
6. Undo for parts: Metal out of mediaserverd: write `* -backboardd -mediaserverd` in `/var/db/negronimetal/clients` as your own list (no gate mark in the first line). All: `camera=0`, or `CAMERA=0` root.

## 11. Crash loop without Metal, photo path, black frames (plug-in only; boot 20:02, 2026-11-01)

Owner: "Photos do not get taken, and the camera flashes in and out for a few seconds." Earlier: "quite bad quality". Log: `logs/laurel-boot-2002.txt` (main checkout).
Status: code, built, mock-tested. **Not run on the phone: every statement about the phone's behaviour with these changes is [I].** No kernel change: root (userdata) only.

### The crash: a node that needs Metal [V]

`scripts/debug/crash-symbolize.sh` (slide 0x20220000), 6 of 6 `CRASH mediaserverd` lines, one stack:

```
0x1c21672f0 CMCapture!-[BWMultiFilterThumbnailNode prepareForCurrentConfigurationToBecomeLive] + 296     far 0x8
0x1c2186230 CMCapture!___65-[BWGraph startDeferredNodePrepareIfNeededWithCompletionHandler:]_block_invoke + 300
            libdispatch ... _pthread_start
```

- Unslid 0x1a1f472ec `bl objc_msgSend$filterDescriptor` on ivar `_filter`, 0x1a1f472f0 `strb wzr, [x0, #0x8]`, no check. `_filter` is nil.
- `_filter` = `[FigColorCubeMetalFilter new]` (`_loadAndConfigureFilterBundle` 0x1a1fc2c08, `MetalFilter.bundle`; its result is ignored at 0x1a1f471fc). `init` -> `initWithCommandQueue:nil` (0x1f63afab8) -> `-[FigMetalContext initWithbundle:andOptionalCommandQueue:]` -> `commonInitWithOptionalCommandQueue:` 0x1c789c328: `+createMetalDevice` nil -> `cbz` 0x1c789c340 -> error -> nil.
- So this node, Camera.app's filter strip, needs Metal. `enableDeferredPrepareForNodesNotInPathOfSinkNode:` puts every node off the preview's path on a queue that runs after the first pictures: that is why each session gave pictures for about 1 s, then died. The app builds the session again: "flashes in and out". A shutter press never had a live session: no `a photograph` line in the boot.
- Exact match with the Metal list: boot 20:02 `clients "* -backboardd -mediaserverd"`: 6 of 6 crashes, this stack, `NMTL[n mediaserverd]: not listed` in each process. Boots 18:40, 19:07, 19:34 (Metal listed): 0 of this stack.
- [U] HakiOS also takes the Metal device out of mediaserverd (`inject_media.c`) and has no such hook. Why it did not crash there is not known.

### Decision: Metal stays out of mediaserverd; the node goes without it

**Replaced 2026-11-01 by the owner: mediaserverd has Metal.** metal.md section 12: clients `* -backboardd`, filters on the GPU, hooks 10 + 11 only with no device or past the memory guard's limit. The text below is the old reasoning; its evidence stays valid.

Metal facts [V]: boot 19:34, Metal listed: 236 `NMTL[n mediaserverd]: surface import refused: no-copy buffer` (metal.md row 4: no surface import in this process), footprint 16 MiB at 19:42:01 -> `low swap ... 2607 MB` at 19:42:09, 1.7 s after the shutter; the photograph had just passed the noise reduction, no `encoded` line. Boot 20:02, Metal out: 0 `low swap` lines (but sessions lasted at most 40 frames, so this is no proof of a flat footprint: no `memory at frame` line was reached, that line comes at frame 60). [I] the thumbnail filter is the user of those imports: it takes every preview frame.

Hooks 10 and 11 (`media_hooks.c`, guards as the others: address + first word, `check-cache.sh`):

| Method | No Metal device | Metal device |
| --- | --- | --- |
| `-[BWMultiFilterThumbnailNode prepareForCurrentConfigurationToBecomeLive]` 0x1a1f471c8 | `[super prepare...]` only, no filter made | stock |
| `-[BWMultiFilterThumbnailNode renderSampleBuffer:forInput:]` 0x1a208d600 | `_filter` nil: the stock method would emit a buffer nobody wrote. `camera_thumbs.c`: the picture in each place (output = width x height x filter count [V `didSelectFormat:forInput:`]), nearest sample, 420f/420v only, then `BWCMSampleBufferCreateCopyWithNewPixelBuffer` and `emitSampleBuffer:` | stock |

Result: filter strip shows the scene with no effect [I]. Other deferred nodes read in the cache: `BWGNRNode` prepare (`FigCapturePixelConverter`), `BWPhotoEncoderNode`, `BWStillImageCoordinatorNode`: no such unchecked filter object. [U] the rest of the deferred list has never run without Metal: a next crash will name the next node.

### Photo path

Shutter -> `FigCaptureStillImageSettings qualityPrioritization` (hook: speed, one frame) -> `StillImageCaptureNow` on the stream -> `stills_wanted` -> `MODE 1` -> second frame of 4000x3000 -> `deliver` on `StillImage` (the graph's pool, its handler) -> `BWStillImageCoordinatorNode` -> `gnr_render` (hook) -> `BWPhotoEncoderNode` (VCPHEVC software HEIC, hook) -> Camera.app, Photos.

- [V boot 19:34, old build, 1280x720 frames] `a photograph asked for`, `StillImage: 4032x3024`, `the photograph is given`, `goes past the noise reduction`. So the handler, pool and objects CMCapture needs do come from the real graph up to the GNR node. Never seen: `encoded`, a saved file, and all of this on the 2773 mode switch.
- **File size [V code]: the file is 4032x3024.** The graph's format and pool are the iPhone X names; the sensor frame is 4000x3000, scaled 1.008x by `isp_render_still_nv12`. Changing the format name risks the plist match: not done.
- Bug fixed: `deliver` was void, and a picture that found no buffer in the pool was counted as given (`stills_wanted--`, line `the photograph is given`). The graph then waited for ever. Now: tried again on the next frames, after 8 tries one line with what is missing, and the preview comes back.
- Time: render + finish 226 ms on one host thread, flat frame [V]; on the phone [I] about 1 s (no measurement). Under the kernel's 3 s rule. Mock (`cam5_dark.h`): pool refuses 10 asks, the photograph comes at the third try, mode out and back, lens still.

### Is the picture real? No light in any frame so far

All values of boot 20:02 [V], above black, 10-bit (white 959):

| Time | Exposure | Gain | Mean | Top |
| --- | --- | --- | --- | --- |
| 20:02:59 self-check | 1674 lines = 21 ms | 16x | 0 | 7 |
| 20:03:13 | 2556 lines = 33 ms | 6.8x | 0 | 3 |
| 20:15:13 | 10368 lines = 133 ms | 16x | 0 | 10 |
| 20:17:27 | 10368 lines = 133 ms | 16x | 0 | 9 |

Older boots: `mean 64` (= black) at every session, since the first frame.

- `1% over 8` means nothing: it was the middle of the lowest 16-step bin. Fixed in the plug-in's lines (1-step bins under 32). The kernel's line still reads 8 for a black frame.
- Sharpness flat, and why [V calc + host test]: sharpness = steps of block means / mean squared. Noise cut off at black: `4 x 0.34 / 32 / 0.4^2 = 0.27`, almost whatever the noise's size and wherever the lens is. Log: 0.2795 to 0.2891 (one 0.2031 first). `cam6_test` repeats the old measure on such noise: sigma 1, 2, 4, 8 = 0.335, 0.282, 0.268, 0.262; sigma 2 gives green 0.8 and 0.28, as the log's `green 0-1` and 0.28. So the sweep measured noise only, with nothing in it about the lens: **the frame has no picture.**
- Noise rises with gain (top 3 at 6.8x, 7-10 at 16x): the sensor's read-out runs [I].
- Judgement: 133 ms x 16x would clip a lit room. Top 10 of 959 is no light on the pixels. **Cause [U]: I cannot tell from here:** (a) lens covered or a dark scene (the boot self-check at 20:02:59 may be the phone on a table; the sessions at 20:14-20:17 were in the owner's hands, scene unknown); (b) the pixels get no supply: VANA (gpio 15, equal to the DT [V]). Register tables are not the cause: qtech = sunny in modes 1, 2 and 6 [V this boot's diff], digital gains 1x, stock exposure writer the same [V section 10]. The owner's "bad quality" fits a noise picture, or a real picture in another scene; no picture file exists.
- The torch was not on in these sessions [V]: `dark: off` 20:17:13, session 20:17:15.

The next boot decides, one test: lit room, lens free, phone in the hand. New line `picture: no light on the sensor` with those numbers = (b), then read VANA and the sensor analog registers; no such line and `top` high = the scene was dark, and then the rest of the picture work applies. `scripts/laurel/cam-frame.sh` after the app closes gives the raw frame as a PNG.

### AF scale

- Noise term out of the measure: half the mean square of the difference of a cell's two greens is the noise's variance S; S / 8 is noise's share of the steps. Host [V]: noise only: 0.26-0.34 -> 0.0000 at each sigma; a real edge at noise sigma 6: 0.02852 sharp, 0.00231 soft (ratio 12).
- Window under 4 steps above black: no scan, lens stays, AFStatus 0 (no photograph held back), line `focus: waits:`. A tap in the dark is done when light comes.
- A sweep with sharpest under 1.15 x least sharp: lens back to its start, line `focus: the sweep is flat`. It used to end at the first place measured.

### Build and tests [V]

`userland/laurel/camera/build.sh`, `scripts/laurel/cam-test.sh`, `scripts/laurel/cam-leak-test.sh` (+ `cam5_dark.h`, `cam6_test.c`), `scripts/laurel/camera-cache-check.sh` (11 hooks; `check-cache.sh` now also looks in Metal), `scripts/laurel/kernel-linux.sh`: numbers in `docs/notes.md`. A mock is not CMCapture: the hooks' objc paths were compiled and checked against the cache, not run.

### Expected lines [I]

```
LAUREL CAMERA: ios hooks: -[BWMultiFilterThumbnailNode prepareForCurrentConfigurationToBecomeLive] replaced (10 of 11)
LAUREL CAMERA: ios hooks: -[BWMultiFilterThumbnailNode renderSampleBuffer:forInput:] replaced (11 of 11)
-- open Camera --
LAUREL CAMERA: ios hooks: no Metal device in this process: the filter thumbnails go unfiltered, through the CPU
LAUREL CAMERA: ios: memory at frame 60: footprint N MB, malloc M MB; by VM tag: ...       (must stay flat; the first time this line is reached without Metal)
LAUREL CAMERA: ios: picture: no light on the sensor: exposure E ms, gain G, green M above black, 1% over B, top T: ...   (only without light)
LAUREL CAMERA: ios: focus: waits: green M above black in the window is noise ...           (only without light)
LAUREL CAMERA: ios: focus: sweep: 48 0.0012 (green 140)                                    (in light)
-- shutter --
LAUREL CAMERA: ios: stream: a photograph asked for StillImageCaptureNow = ...
LAUREL CAMERA: ios: a photograph: the lens stays at N, the photograph mode asked for
LAUREL CAMERA: ios session: mode 0 after N frames, VFE errors 0 (0): to mode 3
LAUREL CAMERA: ios: StillImage: 4032x3024 made of every pixel in N ms
LAUREL CAMERA: ios: the photograph is given (1 so far, 4000x3000 frame, level x1.00)
LAUREL CAMERA: ios hooks: a photograph goes past the noise reduction, which has nothing to do it with here
LAUREL CAMERA: ios hooks: a photograph of 4032x3024 encoded in N ms
```

No `CRASH mediaserverd`, no `low swap`, no `ios session: end (closed) after 10 frames`.
Bad signs: `left alone` on hooks 10, 11; a new `CRASH mediaserverd` (symbolize it: the next node); `filter thumbnails: off`; `a photograph NOT given`; `photograph mode: off`; no `encoded` line within about 30 s of the shutter (the encoder has never finished on this phone).

### Test steps (owner approval for each partition write)

1. `userland/laurel/camera/build.sh`, `sudo scripts/laurel/root.sh`, flash userdata. No boot image needed for this change.
2. Lit room, lens free. Open Camera: preview stays. Read `top` and the `picture:` line first.
3. Shutter, open the photo in Photos. Keep the preview on for 2 minutes: footprint flat.

## 12. Why the IMX586 stream shows no light: review and self-check (patch 2784, plug-in; 2026-11-01)

Problem [V `logs/laurel-boot-2002.txt`]: 133 ms, 16x, `above black: mean 0, 1% over 8, top 9-10`. Status: code, built, host-tested. **Not run on the phone.**

**Result: no fault in the code explains the dark frames. The cause stays unknown [U].** One real difference from stock was found and fixed (L12A mode); I have no evidence that it is the cause. The next boot separates the candidates: the lines below.

### What was checked, with evidence

| Point | Evidence | Result |
| --- | --- | --- |
| Rear power list | `camera-sensors.py` on all 3 libraries (`out/laurel/camera/sensors.txt`) = `lcam_rear_up` in `laurel_cam_core.h` = order in DT `eeprom0` (laurel dtsi 34-52); raw entries at `.data` 0x5e08 | [V] same steps, same delays. IMX586 qtech = sunny = IMX582: no difference by module |
| VANA | [V] GPIO step only: TLMM 15 (`qcom,gpio-vana`, DT lines 15, 162). The DT's `cam_vana-supply` L3P (2.8 V) is PM8008, disabled in `trinket.dtsi` 3039-3045, and no library step uses it. So VANA comes from a switched regulator outside the DT. | **Input and voltage of that regulator: [U]**: no schematic, no DT node |
| VDIG, VIO, VAF | [V] TLMM 14, 49, 123. VREG step = `cam_vio-supply` = L12A 1.8 V, the only PMIC rail of the list | Equal to the code. [V] QRD uses gpio 49 for PM8008 enable; on laurel it is CAM_VIO |
| The pins | [V] `pinctrl-trinket.c`: 14, 15 WEST; 48, 49 SOUTH; 123 EAST = `lcam_tile`. Control word: OE bit 9, out bit 1 of the io word. [V] gpio 14/15 are QUP SE3: `qupv3_se3` is disabled in the DT, our BT is on 10-13 | No clash found |
| **L12A load** | [V] Stock: `regulator_set_load(80000)` before enable (laurel `cam-vreg-op-mode`), over this rail's `hpm-min-load` 10 mA, gives RPM `lsmd` 7 (`pmic5-ldo`, `rpm-smd-regulator.c`). We sent only `uv` and `swen` | **The one difference. Fixed.** [U] what L12A feeds and whether it matters |
| Delays, MCLK | [V] the same list. MCLK: [V] fps 45.4 at 1722 lines and 234 at 780 lines match the PLL registers of a 24 MHz INCK | MCLK right |
| Tables | [V] qtech = sunny in init, modes 1, 2, 6 (`.data` diff: only mode 0 gets 6 more writes, PDAF data, a stock clock field). [V] no table writes 0x0100, 0x0104, 0x0600, 0x0601 (`cam7_test`). [V] the other stock settings: start = 0x0100 1, stop = 0x0100 0, hold = 0x0104 | Nothing is missing from the write path. The init line counts 239 bursts of the init table only; the mode table has its own |
| Writes applied | [V] `write_table` stops at a NACK (`CCI write ... failed`): none in the log. [V] the registers work: fps, frame length (10416 lines at 7.9 fps) and gain (noise grows) follow. [U] every value: no read-back before this patch | Self-check: `table read-back` |
| Exposure, gain | [V] stock `sensor_fill_exposure_array` (library `.text`): 0x0340, 0x0202, gain, digital 0x020e-0x0215, 0x3100 only for long exposures. Gain code clamp 0x3c0 = ours at 16x. Margin 48 = `vert_offset` | Same registers. 10368 + 48 = 10416: the frame holds the exposure |
| Black level | [V] library color level info `.data` 0x6050: white 1023, pedestals 64, 64, 64, 64 (`cam7_test`) | 64 was [I], now [V] |
| Test pattern on | [V] no table writes it; [I] the noise grows with the gain, a pattern has no noise | No. Read-back shows it |
| RAW10, stride | [V] `lcam_raw10_px` and the plug-in's `cell`, `isp_raw_measure` read MIPI RAW10. [V] the size check passes. [I, strong] a wrong shift or stride cannot give mean 64 with top 74 in every frame: all bytes are near 16. A wrong unpack makes values vary, it does not flatten them | Not the unpack [I]. Colour bars prove it [next boot] |
| Mean in the plug-in | [V] `cell` takes off `f->black`, cuts at 0; the kernel's own mean agrees (`mean 64`, 2 code paths) | Right. `1% over 8` in the kernel was a 16-step bin: fixed |
| Library choice | [V] the kernel takes the qtech file first, the phone has a sunny depth camera; the used tables are equal | No effect. The qtech test pattern table holds another sensor's 0x5e00/0x4320; only sunny's 0x0600/0x0601 is real |

Size of the gap [I, calculation]: 1.6 um binned, f/1.79, a 1 lux room gives about 30 electrons in 133 ms, about 20 steps at 16x. Mean 0 is under about 0.05 lux at the scene. Noise at top 9-10 is a normal read-out noise at 16x, so the ADC and PGA run. A dark scene means a covered lens: **a phone on a USB cable, screen up, lens on the table, fits every line of every log [I].** The torch was never on with frames running: 19:41:24 `dark` comes as the session starts, 20:17:13 before it.

Open causes [U], in order: (a) lens on a table or covered; (b) VANA does not reach the pixels: input of the switched regulator, or a broken module; (c) a table value that did not stick.

### The self-check (kernel `laurel_cam_light.c`, pure part `laurel_cam_light.h`; plug-in `isp_raw_measure`)

It changes nothing that the frames need. A failed read gives a line and the frames go on. The colour bars are 150 ms of the boot self-check, once a boot, and the kept frame stays a real one.

Expected lines [I]. At the boot, 2 s after the root:

```
LAUREL CAMERA: sensor: table read-back: 616 writes, N the same, M differ, 0 reads failed, T ms: 0x.... wrote .. read ..
LAUREL CAMERA: sensor: test pattern: colour bars in memory: columns of the 4 Bayer places 0xcc 0xf0 0xf0 0xaa, levels L..H, Bayer RGGB as the library says: sensor -> MIPI -> VFE -> buffer -> RAW10 reading is right
LAUREL CAMERA: rails (boot): RESET 48 ctl 0x200 out 1 in 1, VIO 49 ctl 0x200 out 1 in 1, VANA 15 ctl 0x200 out 1 in 1, VDIG 14 ctl 0x200 out 1 in 1, VAF 123 ctl 0x200 out 1 in 1
LAUREL CAMERA: rails (boot): L12A: enable 0x80, 1800 mV, mode 7 (7 high power), status 0x..; PM6125 LDOs on (bit n = Ln): 0x...
LAUREL CAMERA: sensor: read back (boot): stream 1 hold 0 frame count N, exposure 1674 gain code 0x300 digital 0x100, frame 1722 line 5376 shift 0
LAUREL CAMERA: sensor: read back (boot): lines 0..5999 out 1920x1440 binning 0x44 mode 0x22 format 0xa0a lanes 3 test pattern 0 pedestal 64 temperature T; 0 reads failed
LAUREL CAMERA: raw (boot): 1920x1440, 184320 samples: min A max B mean M (black 64); top 3 bits n0 n1 ... n7
LAUREL CAMERA: raw (boot): Bayer places x10 ...; bytes of the 5-byte group b0 b1 b2 b3 b4; no signal: ... | signal: ...
```

Each session: the rails, read back and raw lines at frame 6, the raw line each 150 frames (5 s at 30 fps), plus from the plug-in, from the bytes it got:

```
LAUREL CAMERA: ios: raw as read: frame 6, 1920x1440 stride 2400, N samples: min A max B mean M (black 64); top 3 bits ...; bytes of the group ...
```

`spmi errors ... torch 0 camera 0, forced 0`: the new user. `rail: the RPM refused the L12A mode vote` only on a refusal. `temperature`, `pedestal`, the `mode 7` and the bars' levels are [I]: first read ever. Some table registers may read back differently by nature; a list that names many is not a fault by itself: read its addresses.

### How to read the next boot

| Lines | Means | Next |
| --- | --- | --- |
| `NO BARS` | Path or reading wrong (or the sensor took no pattern: then `test pattern 0` and a noise frame) | Look at `raw` bytes and places; the path, not the pixels |
| Bars right, `signal:` in a lit room | The sensor was fine, the scene was dark | Picture work (section 10) goes on |
| Bars right, `no signal` in a lit room, lens free, `raw` the same with a torch on a near white wall | The array gives nothing | Read `rails`: VANA `in 0` = pad not driven; L12A not on or `mode` not 7; `table read-back` list. All clean: the switched regulator's input or the module: [U] from here; a stock boot of this phone settles it |
| `raw (session)` and `raw as read` differ | read() path | `laurel_cam_dev.c`, the ring |

### Build and test [V]

`scripts/laurel/cam-test.sh` + `tools/laurel-cam-test/cam7_test.c`: black noise = `no signal`, lit = `signal`, one byte off shows in the group's bytes, constant frame named, kernel numbers = plug-in numbers, all 4 Bayer orders found from bars, noise, flat frames and a wrong stride are not good bars, `1% over` real on black, stock data above. The patch: `scripts/laurel/camera-patch.sh BASE WORK 2784-laurel-camera-light`. Build numbers: `docs/notes.md`.

### Test steps (owner approval for each partition write)

1. **Boot image and root, both:** kernel: `scripts/laurel/uefi-image.sh`, `flash-boot.sh`. Plug-in: `userland/laurel/camera/build.sh`, `sudo scripts/laurel/root.sh`, flash userdata.
2. First the boot lines (they do not need a scene: bars, read-back, rails).
3. Hold the phone. Lens free, point it at a window or a lamp. Open Camera. 15 s (3 `raw` lines).
4. Cover the lens with a finger 10 s, free it 10 s.
5. Turn the flashlight on in the Camera app and hold the phone 10 cm from a white wall, 10 s.
6. Report: `grep -a -E 'raw \(|raw as read|rails \(|read back|table read-back|test pattern' <log>`.
7. Undo: `camera=0` is the kill switch for all of it.
