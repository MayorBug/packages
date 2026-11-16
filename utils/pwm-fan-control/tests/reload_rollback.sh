#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lifecycle_fixture.sh"
. "$PWM_FAN_LIB_DIR/common.sh"
. "$PWM_FAN_LIB_DIR/config.sh"
. "$PWM_FAN_LIB_DIR/hardware.sh"
. "$PWM_FAN_LIB_DIR/policy.sh"
. "$PWM_FAN_LIB_DIR/control.sh"
. "$PWM_FAN_LIB_DIR/daemon.sh"

PWM_FAN_SYS_ROOT=$sys
RUN_DIR=$run
CONFIG_FILE=$config
LOGGER=$bin/logger
PWM_FAN_TEST_LOG=$TEST_TMP/events
export PWM_FAN_TEST_LOG
read_uptime() { printf '0\n'; }
# Both destination modes must reject a failed handoff without losing live state.
pwm_apply_verified() { return 1; }
for candidate in kernel disabled; do
	config_parse "$DEFAULT_CONFIG"
	CFG_MODE=manual
	validate_config
	ACTIVE_MODE=manual
	hardware_state_reset
	policy_state_reset
	hardware_discover
	policy_build
	policy_floor_update 50000
	old_points=$POLICY_POINTS
	config_render > "$CONFIG_FILE"
	sed "s/^mode=.*/mode=$candidate/" "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
	mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
	: > "$TEST_TMP/events"
	expect_failure reload_config
	assert_eq "$ACTIVE_MODE" manual "failed $candidate handoff keeps active Manual mode"
	assert_eq "$CFG_MODE" manual "failed $candidate handoff restores runtime configuration"
	assert_eq "$POLICY_POINTS" "$old_points" "failed $candidate handoff restores policy"
	assert_eq "$HW_HWMON" "$sys/class/hwmon/hwmon0" "failed $candidate handoff restores hardware path"
	assert_eq "$(cat "$sys/class/hwmon/hwmon0/pwm1")" 255 "failed $candidate handoff requests strongest validated cooling"
	grep -q 'code=kernel_handoff_failed' "$TEST_TMP/events" || fail 'missing handoff failure event'
done
