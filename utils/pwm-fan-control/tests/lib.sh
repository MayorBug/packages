#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PACKAGE_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)
CONTROLLER=$PACKAGE_DIR/files/usr/sbin/pwm-fan-control
DEFAULT_CONFIG=$PACKAGE_DIR/files/etc/pwm-fan.conf
PWM_FAN_LIB_DIR=$PACKAGE_DIR/files/usr/lib/pwm-fan
export PWM_FAN_LIB_DIR
TEST_TMP=

setup_tmp()
{
	TEST_TMP=$(mktemp -d)
	trap 'rm -rf "$TEST_TMP"' EXIT INT TERM
}

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

assert_eq()
{
	[ "$1" = "$2" ] || fail "$3 (expected $2, got $1)"
	pass "$3"
}

expect_failure()
{
	if "$@" >/dev/null 2>&1; then
		fail "expected failure: $*"
	fi
}
