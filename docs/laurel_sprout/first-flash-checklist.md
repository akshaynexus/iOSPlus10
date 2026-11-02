# Mi A3: first flash checklist (LineageOS + iOS 26)

Short form of `dual-boot.md` section 1, which holds all detail and the recovery table. **Nothing here has run on the phone.** Agents run no writing step until the owner says yes to that step. Run everything from the main checkout, and do not clean its `out/laurel/dualboot/`.

## Before anything

- Phone charged, on the good USB cable, LineageOS running.
- Start the USB log before the iOS boot: `make usblog`. The tmux server stopped at 07:57 on 2026-11-02 with the old session, cause unknown.
- Copy off anything on Android you want to keep. Step 4 erases it.

## Steps

| Step | What | Writes to the phone | Owner |
| --- | --- | --- | --- |
| 0 | `scripts/bg.sh laurel-backup scripts/backup/laurel-backup.sh data` | nothing | yes |
| 1 | `adb root`; `dual-boot.sh gpt-write --dry-run`; `dual-boot.sh check-slot-b` | helper in `/data/local/tmp` | see the output |
| 1b | Rehearsal: `CONFIRM=rehearsal-reach dual-boot.sh rehearsal reach`, then `dual-boot.sh rehearsal recovery` | `misc` boot message if ABL accepts | **at the phone** |
| 2 | `CONFIRM=gpt-write dual-boot.sh gpt-write` | **LUN 0 GPT**, 2 `userdata` superblock blocks | **yes** |
| 3 | `adb reboot bootloader`; `CONFIRM=after-gpt dual-boot.sh after-gpt` | nothing | |
| 4 | Recovery: Format data. Android setup, Build number x7, USB debugging, RSA dialog, Rooted debugging | **all of `userdata`, `metadata`** | **yes, at the phone** |
| 5 | `adb root`; `dual-boot.sh android-check` | Updater off | |
| 6 | `dual-boot.sh prepare-root`; `adb reboot bootloader`; `CONFIRM=install dual-boot.sh install` | `iosroot` | **yes** |
| 6b | `adb root`; `dual-boot.sh verify-root` | helper and list in `/data/local/tmp`; `iosroot` gets no write | |
| 7 | `dual-boot.sh image` | nothing | |
| 8 | `adb reboot bootloader`; `CONFIRM=flash-slot-b dual-boot.sh flash-slot-b`; Android must start | `boot_b`, `dtbo_b` | **yes** |
| 9 | `CONFIRM=switch dual-boot.sh switch` | slot flags | **yes** |
| 10 | Read `LAUREL DUALBOOT` on the panel or USB log; `dual-boot.sh ro-result LOG` | nothing | at the phone |
| 11 | Power + Vol Down; `CONFIRM=to-android dual-boot.sh to-android`; `dual-boot.sh android-check`. **Android must open its data** | slot flags | at the phone |
| 12 | `dual-boot.sh image rw`; `CONFIRM=flash-slot-b dual-boot.sh flash-slot-b rw`; `CONFIRM=switch dual-boot.sh switch rw` | `boot_b`, slot flags; Mu's menu can write slot flags | **yes** |

Step 2's guard needs a rehearsal result. With `recovery no-root` on record it also needs `NO_RECOVERY_ROOT=lun-erase-accepted`.

## Rules

- Flash `iosroot` only through `dual-boot.sh install`. A flash by hand or from another checkout does not void an old read-back.
- A `fastboot` call has no time limit except the last reboot. If a flash step shows no progress for many minutes, restart the phone by hand and run the step again. The record stays safe.
- No patch changes between now and step 7 without a new kernel build: the iOS 26 image has no series check. Do not skip step 7.

## Risks to accept before step 2

1. **Power loss during the GPT write.** The way back depends on the rehearsal. With no root in recovery, the last resort erases LUN 0 and restores `persist` and others from the backup. That restore has never been tried.
2. **Android keys after an iOS boot.** The header now matches Lineage's; this is not proven enough. Step 11 tests it. If Android asks for a reset, refuse it, and report. Worst case: format again, losing Android data only.
3. **Mu slot flag writes (step 12 on).** XBL's loader tries the backup GPT [V disassembly]; later stages are unknown. A cut during that write could need EDL. Low chance per write, not zero.
4. **adb in Android (only if the tile is installed).** A short window at boot listens on all interfaces. Never accept an unexpected adb prompt.

## What to expect

- The iOS 26 kernel has never booted. An early failure is a normal first result. Step 10 is a read-only boot with no UI.
- Step 12: reaching launchd counts as a win. A home screen is not expected on the first try. The first frame can take 30 to 120 s [I].
- If it fails: step 11, and work goes on next time.
- Black panel: `make laurel-ios26-diag`, then `scripts/bg.sh -s ios26-diag 40`. See `ios26-first-boot.md`.
- Not on this root: camera plug-in, no-wipe update. The rest of the parity table is built but has not run: `ios26-parity.md`.
