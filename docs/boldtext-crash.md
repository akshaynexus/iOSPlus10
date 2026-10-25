# Bold Text crash loop

Status (2026-10-25): **root cause found** [V]. Bold Text on makes SpringBoard crash every ~7 s,
because CoreImage uses its OpenGL ES backend and there is no GL driver. The root we build keeps
Bold Text off. A CoreImage fallback is in work (`userland/cifix/`, separate agent); the real fix is
the GPU driver. Marks: **[V]** seen (source given), **[I]** inference. Full disassembly notes:
[notes.md](notes.md), section "CoreImage/PosterBoard crash".

## Evidence

Capture: `logs/usblog-20261024-235438.txt` (`make usblog`, owner turned Bold Text on). Symbols:
`scripts/debug/symbolicate.sh logs/usblog-20261024-235438.txt` (ipsw + the root's shared cache,
attached read-only). Re-run 2026-10-25 by the review: same result [V].

- SpringBoard: 106 crashes in the log, sig 11, pc 0 (a NULL call), slide 0x1f750000 [V].
- Backtrace (unslid) [V]:
  `CI::GLContext::init() + 204` (lr 0x194b3858c) <- `CI::GLContext::GLContext(...)` <-
  `+[CIContext(Internal) internalContextWithEAGLContext:options:]` <- `-[CIContext initWithOptions:]` <-
  `+[CIContext contextWithOptions:]` <- `+[CUIShapeEffectStack sharedCIContext]` (dispatch_once) <-
  `-[CUICatalog imageByStylingImage:stylePresetName:styleConfiguration:foregroundColor:scale:]` <-
  `-[UIImage _imageWithStylePresets:tintColor:traitCollection:]`.
- Cause in CoreImage: `-[EAGLContext getMacroContextPrivate]` returns NULL, `_wrapGetMacroContext`
  leaves the GL dispatch table zero, and `CI::GLContext::init` calls table+0xe8 (glDisable) [V, notes.md].
- iOS 16 CoreImage has only the Metal and GL backends; there is no CPU renderer.
  `kCIContextUseSoftwareRenderer` (which CoreUI passes) does not avoid GL [V, notes.md].
- Same lr 0x194b3858c as slop's 2026-10-22 SpringBoard loop without Bold Text (slop `NOTES.md:569`) [V].
  So any UIKit path that reaches CoreUI's shared CIContext can crash, in any app [V, notes.md].
- Why Bold Text triggers it [I]: with Bold Text on, UIKit asks CoreUI for styled glyph/image
  variants (`_imageWithStylePresets:`) during SpringBoard launch. With it off, the earlier log
  `logs/usblog-20261024-195455.txt` has no SpringBoard crash [V].

PosterBoard crashes too in the same log (20 times, sig 5): the assertion in
`-[PBFPosterExtensionDataStore _stateLock_setupSwitcherConfigurationForFirstTime] + 2040`, reached
from `-[PRSServer prewarmWithCompletion:]` [V]. That is a separate fault (poster extensions are not
discovered; see notes.md and slop `NOTES.md:800`). It does not depend on Bold Text [I].

## The preference

- Key: `EnhancedTextLegibilityEnabled` in domain `com.apple.Accessibility`, for the mobile user:
  `/private/var/mobile/Library/Preferences/com.apple.Accessibility.plist` [V: the only
  "EnhancedTextLegibilityEnabled" string in the 20H392 cache is in `libAccessibility.dylib`
  (`ipsw dyld str`), next to the string `com.apple.Accessibility`].
- `_AXSEnhanceTextLegibilityEnabledGlobal` 0x191998934 reads `kAXSEnhanceTextLegibilityPreference`
  with `_AXSGetPreferenceValue` and returns "value == 1". `_AXSSetEnhanceTextLegibilityEnabled`
  0x191998990 calls `_AXSSetEnhanceTextLegibilityEnabledApp(value, NULL)` (global) [V: `ipsw dyld
  disass --vaddr`]. There is also a per-app variant (`..._App`) [V symbols].
- Change notifications in libAccessibility: `com.apple.accessibility.text.legibility.status`,
  `com.apple.accessibility.cache.enhance.text.legibility` [V strings; that they are Darwin notify
  names is I].
- The switch exists in two Settings panes: `AccessibilitySettings.bundle` (`setBoldTextEnabled:specifier:`)
  and `DisplayAndBrightnessSettings` (in the shared cache) [V strings].

## Root default: `scripts/ios16/root-tweaks-boldtext.py`

`scripts/ios16/root-finish.sh` runs it on every root build (macOS `root-macos.sh` and Linux
`root-linux.sh` both call `root-finish.sh`, as root). It sets `EnhancedTextLegibilityEnabled = false`
in the binary plist above, keeps other keys, owner 501:501, mode 0600.

Review test 2026-10-25 [V]: on a copy of the built root's `Preferences` folder (from
`~/op10-apple/ios16-root.img`, read-only): two runs give the same file (same sha256); a plist with
`EnhancedTextLegibilityEnabled = true` and another key comes out `false` with the other key kept;
the output is `bplist00`, mode 0600, chown(501, 501) is called. The result is byte-identical to the
file in the current built root (sha256 `71639153...`).

It does not lock the switch. Turning Bold Text on still crashes SpringBoard until CoreImage works.

## Recovery when Bold Text was turned on

1. SSH still works during the SpringBoard loop (dropbear and the USB network do not need
   SpringBoard) [I: SpringBoard is not in their launch path; not tested in the loop]. Make the file
   on the host and copy it:
   ```
   mkdir -p /tmp/bt/private/var/mobile/Library/Preferences
   sudo python3 scripts/ios16/root-tweaks-boldtext.py /tmp/bt        # macOS or Linux (chown needs root)
   scripts/net/ssh-phone.sh push /tmp/bt/private/var/mobile/Library/Preferences/com.apple.Accessibility.plist /var/mobile/Library/Preferences/
   scripts/net/ssh-phone.sh 'chown 501:501 /var/mobile/Library/Preferences/com.apple.Accessibility.plist; chmod 600 /var/mobile/Library/Preferences/com.apple.Accessibility.plist; sync'
   scripts/net/ssh-phone.sh reboot
   ```
   This replaces the whole file (it may hold other accessibility settings). The reboot restarts
   cfprefsd, which caches preferences; the phone has no `killall` (toybox has only `kill`) [V:
   `out/ssh/ios/toybox.applets`, no `usr/bin/killall` in the root]. Not tested [I].
2. If SSH does not answer: re-flash `userdata` with a fresh root (Bold Text off), with the owner's
   approval: [flash-ios16.md](flash-ios16.md). This erases the iOS user data.

## Next steps

- CoreImage fallback (agent, `userland/cifix/`): hook points are listed in notes.md
  (`internalContextWithEAGLContext:options:`, the CoreUI flatten path). Note: launchd drops
  `DYLD_*` for `com.apple.*` jobs [V, notes.md], so injection needs another route.
- The GPU driver (EAGL on Mesa, `docs/gpu-userland.md`) removes the cause.
- Test after either fix: turn Bold Text on with `make usblog` running; expect no `CRASH SpringBoard` lines.
