# Third-Party Notices and Licenses

This repository, **iOSPlus10**, incorporates, links against, or builds with components from open-source projects governed by their respective licenses. This document collects verbatim copyright notices, licenses, and disclaimers for third-party software and submodules utilized across the project.

---

## Summary of Components

| Component / Submodule | Primary Copyright Holder(s) | License |
|---|---|---|
| `external/UniXNU` & `external/slop/unixnu-negroni` | UniXNU contributors | BSD-2-Clause-Patent |
| `external/UniXNU/drivers/DarwinBoot` | UniXNU contributors | BSD-2-Clause-Patent |
| `external/Mu-Silicium-negroni` & submodules | Andrei Warkentin, Project Silicium, Microsoft Corp., ARM Ltd., Intel Corp., Apple Inc., Linux Foundation | BSD-2-Clause / Project Mu / EDK II |
| `external/hackios-xnu-userland` | OOSEX GANG | MIT |
| HakiOS userland (hackios-next; parts in `userland/negronigl/`) | the HakiOS authors | MIT |
| `external/ios-flame` | NWylynko, dipa-studio | MIT |
| `external/metal2vulkan` | steelbrain | GPL-2.0-or-later OR LGPL-3.0-or-later |
| `external/ios-sweet` & `external/ios-sweet-upstream` | dipa-studio | MIT |
| `external/Chlorophyll` & `userland/metal/probes` | ry-diffusion / Chlorophyll authors | MIT |
| `external/ios-apollo` | aTechGeekDev, dipa-studio | MIT |
| `external/ios-s9` | syncmodz, dipa-studio | MIT |
| `external/hackios-xnu-kernel` & XNU patches | Apple Inc. | Apple Public Source License (APSL) 2.0 |
| `userland/negronigl/` (Mesa integration / freedreno) | Mesa contributors, Rob Clark | MIT |
| Linux kernel drivers (ath11k / Qualcomm) | Qualcomm Technologies Inc., Linux Foundation | BSD-3-Clause-Clear |
| seemoo-lab/owl (port in `patches/xnu/0347-negroni-awdl.patch`: `bsd/dev/negroni_awdl_owl.{c,h}`) | The Open Wireless Link Project, Milan Stute | GPL-3.0-or-later |
| Qualcomm WALT / OPLUS frame_boost (logic port in `patches/xnu/0395-negroni-cpuperf.patch`: `bsd/dev/negroni_cpuperf.c`) | The Linux Foundation, Intel Corporation, Oplus | GPL-2.0-only |
| KGSL msm_adreno_tz GPU governor (logic port in `patches/xnu/0389-negroni-gpu-frame-pace.patch`: `bsd/dev/negroni_adreno.c` tz_start/tz_want) | The Linux Foundation, Qualcomm Innovation Center | GPL-2.0-only |

---

## 1. BSD-2-Clause-Patent

Used by **UniXNU**, **DarwinBoot**, **UniXNU-negroni**, **UniXNU-pong**, **UniXNU-zeta**, and **slop**:

```text
Copyright (c) 2026, UniXNU contributors. All rights reserved.

SPDX-License-Identifier: BSD-2-Clause-Patent

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

Subject to the terms and conditions of this license, each copyright holder
and contributor hereby grants to those receiving rights under this license
a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable
(except for failure to satisfy the conditions of this license) patent
license to make, have made, use, offer to sell, sell, import, and otherwise
transfer this software, where such license applies only to those patent
claims, already acquired or hereafter acquired, licensable by such copyright
holder or contributor that are necessarily infringed by:

(a) their Contribution(s) (the licensed copyrights of copyright holders and
    non-copyrightable additions of contributors, in source or binary form)
    alone; or

(b) combination of their Contribution(s) with the work of authorship to
    which such Contribution(s) was added by such copyright holder or
    contributor, if, at the time the Contribution is added, such addition
    causes such combination to be necessarily infringed. The patent license
    shall not apply to any other combinations which include the
    Contribution.

Except as expressly stated above, no rights or licenses from any copyright
holder or contributor is granted under this license, whether expressly, by
implication, estoppel or otherwise.

DISCLAIMER

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

---

## 2. Project Mu / EDK II (BSD-2-Clause)

Used by **Mu-Silicium-negroni** and nested submodules (`mu_basecore`, `Silicium-ACPI`, `mu_plus`):

```text
Copyright (c) Andrei Warkentin. All rights reserved.
Copyright (c) Apple Inc. All rights reserved.
Copyright (c) ARM Limited. All rights reserved.
Copyright (c) Bingxing Wang. All rights reserved.
Copyright (c) DuoWoA authors. All rights reserved.
Copyright (c) Intel Corporation. All rights reserved.
Copyright (c) Linaro Limited. All rights reserved.
Copyright (c) Microsoft Corporation. All rights reserved.
Copyright (c) Samuel Tulach. All rights reserved.
Copyright (c) The Android Open Source Project. All rights reserved.
Copyright (c) The Linux Foundation. All rights reserved.
Copyright (c) Travis Geiselbrecht. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

* Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in
  the documentation and/or other materials provided with the
  distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

---

## 3. MIT License

Used by **hackios-xnu-userland**, **ios-sweet**, **ios-flame**, **Chlorophyll**, **ios-apollo**, **ios-s9**, and **op10tool**:

### A. hackios-xnu-userland (OOSEX GANG)
```text
MIT License

Copyright (c) 2026 OOSEX GANG

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### B. ios-sweet / dipa-studio & derivatives
```text
MIT License

Copyright (c) 2026 dipa-studio

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### C. Chlorophyll (ry-diffusion)
```text
MIT License

Copyright (c) 2026 the Chlorophyll authors (ry-diffusion/Chlorophyll)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### D. HakiOS userland (hackios-next, reference tree out/src/hackios-next)
Used in `userland/negronigl/shaders.c` (the two full-precision `#define` lines) and `userland/negronigl/surface.c`
(texel-size table, plane-copy idea). Only the userland part (`userland/src/`) is MIT; its kernel part is APSL 2.0.
```text
MIT License

Copyright (c) 2025-2026 the HakiOS authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 4. GNU LGPL v3.0 / GPL v2.0 (metal2vulkan)

`external/metal2vulkan` is dual-licensed under GPL-2.0-or-later OR LGPL-3.0-or-later:

```text
metal2vulkan is dual-licensed. You can redistribute it and/or modify it
under the terms of either of these two licenses, at your choice:

  * the GNU General Public License as published by the Free Software
    Foundation, either version 2 of the License, or (at your option) any
    later version; or

  * the GNU Lesser General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your
    option) any later version.

SPDX-License-Identifier: GPL-2.0-or-later OR LGPL-3.0-or-later
```
Complete license texts for GNU General Public License v2.0 and GNU Lesser General Public License v3.0 are maintained in `external/metal2vulkan/LICENSE-GPL-2.0` and `external/metal2vulkan/LICENSE-LGPL-3.0`.

---

## 5. Apple Public Source License (APSL) Version 2.0

Used for Apple open-source components including **XNU** (kernel), **IOHIDFamily**, **libpthread**, and **hfs**:

```text
APPLE PUBLIC SOURCE LICENSE
Version 2.0 - August 6, 2003

Please read this License carefully before downloading this software.  By
downloading or using this software, you are agreeing to be bound by the
terms of this License.  If you do not or cannot agree to the terms of
this License, please do not download or use the software.

1. General; Definitions.  This License applies to any program or other
work which Apple Computer, Inc. ("Apple") makes publicly available and
which contains a notice placed by Apple identifying such program or work
as "Original Code" and stating that it is subject to the terms of this
Apple Public Source License version 2.0 ("License").  As used in this
License:
...
Full terms available at: https://opensource.apple.com/apsl/
```

---

## 6. Mesa 3D & Freedreno (MIT License)

Used for userland OpenGL ES / Vulkan graphics translation (`userland/negronigl` and Mesa drivers):

```text
Copyright (C) 1999-2007  Brian Paul   All Rights Reserved.
Copyright (C) 2012-2026  Rob Clark <robclark@freedesktop.org>
Copyright (C) 2018-2026  Google LLC

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 7. The Clear BSD License (BSD-3-Clause-Clear)

Used for Qualcomm hardware drivers (such as `ath11k` wireless driver components adapted from Linux):

```text
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
Copyright (c) The Linux Foundation. All rights reserved.

The Clear BSD License

Redistribution and use in source and binary forms, with or without modification, are permitted (subject to the
limitations in the disclaimer below) provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the
   following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
   following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote
   products derived from this software without specific prior written permission.

NO EXPRESS OR IMPLIED LICENSES TO ANY PARTY'S PATENT RIGHTS ARE GRANTED BY THIS LICENSE. THIS SOFTWARE IS
PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT
NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## 8. GNU GPL v3.0 (OWL, AWDL engine)

`patches/xnu/0347-negroni-awdl.patch` adds `bsd/dev/negroni_awdl_owl.c` and `bsd/dev/negroni_awdl_owl.h`, a kernel port of
OWL (https://github.com/seemoo-lab/owl, commit `0ee3263f944ea721c355f826aa90d636d012a512`; reference repo in
`external/owl`, pinned in `scripts/setup/get-references.sh`).

```
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2018  The Open Wireless Link Project
Copyright (C) 2018  Milan Stute
```

The complete GNU General Public License v3.0 text is in `LICENSES/GPL-3.0.txt` (copied from OWL's `COPYING`).
A kernel built with patch 0347 contains this GPL-3.0 code; the kill switch `negroniawdl=0` turns it off at run time
but does not remove it from the binary.

---

## 9. GNU GPL v2.0 (WALT / OPLUS CPU policy, patch 0395)

`patches/xnu/0395-negroni-cpuperf.patch` adds `bsd/dev/negroni_cpuperf.c`, a re-written port of the CPU frequency and
placement policy of the Android kernel of this phone: Qualcomm WALT (`kernel/sched/walt/walt.c`, `cpufreq_walt.c`,
`input-boost.c`, `boost.c` of OnePlusOSS/android_kernel_oneplus_sm8450 commit `e9da5922d6d1925fa7cc3062b65d92fa2812c3aa`)
and the OPLUS frame boost (`vendor/oplus/kernel/cpu/sched/frame_boost/` of
OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450 commit `835109f6cf48dbae09b68ef072bfecbf48e15064`).
Fetch: `scripts/setup/fetch-cpuperf-sources.sh`.

```
SPDX-License-Identifier: GPL-2.0-only
Copyright (c) 2012-2021, The Linux Foundation. All rights reserved.
Copyright (C) 2016, Intel Corporation
Copyright (C) 2020 Oplus. All rights reserved.
```

The complete GNU General Public License v2.0 text is in `LICENSES/GPL-2.0.txt` (copied from `external/metal2vulkan/LICENSE-GPL-2.0`).
A kernel built with patch 0395 contains this code; the kill switch `negronicpuperf=0` turns it off at run time but does not
remove it from the binary.

---

## 10. GNU GPL v2.0 (KGSL msm_adreno_tz GPU governor, patch 0389)

`patches/xnu/0389-negroni-gpu-frame-pace.patch` adds to `bsd/dev/negroni_adreno.c` a port of the GPU governor of the
Android kernel of this phone: `drivers/gpu/msm/governor_msm_adreno_tz.c` (tz_start, tz_init, tz_get_target_freq,
tz_suspend), `kgsl_pwrscale.c` and the DCVS calls of `drivers/firmware/qcom_scm.c` of OnePlusOSS/android_kernel_oneplus_sm8450
commit `e9da5922d6d1925fa7cc3062b65d92fa2812c3aa`. Fetch: `scripts/setup/fetch-gpu-governor-sources.sh`.

```
SPDX-License-Identifier: GPL-2.0-only
Copyright (c) 2010-2021, The Linux Foundation. All rights reserved.
Copyright (c) 2022 Qualcomm Innovation Center, Inc. All rights reserved.
```

The complete GNU General Public License v2.0 text is in `LICENSES/GPL-2.0.txt`. A kernel built with patch 0389 contains
this code; the kill switch `negronigpu_tz=0` turns it off at run time but does not remove it from the binary.
