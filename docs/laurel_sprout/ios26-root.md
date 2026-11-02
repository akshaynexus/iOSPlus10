# Mi A3 iOS 26 root: HFS+ image, built on Linux

Date: 2026-11-02. **Host only. This root has never booted. Nothing was written to a device.** Labels: [V] measured here, [I] inference, [U] unknown.

```sh
scripts/bg.sh ios26-root scripts/laurel/ios26-root.sh         # make laurel-ios26-root
scripts/bg.sh ios26-again scripts/laurel/ios26-root-again.sh  # same bytes proof: build twice, third run must stop
python3 -I scripts/laurel/ios26-root-spec.py --self-test      # the hooks: air, Metal, debug, parity; no donor files
```

Inputs: `DEV=n104ap` output of `scripts/ios26/fetch-os.sh`, `sysos-tree.sh`, `lower-userland.sh` (`ios26-userland.md` section 2). No sudo: read-only `apfs-fuse` mounts, `udisksctl` for the kernel mount. The negroni path is `scripts/ios26/root-macos.sh`; this build does not touch it.

Output (Apple content, never in git): `~/op10-apple/ios26/23F84-n104ap/root/ios26-root.img`, `.manifest`, `report.txt`. Link: `out/ios26/root-n104ap`. Writing it to the phone is another step (`scripts/laurel/dual-boot.sh install`), and not done.

## 1. Result [V]

| Item | Value |
|---|---|
| Area | 32 GiB = 34,359,738,368 bytes (owner decision) |
| Volume | **34,354,491,392 bytes** (`IOS26_VOLUME_BYTES`, `scripts/lib/laurel-layout.sh`). `iosroot` holds it with the console log; margin 401,584,128 bytes (dual-boot.md section 2). The extent table is in the ADT, not the area |
| Real size on the host | About 18 GB (sparse) |
| SHA-256 | `3e2eed0a099bc9c8eb08fcda3d94feaac12a09f0ba30c6c8863dde5d52f8bc22`, the same in three full builds (the last one after the air hook went into the spec script, an input of the build). A run with no change stops at "inputs unchanged" |
| Content | 237,286 files, 2,705 symlinks, 231,112 folders, 17,510 MiB |
| Free for `/private/var` | 14,253 MiB. `/private/var` is in the same volume |
| `op10tool hfs-verify` | 237,286 SHA-256 match; extents do not overlap; bitmap exact |
| `fsck.hfsplus -f -n` | OK. Only the known line "Volume header needs minor repair", which a fresh `mkfs.hfsplus -J` also gives |
| Real kernel read-only mount | 471,103 of 471,103 entries: type, mode, size or target. 0 extra, 0 differ. Owner is forced by the mount, so `hfs-verify` checks owner in the catalog |
| Layout | 11 of 11 paths |
| SHA-256 through the mount | 85 cache files, launchd, dyld, launchd.plist, 3,000 sample files: 5,124 MiB, 0 differ |
| Trust data | 7,090 entries, 3,490 new from the lowering, 56 with no original attribute. **The kernel does not read this file**: trust caches are off, built-in AMFI marks each signed file of the root |

## 2. Layout

| Path | Content |
|---|---|
| `/` | OS volume |
| `/private/preboot/Cryptexes/OS`, `/App` | SystemOS and AppOS volumes |
| `/System/Library/Caches/com.apple.dyld` | The lowered cache, real files. dyld looks here when libignition is skipped (kernel: `dyld_flags` 0x8) |
| `/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld` | Symlink to the above (iOS 16: hard links) |
| A file only in a cryptex | Symlink at its root path. A path under a symlink of the OS volume is skipped: the root path works already |

The writer (`tools/op10tool/src/hfs.rs`) makes HFSX with journal flags set, so XNU makes the journal at mount. No hard links: a file with more than one APFS link becomes one copy per path. Extended attributes are not copied, as `rsync -aH` on iOS 16. Names are decomposed UTF-16, `:` stored as `/`.

Same inputs, same bytes: the build hashes the spec, the changed files and each lowered file. A read that gets EIO from `apfs-fuse` under load tries again.

## 3. Tweaks: audit per item

`report.txt` and `/usr/share/laurel/ios26-root-audit.txt` have one line per item: `applied`, `kept`, `not-found` or `built`, with the reason.

- launchd: `_PanicOnCrash` renamed in 9 jobs; CommCenter, the iOS 16 list, aned and three programs dropped; `CA_HEARTBEAT_RATE` 60 [U on 26]; `launchd.plist.sig` kept (it does not match, the same as the iOS 16 root that boots); cryptexd kept [U].
- Containers, logd stores, plain system keybag, InterfaceNamer 10 s, MediaToolbox, jetsam widget limit: applied.
- Preferences: key names of iOS 16; each marked [U] where 26 was not read.
- `activation data ark`: **not-found**. The 23F84 OS volume has no mobileactivationd system container. The kernel path stays; enough on 26: [U].

Features of the iOS 16 root on this one, with the table of all of them: [ios26-parity.md](ios26-parity.md). Each is one hook and one audit line; what is off says why in `report.txt`. SSH and debugging: section 4.2.

## 4. AirDrop and AirPlay hook

`ios26-root-spec.py` function `air()` calls `scripts/laurel/root-air-ios26.sh STAGE` (branch `t3/laurel-ios26-airdrop`, not merged here).

- This build has no writable mount. So the script runs on a stage with the launchd.plist of this tree. What it leaves goes into the image, owner 0:0. A job it took out loses its plist too.
- The script is not in the tree: no change, same bytes. So the image above has none of these parts.
- The script fails (for example its binaries are not built): the root builds without them, with an audit line `off`.

Tests [V]: `--self-test` 10 of 10 with a stand-in script (files, owners, a removed job, a failure, a missing script). The real script of `origin/t3/laurel-ios26-airdrop` on the real launchd.plist with `AWDL=0 AIRPLAY=0` gave 3 files, 677 jobs before and after. **With the switches on it was not run:** `out/laurel/awdl` and `out/laurel/airplay` are not built on this host.

After the merge: build those binaries, then `FORCE=1 scripts/laurel/ios26-root.sh`. The image changes, and the proof of section 1 must run again.

## 4.1 Metal hook

`ios26-root-spec.py` function `metal()` runs `scripts/laurel/root-add-metal-ios26.sh STAGE`. Input: `out/ios26/metal/stage` of the same checkout (`METAL_STAGE` selects another). Docs: `ios26-metal.md` section 9.

- The stage has the jetsam plists, so the script edits them. What it leaves goes into the image, owner 0:0, modes as the script set them (`cache`, `strikes` 1777, `stack` 777, `metal.log` 666). The `com.apple.backboardd` preference goes through `merge_pref`, owner mobile.
- No stage, or a failure: the root is built **with no compositor**, one audit line `off metal26`, and `ios26-root.sh` prints that line at its end. Read it. 23F84 has no GL path, so such a root shows no picture.
- **The sizes and hash in section 1 are from before this hook. The image changes.** Run `scripts/laurel/ios26-root-again.sh` again for the same-bytes proof.

Test [V]: `--self-test`: `metal hook self-test: 15 of 15` with the real script on the real stage (bytes, owners, modes, clients, preference, no second stack), no backboardd, no stage. The jetsam step alone, on the plist of the last root: `146 extension limits raised`. **The full root with this hook was not built:** the owner rebuilds it.

## 4.2 Debug hook (SSH without a picture)

`ios26-root-spec.py` function `debug()` runs `scripts/laurel/root-debug-ios26.sh STAGE` before `air()` and `metal()`. It needs neither, and their failure does not remove it. What, why and what to read: `ios26-first-boot.md`.

- The script uses `scripts/net/root-add-ssh.py` of iOS 16 with `SSH_IOS26=1` (default off: the iOS 16 root does not change). Stage input: launchd.plist, the account files, the list of stock commands of this tree. Binaries: `out/ssh/ios` of this checkout, else of the main checkout, and `out/laurel/debug/ios/ksysctl`.
- One audit line each: `debug ssh`, `debug login`, `debug usb network`, `debug tools`, `debug jobs`, `debug-ios26`, then `root-manifest`. Also `ROOT_OUT=DIR` for a test next to a root in use.
- It fails or `DEBUG26=0`: the root is built with one audit line `off debug-ios26`, and `ios26-root.sh` prints it at its end.
- `/usr/share/laurel/root-manifest`: first line for `LAUREL BUILD: root ...` (patch 2912), with the commit's time, so the same commit gives the same bytes. It holds the kernel series of `out/laurel-kernel-ios26/out`: build the kernel first.
- **Sizes and the hash of section 1 are from before these hooks. The image changes.** Run `ios26-root-again.sh` again.

Tests [V]: `--self-test`: `debug hook self-test: 27 of 27`, with the real binaries of `out/ssh/ios` and scratch keys (job, USB address only, owners, modes, links, kill switch, missing tool; the job stays when Metal and AirDrop fail); with `METAL_STAGE` of the real stage also `metal hook self-test: 15 of 15`. Real 23F84 build with `ROOT_OUT` (scratch path, the shared image was not touched), twice: no Metal stage (`off metal26`, `applied debug-ios26`), and with the Metal stage. Each: `hfs-verify` OK, `fsck` OK, kernel read-only mount 0 differ; job, binaries and keys read back from the image.

## 4.3 Parity hooks

`ios26-root-spec.py` function `parity()`, after `debug()`, `air()`, `metal()`. Binaries: `scripts/bg.sh ios26-parity scripts/laurel/ios26-parity-build.sh` first; a hook takes only a file on `out/ios26/parity-check.tsv`. A failure of any kind in one hook restores the tree, launchd.plist and the overlay to what they were before it. Doc: `ios26-parity.md`.

## 5. What is not proven

Boot. launchd, dyld, AMFI, wifid and every other process accepting this root. That XNU's journal start on the phone accepts these flags: the Linux kernel mount proves the catalog, read-only, and not the XNU write path.
