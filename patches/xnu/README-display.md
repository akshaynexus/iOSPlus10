# Display pipe requirements: patch 0388 `0388-negroni-fb-display-pipe-dicts.patch`

Status (2026-10-27): kernel code done, full kernel compile clean (`out/kernel/local-20261027-131907/kernel.development.negroni`,
sha256 7c5829e09949bb2aa3cf06b9d2c23246510512905090683ba9dc36e6d50d766d; all patches through 0388). Not tested on the phone.
Not reviewed yet.
Applies after 0253 (same `AppleCLCD::start` context). Other framebuffer patches: `README-gpu-kernel.md` (0234, 0252-0256, ...),
`README-brightness.md` (0250, 0251, 0258).

## Problem [V]

slop 0046/0061 (kept by our 0250/0253) publish `"DisplayPipePlaneBaseAlignment" = 64` (a number) on `AppleCLCD`.
VideoToolbox reads it as a dictionary without a type check. Each image-queue sink (camera preview, and [I] AVPlayer,
AVSampleBufferDisplayLayer) throws `-[__NSCFNumber objectForKey:]` (docs/camera-ios-2026-10-27.md section 11;
docs/notes.md section 75).

## Readers in the 20H392 dyld shared cache [V]

Search: raw grep of all `out/dsc/cache/dyld_shared_cache_arm64*` files for `DisplayPipe*`, `PlaneBaseAlignment*`,
`StrideLinear*`, `StrideTiled*`. Only two images have the strings: VideoToolbox and QuartzCore. No `...Tiled` key exists.
IOMobileFramebuffer, CoreMedia, MediaToolbox, AVFoundation, IOSurface and backboardd have none of the strings.
(`DisplayPipeRequiresPacked10BitPixelFormatForP3Input` in CMCapture is a capture-source property, not a registry key.)
Xrefs: `ipsw dyld xref` on the `__cfstring` entries.

| Reader | Property | How it parses | Keys | Value if missing |
|--------|----------|---------------|------|------------------|
| VideoToolbox `FigGetAlignmentForIOSurfaceOutputToDisplayService` (0x194f3b410) | `DisplayPipePlaneBaseAlignment` | `IORegistryEntrySearchCFProperty` on the `getH3clcdService` service (`AppleCLCD`, then `AppleCLCD2`, `AppleRGBOUT`); `CFDictionaryGetValue` with **no type check** of the property; the value must be a CFNumber (`CFGetTypeID` check), read as SInt64 | `PlaneBaseAlignmentLinear` | 64 |
| same function | `DisplayPipeStrideRequirements` | same (no type check of the property) | `StrideLinearHorizontal` | 64 |
| QuartzCore `CA::WindowServer::AppleDisplay::AppleDisplay` (+3724..+3868) | `DisplayPipeStrideRequirements` | `copy_display_property(..., CFDictionaryGetTypeID())`: `IOMobileFramebufferCopyProperty`, else `IORegistryEntrySearchCFProperty`; drops a non-dictionary | `StrideLinearHorizontal` -> `this+0xa10`, `StrideLinearVertical` -> `this+0xa18` (0 = keep default) | 64, 1 |
| same | `DisplayPipePlaneBaseAlignment` | same (dictionary only) | `PlaneBaseAlignmentLinear` -> `this+0xa08` (0 = keep default) | 64 |

VideoToolbox caches both answers in statics (`_planeBaseRequirement`, `_strideRequirement`) per process.
QuartzCore defaults: `stur q0` with {64, 64} at `this+0xa08`, then {1, 0x1000} at `this+0xa18` (constant at 0x18855bfd0).
So QuartzCore ignored our old number; the dictionaries give it the same values as its defaults.

## Real device (iPhone X, D22) [I]

No D22 ioreg/ADT dump with these properties is in the repo, in `external/` or in `out/src/hackios-next`. All other ports
(ios-flame, bergamota, ios-sweet, ios-apollo) copy the same number 64 from slop. [I] Real AppleCLCD publishes both as
dictionaries (both Apple readers expect that). The values here are the readers' own defaults (64 / 64 / 1), so they are
safe even if the real D22 values differ.

## Change

`iokit/Kernel/arm/NegroniFramebuffer.cpp`: new `negroni_fb_publish_pipe_reqs()`, called in `AppleCLCD::start` where the
number was set:

- `DisplayPipePlaneBaseAlignment = {PlaneBaseAlignmentLinear = 64}`
- `DisplayPipeStrideRequirements = {StrideLinearHorizontal = 64, StrideLinearVertical = 1}`
- Self-check: both properties are read back (dictionary, OSNumber, value). On a failure (no memory, setProperty,
  read-back) both properties are removed (the readers then use the same defaults, no exception) and the log says why:
  `NEGRONI FB: display pipe: off: <reason>; properties removed ...`.
- Success log: `NEGRONI FB: display pipe: DisplayPipePlaneBaseAlignment {PlaneBaseAlignmentLinear=64}, ...`.
- Kill switch `negronifb_pipedict=0`: the old number 64 (VideoToolbox image-queue sinks throw again).

No kernel code reads the property (grep of the patched tree: one setter only). Our userland reader is
`userland/camera/media_hooks.c` `seed_display_alignment()`: it writes 64 into the VideoToolbox statics before the first
read. It still works with this patch (same value) and can be removed after the test below.

## Test

1. `ioreg -l -w0 -c AppleCLCD | grep DisplayPipe` (read-only, `scripts/net/ssh-phone.sh`):
   `"DisplayPipePlaneBaseAlignment" = {"PlaneBaseAlignmentLinear"=64}` and
   `"DisplayPipeStrideRequirements" = {"StrideLinearHorizontal"=64,"StrideLinearVertical"=1}`.
2. Boot log: the `NEGRONI FB: display pipe:` line (not `off`).
3. Camera.app with the plug-in: preview as before. Then with `seed_display_alignment()` disabled (or the plug-in
   seeding skipped): no `UNCAUGHT EXCEPTION -[__NSCFNumber objectForKey:]`, preview shows.
4. A video in Safari and in Photos plays (AVPlayer image queue): no `objectForKey:` exception in mediaserverd/the app.
5. SpringBoard/backboardd: no visual change (QuartzCore gets its own defaults).

## Risks

- [I] If a reader not found here (a kext, or a binary outside the shared cache) reads the property as a number, it now
  gets a dictionary. Search covered only the shared cache; `/usr/sbin`, `/usr/libexec` and app binaries outside the
  cache are not searched.
- The values are defaults, not measured D22 values. If later work needs a real stride requirement (e.g. our DPU scanout
  of client surfaces), change `NEGRONI_FB_STRIDE_*`; QuartzCore then aligns its display surfaces to it.
