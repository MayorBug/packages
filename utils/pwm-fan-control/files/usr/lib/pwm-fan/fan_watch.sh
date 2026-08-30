# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>
fan_watch_reset()
{
	FANWATCH_STATE=idle
	FANWATCH_ZERO_COUNT=0
	FANWATCH_SPINUP_UNTIL=0
	FANWATCH_LAST_EXPECTED_PWM=0
}

fan_watch_update()
{
	local now=$1 expected=$2 actual=$3 pwm_state=$4 rpm=$5 tach_state=$6
	local threshold=${PWM_FAN_STALL_MIN_PWM:-26} spinup=${PWM_FAN_SPINUP_SECONDS:-5}
	is_uint "$now" && is_uint "$expected" || return 1
	if [ "$pwm_state" = unavailable ]; then FANWATCH_STATE=pwm_unavailable; FANWATCH_ZERO_COUNT=0; return 0; fi
	if [ "$pwm_state" != applied ] || ! is_uint "$actual" || [ "$actual" -ne "$expected" ]; then FANWATCH_STATE=pwm_not_applied; FANWATCH_ZERO_COUNT=0; return 0; fi
	case $tach_state in
		disabled) FANWATCH_STATE=idle; FANWATCH_ZERO_COUNT=0; return 0 ;;
		unavailable) FANWATCH_STATE=tach_unavailable; FANWATCH_ZERO_COUNT=0; return 0 ;;
		read_error) FANWATCH_STATE=tach_read_error; FANWATCH_ZERO_COUNT=0; return 0 ;;
	esac
	if [ "$expected" -lt "$threshold" ]; then
		FANWATCH_STATE=idle; FANWATCH_ZERO_COUNT=0; FANWATCH_SPINUP_UNTIL=0
	elif is_uint "$rpm" && [ "$rpm" -gt 0 ]; then
		FANWATCH_STATE=running; FANWATCH_ZERO_COUNT=0; FANWATCH_SPINUP_UNTIL=0
	else
		if [ "$FANWATCH_LAST_EXPECTED_PWM" -lt "$threshold" ]; then
			FANWATCH_SPINUP_UNTIL=$((now + spinup)); FANWATCH_ZERO_COUNT=0
		fi
		if [ "$now" -lt "$FANWATCH_SPINUP_UNTIL" ]; then
			FANWATCH_STATE=spinup
		else
			FANWATCH_ZERO_COUNT=$((FANWATCH_ZERO_COUNT + 1))
			if [ "$FANWATCH_ZERO_COUNT" -ge 3 ]; then FANWATCH_STATE=fan_failed; else FANWATCH_STATE=spinup; fi
		fi
	fi
	FANWATCH_LAST_EXPECTED_PWM=$expected
}
