# Mi A3: disabled or broken system apps and features (2026-11-01)

Owner: "A lot of system apps and features are disabled. Fix these." Branch `t3/laurel-system-features`. Built and dry-run, NOT BOOTED.

Labels: [V] read in files, in the 20H392 images or in `logs/laurel-boot-2002.txt` (boot 20:02, 15 min). [I] inference. [U] unknown.
Sources: DMGs through apfs-fuse, `~/op10-apple/laurel-ios16-root.img` of 19:51 through 7z (no sudo), `crash-symbolize.sh`, disassembly.

## 1. Main cause

[V] 20H392 keeps 32 Apple apps in `/private/var/staged_system_apps`. A real iPhone installs them at the first-boot migration
(SystemAppMigrator). Our root skips that migration, as all ports do. Negroni, slop, ios-flame and ios-apollo move the apps to
`/Applications` as a separate step. **`scripts/laurel/root.sh` never had this step.** The root of 19:51 has all 32 still staged.
So the phone had no Calendar, Clock, Mail, Notes, Maps, Weather, Contacts, Music, Files, Health or Calculator.
slop saw the same on 2026-10-23: "user sees only Photos, App Store, Settings".

## 2. The table

Actions: **ON** = enabled by this branch. **DRIVER** = needs a driver. **OFF** = stays off, with the reason. **OPEN** = runs, has a fault. **OK** = no change necessary.

### 2.1 Enabled now

| Item | Why it was off | Evidence | Action | Expected cost |
| --- | --- | --- | --- | --- |
| 32 stock apps: AppleTV, Books, Bridge (Watch), Calculator, Compass, Contacts, FaceTime, Files, FindMy, Fitness, Freeform, Health, Home, Magnifier, Maps, Measure, MobileCal, MobileMail, MobileNotes, MobileStore, MobileTimer, Music, News, Passbook, Podcasts, Reminders, Translate, Shortcuts, Stocks, Tips, VoiceMemos, Weather | our step was missing (section 1) | [V] 7z list; [V] negroni `root-finish.sh`, apollo `sweet-root-tweaks.py`, flame HANDOFF 554 | **ON** `root-system-features.py`: move + placeholder out | Disk 0 (487 MiB is moved). First LaunchServices seed: 32 more apps and 102 more extensions, on top of 141 apps. [I] boot 20:02 took about 2 min to the seed end; expect about 30 s more, first boot only. At rest: 0 until an app runs. A widget costs its Metal memory (limit 64 MiB) only when it is placed |
| `aggregated` (power log, Settings > Battery) | dropped because ios-sailfish did, not for a fault here | [V] plist: `com.apple.powerlog.plxpclogger.xpc`, KeepAlive. [V] scion `mkjobs.py`: "Settings > Battery waits for" it, runs a whole session. Never run on the Mi A3 | **ON** job back; limit 16-20 -> 32 MiB, so that a kill at the limit does not become a KeepAlive loop | One more resident process, at most 32 MiB. [I] under 1 % of one core at idle. Read `LAUREL CPU TOP`. Above 2 %: `RESTORE_JOBS=` turns it off |
| Socket delegate (priv 10001) | our kernel denied it | [V] log: itunesstored, cloudd, dasd, nsurlsessiond. [V] each binary has `com.apple.private.network.socket-delegate`. [V] XNU `uipc_socket.c`, `necp_client.c` | **ON** kernel 2910, by entitlement | none |
| Skywalk kernel pipe (priv 12001) | our kernel denied it | [V] log: identityservicesd; entitlement in binary | **ON** 2910 | none |
| System override (priv 1003) | our kernel denied it | [V] log: mediaserverd at Camera start; entitlement `com.apple.private.kernel.system-override` | **ON** 2910 | I/O and CPU throttles off only during the call, as on iOS |
| AppleKeyStore selectors 8, 31, 32 and others; software passcode | topaz has few selectors | [V] log: SpringBoard sel 8 failed 34 times, sel 32 4 times, profiled sel 31 6 times, all `0xe00002c7` | **ON** merged 2904. Settings > Passcode. No SEP: a lock-screen gate only | Lower: 2904 logs the first calls per selector. Boot 20:02 had 3019 `SWEET AKS` lines in 15 min |
| HFS on flash | no SSD flag | merged 2902 | **ON** | Lower: no file relocation, no hot-file work |
| IOSurface wired guard | absent | merged 2906 (negroni freeze of 2026-10-27) | **ON**, 55 % of RAM, backboardd and SpringBoard exempt | one check per surface |
| USB poll and TX queue (for SSH) | fixed 1 ms poll | merged 2905. Changed here: only a received frame holds the 200 us poll. The original also held it for the live log alone | **ON** | Lower at idle: 4 ms, 20 ms without a host |
| SSH over USB (dropbear) | not in the root | merged from infra (`root.sh`, `phone-ssh.sh`, Linux build) | **ON** when `out/ssh/ios` exists | [I] none until a session starts |

### 2.2 Needs a driver or hardware service

| Item | Evidence | Action |
| --- | --- | --- |
| Cellular: Phone, voicemail, data; `CommCenter`, `CommCenter-noncellular` | [V] scion `mkjobs.py`: noncellular dies every 15 s without `AppleIPAppender` and `AppleBaseband`. `cellular.md`: the kernel QMI path is ours, not Apple's | **DRIVER**. Stays off. [I] MobilePhone and FaceTime have tag `any-telephony`, so SpringBoard can hide them |
| `voicemail.vmd` | ~29k CommCenter retries per boot (sailfish) | **DRIVER** (with CommCenter) |
| Motion: auto-rotate, Compass, Measure | [V] log: `gyro` -> none. Sensors are on the ADSP sensor hub | **DRIVER** (SSC client). Compass tag `magnetometer`, Measure tag `arkit`: [I] hidden or useless until then |
| Auto-brightness | [V] log: `als` -> none. stk3x3x on the sensor hub (`brightness.md`) | **DRIVER**. `root-brightness.py` stays |
| Location fix | locationd runs, switch on. No GNSS client: negroni 0397 is not ported | **DRIVER** (`negroni-ports.md` item 15) |
| Microphone: Voice Memos, Siri, calls | `audio.md` "Microphone": analog AMIC1 on WCD937x + SoundWire | **DRIVER built, not booted** (patch 2920). Voice Memos: test steps there. Siri: needs network services [U]. Calls: no cell path |
| Front, depth, ultrawide cameras | `camera.md`: rear IMX586 only | **DRIVER** |
| Hardware video decode | [V] log: `AppleVXD375/390` -> none | **DRIVER**. Wallpaper HEIC is solved by `root-wallpaper.sh` |
| AirDrop, AWDL: `wifip2pd` | [V] 76 starts in 15 min, no crash line. No AWDL data path on this firmware (`airplay-airdrop.md`) | **DRIVER, off by the evidence**. `LAUREL AWDL: off: ...`. `wifip2pd` stays out (`root-tweaks-perf.py`). AirDrop on en0 only (`root-airdrop-lan.py`) |
| Face ID, Touch ID | [V] log: `ApplePearlSEPDriver`, `pearl-sep` -> none. No SEP | **DRIVER**. Passcode only |
| USB accessories, MagSafe, thermal/`ApplePPM` | [V] log: `IOAccessoryManager`, `AppleHPMDevice`, `ApplePPM` -> 0 | **DRIVER**, no user request |

### 2.3 Stays off, with a reason

| Item | Reason | Evidence | Way back |
| --- | --- | --- | --- |
| `fairplayd.H2` | requests queue for ever; locationd and CoreLocation clients deadlock. So App Store apps with FairPlay do not run | [V] flame HANDOFF 238-245, apollo boots 47-50 | no FairPlay hardware |
| `syncdefaultsd` | [V] sig 6, 12 crashes in 15 min: uncaught exception in an XPC reply (symbolicated: `_dispatch_client_callout4`, `_objc_terminate`). scion: `-[NSURL initFileURLWithPath:isDirectory:]: nil string`; a directory and a container were ruled out. iCloud key-value sync has no use without an Apple ID | [V] log, disassembly: fallback through `getpwuid` exists; nil source [U] | read the exception over SSH with the job on (section 6) |
| `activityawardsd` | sig 6 at launch, every 10 s; 14 crashes on negroni. Fitness opens, awards tab empty [I] | [V] `root-tweaks-extra.py` | same as syncdefaultsd |
| `nanotimekitcompaniond` | [V] 73 starts in 15 min. Watch face companion, no watch | [V] log | with a paired watch |
| `ReportCrash`, `spindump`, `tailspind` | ReportCrash used ~60 % of a core (sailfish). Debug tools; our `CRASH` lines replace them. Side effect: 29 `Failed to send exception EXC_CORPSE_NOTIFY` lines; Analytics Data stays empty | [V] log | kept off while crash loops remain |
| `aggregated.addaily` | analytics upload only, no user feature; 0 use here | [V] plist | not needed |
| `BTAudioHALPlugin.driver` (Bluetooth audio) | The old reason is gone: `bluetoothd` holds `com.apple.BTAudioHALPlugin.xpc` [V] and runs [V log: `LAUREL BT: ios: client control connected`]. But no port ever ran the plug-in, and a trap stops all audio and the camera. No paired headset test exists | [V] plist, notes 1596 | `BTAUDIO=1 root-audio.sh`, test in section 6 |
| `StartRecorderServer` false | the camera plug-in starts the capture servers itself | [V] `camera.md` | no change necessary |

### 2.4 Runs with a fault

| Item | Evidence | State |
| --- | --- | --- |
| `webbookmarksd` | [V] 7 starts, 6 crashes sig 6, 2-3 min apart, uncaught exception in a Mach async reply. Not a tight loop. [V] its container fallback (`sandbox_container_path_for_pid` fails, kernel op 4 = ENOENT) only skips `setenv HOME` | **OPEN**. Stays on: Safari may use it [I]. Read the exception over SSH |
| `driverkitd` | [V] sig 9, reason namespace 1 (jetsam) code 7 (process limit), in `NSData initWithContentsOfFile`. One start, no restart | **OK** at no cost: no DriverKit driver here |
| `mediaserverd` | [V] 6 crashes at Camera start: `-[BWMultiFilterThumbnailNode prepareForCurrentConfigurationToBecomeLive]`, far 0x8 | **OPEN**, camera area |
| `PosterBoard` | [V] 1 sig 10 in `PBFPosterSnapshotter _lock_populateSnapshotsFromAssetCatalogIfPossible` -> `_ERROR_ImageIO_DataBufferIsNotReadable` | **OPEN**, wallpaper area |
| `backboardd` | [V] 1 sig 11 at 20:16:15, GL code | **OPEN**, GPU area |
| Bold Text | `root-tweaks-boldtext.py` writes only the stock value false; the switch works. Old crash: CoreImage GL with no GL driver. GL exists now. Not tested | Owner test only. A crash loop at SpringBoard start means a root rebuild |

### 2.5 Checked, nothing disabled

- [V] Sandbox ops `op 1, 5, 6, 7, 12, 15, 16, 22, 28`: allowed. Op 4 (container path): ENOENT, the normal answer for no container.
- [V] Priv 10003 (`symptomsd`, network statistics): stays denied in 2910. No feature here, and it can add wakeups per socket event [I]. `kernel_task` 10001: a socket credential, unchanged.
- [V] Setup is skipped, activation seeded (`data_ark`), no restriction or managed-configuration key in our root scripts.
- [V] The 36 `Disabled` jobs in the cache are Apple's stock state (Watch companions, `iap2d`, `sntpd`, ...). No change.
- [V] No script hides an app. SpringBoard hides by `SBAppTags` and MobileGestalt: `any-telephony`, `magnetometer`, `arkit`, `watch-companion`, `MusicStore`. We do not fake answers: an icon must work.
- Negroni extras not ported: `negroni-locd`, fingerprint daemon. XNUtils is ported: `docs/laurel_sprout/xnutils.md`. The stock power-off slider exists. Not a disabled stock feature.

## 3. What changed

| File | Change |
| --- | --- |
| `scripts/laurel/root-system-features.py` (new) | Apps, job, jetsam limit. `STAGED_APPS=0`, `RESTORE_JOBS=`, `AGGREGATED_JETSAM_MB=`. `--self-test` |
| `scripts/laurel/root-dry-run.sh` (new) | All job tweaks on a copy of stock files, as the user. Checks the off list and the apps |
| `scripts/laurel/root.sh` | Calls the new script after `root-tweaks-perf.py`; SSH step from infra |
| `scripts/laurel/root-audio.sh` | `BTAUDIO=1` keeps the Bluetooth plug-in (default off) |
| `patches/laurel/xnu/2910-*` (new) | Privileges by entitlement. Kill switch `laurelsandbox=0` (2903) |

Result of the job list [V dry run]: stock 532 -> 520 (bluetoothd stays; `com.laurel.metal-gate` comes from `root-add-metal.sh`). Off: CommCenter (2), ReportCrash, activityawardsd, aggregated.addaily, fairplayd.H2, spindump, tailspind, voicemail.vmd, nanotimekitcompaniond, wifip2pd, syncdefaultsd.

## 4. Branch t3/laurel-kernel-infra-ports (2 commits, 2900-2907)

Base is older than `laurel-sprout`; the audit showed 5 of 8 patches do not apply.

| Patch | Value | Decision |
| --- | --- | --- |
| 2902 UFS SSD | less I/O | merged |
| 2903 sandbox | already in `laurel-sprout` | same file; 2910 extends it |
| 2904 AKS + passcode | missing selectors, passcode | merged. Stored passcode lost: `laurelaks_reset=1` for one boot |
| 2905 USB poll, TX queue, reset | SSH speed, lower idle cost | merged, refreshed, poll rule changed (table) |
| 2906 wired guard | stability | merged, refreshed |
| 2900 console head, boot log | debug only; touches console, panic and UFS write paths | **parked** in `patches/laurel/parked/`: refresh and boot it alone |
| 2901 RTC, settime | same job as 2720 | **parked**: superseded |
| 2907 SPMI mutex | review fix for 2900 users, before 2710 | **parked** |
| userland: SSH Linux build, `phone-ssh.sh`, `log-pull.sh`, op10tool texts | tools | merged. `bootlog` commands need 2900: `error: unknown command` until then |

## 5. Build results

- Kernel: `applied=291 known-skip=0 failed=0`, 0 LSE/RCpc, sha256 a60e5633ac733f2d... (`out/laurel-kernel/out/kernel.development.sweet`).
- `root-system-features.py --self-test`: pass. `root-dry-run.sh` on 20H392 files: **PASS**, 32 apps moved, 173 apps, 0 staged, 0 placeholders.
- **The root is not built:** `root.sh` needs sudo. Not booted.
- op10tool builds after the merge.

## 6. Test steps for the owner

1. Build and flash (the flash erases iOS data; your approval): `scripts/bg.sh laurel-full sh -c 'scripts/laurel/build-all.sh && scripts/laurel/root-flash-test.sh'`. Optional SSH first: `scripts/bg.sh ssh-build sh -c 'userland/ssh/fetch.sh && userland/ssh/fetch-sdk.sh && userland/ssh/build.sh'`.
2. Root build log: `laurel system: staged apps: 32 moved to /Applications, 173 apps there`, `laurel system: job com.apple.aggregated: back in launchd.plist`.
3. First boot takes longer once. Home screen: more pages with Calendar, Clock, Mail, Notes, Maps, Weather, Reminders, Files, Contacts, Calculator, Music, Health. Report any missing icon, and whether Phone, FaceTime, Compass, Watch show ([I] above).
4. Open each one. Expected to fail without an account or service [I]: News, TV, Books, Podcasts, Wallet, Find My, Fitness awards.
5. Settings > Battery: the page opens and fills after some hours.
6. Settings > Face ID & Passcode (or Passcode): set a passcode, lock, unlock.
7. Idle 5 min: read `LAUREL CPU TOP`. `aggregated` under 2 %. No `exec wifip2pd`, `exec nanotimekitcompaniond`, `exec syncdefaultsd`.
8. Optional Bluetooth audio, only after a headset pairs: rebuild with `BTAUDIO=1`. If `CRASH mediaserverd` shows `xpc`: back to the default.
9. Optional exception text with SSH: `scripts/net/phone-log.sh webbookmarksd`, then read the `Terminating app due to uncaught exception` line.

## 7. Expected log lines

```text
LAUREL SANDBOX: privileges 1002/1007/12000 + entitled 1003/10001/12001 on, extension tokens on
LAUREL SANDBOX: nsurlsessiond privilege 10001 granted (first grant)      (first process that asks; once per privilege)
LAUREL SANDBOX: mediaserverd privilege 1003 granted (first grant)
LAUREL AKS: AppleKeyStore registered (unlocked, lock state 0x6, key wrap on, passcode on)
LAUREL SSD: on: UFS reports solid state (HFS: no file relocation, no hot files)
LAUREL USB POLL: on: 200 us while frames move, 4 ms idle, 20 ms without a host, TX queue 128, ENDTRANSFER at bus reset on
LAUREL WIRED: on: buffer surfaces refused above 1795 MiB wired = 55% of max_mem 3264 MiB (...)
exec aggregated                                                          (once; no CRASH aggregated)
exec MobileCal / MobileNotes / Weather ...                               (when opened)
```

Gone: `SWEET Sandbox: ... privilege 10001 denied` for processes with the entitlement, `CRASH syncdefaultsd`, thousands of `SWEET AKS` lines.

Fallbacks: `laurelsandbox=0` (2903 + 2910), `laurelaks_passcode=0`, `laurelwiredguard=0`, `laurelusb_poll=0`; root: `STAGED_APPS=0`, `RESTORE_JOBS=`.
