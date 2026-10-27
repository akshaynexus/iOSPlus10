# AKS, AMFI and Sandbox patches (0220-0223, 0221-aks-passcode)

These patches change the in-kernel stand-ins for AppleKeyStore, AMFI and Sandbox on negroni
(OnePlus 10 Pro, NE2211, iOS 16.7.16 20H392). All code is for the NEGRONI machine config only
(`ARM64_BOARD_CONFIG_NEGRONI` / `NEGRONI`).

Base: branch `base` of `out/kernel/xnu` (xnu-8796.141.3 + dxb + slop negroni patches, slop
64438bd). Work branch: `aks-amfi` in `out/kernel/wt-aks-amfi`, one commit per patch.

| Patch | Changes | Boot-arg to undo |
|---|---|---|
| `0220-negroni-aks-no-passcode.patch` | AKS answers "no passcode", key wrap/unwrap, quieter log | `negroniaks=` (bits), `negroniaks_log=1` |
| `0221-negroni-aks-passcode.patch` | AKS software keybag: set / change / remove a passcode, lock screen, survives reboots (section "0221 passcode" below) | `negroniaks=3` (bit 2 off), `negroniaks_reset=1` (forget the passcode for one boot) |
| `0221-negroni-amfi-policy.patch` | MAC policy named `AMFI` (ops 0x5a, 0x60), `AppleMobileFileIntegrity` IOService | `negroniamfi=` (bits), `negroniamfi=0` = all off |
| `0222-negroni-sandbox-privileges.patch` | Sandbox grants privileges 1002, 1007, 12000 to system code | `negronisandbox=0` |
| `0223-negroni-sandbox-appex-container.patch` | Sandbox op 4 gives app extensions a container path | `negroniappex=0` |
| `0386-negroni-sandbox-extensions.patch` | Sandbox op 5 issues a fixed extension token, op 6 accepts any (tccd "Failed to issue Sandbox Extension", Camera.app not authorized; section "0386" below) | `negronisbext=0` |

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

## 0221 passcode: software keybag (`0221-negroni-aks-passcode.patch`)

Files: `iokit/Kernel/arm/NegroniKeyStore.cpp`, new `iokit/Kernel/arm/NegroniKeyStoreCore.h` (plain C: hash, compare,
blob, DER integers). The file name sorts before `0221-negroni-amfi-policy.patch`, so it applies directly on 0220.
Owner report (2026-10-27): "passcodes can't be turned on at all". Settings > Passcode > Turn Passcode On failed.

### Why it failed [V]

- keybagd changes the passcode with `aks_change_secret` = selector 15. 0220 answered `kIOReturnUnsupported` for 15
  (and for 3, 5 with a real handle, 6, 30, 42, 87, 105). No boot log has a `sel 15` line [V: grep of all
  logs/usblog-*.txt], so the owner's try probably stopped earlier or in a boot without a log [I]; in any case keybagd
  could not succeed without selector 15.
- 0220 always answered "no passcode" (lock state 0x6, sls 3). `MCPasscodeManager isPasscodeSet` is
  `MKBGetDeviceLockState() != 3` [V: ManagedConfiguration 20H392, `-[MCPasscodeManager isPasscodeSet]`], so even a
  successful change would show "off".

### Call chain and selector map [V: disassembly of the 20H392 dyld cache and keybagd]

Tools: `ipsw dyld disass out/dsc/cache/dyld_shared_cache_arm64 --image AppleKeyStore|MobileKeyBag|ManagedConfiguration`,
`ipsw macho disass` of `/usr/libexec/keybagd`, `/usr/libexec/profiled` and
`/System/Library/UserEventPlugins/MobileKeyBagLockState.plugin` from `~/op10-apple/ios16-root.img` (attached read-only).
The output is in `out/aks/` (git-ignored).

Settings -> `MCProfileConnection changePasscodeFrom:to:outError:` -> XPC `changePasscode:oldPasscode:completion:` to
profiled -> `MCPasscodeManagerWriter changePasscodeFrom:to:outError:` (restriction check, `isDeviceUnlocked` = sls 0
or 3, passcode history, then) `MKBKeyBagChangeSystemSecret(old, new, opaque)` -> XPC to keybagd
`-[KBXPCService changeSystemSecretfromOldSecret:...]` (entitlement `com.apple.keystore.device`) ->
`KBChangeSystemSecret` (keybagd 0x100003c88) -> `KBChangeSystemNonSeSecret` (0x1000059f0). libaks is linked
statically into keybagd. Every libaks call is `IOConnectCallMethod` on `AppleKeyStore`:

| Sel | libaks function | In | Out | Caller / use |
|---|---|---|---|---|
| 2 | `aks_create_bag` | 6 scalars {type, -1, pass ptr, pass len, 0, 0} | 1 scalar handle | user bags (not on our path) |
| 3 | `aks_save_bag` | 1 scalar {handle} | struct, 32 KiB buffer (out of line) | keybagd `KBSaveSystemBagHandle` |
| 4 | `aks_unload_bag` | 1 scalar {handle} | - | after set_system |
| 5 | `aks_set_system(_with_passcode)` | 4 scalars {handle, system handle, pass ptr, pass len} | - | boot load, passcode change |
| 6 | `aks_load_bag` | struct = blob | 1 scalar handle | keybagd `load_devicebag` |
| 7 | `aks_get_lock_state` | 1 scalar {handle} | 1 scalar | everybody |
| 8 / 32 | `aks_lock_device(handle, now)` | 1 scalar | - | SpringBoard `lockSkippingGracePeriod:` (32 = "LockDeviceNow") |
| 9 | `aks_unlock_device` | 3 scalars {handle, pass ptr, pass len} | - | SpringBoard `MKBUnlockDevice` |
| 12 | `aks_unlock_bag` | 3 scalars {handle, pass ptr, pass len} | - | - |
| 13 | `aks_lock_bag` | 1 scalar | - | - |
| 14 | `aks_get_system` | 0 or 1 scalar | 1 scalar handle; `kIOReturnNotFound` = load the file (0221 never answers it) | keybagd |
| 15 | `aks_change_secret(_se)` | 11 scalars {handle, flags, 0xff, old ptr, old len, new ptr, new len, 0, 0, 0, 0} | 1 scalar handle | keybagd |
| 17 / 35 | `aks_get_(extended_)device_state` | 1 scalar | DER, 4 KiB buffer | `MKBGetDeviceLockState` = "sls" |
| 30 | `aks_set_configuration` | 3 scalars {handle, DER ptr, DER len} | - | `MKBDeviceSetGracePeriod` ("gp") |
| 31 | `aks_get_configuration` | 1 scalar | DER, 32 KiB buffer | profiled, SpringBoard ("mua") |
| 42 | `aks_verify_password` | 1 scalar + struct {u32 count; per item u32 len, bytes padded to 4} | - | `MKBVerifyPasswordWithContext` |
| 87 | `aks_invalidate_bag` | struct = old blob | - | after a change (failure only logged) |
| 105 | `aks_change_secret_epilogue` | 3 scalars {handle, new ptr, new len} | - | after set_system |

Passcode pointers are user addresses in the calling process (keybagd, SpringBoard); the kernel reads them with
`copyin`. Other selectors that keybagd links (stash 0x21-0x25, SE 0x45-0x5f, personas 0x60-0x62, backup 0x14-0x16,
0x6e-0x71) are not on the passcode path and stay unsupported.

`KBChangeSystemSecret` with system handle 0: reads systembag.kb (old blob), asks the lock state; bit 13 (SE bound)
clear -> non-SE path; `KBisxARTBasedKeyBag` = lock state bit 22, clear -> "two phase":
`change_secret(0, old, new, flags 4)` -> new handle T; `KBSaveSystemBagHandle(T)` = `save_bag(T)` and write
`/private/var/keybags/systembag.kb` = plist {KeyBagKeys = blob, KeyBagVersion}; plain plist because the ADT has
`/defaults no-effaceable-storage` (slop mkadt.py); `set_system(T, 0, new)`; `change_secret_epilogue(0, new)`;
`unload_bag(T)`; `invalidate_bag(old blob)`. keybagd maps 0xe00002e2 and 0xe00002ce to "-3 wrong passcode".

Boot: keybagd `load_devicebag`: `get_system` -> if 0xe00002f0 (NotFound): read systembag.kb, `load_bag(KeyBagKeys)`
-> h, `set_system(h, 0, NULL, 0)`, `unload_bag(h)`, `get_system` again. Any failure there calls
`FATAL KEYBAG ERROR` -> NVRAM `auto-boot=false` + `reboot()` [V: keybagd 0x100012228].

Lock events: `MobileKeyBagLockState.plugin` (UserEventAgent) registers `IOGeneralInterest` on AppleKeyStore.
Message 0xe3ffd00d -> `notify_post("com.apple.mobile.keybagd.lock_status")`; 0xe3ffd00f -> post
`com.apple.mobile.keybagd.first_unlock` once (selectors 103 / 102); 0xe3ffd00c -> passcode threshold. At its
start it posts first_unlock only when lock state bit 2 (unlocked since boot) is set.

### What 0221 does

- Software keybag: system bag (handle 0; every handle outside 0x1000-0x1fff, e.g. the device handle -3) + 16
  temporary bags (handle 0x1000 + generation * 16 + slot; a stale or unknown temporary handle is refused). A bag holds: passcode set yes/no,
  PBKDF2 iterations (20000), random 16-byte salt (`read_random`), 32-byte PBKDF2-HMAC-SHA256 hash, grace period,
  UUID. The passcode itself is never stored or logged; buffers are zeroed after use; compare is constant time.
- Blob for keybagd (128 bytes, `NegroniKeyStoreCore.h`): "NAKS", version 1, flags, iterations, grace, salt, hash,
  UUID, SHA-256 checksum. `load_bag` (6) never fails: a foreign blob (slop's "SWEET"), a damaged blob or
  `negroniaks_reset=1` gives a bag without a passcode, and the log says which.
- Boot load: `get_system` (14) always answers handle 0, as 0220 did. It never answers kIOReturnNotFound, so keybagd
  never takes its own file-load path (`load_devicebag`), where any failure is `FATAL KEYBAG ERROR` + reboot. At
  keybagd's first selector 14 (once per boot) the kernel reads `/private/var/keybags/systembag.kb` itself
  (`vnode_lookup` first: only a regular file is opened, never a FIFO or a device; then `vnode_open` with
  `O_NOFOLLOW | O_NONBLOCK` + `vn_rdwr` in keybagd's thread and credentials, type checked again, no symlink, max 64 KiB; `systembag.kb.writing` when the file is
  missing or empty, as keybagd does) and searches it for a valid blob of ours (`nks_find_blob`: raw bytes = binary
  plist, which keybagd writes with `CFPropertyListWrite` format 200; base64 in `<data>` = XML plist). No file, a
  read error, slop's "SWEET", a damaged blob or `negroniaks_reset=1` = a bag without a passcode. So with no passcode
  the boot path is exactly the 0220 one.
- Lock state: no passcode -> 0x6 / sls 3 as in 0220. Passcode set: bit 0 locked, bit 2 unlocked since boot;
  sls 0 unlocked, 1 locked. After a boot with a passcode: 0x1 / sls 1 until the first unlock.
- `change_secret` (15) checks the old passcode (no passcode: anything), hashes the new one with a new salt; empty
  new passcode = passcode off. Flag 4 puts the result in a new temporary bag, else in place.
- `unlock_device` (9) / `unlock_bag` (12) / `verify_password` (42): wrong passcode -> 0xe00002e2
  (kIOReturnNotPermitted). Wrong passcodes at 9 / 12 count (since the last unlock; a reboot clears the count).
  Device state "sfa" reports at most 9 = "mua" - 1: SpringBoard
  (`-[SBFUserAuthenticationModelSEP _refreshStateForMkbState:notify:]`) marks the device permanently blocked
  ("connect to iTunes"), or asks for a wipe with "Erase Data" on, when sfa >= mua (10) [V: SBF disassembly]. So
  wrong passcodes never block or erase the phone. Backoff "sb" stays 0: no kernel delays, no "try again in N
  minutes" (a lock-screen gate only, see Security). `verify_password` reads only the first packed item (the
  passcode), so a large second item does not fail the call.
- `lock_device` 32 and `lock_bag` lock now; 8 locks after the grace period from `set_configuration` "gp"
  (0 = now; the deadline uses `mach_continuous_time`, checked when somebody asks the state).
- Only keybagd may use the selectors that change or export bags (2, 3, 5, 6, 15, 87, 105); others get the 0220
  answer (5: success without a change; the others kIOReturnUnsupported) and a log line
  `<proc> may not use selector N (keybagd only): 0220 answer` (first 10). Unlock, lock, verify and configuration
  stay open (SpringBoard, Settings).
- Interest messages 0xe3ffd00d on every lock state change and 0xe3ffd00f at the first unlock after boot, sent
  after the AKS lock is dropped.
- Log lines (always): `keybagd: system bag from /private/var/keybags/systembag.kb (N bytes, error E): ...,
  lock state 0x..`, `system bag set (passcode set|no passcode, change, lock state 0x..)`,
  `change secret: passcode set|removed`,
  `change secret: old passcode wrong`, `unlock: wrong passcode (n since the last unlock)`, `unlocked (first unlock
  since boot)`, `grace period N s`.
- Boot-args: `negroniaks` bit 2 (default on; default mask is now 7): clear = 0220 behaviour (no passcode,
  selector 14 always a handle, passcode selectors unsupported). `negroniaks_reset=1`: the loaded bag counts as
  "no passcode" for this boot.

**Security.** This is a lock-screen gate, not data protection. There is no SEP and no hardware key: class keys
(wrap/unwrap 10/11, 0220) do not depend on the passcode, files are not encrypted (HFS+ without cprotect), and
the salt + hash are in a plain plist in /private/var/keybags. With root (SSH) a 6-digit passcode can be found by a
brute force of 10^6 PBKDF2 runs. Do not enable "Erase Data" (keybagd/SpringBoard wipe logic is not tested here).

Review 2 (Opus, 2026-10-27): defects fixed. D1: the keybagd file-load path (14 = NotFound) ran on every boot
because the root has slop's systembag.kb ("SWEET"), so 0221 changed the boot with no passcode, and any keybagd
failure there = FATAL KEYBAG reboot loop; now the kernel reads the file (above). D2: "sfa" could reach "mua" ->
SpringBoard permanent block or wipe request; now capped at 9. D3: `verify_password` refused a packed input over
648 bytes; now reads a prefix. D4: other processes got kIOReturnNotPrivileged where 0220 answered; now the 0220
answer. Host test extended: blob search in binary/XML plists (python3 plistlib), damaged/SWEET/3000 random files,
built with ASan + UBSan.

Review (Fable, low effort): ACCEPT WITH FIXES. Applied: stale/unknown temporary handles refused + generation in
the handle (F1), keybagd-only gate (F2), zeroing on a copyin error (F3). Not changed: the grace-period lock is
noticed at the next state query (F4; SpringBoard asks often); selector 23 keeps the fixed UUID (F5; securityd may
cache it); "Erase Data" note above (F6: device state reports the failed count, "mua" is 10).

Host test: `scripts/kernel/test-aks-core.sh` takes `NegroniKeyStoreCore.h` out of the patch and runs
`tools/aks-core-test/aks_core_test.c`: HMAC (RFC 4231 + 200 random cases vs CommonCrypto/OpenSSL), PBKDF2 (RFC 7914
+ 6 cases vs `CCKeyDerivationPBKDF`/`PKCS5_PBKDF2_HMAC`), set/verify (right, wrong, empty, prefix, longer), blob
round trip, 128 one-bit corruptions refused, "SWEET" refused, DER integers 0..0xffffffff, blob search in a
keybag file (binary + XML plist from python3 plistlib found; damaged, truncated, SWEET, 3000 random files refused).
Built with AddressSanitizer + UBSan when the compiler has them.

### Test steps for the owner

1. Boot the image with this kernel. Log (make usblog / grep -a 'NEGRONI AKS'): `AppleKeyStore registered (...
   passcode on)`, `keybagd: system bag from /private/var/keybags/systembag.kb (N bytes, error 0): no NEGRONI bag
   in it: no passcode, lock state 0x6` (slop's "SWEET"). No `sel 6` line at boot. The phone boots as before, no
   lock screen passcode.
2. Settings > Passcode (Face ID & Passcode / Touch ID & Passcode) > Turn Passcode On, enter a passcode twice.
   Expect `change secret: passcode set (handle 0x0 flags 0x4 -> 0x10..)`, `sel 3` (save), `system bag set (passcode
   set, change, lock state 0x4)`. Settings shows "Turn Passcode Off" / "Change Passcode".
3. Lock with the side button, wake: the lock screen asks for the passcode. A wrong one: `unlock: wrong passcode`.
   The right one opens.
   Check the file: `scripts/net/ssh-phone.sh 'ls -l /private/var/keybags/'` (systembag.kb changed now).
4. Reboot (`scripts/net/ssh-phone.sh reboot`). Expect `keybagd: system bag from ... (N bytes, error 0): passcode
   set, lock state 0x1`. The lock screen asks before the first unlock; after it:
   `unlocked (first unlock since boot)`. Wrong passcodes 10+ times: still asks, never "disabled".
5. Settings > Passcode > Turn Passcode Off, enter the passcode: `change secret: passcode removed`, lock state 0x6.
   Reboot: `keybagd: system bag from ...: no passcode, lock state 0x6`.
If step 2 still fails: send the log lines with `NEGRONI AKS` and `/var/logs/keybagd.log` if it exists
(`scripts/net/ssh-phone.sh pull /var/logs/keybagd.log logs/`).

### Recovery (never locked out)

- Forget the passcode for one boot: add `negroniaks_reset=1` to the boot-args (fastboot boot). The lock screen does
  not ask. To make it permanent: Settings > Turn Passcode On with a new passcode, then Turn Passcode Off (keybagd
  writes a bag without a passcode), or keep the new passcode.
- Turn all of 0221 off: `negroniaks=3` (the 0220 behaviour: no passcode; keybagd does not load the file).
- Over SSH (dropbear runs as root and does not wait for an unlock [I]): `scripts/net/ssh-phone.sh 'rm -f
  /private/var/keybags/systembag.kb /private/var/keybags/systembag.kb.writing'`, then reboot. Without the file the
  kernel uses a bag without a passcode; keybagd still gets handle 0 (it never reads the file at boot).
- A forgotten passcode or a lock screen that does not accept it: reboot (the failure count is in RAM only), or boot
  once with `negroniaks_reset=1` / `negroniaks=3`.

### Risks

- [I] The kernel reads the file at keybagd's first selector 14 (keybagd --init, `load_devicebag`). If /private/var
  is not mounted then, the read fails and the passcode is off for that boot (fail-open, logged with the error).
- [I] The XPC handle for the change is 0 or -3 (`keybagd 0x1000123d0`, persona check). With -3 keybagd saves to the
  user bag path, not systembag.kb: the passcode would work until the next reboot and then be gone (fail-open).
- [V] keybagd uses `LockoutState.plist` only in `MKBDeviceLockModelEducationalMode` (shared iPad), not here. The
  SpringBoard lock model reads sfa / sb / mua from AKS: with sfa capped at 9 and sb 0 it never blocks.
- [I] Daemons that wait for the first unlock (class C keychain items, `first_unlock` notification) now wait after a
  reboot with a passcode until the owner unlocks. That is the iOS behaviour; SSH (dropbear, root) does not wait.
- Not verified on the phone: everything in this section is from disassembly and a host test.

### wifid "device hasn't been unlocked since boot" (2026-10-27 phone log, kernel with 0220)

[V] wifid (`/usr/sbin/wifid`, 20H392) keeps `manager->unlockedSinceBoot` (manager + 0x528). `WiFiManagerCreate`
sets it from a global that is not from AKS (false), so the first `WiFiManagerSetPowerExt` always logs "hasn't been
unlocked since boot. Overriding power state to OFF". `WiFiManagerScheduleWithQueue` then calls
`MKBUserUnlockedSinceBoot(0)` = `aks_get_lock_state(0)` (selector 7) bit 2, and on true logs "First unlock since
launch" and turns Wi-Fi on; the `com.apple.mobile.keybagd.lock_status` handler does the same later. With 0220
(0x6) the answer is already true: logs/phone-log-20261027-025305.txt has "First unlock since launch",
"Turning WiFiManager ON" and "unlockedSinceBoot TRUE" at 14:24:26. The 50 s gap (14:23:36.43 -> 14:24:26.18) is a
stall inside `WiFiManagerScheduleWithQueue` before its first log line, not the AKS answer [I: the last wifid line
before it is "The connection to ACDAccountStore was invalidated" at 14:24:21].
With 0221: no passcode = 0x6 from boot (bit 2 set); with a passcode bit 2 is set at the first unlock, and the kernel
sends 0xe3ffd00d (-> lock_status, wifid re-checks) and 0xe3ffd00f (-> first_unlock). bluetoothd, locationd and apsd
use the `com.apple.mobile.keybagd.first_unlock` notification (locationd also lock_status) [V: strings]; the
UserEventAgent plugin posts it at its start when bit 2 is set, else on 0xe3ffd00f. No code change was needed.

## 0386: Sandbox ops 5 and 6, extension issue and consume (2026-10-27)

File: `bsd/kern/negroni_amfi.c`, `negroni_sandbox_extension_issue()`, `negroni_sandbox_syscall()`.

- [V log] `logs/camlog6-full.txt` 05:42:04: tccd grants kTCCServiceCamera/Microphone to Camera.app (authValue 2) and
  then replies `Failed to issue Sandbox Extension` (kTCCErrorDomain 6). AVFCapture treats that as denied:
  `Creating an AVCaptureDeviceInput ... failed: -11852 "This app is not authorized to use Back Camera"`. The session
  runs with no input, so no stream starts. tccd fails the same way for sharingd/contactsd (AddressBook) and Safari.
- [V disasm 20H392] `__sandbox_extension_issue` (libsystem_sandbox 0x1d1af4f98) mallocs 0x800 bytes and calls
  `__sandbox_ms("Sandbox", 5, {class, type (0 file, 1 mach, 3 generic), data, flags, token_buf, pid, pidversion})`; the policy writes the token string into
  `token_buf` (offset 0x20). `sandbox_extension_consume` (0x1d1af4ecc) calls op 6 with `{token, length, &handle}`
  and returns the handle (0 when the policy writes nothing) on success.
- Before: ENOENT for both. Now: op 5 copies out a fixed token of the usual shape, op 6 returns 0. Without a sandbox an
  extension grants nothing, so this only removes the error. `negronisbext=0` restores ENOENT.
- [I] Same fix for other services that tccd issues extensions for (AddressBook, Photos, Microphone).
- Built: syntax check only (`scripts/kernel/compile-one.sh`, OK). Applies on the current patched tree
  (`git apply --check` on `out/kernel/tree-airdrop`). Not booted.
