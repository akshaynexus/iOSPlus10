#!/bin/sh
# Host test of what powermenu-helper (setuid root) reads from the folder that mobile processes can write: userland/laurel/xnutils/helper_ios26.c + helper_files.c, built for this host, with their folder in a temp root (XT_ROOT).
#   scripts/laurel/root-helper-test.sh [TREE]    TREE: where the sources come from (default this repo; an older tree shows that these tests find the defect)
# The test runs as this user, who plays both the planting caller and the helper. It shows what the helper's code opens and prints; it does not run a setuid file. Nothing here proves anything about the phone.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-$REPO}
D=$(mktemp -d "${TMPDIR:-/tmp}/ldb-helper26.XXXXXX")
trap 'rm -rf -- "$D"' EXIT
S=$SRC/userland/laurel/xnutils
fails=0; n=0
cat > "$D/main.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
int xt_do_metaloption(const char *name);
int xt_do_metalstate(void);
int xt_do_bench_begin(void);
int xt_do_bench_end(void);
/* root's chown cannot run here: only the mode and the path count */
int test_chown(const char *p, uid_t u, gid_t g) { (void)p; (void)u; (void)g; return 0; }
int test_fchown(int fd, uid_t u, gid_t g) { (void)fd; (void)u; (void)g; return 0; }
int main(int argc, char **argv)
{
	(void)argc;
	if (!strcmp(argv[1], "metalstate")) return xt_do_metalstate();
	if (!strcmp(argv[1], "bench-begin")) return xt_do_bench_begin();
	if (!strcmp(argv[1], "bench-end")) return xt_do_bench_end();
	if (!strcmp(argv[1], "metaloption")) return xt_do_metaloption(argv[2]);
	return 2;
}
C
R=$D/root
DB=$R/private/var/db/negronimetal
cc -std=gnu11 -D_GNU_SOURCE -O1 -g -w -fsanitize=address,undefined -fno-sanitize-recover=undefined -DXT_IOS26=1 -DXT_ROOT="\"$R\"" -DXT_MOBILE_UID="$(id -u)" -Dchown=test_chown -Dfchown=test_fchown \
  -Dd_namlen=d_reclen -I"$S" -o "$D/h" "$D/main.c" "$S/helper_ios26.c" "$S/helper_files.c" || { echo "root-helper-test: FAILED: does not build" >&2; exit 1; }
SECRET="root-only-secret-text"
printf '%s\n' "$SECRET" > "$D/secret"
reset() { rm -rf "$R"; mkdir -p "$DB/stack"; chmod 777 "$DB/stack"; }
no() { fails=$((fails + 1)); echo "FAIL $name: $1"; printf '%s\n' "$o" | tail -3 | sed 's/^/     | /'; }
run() { n=$((n + 1)); name=$1; shift; o=$(timeout 20 "$@" 2>&1); rc=$?; }
ok_() { echo "ok   $name"; }
leak() { case "$o" in *"$SECRET"*) no "the secret reached the output" ;; *) ok_ ;; esac; }

reset; ln -s "$D/secret" "$DB/stack/bench-result"; run "F9 bench-end: a symlink at bench-result: its target is not read" "$D/h" bench-end; [ "$rc" = 0 ] || no "exit $rc"; leak
reset; ln "$D/secret" "$DB/stack/bench-result"; run "F9 bench-end: a hard link at bench-result: not read" "$D/h" bench-end; [ "$rc" = 0 ] || no "exit $rc"; leak
reset; mkfifo "$DB/stack/bench-result"; run "F9 bench-end: a FIFO at bench-result: no hang" "$D/h" bench-end; if [ "$rc" = 124 ]; then no "the helper hangs"; else ok_; fi
reset; printf 'PRESENTS=12\nSECONDS=1.00\n' > "$DB/stack/bench-result"; run "F9 bench-end: a plain file of the compositor: printed" "$D/h" bench-end; case "$o" in *PRESENTS=12*) ok_ ;; *) no "no result" ;; esac
reset; ln -s "$D/secret" "$DB/stack/active"; ln -s "$D/secret" "$DB/stack/state"; run "F9 metalstate: symlinks at active and state: not read" "$D/h" metalstate; [ "$rc" = 0 ] || no "exit $rc"; leak
reset; ln "$D/secret" "$DB/stack/active"; run "F9 metalstate: a hard link at active: not read" "$D/h" metalstate; leak
reset; mkfifo "$DB/stack/state"; run "F9 metalstate: a FIFO at state: no hang" "$D/h" metalstate; if [ "$rc" = 124 ]; then no "the helper hangs"; else ok_; fi
reset; printf 'hot it works\n' > "$DB/stack/active"; run "F9 metalstate: a plain file: read" "$D/h" metalstate; case "$o" in *ACTIVE=hot*) ok_ ;; *) no "no ACTIVE=hot" ;; esac
reset; run "F9 metaloption: the folder is sticky afterwards, also when it was 0777" "$D/h" metaloption hot; m=$(stat -c %a "$DB/stack" 2>/dev/null || stat -f %Lp "$DB/stack"); if [ "$m" = 1777 ]; then ok_; else no "mode $m"; fi
rm -rf "$R"; mkdir -p "$DB"; run "F9 metaloption: a new folder is sticky" "$D/h" metaloption hot; m=$(stat -c %a "$DB/stack" 2>/dev/null || stat -f %Lp "$DB/stack"); if [ "$m" = 1777 ]; then ok_; else no "mode $m"; fi
reset; ln -s "$D/secret" "$DB/stack/bench-on"; ln -s "$D/secret" "$DB/stack/bench-on.new"; run "F9 bench-begin: a symlink at bench-on and bench-on.new: the target stays" "$D/h" bench-begin
if [ "$rc" = 0 ] && [ "$(cat "$D/secret")" = "$SECRET" ] && [ ! -L "$DB/stack/bench-on" ]; then ok_; else no "exit $rc, target '$(cat "$D/secret")'"; fi
reset; rmdir "$DB/stack"; ln -s "$D" "$DB/stack"; run "F9 metaloption: stack is a symlink: refused" "$D/h" metaloption hot; if [ "$rc" != 0 ]; then ok_; else no "it went through the link"; fi
echo "root-helper-test: $n cases, $fails failed"
[ "$fails" = 0 ]
