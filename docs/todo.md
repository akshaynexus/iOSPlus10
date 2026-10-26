# TODO

## One tool instead of shell + Python + Rust (owner, 2026-10-26)

Goal: fold the repo's automation into `tools/op10tool` (one Rust binary, macOS + Linux) so there is one tool to
maintain, not 114 shell scripts, 25 Python scripts and the Rust CLI. Rule from CLAUDE.md stays: binary formats,
large files and parallel I/O go into Rust first; short glue may stay shell until it is folded in.

Order (by how often we run them and how much format/binary work they do):

1. Flash and phone control: `scripts/flash/ios16.sh` (steps: check/recovery/vendor_boot/vbmeta/dtbo/boot/userdata/
   active), `scripts/flash/restore.sh`, `scripts/fw/write-areas.sh`, the `op10tool ctl` commands that exist ->
   `op10tool flash <step>`, `op10tool restore`, with the same owner-approval gates (`--yes`).
2. Root image: `scripts/ios16/root-refresh.sh`, `root-simg.sh` (AREAS embed), `root-update.sh` (HFS mount + hooks:
   this one needs sudo/hdiutil on macOS and a loop mount on Linux), `scripts/audio/hfs-extract.py` (HFS+ catalog
   reader, hard links) -> `op10tool root refresh|simg|extract` (HFS+ reader in Rust, no mount for extraction).
3. Firmware areas: `scripts/fw/build-areas.sh`, `scripts/audio/mkadsparea.py`, `scripts/wifi/mk*area*`,
   `scripts/bt/mkbtpack.py`, `scripts/fw/checkarea.py` -> `op10tool areas build|check`.
4. Images: `scripts/ios16/build.sh` (ADT + esp + boot_a + vendor_boot via mkbootimg/unpack_bootimg),
   `scripts/ios16/adt-extra.py` (ADT editor) -> `op10tool image build`, `op10tool adt edit`.
5. Kernel build drivers: `scripts/kernel/build-local.sh`, `patched-tree.sh`, `compile-one.sh`, the lock
   (`out/kernel/.lock`) -> `op10tool kernel build|tree|check` with the lock and the patch-report built in.
6. Phone helpers: `scripts/net/ssh-phone.sh`, `phone-log.sh`, `scripts/metal/phone-test.sh`, `scripts/gpu/phone-gl.sh`,
   `scripts/haptics/phone-haptics.sh`, `scripts/bt/phone-bt.sh` -> `op10tool phone <subcommand>`.
7. Analysis tools that are Python today: `scripts/display/panel-dts-dump.py`, `scripts/camera/raw-to-png.py`,
   `scripts/fp/raw-to-png.py`, `scripts/metal/selector-gap.py`, `scripts/camera/ios-re/*` -> `op10tool dts panel`,
   `op10tool raw2png`, `op10tool selector-gap` (keep the Python copies until the Rust output is byte-equal:
   `tools/op10tool/tests/compare-python.sh` pattern).
8. Keep as shell for now: `scripts/bg.sh` (tmux), the `scripts/setup/*` fetchers (git/curl glue), the per-agent
   build wrappers (they become `op10tool kernel build` callers).

Each step: same output as the old script (compare test), the old script becomes a one-line wrapper that calls
op10tool for one release, then is deleted. Owner approval gates (partition writes, SMMU writes) stay explicit flags.
