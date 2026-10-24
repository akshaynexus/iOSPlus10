# Camera support research and plan

Status: research only. No camera hardware has been powered or probed from iOS. The owner asked for a native XNU port for iOS 16.7.16 (20H392, D22AP) on NE2211 / SM8450. The phone remains untouched.

## Findings

### Camera hardware

OnePlus's product specification identifies the rear main camera as Sony IMX789 with OIS, the ultra-wide as Samsung JN1, and the telephoto as 8 MP with OIS. Independent device reviews identify the telephoto as OmniVision OV08A10 and the front sensor as Sony IMX615. The commercial spec is not enough to map sensor index to CCI/CSIPHY. [OnePlus specifications](https://www.oneplus.com/us/10-pro/specs), [OnePlus India](https://www.oneplus.in/10-pro), [Android Central review](https://www.androidcentral.com/smartphones/oneplus/oneplus-10-pro-review), [NE2211 DT source: `out/live.dts`]

The checked-in `out/live.dts` has four `qcom,cam-sensor*` nodes under the camera CCI buses. The nodes identify cell indices and CSIPHY indices, but not silicon model names, I2C addresses, lane counts, detailed lane assignments, or camera module IDs. Do not infer those from index ordering. Decode the stock `dtbo.img` and vendor camera module configuration before writing sensor probe tables. [V: `out/live.dts:22144-22578`]

The base live DT exposes CCI0 at `0xac15000` and CCI1 at `0xac16000`. Each has master 0 and 1 pinctrl groups. Four CCI timing profiles are present. Camera MCLK/reset pinctrl states are also present. The sensor nodes report `csiphy-sd-index` values 1, 2, 5, and 0. These are downstream subdevice indices, not by themselves physical lane counts. [V: `out/live.dts:4995-6206,22044-22578`]

The DT exposes actuator, EEPROM, OIS, flash, sensor, and regulator nodes/supplies, including OIS names LC898128 and LC898124. Their associations vary by sensor slot. The live DTS has regulators via phandles, not resolved human-readable rail names in the sensor block; resolve phandles and regulator nodes from the DTB/DTBO plus camera module binaries before power sequencing. [V: `out/live.dts:22130-22578`]

The NE2211 camera CSI receive and ISP blocks are Qualcomm downstream camera hardware. The kernel camera memory region is reserved at `0x9f500000` size `0x800000`; a DT property declares `qcom,vmid-cp-camera-preview-ro`, suggesting a protected preview buffer path. That property alone does not prove that all camera operation requires TrustZone. [V: `out/live.dts:184-188,13481`]

SM8450 is marketed with Spectra image processing, but Qualcomm public docs describe the downstream camera stack as Camera Core Driver, and the upstream stack as CamSS. Qualcomm's camera guide says downstream camera is not enabled by default in its Linux distribution and requires overlay setup. The proprietary Android stack is CAMX plus `cam_kernel`/camera core and sensor modules; it uses vendor-specific calibration/tuning and firmware. Identify exact firmware names and files from the offline vendor image before deciding if `CAMERA_ICP.elf` is present. It was not found by searching the available text artifacts in this checkout. [Qualcomm camera overview](https://docs.qualcomm.com/bundle/publicresource/topics/80-80021-17/camera-overview.html), [V: local `~/op10-backup/images` inventory]

Upstream Linux does not currently expose an SM8450 CAMSS binding/driver variant in the mainline tree examined; the published upstream CAMSS binding in the recent tree is for SM8550, a later platform. Treat Linux as a register and architecture reference, not as a ready-made SM8450 driver. Check the exact kernel revision before implementation because upstream status changes. [Upstream binding](https://linux.googlesource.com/linux/kernel/git/torvalds/linux/+/refs/heads/master/Documentation/devicetree/bindings/media/qcom,sm8550-camss.yaml), [SM8450 DT](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/qcom/sm8450.dtsi)

No NE2211-specific camera implementation was found in the searched reference ports. `external/hackios-xnu-kernel/xnu/files/bsd/dev/redwood_camera.c` is a POCO X5 Pro / SM6375 implementation. Its test pattern and I2C-first bring-up ladder are useful examples only; sensor names, rails, GPIOs, addresses, clocking and ISP register programming are not transferable. [V: file header and sensor table in that source]

### iOS capture path

`AVCaptureDevice` represents hardware or virtual capture devices and feeds `AVCaptureSession`. On macOS, CoreMediaIO DAL plug-ins and newer CMIO extensions can provide custom cameras. Apple's documentation scopes those extension APIs to macOS; it does not document a supported third-party DAL/CMIO camera plug-in mechanism for iOS. Therefore a macOS virtual camera approach is not a practical iOS route. [Apple `AVCaptureDevice`](https://developer.apple.com/documentation/avfoundation/avcapturedevice), [Apple Core Media I/O](https://developer.apple.com/documentation/coremediaio)

On iOS, the stock camera path is private and device-identity-specific. D22AP is an A11/iPhone X identity, so the expected Apple stack is the A11-era AppleH10CamIn/ISP integration, with `mediaserverd` coordinating capture and camera-specific services such as `cameracaptured` / `appleh13camerad` varying by OS and hardware generation. This service list is a hypothesis until verified against the supplied 20H392 root and launchd plists. The needed kernel/user interface is not just a generic camera class: expect AppleCamIn matching, IOUserClient/memory-buffer semantics, ISP firmware and tuning formats. [I: based on iOS camera architecture and the requested iOS image; inspect `~/op10-apple/ios16-root.img` read-only before implementation]

A fake AppleCamIn provider that supplies buffers from a separate capture path is the only plausible route to Apple's built-in camera apps, but compatibility would require matching private IORegistry properties, user client selectors, buffer formats, timing, metadata and camera HAL assumptions. This is research-grade reverse engineering. A direct app that reads a custom XNU character device can show frames in a purpose-built app, but standard AVFoundation apps will not discover that device automatically. [I]

### Staged implementation plan

| Stage | Work and exit condition | Estimate | Assessment |
|---|---|---:|---|
| 0. Offline inventory | Decode stock DTBO/vendor images and vendor camera configuration. Resolve all four modules, CCI addresses, lanes, regulators, GPIOs, clocks, OIS/actuator/EEPROM and firmware filenames. No phone access. | 1–3 days | Realistic; required before writes |
| 1. Sensor power + CCI | Add guarded XNU diagnostic driver for one sensor: acquire only documented rails/clocks/GPIOs, issue a read-only chip-ID transaction, log and power down. First target the simplest fixed-focus module after mapping. Exit: repeatable ID read with all rail states restored. | 1–3 weeks | Realistic, moderate risk; XNU lacks existing Qualcomm CCI and regulator frameworks for this board |
| 2. CSI-2 receive | First drive CSID/IFE test pattern to DMA memory; then sensor RAW10 stream through CSIPHY/CSID to RDI buffer. Verify frame sequence and Bayer data on host. Bypass IFE processing if raw RDI is available. If the hardware requires ICP firmware/session, load and start it from the vendor image. | 3–8 weeks | Research-grade; registers, clocks, SMMU/IOMMU setup and firmware trust are major unknowns |
| 3. Image conversion | Convert RAW10/Bayer to RGB on CPU for low-resolution preview; later test Adreno compute only after existing GPU bring-up. Validate colors, stride, crop and frame rate. | 1–2 weeks CPU; 2–6 weeks GPU | CPU demo realistic at small sizes; full-resolution real-time CPU is unlikely. GPU route depends on current incomplete Adreno stack |
| 4. iOS capture integration | Prove custom frame delivery in an in-house app first. Then inspect 20H392 camera daemons, AppleH10CamIn kext/driver matching, user clients, and mappings in the iPhone X IPSW. Prototype an AppleH10CamIn-compatible service and expose a single camera. | 1–3 months+ | Research-grade; no public iOS camera plug-in interface identified |
| 5. Still/video | Add exposure/white-balance/focus controls, timestamps, front/rear switching, metadata and media writer integration after stable streaming. | 1–3 months beyond stage 4 | Still capture may be achievable before video; AVFoundation/Camera.app integration remains gated by stage 4 |

Avoid simultaneous sensor bring-up. Start with one rear module and basic RAW frames. Defer OIS, autofocus, flash, multi-camera, HDR, HEIC, stabilization and vendor image tuning until the simple path works.

### Main risks

- SM8450 camera subsystem access may be mediated by secure-world services or memory ownership. The DT's camera VMID hint makes this a concrete investigation, not a confirmed blanket restriction.
- `CAMERA_ICP.elf` or other DSP firmware may be signed, authenticated, or loaded through Qualcomm secure boot APIs unavailable to this XNU environment.
- CAMX sensor modules and IQ tuning are proprietary and tuned per module/lens; a raw Bayer stream can work without them, but polished auto exposure, color, noise reduction, HDR and video modes will not.
- A11/D22AP's private camera driver path may reject an emulated SM8450 device, require matching Apple camera firmware, or assume Apple ISP output structures. A simple UVC-like device is not a supported substitute on iOS.
- Sensor names and DT lane topology remain unverified against stock overlay/module files. Guessing a lane map or rail order risks a nonfunctional probe or hardware damage; stage 0 must precede power-on.

## Recommended first step

Create a reproducible offline inventory script that extracts stock DTBO overlays and vendor camera configuration into `out/`, then records a per-slot table with module name, CCI master/address, CSI lanes/PHY, rails, clocks, GPIOs, EEPROM, actuator and OIS. Resolve sensor identity from the actual NE2211 vendor files, not from general OnePlus 10 Pro specifications. Once reviewed, stage 1 can add a read-only chip-ID probe for one module.

## Sources / evidence limits

- Local observations are labeled [V] and point to checkout files.
- Web facts link to primary vendor or upstream sources where available.
- Camera daemon sequence and iOS AppleH10CamIn compatibility are marked [I] pending inspection of the local 20H392 root and device kexts.
- `external/hackios-xnu-kernel` camera code is for redwood / POCO X5 Pro only and is not NE2211 evidence.
