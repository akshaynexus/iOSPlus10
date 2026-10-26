#!/bin/sh
# Refresh the iOS 16 root image with the current add-ons and firmware areas, from the sparse root alone
# (no full root rebuild). One command, run in tmux (make root-refresh or scripts/bg.sh):
#   SUDO_PASS=... scripts/ios16/root-refresh.sh [HOOK...]
# Steps: 1. op10tool simg2img (holes, not zeros) $APPLE/ios16-root.simg -> ios16-root.img
#        2. sudo scripts/ios16/root-update.sh ios16-root.img ios16-root-new.img HOOK... (default: every hook;
#           tweaks runs first, see root-update.sh)
#        3. op10tool hfs-size --trim (the raw is partition-sized), AREAS=1 root-simg.sh -> ios16-root-new.simg
#           (needs out/firmware/*-area.bin from scripts/fw/build-areas.sh)
#        4. the old simg becomes ios16-root-prev.simg, the new one ios16-root.simg (what scripts/flash/ios16.sh flashes)
# Disk: the raw image costs its data (~15 GB) + the new simg (~12 GB) during the run; the clones share blocks.
# sudo: pass the password in SUDO_PASS (tmux has no terminal for the prompt) or run from a shell with sudo cached.
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
S=$APPLE/ios16-root.simg; RAW=$APPLE/ios16-root.img; NEW=$APPLE/ios16-root-new.img
[ -f "$S" ] || { echo "missing $S" >&2; exit 1; }
HOOKS=${*:-"tweaks metal powermenu negronigl audio ssh haptics bt camera fpd"}
for a in gpu adsp wlan; do [ -f "$OUT/firmware/$a-area.bin" ] || { echo "missing out/firmware/$a-area.bin (scripts/fw/build-areas.sh)" >&2; exit 1; }; done
rm -f "$RAW" "$NEW" "${NEW%.img}.simg"
"$OUT/bin/op10tool" simg2img "$S" "$RAW"
"$OUT/bin/op10tool" hfs-size --trim "$RAW"
if [ -n "${SUDO_PASS:-}" ]; then printf '%s\n' "$SUDO_PASS" | sudo -S "$REPO/scripts/ios16/root-update.sh" "$RAW" "$NEW" $HOOKS
else sudo "$REPO/scripts/ios16/root-update.sh" "$RAW" "$NEW" $HOOKS; fi
AREAS=1 "$REPO/scripts/ios16/root-simg.sh" "$NEW"
mv -f "$S" "$APPLE/ios16-root-prev.simg"
mv -f "${NEW%.img}.simg" "$S"
rm -f "$RAW" "$NEW"
ls -l "$S" "$APPLE/ios16-root-prev.simg"
echo "root refreshed: $S (previous kept as ios16-root-prev.simg); flash with scripts/flash/ios16.sh userdata"
