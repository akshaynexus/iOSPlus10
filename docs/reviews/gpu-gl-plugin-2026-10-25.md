# GL renderer plugin (NegroniGL.bundle) work log, 2026-10-25

Agent: Opus "GL driver plugin". Scope: docs/gl-renderer-plugin.md, userland/negronigl/plugin/,
patches/xnu/0205-negroni-accel-plugins.patch, scripts/gpu/root-add-negronigl.sh, phone test plan in
docs/gpu-userland.md. [V] = verified (disassembly, build, run on the Mac), [I] = inference.

## 1. Patch 0205 (first, owner priority: Metal first)

- Tree: `scripts/kernel/patched-tree.sh out/kernel/tree-0205 0205` (tmux tree-0205, exit 0, 0 patches
  skipped, stops before 0210). Edit: `iokit/Kernel/arm/NegroniAccel.cpp` only; `git diff` = the patch.
- Properties set in `IOAcceleratorES::start` before `registerService()`:
  `IOGLESBundleName="NegroniGL"` (boot-arg `negronigl`, default 1), `MetalPluginName="NegroniMetal"` +
  `MetalPluginClassName="NegroniMTLDevice"` (boot-arg `negronimetal`, default 0).
- Build: `scripts/bg.sh kernel-gl scripts/kernel/build-local.sh` exit 0 [V]. Kernel
  `out/kernel/local-20261024-234223/kernel.development.negroni`; patch report: "Applying
  0205-negroni-accel-plugins.patch"; skipped only dxb's own TrustCache, iobuffermemd_monterey,
  skywalk_sonoma, syntax_checker_sonoma (as before). Strings `IOGLESBundleName`, `NegroniMTLDevice` and the
  new "NEGRONI ACCEL" line are in the kernel [V].
- Both plugins on one service [V, libGFXShared gfxInitializeLibrary 0x1d3f6e494..0x1d3f6e590]: GL reads
  `IOGLESBundleName` and `IOGLESMetalBundleName`; one present -> that one; both present -> CFPreferences
  `UseMetal` (domain `com.apple.opengl`) if set, else the `IOGLESDefaultUseMetal` CFBoolean (true -> Metal
  name). Metal reads only `MetalPluginName`/`MetalPluginClassName` (docs/metal-design.md). 0205 never sets
  `IOGLESMetalBundleName`, so the GL choice is always NegroniGL. Reported to the coordinator.

## 2. NegroniGL.bundle and softpipe (second GL agent, 2026-10-25)

- RE facts (gfxInitializeLibrary, GLD device/pixel format/sharegroup, EAGL's GLI use): docs/notes.md
  section 15, the bullets marked "second GL agent" [V].
- Coordinator decision: no GLEngine GLD renderer; the bundle gives EAGL the GLI entries on Mesa.
- Stopped part: the GLI source (EAGL context create/destroy, SetInteger/GetInteger with the
  0x38e/0x399 IOSurface texture, BindViewES/PresentViewES, and how the bundle hands that table to
  OpenGLES). A safety classifier stopped the write twice; the cut-off file was deleted and not
  written again. Until that part exists, `gldChoosePixelFormat` returns 0x2712 (EAGL contexts stay
  nil, the same as without the plugin). The owner must decide how this part gets written.
- Written [V build]: `sw_winsys.c` (softpipe display targets: memory, IOSurface by ID mapped with
  IOSurfaceLock), `ngl_init` driver choice (freedreno if RedwoodGPU opens, else softpipe;
  `NEGRONIGL_DRIVER`, boot-arg `negronigl_sw=1`), `surface.c` softpipe import + GL_RENDERBUFFER target,
  GLES 3.1 -> 3.0 fallback, `plugin/gld.c` (13 gld functions; driver ID 0x4e00; version 4.1.0x10),
  `plugin/gen-gld.py` (stubs for the other names: log once, 0x2717; export list), `plugin/Info.plist`.
- Build [V]: `scripts/bg.sh gpu-build scripts/gpu/build.sh` (Mesa freedreno + softpipe, no Vulkan;
  Turnip stays with turnip-build.sh): NegroniGL.bundle 129/129 table names + 2, arm64, minos 16.0,
  ad hoc signed; negronigl.dylib contains softpipe. Weak imports: pthread_mutexattr_{init,settype,destroy}
  (iOS 27.1 SDK markings; present on iOS 16 [I]).
- Installer [V fake root]: `scripts/gpu/root-add-negronigl.sh` (NEGRONIGL=1 hook in root-finish.sh,
  default off), `scripts/gpu/test-root-add-negronigl.sh` passed.
- Untested: everything on the phone. `ngl_test` (softpipe when no GPU) is the first phone check.
- Disk: deleted out/gpu/re/dsc.a2s (765 MB ipsw cache, regenerable).

## 3. GLI part written (GL GLI agent, 2026-10-25)

- The stopped part from section 2 is now written and builds. Files:
  - `plugin/gli_table.c`, `plugin/gli_context.c` (already committed in 6d3cfd1): reviewed against
    notes 15; both were correct. One fix: gli_context.c defined gliCreateContextWithShared,
    gliDestroyContext, gliSetInteger, gliGetInteger without `NGL_GLD`, so hidden visibility dropped
    them from the bundle exports once the file was compiled in (14/18). Added `NGL_GLD`; now 18/18.
  - `plugin/gli_view.c` (new, ~180 lines): gliBindViewES, gliPresentViewES, and the CGL-only
    gliAttachDrawable/gliAttachDrawableWithOptions no-ops (the dlsym loop needs all 18 non-NULL).
    gliBindViewES takes the drawable IOSurface from nativeWindow +0x18 and binds it as GL_RENDERBUFFER
    storage through surface.c; ngl_gli_view_unbind releases it on detach/destroy.
  - `plugin/gld.c`: gldChoosePixelFormat now returns `&ngl_pf` (was 0x2712).
  - `plugin/gen-gld.py`, `scripts/gpu/build.sh`: export and check the 18 `gli*` names.
  - `userland/negronigl/meson.build`: added `ngl_plugin_src` (gli_table/context/view) to the bundle.
- How the table reaches OpenGLES [V, out/gpu/re/OpenGLES.s + GLEngine.s]: eagl_init's dlsym loop at
  0x1d3f52648 reads `_gli_plugin[0]`, which ngl_gli_register already overwrote with our bundle handle,
  and binds our 18 exports into +0x08..+0x90. Details in notes section 15a.
- Build: `scripts/bg.sh gpu-build scripts/gpu/build.sh` exit 0; 129/129 GLD + 18/18 GLI exported;
  NegroniGL.bundle arm64, minos 16.0, ad hoc signed, codesign -v OK.
- Untested on the phone. ngl_test is an iOS binary, so the GLI entries cannot run on the Mac; the
  first exercise is on the phone (EAGLContext non-nil; Bold Text on SpringBoard must not crash).

## 4. Peer review of the GLI part (Opus review agent, 2026-10-25)

Scope: plugin/ (gli_table.c, gli_context.c, gli_view.c, gld.c, gen-gld.py), eagl.c ngl_bind,
negronigl.h, scripts/gpu/build.sh. Checked against out/gpu/re (OpenGLES, GLEngine, libGFXShared,
QuartzCore, CoreImage; 20H392, unslid). [V] = seen in the disassembly or the build, [I] = inference.

### 4.1 Claims checked

- [V] Call order is right. eagl_init stores GLEngine's dlopen handle at `_gli_plugin[0]`
  (0x1d3f52578), calls gliInitializeLibrary (`blr x20` 0x1d3f52630; GLEngine 0x1f6e96388 calls
  gfxInitializeLibrary synchronously), and only then the dlsym loop reads `[_gli_plugin]` again on
  every pass (0x1d3f52648). libGFXShared calls gldInitializeLibrary at 0x1d3f6e904, before the
  gldGetVersion check and the 129-name dlsym. So a write from gldInitializeLibrary is seen.
- [V] The memory is writable: eagl_init itself stores there (`str x0, [x23, #0xda0]`), it is
  OpenGLES `__DATA_DIRTY`.
- [V] Processes without GLEngine: gfxInitializeLibrary is reached only from GLEngine's
  gliInitializeLibrary (no other caller in the 7 disassembled images), and GLEngine is loaded only
  by eagl_init. A process that never makes an EAGLSharegroup never loads the bundle.
- [V] gliCreateContextWithShared args (pf = sharegroup +0x10, gfx shared state = +0x18, priv+0x28,
  priv+0x2088, flags), 0x38e/0x399 parameter layout, BindViewES/PresentViewES call sites: as written.
  Every sharegroup has its own gfx shared state, so "shared" names the sharegroup.
- [V] priv+0x2088 is the back table of GLCSelectDispatch/GLCRestoreDispatch (0x1d3f52a2c..);
  filling it with the same functions is harmless.

### 4.2 Findings (by severity) and fixes

1. **Critical [V]: the GLI table was never installed.** `gldInitializeLibrary` (gld.c) never called
   `ngl_gli_register`; nothing else did. eagl_init then bound GLEngine's own 18 entries, GLEngine's
   gliChoosePixelFormat got `&ngl_pf` from our gldChoosePixelFormat, and EAGL became "initialized"
   on GLEngine with our stub GLD renderer (exactly the case the old 0x2712 refusal avoided).
   Fix: gldInitializeLibrary calls `ngl_gli_register()` on every load (idempotent); build.sh fails
   if the call is missing. [V otool: `bl _ngl_gli_register` on both paths of gldInitializeLibrary.]
2. **High [V]: crash when the last EAGLSharegroup goes.** eagl_dealloc (0x1d3f52380), at refcount 0,
   does `dlsym(_gli_plugin[0], "gliTerminateLibrary")` and `blr x0` with no NULL check. The bundle
   did not export that name: pc 0 crash in any process that frees its last EAGL context.
   Fix: `gliTerminateLibrary` (gli_table.c), exported as a 19th GLI name (gen-gld.py GLI_EXTRA,
   build.sh check). It calls libGFXShared `gfxReleaseLibrary` (balances GLEngine's
   gfxInitializeLibrary: devices destroyed, plugin record dropped, bundle stays mapped by
   RTLD_NODELETE) and dlcloses the GLEngine handle we replaced. It does not call GLEngine's
   gliTerminateLibrary (its cvmPostTerm would run without cvmPreInit on this path) [I safe].
3. **High [V]: no re-install after terminate.** ngl_gli_register had a once-only latch. After a
   terminate the next eagl_init would bind GLEngine again. Fix: the latch is gone; register runs
   when `_gli_plugin[0]` is GLEngine's handle and `_eagl_initialized` is 0, skips when already ours.
   It also checks four code words of the 20H392 OpenGLES (EAGLGetVersion 0xb4000060, eagl_init
   0x1d3f52578 0xf906d2e0, 0x1d3f52644 0x913682b5 / 0xf94002a0) before it writes anything.
4. **High [V], item 2: gldChoosePixelFormat refuses again (0x2712).** Its only caller is GLEngine's
   gliChoosePixelFormat (plugin +0x468, GLEngine 0x1f6e96574; no read of +0x468 in libGFXShared,
   OpenGLES, libGLImage, libCoreVMClient, CoreImage, QuartzCore). The claim "libGFXShared may still
   ask the plugin for a format" is wrong: libGFXShared reads only pf+8 (device ID) in
   gfxCreateSharedState. So the path that now runs: our table installed -> our gliChoosePixelFormat
   -> ngl_pf -> gfxCreateSharedState(device 0x01024e00) -> gldCreateShareGroup -> our contexts.
   If the table is not installed, GLEngine's path fails cleanly in eagl_init (nil contexts, the old
   behaviour) and never drives the stub gld* functions.
5. **Medium [V]: use after free in sharegroups.** The share table kept the first context as "lead"
   until the whole sharegroup was empty; destroying the lead first left a freed pointer that the next
   context passed to st_api_create_context. Fix: a list of live contexts; a new context shares with
   any live one of the same shared state; the lock is held across ngl_create and destroy unlinks
   first. No 32-entry limit.
6. **Medium [V Mesa source]: destroy on another thread.** gliDestroyContext freed a context that may
   be current on another thread; Mesa's next `_mesa_make_current` there reads the old context
   (context.c:1482), and the TLS pointer could match a new context at the same address. Fix:
   per-context bind count (eagl.c ngl_bind -> ngl_gli_bound, plugin build only); such a context is
   marked and freed when its last thread switches away. [I] A thread that exits with it current
   leaks it.
7. **Medium [V]: BindViewES could never succeed.** CA's begin_iosurface (+0x18, 0x188469a30) returns
   NULL until the window is attached (+0x08 sets bit 1 of +0x84), and PresentViewES never handed
   the frame to CA. Fix (gli_view.c): attach(nw, 'BGRA', {ctx, create -> 1, destroy, preflight NULL})
   like GLEngine 0x1f6f57940 (CA null-checks preflight, 0x18846a1b0; attach takes a reference at
   +0x80, so the window stays valid until detach), begin_properties, begin_iosurface, renderbuffer
   storage; present = glFinish, swap(nw, version >= 5 && t ? (after ? 5 : 3) : 1, t) as GLEngine
   0x1f6f57e94, then the next begin_iosurface surface becomes the renderbuffer storage. Detach on
   unbind and destroy. gliPresentViewES takes the double (d0) now.
8. **Low [V]: GLCGetProfilerStorage (0x1d3f5299c) reads 8 bytes** from gliGetInteger(0x7aa); we wrote
   4 (garbage pointer). Fix: 0x7aa writes a NULL pointer.
9. **Low [V]: -setBlockFence:onQueue: (0x263/0x264) was accepted** but the block is never called; a
   caller could wait forever. Fix: refuse (the method returns NO).

### 4.3 CoreImage (item 4)

- [V] CI::GLContext makes two EAGLContexts (API 3, else 2; the second shares with the first,
  0x194b388c8..0x194b38914), calls GL only through `_wrapGetMacroContext` (x0 = priv+0x20, function
  = [priv+0x28 + 8*slot], 0x194b329ec). With findings 1-5 fixed, these contexts are Mesa contexts
  (softpipe without the GPU) and the table at priv+0x28 is ngl_dispatch, so `CI::GLContext::init`
  no longer calls a zero table. [I] Not run: whether every GL call CI makes renders right.
- [I] If Mesa cannot make even a GLES 2 context, the context is nil and CI crashes as before.

### 4.4 Still open

- [I] 0x399 invert is ignored (CI/CA inverted renders come out flipped).
- [I] Sharegroup objects die with the last context of the sharegroup (Apple keeps them while the
  EAGLSharegroup lives).
- [I] Drawable rotation flags (begin_properties bit 2) are not applied; all drawables are 'BGRA'.
- [I] surface.c checks `glGetError()` after the EGLImage call and so eats an earlier app error.
- [I] All of it is untested on the phone. The CAEAGLLayer path follows CA/GLEngine code read in
  the disassembly only.

### 4.5 Build

- [V] `scripts/bg.sh gpu-build scripts/gpu/build.sh` exit 0: 129/129 GLD + 18/18 GLI names +
  gliTerminateLibrary + gldInitializeLibrary/gldTerminateLibrary, no other exports; arm64,
  minos 16.0, codesign -v OK; NegroniGL 14,896,288 bytes, sha256 2bde3c82...

### 4.6 First phone checks

1. Log line "GLI table installed in OpenGLES _gli_plugin" in the first process that makes an
   EAGLContext, then "EAGLContext GLI ... on Mesa". A line "gldChoosePixelFormat: GLEngine path"
   means the install failed.
2. A test that creates and releases an EAGLContext twice in one process: no crash at release
   (gliTerminateLibrary), and the second create gets "GLI table installed" again.
3. Bold Text on with `make usblog`: no SpringBoard crash in CI::GLContext::init.
