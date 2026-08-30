# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>
hardware_policy_refresh()
{
	local old_hwmon=$HW_HWMON old_hwmon_device=$HW_HWMON_DEVICE
	local old_thermal=$HW_THERMAL old_thermal_node=$HW_THERMAL_OF_NODE
	local old_cooling=$HW_COOLING old_fan_node=$HW_FAN_OF_NODE old_tach=$HW_TACH
	local old_error=$HW_DISCOVERY_ERROR old_available=$POLICY_AVAILABLE
	local old_levels=$POLICY_LEVELS old_points=$POLICY_POINTS old_max=$POLICY_MAX_STATE
	local old_policy_state=$POLICY_STATE old_floor=$POLICY_FLOOR_PWM
	if hardware_discover && policy_build; then
		return 0
	fi
	HW_HWMON=$old_hwmon
	HW_HWMON_DEVICE=$old_hwmon_device
	HW_THERMAL=$old_thermal
	HW_THERMAL_OF_NODE=$old_thermal_node
	HW_COOLING=$old_cooling
	HW_FAN_OF_NODE=$old_fan_node
	HW_TACH=$old_tach
	HW_DISCOVERY_ERROR=$old_error
	POLICY_AVAILABLE=$old_available
	POLICY_LEVELS=$old_levels
	POLICY_POINTS=$old_points
	POLICY_MAX_STATE=$old_max
	POLICY_STATE=$old_policy_state
	POLICY_FLOOR_PWM=$old_floor
	return 1
}
policy_state_reset()
{
	POLICY_AVAILABLE=0
	POLICY_LEVELS=
	POLICY_POINTS=
	POLICY_MAX_STATE=0
	POLICY_STATE=
	POLICY_FLOOR_PWM=
}

policy_pwm_for_state()
{
	local wanted=$1 state=0 pwm
	set -f
	for pwm in $POLICY_LEVELS; do
		if [ "$state" -eq "$wanted" ]; then printf '%s\n' "$pwm"; set +f; return 0; fi
		state=$((state + 1))
	done
	set +f
	return 1
}

policy_find_trip_node()
{
	local wanted=$1 node file phandle
	for node in "$HW_THERMAL_OF_NODE"/trips/*; do
		[ -d "$node" ] || continue
		file=$node/phandle; [ -r "$file" ] || file=$node/linux,phandle
		phandle=$(hardware_read_be32 "$file" 2>/dev/null || true)
		[ "$phandle" != "$wanted" ] || { printf '%s\n' "$node"; return 0; }
	done
	return 1
}

policy_build()
{
	local file fan_phandle map cells minimum maximum state trip_phandle trip_node
	local temperature hysteresis release pwm raw_points= count=0 actual_max point previous_pwm=-1 normalized=
	POLICY_AVAILABLE=0; POLICY_LEVELS=; POLICY_POINTS=; POLICY_MAX_STATE=0
	POLICY_LEVELS=$(hardware_read_be32_list "$HW_FAN_OF_NODE/cooling-levels") || return 1
	file=$HW_FAN_OF_NODE/phandle; [ -r "$file" ] || file=$HW_FAN_OF_NODE/linux,phandle
	 fan_phandle=$(hardware_read_be32 "$file") || return 1
	set -f
	for pwm in $POLICY_LEVELS; do
		is_uint "$pwm" && [ "$pwm" -le 255 ] || { set +f; return 1; }
		count=$((count + 1))
	done
	set +f
	[ "$count" -gt 0 ] || return 1
	POLICY_MAX_STATE=$((count - 1))
	actual_max=$(read_uint "$HW_COOLING/max_state" 2>/dev/null) || return 1
	[ "$actual_max" -eq "$POLICY_MAX_STATE" ] || return 1

	for map in "$HW_THERMAL_OF_NODE"/cooling-maps/*; do
		[ -d "$map" ] || continue
		cells=$(hardware_read_be32_list "$map/cooling-device" 2>/dev/null || true)
		set -f; set -- $cells; set +f
		[ "$#" -ge 3 ] || continue
		[ "$1" = "$fan_phandle" ] || continue
		minimum=$2; maximum=$3
		is_uint "$minimum" && is_uint "$maximum" || return 1
		[ "$minimum" -le "$maximum" ] && [ "$maximum" -le "$POLICY_MAX_STATE" ] || return 1
		state=$maximum
		trip_phandle=$(hardware_read_be32 "$map/trip" 2>/dev/null || true)
		trip_node=$(policy_find_trip_node "$trip_phandle" 2>/dev/null || true)
		[ -n "$trip_node" ] || return 1
		temperature=$(hardware_read_be32 "$trip_node/temperature" 2>/dev/null || true)
		hysteresis=$(hardware_read_be32 "$trip_node/hysteresis" 2>/dev/null || printf '0\n')
		is_uint "$temperature" && is_uint "$hysteresis" && [ "$hysteresis" -le "$temperature" ] || return 1
		release=$((temperature - hysteresis))
		pwm=$(policy_pwm_for_state "$state") || return 1
		raw_points="${raw_points}${raw_points:+
}$temperature:$hysteresis:$release:$state:$pwm"
	done
	[ -n "$raw_points" ] || return 1
	# BusyBox sort does not interpret GNU field-key syntax consistently. Every
	# record begins with an unsigned temperature, so plain numeric sorting is
	# sufficient; duplicate trips are resolved deterministically below.
	POLICY_POINTS=$(printf '%s\n' "$raw_points" | sort -n | awk -F: '
		{
			trip=$1; hyst=$2; release=$3; state=$4; pwm=$5
			if (trip == saved_trip) {
				if (state >= saved_state) { saved_state=state; saved_pwm=pwm }
				if (hyst > saved_hyst) { saved_hyst=hyst; saved_release=trip-hyst }
				next
			}
			if (NR > 1) print saved_trip ":" saved_hyst ":" saved_release ":" saved_state ":" saved_pwm
			saved_trip=trip; saved_hyst=hyst; saved_release=release; saved_state=state; saved_pwm=pwm
		}
		END { if (NR) print saved_trip ":" saved_hyst ":" saved_release ":" saved_state ":" saved_pwm }
	') || return 1
	[ -n "$POLICY_POINTS" ] || return 1
	set -f
	for point in $POLICY_POINTS; do
		pwm=${point##*:}
		[ "$pwm" -ge "$previous_pwm" ] || { set +f; return 1; }
		if [ "$pwm" -gt "$previous_pwm" ]; then
			normalized="${normalized}${normalized:+
}$point"
		fi
		previous_pwm=$pwm
	done
	set +f
	POLICY_POINTS=$normalized
	POLICY_AVAILABLE=1
}

policy_floor_reset()
{
	POLICY_STATE=
	POLICY_FLOOR_PWM=
}

policy_point_for_state()
{
	local wanted=$1 point rest state
	set -f
	for point in $POLICY_POINTS; do
		rest=${point#*:}; rest=${rest#*:}; rest=${rest#*:}; state=${rest%%:*}
		[ "$state" -ne "$wanted" ] || { printf '%s\n' "$point"; set +f; return 0; }
	done
	set +f
	return 1
}

policy_floor_update()
{
	local temperature=$1 point trip rest release state candidate=0 current
	is_uint "$temperature" && [ "$POLICY_AVAILABLE" -eq 1 ] || return 1
	set -f
	if [ -z "$POLICY_STATE" ]; then
		# Conservative startup: a temperature inside a hysteresis band keeps the
		# higher state because it is already above that state's release point.
		for point in $POLICY_POINTS; do
			trip=${point%%:*}; rest=${point#*:}; rest=${rest#*:}; release=${rest%%:*}; rest=${rest#*:}; state=${rest%%:*}
			[ "$temperature" -ge "$release" ] && candidate=$state
		done
	else
		for point in $POLICY_POINTS; do
			trip=${point%%:*}; rest=${point#*:}; rest=${rest#*:}; release=${rest%%:*}; rest=${rest#*:}; state=${rest%%:*}
			[ "$temperature" -ge "$trip" ] && candidate=$state
		done
		if [ "$candidate" -lt "$POLICY_STATE" ]; then
			current=$(policy_point_for_state "$POLICY_STATE" 2>/dev/null || true)
			if [ -n "$current" ]; then
				rest=${current#*:}; rest=${rest#*:}; release=${rest%%:*}
				[ "$temperature" -lt "$release" ] || candidate=$POLICY_STATE
			fi
		fi
	fi
	set +f
	POLICY_STATE=$candidate
	POLICY_FLOOR_PWM=$(policy_pwm_for_state "$candidate") || return 1
}

policy_handoff()
{
	policy_floor_update "$1" || return 1
	pwm_apply_verified "$POLICY_FLOOR_PWM"
}
