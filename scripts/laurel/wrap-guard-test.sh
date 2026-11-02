#!/bin/sh
# Host test of the crash guard of the two start programs: userland/laurel/notch/sb_wrap.c and flashlight/cc_wrap.c, built for this host with their paths in a temp folder and a stub of sysctlbyname. The "real" program is a script that prints what it got.
#   scripts/laurel/wrap-guard-test.sh [TREE]     TREE: where the sources come from (default this repo; an older tree shows that these tests find the defect)
# Proves the logic on the host. Nothing here proves anything about the phone.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-$REPO}
D=$(mktemp -d "${TMPDIR:-/tmp}/ldb-wrap.XXXXXX")
trap 'chmod -R u+w "$D" 2>/dev/null; rm -rf -- "$D"' EXIT
fails=0; n=0
mkdir -p "$D/inc/sys" "$D/s"
cat > "$D/inc/sys/sysctl.h" <<'H'
#include <stddef.h>
int sysctlbyname(const char *name, void *out, size_t *len, void *in, size_t inlen);
H
cat > "$D/stub.c" <<'C'
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
int sysctlbyname(const char *name, void *out, size_t *len, void *in, size_t inlen)
{
	const char *v = getenv(strcmp(name, "kern.bootargs") == 0 ? "FAKE_BOOTARGS" : "FAKE_SESSION");
	(void)in; (void)inlen;
	if (v == NULL) return -1;
	strncpy(out, v, *len);
	return 0;
}
C
cat > "$D/s/real" <<'R'
#!/bin/sh
echo "REAL DYLD=[${DYLD_INSERT_LIBRARIES:-}]"
R
chmod +x "$D/s/real"
: > "$D/s/lib-a"; : > "$D/s/lib-b"; : > "$D/s/lib-c"; : > "$D/s/bundle"
# the paths of the file become these; nothing else of the source changes
build() {  # SRC_FILE OUT NAMES-TO-DROP DEFINES...
  f=$1; o=$2; drop=$3; shift 3
  sed -E -e "/^#define +($drop) /d" -e "s#\"/dev/console\"#\"$D/s/console\"#" "$f" > "$D/$(basename "$o").c"
  cc -std=gnu11 -D_GNU_SOURCE -O1 -g -w -fsanitize=address,undefined -fno-sanitize-recover=undefined -I"$D/inc" "$@" -o "$o" "$D/$(basename "$o").c" "$D/stub.c" || { echo "wrap-guard-test: FAILED: $f does not build" >&2; exit 1; }
}
SB_ARGS="-DREAL=\"$D/s/real\" -DDYLIB=\"$D/s/lib-a\" -DCELLBAR=\"$D/s/lib-b\" -DRINGER=\"$D/s/lib-c\" -DLOG=\"$D/s/log\""
CC_ARGS="-DREAL=\"$D/s/real\" -DBUNDLE=\"$D/s/bundle\" -DOFF_FILE=\"$D/s/no-such-off-file\""
# shellcheck disable=SC2086
build "$SRC/userland/laurel/notch/sb_wrap.c" "$D/sb" 'REAL|DYLIB|CELLBAR|RINGER|STATE|LOG' $SB_ARGS -DSTATE="\"$D/s/sb.state\""
# shellcheck disable=SC2086
build "$SRC/userland/laurel/notch/sb_wrap.c" "$D/sb-ro" 'REAL|DYLIB|CELLBAR|RINGER|STATE|LOG' $SB_ARGS -DSTATE="\"$D/ro/sb.state\""
# shellcheck disable=SC2086
build "$SRC/userland/laurel/flashlight/cc_wrap.c" "$D/cc" 'REAL|BUNDLE|OFF_FILE|STATE' $CC_ARGS -DSTATE="\"$D/s/cc.state\""
# shellcheck disable=SC2086
build "$SRC/userland/laurel/flashlight/cc_wrap.c" "$D/cc-ro" 'REAL|BUNDLE|OFF_FILE|STATE' $CC_ARGS -DSTATE="\"$D/ro/cc.state\""
mkdir -p "$D/ro"; chmod 555 "$D/ro"
[ ! -w "$D/ro" ] || { echo "note this user can write a read-only folder (root?): the read-only cases test nothing"; }
export FAKE_SESSION=boot-1 FAKE_BOOTARGS="debug=0xc" ASAN_OPTIONS=detect_leaks=0
reset() { rm -f "$D/s/sb.state" "$D/s/cc.state" "$D/s/log" "$D/s/console"; : > "$D/s/console"; : > "$D/s/log"; }
t() {
  name=$1; want=$2; shift 2; n=$((n + 1))
  o=$("$@" 2>&1); rc=$?
  logs=$(cat "$D/s/log" "$D/s/console" 2>/dev/null)
  case "$rc:$o" in
  0:*"$want"*) echo "ok   $name" ;;
  *) fails=$((fails + 1)); echo "FAIL $name: exit $rc: $o" ;;
  esac
}
said() { n=$((n + 1)); if printf '%s' "$logs" | grep -qF -- "$2"; then echo "ok   $1"; else fails=$((fails + 1)); echo "FAIL $1: no line '$2' in: $logs"; fi; }
for w in sb cc; do
  case "$w" in sb) on="$D/s/lib-a:$D/s/lib-b:$D/s/lib-c"; line="LAUREL NOTCH"; kill="notch=0 cell=0 ringer=0" ;; cc) on="$D/s/bundle"; line="LAUREL FLASHLIGHT"; kill=torch=0 ;; esac
  reset; t "$w: the state file is written: inserted" "REAL DYLD=[$on]" "$D/$w"
  reset; t "F7 $w: the state file cannot be written: no library in this start, the real program runs" "REAL DYLD=[]" "$D/$w-ro"
  said "F7 $w: one off line says why" "off: no crash guard"
  reset; "$D/$w" >/dev/null; "$D/$w" >/dev/null; t "$w: third start in 30 s: no library, the real program runs" "REAL DYLD=[]" "$D/$w"
  reset; t "$w: kill switches: no library" "REAL DYLD=[]" env FAKE_BOOTARGS="$kill" "$D/$w"
  # the limit, as ios26-first-boot.md says: a start over 30 s after the one before it counts as new, so a slow crash is not counted
  reset; printf 'boot-1 1 %s\n' "$(($(date +%s) - 100))" > "$D/s/$w.state"; t "$w: a start 100 s after the last one: the count starts again (a slow crash is not counted: documented)" "REAL DYLD=[$on]" "$D/$w"
  [ "$(cut -d' ' -f2 "$D/s/$w.state")" = 0 ] || { fails=$((fails + 1)); echo "FAIL $w: the count: $(cat "$D/s/$w.state")"; }
  # a new boot has a new count
  reset; printf 'boot-0 5 %s\n' "$(date +%s)" > "$D/s/$w.state"; t "$w: another boot's state: the count starts again" "REAL DYLD=[$on]" "$D/$w"
done
echo "wrap-guard-test: $n cases, $fails failed"
[ "$fails" = 0 ]
