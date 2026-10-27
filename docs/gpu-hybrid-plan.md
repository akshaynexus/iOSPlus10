# Hybrid GPU acceleration: Metal + GLES + CPU per process (2026-10-27)

Owner: "we have a lot of things we can borrow; let's borrow and improve our GPU acceleration, so that it fixes the parts
Metal lacks or is bad at where OpenGL is needed and vice versa, so we are on top."

Marks: **[V]** seen in a log, a binary or a test run (file named). **[I]** inference. Phone clock = host - 12.5 h.
Inputs: logs/usblog-20261025-223827.txt, usblog-20261026-233816.txt, usblog-20261027-171256.txt (kernel log with `NMTL`,
`CRASH`, `NEGRONI SURF` lines), logs/camlog3/5/6-full.txt and logs/phone-full-20261027-1743.txt (unified log),
docs/gpu-comparison-2026-10-27.md, docs/metal-widgets-2026-10-27.md, the reference trees in external/ and out/src/hackios-next.

## 1. Short answer

- The Metal path (NegroniMetal -> metal2vulkan -> Turnip) is the main path. It runs backboardd, SpringBoard, chronod,
  posters, Maps snapshots, Photos and WebGL [V]. Its open faults are surface formats (two-plane XR10 / YUV), memory in
  small processes, posters' XR answer, and pipelines that metal2vulkan does not build (VFX).
- The GL path (negronigl: Mesa freedreno A730) works in a test process (`ngl_test` PASS on the phone, 2026-10-25 [V]),
  but no system process used it in the last 3 boots: backboardd is `-backboardd` in the app gate, and no app made an
  EAGLContext [V: the only GL lines are `NegroniGL app gate closed for backboardd`]. So today GL is not a fallback.
- No reference port selects GL with a CA environment variable or a default. CoreAnimation's render server takes Metal
  if `MTLCreateSystemDefaultDevice` gives a device, else OpenGL ES, else its software renderer (HackiOS
  hackios-next 8851317 userland/src/eagl.c:5-7, sailfish tools/sweetgl/eagl.c:2205) [V their comments]. The per-process
  choice is therefore "give or refuse the Metal device" and "give or refuse the GL driver".
- New: `userland/gpu-policy` makes that choice per process from a policy file plus the health of each API (owner
  switch = DISABLED, failed self-check in this boot = FAILED). A FAILED Metal moves the process to GL (only where GL
  can be used: backboardd and EAGL clients); a FAILED GL moves it to the CPU. Both have dead-man strikes. Built and
  host-tested; the GL side is hooked now; the Metal side needs 2 small hooks in the reviewed NegroniMetal.mm (section 7).
- Owner report (photo, 18:48): Camera preview black on Metal (2-plane '420f' refused; the plane fix was rolled back) and a
  partly drawn dash in Camera's top bar (notch area). Both are in the matrix; the GL fallback A/B (section 8 step 3) tells
  whether GL draws them whole.
- Borrowed for GLES now: full precision in CA's shaders (HackiOS) and a CPU copy for multi-plane surfaces (HackiOS idea),
  so video/camera/'b3a8' textures are no longer empty on GL. Shader corpus regression test (Chlorophyll's method) on the Mac.

## 2. Capability matrix (who uses what, what fails, what is better)

Crash counts are `CRASH NAME sig N` lines per boot log (de-duplicated by pid where it matters; see the logs).

| Client / framework | In-process GPU users | Metal path today | GL path today | Better on | Policy order |
|---|---|---|---|---|---|
| backboardd (CA render server) | CA Metal renderer, or CA OGL renderer through EAGL | [V] opens in 0.7 s, 17-41 pipelines, 0 failed; `Failed to allocate MTLTexture from IOSurface` 118-568 per capture (chronod's 2-plane `_RB4`/`b3a8` widget surfaces; RB_COLOR_MODE=fixed avoids them; the flame/0016 plane textures were rolled back because they broke the IOSurface no-copy import); 3-11 x `Failed to allocate ... b3a8 framebuffer MTLPixelFormatRGB10A8_2P_XR10`; 10-25: 16 x `texture refused: OutOfMemory(Device)` + 12 x linear | [V] never ran in backboardd on the phone. Code: EAGL shim + preflight (FD730, triangle, IOSurface). Missing: XR/10-bit formats (BGRA only), 3 CA texture functions that sailfish patches in (vcm, cm4, variable blur), draws with program 0 (lock-screen wallpaper, HackiOS plain_draw_begin), vibrancy groups | Metal (formats, YUV, 0 pipeline failures). GL as the fallback when Metal fails (strikes, GPU lost, open refused) instead of Apple's software GL | metal gl cpu |
| SpringBoard | Siri orb (MPS), CAMetalLayer, RenderBox | [V] opens 4-16 x per log; Siri orb crash fixed (flame/0012); MPS feature flags answered NO | none (no EAGL user) | Metal | metal cpu |
| chronod (home-screen widgets, RenderBox) | RenderBox | [V] blank widgets = 2-plane XR10 surfaces refused (RB_COLOR_MODE=fixed is the remaining fix; plane textures rolled back); 14-19 MiB, 0 refused pipelines | RenderBox has no GL back end [I: not checked in its imports; flame runs `* -chronod` = CPU for correct widgets, HANDOFF.md:42-43] | Metal, else CPU (flame's choice) | metal cpu |
| WidgetKit extensions (FitnessWidget = VFX) | VFX renderer | [V] jetsam 30 MiB kills (fixed: 64 MiB root limit + 40 MiB memory rule); `render pipeline skipped: nil render pipeline` 4-26 x; the corpus test translates all 144 VFX vertex/fragment functions on the host, so the nil pipeline is a runtime state/limit item [I] | none (VFX is Metal only) | Metal, else CPU | ext:com.apple.widgetkit-extension metal cpu |
| Posters (AegirPoster, Pride, Collections, Weather, Emoji, Unity, Gradient, Extragalactic) | CAMetalLayer (ClockKitUI, NanoUniverse) | [V] AegirPoster sig 6 `CAMetalLayerInvalid: unsupported extended range format` 172 / 212 / 615 per log (fix: NEGRONIMETAL_XR10=auto, pending); 7 other posters sig 5 at one pc 0x1e4550900 (same in all 7, not tied to Metal [I]); CollectionsPoster makes 420f 2-plane and L008 surfaces | none | Metal, else CPU | *Poster metal cpu |
| com.apple.WebKit.GPU (WebGL, WebGPU through ANGLE-Metal) | ANGLE Metal back end | [V] WebGL 1+2 work (flame/0014-0015); 2 x `MSL front end refused ... Undefined symbol(s) for architecture 'air64'`; footprint 396 MiB against a 300 MiB fatal limit; pipelines 0.1-1.2 s each | ANGLE's GL back end is not in the iOS 16 build [I] | Metal | metal cpu |
| Maps / MapKit.SnapshotService (VectorKit) | VectorKit Metal | [V] opens 3-9 x; Maps sig 6 once (10-25) | none | Metal | metal cpu |
| Video playback (mediaserverd, AVPlayerLayer) | none in-process; backboardd samples 420v/420f + L008 surfaces | [V] mediaserverd makes L008 surfaces (42-244 per log); two-plane YCbCr textures: see the Camera row (rolled back); video decode itself crashes: mediaserverd sig 10 in H264SW writing into the shared region (notes.md 76, camera agent; also flame HANDOFF.md:249-252) - not a GPU item | before: multi-plane surfaces refused = empty video on GL; now: CPU copy per plane (section 5) | Metal (zero copy); GL now works with a copy | (backboardd's) |
| Camera.app preview (owner photo 2026-10-27 18:48, NegroniMetal 1f184f80... from the root) | backboardd samples the capture's 2-plane '420f' surfaces | [V owner] preview black: the frontend refuses 2-plane surfaces; the f6a96b7d + flame/0016 plane textures fix it but broke the IOSurface no-copy import and were rolled back (coordinator, 2026-10-27) | GL now copies each plane by the CPU (section 5); not run on the phone | GL works today with a copy; Metal after the plane fix is re-done | (backboardd's) |
| Partial draws / clipped layers (owner photo: the short dash next to the Live Photo icon in Camera's top bar, notch area, drawn only partly) | CA render server | [V owner] seen on Metal; cause open: [I] a scissor or viewport rect, a sub-rect blit (`copyFromTexture:sourceOrigin:sourceSize:`), a mask/clip layer, or the notch safe area (D22 = iPhone X geometry on a 1440x3216 panel) | unknown: GL never composited on the phone. Test: the step-3 fallback (section 8) on the same screen: drawn whole on GL = a Metal-path item (bridge scissor/blit), cut on GL too = layout/safe-area item | to decide by the A/B | - |
| Photos (MobileSlideShow) | PhotosUICore Metal | [V] device opens; sig 6 = NSInternalInconsistencyException in its data source (not GPU) | none | Metal | metal gl cpu |
| GLES apps and games, GLKit, CoreImage-on-EAGL | EAGLContext | not used | [V code] NegroniGL.bundle app gate `* -backboardd`; never opened on the phone (no GLES app was started) | GL (only path for GLES apps) | metal gl cpu (GL gate as before) |
| CoreImage (Metal) | CI kernels | stitchable `extern` functions (ci_filters 550) are linked at run time; not translatable by our host tool | n/a | Metal | (caller's) |

Memory [V]: chronod 31 MiB with the device (limit 98/45), widgets 4-13 MiB without it and 11.5 MiB with it under the
64 MiB limit, MapKit.SnapshotService 20 MiB (inactive limit 12 MiB), WebKit.GPU 396 MiB (limit 300). The Metal stack costs
about 15-20 MiB per process (docs/metal-widgets-2026-10-27.md section 1). The GL stack (NegroniGL 13.8 MB file, mostly clean
__TEXT) costs less footprint [I: not measured], but no widget framework can use GL.

Where GL is better than Metal [I unless marked]:
1. backboardd when Metal fails: CA's OGL renderer on the GPU instead of Apple's software GL (the CPU path today).
2. GLES apps and games: there is no other path.
3. Bring-up independence: GL does not need metal2vulkan's translation of 141 CA functions or its pipeline compiles
   (0.1-1.2 s each [V]); a CA shader on Mesa compiles in ms [V ngl_test context 99 ms, frame 1.4 ms].
Where Metal is better: every in-process framework that is Metal only (RenderBox, VFX, MPS, VectorKit, ANGLE, CAMetalLayer),
zero-copy YUV (f6a96b7d) and XR formats, and the 0-failure pipeline record in backboardd.

## 3. Policy

Component: `userland/gpu-policy/negroni_gpu_policy.{h,c}`, compiled into negronigl.dylib and NegroniGL.bundle now, and
into NegroniMetal.bundle after the hook (section 7).

1. **Order per process.** First matching line of `/var/db/negronigpu/policy` (owner), `BUNDLE/gpu-policy.local`, then the
   staged `BUNDLE/gpu-policy` (both bundles; sandboxed apps can read the bundles, not /var/db). Line = `PATTERN API...`;
   PATTERN = fnmatch glob on the process name or `ext:GLOB` on NSExtensionPointIdentifier; API = metal | gl | cpu.
   No match: `metal gl cpu`. Staged defaults: userland/gpu-policy/gpu-policy (matrix column "Policy order").
2. **Health per API** (read from the same files the gates use; Metal's are only read):
   - Metal DISABLED: NegroniMetal.bundle/off, /var/db/negronimetal/off, not in the clients files, boot-arg
     negronimetal=0, jetsam limit < NEGRONIMETAL_MIN_LIMIT_MB (40).
   - Metal FAILED: GPU watchdog marker `strikes/gpu-lost` of this boot; dead-man strikes of this boot >= the limit (2,
     posters 4, env file) in a file older than the process (a newer file = armed by the plugin in this process = in use);
     a failure record of this boot (`/var/db/negronigpu/state/<proc>`, sandbox: `<cache>/negronigpu-state/<proc>`).
   - GL DISABLED: /var/db/negronigl/off, NegroniGL.bundle/off. GL FAILED: GPU lost (same GPU), GL strikes of this boot >=
     NEGRONIGL_STRIKE_LIMIT (2), a GL failure record (preflight or fallback self-test failed).
3. **Choice.** Walk the order. OK -> use it. FAILED -> next. DISABLED as the first API -> no decision (the old gates
   decide: an owner switch keeps its meaning and never moves a process to another API). DISABLED later -> CPU. All
   FAILED -> CPU. So an API that failed in this boot is never used again in this boot for that process: never both broken.
4. **Self-checks (no probes).** Metal: its dead-man, open/self-test deadline, GPU watchdog (existing). GL: the GL
   dead-man (new: strike file armed before the GL path goes in, cleared by the first 3 flushes, 15 s or exit; crash or
   hang = strike), the preflight (shim) or the fallback self-test (bundle: triangle + IOSurface) before GL is given to a
   process that Metal failed in; a failed self-test writes a GL failure record. Log lines `negronigl: gpu-policy: ...`.
5. **Kill switches.** Whole component: `/var/db/negronigpu/off`, `BUNDLE/gpu-policy.off`, `NEGRONIGPU=0` (then the old
   gates alone). Fallback for one process: a policy line without gl (`backboardd metal cpu`). GL dead-man limit:
   `NEGRONIGL_STRIKE_LIMIT`.
6. **Per surface.** Inside one process the API is fixed. Per surface the GL path now chooses GPU import (one plane) or a
   CPU copy (planes); the Metal path chooses zero-copy import or a shadow image (f6a96b7d plane textures).

Where the hooks are:

| Gate | File | Now |
|---|---|---|
| NegroniGL.bundle app gate | userland/negronigl/plugin/gld.c `apps_gate` | lists as before; if closed, `ngp_gl_fallback` may open it (Metal FAILED + order has gl after metal) after the self-test; GL health; GL dead-man armed |
| backboardd EAGL shim | userland/negronigl/negronigl.c `gate_open`, `ngl_load` | clients list as before; if not listed, the same fallback; dead-man armed before the preflight; preflight FAIL = GL failure record |
| GL frames | userland/negronigl/view.c `ngl_flush` | `ngp_gl_frame_ok()` clears the strike after 3 flushes |
| NegroniMetal gate | userland/metal/plugin/NegroniMetal.mm | **later** (section 7) |

## 4. What we take from which project

| What | From (file, commit) | Licence | How used |
|---|---|---|---|
| Full precision: `#define lowp highp`, `#define mediump highp` in CA's shaders (16-bit mediump on Adreno banded the Weather sky) | HackiOS out/src/hackios-next 8851317 `userland/src/eagl.c:3621-3634` | MIT (userland/; kernel parts APSL) | text of the 2 defines + idea; own insert in `userland/negronigl/shaders.c`, self-check retry in `eagl.c ngl_h_CompileShader`; notice in the file |
| CPU copy of one surface plane into a texture | HackiOS `userland/src/eagl.c:674-720` `surface_to_texture`, `bytes_a_pixel` :571 | MIT | idea + texel table; own code `userland/negronigl/surface.c plane_copy` |
| Per-boot crash-loop strikes and Metal -> GL -> plain fallback for backboardd | Bergamota `gpu/eagl/launch/bgl-launch.c:1-30` (0826e48) | MIT (SPDX in the file) | idea only; own code in userland/gpu-policy |
| Clients list `*` / `-NAME` | ios-flame `phone/metal2/SweetMetal2.mm:105-146` (745c434) | MIT | same file syntax (already ours in NegroniMetal) |
| Corpus test: every system metallib through the translator, per library/kind table | Chlorophyll `tools/corpus.py`, `results/all-system-metallibs-summary.txt` (787338f) | MIT | method + table format + their numbers as a reference column; own script `scripts/metal/shader-corpus-test.sh` |
| CA texture functions vcm/cm4/variable blur patched into QuartzCore's tables (20H392 addresses) | ios-sailfish `tools/sweetgl/eagl.c:2150-2200` (6f27e41) | **no licence file**: not copied | not taken; to do as own code from our own 20H392 disassembly (section 9) |
| EAGL preflight, `RedwoodWaitsForGPU` flush | ios-spes `spes_gl_preflight.c` (2cd45c4, no licence), HackiOS `display_waits` | spes: idea only (done earlier); HackiOS MIT | already in negronigl |

## 5. What is built (2026-10-27)

- `userland/gpu-policy/negroni_gpu_policy.{h,c}`, `gpu-policy` (staged order file), `tests/policy_test.c`.
  `scripts/gpu/policy-test.sh`: host test **38 passed, 0 failed** [V] (default order, clients, staged rules, ext: rule,
  Metal strikes of this boot / another boot / armed in this process, poster limit 4, env limit, GL dead-man arm x2 ->
  refused, both failed -> cpu, frames clear the strike, GL off, GPU lost + stale marker, failure records per boot, owner
  rule wins, Metal off -> no decision, memory rule = disabled, component off, `-chronod`); iOS arm64 compile with
  `-Wall -Wextra -Werror` OK.
- negronigl: gate hooks (gld.c, negronigl.c, view.c), full precision (shaders.c, eagl.c retry), plane CPU copy
  (surface.c), `meson.build` + `scripts/gpu/sync-target.sh` (policy sources into the Mesa target),
  `scripts/gpu/build.sh` / `gl-build.sh` / `phone-gl.sh apps on` (stage and push `NegroniGL.bundle/gpu-policy`).
  Build `scripts/bg.sh hybrid-gl-build scripts/gpu/gl-build.sh`: exit 0, no new warning, check-imports PASS (0 missing)
  [V logs/hybrid-gl-build.log]. Stage: `negronigl.dylib` 14,253,712 bytes (sha256 d3110a138ef435f7...),
  `NegroniGL` 13,811,648 (558346b80ba9efab...), `gpu-policy` (e6618f01058d6d12...); `out/gpu/stage.SHA256SUMS`.
- `scripts/metal/shader-corpus-test.sh` (+ `M2V_CLI`, `TRANSLATE_DIR` overrides in `scripts/metal/host-translate.sh`).
  Result: section 6.

## 6. Shader corpus test (Mac)

```sh
scripts/bg.sh shader-corpus env SET=ui scripts/metal/shader-corpus-test.sh all   # fetch (phone, read-only) + run + compare
scripts/metal/shader-corpus-test.sh compare      # latest run vs userland/metal/tests/shader-corpus-ui.tsv: exit 1 on a regression
scripts/metal/shader-corpus-test.sh baseline     # accept the latest run as the new baseline
SET=all ROOT=/mounted/root scripts/metal/shader-corpus-test.sh all             # all 143 metallibs (hours)
```

It builds the host metal2vulkan CLI once per (submodule commit + m2v-flame + m2v patches) as
`out/metal/bin/metal2vulkan-<hash>` from a private copy of `out/metal/src/metal2vulkan`, runs `host-translate.sh` on each
library with the estimated A730 profile, and writes `out/metal/corpus/runs/<time>-<set>/{summary.tsv,summary.txt,libs/}`.
Rows have Chlorophyll's form (`lib kind total= translate=`) and Chlorophyll's iOS 18 / A630 count for the same library as
a reference (another iOS version and another translator: information only). A drop in any (library, kind) pass count
against the baseline is a regression. Run it after every metal2vulkan pin change or m2v patch.

First run [V] 2026-10-27 18:42-18:48 (`out/metal/corpus/runs/20261027-184201-ui`, metal2vulkan f6a96b7d + 6 m2v-flame + 3 m2v
patches, CLI `out/metal/bin/metal2vulkan-8a4b9ab3f593`, about 6 min for 30 libraries; fetched read-only from the phone): **2872 of 2919**
kernel/vertex/fragment functions translate (98.4 %); 4,149 stitchable/visible/unqualified functions (MPSCore, CoreUI, CoreImage) are
counted, not compiled. This run is the baseline `userland/metal/tests/shader-corpus-ui.tsv`; `compare` against it: 0 regressions.

| Library | Result | Note |
|---|---|---|
| QuartzCore | 139 / 141 | the 2 RasterOrderGroups fragments (FragmentShaderPixelInterlock), as in metal-plan.md |
| RenderBox | 47 / 47 | widgets: the blank cause is the surface format, not shaders (metal-widgets section 8) |
| VFX (FitnessWidget) | 253 / 257 (kernels 109/113: 2 x storage images 6 > 4 in the estimated profile, 2 x bloom non-uniform texture-array indexing) | every vertex and fragment translates on the host: the phone's `nil render pipeline` comes from the runtime pipeline state (vertex descriptor, constants, formats) or the real A730 limits, not from translation [I]; next: log the refused pipeline's descriptor in FitnessWidget |
| VectorKit (Maps) | 286 / 309 | 13 = `ClipDistance` with MaxClipDistances 0 in the **estimated** profile (Turnip A730 has clip distances [I]: profile artefact), 7 tessellation (`tessellation_vertex_*`), 3 others |
| MPSImage / MPSCore | 1825 / 1825, 53 / 54 | Siri orb, image filters; MPSCore `copy_float_generic`: `Lowering(Sampler)` not implemented |
| NanoUniverse, ClockKitUI, PridePoster | all | posters' faults are the XR answer, not shaders |
| LocalAuthenticationPrivateUI | 4 / 12 | 7 vertex + 1 fragment `UnmatchedVarying` (Face ID / passcode UI effects) |
| PencilKit | 16 / 22 | 6 fragments `FunctionConstantType` with the host stand-ins [I: may pass with real constants] |
| VideoProcessing, SiriUICore | 7 / 9, 19 / 20 | VCPSideCar deblock kernels: static initializer x2; SiriBlur kernel: texture array non-uniform indexing |

Failure classes: UnmatchedVarying 10, ClipDistance 13 (profile), FunctionConstantType 6, tessellation 7, texture array
non-uniform indexing 3, static initializer 2, RasterOrderGroups 2, descriptor count 2. Chlorophyll's iOS 18 / A630 column is only
for orientation (other OS, other translator; it fails most VFX/QuartzCore fragments that we pass).

## 7. Hook changes the reviewed files need later

Do these after the review of NegroniMetal.mm / patches / fetch-sources.sh / env.sh is committed.

1. `userland/metal/plugin/NegroniMetal.mm`, gate (after `listed()`, before the memory rule):
   ```objc
   #include "negroni_gpu_policy.h"
   ...
   char pw[1200];
   enum ngp_api a = ngp_choose(getprogname(), extension_point(), NULL, pw, sizeof(pw));
   if (a == NGP_GL || a == NGP_CPU) { nlog("gpu-policy: %s: no Metal device", pw); return; }
   ```
   Effect: an owner rule `NAME gl metal cpu` (GL first) works, and a process whose Metal FAILED (record) is refused
   cleanly before the open instead of only by the strike count. `NGP_NONE` / `NGP_METAL` = today's path.
2. Same file, failure records (one line each) where the open fails without a crash:
   `ngp_record_failure(getprogname(), NGP_METAL, why)` after `open refused: ...`, after the open/self-test deadline
   (`device open/self-test still running after N ms`), and when the first-frame summary reports failed pipelines
   (`pipelines N compiled ..., F failed` with F > 0, or the `nil render pipeline` skip in a process whose order has gl
   after metal). Note: `deadman_refused` clears the strike on a clean refusal today; the record keeps the failure for
   this boot, so GL takes over at the next start.
3. `userland/metal/CMakeLists.txt`: add `../gpu-policy/negroni_gpu_policy.c` to the plug-in sources and
   `../gpu-policy` to its include directories; link CoreFoundation (already linked).
4. `scripts/metal/build.sh`: stage `userland/gpu-policy/gpu-policy` as `NegroniMetal.bundle/gpu-policy` (sandboxed
   Metal clients read the order there). `scripts/metal/phone-test.sh push`: push it.
5. No change to `scripts/metal/fetch-sources.sh`, `scripts/metal/env.sh` or the m2v/flame patches.
6. Owner defaults: `scripts/gpu/phone-accel.sh on` and `root-add-negronigl.sh` keep `apps.local = * -backboardd`; the
   fallback ignores that line on purpose (it only fires when Metal FAILED). To turn the fallback off for backboardd:
   `echo "backboardd metal cpu" > /var/db/negronigpu/policy`.

## 8. Test steps (phone; main session)

Nothing in this work touched the phone except one read-only `tar` of 30 metallibs for the corpus.

1. Push the GL stage: `scripts/gpu/phone-gl.sh push`, `scripts/gpu/phone-gl.sh apps on` (also pushes
   `NegroniGL.bundle/gpu-policy`). Keep `make usblog` running.
2. Normal boot, Metal `*`: proof lines in usblog / os_log `dev.iosplus10.negronigl`: no new behaviour; an EAGL app (any GLES
   game) logs `NegroniGL app gate open for NAME (freedreno)` and `gpu-policy: GL dead-man: strike 1 armed`, then
   `strike cleared (first GL frames flushed)`. `negronigl: shader precision highp everywhere`.
3. Fallback A/B for backboardd (no reboot): make Metal FAILED for backboardd in this boot:
   `scripts/net/ssh-phone.sh 'echo "2 $(sysctl -n kern.bootsessionuuid)" > /var/db/negronimetal/strikes/backboardd'`, then
   restart backboardd (`scripts/gpu/phone-gl.sh restart`). Expected: `NMTL[backboardd]: dead-man: 2 unclean starts ...
   no Metal device`, then `negronigl: gpu-policy: GL as the fallback renderer for backboardd (... metal FAILED ...: gl)`,
   `NegroniGL app gate open for backboardd (freedreno, gpu-policy fallback)`, and the UI drawn on the GPU (`NEGRONI FB STAT`
   gpu/zc presents > 0). If backboardd crashes twice: `GL dead-man: 2 unclean starts` and the third start runs on Apple's
   CPU renderer (`NegroniGL app gate closed ... GL dead-man`). Undo: `rm /var/db/negronimetal/strikes/backboardd
   /var/db/negronigl/strikes/backboardd /var/db/negronigpu/state/backboardd` + restart.
   [I] Risk: CA's OGL renderer in backboardd through the bundle route was never run on the phone; the dead-man bounds it to
   2 failed starts.
4. Video on GL (only in step 3's mode): play a video in Photos or open Camera; usblog shows `negronigl: texImageIOSurface:
   IOSurface N plane 0 of 2 ('420f') WxH format 0x1909: CPU copy` and the picture is not black.
5. Owner's Camera screen in step 3's mode: the preview (GL plane copies) and the dash next to the Live Photo icon. Whole
   on GL and cut on Metal = a Metal-path item (bridge scissor / sub-rect blit); cut on both = a layout / safe-area item.
6. Precision: in step 3's mode the Weather widget / lock-screen gradients show no bands; `NEGRONIGL_PRECISION=0` in
   backboardd's environment is the A/B.
7. Corpus: section 6 on the Mac after each metal2vulkan change.

## 9. Next borrowings (not done here)

1. CA texture functions missing on GL (vcm 0x2d, cm4 0x14, nop 0x26, variable blur 0x27): write our own patch of the 20H392
   `tex_fragment_shaders` table from our disassembly (sailfish has no licence: no code copy).
2. Draws with program 0 (lock-screen wallpaper "cst" function 89): HackiOS `plain_draw_begin` eagl.c:2830-3011 (MIT).
3. CA function census on GL (HackiOS hooks `function_supported`, vtable +0x378): log every function the GL renderer refuses.
4. Fault logger for backboardd on GL (HackiOS inject.c `say_the_fault`, MIT): pc/lr/8 frames to the console.
5. Kernel 10-bit -> BGRA surface remap for WebContent only (flame 0124, MIT; HackiOS MiniIOSurface.cpp:461-479, APSL).
6. UniXNU-pong PongMetal/PongAdreno (same A730): read for GMU/firmware differences (licence BSD-2-Clause-Patent / MIT).

## 10. Review fixes (2026-10-27, Opus review)

- shaders.c: the precision defines go right after `#version` (else at the top). `after_directives()` also skips
  indented code lines, so the defines could land after declarations: a uniform mediump in one stage and highp in the
  other = a link error.
- surface.c `plane_copy`: CA's context is ES 2 (no sized formats): when the sized upload fails, upload again with
  internal format = format (`GL_RED_EXT`/`GL_RG_EXT`, EXT_texture_rg). Older GL errors are cleared before the upload.
  A NULL plane base address is refused (the surface is unlocked).
- negroni_gpu_policy.c `boot_id`: when `kern.bootsessionuuid` fails, use `kern.boottime` ("boottime-SEC"), never the
  constant "-" (it matches in every boot, so a strike or a failure record would never expire).
- THIRD_PARTY_NOTICES.md: HakiOS userland MIT notice (section 3.D).
- Open, not changed: the 15 s timer clears a GL strike also when the process then crashes later (a crash loop slower
  than 15 s is not counted); the precision retry compiles one stage without the defines, so its uniforms can differ
  in precision from the other stage (link error; rare: only when the compiler refuses the defines); `plane_copy`
  copies again on every bind (no IOSurfaceGetSeed cache).

## 11. Risks

- [I] The GL fallback for backboardd has never drawn a real CA frame on the phone; first use is in a failure case.
  Bounded by the GL dead-man (2 starts per boot), then the CPU.
- [I] CPU plane copies cost per frame (1080p NV12 = 3 MiB a frame); only on the GL path, only for planes.
- [I] `#define lowp highp` raises ALU cost on Adreno; the compile retry covers compiler refusals, not speed. A/B with
  `NEGRONIGL_PRECISION=0`.
- The Metal health is read from Metal's files; if NegroniMetal.mm changes its strike format or paths, `negroni_gpu_policy.c`
  must follow (both cite each other). The policy host test pins the format.
- A process killed by the user before its first GL frames gets a GL strike (2 in one boot = GL off for it in this boot).
