# Mi A3: update the root in place, keep /private/var

Owner request, 2026-11-01: "Flash the latest images, but don't wipe userdata, or just append, so I don't have to reconnect Wi-Fi and whatnot."
Fact: the iOS root is one HFS+ volume on userdata. A sparse flash erases `/private/var`: Wi-Fi networks, settings, app data.
Labels: [V] read in code or logs, or run here. [I] inference. [U] unknown.

## 1. Commands

```sh
scripts/bg.sh rupd-phone scripts/laurel/update-phone.sh     # all of it: build-all, root.sh (sudo), root update, kernel to boot_b. No userdata flash
scripts/bg.sh rupd scripts/laurel/root-update.sh            # root only: update, verify, ctl reboot, register apps
scripts/laurel/root-update.sh --dry-run                     # read the phone only: each change and the byte count; no write
scripts/laurel/root-update.sh --list                        # no phone: all paths of the delta
scripts/laurel/root-update.sh --rollback [ID]               # old files back from /var/root/laurel-rollback (SSH needed); then ctl reboot
scripts/laurel/root-update.sh --after-boot                  # wait for SSH, register new apps, compare the root again
scripts/laurel/root-flash-test.sh                           # clean install: stays as it was. Erases /private/var
scripts/laurel/root-update-test.sh                          # host test: fake root, fake phone. GNU tools, then the phone's toybox + dash
```

`update-phone.sh` switches: `BUILD=0` (use what is there), `KERNEL=0` (no boot_b flash; `ctl reboot`), `HOLD_S=180`, and all of root.sh's (`AUDIO=0` ...). `root-update.sh`: `REBOOT=0`, `STALE_OK=1`.

## 2. How it works

**File list.** `root-delta.py` in `root.sh`: `snapshot` directly after mkiosroot (a stat of each path), `make` after the feature table. Same path + same kind, mode, owner, size, mtime and ctime = not ours. So a new root step needs no list of its own. Output `$APPLE/laurel-ios16-root.update` (Apple content: never in git): `files.tsv`, `store/<sha256>` (readable with no sudo, so the update needs no mount), `base/` (stock plists of `/private/var`), `meta.json`, `manifest`. The image gets `/usr/share/laurel/root-files`: what this build installs, so the next update can remove what a later build drops.

**Classes**, the rule "keep `/private/var` except what we install":

| Class | Which files | On the phone |
| --- | --- | --- |
| install | all outside `/private/var`; our own files in it (`negronimetal/build.txt`) | replaced by rename when the hash, owner or mode differs |
| plist merge | each `.plist` our steps changed in `/private/var` | only the difference stock -> image is written; all other keys stay |
| key file | `/var/root/.ssh/authorized_keys` | union of lines |
| keep | `negronimetal/{clients,env,metal.log}`, `/var/root/.profile`, folders in `/private/var` | the phone's copy wins; only a missing one is made |
| skip | a stock path in `/private/var` that the image has no more; `datamigrator/` | stays (exception: `staged_system_apps`, moved to `/Applications`) |

Plist rules (`rootupdate/merge.py`): a dictionary merges key by key, so `Sets` keeps the Wi-Fi service. A list: our new items move to the end, so the USB service stays last in `ServiceOrder`. `NetworkServices/<id>` of ours is ours as a whole, so the old `Router` and `DNS` of the USB service go. `AppleLanguages`, `AppleLocale`, `EnhancedTextLegibilityEnabled`, `LocationServicesEnabledIn8.0` are defaults: the phone's value stays. The plist keeps the phone's format and owner. A new state file in `/private/var`: one line in `KEEP` of `root-delta.py`.

Never touched: known networks (`/private/var/preferences/SystemConfiguration/com.apple.wifi.plist` on this phone [V]; no root step writes it [V]), app containers, Keychains, LaunchServices store, photos.

**Order of a run:**

1. Gate: `root-manifest.py flash-check`, the same as for a flash. `--sidecar`: the payload belongs to this root build.
2. Read the phone (stat, then sha256 only of files with the same size; a here-document on `sh -s`, so no file is written). A refusal or a dry run stops here.
3. Stage: one tar over SSH into `/private/var/root/laurel-update/stage` (same volume). A lost link costs only the rest: the next try finds the good files by hash, 3 tries. Owner and mode are checked. `toybox`, `dash`, `dropbearmulti` must start from the stage (exit below 126: a bad signature is a kill), else stop.
4. Key: `authorized_keys`, then one new SSH login with the key only (a wrong password is given). If it fails: stop. Only this file changed.
5. Rollback tar of all old files: `/var/root/laurel-rollback/<UTC>/` (the 2 newest stay).
6. Commit, detached (`setsid nohup`): a dropped SSH does not stop it, the host reads the status file. Each file is one rename, so a running binary keeps its old inode and no process sees half a file. Order: folders, data and libraries, helpers, `/private/etc`, `/usr/local/bin` + `/bin/sh`, `/private/var`, job plists, removals, `launchd.plist`, `root-files`, `root-manifest`. Then `sync`.
7. Verify on the phone: sha256 of each written file, owner, mode, removals. Failure: automatic rollback, exit 1. No reboot came yet, so the running system saw only renames.
8. One line: `root-update: OK: N files (B bytes), ...; hashes checked; rollback ID; reboot now`. Then `op10tool ctl reboot` (else `usbreboot normal`).
9. After the boot: wait for SSH, `pmregister` for new apps, `usbnetcfg show`, the plan again (`N paths differ`).

**Boot line.** `root-manifest` = the image's text, first line + ` in-place <UTC>`, plus one `update` line (`from` the old first line). The kernel prints: `LAUREL BUILD: root <commit> <time> kernel-series <hex> features ... missing 0 in-place <UTC>: kernel series matches`. `root.sh`'s image has no mark. Without the kernel flash it says `KERNEL SERIES DIFFERS`: true then.

## 3. What the notes in the task came to

| Item | Result |
| --- | --- |
| launchd | Only `/System/Library/xpc/launchd.plist` counts ([V] docs/usb-network.md). Replaced by rename. launchd reads it at boot, so the jobs change at the reboot. No `launchctl`, no live change |
| dyld, cryptex | `private/preboot/`, `System/Cryptexes/`, the dyld cache: a difference = refusal. The same files as stock are not in the delta. A stock file hard-linked into a cryptex that a step edits counts as a difference when the phone does not have it yet |
| Info.plist, new apps | [V xnutils.md] A new root seeds LaunchServices once; a root that booted keeps its store. So after the boot `pmregister /Applications/X.app` runs for each app with a new or changed `Info.plist`, `pmregister -u` for a removed one (`/private/var/root/laurel-update/register.list`; a failed line stays for the next `--after-boot`). The store is not removed: a new seed costs a long start ([V notes "GL stall"]) |
| MobileGestalt cache | Both paths of `root-camera.sh` are removed when anything changes: only a cache, made again at the boot |
| Owners, setuid | In `files.tsv`. Tar with `p` + `--numeric-owner` ([V toybox 0.8.15: chown, then chmod with all bits]); checked in the stage, fixed with chown, then chmod. `powermenu-helper` 4750: test passes as the user; root owner [U until the first run] |
| Signatures | Bytes are the same as in the image, so the ad hoc signature stays. [V notes] This port has no trust caches ("trust caches unavailable"). A new inode: [I] no stale signature state in the kernel, one more reason for rename |
| cfprefsd | [I] It can write a plist from memory after our merge, if a client sets a value in the seconds before the reboot. Effect: a key of ours lost. `--after-boot` shows it (`N paths differ`); run the update again: it is idempotent |

## 4. Refusals (exit 3, one line, nothing written)

`root-update: REFLASH NEEDED: <reason> (scripts/laurel/root-flash-test.sh erases /private/var). Nothing changed.`

| Reason | Check |
| --- | --- |
| iOS build changed | `SystemVersion.plist` on the phone against the image |
| stock root changed | base id of `root-files` (other DMGs or mkiosroot.sh); first update: the dyld cache sizes |
| cryptex or shared cache would change | see above |
| volume size changed (partition layout, `SIZE=`) | `df -k /` against the image, 2 % |
| not enough free space | new files + old copies + 256 MiB |
| root not HFS+, read-only, `/private/var` on another volume | `mount`, `stat -c %d` |
| a file an older build changed is stock now | the stock bytes are not in the delta |

## 5. The first update (root of 21:57: password `alpine`, boot job `usbnetcfg up`)

[V image of 21:57, 7z] It has `dev.iosplus10.usbnetcfg` in the launchd cache and as a plist, the USB service with router and DNS, first in the order, no `authorized_keys`, no `root-files`. So:

1. Login: `ssh-phone.sh` gives `alpine` by itself.
2. Key step (section 2, step 4). The new root's job has `-s` (key only): this step proves the key first.
3. **`usbnetcfg down` does not run.** [V 23:10, task text] After it SSH may stop until a reboot. The boot job goes through the cache: new `launchd.plist` without the job, the plist file removed (`LEGACY` in `root-delta.py`), the USB service merged without router and DNS, last in the order. All of this takes effect at the reboot, so the link stays until then.
4. `root-files` and the in-place first line are new.
5. After the reboot: `LAUREL NET: on: default route en0 ...`, no `exec usbnetcfg` line.

## 6. If it goes wrong

| State | Recovery |
| --- | --- |
| Refused, or failed before the commit | Nothing changed (at most the key was added) |
| Failed in the commit or the verify | Automatic rollback by rename; the line says so. If the rollback fails too: no reboot; `--rollback ID` |
| New root boots, a feature is bad | `root-update.sh --rollback`, then `op10tool ctl reboot` |
| New root boots, no SSH | The rollback needs SSH. `op10tool ctl ping` tells if the kernel runs. Only `ctl` remains: full flash |
| Root does not boot at all | `op10tool ctl log` or the USB log. Then `BUILD=0 scripts/laurel/root-flash-test.sh`: the sparse image of the same build. **It erases `/private/var`.** No other way to write the volume from outside: fastboot only flashes whole partitions, and the phone has no recovery that mounts it |

So the sparse image stays worth keeping: `root.sh` still makes it on each run.

## 7. Tests

`root-update-test.sh` runs twice: GNU tools, then toybox 0.8.15 + dash of `out/ssh/host` alone in PATH (the same sources as the phone's). Cases: file list and classes, plist merge, key step, smoke step, inode of a "running" file, setuid, names with spaces and a quote, dry run writes nothing, failure in the commit with rollback, `--rollback` gives the same tree, lost link in the transfer and the commit, second run does nothing, removal of a dropped file, each refusal. `root-dry-run.sh` runs `root-delta.py` on the copy with the real stages.

Results, merged tree (d571276 + this branch) [V]: `root-update-test.sh` 94 of 94 with GNU tools, 94 of 94 with toybox + dash. `build-honest-test.sh` 60 of 60. `root-dry-run.sh` PASS with `AIRPLAY=0 CELL=0` (their new stages are not built on this host): 12 installed, 2 off, 9739 paths, 593 MB. Before the merge, all 13 features: 9740 paths. A simulation with the real `launchd.plist` and `/private/var` plists of the 21:57 image: the job left the cache, dropbear got `-s`, Wi-Fi service kept, USB service without router and DNS, last in the order.

## 8. The one read on the real phone (2026-11-01 23:45, read-only, 52 s, no file written)

`rootupdate/main.py --dry-run` with the payload of `root-dry-run.sh`, not of `root.sh`, with the root of 21:57. Password login through `ssh-phone.sh` worked. Stat of 9740 paths and sha256 of the same-size files worked with the phone's toybox, stock `df` and `mount` [V].

| Plan line | Meaning |
| --- | --- |
| exit 3: `volume size changed: phone 16384 MiB, new root 976248 MiB` | Correct for this payload: it was made on /home. A `root.sh` payload is made on the 16 GiB image. The phone's number is right |
| 9481 `owner or mode` | Artifact: the copy has the host user as owner. A `root.sh` payload has the root's owners |
| host key, `/usr/local/bin/df` | Artifact: this copy made a new host key and has no stock `df`. A real `root.sh` run has neither |
| `mkdir /private/var/containers/Temp` | Real: the phone has no such folder. [I] Boot removes it. Fixed: such a folder alone is no reason for an update (`plan.trivial`) |
| 12 of 13 plists: no change; `preferences.plist`: merge | Real: the phone holds our keys; only the USB service changes |
| 18 files, about 42 MB, of which the two big ones: `NegroniMetal` 22.9 MB, `libOSMesa` 17.1 MB | Real for that stage set. A new build gives other numbers |

## 9. Never run on the phone

Owner rule, 2026-11-01: no flash, reboot or write to the phone unless the owner asks. So the write path has never run on the phone. Unproven: `tar xpf` from SSH on HFS+ and the transfer rate; rename under running daemons on XNU; setuid and owners on the phone; the key login with `-s`; the commit detached with `setsid nohup` under dropbear; `ctl reboot` after the commit; `pmregister` on this root; boot of the updated root; the kernel's in-place first line (its 199-character limit is from the source of patch 2912). `sudo root.sh` was not run either (sudo needs a password here), so no real payload exists yet. Start with `scripts/laurel/root-update.sh --dry-run` after a `root.sh` run: it writes nothing.
