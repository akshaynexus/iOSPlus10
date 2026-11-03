#!/bin/sh
# Host test of the Metal stack selector's rule and files (userland/laurel/metal/option/option_rule.h, option_store.h): bad setting, crash loop, reset, reported failure; a GPU hang, then reboots with no sync: the failed mark holds for that build. Under 2 s, foreground.
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd)
O=$R/out/ios26/option-test; mkdir -p "$O"
${CC:-cc} -g -O1 -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=undefined -I"$R/userland/laurel/metal/option" "$R/userland/laurel/metal/option/option_rule_test.c" -o "$O/t"
"$O/t"
# a root script that creates a file in stack/ stops the mobile compositor's writes: this was the cause of the hang at each boot. Only the compositor creates files there.
if grep -nE '(:|echo[^|;]*|touch[^|;]*)>? *[^ |;]*stack/(state|ok|failed)|touch [^ |;]*stack/(state|ok|failed)' "$R/scripts/laurel/"*.sh | grep -vE 'option-rule-test|xnutils-test|root-helper-test'; then echo "option-rule-test: FAIL: a script writes the selector's files as root"; exit 1; fi
