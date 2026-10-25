# Working on iOSPlus10

Goal: iOS on the OnePlus 10 Pro 5G (NE2211, "negroni", SM8450), booted natively through
Mu-Silicium UEFI + UniXNU/DarwinBoot + XNU. Milestone 1: iOS 16 (existing negroni port).
Final goal: iOS 26 (arm64e, the CPUs have PAC) with Adreno 730 GPU acceleration.

Read first: **`docs/notes.md`** (knowledge base + handoff: every fact, number, error fix and
decision we learned; add yours before you stop), `docs/plan.md` (status and next step), `docs/research-report.md` (stack and blockers),
`docs/backup-and-restore.md` (device state and restore).

## Rules

- **All work lives in this repo.** Every step is a script in `scripts/` (or `docker/`), documented in
  `docs/`, and works on macOS and Linux. Do not leave work in `/tmp`, scratch folders or one-off
  shell commands. Build products go to `out/`, logs to `logs/` (both git-ignored).
- **Everything that can take more than a few seconds runs in tmux**, never in the foreground and
  never as an agent-background command: downloads (curl, aria2c, `gh run download`, remotezip),
  every `docker build` / `docker run` / `scripts/setup/in-docker.sh` call, Mu and shim builds, partition
  dumps, image conversion, large fastboot flashes, CI waits. Use `scripts/bg.sh NAME COMMAND...`;
  check with `scripts/bg.sh -s NAME`; the log is `logs/NAME.log`, the exit code `logs/NAME.exit`.
  The job must survive the end of the agent session. Foreground commands are only for quick checks.
- **Commit and push** completed steps to `origin main` (private repo akshaynexus/iOSPlus10). Update
  `docs/plan.md` after each milestone: what was done, exact results, what is next. Separate
  observations from guesses.
- **Keep out of git:** device dumps, serial numbers, firmware images, OTA files, Apple IPSW/DMG files,
  kernelcaches. `.gitignore` blocks the usual types; check `git status` before each commit.
- **External repos live in `external/`.** The 5 required ones (slop, Mu-Silicium-negroni, UniXNU, ios-flame,
  hackios-xnu-userland, metal2vulkan) are submodules; the reference ones come from `scripts/setup/get-references.sh`
  (`make references`), are git-ignored and pinned in that script. Do not commit changes inside either kind; put our
  changes as patches or scripts in this repo and apply them from a script.
- **Reply style:** ASD-STE100, STE-flavored (short sentences, active voice, technical terms and
  numbers unchanged).
- **Clean old builds after every new build.** The Mac disk is nearly full (a full disk breaks builds and
  the shared git index). After a new build succeeds, run `scripts/clean-builds.sh --yes` (keeps the 2
  newest kernels and the linked one, kernel trees changed in the last 3 h, `out/ios16`, `ios16-debug`;
  removes older `out/kernel/local-*`, idle `out/kernel/tree-*`/`wt-*`, old `out/ios16-*` variants). Agents
  delete their own scratch trees when they finish. Replace a big image (root `.img`/`.simg`) instead
  of keeping old copies, unless it is the only fallback. Never copy a directory into itself. Check
  `df -h` before a large job.

## Phone safety

- Bootloader unlocked; Magisk 30.7 installed in `boot_a` (adb root: `adb shell su -c ...`).
- Test with `fastboot boot` first when the image type allows it.
- **Ask the owner before each partition write.** Allowed targets: `boot_a`, `vendor_boot_a`,
  `vbmeta_a`, `dtbo_a`, `userdata`. Never write slot B, the GPT, or the unique partitions
  (modemst1/2, fsg, fsc, persist, oplusreserve*, devinfo, ...). Never run `fastboot flashing lock`.
- Do not install OxygenOS updates. Stay on `NE2211_16.0.3.530(EX01)`.
- Use the USB cable that works in fastboot mode (one cable worked for adb but not fastboot).
- Restore: `docs/backup-and-restore.md`. Backups are in `~/op10-backup/` (OTA zip, extracted images,
  `partitions/` dump of all 121 small partitions + GPT, Magisk boot image).

## Build environment

- Everything runs natively except the Mu UEFI build (`docs/build-ios16.md` has the table).
- Entry point: `Makefile` (`make help`). Scripts by stage: `scripts/{setup,backup,uefi,ios16,lib}`.
- Parallel builds: use all host cores (`$NPROC` from `scripts/lib/env.sh`) for make/git/cargo;
  Colima gets every core; independent steps run at the same time (separate tmux jobs, `&` + `wait`,
  rayon in Rust). EDK2 `build` auto-detects the CPU count (no `-n` / MAX_CONCURRENT_THREAD_NUMBER).
- Language rule: binary formats, large files and parallel I/O go into the Rust CLI
  `tools/op10tool` (one binary, macOS + Linux); short glue stays shell or Python. A new Rust command
  must match the old tool's output (`tools/op10tool/tests/compare-python.sh`).
  Native tools: `scripts/setup/native-tools.sh`; run with them: `scripts/lib/native-env.sh <command>`.
- Metal management (enable/disable, clearing strikes, logs): see `docs/metal-management.md`.
- `docker/Dockerfile`: Ubuntu 24.04 x86_64 for the Mu build (stuart + x86_64 NuGet tools).
- macOS (Apple silicon): `scripts/setup/colima-up.sh` (Colima + Rosetta), then `scripts/setup/docker-image.sh`.
- Linux x86_64: Docker, then `scripts/setup/docker-image.sh`.
- Run tools in the container: `scripts/setup/in-docker.sh <command>` (repo mounted at the same path,
  `~/op10-backup` read-only).
- Setup per OS: `docs/setup-macos.md`, `docs/setup-linux.md`.
