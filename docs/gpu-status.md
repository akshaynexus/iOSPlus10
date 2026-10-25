# GPU acceleration: status and work plan

The phone has an Adreno 730 GPU. iOS draws its UI on the CPU today, so the UI is slow. This page
is the single record of the GPU driver work: what exists, who works on it, and what comes next.
Details: [gpu-plan.md](gpu-plan.md), [gpu-abi.md](gpu-abi.md), [gpu-userland.md](gpu-userland.md),
[metal-plan.md](metal-plan.md), [metal-design.md](metal-design.md), `patches/xnu/README-gpu-kernel.md`.

## How it works

The design follows the other ports that have a working GPU on the same iOS build (ios-sailfish:
OpenGL ES on Adreno 530; ios-flame: Metal on Adreno 640).

| Layer | Part | Source |
|---|---|---|
| Kernel GPU driver | power, clocks, GMU, firmware, command ring, buffers, fences | slop negroni patches (A730 bring-up) + ours 0230 |
| Kernel display | panel memory, 120 Hz vsync, brightness, GPU copy of finished frames to the panel | slop 0046/0056/0061 + ours 0231, 0250, 0251 |
| User-client interface | the calls between the kernel and the user-space driver | [gpu-abi.md](gpu-abi.md) |
| OpenGL ES driver | Mesa freedreno (open source, MIT) + the EAGL layer that iOS uses | `userland/negronigl/` |
| Vulkan driver | Mesa Turnip (open source, MIT) | built from the same Mesa tree |
| Metal | a Metal device plugin that translates Metal to Vulkan (metal2vulkan) | `userland/metal/` |

iOS finds GPU drivers through the kernel service `IOAcceleratorES`: its properties name the driver
plugins that the system frameworks load (Metal: `MetalPluginName`; OpenGL ES: `IOGLESBundleName`, a GLD
renderer plugin in /System/Library/Extensions that Apple's GLEngine drives: notes section 15). Our kernel publishes this service
(0201), and patch 0205 adds the plugin names. So the drivers load the normal way, in every process.

Order of work (owner's decision, 2026-10-25): **Metal first, OpenGL ES second.** CoreAnimation and
CoreImage try Metal before OpenGL ES, so a working NegroniMetal device accelerates the whole UI, apps and
newer iOS versions; ios-flame drew the 20H392 home screen this way (Metal -> metal2vulkan -> Turnip).
The OpenGL ES plugin (with Mesa softpipe) is the fallback when Metal fails or is turned off
(`negronimetal=0`). Kernel defaults (0205): `negronimetal=1` (Metal on), `negronigl=1` (GL fallback on).
When NegroniMetal is missing or returns no device, CoreAnimation/CoreImage use EAGL -> NegroniGL. Safety: the Metal plugin's allow-list, crash counter and boot-arg prevent a black UI.

## Status (2026-10-25)

| Part | State |
|---|---|
| Kernel GPU user client, IOSurface import (0230) | written, builds, not run on the phone |
| GPU present at 120 Hz (0231, rebased on slop 120 Hz) | written, builds, not run on the phone |
| 120 Hz vsync (slop) | builds; the phone still runs a 60 Hz kernel |
| OpenGL ES driver (negronigl) | builds; CoreAnimation cannot draw through it yet (renderbuffer step fails) |
| Software fallback (Mesa softpipe) | builds (2026-10-25): negronigl.dylib + NegroniGL.bundle (129/129 GLD names, 13 real gld functions), softpipe when RedwoodGPU does not open; not run on the phone. The GLI part that connects EAGL to Mesa is not written (safety filters stopped it twice); until then gldChoosePixelFormat refuses and EAGL contexts stay nil. Waits for the owner |
| Vulkan (Turnip) | builds (2026-10-25, `scripts/gpu/turnip-build.sh`, patch `userland/turnip/mesa-patches/0001`): chained fixups, no `dyld_stub_binder`, exports `redwood_drm_note_surface`; import check vs 20H392 PASS; msm ABI; host import = noted IOSurfaces by ID (0x7e), other pages by USERPTR 0x49 (0232), HOST_CACHED types only; not run on the phone |
| Metal plugin + probes | build (iOS 16 arm64, Xcode 27.1 and 15.4); plugin logic passes a host test on the Mac (MoltenVK); not run on the phone. Fast refusals (no RedwoodGPU, no Turnip, `negronimetal=0`), open + IOSurface self-test under a 6 s deadline, frontend gaps for QuartzCore closed (patch flame/0001) |
| QuartzCore shaders (host, metal2vulkan) | A730 estimate profile: kernels 7/7, vertex 39/39, fragment 93/95 (2 need pixel interlock, Turnip lacks it); bare Vulkan 1.2: fragment 75/95 |
| Host-memory import for Turnip (0232, msm 0x49 USERPTR) | written, builds, not run on the phone |
| Per-client GPU tables (0233, boot-arg `negronigpu_pt=1`, default 0) | written, builds, not run; CPU-switched TTBR0 (CP_SMMU_TABLE_UPDATE not usable without the TrustZone aperture call) |
| Zero-copy scanout at 120 Hz (0234, boot-arg `negronifb_zerocopy=1`, default 0) | written, builds, not run; the boot always logs the display engine's registers (read only) for the first check |

## Agents (2026-10-25)

| Work | Agent | Output |
|---|---|---|
| OpenGL ES driver, plugin loading, softpipe fallback, patch 0205 | Opus "GL driver plugin" | `userland/negronigl/`, `scripts/gpu/`, `docs/reviews/gpu-userland-gl-2026-10-25.md` |
| Vulkan + Metal | Opus "Turnip + Metal" | `userland/metal/`, `scripts/metal/`, `docs/reviews/gpu-turnip-metal-2026-10-25.md` |
| Kernel round 2: memory import for Vulkan, per-client GPU address space, display scanout | Opus "GPU kernel round 2" | `patches/xnu/0232+`, `docs/gpu-abi.md` |

## Test on the phone (after the next flash)

Kernel round 2 (0232-0234): `patches/xnu/README-gpu-kernel.md` section 11 (DPU probe lines first,
then `negronifb_zerocopy=1`, then `negronigpu_pt=1`).


1. `ngl_test` over SSH with the software fallback (`NEGRONIGL_DRIVER=softpipe` forces it).
2. Bold Text on: SpringBoard must not crash.
3. GPU path: boot-args `negroniadreno=22 negroniadreno_keep=1`; `ngl_test`, then the UI.
4. Vulkan/Metal probes: `scripts/metal/phone-test.sh`.

## Open items (2026-10-25)

- Cache maintenance after GPU writes into an imported IOSurface: checked 2026-10-25, no change needed. The frontend's
  `flushSurfaces` calls `sys_dcache_flush` for every IOSurface a command buffer uses, at commit and after completion
  (before completed handlers and before `waitUntilCompleted` returns, so before the self-test's IOSurfaceLock read).
  libSystem's `sys_dcache_flush` is only `dsb ish` on 20H392 arm64 [V: disassembly], but `NegroniMetal.mm` defines its
  own (`dc civac` per 64-byte line, `dsb sy`) and the static link binds the frontend's and the bridge's calls to it
  [V: `nm -u` has no `_sys_dcache_flush`, 3 call sites in the bundle]. Turnip's `vkInvalidateMappedMemoryRanges` is the
  same EL0 `dc civac` loop (`tu_bo_sync_cache`), not CPU_PREP; Turnip never calls CPU_PREP (GL does, `negroni_drm.c`).
  Untested on the phone: needs EL0 cache maintenance (SCTLR_EL1.UCI) on our kernel; a trap there is SIGILL.
- Turnip: 4222 weak flat-namespace lookups at load (cost not measured); submit EBUSY with negronigpu_pt=1 may show as
  "device lost" [I].
