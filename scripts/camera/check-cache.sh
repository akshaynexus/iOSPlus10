#!/bin/sh
# Check the 20H392 dyld shared cache against what NegroniCamera.driver expects (userland/camera/README.md).
#   scripts/camera/check-cache.sh [CACHE]       (default out/dsc/cache/dyld_shared_cache_arm64; a few seconds)
# Output: out/camera/cache-check.txt. Needs ipsw (scripts/setup/native-tools.sh) and the extracted cache
# (scripts/camera/ios-stack.sh / the dsc step). Exit 1 when something does not match.
# Checks:
#  1. cache UUID and unslid base = NEGRONICAM_CACHE_UUID / CACHE_BASE in userland/camera/media_hooks.c
#  2. each hook target's unslid address = the table in media_hooks.c (the driver also checks it at run time and
#     leaves a method alone on a mismatch)
#  3. the H10ISP vtable versions (base 1, device 3, stream 2) = the layout camera_device.c builds
#  4. every symbol camera_device.c / media_hooks.c finds with dlsym() is exported by some image
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
C=${1:-$REPO/out/dsc/cache/dyld_shared_cache_arm64}
SRC=$REPO/userland/camera
OUTF=$REPO/out/camera/cache-check.txt
command -v ipsw >/dev/null || { echo "ipsw not found (scripts/setup/native-tools.sh)" >&2; exit 1; }
[ -f "$C" ] || { echo "missing $C" >&2; exit 1; }
mkdir -p "$REPO/out/camera"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
exec 3>"$OUTF"
log() { echo "$*"; echo "$*" >&3; }

# 1. UUID + base
uuid=$(ipsw dyld info "$C" 2>&1 | sed -n 's/.*> Cache UUID: *//p' | head -1)
want=$(sed -n 's/.*NEGRONICAM_CACHE_UUID *"\([0-9A-F-]*\)".*/\1/p' "$SRC/media_hooks.c" | head -1)
base=$(ipsw dyld info "$C" 2>&1 | sed -n 's/.*Shared Region:.*address: *\(0x[0-9A-Fa-f]*\).*/\1/p' | head -1)
wbase=$(sed -n 's/^#define CACHE_BASE *\(0x[0-9a-fA-F]*\).*/\1/p' "$SRC/media_hooks.c")
if [ "$uuid" = "$want" ]; then log "OK   cache UUID $uuid"; else log "BAD  cache UUID $uuid, media_hooks.c has $want"; fail=1; fi
if [ "$(printf '%d' "$base")" = "$(printf '%d' "$wbase")" ]; then log "OK   cache base $base"; else log "BAD  cache base $base, media_hooks.c has $wbase"; fail=1; fi

# 2. hook targets: the replacements[] table of media_hooks.c ({ "Class", "selector", 0xADDR, 0xFIRST, ..., instance, done })
ipsw dyld symaddr "$C" --image CMCapture > "$T/cmc.txt" 2>/dev/null
python3 - "$SRC/media_hooks.c" > "$T/table.txt" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
t = s[s.index('} replacements[] = {'):]
t = t[:t.index('};')]
for m in re.finditer(r'\{ "(\w+)", "([^"]+)", (0x[0-9a-f]+)UL, (0x[0-9a-f]+)u,[^}]*?(true|false), (true|false) \}', t, re.S):
    print(m.group(1), m.group(2), m.group(3), m.group(4), m.group(5))
PY
[ "$(wc -l < "$T/table.txt" | tr -d ' ')" -gt 0 ] || { log "BAD  no replacements[] table parsed"; fail=1; }
while read -r cls sel addr first inst; do
  sign='+'; [ "$inst" = true ] && sign='-'
  m="$sign[$cls $sel]"
  got=$(grep -F "	$m	CMCapture" "$T/cmc.txt" | head -1 | cut -f1 | tr -d ':')
  word=$(ipsw dyld dump "$C" "$addr" --size 4 2>/dev/null | awk '/^0000/{printf "0x%s%s%s%s", $5, $4, $3, $2}')
  if [ "$got" = "$addr" ] && [ "$word" = "$first" ]; then log "OK   $m $addr first word $word"
  else log "BAD  $m expected $addr/$first, cache ${got:-none}/${word:-?}"; echo x >> "$T/bad"; fi
done < "$T/table.txt"
[ ! -f "$T/bad" ] || fail=1

# 3. H10ISP vtables (the device/stream objects camera_device.c imitates)
ipsw dyld symaddr "$C" --image H10ISP.mediacapture > "$T/h10.txt" 2>/dev/null
ver() { a=$(grep -F "$1	H10ISP" "$T/h10.txt" | head -1 | cut -f1 | tr -d ':'); [ -n "$a" ] && ipsw dyld dump "$C" "$a" --addr --count 1 2>/dev/null | head -1; }
for pair in __ZL29kH10ISPCaptureDeviceBaseClass:0x1 __ZL25kH10ISPCaptureDeviceClass:0x3 __ZL29kH10ISPCaptureStreamBaseClass:0x1 __ZL25kH10ISPCaptureStreamClass:0x2; do
  s=${pair%%:*}; w=${pair#*:}; v=$(ver "$s" || true)
  if [ "$v" = "$w" ]; then log "OK   $s version $v"; else log "BAD  $s version ${v:-?}, expected $w"; fail=1; fi
done

# 4. dlsym() targets: exported ("(regular)") by one of these images
for img in CMCapture CMCaptureCore CoreMedia MediaToolbox VideoToolbox VCPHEVC.videocodec; do ipsw dyld symaddr "$C" --image "$img" 2>/dev/null >> "$T/exp.txt" || true; done
syms=$(cat "$SRC/camera_device.c" "$SRC/media_hooks.c" | grep -o 'dlsym([^,]*, "[A-Za-z0-9_]*")' | sed -E 's/.*"([A-Za-z0-9_]+)".*/\1/' | sort -u)
mdk=$(sed -n '/md_names\[MD_KEYS\] = {/,/};/p' "$SRC/camera_device.c" | grep -o '"kFig[A-Za-z0-9_]*"' | tr -d '"' | sort -u)
for s in $syms $mdk; do
  if grep -q "(regular) _$s\$" "$T/exp.txt"; then log "OK   export $s"; else log "BAD  export $s not found"; fail=1; fi
done
log "result: $([ $fail = 0 ] && echo PASS || echo FAIL) ($(date '+%Y-%m-%d %H:%M'), $C)"
exit $fail
