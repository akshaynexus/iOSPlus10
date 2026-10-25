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
