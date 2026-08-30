#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

cat > "$TEST_TMP/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PWM_FAN_TEST_LOG"
EOF
chmod +x "$TEST_TMP/logger"

LOGGER=$TEST_TMP/logger
PWM_FAN_TEST_LOG=$TEST_TMP/events
export PWM_FAN_TEST_LOG
ACTIVE_FAULT=none
STATUS_WRITE_FAILED=0
MANUAL_TIMEOUT_FAILED=0
. "$PWM_FAN_LIB_DIR/daemon.sh"

record_control_fault temperature_unavailable full_output=1
record_control_fault temperature_unavailable full_output=1
status_result=fail
status_write()
{
	[ "$status_result" = pass ]
}
status_write_tracked || true
record_control_fault temperature_unavailable full_output=1
record_control_fault kernel_policy_unavailable full_output=1
record_control_fault kernel_policy_unavailable full_output=1
record_control_recovery
record_control_fault temperature_unavailable full_output=1

assert_eq "$(grep -c 'code=temperature_unavailable' "$PWM_FAN_TEST_LOG")" 2 \
	'other subsystem events do not repeat an active control fault'
assert_eq "$(grep -c 'code=kernel_policy_unavailable' "$PWM_FAN_TEST_LOG")" 1 \
	'alternating control faults keep independent transitions'
assert_eq "$(grep -c 'code=control_recovered' "$PWM_FAN_TEST_LOG")" 1 \
	'control recovery logs once'

HW_ACTUAL_PWM=128
record_pwm_recovery pwm_not_applied
record_pwm_recovery running
assert_eq "$(grep -c 'code=pwm_write_recovered' "$PWM_FAN_TEST_LOG")" 1 \
	'PWM write recovery logs once per transition'

status_write_tracked || true
status_write_tracked || true
status_result=pass
status_write_tracked
status_result=fail
status_write_tracked || true

assert_eq "$(grep -c 'code=status_write_failed' "$PWM_FAN_TEST_LOG")" 2 \
	'status write failure logs again after recovery'
assert_eq "$(grep -c 'code=status_write_recovered' "$PWM_FAN_TEST_LOG")" 1 \
	'status write recovery logs once'
