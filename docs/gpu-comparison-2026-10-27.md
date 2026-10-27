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

## Speed comparison (2026-10-27, speed research agent)

Scope: frame rate and the cost per frame, not features. Method: read the trees in `external/*` and `out/src/hackios-next`.
For UniXNU (sheng) we shallow-cloned NativeMetal ce5e19e, NativeAdreno 5c8c145 and NativeMobileDisplay 33e941a (deleted
after the read), and read unixnu.com/drivers/adreno740. Nothing was run. [V] = seen in code, a log or a results file.
[claimed] = README or commit text only. [I] = our inference.

**Correction to the table above:** UniXNU (sheng) and UniXNU-pong do NOT use a direct AIR->NIR->PM4 path at run time.
[V] unixnu.com/drivers/adreno740: "runtime compiler chain is Metal, AIR, SPIR-V, NIR, IR3. AirNir is an offline direct AIR
to NIR to IR3 compiler"; AirNir README: "The runtime uses metal2vulkan and Turnip". PongMetal README:3 = "fork of Sheng's
NativeMetal frontend and object bridge over metal2vulkan and Turnip". So sheng, pong, ios-flame and we use the same
layers. Our stack is a descendant of theirs (flame METAL-NEXT.md section 3). A "port UniXNU's direct PM4 path" option
does not exist.

### Our baseline [V]

- `fbstat-report.py logs/usblog-20261027-171256.txt --from 21:13:10 --to 21:40:00`: 951 active seconds, presents/s mean
  14.2 (90 % of seconds in 10-19), gpu-wait skips 119 % of presents, GMU busy 12 % at 220-317 MHz (694 s) and 26.6 % at
  730-818 MHz (223 s, presents/s 18.6). Copy avg 249 us (the panel copy is not the limit). Best seconds 96-101 presents/s.
- Busy UI (main session numbers): ~27 presents/s at 818 MHz, GMU busy 12-26 %, 77 % of presents miss the tick, backboardd
  70-80 % CPU.
- backboardd Metal telemetry (notes.md:602-603, README-gpu-kernel.md:906-908): commit-to-complete mean 15.6 ms (n 9368),
  38 % over 16.7 ms, 7 render passes and ~6.2 M pixels (2.2 screens of 1125x2436) per command buffer. Older row: 8.1 Mpx,
  22.9 MB of host imports invalidated per command buffer (`hostinv`, notes:812-813).
- A GPU that is 12-26 % busy while 77 % of frames are late means the frame time is mostly NOT GPU shader time [I]: it is
  CPU encode/translation in backboardd, serial waits, and copies.

### Table

| Project | Layers CA -> GPU ring per frame | Display path | Measured fps / frame time | Key speed tricks |
|---|---|---|---|---|
| **Ours** (A730) | CA Metal -> NegroniMetal frontend (ObjC) -> Rust bridge -> metal2vulkan runtime f6a96b7d -> Turnip 25.0.7 (msm ABI emulation `negroni_drm.c`) -> RedwoodGPU ioctl | IOSurface -> GPU 2D copy into double-buffered panel memory (0231/0269), multi-layer CPU/GPU compose (0398); zero-copy 0234 exists, default off, never tested | [V] 14.2 presents/s mean in the 21:13-21:40 window; ~27/s at 818 MHz; best 96-101/s; ctc 15.6 ms | persistent pipeline cache `/var/db/negronimetal/cache`, fence IRQ, TZ DCVS + pace floor + input boost (0389), WC GPU pool 1.5 GiB (0401) |
| ios-flame (A640) | same as ours (sweetmtl=2) | IOSurface -> **kernel GPU blit** into panel memory, present not waited (0119); CA frame is a **shadow image copied in/out each frame** (HANDOFF:73-82) | [V own logs] swipe benchmark 19-26 fps (HANDOFF:83-84); 15.8 -> 21 fps from correct vsync period a3 (0121, HANDOFF:61-63); DDR vote: present blit 1.65 -> 1.1 ms (0122) | vsync callback carries the refresh period; DDR/NoC vote to top; 8 MB m2v memory blocks (0100); present not waited |
| UniXNU sheng (A740) | same as ours: NativeMetal frontend -> Rust bridge -> metal2vulkan 720ef1ce + 16 perf patches -> Turnip darwin KMD -> one IOKit struct call per submit | default: GPU blit of the compositor IOSurface into firmware scanout, both imports cached per surface (GpuScanoutPresenter.h:2-4,82-84); swap retires when accepted, not after the copy (8666a99); opt-in `sheng-dpu-scanout=2` = true DPU zero-copy | [claimed, commit 461a842] "600 s without a stall at 70 fps p50"; GPU 19 % busy at 680 MHz with all-sysmem. [V comment PrimeShaders.h:118-122] scripted swipe median frame interval 19 ms | up to 128 IBs per submit (one ring prologue/frame, c232716); no TLBIALL per submit (5c8c145); BoMap 1.42 -> 0.20 ms (1c4065c); RT imports non-cacheable: per-submit cache work was ~60 ms/frame before (b686b90); idle-time priming of all 162 OS metallibs, yields at > 8 CB/250 ms; Turnip builtin shader pack; m2v patches: keep final pass, fewer allocs per draw, keep draw lists, skip unchanged rebinds, faster tracker hashmap, row-safe tile stores (GMEM); `TU_DEBUG=nocb` + autotune GMEM; padded-row aliasing (no shadow of 12288-pitch framebuffers, NativeMetalObjects.rs:166-169); scanout thread user-interactive (c6d29ca: p90 > 40 ms frames -5 ms); fixed vsync range report |
| UniXNU-pong (A730) | same as sheng | GPU blit into Mini framebuffer | none; README says acceleration "unconfirmed" | `TU_DEBUG=sysmem,nocb` forced (PongMetalPlugin.mm:134-136), 256 MiB pool, IRQ fence |
| Chlorophyll (A630) | CA Metal -> own Metal classes (`bgmtl.m`) -> AIR->NIR->ir3 -> freedreno Gallium -> msm-style client | kernel holds the swap until the fence, then GPU scan-out copy on the same ring (0229/0240) | [V FIXES.md] frame ~120 -> ~20 ms; swipe 20.8 -> 28.4 fps (async commit), ~30 -> ~41 fps (pools), backboardd 93-98 % of a core | commit reports "scheduled" at once, no wait in CA; **IOSurface import cache per surface ID: import + first clean was 45 % of backboardd time** (air_metal.c:1644-1650); BO cache keeps freed BOs 15 s, skips busy ones (full-screen alloc ~18 ms); GMEM except fetch draws; `CA_DISABLE_FRAMEBUFFER_COMPRESSION=1`, `CAEnableDeepFramebuffer=NO` (bgmtl_inject.m:320,335-337) |
| HackiOS / hackios-next (A642L) | CA **GLES** renderer -> EAGL bridge -> Mesa freedreno -> IOKit msm client | CA renders to a Mesa texture, one GPU blit into the IOSurface; then a **CPU bilinear copy on 3 threads** (3 ms) into the panel; queue depth 2, 60 Hz own beat | [V notes.md:436-441] Settings scroll **56-58 fps**, 95-97 % on the 16.7 ms step | glFenceSync + flush, CA never waits; GPU pinned 550 MHz + DDR/LLCC max vote (Control Center 46 -> 59 fps); little cores marked (slow frames 84 % -> 46 %); GLES renderer skips ~half of CA's 90 functions (fewer passes) |
| Bergamota (A630) | EAGL GLES / Chlorophyll | direct MDP VIG0 scanout (compile-checked only) | [V NOTES.md:10] 26-40 fps swipes, SwapWait 8-10 ms; depth 1 queue = 2-7 swaps/s | Mesa shader cache 128M on; swap depth 2 |
| ios-spes (A610) | GLES via freedreno | CPU copy 10.4 MB/frame (MDP direct never engaged: RAM > 4 GiB) | [V NOTES.md:637-641] median 27.2 ms (~37 fps), p90 47.8 ms | WC scanout pool below 4 GiB: removed 5-13 MB cache push per submit (6-16 ms each) |
| ios-sailfish (A530) | GLES in backboardd (`sweetgl.dylib`) | kernel GPU bilinear blit into 2 panel buffers + MDP flip | [claimed] 20-40 fps, CA CPU bound | **render 750x1334 @2x (~1 Mpx)**; GPU pinned 600 MHz |
| ios-s9 / ios-sweet | CPU render | CPU copy / zero-copy VIG (s9 0096) | [claimed] 20-30 fps | s9: 828x1792 (1.48 Mpx, -46 %); render threads on big cores |

Notes: no project publishes backboardd CPU % next to a commit-to-complete distribution, so no like-for-like number exists.
The best Metal number is sheng's claimed 70 fps p50 on an A740 (newer GPU, faster CPU); the best measured GPU UI number is
HackiOS GLES 56-58 fps at ~2.7 Mpx with a reduced shader set. Our 14-27 presents/s on a busy UI is below flame (19-26)
only in the DCVS-low window; at 818 MHz it is in flame's range and below sheng and HackiOS.

### Is ours faster or better? [I]

- Same layer count as flame, sheng and pong. Our kernel side is ahead (fence IRQ, TZ DCVS, double-buffered panel, cheap
  0.25 ms copy, zero-copy code present). Our user side lacks most of sheng's per-frame trims (list below).
- The GPU is mostly idle (12-26 % GMU busy). So the cost per frame is CPU and serial latency: frontend + Rust runtime
  encode, shadow copies of IOSurface textures, host-import cache maintenance, and DCVS low clocks between frames.
- 6.2 Mpx per command buffer = 2.2 screens. Part of that may be the shadow copy-in/copy-out of IOSurface textures
  (notes:3463-3464: since m2v e35bf78b every IOSurface texture is a shadow) [I: not measured per pass].

### Ranked changes for us

| # | Change | Evidence | Expected gain | Effort |
|---|---|---|---|---|
| 1 | Remove the IOSurface shadow copies: render and sample IOSurfaces in place (sheng `PaddedReadsPolicy::AliasWrites` + import cache per surface; our 0101 port only covers runtime-owned buffers since e35bf78b) | sheng NativeMetalObjects.rs:166-169, ed654b4; flame HANDOFF:73-82 (shadow ~1 ms + uploads per frame); our notes:3463 | [I] large: fewer passes/pixels per CA buffer (part of the 6.2 Mpx), less CPU in backboardd. Measure first: count shadow copy bytes per CB in telemetry | M (m2v runtime patch over f6a96b7d; flame tried the Turnip dedicated-alloc route and got bands, HANDOFF:76-79) |
| 2 | Port sheng's metal2vulkan perf patches 0009-0016 (keep final pass, fewer allocs per draw, keep draw lists across encoders, skip unchanged rebinds, faster tracker hashmap, row-safe tile stores) onto our pin | NativeMetal bridge/patches (MIT); our m2v patch set has none of these [V ls userland/metal/patches] | [I] backboardd CPU per frame down (70-80 % now); likely the biggest CPU win | M (rebase from 720ef1ce to f6a96b7d; some may be upstream already: check first) |
| 3 | Stop invalidating host imports the GPU only reads (22.9 MB per CB) and make render-target imports non-cacheable (no per-submit maintenance) | our notes:812-813 + 3 lines after ("count only written imports", not done); sheng b686b90 (~60 ms/frame of cache work before); spes NOTES.md:798-801; Chlorophyll 45 % import cost | [I] several ms CPU per CB | S-M (m2v/0001 read/write split; kernel import cacheability) |
| 4 | GPU clock: keep the floor up while frames are late (TZ governor 0389 is in; GMU busy 12 % at 220-317 MHz in 694 s of 951) and vote DDR/LLCC high while the UI moves | our fbstat: 730-818 MHz gives 18.6 vs 12.1 presents/s; older log fixed 818 MHz: +30 % presents/s; HackiOS DDR vote 46 -> 59 fps; flame 0122 | [V] +30-50 % presents/s in busy seconds | S (policy in existing 0389/0384 code; DDR vote = flame 0122 / HackiOS RPMh BCM) |
| 5 | Submit batching: many IBs per submit, no TLB flush per submit, cheaper BO map | sheng c232716, 5c8c145, 1c4065c | [I] 0.5-2 ms per CB; check our RedwoodGPU submit for TLBIALL and per-map SMMU reads first | S-M (kernel) |
| 6 | Idle-time priming of all OS metallibs + Turnip builtin shader pack, yield when frames run | sheng PrimeShaders.h:118-122 (priming during swipes: 19 -> 30-48 ms intervals, so yield matters) | removes first-use hitches (apps, Control Center), not steady fps | M |
| 7 | Early swap retire + scanout/present thread at user-interactive priority | sheng 8666a99, c6d29ca (p90 > 40 ms frames -5 ms); Chlorophyll async commit 20.8 -> 28.4 fps | [I] fewer missed ticks (77 % now) | S |
| 8 | CA settings in backboardd: framebuffer/IOSurface compression off, deep framebuffer off; find why CA picks BGR10_XR attachments (extended-range blend emulation per pixel in m2v) | Chlorophyll bgmtl_inject.m:320,335-337; our notes:814-818 | [I] per-pixel shader cost down; possibly fewer passes | S (A/B via plugin answers; Apple-family answers already say Apple1-3 YES in flame/0014, so CA's 128-draw split does not apply [V]) |
| 9 | GMEM: test `TU_DEBUG=nocb` with autotune vs forced sysmem; port m2v row-safe tile stores first | sheng NativeAdrenoMetalPlugin.mm:220-225 (concurrent binning deadlocked); pong forces sysmem | [I] small while the GPU is 12-26 % busy; matters at 120 Hz | S (env file `/var/db/negronimetal/env`) |
| 10 | Zero-copy DPU scanout (0234 test) | ios-s9 0096 [V on S9]; sheng `sheng-dpu-scanout=2` | small: our copy is 0.25 ms avg [V]; frees the ring and DDR | S to test (boot-arg), M to finish multi-layer |
| 11 | Lower CA render scale (e.g. 828x1792 @2x like s9/sailfish) | sailfish ~1 Mpx, s9 -46 % pixels | [I] ~2x fewer pixels; changes UI size, owner decision | M |

Not recommended: a direct AIR->NIR->PM4 path (no project runs one at frame time; UniXNU keeps AirNir offline), and a GLES
switch for backboardd (HackiOS is faster partly because it skips half of CA's shaders, which loses effects).
