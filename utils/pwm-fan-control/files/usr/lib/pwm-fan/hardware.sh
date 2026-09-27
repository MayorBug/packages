#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>

# Hardware and policy functions only. common.sh and config.sh are caller-owned.

hardware_state_reset()
{
	HW_HWMON=
	HW_HWMON_DEVICE=
	HW_THERMAL=
	HW_THERMAL_OF_NODE=
	HW_COOLING=
	HW_FAN_OF_NODE=
	HW_TACH=
	HW_DISCOVERY_ERROR=none
	HW_CPU_TEMPERATURE_MILLIC=
	HW_ACTUAL_PWM=
	HW_RPM=
	HW_TACH_STATE=unknown
	HW_REQUESTED_PWM=
	HW_PWM_STATE=unknown
	HW_WIFI_SENSORS=
	HW_WIFI_READINGS=
	HW_WIFI_TEMPERATURE_MILLIC=
	HW_WIFI_TEMPERATURE_SOURCE=
	HW_WIFI_STATE=disabled
}

hardware_read_be32_list()
{
	local bytes output= value
	[ -r "$1" ] || return 1
	bytes=$(hexdump -v -e '1/1 "%u "' "$1" 2>/dev/null) || return 1
	set -f; set -- $bytes; set +f
	[ "$#" -gt 0 ] && [ $(( $# % 4 )) -eq 0 ] || return 1
	while [ "$#" -ge 4 ]; do
		value=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
		output="${output}${output:+ }$value"
		shift 4
	done
	printf '%s\n' "$output"
}

hardware_read_be32()
{
	local values
	values=$(hardware_read_be32_list "$1") || return 1
	set -f; set -- $values; set +f
	[ "$#" -eq 1 ] || return 1
	printf '%s\n' "$1"
}

hardware_wifi_supported_name()
{
	local rest chip phy
	case $1 in mt*_phy*) ;; *) return 1 ;; esac
	rest=${1#mt}
	chip=${rest%%_phy*}
	phy=${rest#*_phy}
	case $chip in ''|*[!0-9]*) return 1 ;; esac
	case $phy in ''|*[!0-9]*) return 1 ;; esac
	[ "$rest" = "${chip}_phy${phy}" ]
}

hardware_wifi_discover()
{
	local root=${PWM_FAN_SYS_ROOT:-/sys} directory name records= names='|' matches=0 duplicate=0 checked=0
	HW_WIFI_SENSORS=
	HW_WIFI_READINGS=
	HW_WIFI_TEMPERATURE_MILLIC=
	HW_WIFI_TEMPERATURE_SOURCE=
	case $CFG_WIFI_SOURCE in
		off) HW_WIFI_STATE=disabled; return 0 ;;
	auto)
		for directory in "$root"/class/hwmon/hwmon*; do
			[ -d "$directory" ] || continue
			checked=$((checked + 1)); [ "$checked" -le 64 ] || break
			name=$(read_value "$directory/name" 2>/dev/null || true)
			hardware_wifi_supported_name "$name" || continue
			case $names in *"|$name|"*) duplicate=1 ;; *) names="${names}${name}|" ;; esac
			[ -r "$directory/temp1_input" ] || continue
			records="${records}${records:+
}$name|$directory/temp1_input"
		done
		[ "$duplicate" -eq 0 ] || { HW_WIFI_STATE=ambiguous; return 1; }
		[ -n "$records" ] || { HW_WIFI_STATE=unavailable; return 1; }
		HW_WIFI_SENSORS=$(printf '%s\n' "$records" | sort)
		HW_WIFI_STATE=waiting
		return 0 ;;
	esac
	hardware_wifi_supported_name "$CFG_WIFI_SOURCE" || {
		HW_WIFI_READINGS="$CFG_WIFI_SOURCE|null"; HW_WIFI_STATE=unavailable; return 1
	}
	for directory in "$root"/class/hwmon/hwmon*; do
		[ -d "$directory" ] || continue
		checked=$((checked + 1)); [ "$checked" -le 64 ] || break
		name=$(read_value "$directory/name" 2>/dev/null || true)
		[ "$name" = "$CFG_WIFI_SOURCE" ] || continue
		matches=$((matches + 1))
		[ -r "$directory/temp1_input" ] || continue
		records="$name|$directory/temp1_input"
	done
	if [ "$matches" -gt 1 ]; then HW_WIFI_READINGS="$CFG_WIFI_SOURCE|null"; HW_WIFI_STATE=ambiguous; return 1; fi
	[ "$matches" -eq 1 ] && [ -n "$records" ] || { HW_WIFI_READINGS="$CFG_WIFI_SOURCE|null"; HW_WIFI_STATE=unavailable; return 1; }
	HW_WIFI_SENSORS=$records
	HW_WIFI_STATE=waiting
}

hardware_wifi_read()
{
	local record name path directory current_name value readings= best= best_name=
	HW_WIFI_TEMPERATURE_MILLIC=
	HW_WIFI_TEMPERATURE_SOURCE=
	[ "$CFG_WIFI_SOURCE" != off ] || { HW_WIFI_READINGS=; HW_WIFI_STATE=disabled; return 1; }
	[ -n "$HW_WIFI_SENSORS" ] || return 1
	HW_WIFI_READINGS=
	while IFS= read -r record || [ -n "$record" ]; do
		[ -n "$record" ] || continue
		name=${record%%|*}; path=${record#*|}; directory=${path%/*}
		current_name=$(read_value "$directory/name" 2>/dev/null || true)
		if [ "$current_name" = "$name" ]; then
			value=$(read_uint "$path" 2>/dev/null || true)
		else
			value=
		fi
		if [ -n "$value" ] && [ "$value" -le 125000 ]; then
			readings="${readings}${readings:+
}$name|$value"
			if [ -z "$best" ] || [ "$value" -gt "$best" ]; then
				best=$value; best_name=$name
			fi
		else
			readings="${readings}${readings:+
}$name|null"
		fi
	done <<EOF
$HW_WIFI_SENSORS
EOF
	HW_WIFI_READINGS=$readings
	[ -n "$best" ] || { HW_WIFI_STATE=unavailable; return 1; }
	HW_WIFI_TEMPERATURE_MILLIC=$best
	HW_WIFI_TEMPERATURE_SOURCE=$best_name
	HW_WIFI_STATE=available
}

hardware_discover()
{
	local root=${PWM_FAN_SYS_ROOT:-/sys} directory name
	local hwmon_matches=0 thermal_matches=0 cooling_matches=0
	local cooling_device sole_cooling=
	local new_hwmon= new_hwmon_device= new_thermal= new_thermal_of_node=
	local new_cooling= new_fan_of_node= new_tach= error=none

	for directory in "$root"/class/hwmon/hwmon*; do
		[ -d "$directory" ] || continue
		name=$(read_value "$directory/name" 2>/dev/null || true)
		if [ "$name" = "$CFG_HWMON_NAME" ] && [ -r "$directory/pwm1" ]; then
			new_hwmon=$directory
			hwmon_matches=$((hwmon_matches + 1))
		fi
	done
	if [ "$hwmon_matches" -eq 1 ]; then
		[ -r "$new_hwmon/fan1_input" ] && new_tach=$new_hwmon/fan1_input
		new_hwmon_device=$(readlink -f "$new_hwmon/device" 2>/dev/null || true)
		new_fan_of_node=$(readlink -f "$new_hwmon_device/of_node" 2>/dev/null || true)
	else
		new_hwmon=; new_hwmon_device=; new_fan_of_node=; new_tach=
	fi

	for directory in "$root"/class/thermal/cooling_device*; do
		[ -d "$directory" ] || continue
		name=$(read_value "$directory/type" 2>/dev/null || true)
		[ "$name" = pwm-fan ] || continue
		cooling_matches=$((cooling_matches + 1))
		sole_cooling=$directory
		cooling_device=$(readlink -f "$directory/device" 2>/dev/null || true)
		[ -z "$new_hwmon_device" ] || [ "$cooling_device" != "$new_hwmon_device" ] ||
			new_cooling=$directory
	done
	[ -n "$new_cooling" ] || [ "$cooling_matches" -ne 1 ] || new_cooling=$sole_cooling

	for directory in "$root"/class/thermal/thermal_zone*; do
		[ -d "$directory" ] || continue
		name=$(read_value "$directory/type" 2>/dev/null || true)
		if [ "$name" = "$CFG_THERMAL_ZONE" ]; then
			new_thermal=$directory
			thermal_matches=$((thermal_matches + 1))
		fi
	done
	if [ "$thermal_matches" -eq 1 ]; then
		new_thermal_of_node=$root/firmware/devicetree/base/thermal-zones/$CFG_THERMAL_ZONE
		[ -d "$new_thermal_of_node" ] || new_thermal_of_node=
	else
		new_thermal=
	fi

	if [ "$hwmon_matches" -gt 1 ]; then error=fan_ambiguous
	elif [ "$thermal_matches" -gt 1 ]; then error=thermal_ambiguous
	elif [ "$hwmon_matches" -eq 0 ]; then error=fan_not_found
	elif [ "$thermal_matches" -eq 0 ]; then error=thermal_not_found
	elif [ -z "$new_hwmon_device" ] || [ -z "$new_fan_of_node" ]; then error=fan_device_tree_unavailable
	elif [ -z "$new_cooling" ]; then error=cooling_device_unavailable
	elif [ -z "$new_thermal_of_node" ]; then error=thermal_device_tree_unavailable
	fi
	HW_DISCOVERY_ERROR=$error
	[ "$error" = none ] || return 1

	HW_HWMON=$new_hwmon
	HW_HWMON_DEVICE=$new_hwmon_device
	HW_THERMAL=$new_thermal
	HW_THERMAL_OF_NODE=$new_thermal_of_node
	HW_COOLING=$new_cooling
	HW_FAN_OF_NODE=$new_fan_of_node
	HW_TACH=$new_tach
	hardware_wifi_discover || true
}

hardware_refresh()
{
	# hardware_discover commits paths only after complete success.
	hardware_discover
}

telemetry_read()
{
	local value
	HW_CPU_TEMPERATURE_MILLIC=
	HW_ACTUAL_PWM=
	HW_RPM=
	HW_TACH_STATE=disabled
	HW_WIFI_TEMPERATURE_MILLIC=
	HW_WIFI_TEMPERATURE_SOURCE=
	case ${CFG_WIFI_SOURCE:-off}:${HW_WIFI_STATE:-disabled} in
		off:*) HW_WIFI_READINGS=; HW_WIFI_STATE=disabled ;;
		*:available|*:waiting) HW_WIFI_READINGS=; HW_WIFI_STATE=unavailable ;;
		*:ambiguous|*:unavailable) ;;
		*) HW_WIFI_READINGS=; HW_WIFI_STATE=unavailable ;;
	esac
	value=$(read_uint "$HW_THERMAL/temp" 2>/dev/null) || return 1
	HW_CPU_TEMPERATURE_MILLIC=$value
	value=$(read_uint "$HW_HWMON/pwm1" 2>/dev/null) || return 1
	[ "$value" -le 255 ] || return 1
	HW_ACTUAL_PWM=$value
	hardware_wifi_read || true
	if [ "$CFG_TACH_ENABLED" -eq 1 ]; then
		if [ -z "$HW_TACH" ]; then
			HW_TACH_STATE=unavailable
		elif value=$(read_uint "$HW_TACH" 2>/dev/null); then
			HW_RPM=$value
			if [ "$value" -eq 0 ]; then HW_TACH_STATE=zero; else HW_TACH_STATE=running; fi
		else
			HW_TACH_STATE=read_error
		fi
	fi
}

pwm_apply_verified()
{
	local target=$1 actual attempt=1
	is_uint "$target" && [ "$target" -le 255 ] && [ -w "$HW_HWMON/pwm1" ] || { HW_PWM_STATE=unavailable; return 1; }
	HW_REQUESTED_PWM=$target
	while [ "$attempt" -le 2 ]; do
		actual=$(read_uint "$HW_HWMON/pwm1" 2>/dev/null || printf 'invalid\n')
		if [ "$actual" = "$target" ]; then HW_ACTUAL_PWM=$actual; HW_PWM_STATE=applied; return 0; fi
		if printf '%s\n' "$target" > "$HW_HWMON/pwm1" 2>/dev/null; then
			actual=$(read_uint "$HW_HWMON/pwm1" 2>/dev/null || printf 'invalid\n')
			if [ "$actual" = "$target" ]; then HW_ACTUAL_PWM=$actual; HW_PWM_STATE=applied; return 0; fi
		fi
		attempt=$((attempt + 1))
	done
	HW_ACTUAL_PWM=$actual
	HW_PWM_STATE=not_applied
	return 1
}

pwm_force_full()
{
	local target=$1
	is_uint "$target" && [ "$target" -le 255 ] || return 1
	HW_REQUESTED_PWM=$target
	[ -w "$HW_HWMON/pwm1" ] || { HW_PWM_STATE=unavailable; return 1; }
	if printf '%s\n' "$target" > "$HW_HWMON/pwm1" 2>/dev/null; then HW_PWM_STATE=unverified; return 0; fi
	HW_PWM_STATE=unavailable
	return 1
}
