# Safari WebGL blank canvas (2026-10-27)

Owner's report: "anything animated in safari what uses threejs, webgl whatever is blank and refuses to render".
[V] = read or ran it. [I] = inference. Phone: Metal on for every process (clients `*`), kernel 20H392 root, plugin
`out/metal/stage` sha256 `7473f41b…ed628` (the same file is installed on the phone).

## 1. Diagnosis

Tools made for this (all in the repo):
- `scripts/net/phone-open-url.sh URL` + `userland/uiopen/uiopen.m`: opens a URL in Safari over SSH (LSApplicationWorkspace
  `openSensitiveURL:`, entitlements in `uiopen.entitlements`). No tap needed. [V] works: SpringBoard log "Trusting entitled client uiopen".
- `scripts/metal/webgl-test.sh` + `userland/metal/webtest/webgl-test.html` + `scripts/metal/webgl-report-server.py`: serves a WebGL
  probe page from the Mac on the USB link (192.168.7.1:8765), opens it in Safari, the page reports every result back as
  `/report?...` lines (context, renderer, draw read-back, 60-frame time). Log: `logs/webgl-test-<time>.log`.
- `scripts/metal/angleprobe.sh` + `userland/metal/probes/angleprobe.m`: WebKit's WebGL path (ANGLE Metal back end,
  `libANGLE-shared.dylib` of the 20H392 WebCore framework) as a CLI run as root, so metal.log shows what the GPU process does.
  A watchdog prints the main-thread backtrace after `ANGLEPROBE_TIMEOUT_S` (default 15 s).

What the page saw [V] (`logs/webgl-test-20261027-004402.log`):
```
webgl context=ok renderer="null" vendor="null" version="null" glsl="null"
onerror TypeError: Argument 1 ('shader') to WebGLRenderingContext.shaderSource must be an instance of WebGLShader
```
`getContext('webgl')` returns an object, every call answers null: a context that is lost from the start (WebKit's
RemoteGraphicsContextGL proxy whose GPU-process side failed). Second run: the GPU process (pid 638) was killed 3 s after the
page load: unified log `GPUProcessProxy::didBecomeUnresponsive: GPUProcess with PID 638 became unresponsive, terminating it` [V].
No `CRASH` line for it in usblog (SIGKILL by Safari, not a fault), no `refused`, `MISSING` or `uncaught exception` line in
metal.log for the GPU process, no ANGLE pipeline in its `pipelines.log` (only CoreAnimation draws) [V]. The WebContent
processes never ask for a Metal device (no NMTL line for them on the console) [V]: WebGL runs in `com.apple.WebKit.GPU` here.

angleprobe [V] (`logs/angleprobe-20261027-005213.log`): `eglGetPlatformDisplayEXT(METAL)` returns no display with
`eglError 0x3000` (EGL_SUCCESS), and the plugin's device opened inside that call (185 ms). So ANGLE created the system
device, asked it something, and decided "no Metal renderer".

Disassembly of the 20H392 `libANGLE-shared.dylib` (`ipsw dyld disass` on `out/dsc/cache`, saved in `out/metal/angle/`) [V]:
`egl::Display::GetDisplayFromNativeDisplay` calls `angle::IsMetalRendererAvailable()` before `rx::CreateMetalDisplay`;
`IsMetalRendererAvailable` is:
```
device = MTLCreateSystemDefaultDevice(); if (!device) return NO;
gpuFamilySufficient = [device supportsFeatureSet:4];     // MTLFeatureSet_iOS_GPUFamily3_v1 (A9, iOS 9)
(cached in a static: asked once per process)
```
The flame frontend answers every feature set with NO: `NativeBridgeMetalFrontend.mm:1787`
`- (BOOL)supportsFeatureSet:(MTLFeatureSet)set {(void)set;return NO;}` (while `supportsFamily:` answers YES for Apple1-3 and
Common1-2, journal `F` lines) [V].

**Cause: ours (d/a-class, a device answer), not metal2vulkan.** ANGLE never makes an EGL display on our device, WebKit's
GraphicsContextGL creation fails, the page gets a lost WebGL context, the canvas stays blank. The static cache means the GPU
process never retries until it is relaunched. The "unresponsive" kill of the second run is a second symptom to re-check
after the fix (it may be WebKit's handling of the failed creation under a sync IPC).

Not the cause [V]: the clients gate (the GPU process opens the device: `device Turnip Adreno (TM) 730 in 536 ms` for pid 638),
refused formats or MSL compiles (no such line), feature flags (no `/System/Library/FeatureFlags/Domain/WebKit.plist`; the
`UseGPUProcessForWebGLEnabled` key exists in the cache; WebGL in the GPU process is the observed behaviour).

## 2. Fix (flame/0014)

`supportsFeatureSet:` answers YES for the iOS feature sets of GPU families 1-3 (values 0-10, 12-14: the families
`supportsFamily:` already answers YES for) and NO for family 4 and 5 (11, 15, 16) and every macOS/tvOS set.

Result with flame/0014 (plugin sha256 `77a92ea1…11fa`, pushed with `scripts/metal/phone-test.sh push`) [V]:
- `scripts/metal/angleprobe.sh --es2` passes end to end (`logs/angleprobe-20261027-005918.log`): EGL 1.5 display, ES 3.0 context
  `ANGLE Metal Renderer: Turnip Adreno (TM) 730`, both shaders compiled through the MSL front end (`newLibraryWithSource #1 ... 2602 ms`,
  `#2 ... 4548 ms`, the first compile of each; cached after), red triangle read back, IOSurface pbuffer path PASS.
- Safari (WebKit processes killed, respawned with the new plugin): the GPU process now makes the display and encodes, then dies:
  `MISSING NBRenderEncoder -setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:` -> `uncaught exception NSInvalidArgumentException`
  from `rx::mtl::RenderCommandEncoder::endEncodingImpl` <- `ContextMtl::endRenderEncoding` <- `ContextMtl::flush` (symbolicated with
  `ipsw dyld a2s`). Before that: `command buffer refused: renderCommandEncoder: ... RenderPass(ResolveWithoutTexture(Depth))` twice:
  the frontend dropped `resolveTexture` of every pass attachment, and ANGLE's MSAA default framebuffer resolves depth in the pass.
  The page got `glError=37442` (CONTEXT_LOST_WEBGL).

## 3. Fix 2 (flame/0015, bridge + frontend)

`userland/metal/patches/flame/0015-negroni-angle-render-pass.patch` (3 files): `NmbPassAttachment` carries the resolve target
(`resolve_texture/_level/_slice/_depth_plane` -> the runtime's `resolve_*`), three late store-action calls
`nmb_render_set_{color,depth,stencil}_store_action` over the runtime's `set_*_store_action` (the runtime already handles
`MTLStoreActionUnknown` + late store), and in the frontend: resolve textures passed through, `setColorStoreAction:atIndex:`,
`setDepthStoreAction:`, `setStencilStoreAction:` (the `*Options:` forms are no-ops), the `...SamplerStates:withRange:` forms and the
LOD-clamp sampler forms on the render and compute encoders (clamps not carried: the sampler's own `lod_min/lod_max`; a narrowing clamp
is logged once). The struct grows at the end, so the bridge is rebuilt (`scripts/metal/build-bridge.sh`) with the plugin.

## 4. Upstream metal2vulkan (stage 2) [V]

`git -C external/metal2vulkan fetch origin` (no checkout): our pin `720ef1ce` (2026-10-14) is an ancestor of `origin/master` =
`origin/development` = `f6a96b7d` (2026-10-26); **688 commits** after the pin (666 in `crates/`), 0 local commits ahead. By subject:
texture 100, format 69, completion/fence/event 43, argument buffer/indirect 40, blit 25, IOSurface 7, present/drawable 3, MSL 4.
Churn in the files our m2v patches touch (ios-flame's 0001-0005, 0100-0101 and our m2v/0001-0003): `runtime/src/render.rs` 70
commits, `command_buffer/mod.rs` 65, `device/mod.rs` 43, `driver_facts.rs` 26, `pipeline/compile.rs` 26, `buffer.rs` 22,
`policy.rs` 20, ... (none of the patched files was deleted). A rebase means re-doing those patches by hand against 2 weeks of
upstream churn: not done here. **The blank canvas is ours** (device answer, missing selectors, dropped resolve textures); nothing in
the upstream list targets it (the runtime at our pin already has late store actions and resolve attachments). Upstream IOSurface work
(2026-10-23..26: a texture over an IOSurface whose GPU rows share bytes, present copies) is worth a look later for the compositing path,
after the plugin side is stable. The old pin stays.

## 5. Result with flame/0014 + flame/0015 [V]

Plugin sha256 `4ce4478477faef64c265c5a3aa393f49d1bcc90fc7434d6e3a8dcd13512222fa` (bridge rebuilt, `scripts/metal/build.sh` exit 0,
check-imports clean), pushed with `scripts/metal/phone-test.sh push`, WebKit GPU + WebContent processes killed (Safari respawned them).
`scripts/metal/webgl-test.sh` (`logs/webgl-test-20261027-010618.log`):
```
webgl  context=ok renderer="Apple GPU" version="WebGL 1.0"  lost=false exts=27 drawingBuffer=256x256 antialias=true depth=true
webgl2 context=ok renderer="Apple GPU" version="WebGL 2.0"  lost=false exts=16
webgl  draw center=255,0,0,255 corner=0,0,255,255 glError=0      webgl2 draw center=255,0,0,255 corner=0,0,255,255 glError=0
webgl 60 frames in 6531 ms (cold), 3956 ms (2nd run)     webgl2 60 frames in 4135 ms (cold), 1504 ms (2nd run)
```
GPU process pid 1228 unchanged over 4 page loads and the three.js keyframes example (`https://threejs.org/examples/#webgl_animation_keyframes`,
opened with phone-open-url.sh), no `CRASH com.apple.WebKit*` in usblog, no `refused`/`MISSING`/`uncaught` line for pid 1228 in metal.log.
The GPU journal shows ANGLE's pipelines (`samples=4`: the MSAA default framebuffer, resolved in the pass) compiling at 0.65-1.2 s each on
the three.js page: the first seconds of a heavy page are pipeline compiles (shader cache warms them for the next load).

Not proven: what the screen shows (no screenshot path from the Mac; the owner looks). Frame rate of real pages: the probe page's
60 frames took 1.5 s (WebGL 2, warm) to 4 s (WebGL 1, warm), so animation is visible but not 60 Hz; the per-pipeline compile time
(0.1-1.2 s, `pipelines.log` `R` lines) dominates the first seconds of every new page.

## 6. Owner steps

1. Safari: open `https://get.webgl.org` (spinning cube), then `https://threejs.org/examples/#webgl_animation_keyframes`,
   `https://webglsamples.org/aquarium/aquarium.html`. Expect drawing within a few seconds (first load compiles pipelines).
2. If a page stays blank: `scripts/net/ssh-phone.sh "ps -A | grep WebKit.GPU"` (a new pid = the GPU process died or was killed),
   `scripts/net/ssh-phone.sh "grep -a 'MISSING\|uncaught\|refused' /private/var/db/negronimetal/metal.log | tail"`, and
   `scripts/net/phone-log.sh -g GPUProcessProxy` for `didBecomeUnresponsive`. A `MISSING NBRenderEncoder -<selector>` line names the next
   selector to add to the frontend (flame patch, like 0015).
3. The plugin on the phone is the pushed one (survives until userdata is flashed again); `scripts/ios16/root-update.sh` / the metal
   root hook take `out/metal/stage` as is, so a new root gets it.
