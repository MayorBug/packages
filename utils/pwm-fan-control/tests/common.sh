#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

COMMON=$PACKAGE_DIR/files/usr/lib/pwm-fan/common.sh

before=$(trap)
. "$COMMON"
after=$(trap)
assert_eq "$after" "$before" 'sourcing common helpers installs no traps'

printf '123\n' > "$TEST_TMP/value"
assert_eq "$(read_value "$TEST_TMP/value")" 123 'read_value reads one value'
assert_eq "$(read_uint "$TEST_TMP/value")" 123 'read_uint accepts unsigned integer'
printf '%s\n' -1 > "$TEST_TMP/value"
expect_failure read_uint "$TEST_TMP/value"

printf '42.75 1.00\n' > "$TEST_TMP/uptime"
PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime
assert_eq "$(monotonic_now)" 42 'monotonic time discards fractions'

printf '0\n' > "$TEST_TMP/slept"
sleep_test() { printf '%s\n' "$1" > "$TEST_TMP/slept"; }
PWM_FAN_SLEEP=sleep_test
deadline_sleep 47
assert_eq "$(cat "$TEST_TMP/slept")" 5 'deadline sleep uses remaining monotonic time'

printf 'old\n' > "$TEST_TMP/target"
printf 'new\n' | atomic_replace "$TEST_TMP/target" 0600
assert_eq "$(cat "$TEST_TMP/target")" new 'atomic replace installs stdin content'
[ "$(stat -c %a "$TEST_TMP/target")" = 600 ] || fail 'atomic replace mode is not 0600'

assert_eq "$(printf '%s' 'a\b"c' | json_escape)" 'a\\b\"c' \
	'JSON escaping handles slash and quote'
assert_eq "$(printf 'one\ttwo\rthree\bfour\ffive\nsix' | json_escape)" \
	'one\ttwo\rthree\bfour\ffive\nsix' \
	'JSON escaping handles whitespace control characters'
assert_eq "$(percent_to_pwm 0)" 0 'zero percent maps to raw zero'
assert_eq "$(percent_to_pwm 50)" 128 'half output maps to nearest raw PWM'
assert_eq "$(percent_to_pwm 100)" 255 'full output maps to raw 255'
expect_failure percent_to_pwm 101

pass 'common helper contract'
