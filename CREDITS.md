# Credits and Upstream Attribution

**iOSPlus10** is built on the shoulders of giants. Booting and running Darwin/XNU and iOS userland on modern Qualcomm Snapdragon hardware (specifically the OnePlus 10 Pro 5G / SM8450 "negroni") is made possible by years of reverse engineering, firmware development, kernel porting, and graphics driver innovation across the open-source community.

We express our deepest gratitude to the following developers, research teams, and upstream projects.

---

## 1. Direct Build Submodules & Core Negroni Stack

These repositories form the operational core of the iOSPlus10 build pipeline:

| Project | Original Authors / Upstream | Role in iOSPlus10 | License |
|---|---|---|---|
| [**slop**](https://github.com/MellysInformejtik/slop) | [MellysInformejtik](https://github.com/MellysInformejtik) (forked to [akshaynexus/slop](https://github.com/akshaynexus/slop)) | Negroni device baseline: 125+ XNU-8796 kernel patches, device shim, `mkadt.py`, `adt.py`, `mkdarwinboot.py`, rootfs construction scripts, and UEFI patching tools. | BSD-2-Clause-Patent / APSL 2.0 / MIT |
| [**UniXNU**](https://github.com/UniXNU/UniXNU) | [UniXNU contributors](https://github.com/UniXNU) (forked to [akshaynexus/UniXNU](https://github.com/akshaynexus/UniXNU)) | Unified Darwin UEFI bootloader package (`UniXNUPkg`), boot manager, and hardware interface kits (`NativeAdreno`, `NativeMetal`, `AirNir`, `NativeUfs`, `NativeRamBlock`). | BSD-2-Clause-Patent |
| [**DarwinBoot**](https://github.com/UniXNU/DarwinBoot) | [UniXNU contributors](https://github.com/UniXNU) (forked to [akshaynexus/DarwinBoot](https://github.com/akshaynexus/DarwinBoot)) | Core UEFI driver that boots Darwin/XNU kernels on ARM64 platforms. | BSD-2-Clause-Patent |
| [**Mu-Silicium-negroni**](https://github.com/pawlickerr/Mu-Silicium-negroni) | [pawlickerr](https://github.com/pawlickerr) & [Project Silicium](https://github.com/Project-Silicium) (forked to [akshaynexus/Mu-Silicum-negroni](https://github.com/akshaynexus/Mu-Silicum-negroni)) | TianoCore / Microsoft Project Mu UEFI firmware tree adapted for OnePlus 10 Pro (`negroniPkg`), including ACPI tables (`Silicium-ACPI`) and core UEFI runtime (`mu_basecore`). | BSD-2-Clause / Microsoft Project Mu / EDK II |
| [**hackios-xnu-userland**](https://github.com/oosexgang/hackios-xnu-userland) | [OOSEX GANG](https://github.com/oosexgang) | HackiOS userland patches, launchd job layout, preference templates, and Mesa/EAGL userspace integration. | MIT |
| [**ios-flame**](https://github.com/NWylynko/ios-flame) | [NWylynko](https://github.com/NWylynko) & [dipa-studio](https://github.com/dipa-studio) | Pixel 4 (SM8150) port: ADT MAC address fix, AMFI policy / IOService stand-ins, kernel command server, and userland root tools. | MIT |
| [**metal2vulkan**](https://github.com/steelbrain/metal2vulkan) | [steelbrain](https://github.com/steelbrain) | Metal shading language / API translation to Vulkan. | GPL-2.0-or-later OR LGPL-3.0-or-later |

---

## 2. Foundational Lineage & Port Pioneers

Every modern XNU-on-Android project owes its lineage to a succession of breakthrough community ports:

- **[ios-sweet](https://github.com/dipa-studio/ios-sweet)** by [dipa-studio](https://github.com/dipa-studio):  
  The pioneering port of modern XNU and iOS 16 userland to Qualcomm hardware (Redmi Note 10 Pro / SM7150). Established the foundational kernel shims, DeviceTree generation (`mkadt`), and IPSW rootfs extraction techniques that the entire ecosystem builds upon.

- **[ios-sailfish](https://github.com/joranv1/ios-sailfish)** by [joranv1](https://github.com/joranv1):  
  The first port (Google Pixel 1 / MSM8996) to achieve **working hardware-accelerated graphics** via Mesa freedreno and the EAGL shim (`sweetgl`). Also contributed pivotal ~20-second fast boot optimizations (IOAcceleratorES, IORTC quiescence, and launchd pruning).

- **[Chlorophyll](https://github.com/ry-diffusion/Chlorophyll)** by [ry-diffusion](https://github.com/ry-diffusion):  
  Pioneering implementation of an open-source Metal driver stack: AIR (Apple Intermediate Representation) -> NIR -> ir3 compiler pipeline targeting Adreno GPUs over Mesa freedreno.

- **[UniXNU-negroni](https://github.com/pawlickerr/UniXNU-negroni)** by [pawlickerr](https://github.com/pawlickerr):  
  Initial device port and board definition bringing UniXNU and DarwinBoot to the OnePlus 10 Pro 5G.

- **[UniXNU-pong](https://github.com/Chengdong-Yu/UniXNU-pong)** by [Chengdong Yu](https://github.com/Chengdong-Yu):  
  Nothing Phone 2 (SM8475, Adreno 730) port; critical reference for SM8450/SM8475 Adreno 730 bring-up, on-demand launchd job management, and IORTC timing adjustments.

- **[UniXNU-ios26](https://github.com/none24smu/UniXNU)** & **[UniXNU-zeta](https://github.com/none24smu/UniXNU-zeta)** by [none24smu](https://github.com/none24smu):  
  Trailblazing research on modern XNU versions (xnu-12377 / iOS 26), ARMv8.3 PAC handling, shared-cache layout, and kernel watchdog policies.

- **[bergamota](https://github.com/ry-diffusion/bergamota)** by [ry-diffusion](https://github.com/ry-diffusion):  
  POCO F1 port targeting iOS 18 (xnu-11215); provided key references for USB Ethernet networking (`tools/ssh`), log utilities, and modern Apple toolchain workflows.

- **[hackios-xnu-kernel](https://github.com/oosexgang/hackios-xnu-kernel)** by [OOSEX GANG](https://github.com/oosexgang):  
  POCO X5 Pro (SM7325) kernel development, in-kernel APFS mounting, and AKS (AppleKeyStore) key wrapping/unwrapping.

- **[ios-apollo](https://github.com/aTechGeekDev/ios-apollo)** by [aTechGeekDev](https://github.com/aTechGeekDev):  
  Mi 10T 5G (SM8250) port; contributed hypervisor-safe MMIO accessors and staged GPU bring-up sequencing.

- **[ios-s9](https://github.com/syncmodz/ios-s9)** by [syncmodz](https://github.com/syncmodz):  
  Samsung Galaxy S9 (SM-G9600) port; driver and kernel adaptations for Qualcomm Snapdragon 845.

- **[ios-spes](https://github.com/AdyaGMD/ios-spes)** by [AdyaGMD](https://github.com/AdyaGMD):  
  Redmi Note 11 (SM6225) port reference.

---

## 3. Graphics, Compilers, & System Software

- **[Mesa 3D Graphics Library](https://mesa3d.org/) & [freedreno](https://gitlab.freedesktop.org/mesa/mesa)**:  
  Rob Clark and the Mesa community for the open-source Gallium freedreno OpenGL driver and Turnip Vulkan driver that power accelerated graphics on Qualcomm Adreno GPUs.

- **[Project Mu](https://microsoft.github.io/mu/) & [TianoCore EDK II](https://www.tianocore.org/)**:  
  Microsoft and the TianoCore open-source community for the modern, modular UEFI framework that underpins Mu-Silicium.

- **[Project Silicium](https://github.com/Project-Silicium)**:  
  For UEFI porting and ACPI definitions across modern Qualcomm Snapdragon platforms.

- **[blacktop/ipsw](https://github.com/blacktop/ipsw) & [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build)**:  
  Tooling for unpacking Apple IPSWs and building vanilla Darwin/XNU kernels on modern host operating systems.

---

## 4. Base Operating Systems and Hardware Vendors

- **[Apple Inc.](https://opensource.apple.com/)**:  
  Source releases of the XNU kernel, libpthread, IOHIDFamily, and Apple filesystem components under the Apple Public Source License (APSL 2.0).  
  *Note: iOS, Darwin userland binaries, firmware, and related assets are proprietary to Apple Inc. and are obtained directly from Apple restore images (IPSW) by the end user during the build process.*

- **Qualcomm Technologies, Inc. & OnePlus / OPlus**:  
  Open-source Linux kernel device tree definitions, CAF/CLO kernel releases, and hardware documentation for the Snapdragon 8 Gen 1 (SM8450) and OnePlus 10 Pro (NE2211/NE2213/NE2215).

---

## Notice & Licensing

For verbatim license texts, copyright notices, and disclaimers for the code and submodules utilized by this repository, please refer to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
