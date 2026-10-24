#!/bin/sh
# Extract the audio DSP (ADSP) firmware of the NE2211 from the stock modem (NON-HLOS) image.
#   scripts/audio/extract-adsp-fw.sh [--dump]
# Default source: the full OTA ($BACKUP/NE2211_16.0.3.530_EX01_full.zip): payload-dumper-go -p modem.
# --dump: the read-only partition dump $BACKUP/partitions/modem_a.img.gz instead (same content
#         if the phone runs the OTA build; the script prints both checksums for comparison).
# Output (git-ignored, vendor firmware: never commit it):
#   out/firmware/modem/modem.img           the FAT image
#   out/firmware/adsp/adsp.mdt, adsp.bNN    (26 program headers; b24 has no file: BSS)
#   out/firmware/adsp/*.jsn                 servreg domains: adspr (root_pd), adspua (audio_pd), battmgr
#   out/firmware/adsp/SHA256SUMS            sha256 of every file
#   out/firmware/adsp/LISTING.txt           the full image/ listing (for the audio plan)
# Long (payload extraction of ~200 MB): run as  scripts/bg.sh adsp-fw scripts/audio/extract-adsp-fw.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
M=$OUT/firmware/modem
A=$OUT/firmware/adsp
mkdir -p "$M" "$A"

if [ "${1:-}" = "--dump" ]; then
  src=$BACKUP/partitions/modem_a.img.gz
  [ -f "$src" ] || { echo "no $src (scripts/backup/dump-partitions.sh)" >&2; exit 1; }
  gunzip -c "$src" > "$M/modem.img"
else
  [ -f "$OTA" ] || { echo "no OTA zip $OTA (scripts/backup/fetch-stock-ota.sh)" >&2; exit 1; }
  command -v payload-dumper-go >/dev/null || { echo "payload-dumper-go missing (docs/setup-*.md)" >&2; exit 1; }
  rm -rf "$M/payload"
  payload-dumper-go -o "$M/payload" -p modem "$OTA"
  mv "$M/payload/modem.img" "$M/modem.img"
  rm -rf "$M/payload"
fi

# The FAT image is untrusted input: run the reader isolated (-I), from the repo, not from out/.
F="python3 -I $REPO/scripts/audio/fatcopy.py"
$F "$M/modem.img" list image > "$A/LISTING.txt"
rm -f "$A"/adsp* "$A"/*.jsn
$F "$M/modem.img" get image 'adsp*' "$A"
$F "$M/modem.img" get image 'battmgr.jsn' "$A"    # charger PD of the ADSP (servreg, docs/audio-plan.md)
# The ADSP image has a hash segment and N load segments: check that every .bNN the .mdt names exists.
python3 -I - "$A" <<'EOF'
import os, struct, sys
d = sys.argv[1]
for mdt in sorted(f for f in os.listdir(d) if f.endswith('.mdt')):
    h = open(os.path.join(d, mdt), 'rb').read()
    if h[:4] != b'\x7fELF':
        sys.exit(f'{mdt}: not an ELF header')
    is64 = h[4] == 2
    phoff = struct.unpack_from('<Q' if is64 else '<I', h, 32 if is64 else 28)[0]
    phnum = struct.unpack_from('<H', h, 56 if is64 else 44)[0]
    stem, low, high, n = mdt[:-4], None, 0, 0
    for i in range(phnum):
        o = phoff + i * (56 if is64 else 32)
        if is64:
            ptype, flags, off, va, pa, filesz, memsz = struct.unpack_from('<IIQQQQQ', h, o)
        else:
            ptype, off, va, pa, filesz, memsz, flags = struct.unpack_from('<IIIIIII', h, o)
        seg = os.path.join(d, f'{stem}.b{i:02d}')
        kind = (flags >> 24) & 7          # QCOM_MDT_TYPE: 2 = hash segment
        if ptype == 1 and kind != 2 and memsz:
            low = pa if low is None else min(low, pa)
            high = max(high, pa + memsz)
        if filesz and not os.path.exists(seg):
            sys.exit(f'{mdt}: segment {i} ({filesz} bytes) has no file {seg}')
        n += 1
    reloc = any((struct.unpack_from('<I', h, phoff + i * (56 if is64 else 32) + (4 if is64 else 24))[0] >> 27) & 1
                for i in range(phnum))
    print(f'{mdt}: {"ELF64" if is64 else "ELF32"}, {n} program headers, load {low:#x}..{high:#x} '
          f'({(high - low) / 1048576:.1f} MiB), relocatable {reloc}')
EOF
(cd "$A" && { sha256sum adsp* *.jsn 2>/dev/null || shasum -a 256 adsp* *.jsn; } > SHA256SUMS)
echo "modem.img sha256: $( (sha256sum "$M/modem.img" 2>/dev/null || shasum -a 256 "$M/modem.img") | cut -d' ' -f1)"
du -ch "$A"/adsp* | tail -1
echo "$(ls "$A"/adsp.* "$A"/*.jsn | wc -l | tr -d ' ') files in $A (SHA256SUMS, LISTING.txt)"
echo "next: scripts/audio/mkadsparea.py out/firmware/adsp-area.bin (kernel patch 0240, negroniadsp=1)"
