#!/bin/sh
# Copy a program or script to the phone over SSH, run it, print its output and exit code.
# Main test loop for on-phone work (GPU/Metal/Wi-Fi probes). docs/usb-network.md.
#   scripts/net/phone-run.sh [-s | -e ENTITLEMENTS] [-f EXTRA]... [-k] [-d DIR] FILE [ARGS...]
#     -s       sign a copy ad hoc with userland/ssh/entitlements.plist before the copy (macOS
#              codesign, else ldid); the negroni kernel runs only signed Mach-O files
#     -e FILE  sign with these entitlements instead
#     -f EXTRA copy EXTRA into the same folder too (data files, dylibs); repeatable
#     -k       keep the files on the phone (default: remove them after the run)
#     -d DIR   folder on the phone (default /private/var/tmp/phone-run; root file system)
# Exit code: the program's exit code; 255 = SSH problem. Env as scripts/net/ssh-phone.sh
# (PHONE_IP, PHONE_USER, SSH_KEY, SSH_OPTS).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
dir=/private/var/tmp/phone-run
ents=; keep=0; extras=
while getopts se:f:kd:h o; do
  case $o in
  s) ents=$REPO/userland/ssh/entitlements.plist ;;
  e) ents=$OPTARG ;;
  f) [ -e "$OPTARG" ] || { echo "phone-run: no file $OPTARG" >&2; exit 2; }
     extras="$extras
$OPTARG" ;;
  k) keep=1 ;;
  d) dir=$OPTARG ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { sed -n 2,14p "$0"; exit 2; }
file=$1; shift
[ -f "$file" ] || { echo "phone-run: no file $file" >&2; exit 2; }
name=$(basename "$file")

# optional signing, on a copy (the original stays as it is)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/phone-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp "$file" "$tmp/$name"; chmod 755 "$tmp/$name"
if [ -n "$ents" ]; then
  [ -f "$ents" ] || { echo "phone-run: no entitlements file $ents" >&2; exit 2; }
  if command -v codesign >/dev/null 2>&1; then codesign --force -s - --entitlements "$ents" "$tmp/$name"
  elif command -v ldid >/dev/null 2>&1; then ldid -S"$ents" "$tmp/$name"
  else echo "phone-run: -s/-e need codesign (macOS) or ldid" >&2; exit 2; fi
elif command -v codesign >/dev/null 2>&1 && file "$tmp/$name" | grep -q Mach-O &&
     ! codesign -v "$tmp/$name" 2>/dev/null; then
  echo "phone-run: warning: $name is an unsigned Mach-O; the phone will refuse it (use -s)" >&2
fi

q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }   # shell-quote for the remote sh
qdir=$(q "$dir")

"$SSHP" "mkdir -p $qdir" </dev/null
old_ifs=$IFS; IFS='
'
# shellcheck disable=SC2086
"$SSHP" push "$tmp/$name" $extras "$dir/"
IFS=$old_ifs

cmd="cd $qdir && ./$(q "$name")"
for a in "$@"; do cmd="$cmd $(q "$a")"; done
echo "phone-run: $dir/$name $*" >&2
set +e
"$SSHP" "$cmd" </dev/null
rc=$?
set -e
if [ $keep = 0 ] && [ $rc != 255 ]; then
  rm_list=$(q "$dir/$name")
  old_ifs=$IFS; IFS='
'
  for x in $extras; do rm_list="$rm_list $(q "$dir/$(basename "$x")")"; done
  IFS=$old_ifs
  "$SSHP" "rm -rf $rm_list" </dev/null || true
fi
echo "phone-run: exit $rc" >&2
exit $rc
