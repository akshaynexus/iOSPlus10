# AKS, AMFI and Sandbox patches (0220-0223)

These patches change the in-kernel stand-ins for AppleKeyStore, AMFI and Sandbox on negroni
(OnePlus 10 Pro, NE2211, iOS 16.7.16 20H392). All code is for the NEGRONI machine config only
(`ARM64_BOARD_CONFIG_NEGRONI` / `NEGRONI`).

Base: branch `base` of `out/kernel/xnu` (xnu-8796.141.3 + dxb + slop negroni patches, slop
64438bd). Work branch: `aks-amfi` in `out/kernel/wt-aks-amfi`, one commit per patch.

| Patch | Changes | Boot-arg to undo |
|---|---|---|
| `0220-negroni-aks-no-passcode.patch` | AKS answers "no passcode", key wrap/unwrap, quieter log | `negroniaks=` (bits), `negroniaks_log=1` |
| `0221-negroni-amfi-policy.patch` | MAC policy named `AMFI` (ops 0x5a, 0x60), `AppleMobileFileIntegrity` IOService | `negroniamfi=` (bits), `negroniamfi=0` = all off |
| `0222-negroni-sandbox-privileges.patch` | Sandbox grants privileges 1002, 1007, 12000 to system code | `negronisandbox=0` |
| `0223-negroni-sandbox-appex-container.patch` | Sandbox op 4 gives app extensions a container path | `negroniappex=0` |

Each patch applies alone on `base` with `git apply --check`. The full set
(0200-0202 + 0220-0223) applies in name order (tested 2026-10-24). 0221-0223 were made with
`git diff` from the previous commit, so their line numbers assume the earlier patches. `git apply`
finds the hunks at the offset. 0221 adds one entry to `iokit/KernelConfigTables.cpp` and one line
to `iokit/conf/files.arm64`, after the AppleKeyStore lines. A later patch that edits the same
lines can make 0221 fail to apply (prepare-src.sh then skips it with "SKIPPED").

## Observed problems (live kernel log of our phone)

- `NEGRONI AKS: securityd sel 10 arg0 0 in 2/32 out 1/40 -> 0xe00002c7`: key wrap is not
  supported, so keychain writes fail.
- Storms of `NEGRONI AKS: <proc> sel 17 ... -> 0x0` (contextstored, SpringBoard, coreduetd,
  corespeechd). The AKS answered lock state 0x4 and `sls` 0.
- `NEGRONI Sandbox: aggregated privilege 1002 denied`, `SpringBoard privilege 1007 denied`,
  `identityservicesd privilege 12000 denied`, `cloudd privilege 1002 denied`.
- Home screen widgets show "Waiting...".

## 0220: AppleKeyStore

File: `iokit/Kernel/arm/NegroniKeyStore.cpp`.

1. **No passcode.** Lock state (selector 7) and device state `ss` are 0x6 (bit 1 no passcode,
   bit 2 unlocked since boot). Device state `sls` is 3 (disabled = no passcode). Before: 0x4 and
   `sls` 0, a passcode device that is unlocked. ios-sailfish fixed the same selector-17 storm
   with these values. The values agree with HackiOS.
2. **Key wrap / unwrap (selectors 10 / 11).** Wrap input: 2 scalars (handle, class) and the key
   (1-64 bytes, inband). Output: 1 scalar (the class) and the wrapped key, 8 bytes longer.
   Format: `"HKwr"`, class byte, 3 zero bytes, key XOR `(0x5a + 37 * i)`. Unwrap checks the mark
   and returns the key. The format is the HackiOS / ios-flame format.
3. Selectors from HackiOS that the negroni AKS did not answer: 8 lock device and 32 lock device
   now (no-op), 100 assert promote and 115 prewarm (no-op), 23 bag UUID (fixed 16 bytes),
   31 configuration (DER `bd` 0, `gp` 0, `mua` 10), 40 generation (0). Selector 102 (first-unlock
   notification posted) is now remembered, and selector 103 returns it. Before, 103 always
   returned "not set".
4. Log: 5 lines per selector for successes and 5 for failures (sailfish 0180 logged 5 per
   selector). `negroniaks_log=1` logs every call.
5. Out-of-line output buffers (above 4096 bytes) are now wired (`prepare()` / `complete()`)
   around `writeBytes()`, as HackiOS does. Before, an unwired user buffer could get no data.

Boot-arg `negroniaks` (bit mask, default 3): bit 0 = no-passcode answers (clear: 0x4 / `sls` 0),
bit 1 = wrap/unwrap (clear: `kIOReturnUnsupported`, as before).

**Security implication.** There is no SEP and no secret on this device. The "wrapped" keys are
encoded, not encrypted. A person who can read the keychain database
(`/private/var/Keychains/keychain-2.db`) can decode every keychain item (Wi-Fi passwords, tokens).
The same is true for data protection: all classes are always available. Do not keep real
credentials on this phone. A fixed AES key in the kernel gives no more protection, because the
key is in the public kernel image. For this reason the patch uses the HackiOS format.

Keychain items that were written before this patch do not exist (writes failed). Items written
with this patch can only be read by a kernel with the same format (bit 1 set).

References: ios-sailfish `xnu/patches/0180-sailfish-idle-cache-pmap-aks.patch` (lock state,
`sls`, log limit), HackiOS `hackios-xnu-kernel/xnu/files/iokit/Kernel/MiniAppleKeyStore.cpp`
lines 29-56, 168-299 (selectors, wrap/unwrap, configuration), ios-flame
`xnu/patches/0123-flame-en0-apple80211-wifid-over-wland.patch` (wrap/unwrap in a SweetKeyStore).

## 0221: AMFI

Files: `bsd/kern/negroni_amfi.c`, new `iokit/Kernel/arm/NegroniAMFI.cpp`,
`iokit/KernelConfigTables.cpp`, `iokit/conf/files.arm64`.

The negroni tree had no equivalent. Its signature policy is named `NEGRONI AMFI`, so
`__mac_syscall("AMFI", ...)` got ENOPOLICY ("Policy not found"). There was no
`AppleMobileFileIntegrity` IOService.

1. **New MAC policy named exactly `AMFI`** (only `mpo_policy_syscall`; the `NEGRONI AMFI` policy
   does not change). The first use of each op is logged
   (`NEGRONI AMFI: <proc> __mac_syscall("AMFI", 0x..)`). Other ops return ENOPOLICY, as before.
   - **0x5a** `amfi_check_dyld_policy_self`, arg = `{u64 input flags; u64 *output}`. dyld asks
     this at each launch. An error means "allow nothing", and then every `@rpath`,
     `@executable_path` and `@loader_path` load fails ("security policy does not allow @ path
     expansion"). Apps and app extensions with embedded frameworks do not start. Answer
     (ios-flame 0114): `@` paths (0x1) always. Path variables, fallback paths, print variables,
     failed insertions, interposing and embedded variables (0xfa) unless the input says
     restricted (`__RESTRICT`, 0x2) or FairPlay encrypted (0x4). Custom shared cache (0x4 out)
     stays off.
   - **0x60** `amfi_interface_query_bootarg_state`, arg = `u64 *state`. Answer 0x86
     (bergamota 0099). ExtensionFoundation (lsd) then reads
     `/System/Library/xpc/extensions.plist` without the AMFI signature check. Before, the read
     failed ("Unable to find AMFI"), the extension point catalog was empty and no app extension
     was registered. bergamota `docs/EXTENSION_CACHE.md` shows this chain on 20H392, our build.
2. **`AppleMobileFileIntegrity` IOService** (ios-flame 0103), on IOResources. User client
   selector 6 (trust cache query, 1 scalar + cdhash) returns success = trusted. Other selectors
   are logged once and return `kIOReturnUnsupported`. ExtensionFoundation's
   `_EX_dictionaryWithSignedURL:` asks this service before it uses a signed cache.

Boot-arg `negroniamfi` (bit mask, default 7): bit 0 = op 0x5a, bit 1 = op 0x60, bit 2 = the
IOService. `negroniamfi=0` removes all of 0221 (the `AMFI` policy is not registered when bits 0
and 1 are clear).

Boot log lines: `NEGRONI AMFI: "AMFI" syscall policy (negroniamfi 0x7) registered (0)` and
`NEGRONI AMFI: AppleMobileFileIntegrity published (trust cache queries answer trusted)`.

References: ios-flame `xnu/patches/0114-flame-amfi-dyld-policy.patch`,
`xnu/patches/0103-flame-amfi-trust-query.patch`, `HANDOFF.md` lines 231-236 and 594-597;
ios-sailfish `xnu/patches/0139-sailfish-amfi-dyld-policy.patch` (simpler 0x5a answer 0x7b);
bergamota `xnu/patches/0099-sweet-amfi-named-policy.patch` (op 0x60, separate policy),
`xnu/patches/0131-ios18-arm64e-exec.patch` (0x5a struct layout), `docs/EXTENSION_CACHE.md`.

## 0222: Sandbox privileges

File: `bsd/kern/negroni_amfi.c`, `negroni_sandbox_priv_grant()`.

Meaning of the numbers (`bsd/sys/priv.h`) and the grant rule:

| Priv | Name | Kernel check | Denied for | Granted to |
|---|---|---|---|---|
| 1002 | `PRIV_GLOBAL_PROC_INFO` | `proc_info.c`: proc_info about processes of other users (read only) | aggregated, cloudd | platform binaries |
| 1007 | `PRIV_DARKBOOT` | `kern_sysctl.c`: write `kern.darkboot` (NVRAM flag that hides the boot progress UI at the next boot) | SpringBoard | platform binaries |
| 12000 | `PRIV_SKYWALK_REGISTER_USER_PIPE` | `skywalk/nexus/nexus.c`: register a Skywalk user pipe nexus | identityservicesd | processes with entitlement `com.apple.private.skywalk.register-user-pipe` |

The entitlement name for 12000 is the one that xnu `bsd/skywalk/core/skywalk.c` `sk_priv_chk()`
reports for this privilege. For 1002 and 1007 the entitlement names are not known (no iOS root
was available for this work), so the rule is "platform binary". On negroni every signed binary
on the root filesystem is a platform binary (`negroni_amfi_vnode_check_signature`).

The check uses the current process. The grant is given only when the credential asked about is
the credential of the current thread (credentials are shared, so the pointers are equal). The
first grant of each privilege is logged (`NEGRONI Sandbox: <proc> privilege <n> granted`).
Other privileges are denied and logged as before. `negronisandbox=0` removes the new grants.

Why this is safe: 1002 discloses process information only. 1007 sets a cosmetic boot flag.
12000 is given only to processes that Apple entitled for it.

## 0223: Sandbox op 4, container path for app extensions

File: `bsd/kern/negroni_amfi.c`, `negroni_sandbox_syscall()`.

Op 4 (container path of a pid), arg = `{int64 pid; 0; char *buf; u64 len; 0}`. Before, every
call returned ENOENT. PlugInKit's checkEnvironment then stops every app extension ("plugin has
invalid sandbox or container: error 2"). Now a process that runs as uid 501 (mobile) from an
executable inside a `.appex/` directory gets `/private/var/mobile`. All other processes get
ENOENT, like an uncontainerized process on iOS. `negroniappex=0` restores ENOENT for all.

This is a guess for the widget "Waiting..." problem: widgets are app extensions, and 0221
(catalog, @rpath) plus 0223 (container) remove the two known causes. It is not verified on our
phone.

Reference: ios-sailfish `xnu/patches/0110-sailfish-sandbox-container-path-appex.patch`.

## Reference commits

| Repo (`external/`) | Commit |
|---|---|
| ios-sailfish | 6f27e41ff249f2680540ebe8ee5ab982c5e641c9 |
| ios-flame | 745c4341af86089efb0df851fa8a27fb8face624 |
| bergamota | 0826e48c3d3f4bd9b0ab7d5af82ed92dfaeec425 |
| hackios-xnu-kernel | d82c64a3a31cd27a0a0afbf6e213e467e44b1b4c |

## Verification done

- `git apply --check` of each patch alone on `base`: OK. Full set 0200-0202 + 0220-0223 in name
  order: all applied.
- Single-file syntax check (`clang -fsyntax-only`, local Xcode clang) of `NegroniKeyStore.cpp`,
  `NegroniAMFI.cpp` and `negroni_amfi.c`. Flags: the CI build tree's recorded
  `out/kernel/buildtree/build/xnu.obj/DEVELOPMENT_ARM64_NEGRONI/{iokit,bsd}/DEVELOPMENT/.CFLAGS`
  with the CI paths changed to the worktree and build tree, run in that directory. C++ adds
  `-std=gnu++1z -fsized-deallocation -fapple-kext`. Result: no errors. The only warnings come
  from `OSDefineMetaClassAndStructors` and an old `strlcpy` line, the same as in the unchanged
  files.
- Not done: a full kernel build (needs Xcode 15, CI) and a boot test.

## What to check on the phone

1. Boot log: `NEGRONI AKS: AppleKeyStore registered (unlocked, lock state 0x6, key wrap on)`,
   the two `NEGRONI AMFI` lines above, `NEGRONI Sandbox: permissive policy registered`.
2. Selector-17 storm: at most 5 `sel 17` lines, and less CPU use by contextstored and
   coreduetd. If the clients still ask often, the storm has a different cause (the log limit
   hides it: use `negroniaks_log=1`).
3. Keychain: `securityd sel 10 ... -> 0x0` and `sel 11 ... -> 0x0`. Wi-Fi passwords stay saved
   after a reboot.
4. `__mac_syscall("AMFI", 0x5a)` and `0x60` lines. Apps with embedded frameworks start. No
   "Unable to find AMFI" or "Extension cache does not have an entry" in the unified log.
5. Widgets render (not "Waiting...").
6. `privilege 1002/1007/12000 granted` lines, no `denied` lines for them.

## Risks

- The selector numbers 8, 23, 31, 32, 40, 100, 115 come from HackiOS (iOS 16.5). The numbers
  that negroni and HackiOS both have agree, but these 7 are not verified on 16.7.16. A wrong
  number answers a different call with success. Log lines for them show the argument shapes.
- `sls` 3 / no passcode: Settings shows "no passcode". Code that requires a passcode (for
  example Apple Pay, some MDM paths) refuses, as on a real device without a passcode.
- 0x5a gives DYLD_* variables and interposing to every process that is not restricted or
  encrypted. That is development-device behaviour and makes injection easy.
- 0x60 = 0x86 also tells lsd and installd that code signing enforcement is off (bergamota: MI
  skips signature checks). This is the wanted behaviour here, but other users of op 0x60 are
  not known. Bit names of 0x86 are not known.
- The IOService trusts every cdhash.
- 1002 / 1007 go to all platform binaries. If third-party apps also count as platform binaries
  on this port (same root filesystem), they get them too. Impact is small (see 0222).
- 0223 puts all app extensions in the same container (`/private/var/mobile`), with no
  isolation between them.

## Integration notes

- Copy is done: the four patches are in `patches/xnu/`. `scripts/kernel/ci-build.sh` picks up
  `patches/xnu/*.patch` automatically.
- No root filesystem change is needed. The root tweak "ExtensionKit
  `enforce_xpc_cache_code_signing` off" (`scripts/ios16/root-tweaks-extra.py`) and 0221 op 0x60
  do the same thing. Both can stay.
- Do not mix kernels with and without 0220 bit 1 on the same userdata: keychain items written
  with wrap on cannot be read with wrap off.
- After the first boot with 0221/0223, LaunchServices databases built with the empty catalog
  can persist (bergamota Q3). If widgets still do not register, delete
  `/private/var/containers/Data/System/*/Library/Caches/com.apple.LaunchServices-*.csstore` and
  `/private/var/mobile/Library/Caches/com.apple.LaunchServices-*` (needs a root change; ask first).
- `docs/boot-speed.md` rows "AKS lock state..." and "AMFI policy named AMFI..." can move to
  "patch ready, needs a kernel build" after these are committed.
