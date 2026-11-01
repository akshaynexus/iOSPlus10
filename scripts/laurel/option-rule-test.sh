#!/bin/sh
# Host test of the Metal stack selector's rule (userland/laurel/metal/option/option_rule.h): bad setting, crash loop, reset, reported failure. Under 2 s, foreground.
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd)
O=$R/out/ios26/option-test; mkdir -p "$O"
${CC:-cc} -g -O1 -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=undefined -I"$R/userland/laurel/metal/option" "$R/userland/laurel/metal/option/option_rule_test.c" -o "$O/t"
"$O/t"
