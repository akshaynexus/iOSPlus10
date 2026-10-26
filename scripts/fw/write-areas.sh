#!/bin/sh
# WARNING (2026-10-25): the phone had a kernel panic seconds after this script's first SSH command, which reads
# blocks of /dev/rufsroot0 with dd while the root on the same partition is mounted [I: cause not proven; the panic
# log was not read]. Prefer AREAS=1 scripts/ios16/root-simg.sh (the areas go into the userdata flash).
# Write the firmware areas (GPU, ADSP, WLAN) to the end of userdata from the running iOS over SSH.
#   scripts/fw/write-areas.sh                 local checks + the plan only; writes nothing
#   CONFIRM=yes scripts/fw/write-areas.sh     write (ASK THE OWNER FIRST: this writes userdata)
# Env: AREAS (default "gpu adsp wlan"), LOG_CHECK=0 (skip the log header check, see below),
# plus the scripts/net/ssh-phone.sh variables (PHONE_IP, SSH_KEY, ...).
# Inputs: out/firmware/{gpu,adsp,wlan}-area.bin (scripts/fw/build-areas.sh).
#
# Layout (4096-byte blocks of userdata, block 0 = partition start, N = partition size in blocks;
# kernel bsd/dev/negroni_ufs.c, negroni_fw_load and negroni_ufs_{adsp,wlan}_area_read):
#   old console log  N-1025  .. N-1       (never written here; "SWEETLOG", not written since kernel 0367)
#   GPU fw area      N-3073  .. N-1026    gpu-area.bin   2048 blocks
#   ADSP fw area     N-11265 .. N-3074    adsp-area.bin  8192 blocks
#   WLAN fw area     N-19457 .. N-11266   wlan-area.bin  8192 blocks
#   boot log area    N-28673 .. N-19458   (kernel 0367, never written here; superblock "NEGRBLOG")
# NE2211 (getvar partition-size:userdata 0x37F450F000): N = 58672399.
#
# Device: /dev/rufsroot0 (character node of the kernel's ufsroot0 = the whole GPT partition
# "userdata", offset 0 = partition start, writable only with boot-arg ufsrw=1). The block node
# /dev/ufsroot0 is the mounted HFS+ root: the kernel refuses to open it for writing.
#
# Steps with CONFIRM=yes:
#  1. N from the device: binary search for the first block that cannot be read (read-only dd);
#     it must equal N from getvar (58672399). Block N-1025 must start with "SWEETLOG" (the old
#     console log header) or block N-28673 with "NEGRBLOG" (the 0367 boot log); LOG_CHECK=0 skips this.
#  2. HFS+ end from `df -k /`: every write must be at or above it and at or above N-19457, and
#     end at or below N-1026. Else stop.
#  3. Push the images to /private/var/tmp/fwareas and compare sha256 on the phone.
#  4. Save the old contents of each area to out/firmware/area-backup-DATE/ (read-only dd).
#  5. dd bs=4096 seek=S count=C conv=notrunc,fsync of=/dev/rufsroot0.
#  6. Read each area back (dd | sha256sum) and compare with the local image.
#  7. sync, a console line (the log thread then sends SYNCHRONIZE CACHE for the whole LUN), 15 s wait.
# The kernel reads the areas at boot: reboot after (scripts/net/ssh-phone.sh reboot).
# shellcheck disable=SC2046  # "set -- $(area X)" splits "START COUNT" on purpose
set -eu
. "$(dirname "$0")/../lib/env.sh"
F=$OUT/firmware
SSH=$REPO/scripts/net/ssh-phone.sh
DEV=/dev/rufsroot0
RDIR=/private/var/tmp/fwareas
AREAS=${AREAS:-gpu adsp wlan}
KNOWN_N=58672399                # NE2211 userdata, from ~/op10-backup/getvar-all.txt (2026-10-24)
LOG_BLOCKS=1025

die() { echo "write-areas: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
ph() { "$SSH" "$*"; }            # one remote command string (dash on the phone)

# Expected N from getvar (must agree with the known value for this phone).
GETVAR=$BACKUP/getvar-all.txt
[ -f "$GETVAR" ] || die "no $GETVAR"
hex=$(sed -n 's/.*partition-size:userdata:\(0x[0-9A-Fa-f]*\).*/\1/p' "$GETVAR" | head -n 1)
[ -n "$hex" ] || die "no partition-size:userdata in $GETVAR"
bytes=$(printf '%d' "$hex")
[ $((bytes % 4096)) -eq 0 ] || die "userdata size $hex is not a multiple of 4096"
N=$((bytes / 4096))
[ "$N" -eq "$KNOWN_N" ] || die "getvar N $N != known $KNOWN_N (another phone or partition table?)"
LOW=$((N - 19457))               # lowest block this script may touch
HIGH=$((N - LOG_BLOCKS))         # first block it may not touch (the log area)

# start and block count of one area
area() {
  case $1 in
  gpu)  echo "$((N - 3073)) 2048" ;;
  adsp) echo "$((N - 11265)) 8192" ;;
  wlan) echo "$((N - 19457)) 8192" ;;
  *) die "unknown area $1" ;;
  esac
}

# Local checks and the plan.
for a in $AREAS; do
  img=$F/$a-area.bin
  [ -f "$img" ] || die "missing $img (scripts/fw/build-areas.sh)"
  set -- $(area "$a"); s=$1; c=$2
  [ "$(wc -c < "$img" | tr -d ' ')" -eq $((c * 4096)) ] || die "$img is not $c blocks"
  python3 -I "$REPO/scripts/fw/checkarea.py" "$a" "$img" > /dev/null || die "$img fails scripts/fw/checkarea.py"
  [ "$s" -ge "$LOW" ] && [ $((s + c)) -le "$HIGH" ] || die "$a: blocks $s..$((s + c - 1)) outside $LOW..$((HIGH - 1))"
  echo "plan: $a  blocks $s..$((s + c - 1))  sha256 $(sha "$img")"
  echo "      dd if=$RDIR/$a-area.bin of=$DEV bs=4096 seek=$s count=$c conv=notrunc,fsync"
done
echo "plan: N = $N blocks, writes stay in $LOW..$((HIGH - 1)), HFS+ root must end at or below block $LOW"
if [ "${CONFIRM:-}" != yes ]; then
  echo "write-areas: nothing written. Ask the owner, then run with CONFIRM=yes." >&2
  exit 2
fi

# 1. N from the device (read-only probes).
ph "test -c $DEV" || die "$DEV is not a character device on the phone"
# shellcheck disable=SC2016
PN=$(ph 'r() { n=$(dd if='"$DEV"' bs=4096 skip=$1 count=1 2>/dev/null | wc -c | tr -d " "); [ "$n" = 4096 ]; }
lo=0; hi=134217728
r 0 || { echo "E block 0 unreadable"; exit 0; }
r $hi && { echo "E block $hi readable"; exit 0; }
while [ $((hi - lo)) -gt 1 ]; do m=$(((lo + hi) / 2)); if r $m; then lo=$m; else hi=$m; fi; done
echo $hi')
case $PN in ''|*[!0-9]*) die "N probe failed: $PN" ;; esac
[ "$PN" -eq "$N" ] || die "the phone's userdata has $PN blocks, expected $N: stop"
echo "phone: $DEV has $PN blocks (= getvar)"
if [ "${LOG_CHECK:-1}" != 0 ]; then
  m=$(ph "dd if=$DEV bs=4096 skip=$((N - LOG_BLOCKS)) count=1 2>/dev/null | head -c 8")
  if [ "$m" = SWEETLOG ]; then
    echo "phone: log header SWEETLOG at block $((N - LOG_BLOCKS))"
  else
    m2=$(ph "dd if=$DEV bs=4096 skip=$((N - 28673)) count=1 2>/dev/null | head -c 8")
    [ "$m2" = NEGRBLOG ] || die "no SWEETLOG at block $((N - LOG_BLOCKS)) ('$m') and no NEGRBLOG at $((N - 28673)) ('$m2'); LOG_CHECK=0 to skip"
    echo "phone: boot log superblock NEGRBLOG at block $((N - 28673))"
  fi
fi

# 2. HFS+ end.
kib=$(ph "df -k /" | awk '$1 == "/dev/ufsroot0" {print $2}')
case $kib in ''|*[!0-9]*) die "cannot read the HFS+ size (df -k /)" ;; esac
HFS=$((kib / 4))
[ "$HFS" -le "$LOW" ] || die "HFS+ root ends at block $HFS, above $LOW: stop"
# the boot log area (kernel 0367) lies below the firmware areas: the root must end below it too
[ "$HFS" -le $((N - 28673)) ] || die "HFS+ root ends at block $HFS, above the boot log area at $((N - 28673)): stop"
echo "phone: HFS+ root $HFS blocks, ends below $LOW"

# 3. Push and compare.
ph "mkdir -p $RDIR"
for a in $AREAS; do
  "$SSH" push "$F/$a-area.bin" "$RDIR/"
  r=$(ph "sha256sum $RDIR/$a-area.bin" | cut -d' ' -f1)
  [ "$r" = "$(sha "$F/$a-area.bin")" ] || die "$a: pushed copy sha256 $r differs"
done

# 4. Backup of the old contents.
B=$F/area-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$B"
for a in $AREAS; do
  set -- $(area "$a"); s=$1; c=$2
  ph "dd if=$DEV bs=4096 skip=$s count=$c 2>/dev/null" > "$B/$a-old.bin"
  [ "$(wc -c < "$B/$a-old.bin" | tr -d ' ')" -eq $((c * 4096)) ] || die "$a: backup read short"
done
echo "backup: $B"

# 5. + 6. Write and read back.
result=0
for a in $AREAS; do
  set -- $(area "$a"); s=$1; c=$2
  [ "$s" -ge "$LOW" ] && [ "$s" -ge "$HFS" ] && [ $((s + c)) -le "$HIGH" ] || die "$a: range check failed"
  ph "dd if=$RDIR/$a-area.bin of=$DEV bs=4096 seek=$s count=$c conv=notrunc,fsync" || die "$a: dd failed"
  r=$(ph "dd if=$DEV bs=4096 skip=$s count=$c 2>/dev/null | sha256sum" | cut -d' ' -f1)
  if [ "$r" = "$(sha "$F/$a-area.bin")" ]; then echo "result: $a blocks $s..$((s + c - 1)) written, read back OK $r"
  else echo "result: $a READ BACK MISMATCH $r (backup in $B)" >&2; result=1; fi
done

# 7. Flush.
ph "sync; echo 'write-areas: firmware areas written' > /dev/console; rm -rf $RDIR"
sleep 15
[ $result -eq 0 ] && echo "write-areas: done. Reboot (scripts/net/ssh-phone.sh reboot); look for NEGRONI FW lines."
exit $result
