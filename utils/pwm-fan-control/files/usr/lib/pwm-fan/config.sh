#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>

# Configuration ownership only. common.sh must be sourced by the caller.

CFG_KEYS='config_version mode control_interval_s hwmon_name thermal_zone tach_enabled temperature_filter temperature_filter_duration_s modem_source modem_http_host modem_at_device modem_interval_s pid_target_c pid_kp pid_ki pid_kd pid_integral_limit curve_style curve_hysteresis_c curve_points manual_output_percent manual_timeout_min'

config_defaults()
{
	local key value defaults=
	CFG_CONFIG_VERSION=2
	CFG_MODE=kernel
	CFG_CONTROL_INTERVAL_S=2
	CFG_HWMON_NAME=pwmfan
	CFG_THERMAL_ZONE=cpu-thermal
	CFG_TACH_ENABLED=1
	CFG_TEMPERATURE_FILTER=median
	CFG_TEMPERATURE_FILTER_DURATION_S=10
	CFG_MODEM_SOURCE=off
	CFG_MODEM_HTTP_HOST=192.168.224.1
	CFG_MODEM_AT_DEVICE=/dev/ttyUSB2
	CFG_MODEM_INTERVAL_S=15
	CFG_PID_TARGET_C=55
	CFG_PID_KP=0.1
	CFG_PID_KI=0.0005
	CFG_PID_KD=0.10
	CFG_PID_INTEGRAL_LIMIT=0.60
	CFG_CURVE_STYLE=smooth
	CFG_CURVE_HYSTERESIS_C=2
	CFG_CURVE_POINTS=45:0,55:38,65:50,75:75,85:100
	CFG_MANUAL_OUTPUT_PERCENT=50
	CFG_MANUAL_TIMEOUT_MIN=0
	if [ -z "${CFG_DEFAULT_VALUES:-}" ]; then
		for key in $CFG_KEYS; do
			value=$(config_get_value "$key") || return 1
			defaults="${defaults}${defaults:+
}$key|$value"
		done
		CFG_DEFAULT_VALUES=$defaults
	fi
	CFG_SEEN_KEYS=
	CFG_RAW_VALUES=
	CFG_DIAGNOSTICS=
	CFG_ERROR_COUNT=0
	CFG_WARNING_COUNT=0
	CFG_DIAGNOSTIC_COUNT=0
	CFG_DIAGNOSTICS_TRUNCATED=0
}

config_default()
{
	local wanted=$1 record key
	while IFS= read -r record || [ -n "$record" ]; do
		key=${record%%|*}
		[ "$key" != "$wanted" ] || { printf '%s\n' "${record#*|}"; return 0; }
	done <<EOF
$CFG_DEFAULT_VALUES
EOF
	return 1
}

config_trim()
{
	printf '%s\n' "$1" | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }'
}

config_has_key()
{
	case " $CFG_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

config_seen()
{
	case " $CFG_SEEN_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

config_line()
{
	local wanted=$1 record key rest
	while IFS= read -r record || [ -n "$record" ]; do
		key=${record%%|*}; rest=${record#*|}
		[ "$key" != "$wanted" ] || { printf '%s\n' "${rest%%|*}"; return 0; }
	done <<EOF
$CFG_RAW_VALUES
EOF
	printf '0\n'
}

config_diag()
{
	local severity=$1 code=$2 key=$3 line=$4 value=$5 default_value=$6 message=$7 record
	if [ "${CFG_DIAGNOSTIC_COUNT:-0}" -ge 64 ]; then
		if [ "${CFG_DIAGNOSTICS_TRUNCATED:-0}" -eq 0 ]; then
			CFG_DIAGNOSTICS=$(printf '%s\n' "$CFG_DIAGNOSTICS" | sed '$d')
			record='warning|diagnostics_truncated||0|||Additional configuration diagnostics were omitted.'
			CFG_DIAGNOSTICS="${CFG_DIAGNOSTICS}${CFG_DIAGNOSTICS:+
}$record"
			CFG_DIAGNOSTICS_TRUNCATED=1
		fi
		return 0
	fi
	if [ "$line" -eq 0 ] && [ -n "$key" ] && config_seen "$key"; then
		line=$(config_line "$key")
	fi
	value=$(printf '%s' "$value" | tr '\t\r\n|' '    ' | cut -c1-240)
	message=$(printf '%s' "$message" | tr '\t\r\n|' '    ' | cut -c1-240)
	record="$severity|$code|$key|$line|$value|$default_value|$message"
	CFG_DIAGNOSTICS="${CFG_DIAGNOSTICS}${CFG_DIAGNOSTICS:+
}$record"
	CFG_DIAGNOSTIC_COUNT=$((CFG_DIAGNOSTIC_COUNT + 1))
	if [ "$severity" = error ]; then
		CFG_ERROR_COUNT=$((CFG_ERROR_COUNT + 1))
	else
		CFG_WARNING_COUNT=$((CFG_WARNING_COUNT + 1))
	fi
}

config_set_value()
{
	local key=$1 value=$2
	case $key in
		config_version) CFG_CONFIG_VERSION=$value ;;
		mode) CFG_MODE=$value ;;
		control_interval_s) CFG_CONTROL_INTERVAL_S=$value ;;
		hwmon_name) CFG_HWMON_NAME=$value ;;
		thermal_zone) CFG_THERMAL_ZONE=$value ;;
		tach_enabled) CFG_TACH_ENABLED=$value ;;
		temperature_filter) CFG_TEMPERATURE_FILTER=$value ;;
		temperature_filter_duration_s) CFG_TEMPERATURE_FILTER_DURATION_S=$value ;;
		modem_source) CFG_MODEM_SOURCE=$value ;;
		modem_http_host) CFG_MODEM_HTTP_HOST=$value ;;
		modem_at_device) CFG_MODEM_AT_DEVICE=$value ;;
		modem_interval_s) CFG_MODEM_INTERVAL_S=$value ;;
		pid_target_c) CFG_PID_TARGET_C=$value ;;
		pid_kp) CFG_PID_KP=$value ;;
		pid_ki) CFG_PID_KI=$value ;;
		pid_kd) CFG_PID_KD=$value ;;
		pid_integral_limit) CFG_PID_INTEGRAL_LIMIT=$value ;;
		curve_style) CFG_CURVE_STYLE=$value ;;
		curve_hysteresis_c) CFG_CURVE_HYSTERESIS_C=$value ;;
		curve_points) CFG_CURVE_POINTS=$value ;;
		manual_output_percent) CFG_MANUAL_OUTPUT_PERCENT=$value ;;
		manual_timeout_min) CFG_MANUAL_TIMEOUT_MIN=$value ;;
		*) return 1 ;;
	esac
}

config_get_value()
{
	case $1 in
		config_version) printf '%s\n' "$CFG_CONFIG_VERSION" ;;
		mode) printf '%s\n' "$CFG_MODE" ;;
		control_interval_s) printf '%s\n' "$CFG_CONTROL_INTERVAL_S" ;;
		hwmon_name) printf '%s\n' "$CFG_HWMON_NAME" ;;
		thermal_zone) printf '%s\n' "$CFG_THERMAL_ZONE" ;;
		tach_enabled) printf '%s\n' "$CFG_TACH_ENABLED" ;;
		temperature_filter) printf '%s\n' "$CFG_TEMPERATURE_FILTER" ;;
		temperature_filter_duration_s) printf '%s\n' "$CFG_TEMPERATURE_FILTER_DURATION_S" ;;
		modem_source) printf '%s\n' "$CFG_MODEM_SOURCE" ;;
		modem_http_host) printf '%s\n' "$CFG_MODEM_HTTP_HOST" ;;
		modem_at_device) printf '%s\n' "$CFG_MODEM_AT_DEVICE" ;;
		modem_interval_s) printf '%s\n' "$CFG_MODEM_INTERVAL_S" ;;
		pid_target_c) printf '%s\n' "$CFG_PID_TARGET_C" ;;
		pid_kp) printf '%s\n' "$CFG_PID_KP" ;;
		pid_ki) printf '%s\n' "$CFG_PID_KI" ;;
		pid_kd) printf '%s\n' "$CFG_PID_KD" ;;
		pid_integral_limit) printf '%s\n' "$CFG_PID_INTEGRAL_LIMIT" ;;
		curve_style) printf '%s\n' "$CFG_CURVE_STYLE" ;;
		curve_hysteresis_c) printf '%s\n' "$CFG_CURVE_HYSTERESIS_C" ;;
		curve_points) printf '%s\n' "$CFG_CURVE_POINTS" ;;
		manual_output_percent) printf '%s\n' "$CFG_MANUAL_OUTPUT_PERCENT" ;;
		manual_timeout_min) printf '%s\n' "$CFG_MANUAL_TIMEOUT_MIN" ;;
		*) return 1 ;;
	esac
}

config_parse()
{
	local file=$1 bytes line key value line_number=0 key_default
	config_defaults
	[ -f "$file" ] || {
		config_diag error config_missing '' 0 "$file" '' 'Configuration file not found.'
		return 1
	}
	bytes=$(wc -c < "$file" 2>/dev/null || printf '0\n')
	is_uint "$bytes" && [ "$bytes" -le 16384 ] || {
		config_diag error config_too_large '' 0 "$bytes" 16384 'Configuration exceeds 16 KiB.'
		return 1
	}
	while IFS= read -r line || [ -n "$line" ]; do
		line_number=$((line_number + 1))
		line=$(config_trim "$line")
		case $line in ''|'#'*) continue ;; esac
		case $line in *=*) ;; *)
			config_diag error malformed_line '' "$line_number" "$line" '' 'Expected key=value.'
			continue ;;
		esac
		key=$(config_trim "${line%%=*}")
		value=$(config_trim "${line#*=}")
		if [ -z "$key" ] || [ -z "$value" ]; then
			config_diag error empty_key_or_value "$key" "$line_number" "$value" '' 'Key and value must be non-empty.'
			continue
		fi
		if [ "$key" = pid_hysteresis_c ]; then
			config_diag warning obsolete_key_ignored "$key" "$line_number" "$value" '' 'Obsolete setting ignored. Auto uses a fixed idle deadband.'
			continue
		fi
		if ! config_has_key "$key"; then
			config_diag error unknown_key "$key" "$line_number" "$value" '' 'Unknown configuration key.'
			continue
		fi
		if config_seen "$key"; then
			config_diag error duplicate_key "$key" "$line_number" "$value" "$(config_default "$key")" 'Duplicate configuration key.'
			continue
		fi
		case $value in *'#'*|*'"'*|*"'"*|*'`'*|*'$'*|*'\\'*)
			config_diag error unsupported_syntax "$key" "$line_number" "$value" "$(config_default "$key")" 'Quotes, comments, escapes and expansion are unsupported.'
			continue ;;
		esac
		CFG_SEEN_KEYS="${CFG_SEEN_KEYS}${CFG_SEEN_KEYS:+ }$key"
		CFG_RAW_VALUES="${CFG_RAW_VALUES}${CFG_RAW_VALUES:+
}$key|$line_number|$value"
		config_set_value "$key" "$value"
	done < "$file"
	for key in $CFG_KEYS; do
		if ! config_seen "$key"; then
			key_default=$(config_default "$key")
			config_diag warning missing_key_defaulted "$key" 0 '' "$key_default" 'Missing key uses the current default.'
		fi
	done
	[ "$CFG_ERROR_COUNT" -eq 0 ]
}

config_uint_range()
{
	local key=$1 value=$2 minimum=$3 maximum=$4
	if ! is_uint "$value" || [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
		config_diag error invalid_value "$key" 0 "$value" "$(config_default "$key")" "Expected integer $minimum-$maximum."
		return 1
	fi
}

config_number_range()
{
	local key=$1 value=$2 minimum=$3 maximum=$4
	if ! printf '%s\n' "$value" | awk -v min="$minimum" -v max="$maximum" '
		$0 ~ /^[0-9]+([.][0-9]+)?$/ && $0 + 0 >= min && $0 + 0 <= max { ok=1 }
		END { exit !ok }'; then
		config_diag error invalid_value "$key" 0 "$value" "$(config_default "$key")" "Expected number $minimum-$maximum."
		return 1
	fi
}

config_validate_points()
{
	local old_ifs point temperature percent count=0 previous_t=-1 previous_p=-1
	old_ifs=$IFS; IFS=,
	set -f; set -- $CFG_CURVE_POINTS; set +f; IFS=$old_ifs
	for point in "$@"; do
		case $point in *:*:*) count=99; break ;; *:*) ;; *) count=99; break ;; esac
		temperature=${point%%:*}; percent=${point#*:}
		if ! is_uint "$temperature" || ! is_uint "$percent" ||
			[ "$temperature" -lt 20 ] || [ "$temperature" -gt 125 ] ||
			[ "$percent" -gt 100 ] || [ "$temperature" -le "$previous_t" ] ||
			[ "$percent" -lt "$previous_p" ]; then count=99; break; fi
		previous_t=$temperature; previous_p=$percent; count=$((count + 1))
	done
	if [ "$count" -lt 2 ] || [ "$count" -gt 10 ]; then
		config_diag error invalid_value curve_points 0 "$CFG_CURVE_POINTS" "$(config_default curve_points)" 'Expected 2-10 ascending temperature:percent pairs with nondecreasing output.'
		return 1
	fi
}

config_validate()
{
	local failed=0
	[ "$CFG_CONFIG_VERSION" = 2 ] || { config_diag error unsupported_version config_version 0 "$CFG_CONFIG_VERSION" 2 'Unsupported config version.'; failed=1; }
	case $CFG_MODE in kernel|auto|curve|manual|disabled) ;; *) config_diag error invalid_value mode 0 "$CFG_MODE" kernel 'Expected kernel, auto, curve, manual, or disabled.'; failed=1 ;; esac
	config_uint_range control_interval_s "$CFG_CONTROL_INTERVAL_S" 1 60 || failed=1
	case $CFG_HWMON_NAME in ''|*[!A-Za-z0-9_.-]*) config_diag error invalid_value hwmon_name 0 "$CFG_HWMON_NAME" pwmfan 'Expected a safe sysfs component.'; failed=1 ;; *) [ "${#CFG_HWMON_NAME}" -le 64 ] || { config_diag error invalid_value hwmon_name 0 "$CFG_HWMON_NAME" pwmfan 'Expected at most 64 characters.'; failed=1; } ;; esac
	case $CFG_THERMAL_ZONE in ''|*[!A-Za-z0-9_.-]*) config_diag error invalid_value thermal_zone 0 "$CFG_THERMAL_ZONE" cpu-thermal 'Expected a safe sysfs component.'; failed=1 ;; *) [ "${#CFG_THERMAL_ZONE}" -le 64 ] || { config_diag error invalid_value thermal_zone 0 "$CFG_THERMAL_ZONE" cpu-thermal 'Expected at most 64 characters.'; failed=1; } ;; esac
	case $CFG_TACH_ENABLED in 0|1) ;; *) config_diag error invalid_value tach_enabled 0 "$CFG_TACH_ENABLED" 1 'Expected 0 or 1.'; failed=1 ;; esac
	case $CFG_TEMPERATURE_FILTER in none|median) ;; *) config_diag error invalid_value temperature_filter 0 "$CFG_TEMPERATURE_FILTER" median 'Expected none or median.'; failed=1 ;; esac
	case $CFG_TEMPERATURE_FILTER_DURATION_S in
		5|10|15) ;;
		*) config_diag error invalid_value temperature_filter_duration_s 0 "$CFG_TEMPERATURE_FILTER_DURATION_S" 10 'Expected 5, 10, or 15 seconds.'; failed=1 ;;
	esac
	case $CFG_MODEM_SOURCE in off|qmanager_http|quectel_at) ;; *) config_diag error invalid_value modem_source 0 "$CFG_MODEM_SOURCE" off 'Expected off, qmanager_http, or quectel_at.'; failed=1 ;; esac
	case $CFG_MODEM_HTTP_HOST in ''|-*|*[!A-Za-z0-9.-]*) config_diag error invalid_value modem_http_host 0 "$CFG_MODEM_HTTP_HOST" 192.168.224.1 'Expected a conservative hostname or IPv4 address.'; failed=1 ;; *) [ "${#CFG_MODEM_HTTP_HOST}" -le 253 ] || { config_diag error invalid_value modem_http_host 0 "$CFG_MODEM_HTTP_HOST" 192.168.224.1 'Expected at most 253 characters.'; failed=1; } ;; esac
	case $CFG_MODEM_AT_DEVICE in /dev/*) case $CFG_MODEM_AT_DEVICE in *'..'*|*[!A-Za-z0-9_./-]*) config_diag error invalid_value modem_at_device 0 "$CFG_MODEM_AT_DEVICE" /dev/ttyUSB2 'Expected a safe absolute TTY path under /dev.'; failed=1 ;; *) [ "${#CFG_MODEM_AT_DEVICE}" -le 255 ] || { config_diag error invalid_value modem_at_device 0 "$CFG_MODEM_AT_DEVICE" /dev/ttyUSB2 'Expected at most 255 characters.'; failed=1; } ;; esac ;; *) config_diag error invalid_value modem_at_device 0 "$CFG_MODEM_AT_DEVICE" /dev/ttyUSB2 'Expected an absolute TTY path under /dev.'; failed=1 ;; esac
	config_uint_range modem_interval_s "$CFG_MODEM_INTERVAL_S" 10 30 || failed=1
	config_number_range pid_target_c "$CFG_PID_TARGET_C" 30 100 || failed=1
	config_number_range pid_kp "$CFG_PID_KP" 0 0.20 || failed=1
	config_number_range pid_ki "$CFG_PID_KI" 0 0.001667 || failed=1
	config_number_range pid_kd "$CFG_PID_KD" 0 1.20 || failed=1
	config_number_range pid_integral_limit "$CFG_PID_INTEGRAL_LIMIT" 0 1.00 || failed=1
	case $CFG_CURVE_STYLE in step|smooth) ;; *) config_diag error invalid_value curve_style 0 "$CFG_CURVE_STYLE" smooth 'Expected step or smooth.'; failed=1 ;; esac
	config_number_range curve_hysteresis_c "$CFG_CURVE_HYSTERESIS_C" 0 20 || failed=1
	config_validate_points || failed=1
	config_uint_range manual_output_percent "$CFG_MANUAL_OUTPUT_PERCENT" 0 100 || failed=1
	config_uint_range manual_timeout_min "$CFG_MANUAL_TIMEOUT_MIN" 0 1440 || failed=1
	[ "$failed" -eq 0 ] && [ "$CFG_ERROR_COUNT" -eq 0 ]
}

config_render()
{
	local key value comment first=1
	for key in $CFG_KEYS; do
		case $key in
			config_version) comment='Config format version. Change only during a documented upgrade.' ;;
			mode) comment='Mode: kernel, auto, curve, manual, or disabled.' ;;
			control_interval_s) comment='Control loop interval in seconds (1-60).' ;;
			hwmon_name) comment='hwmon driver name that exposes pwm1.' ;;
			thermal_zone) comment='Thermal zone type used for required CPU temperature.' ;;
			tach_enabled) comment='Read fan1_input and detect a stopped fan (0 or 1).' ;;
			temperature_filter) comment='Temperature filter: none or median.' ;;
			temperature_filter_duration_s) comment='Median filter duration in seconds: 5, 10, or 15.' ;;
			modem_source) comment='Optional modem source: off, qmanager_http, or quectel_at.' ;;
			modem_http_host) comment='QManager host or IPv4 address.' ;;
			modem_at_device) comment='Quectel AT port.' ;;
			modem_interval_s) comment='Modem polling interval in seconds (10-30).' ;;
			pid_target_c) comment='Auto target temperature in degrees Celsius (30-100).' ;;
			pid_kp) comment='Auto proportional gain in output per degree Celsius (0-0.20).' ;;
			pid_ki) comment='Auto integral gain in output per degree-second (0-0.001667).' ;;
			pid_kd) comment='Auto derivative gain in output-seconds per degree Celsius (0-1.20).' ;;
			pid_integral_limit) comment='Maximum accumulated integral output (0-1.00).' ;;
			curve_style) comment='Curve interpolation: step or smooth.' ;;
			curve_hysteresis_c) comment='Step-mode hysteresis in degrees Celsius (0-20).' ;;
			curve_points) comment='Curve points as ascending temperature:percent pairs.' ;;
			manual_output_percent) comment='Manual requested fan output in percent (0-100).' ;;
			manual_timeout_min) comment='Minutes before Manual returns to Kernel; 0 disables timeout.' ;;
		esac
		value=$(config_get_value "$key") || return 1
		[ "$first" -eq 1 ] || printf '\n'
		printf '# %s\n%s=%s\n' "$comment" "$key" "$value"
		first=0
	done
}

config_revision()
{
	[ -f "$1" ] || { printf 'missing\n'; return 0; }
	md5sum "$1" 2>/dev/null | awk '{ print $1 }'
}

config_lock_acquire()
{
	local lock=${PWM_FAN_CONFIG_LOCK:-/var/lock/pwm-fan-config.lock} stamp now created
	stamp=$lock/created
	if ! mkdir "$lock" 2>/dev/null; then
		created=$(read_uint "$stamp" 2>/dev/null || printf '0\n')
		now=$(date +%s 2>/dev/null || printf '0\n')
		if is_uint "$now" && [ "$now" -gt 0 ] && [ "$created" -gt 0 ] &&
			[ $((now - created)) -gt 30 ]; then
			rm -f "$stamp" 2>/dev/null || return 1
			rmdir "$lock" 2>/dev/null || return 1
			mkdir "$lock" 2>/dev/null || return 1
		else
			return 1
		fi
	fi
	date +%s > "$stamp" 2>/dev/null || { rmdir "$lock" 2>/dev/null || true; return 1; }
	CFG_LOCK=$lock
}

config_lock_release()
{
	[ -n "${CFG_LOCK:-}" ] || return 0
	rm -f "$CFG_LOCK/created" 2>/dev/null || true
	rmdir "$CFG_LOCK" 2>/dev/null || true
	CFG_LOCK=
}

config_install()
{
	local candidate=$1 expected=${2:-} target=${3:-${PWM_FAN_CONFIG_FILE:-/etc/pwm-fan.conf}} current
	config_lock_acquire || return 1
	current=$(config_revision "$target") || { config_lock_release; return 1; }
	if [ -n "$expected" ] && [ "$expected" != "$current" ]; then
		config_lock_release; return 2
	fi
	if ! config_parse "$candidate" || ! config_validate; then
		config_lock_release; return 1
	fi
	if ! config_render | atomic_replace "$target" 0600; then
		config_lock_release; return 1
	fi
	config_lock_release
	config_revision "$target"
}

config_set()
{
	local key=$1 value=$2 target=${3:-${PWM_FAN_CONFIG_FILE:-/etc/pwm-fan.conf}}
	config_has_key "$key" || return 1
	config_lock_acquire || return 1
	# Keep callers' active CFG_* values untouched. This matters to the daemon:
	# a failed persistent write must never change its current runtime role.
	if ! (
		config_parse "$target" && config_validate &&
		config_set_value "$key" "$value" && config_validate || exit 1
		config_render | atomic_replace "$target" 0600
	); then
		config_lock_release; return 1
	fi
	config_lock_release
}

config_reset()
{
	local expected=${1:-} target=${2:-${PWM_FAN_CONFIG_FILE:-/etc/pwm-fan.conf}} current
	config_lock_acquire || return 1
	current=$(config_revision "$target") || { config_lock_release; return 1; }
	if [ -n "$expected" ] && [ "$expected" != "$current" ]; then config_lock_release; return 2; fi
	config_defaults
	if ! config_render | atomic_replace "$target" 0600; then config_lock_release; return 1; fi
	config_lock_release
	config_revision "$target"
}

config_upgrade_v1()
{
	local target=${1:-${PWM_FAN_CONFIG_FILE:-/etc/pwm-fan.conf}} version candidate directory
	[ -f "$target" ] || return 0
	version=$(awk -F= '
		/^[[:space:]]*config_version[[:space:]]*=/ {
			value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit
		}' "$target" 2>/dev/null)
	case $version in
		2) return 2 ;;
		1) ;;
		*) return 1 ;;
	esac
	directory=${PWM_FAN_CONFIG_TMP_DIR:-/tmp}
	candidate=$directory/.pwm-fan-config-upgrade.$$
	if ! awk '
		/^[[:space:]]*temperature_filter[[:space:]]*=/ { next }
		/^[[:space:]]*temperature_samples[[:space:]]*=/ { next }
		/^[[:space:]]*config_version[[:space:]]*=/ { print "config_version=2"; next }
		{ print }
		END {
			print "temperature_filter=median"
			print "temperature_filter_duration_s=10"
		}' "$target" > "$candidate" ||
		! config_parse "$candidate" || ! config_validate; then
		rm -f "$candidate"
		return 1
	fi
	if ! config_render | atomic_replace "$target" 0600; then
		rm -f "$candidate"
		return 1
	fi
	rm -f "$candidate"
}
