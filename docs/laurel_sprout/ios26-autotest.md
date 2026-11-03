# Mi A3 iOS 26: an agent tests the UI with no finger

Date: 2026-11-03. Tool: `scripts/laurel/ios26-autotest.sh`. Labels: [V] measured on the phone or here, [I] inference, [U] unknown.

## 1. Commands

```sh
scripts/laurel/ios26-autotest.sh install                 # build laurel-autotest, copy it to /usr/local/bin. Works on a running phone, no root rebuild
scripts/laurel/ios26-autotest.sh check                   # LAUREL AUTOTEST: on|off: ...
scripts/laurel/ios26-autotest.sh shot home1              # logs/autotest-shots/home1.png: read this PNG to see the UI
scripts/laurel/ios26-autotest.sh tap 360 1433            # panel pixels, 720x1560
scripts/laurel/ios26-autotest.sh swipe 620 800 100 800 300
scripts/laurel/ios26-autotest.sh edge bottom 800 300     # bottom|top|left|right [LEN] [MS] [AT]: with the kernel's edge flag
scripts/laurel/ios26-autotest.sh key power               # power|volup|voldown|home [MS]
scripts/laurel/ios26-autotest.sh open com.apple.Preferences
scripts/laurel/ios26-autotest.sh home                    # an edge swipe from the bottom
scripts/laurel/ios26-autotest.sh settle 700 8000 [change]  # waits until the picture holds still
scripts/laurel/ios26-autotest.sh seq 60 3000             # sequence shot: frames that equal an older frame, black frames
scripts/bg.sh autotest scripts/laurel/ios26-autotest.sh run [--only settings,safari] [--scenario FILE]
scripts/laurel/ios26-autotest.sh test                    # no phone
```

`run` needs `make usblog` for the kernel lines; with no live log the table says so. It writes `logs/autotest-DATE.txt` and `logs/autotest-DATE/` (PNG of each `shot`, `NAME-seqN/frame-NNN.png`). Scenario: `scripts/laurel/ios26-autotest.scenario`; its head lists the verbs. Exit 0: all steps ok.

The tool never flashes, reboots, restarts a process, or changes a setting. A lost SSH is not a fault: the step gets a note, the runner waits 120 s and goes on.

## 2. How it works

| Part | How | Needs a flash |
|---|---|---|
| Touch, keys | `laurel-autotest` (root, `userland/laurel/autotest`) builds the events of `SweetHIDTouch::touch` and `SweetHIDButtons::key`, with the sender id of these services, and gives them to the event system in backboardd: `IOHIDEventSystemClientDispatchEvent` | No |
| Frame | Finds the surfaces of 720x1560 with `IOSurfaceLookup` and reads the one on the panel. No lock (a lock can change a seed), no write, no display code | No |
| Which surface | From the in-use marks: see below | No |
| App start | `SBSLaunchApplicationWithIdentifier`, then `LSApplicationWorkspace` | No |
| Kernel path for input | Patch 2983: USB command server words `touch F D X Y`, `key K D`, `synth`; `op10tool input ...`. The script takes it by itself when `op10tool input check` says `synth on`. `AUTOTEST_INPUT=ssh`: not this way | **Yes. Built, not booted** |
| Exact surface | Patch 2983: `kern.laurel_scan_surface`, written after the latch. The tool reads it first | **Yes. Built, not booted** |

### Limits

- [V code] **With no patch 2983, frame rates can be under those of a finger.** `laurel_input_touch` (2890: CPU and GPU clock answer to touch) and `laurel_touch_event_at` run in the kernel's touch path, and the event system path does not pass there. So `touch to next flip` stays 0, and the table's head says which input ran. Compare frame rates only between runs with the same input.
- [V] The kernel's `SWEET HID: touch` lines do not print with the no-flash input.
- [I] Which surface, with no patch: the kernel marks a surface in use at its swap, and drops the mark of the frame before when the new one has latched (`AppleCLCD::showDirect`). A surface with a new mark can hold its old picture for up to 900 ms (the wait for the GPU). So the rule: the current surface stays until its own mark goes. If CoreAnimation holds a use count of its own at that time, the current surface stays too long [U if it does]. The output says `inferred`. A flash result from `inferred` is a lead, not proof: confirm it with 2983, or by eye.
- [V] With the panel off, the last surface keeps its mark, and CoreAnimation has drawn it black: `shot` gives a black frame. `awake` reads SpringBoard's `com.apple.springboard.hasBlankedScreen`: exit 1 when off.
- The copy path of the framebuffer (`showPending`) is not read. On all boots here the frames took the direct path [V `LAUREL FB CANVAS: ... direct path`].
- A sequence reads 1 row and 1 column in 4 (180x390). It cannot see a change that is only in the skipped pixels.

## 3. Facts found on the phone [V]

| Fact | Evidence |
|---|---|
| A file in `/var/tmp` runs with `csflags` 0 and no blobs, so backboardd says `missing the 'com.apple.private.hid.client.event-dispatch' entitlement`, `entitlements:0x0`. The same file in `/usr/local/bin`: `0x26000001`, `entitlements:0x1f` | `csops` from the tool; `oslogstream`. So `install` uses `/usr/local/bin`, and `check` says off for a bad signature. Why `/var/tmp` differs: [U] |
| `IOSurfaceGetUseCount` reads 0 for the kernel's marks, `IOSurfaceIsInUse` sees them | `surfaces` |
| `key home` changes nothing on this model (N104AP table, no home button) | 0.05 % of the picture. So `home` is an edge swipe |
| `key power` wakes the panel | `SWEET FB: display on`, `brightness 255 of 255` |
| The compositor uses surfaces 1 and 3 at first, and adds 197, 198 with an app in front | `surfaces` |
| A boot can hang with `ps busy` on each try: `proc_list_mlock` held, no exec for 465 s, `usernotificationsd` 60 s of CPU a minute, SSH `Connection timed out during banner exchange`, `ctl ping` works. So the old note "dropbear stops answering" has this one cause in this case | 06:30-06:38, logs/usblog-20261103-000638.txt. Cause of the hold: [U] |
| A fixed wait of 2 to 8 s gives frames of an animation: the first run's "settings-open" showed Home, "control-center-closed" showed Control Center, and the table said ok | So `settle`. **Look at the PNGs: `changed` only says that the picture moved** |

## 4. Tests

```
scripts/laurel/ios26-autotest.sh test                             # self-test of the runner + cargo tests of the frame, PNG and flash code
python3 -I tools/op10tool/tests/input-test.py out/bin/op10tool    # op10tool input against a fake command server on 127.0.0.1:5141
```

Kernel [V host]: `kernel-ios26-linux.sh` with 2983: 350 patches, 229 applied, 86 applied+rules, 8 skipped, 0 errors; LSE/RCpc 0; printf-arg-check OK; copyio table OK; armv80-check 0. **2983 has not run on the phone.**

## 5. After a flash with 2983

| Read | Meaning |
|---|---|
| `LAUREL SYNTH: on: ...` in the USB log | The feature is on |
| `LAUREL SYNTH: off: <reason>` | Off, also `laurelsynth=0`. Only this feature |
| `op10tool input check` -> `synth on` | The script takes the kernel path |
| `LAUREL AUTOTEST: on: ... panel surface from the kernel` | Exact surface |
| `op10tool input check` -> `error: unknown command` | A kernel with no 2983 |
| `SWEET HID: touch 9 down at ...` | The kernel path ran. Finger 9, so a real finger keeps its own state |
