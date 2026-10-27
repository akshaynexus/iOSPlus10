# GPU / Metal comparison with other iOS-on-Android ports (2026-10-27)

Method: README + tree grep of each `external/*` and `out/src/hackios-next`, `git log -1`, 15 unauthenticated GitHub API calls.
[V] = seen in README or code in this checkout. [claimed] = README/issue text, not reproduced. [unverified] = not checked.
No project here was run by us. Some UniXNU `drivers/NativeMetal` and `kits/*` dirs are empty submodules in our checkout, so UniXNU's GPU code is [unverified] beyond its README.

## Table

| Project | Device / SoC | GPU | Kernel GPU driver | Userland GPU layer | What works | Last commit | Licence (API) / stars |
|---|---|---|---|---|---|---|---|
| **iOSPlus10 (ours)** | OnePlus 10 Pro, SM8450 | Adreno 730 | own RedwoodGPU (KGSL-like, GMU, IFPC, 0384 governor + completion IRQ), patches 0230-0234+ | NegroniMetal plug-in over metal2vulkan + Turnip (ios-flame lineage); GL path NegroniGL | [V, our docs] WebGL works; widgets partly (FitnessWidget killed by 30 MiB jetsam limit; Music/Sleep/Safari widget crashes are not Metal); some Metal clients crash; AegirPoster "unsupported extended range format" | 2026-10-27 | private |
| ios-flame | Pixel 4, SM8150 | Adreno 640 | in-kernel (sweet GPU driver, `xnu/patches`) | Metal -> metal2vulkan -> Turnip (`sweetmtl=2`), `phone/metal2`, `phone/turnip` | [V README] SpringBoard, apps, Settings, Safari "rendered through Metal", 20-26 fps swipes; [claimed] same. Not working: video playback, HEIC/HEVC, Metal widgets (CPU path), audio | 2026-10-22 | MIT / 11 stars |
| metal2vulkan | (library, host + device) | any Vulkan | n/a | Rust: AIR reader, Metal API on Vulkan (compute, render, tessellation, tile, mesh) | [V README] translator + runtime + validation crates | 2026-10-26 | GPL-2+ or LGPL-3+ / 295 |
| Chlorophyll (Bergamota Metal driver) | Poco F1, SM845 | Adreno 630 | Bergamota kernel, libdrm stand-in | AIR -> NIR -> freedreno ir3, Metal classes over Mesa 25.0.7 Gallium (`air/air_metal.c`, `src/bgmtl.m`) | [V results/] spikes run on the Adreno 630 incl. "all system metallibs" and CoreAnimation fragment classes; no end-to-end claim seen | 2026-10-24 | NOASSERTION / 5 |
| Bergamota | Poco F1, SM845 (iOS 18.7.8) | Adreno 630 | `gpu/freedreno-sweet` | `gpu/eagl` (GLES on freedreno), `gpu/metal` (Chlorophyll) | [V README] SpringBoard boots with **CPU rendering, "no GPU yet"**; GPU = work in progress | 2026-10-24 | none / 64 |
| hackios-xnu-kernel (HackiOS) | POCO X5 Pro, SM6375 (kernel + QEMU) | Adreno 642L | `hakios.*` driver, `gpu=1`, RedwoodGPU service | Mesa 25.0.7 freedreno on Darwin, GLES -> CoreAnimation via EAGL bridge | [V README] SpringBoard on the Adreno via GLES, apps, Safari, widgets (Weather, Calendar), Wi-Fi; Metal "in progress": 293 of 456 system shaders run (`docs/air.md`) | 2026-10-23 | NOASSERTION / 1765 |
| hackios-xnu-userland | same | same | same | `userland/src` inject libs, `tools/mk-mesa.sh`, `tools/air/`, `tools/metal/` | [V] AIR analysis tools, EAGL bridge | 2026-10-22 | none / 391 |
| out/src/hackios-next | same (newer tree) | Adreno 642L | `gpu=1` | GLES via Mesa | [V README] "GPU rendering on Adreno" yes; "Metal: there is a shader compiler, no Metal" | 2026-10-26 | NOASSERTION |
| ios-sailfish | Pixel 1, SM821 | Adreno 530 | own driver (power, SMMU, CP, zap via TZ, BOs, submit) | Mesa freedreno GLES 3.1 in backboardd as `sweetgl.dylib` (EAGL) | [V README] GPU compositing up to 60 Hz, 20-40 fps. **No Metal**; Metal apps do not work | 2026-10-22 | none / 84 |
| ios-spes | Redmi Note 11, SM6225 | Adreno 610 | patches 0107+ (GPLL0 clock, fences), HackiOS RedwoodGPU design | Mesa freedreno + HackiOS EAGL bridge | [V README] UI runs on the GPU (GLES). Metal: [unverified] | 2026-10-25 | none / 2 |
| ios-apollo | Mi 10T, SM8250 | Adreno 650 | staged bring-up 0096+ (`sweetgpu=1..22`) | planned Mesa freedreno + CA bridge | [V README] phase 2: GMU/3D core; CPU rendering otherwise | 2026-10-24 | MIT / 6 |
| ios-sweet / -upstream | Redmi Note 10 Pro, SM7150 | Adreno 618 | none | none, CPU 20-30 fps | [V README] "No GPU" | 2026-10-23 | MIT / 1101 |
| ios-s9 | Galaxy S9, SDM845 | Adreno 630 | none | none, CPU | [V README] "No GPU" | 2026-10-24 | MIT / 5 |
| slop | (our fork of ios-sweet, negroni) | Adreno 730 | our GPU patches (feed our kernel) | n/a | [V] README is the sweet copy; real GPU facts in our NOTES | 2026-10-26 | n/a |
| UniXNU (+ ios26 branch) | Xiaomi Pad 6S Pro (sheng, SM8650) | Adreno 740 | `drivers/NativeAdreno`, kits `AdrenoFirmware`, `AdrenoPM4` | `NativeMetal` driver, kit `AirNir` (AIR -> NIR), PM4 direct [unverified: submodules empty] | [claimed README news] "native Metal GPU driver fully working", render server composites through the Adreno 740, per-process Metal devices | 2026-10-25 / 10-22 | NOASSERTION / 0 |
| UniXNU-pong | Nothing Phone (2), SM8475 | Adreno 730 | `drivers/PongAdreno` | `PongMetal` + `NativeMetal` | [claimed] table says "Adreno 730 / Metal: hardware acceleration works"; same README says "not confirmed complete". [V] logs of PM4 submit/Metal discovery are quoted, not in tree. Same SoC family as ours | 2026-10-23 | NOASSERTION / 1 |
| UniXNU-zeta | Surface Duo 2, SM8350 (iOS 26.5.2) | Adreno 660 | no GPU mention in README/board.toml [V] | none found | boots target only | 2026-10-24 | NOASSERTION / 3 |
| UniXNU-negroni | OnePlus 10 Pro (our device, upstream attempt) | Adreno 730 | none | none | [V README] "without GPU acceleration" | 2026-10-22 | none / 2 |
| Mu-Silicium-negroni | UEFI | n/a | n/a | n/a | boot firmware only | 2026-10-25 | n/a |

## Honest ranking (GPU / Metal acceleration)

1. **ios-flame** (Pixel 4). Only project with documented, screenshot-backed Metal for SpringBoard and ordinary apps on Turnip. Same stack as ours, older SoC (A640, much simpler than A730 GMU/IFPC). Weak spots: no video, Metal widgets on CPU path.
2. **UniXNU / sheng** [claimed]. Strongest claim (Metal composites the UI, per-process devices on A740), custom AIR->NIR->PM4 path rather than Vulkan. Cannot verify: submodules empty here, no screenshots or code read.
3. **Ours (A730)**. Same architecture as ios-flame, on a harder GPU, with a real kernel driver (GMU, IFPC, governor, completion IRQ, per-client VA) and a documented crash-triage process. Metal is on for all clients with WebGL working. Below flame because widgets and several Metal clients crash and AegirPoster fails on an extended-range format. Ahead of the rest on SoC difficulty and on proof of kernel power management.
4. **UniXNU-pong** (A730) [claimed, contradictory README]. Closest hardware to ours; worth a code read.
5. **HackiOS** (A642L). Best GL path: GPU-composited SpringBoard, widgets, Safari; Metal only 293/456 system shaders.
6. **ios-sailfish, ios-spes**. GLES only, no Metal; Metal apps fail.
7. **Chlorophyll / Bergamota**. Metal translator with strong shader-coverage data but SpringBoard still CPU-rendered.
8. **ios-apollo** (bring-up), then **ios-sweet, ios-s9, UniXNU-negroni, UniXNU-zeta**: CPU only.

## Worth taking

- **UniXNU-pong `drivers/PongAdreno`, `drivers/PongMetal`**: same SM8475/A730 family. Compare its GMU/power and Adreno 730 firmware load against `patches/xnu` 0230-0234 and the 0384 governor. Also `proprietary-files.txt`. (Check licence first, NOASSERTION.)
- **UniXNU `kits/AdrenoPM4`, `kits/AirNir`, `drivers/NativeAdreno`** (init submodules read-only to read): alternative to Turnip for a fixed A7xx command stream; useful if Turnip memory cost (15-20 MiB, see widgets doc) blocks 30 MiB widgets.
- **Chlorophyll `results/all-system-metallibs-summary.*`, `ca-fragment-classes.tsv`, `docs/FIXES.md`**: system-metallib coverage lists; diff against metal2vulkan failures (AegirPoster extended-range format) and use for a regression corpus.
- **hackios-xnu-userland `docs/air.md`, `tools/air/`, `tools/metal/`** and **hackios-xnu-kernel `docs/`**: lists of which of the 456 system shaders fail and why (`air.md`, `metal.md`).
- **ios-flame `METAL-NEXT.md`, `phone/metal2/`, `phone/turnip/`, `tools/build-turnip-ios.sh`, `tools/build-m2v-bridge.sh`**: upstream of our plug-in. Check for flame fixes after our fork (last commit 2026-10-22) and for the Today-view widget CPU fallback, which would avoid the jetsam kill of Metal widgets.
- **ios-sailfish / ios-spes EAGL bridge (`tools/eagl-attach-gpu.patch`, `sweetgl.dylib`)**: mature GLES-on-freedreno fallback for processes where Metal is memory-bound (widgets). Matches our NegroniGL path.
- **metal2vulkan upstream** (steelbrain, 295 stars, pushed 2026-10-26): rebase point for patches 0001-0003; check CHANGELOG for fixes to `from_metallib` copying the whole metallib (widget memory).

Unverified: all "works" claims for UniXNU family and pong; Chlorophyll end-to-end; ios-spes Metal; any performance number other than README quotes.
