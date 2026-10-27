#!/bin/sh
# Host test of the GPU policy component (userland/gpu-policy; docs/gpu-hybrid-plan.md), macOS and Linux:
#   1. builds userland/gpu-policy/tests/policy_test.c with the host cc and runs it (fake root in $TMPDIR);
#   2. on macOS, also compiles negroni_gpu_policy.c for arm64-apple-ios16.0 (-Wall -Werror) as a build check.
# Output: out/gpu-policy/. A few seconds; no tmux needed.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/userland/gpu-policy
O=$REPO/out/gpu-policy
mkdir -p "$O"
CC=${CC:-cc}
FW=""
[ "$(uname -s)" = Darwin ] && FW="-framework CoreFoundation"
# shellcheck disable=SC2086
$CC -std=gnu11 -Wall -Wextra -Werror -O1 -g -DSRCDIR="\"$SRC\"" -o "$O/policy_test" \
	"$SRC/tests/policy_test.c" "$SRC/negroni_gpu_policy.c" -lpthread $FW
"$O/policy_test"
if [ "$(uname -s)" = Darwin ]; then
	SDK=${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
	xcrun clang -target arm64-apple-ios16.0 -isysroot "$SDK" -std=gnu11 -Wall -Wextra -Werror -O2 \
		-c "$SRC/negroni_gpu_policy.c" -o "$O/negroni_gpu_policy.ios.o"
	echo "policy-test: iOS arm64 compile OK ($O/negroni_gpu_policy.ios.o)"
fi
