#!/bin/sh
# Host test of the kernel's answer to dyld (patch 2957): the real function sweet_amfi_syscall, cut from the real bsd/kern/sweet_amfi.c of each built tree, with stubs around it.
#   scripts/laurel/amfi-dyld-test.sh [FILE...]     default: the sweet_amfi.c of out/laurel-kernel and out/laurel-kernel-ios26 of this checkout, when they exist
# Proves the answer on the host. That dyld of each root reads it, and that the setuid bit sets P_SUGID on the phone, is [V code], not run.
set -eu
. "$(dirname "$0")/../lib/env.sh"
[ $# != 0 ] || set -- "$OUT/laurel-kernel/xnu-src/xnu-8796.141.3/bsd/kern/sweet_amfi.c" "$OUT/laurel-kernel-ios26/src/xnu/bsd/kern/sweet_amfi.c"
D=$(mktemp -d "${TMPDIR:-/tmp}/ldb-amfi.XXXXXX")
trap 'rm -rf -- "$D"' EXIT
fails=0; seen=0
for f in "$@"; do
  [ -f "$f" ] || { echo "note no $f: not checked"; continue; }
  seen=$((seen + 1))
  awk '/^#define SWEET_AMFI_CHECK_DYLD_POLICY/ {p = 1} p {print} p && /^}/ {exit}' "$f" > "$D/fn.h"
  grep -q 'sweet_amfi_syscall' "$D/fn.h" || { echo "FAIL $f: no sweet_amfi_syscall"; fails=$((fails + 1)); continue; }
  cat > "$D/t.c" <<'C'
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define __unused __attribute__((unused))
typedef uint64_t user_addr_t;
struct proc { int sugid; };
static int proc_issetugid(struct proc *p) { return p->sugid; }
static int copyin(user_addr_t from, void *to, size_t n) { memcpy(to, (void *)from, n); return 0; }
static int copyout(const void *from, user_addr_t to, size_t n) { memcpy((void *)to, from, n); return 0; }
static void proc_selfname(char *b, int n) { snprintf(b, (size_t)n, "test"); }
#include "fn.h"
int main(void)
{
	struct proc plain = { 0 }, sugid = { 1 };
	uint64_t out = 0x55, in[2] = { 0, (uint64_t)(uintptr_t)&out };
	if (sweet_amfi_syscall(&plain, SWEET_AMFI_CHECK_DYLD_POLICY, (user_addr_t)(uintptr_t)in) != 0 || out != 0xff) { printf("a plain process: %llx, wanted ff\n", (unsigned long long)out); return 1; }
	out = 0x55;
	if (sweet_amfi_syscall(&sugid, SWEET_AMFI_CHECK_DYLD_POLICY, (user_addr_t)(uintptr_t)in) != 0 || out != 0) { printf("a setuid process: dyld may take DYLD_* (answer %llx, wanted 0)\n", (unsigned long long)out); return 1; }
	/* the other questions leave the output alone, as before */
	out = 0x55;
	if (sweet_amfi_syscall(&sugid, 7, 0) != 0 || out != 0x55) { printf("another question changed the output\n"); return 1; }
	return 0;
}
C
  cc -std=gnu11 -w -I"$D" -o "$D/t" "$D/t.c"
  if r=$("$D/t"); then echo "ok   F9 $(echo "$f" | sed 's#.*/out/##'): plain process 0xff, setuid process 0"; else echo "FAIL F9 $f: $r"; fails=$((fails + 1)); fi
done
[ "$seen" != 0 ] || { echo "amfi-dyld-test: FAILED: no kernel tree"; exit 1; }
[ "$fails" = 0 ]
