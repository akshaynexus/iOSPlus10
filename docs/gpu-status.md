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
| Software fallback (Mesa softpipe) | partly written, not built (notes 15): driver choice, softpipe winsys, 13 gld functions. The GLI-side file that connects EAGL to Mesa is missing: safety filters stopped two agent runs while they wrote it. Waits for the owner |
| Vulkan (Turnip) | links; needs review and the parts Metal uses |
| Metal plugin + probes | build (iOS 16 arm64, Xcode 27.1 and 15.4); plugin logic passes a host test on the Mac (MoltenVK); not run on the phone. Fast refusals (no RedwoodGPU, no Turnip, `negronimetal=0`), open + IOSurface self-test under a 6 s deadline, frontend gaps for QuartzCore closed (patch flame/0001) |
| QuartzCore shaders (host, metal2vulkan) | A730 estimate profile: kernels 7/7, vertex 39/39, fragment 93/95 (2 need pixel interlock, Turnip lacks it); bare Vulkan 1.2: fragment 75/95 |
| Display scanout of rendered frames without a CPU copy | planned (ios-s9 / bergamota show the method) |

## Agents (2026-10-25)

| Work | Agent | Output |
|---|---|---|
| OpenGL ES driver, plugin loading, softpipe fallback, patch 0205 | Opus "GL driver plugin" | `userland/negronigl/`, `scripts/gpu/`, `docs/reviews/gpu-userland-gl-2026-10-25.md` |
| Vulkan + Metal | Opus "Turnip + Metal" | `userland/metal/`, `scripts/metal/`, `docs/reviews/gpu-turnip-metal-2026-10-25.md` |
| Kernel round 2: memory import for Vulkan, per-client GPU address space, display scanout | Opus "GPU kernel round 2" | `patches/xnu/0232+`, `docs/gpu-abi.md` |

## Test on the phone (after the next flash)

1. `ngl_test` over SSH with the software fallback.
2. Bold Text on: SpringBoard must not crash.
3. GPU path: boot-args `negroniadreno=22 negroniadreno_keep=1`; `ngl_test`, then the UI.
4. Vulkan/Metal probes: `scripts/metal/phone-test.sh`.
