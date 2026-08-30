#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

PID_IDLE_MARGIN_MILLI=2000

number_to_milli()
{
	awk -v value="$1" 'BEGIN { printf "%.0f\n", value * 1000 }'
}

number_to_fixed()
{
	awk -v value="$1" 'BEGIN { printf "%.0f\n", value * 1000000 }'
}

activate_control_config()
{
	local point temperature percent converted=
	PID_TARGET_MILLI=$(number_to_milli "$CFG_PID_TARGET_C")
	PID_RELEASE_MILLI=$((PID_TARGET_MILLI - PID_IDLE_MARGIN_MILLI))
	PID_KP_FIXED=$(number_to_fixed "$CFG_PID_KP")
	PID_KI_FIXED=$(number_to_fixed "$CFG_PID_KI")
	PID_KD_FIXED=$(number_to_fixed "$CFG_PID_KD")
	PID_LIMIT_FIXED=$(number_to_fixed "$CFG_PID_INTEGRAL_LIMIT")
	CURVE_HYSTERESIS_MILLI=$(number_to_milli "$CFG_CURVE_HYSTERESIS_C")
	set -f
	for point in $(printf '%s' "$CFG_CURVE_POINTS" | tr ',' ' '); do
		temperature=${point%%:*}; percent=${point#*:}
		converted="${converted:+$converted,}$temperature:$(percent_to_pwm "$percent")"
	done
	set +f
	CURVE_POINTS_PWM=$converted
	MANUAL_PWM=$(percent_to_pwm "$CFG_MANUAL_OUTPUT_PERCENT")
}

temperature_filter_update()
{
	local now=$1 sample=$2 entry timestamp value kept= sorted middle cutoff
	if [ "$CFG_TEMPERATURE_FILTER" = none ]; then
		FILTER_BUFFER=
		FILTER_OUTPUT_MILLIC=$sample
		return
	fi
	cutoff=$((now - CFG_TEMPERATURE_FILTER_DURATION_S))
	for entry in $FILTER_BUFFER; do
		timestamp=${entry%%:*}; value=${entry#*:}
		is_uint "$timestamp" && is_uint "$value" && [ "$timestamp" -ge "$cutoff" ] || continue
		kept="${kept:+$kept }$entry"
	done
	FILTER_BUFFER="${kept:+$kept }$now:$sample"
	set -f
	# shellcheck disable=SC2086
	set -- $FILTER_BUFFER
	sorted=$(for entry in "$@"; do printf '%s\n' "${entry#*:}"; done | sort -n)
	# shellcheck disable=SC2086
	set -- $sorted
	middle=$((($# + 1) / 2))
	while [ "$middle" -gt 1 ]; do shift; middle=$((middle - 1)); done
	set +f
	FILTER_OUTPUT_MILLIC=$1
}

calculate_step_curve()
{
	local temperature=$1 point point_t point_pwm requested=0 threshold=0
	set -f
	# shellcheck disable=SC2046
	set -- $(printf '%s' "$CURVE_POINTS_PWM" | tr ',' ' ')
	for point in "$@"; do
		point_t=${point%%:*}; point_pwm=${point#*:}
		if [ "$temperature" -ge $((point_t * 1000)) ]; then
			requested=$point_pwm
			threshold=$((point_t * 1000))
		else
			break
		fi
	done
	set +f
	if [ -n "$LAST_CURVE_PWM" ] && [ "$requested" -lt "$LAST_CURVE_PWM" ] &&
		[ "$temperature" -ge $((LAST_CURVE_THRESHOLD - CURVE_HYSTERESIS_MILLI)) ]; then
		REQUESTED_PWM=$LAST_CURVE_PWM
	else
		REQUESTED_PWM=$requested
		LAST_CURVE_PWM=$requested
		LAST_CURVE_THRESHOLD=$threshold
	fi
}

calculate_smooth_curve()
{
	REQUESTED_PWM=$(awk -v points="$CURVE_POINTS_PWM" -v wanted="$1" '
		BEGIN {
			n = split(points, raw, ",")
			for (i = 1; i <= n; i++) {
				split(raw[i], pair, ":")
				x[i] = pair[1] * 1000
				y[i] = pair[2]
			}
			if (wanted <= x[1]) { print y[1]; exit }
			if (wanted >= x[n]) { print y[n]; exit }
			for (i = 1; i < n; i++) {
				dx[i] = x[i + 1] - x[i]
				d[i] = (y[i + 1] - y[i]) / dx[i]
			}
			m[1] = d[1]; m[n] = d[n - 1]
			for (i = 2; i < n; i++) {
				if (d[i - 1] == 0 || d[i] == 0 || d[i - 1] * d[i] <= 0)
					m[i] = 0
				else
					m[i] = 2 / (1 / d[i - 1] + 1 / d[i])
			}
			for (i = 1; i < n; i++) {
				if (d[i] == 0) { m[i] = 0; m[i + 1] = 0; continue }
				a = m[i] / d[i]; b = m[i + 1] / d[i]
				s = a * a + b * b
				if (s > 9) {
					scale = 3 / sqrt(s)
					m[i] = scale * a * d[i]
					m[i + 1] = scale * b * d[i]
				}
			}
			for (i = 1; i < n; i++) if (wanted <= x[i + 1]) {
				t = (wanted - x[i]) / dx[i]
				h00 = (2 * t * t * t - 3 * t * t + 1)
				h10 = (t * t * t - 2 * t * t + t)
				h01 = (-2 * t * t * t + 3 * t * t)
				h11 = (t * t * t - t * t)
				value = h00 * y[i] + h10 * dx[i] * m[i] + h01 * y[i + 1] + h11 * dx[i] * m[i + 1]
				if (value < y[i]) value = y[i]
				if (value > y[i + 1]) value = y[i + 1]
				printf "%.0f\n", value
				exit
			}
		}' ) || return 1
	LAST_CURVE_PWM=$REQUESTED_PWM
}

temperature_filter_reset()
{
	FILTER_BUFFER=
	FILTER_OUTPUT_MILLIC=
}

pid_reset()
{
	PID_I_FIXED=0
	PID_COOLING_ACTIVE=0
	PID_LAST_TEMP=
	PID_LAST_UPTIME=
}

curve_reset()
{
	LAST_CURVE_PWM=
	LAST_CURVE_THRESHOLD=0
}

reset_control_state()
{
	REQUESTED_PWM=0
	temperature_filter_reset
	pid_reset
	curve_reset
}

calculate_pid()
{
	local temperature=$1 now dt error proportional derivative=0 delta_i output candidate_i
	if [ "$PID_COOLING_ACTIVE" -ne 1 ]; then
		if [ "$temperature" -le "$PID_TARGET_MILLI" ]; then
			REQUESTED_PWM=0
			return 0
		fi
		PID_COOLING_ACTIVE=1
		PID_I_FIXED=0
		PID_LAST_TEMP=
		PID_LAST_UPTIME=
	elif [ "$temperature" -le "$PID_RELEASE_MILLI" ]; then
		pid_reset
		REQUESTED_PWM=0
		return 0
	fi
	now=$(read_uptime) || return 1
	error=$((temperature - PID_TARGET_MILLI))
	proportional=$((error * PID_KP_FIXED / 1000))
	if [ -z "$PID_LAST_UPTIME" ] || [ -z "$PID_LAST_TEMP" ] ||
		[ "$now" -le "$PID_LAST_UPTIME" ] ||
		[ $((now - PID_LAST_UPTIME)) -gt $((CFG_CONTROL_INTERVAL_S * 5 + 5)) ]; then
		PID_I_FIXED=0
	else
		dt=$((now - PID_LAST_UPTIME))
		derivative=$(((temperature - PID_LAST_TEMP) * PID_KD_FIXED / 1000 / dt))
		delta_i=$((error * PID_KI_FIXED * dt / 1000))
		candidate_i=$((PID_I_FIXED + delta_i))
		if [ "$delta_i" -gt 0 ] &&
			[ $((proportional + PID_I_FIXED + derivative)) -ge 1000000 ]; then
			candidate_i=$PID_I_FIXED
		fi
		[ "$candidate_i" -ge 0 ] || candidate_i=0
		[ "$candidate_i" -le "$PID_LIMIT_FIXED" ] || candidate_i=$PID_LIMIT_FIXED
		PID_I_FIXED=$candidate_i
	fi
	output=$((proportional + PID_I_FIXED + derivative))
	[ "$output" -ge 0 ] || output=0
	[ "$output" -le 1000000 ] || output=1000000
	REQUESTED_PWM=$(((output * 255 + 500000) / 1000000))
	PID_LAST_TEMP=$temperature
	PID_LAST_UPTIME=$now
}
