#!/bin/bash
# A wait for the GPU must sleep in the kernel, not ask in a loop. The real fence_wait_until + msm_fence_wait + mono_ns, cut from userland/negronigl/drm/negroni_drm.c (of a given commit too),
# against a host copy of the kernel's rule (RedwoodGPU.cpp millisecondsUntil + gpuWait, its clock = mach_continuous_time) with the two clocks of boot 11: CLOCK_MONOTONIC 18.57 s behind CLOCK_MONOTONIC_RAW.
#   scripts/laurel/test-fence-wait.sh [BASE_COMMIT]     with BASE_COMMIT: that commit's code is the control, and must show the busy loop
# Host only, quick. Exit 0: PASS.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cut_code() {  # the three functions, from the top of mono_ns to the end of fence_wait_until
  python3 -I - "$1" <<'P'
import re,sys
s=open(sys.argv[1]).read()
a=s.index('static int64_t\nmono_ns(void)')
b=s.index('/*\n * msm timeouts are absolute times.')
print(s[a:b])
P
}
run() {  # NAME FILE; prints the number of system calls of one wait for a GPU job of 39 ms
  cut_code "$2" > "$W/code.h"
  cat > "$W/t.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#define ETIMEDOUT_ ETIMEDOUT
enum { NGL_ABI_SCALAR = 1, NGL_ABI_MSM_STRUCT = 2 };
static int abi = NGL_ABI_MSM_STRUCT;
#define NGL_MSM_SEL(x) (x)
#define DRM_MSM_WAIT_FENCE 7
struct drm_msm_timespec { int64_t tv_sec, tv_nsec; };
struct drm_msm_wait_fence { uint32_t fence, pad; struct drm_msm_timespec timeout; uint32_t queueid; };
/* the phone's clocks: the test's time moves only with the kernel's waits and with each call */
static int64_t tick_ns; static const int64_t RAW_AHEAD_NS = 18570000000ll;
static int fake_clock(int id, struct timespec *t) { int64_t v = tick_ns + 39000000000ll - (id == CLOCK_MONOTONIC ? RAW_AHEAD_NS : 0); t->tv_sec = v / 1000000000ll; t->tv_nsec = v % 1000000000ll; return 0; }
#define clock_gettime fake_clock
/* the kernel: RedwoodGPU.cpp case kMsmWaitFence: patience = millisecondsUntil(timeout); gpuWait(fence, patience); 200 us between two looks; done at 39 ms */
static const int64_t DONE_AT_NS = 39000000ll, KERNEL_NOW_0 = 39000000000ll;
static unsigned calls, slept_calls;
static int msm_call(unsigned sel, void *arg, size_t n) {
	struct drm_msm_wait_fence *w = arg; (void)sel; (void)n;
	calls++; tick_ns += 10000;      /* one system call: 10 us */
	int64_t left = w->timeout.tv_sec * 1000000000ll + w->timeout.tv_nsec - (tick_ns + KERNEL_NOW_0);
	uint64_t patience = left <= 0 ? 0 : (uint64_t)left / 1000000;
	if (tick_ns >= DONE_AT_NS) return 0;
	if (patience == 0) return ETIMEDOUT;
	slept_calls++;
	int64_t until = tick_ns + (int64_t)patience * 1000000;
	while (tick_ns < until) { tick_ns += 200000; if (tick_ns >= DONE_AT_NS) return 0; }
	return ETIMEDOUT;
}
static int seq_wait(uint32_t seq, uint64_t ms) { (void)seq; (void)ms; return EIO; }
static bool seq_passed(uint32_t seq) { (void)seq; return false; }
#include "code.h"
int main(void) {
	int64_t deadline = mono_ns() + 1000000000ll; /* Mesa: one second from now on its clock */
	int e = fence_wait_until(3, deadline);
	printf("%d %u %u\n", e, calls, slept_calls);
	return 0;
}
C
  clang -O1 -w -I "$W" "$W/t.c" -o "$W/t"
  "$W/t"
}
new=$(run head "$REPO/userland/negronigl/drm/negroni_drm.c")
echo "this tree: answer, system calls, calls that slept: $new"
read -r e calls slept <<< "$new"
fail=0
[ "$e" = 0 ] && [ "$calls" -le 3 ] && [ "$slept" -ge 1 ] || { echo "test-fence-wait: the wait does not sleep"; fail=1; }
base=${1:-}
if [ -n "$base" ]; then
  git -C "$REPO" show "$base:userland/negronigl/drm/negroni_drm.c" > "$W/old.c"
  old=$(run base "$W/old.c")
  echo "control $base: answer, system calls, calls that slept: $old"
  read -r e calls slept <<< "$old"
  [ "$e" = 0 ] && [ "$calls" -ge 1000 ] && [ "$slept" = 0 ] || { echo "test-fence-wait: the control does not show the busy loop"; fail=1; }
fi
[ $fail = 0 ] && echo "test-fence-wait: PASS"
exit $fail
