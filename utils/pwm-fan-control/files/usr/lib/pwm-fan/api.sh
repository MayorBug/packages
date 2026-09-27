# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>
parse_config_option()
{
	[ "$#" -eq 0 ] && return 0
	[ "$#" -eq 2 ] && [ "$1" = -c ] || { usage >&2; return 1; }
	CONFIG_FILE=$2
}
config_raw_value()
{
	local wanted=$1 record key rest value
	while IFS= read -r record || [ -n "$record" ]; do
		[ -n "$record" ] || continue
		key=${record%%|*}; rest=${record#*|}; value=${rest#*|}
		[ "$key" != "$wanted" ] || { printf '%s\n' "$value"; return 0; }
	done <<EOF
$CFG_RAW_VALUES
EOF
	return 1
}

config_key_invalid()
{
	local wanted=$1 record severity rest key
	while IFS= read -r record || [ -n "$record" ]; do
		[ -n "$record" ] || continue
		severity=${record%%|*}; rest=${record#*|}; rest=${rest#*|}; key=${rest%%|*}
		[ "$severity" != error ] || [ "$key" != "$wanted" ] || return 0
	done <<EOF
$CFG_DIAGNOSTICS
EOF
	return 1
}

config_diagnostics_json()
{
	local record severity code key line value default_value message rest first=1
	printf '['
	while IFS= read -r record || [ -n "$record" ]; do
		[ -n "$record" ] || continue
		severity=${record%%|*}; rest=${record#*|}
		code=${rest%%|*}; rest=${rest#*|}
		key=${rest%%|*}; rest=${rest#*|}
		line=${rest%%|*}; rest=${rest#*|}
		value=${rest%%|*}; rest=${rest#*|}
		default_value=${rest%%|*}; message=${rest#*|}
		[ "$first" -eq 1 ] || printf ','
		printf '{"severity":"%s","code":"%s","key":"%s","line":%s,"value":"%s","default_value":"%s","message":"%s"}' \
			"$(printf '%s' "$severity" | json_escape)" \
			"$(printf '%s' "$code" | json_escape)" \
			"$(printf '%s' "$key" | json_escape)" "${line:-0}" \
			"$(printf '%s' "$value" | json_escape)" \
			"$(printf '%s' "$default_value" | json_escape)" \
			"$(printf '%s' "$message" | json_escape)"
		first=0
	done <<EOF
$CFG_DIAGNOSTICS
EOF
	printf ']'
}

config_values_json()
{
	local kind=$1 key value first=1
	printf '{'
	for key in $CFG_KEYS; do
		[ "$first" -eq 1 ] || printf ','
		printf '"%s":' "$key"
		case $kind in
			raw) value=$(config_raw_value "$key" 2>/dev/null || true); [ -n "$value" ] || { printf 'null'; first=0; continue; } ;;
			effective) config_key_invalid "$key" && { printf 'null'; first=0; continue; }; value=$(config_get_value "$key") ;;
			defaults) value=$(config_default "$key") ;;
		esac
		printf '"%s"' "$(printf '%s' "$value" | json_escape)"
		first=0
	done
	printf '}'
}

config_document_json()
{
	local file=$1 parse_ok=1 validate_ok=1 valid=false revision
	config_parse "$file" || parse_ok=0
	config_validate || validate_ok=0
	[ "$parse_ok" -eq 1 ] && [ "$validate_ok" -eq 1 ] && valid=true
	revision=$(config_revision "$file") || revision=missing
	printf '{"valid":%s,"config_revision":"%s","raw_values":' "$valid" \
		"$(printf '%s' "$revision" | json_escape)"
	config_values_json raw
	printf ',"effective_values":'; config_values_json effective
	printf ',"defaults":'; config_values_json defaults
	printf ',"diagnostics":'; config_diagnostics_json
	printf '}\n'
	[ "$valid" = true ]
}

parse_validate_options()
{
	VALIDATE_FILE=$CONFIG_FILE
	VALIDATE_JSON=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			-c) [ "$#" -ge 2 ] || return 1; VALIDATE_FILE=$2; shift 2 ;;
			--json) VALIDATE_JSON=1; shift ;;
			*) return 1 ;;
		esac
	done
	[ "$VALIDATE_JSON" -eq 1 ]
}

run_config_install()
{
	[ "$#" -eq 4 ] && [ "$1" = -c ] && [ "$3" = --expect ] || return 1
	config_install "$2" "$4" "$CONFIG_FILE"
}

run_config_reset()
{
	[ "$#" -eq 2 ] && [ "$1" = --expect ] || return 1
	config_reset "$2" "$CONFIG_FILE"
}

status_unavailable_json()
{
	local mode=$1 role=$2 configuration=$3 control=$4 reason=$5 diagnostics=${6:-[]}
	local controller_state=error controller_code=$reason monitoring_state=warning monitoring_code=controller_unavailable
	local history_state=warning history_code=unknown
	if [ "$mode" = disabled ]; then
		controller_state=disabled; controller_code=disabled
		monitoring_state=disabled; monitoring_code=disabled
		history_state=disabled; history_code=disabled
	fi
	printf '{"contract_version":%s,"process_id":null,"timestamp":%s,' \
		"$STATUS_VERSION" "$(date +%s 2>/dev/null || printf '0\n')"
	printf '"started_uptime":null,"updated_uptime":null,"controller_running":false,"controller_fresh":false,'
	printf '"configured_mode":"%s","active_mode":null,"runtime_role":"%s",' \
		"$(printf '%s' "$mode" | json_escape)" "$role"
	printf '"curve_style":null,"temperature_filter":null,"tach_enabled":null,'
	printf '"wifi_source":null,"modem_source":null,"modem_http_host":null,"modem_at_device":null,"modem_interval_s":null,'
	printf '"hwmon_name":null,"thermal_zone":null,"tachometer_available":null,'
	printf '"configuration_state":"%s","hardware_state":"unknown",' "$configuration"
	printf '"configuration_diagnostics":%s,' "$diagnostics"
	printf '"control_state":"%s","control_reason":"%s","history_state":"unknown",' \
		"$control" "$reason"
	printf '"cpu_temperature_millic":null,"wifi_temperature_millic":null,"wifi_temperature_source":null,'
	printf '"wifi_state":"unknown","wifi_sensors":[],"modem_temperature_millic":null,'
	printf '"selected_temperature_source":null,"selected_temperature_millic":null,"filtered_temperature_millic":null,'
	printf '"requested_pwm":null,"kernel_floor_state":null,"kernel_floor_pwm":null,'
	printf '"effective_pwm":null,"actual_pwm":null,"rpm":null,'
	printf '"tach_state":"unknown","fan_state":"unknown","modem_state":"unknown",'
	printf '"health":{"monitoring":{"state":"%s","code":"%s"},' "$monitoring_state" "$monitoring_code"
	printf '"controller":{"state":"%s","code":"%s"},' "$controller_state" "$controller_code"
	printf '"history":{"state":"%s","code":"%s"}},"pid":null}\n' \
		"$history_state" "$history_code"
}

status_emit_merged()
{
	local mode=$1 configuration=$2 diagnostics=$3 line
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in
			*'"configured_mode":'*) printf '  "configured_mode":"%s",\n' "$(printf '%s' "$mode" | json_escape)" ;;
			*'"configuration_state":'*)
				printf '  "configuration_state":"%s",\n' "$configuration"
				printf '  "configuration_diagnostics":%s,\n' "$diagnostics" ;;
			*) printf '%s\n' "$line" ;;
		esac
	done < "$STATUS_FILE"
}

status_json()
{
	local parse_ok=1 validate_ok=1 mode role updated pid version bytes now age stale_limit configuration=valid diagnostics
	config_parse "$CONFIG_FILE" || parse_ok=0
	config_validate || validate_ok=0
	mode=$CFG_MODE
	diagnostics=$(config_diagnostics_json)
	if [ "$parse_ok" -ne 1 ] || [ "$validate_ok" -ne 1 ]; then
		configuration=invalid
		# Validation must not feed unsafe values into status freshness arithmetic.
		CFG_CONTROL_INTERVAL_S=2
	fi
	case $mode in kernel) role=observe ;; *) role=control ;; esac
	if [ ! -r "$STATUS_FILE" ]; then
		if [ "$mode" = disabled ]; then
			status_unavailable_json disabled off "$configuration" disabled disabled "$diagnostics"
			return 0
		fi
		status_unavailable_json "$mode" "$role" "$configuration" error controller_stopped "$diagnostics"
		return 1
	fi
	bytes=$(wc -c < "$STATUS_FILE" 2>/dev/null || printf '0\n')
	is_uint "$bytes" && [ "$bytes" -le 16384 ] || {
		if [ "$mode" = disabled ]; then
			status_unavailable_json disabled off "$configuration" disabled disabled "$diagnostics"
			return 0
		fi
		status_unavailable_json "$mode" "$role" "$configuration" error status_invalid "$diagnostics"
		return 1
	}
	version=$(sed -n 's/.*"contract_version":\([0-9][0-9]*\).*/\1/p' "$STATUS_FILE" | head -n 1)
	updated=$(sed -n 's/.*"updated_uptime":\([0-9][0-9]*\).*/\1/p' "$STATUS_FILE" | head -n 1)
	pid=$(sed -n 's/.*"process_id":\([0-9][0-9]*\).*/\1/p' "$STATUS_FILE" | head -n 1)
	if [ "$version" != "$STATUS_VERSION" ] || ! is_uint "$updated" || ! is_uint "$pid"; then
		if [ "$mode" = disabled ]; then
			status_unavailable_json disabled off "$configuration" disabled disabled "$diagnostics"
			return 0
		fi
		status_unavailable_json "$mode" "$role" "$configuration" error status_invalid "$diagnostics"
		return 1
	fi
	now=$(read_uptime 2>/dev/null || printf '0\n')
	stale_limit=$((CFG_CONTROL_INTERVAL_S * 3)); [ "$stale_limit" -ge 10 ] || stale_limit=10
	if [ "$now" -lt "$updated" ]; then age=$((stale_limit + 1)); else age=$((now - updated)); fi
	if ! kill -0 "$pid" 2>/dev/null; then
		if [ "$mode" = disabled ]; then
			status_unavailable_json disabled off "$configuration" disabled disabled "$diagnostics"
			return 0
		fi
		status_unavailable_json "$mode" "$role" "$configuration" error controller_stopped "$diagnostics"
		return 1
	fi
	if [ "$age" -gt "$stale_limit" ]; then
		if [ "$mode" = disabled ]; then
			status_unavailable_json disabled off "$configuration" disabled disabled "$diagnostics"
			return 0
		fi
		status_unavailable_json "$mode" "$role" "$configuration" error controller_stale "$diagnostics"
		return 1
	fi
	status_emit_merged "$mode" "$configuration" "$diagnostics"
	[ "$configuration" = valid ]
}

policy_points_json()
{
	local point trip rest hysteresis release state pwm first=1
	printf '['
	set -f
	for point in $POLICY_POINTS; do
		trip=${point%%:*}; rest=${point#*:}
		hysteresis=${rest%%:*}; rest=${rest#*:}
		release=${rest%%:*}; rest=${rest#*:}
		state=${rest%%:*}; pwm=${rest#*:}
		[ "$first" -eq 1 ] || printf ','
		printf '{"trip_temperature_millic":%s,"hysteresis_millic":%s,' "$trip" "$hysteresis"
		printf '"release_temperature_millic":%s,"state":%s,"pwm":%s}' "$release" "$state" "$pwm"
		first=0
	done
	set +f
	printf ']'
}

wifi_probe_json()
{
	local configured=$CFG_WIFI_SOURCE record name value first=1 selected=false found=0
	CFG_WIFI_SOURCE=auto
	hardware_wifi_discover >/dev/null 2>&1 || true
	hardware_wifi_read >/dev/null 2>&1 || true
	printf '['
	while IFS= read -r record || [ -n "$record" ]; do
		[ -n "$record" ] || continue
		name=${record%%|*}; value=${record#*|}
		[ "$name" = "$configured" ] && found=1
		case $configured in
			auto) [ "$name" = "$HW_WIFI_TEMPERATURE_SOURCE" ] && selected=true || selected=false ;;
			*) [ "$name" = "$configured" ] && selected=true || selected=false ;;
		esac
		[ "$first" -eq 1 ] || printf ','
		printf '{"name":"%s","temperature_millic":%s,"available":%s,"selected":%s}' \
			"$(printf '%s' "$name" | json_escape)" "$value" \
			"$([ "$value" != null ] && printf true || printf false)" "$selected"
		first=0
	done <<EOF
$HW_WIFI_READINGS
EOF
	if [ "$configured" != off ] && [ "$configured" != auto ] && [ "$found" -eq 0 ]; then
		[ "$first" -eq 1 ] || printf ','
		printf '{"name":"%s","temperature_millic":null,"available":false,"selected":true}' \
			"$(printf '%s' "$configured" | json_escape)"
	fi
	printf ']'
}

probe_json()
{
	local file=$1 parse_ok=1 validate_ok=1 applicable=true observation_available=false code=none pwm_readable=false pwm_writable=false
	local actual_pwm=null cpu_temperature=null rpm=null tach_state=unknown wifi_json='[]'
	config_parse "$file" || parse_ok=0
	config_validate || validate_ok=0
	if [ "$parse_ok" -ne 1 ] || [ "$validate_ok" -ne 1 ]; then
		printf '{"contract_version":%s,"valid":false,"applicable":false,"diagnostics":' "$STATUS_VERSION"
		config_diagnostics_json
		printf '}\n'
		return 1
	fi
	hardware_state_reset
	policy_state_reset
	if ! hardware_discover; then
		applicable=false; code=$HW_DISCOVERY_ERROR
	else
		observation_available=true
		if ! policy_build; then
			applicable=false; code=kernel_policy_invalid
		fi
	fi
	[ -n "$HW_HWMON" ] && [ -r "$HW_HWMON/pwm1" ] && pwm_readable=true
	[ -n "$HW_HWMON" ] && [ -w "$HW_HWMON/pwm1" ] && pwm_writable=true
	if [ "$observation_available" = true ] && telemetry_read; then
		actual_pwm=${HW_ACTUAL_PWM:-null}
		cpu_temperature=${HW_CPU_TEMPERATURE_MILLIC:-null}
		rpm=${HW_RPM:-null}
		tach_state=$HW_TACH_STATE
	fi
	wifi_json=$(wifi_probe_json)
	printf '{"contract_version":%s,"valid":true,"applicable":%s,"observation_available":%s,' \
		"$STATUS_VERSION" "$applicable" "$observation_available"
	if [ "$code" = none ]; then printf '"diagnostics":[],'; else
		printf '"diagnostics":[{"severity":"error","code":"%s"}],' \
			"$(printf '%s' "$code" | json_escape)"
	fi
	printf '"hardware":{"hwmon_name":"%s","hwmon_device":"%s",' \
		"$(printf '%s' "$CFG_HWMON_NAME" | json_escape)" "$(printf '%s' "$HW_HWMON" | json_escape)"
	printf '"thermal_zone_name":"%s","thermal_zone_device":"%s",' \
		"$(printf '%s' "$CFG_THERMAL_ZONE" | json_escape)" "$(printf '%s' "$HW_THERMAL" | json_escape)"
	printf '"tachometer_available":%s,"pwm_readable":%s,"pwm_writable":%s,' \
		"$([ -n "$HW_TACH" ] && printf true || printf false)" "$pwm_readable" "$pwm_writable"
	printf '"actual_pwm":%s,"cpu_temperature_millic":%s,"rpm":%s,"tach_state":"%s"},' \
		"$actual_pwm" "$cpu_temperature" "$rpm" "$tach_state"
	printf '"wifi_sensors":%s,' "$wifi_json"
	printf '"kernel_policy":{"available":%s,"max_state":%s,"direction":' \
		"$([ "$POLICY_AVAILABLE" -eq 1 ] && printf true || printf false)" "$POLICY_MAX_STATE"
	if [ -n "${POLICY_DIRECTION:-}" ]; then printf '"%s"' "$POLICY_DIRECTION"; else printf 'null'; fi
	printf ',"strongest_pwm":%s,"points":' "${POLICY_FULL_PWM:-null}"
	policy_points_json
	printf '}}\n'
	[ "$applicable" = true ]
}
