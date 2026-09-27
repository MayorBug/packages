# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>
STATUS_VERSION=1

STOP_REQUESTED=0
RELOAD_REQUESTED=0
RUNNING=0
HANDOFF_ON_EXIT=1
STATUS_WRITE_FAILED=0
MANUAL_TIMEOUT_FAILED=0
FILTER_BUFFER=
FILTER_OUTPUT_MILLIC=
ACTIVE_MODE=
MODEM_STATE=waiting
PID_I_FIXED=0
PID_COOLING_ACTIVE=0
PID_LAST_TEMP=
PID_LAST_UPTIME=
LAST_CURVE_PWM=
LAST_CURVE_THRESHOLD=0
CURVE_POINTS_PWM=
MANUAL_PWM=0
START_UPTIME=0
MANUAL_START_UPTIME=0
ACTIVE_FAULT=none
HISTORY_STATE=healthy
HISTORY_NEXT_UPTIME=0
HARDWARE_NEXT_DISCOVERY=0
WIFI_NEXT_DISCOVERY=0
KERNEL_MONITOR_ONLY=0
SNAP_TIMESTAMP=0
SNAP_UPDATED_UPTIME=0
SNAP_STATE=starting
SNAP_REASON=none
SNAP_CPU=null
SNAP_MODEM=null
SNAP_SELECTED=null
SNAP_FILTERED=null
SNAP_REQUESTED_PWM=null
SNAP_EFFECTIVE_PWM=null
SNAP_ACTUAL_PWM=null
SNAP_RPM=null
read_uptime()
{
	PWM_FAN_UPTIME_FILE=$PROC_UPTIME monotonic_now
}
log_event()
{
	local level=$1 code=$2 fields
	shift 2
	fields=$(printf '%s' "$*" | tr '\r\n' '  ' | cut -c 1-512)
	"$LOGGER" -t pwm-fan-control "level=$level code=$code${fields:+ $fields}" \
		2>/dev/null || true
}

status_write_tracked()
{
	if status_write; then
		if [ "$STATUS_WRITE_FAILED" -eq 1 ]; then
			log_event info status_write_recovered
			STATUS_WRITE_FAILED=0
		fi
		return 0
	fi
	if [ "$STATUS_WRITE_FAILED" -eq 0 ]; then
		log_event warning status_write_failed
		STATUS_WRITE_FAILED=1
	fi
	return 1
}

record_control_fault()
{
	local code=$1
	shift
	[ "$ACTIVE_FAULT" = "$code" ] || log_event error "$code" "$@"
	ACTIVE_FAULT=$code
}

record_control_recovery()
{
	[ "$ACTIVE_FAULT" != none ] || return 0
	log_event info control_recovered "previous=$ACTIVE_FAULT"
	ACTIVE_FAULT=none
}

parse_config()
{
	config_parse "$1"
}

validate_config()
{
	config_validate || return 1
	activate_control_config
}

restore_active_config()
{
	local rendered=$1 temporary=$RUN_DIR/.reload-config.$$
	mkdir -p "$RUN_DIR" || return 1
	printf '%s\n' "$rendered" | atomic_replace "$temporary" 0600 || return 1
	if ! config_parse "$temporary" || ! validate_config; then
		rm -f "$temporary"
		return 1
	fi
	rm -f "$temporary"
}

refresh_hardware()
{
	hardware_policy_refresh
}

hardware_check()
{
	[ "$CFG_MODE" = disabled ] && return 0
	hardware_state_reset
	policy_state_reset
	hardware_discover || { die "hardware discovery failed: $HW_DISCOVERY_ERROR"; return 1; }
	if ! policy_build; then
		HW_DISCOVERY_ERROR=kernel_policy_invalid
		[ -r "$HW_THERMAL/temp" ] || { die "CPU temperature is not readable"; return 1; }
		KERNEL_MONITOR_ONLY=1
		return 0
	fi
	KERNEL_MONITOR_ONLY=0
	[ -r "$HW_THERMAL/temp" ] || { die "CPU temperature is not readable"; return 1; }
	case $CFG_MODE in auto|curve|manual)
		[ -w "$HW_HWMON/pwm1" ] || { die "PWM output is not writable"; return 1; } ;;
	esac
}

write_full_output()
{
	[ -n "${POLICY_FULL_PWM:-}" ] || return 1
	pwm_force_full "$POLICY_FULL_PWM" >/dev/null 2>&1
}

record_pwm_recovery()
{
	case $1 in
		pwm_not_applied|pwm_unavailable)
			log_event info pwm_write_recovered "actual_pwm=${HW_ACTUAL_PWM:-unknown}" ;;
	esac
}

record_fan_transition()
{
	local previous=$1
	[ "$previous" != "$FANWATCH_STATE" ] || return 0
	case $FANWATCH_STATE in
		fan_failed) log_event error fan_stopped "expected_pwm=$HW_REQUESTED_PWM rpm=${HW_RPM:-0}" ;;
		pwm_not_applied) log_event error pwm_write_failed "requested_pwm=$HW_REQUESTED_PWM actual_pwm=${HW_ACTUAL_PWM:-unknown}" ;;
		pwm_unavailable) log_event error pwm_unavailable ;;
		tach_read_error) log_event warning tach_read_failed ;;
		running)
			[ "$previous" != fan_failed ] || log_event info fan_recovered "rpm=$HW_RPM"
			record_pwm_recovery "$previous" ;;
		idle|spinup|tach_unavailable) record_pwm_recovery "$previous" ;;
	esac
}

perform_handoff()
{
	local temperature
	temperature=$(read_uint "$HW_THERMAL/temp" 2>/dev/null) || { write_full_output; return 1; }
	policy_handoff "$temperature" || { write_full_output; return 1; }
}

replace_mode_with_kernel()
{
	config_set mode kernel "$CONFIG_FILE"
}

telemetry_with_rediscovery()
{
	local now=$1
	if telemetry_read; then HARDWARE_NEXT_DISCOVERY=0; return 0; fi
	if [ "$HARDWARE_NEXT_DISCOVERY" -eq 0 ]; then
		HARDWARE_NEXT_DISCOVERY=$((now + 10))
		return 1
	fi
	[ "$now" -ge "$HARDWARE_NEXT_DISCOVERY" ] || return 1
	HARDWARE_NEXT_DISCOVERY=$((now + 10))
	refresh_hardware && telemetry_read || return 1
	HARDWARE_NEXT_DISCOVERY=0
}

control_step()
{
	local now cpu selected filtered wifi=null modem=null selected_source=cpu
	local requested_pwm= requested_demand= effective_pwm= effective_demand= expected_pwm= actual_demand=
	local raw=null rpm=null state=running reason=none full_output=1
	local previous_fan previous_wifi previous_modem
	SELECTED_TEMPERATURE_SOURCE=null
	now=$(read_uptime) || return 1
	previous_wifi=${HW_WIFI_STATE:-disabled}
	if ! telemetry_with_rediscovery "$now" || [ -z "$HW_CPU_TEMPERATURE_MILLIC" ]; then
		if [ "$ACTIVE_MODE" = kernel ]; then
			full_output=0
			snapshot_set error temperature_unavailable null null null null null null \
				"${HW_ACTUAL_PWM:-null}" "${HW_RPM:-null}"
		else
			write_full_output
			snapshot_set failsafe temperature_unavailable null null null null null "${POLICY_FULL_PWM:-null}" \
				"${HW_ACTUAL_PWM:-null}" "${HW_RPM:-null}"
		fi
		status_write_tracked || true
		history_record_if_due "$now" || true
		record_control_fault temperature_unavailable "full_output=$full_output"
		return 1
	fi
	cpu=$HW_CPU_TEMPERATURE_MILLIC
	selected=$cpu
	if [ "$CFG_WIFI_SOURCE" != off ]; then
		if [ "$WIFI_NEXT_DISCOVERY" -eq 0 ] || [ "$now" -ge "$WIFI_NEXT_DISCOVERY" ]; then
			hardware_wifi_discover || true
			hardware_wifi_read || true
			WIFI_NEXT_DISCOVERY=$((now + 10))
		fi
		if [ "$HW_WIFI_STATE" = available ]; then
			wifi=$HW_WIFI_TEMPERATURE_MILLIC
			case $ACTIVE_MODE in auto|curve)
				if [ "$wifi" -gt "$selected" ]; then
					selected=$wifi; selected_source="wifi:$HW_WIFI_TEMPERATURE_SOURCE"
				fi ;;
			esac
		fi
	fi
	previous_modem=$MODEM_STATE
	if modem_sample_read "$now"; then
		modem=$MODEM_TEMPERATURE_MILLIC
		case $ACTIVE_MODE in auto|curve)
			if [ "$modem" -gt "$selected" ]; then selected=$modem; selected_source=modem; fi
			;;
		esac
	fi
	if [ "$KERNEL_MONITOR_ONLY" -eq 1 ]; then
		snapshot_set error kernel_policy_invalid "$cpu" null null "$modem" \
			null null "${HW_ACTUAL_PWM:-null}" "${HW_RPM:-null}"
		status_write_tracked || true
		history_record_if_due "$now" || true
		return 0
	fi
	if [ "$previous_wifi" != available ] && [ "$HW_WIFI_STATE" = available ]; then
		if [ "$previous_wifi" = unavailable ] || [ "$previous_wifi" = ambiguous ]; then
			log_event info wifi_temperature_recovered "source=$HW_WIFI_TEMPERATURE_SOURCE temperature_millic=$HW_WIFI_TEMPERATURE_MILLIC"
		else
			log_event info wifi_temperature_available "source=$HW_WIFI_TEMPERATURE_SOURCE temperature_millic=$HW_WIFI_TEMPERATURE_MILLIC"
		fi
	elif [ "$previous_wifi" = available ] && [ "$HW_WIFI_STATE" != available ]; then
		log_event warning wifi_temperature_unavailable "source=$CFG_WIFI_SOURCE fallback=cpu"
	fi
	if [ "$previous_modem" = waiting ] && [ "$MODEM_STATE" = available ]; then
		log_event info modem_temperature_available "source=$CFG_MODEM_SOURCE temperature_millic=$MODEM_TEMPERATURE_MILLIC"
	elif [ "$previous_modem" = available ] && [ "$MODEM_STATE" = lost ]; then
		log_event warning modem_temperature_lost "source=$CFG_MODEM_SOURCE fallback=cpu"
	elif [ "$previous_modem" = lost ] && [ "$MODEM_STATE" = available ]; then
		log_event info modem_temperature_recovered "source=$CFG_MODEM_SOURCE temperature_millic=$MODEM_TEMPERATURE_MILLIC"
	fi
	policy_floor_update "$cpu" || {
		if [ "$ACTIVE_MODE" = kernel ]; then
			full_output=0
			snapshot_set error kernel_policy_unavailable "$cpu" "$selected" null "$modem" \
				null null "${HW_ACTUAL_PWM:-null}" "${HW_RPM:-null}"
		else
			write_full_output
			snapshot_set failsafe kernel_policy_unavailable "$cpu" "$selected" null "$modem" \
				null "${POLICY_FULL_PWM:-null}" "${HW_ACTUAL_PWM:-null}" "${HW_RPM:-null}"
		fi
		status_write_tracked || true
		history_record_if_due "$now" || true
		record_control_fault kernel_policy_unavailable "full_output=$full_output"
		return 1
	}
	case $ACTIVE_MODE in
		kernel) filtered=null; expected_pwm=$POLICY_FLOOR_PWM ;;
		auto) SELECTED_TEMPERATURE_SOURCE=$selected_source; temperature_filter_update "$now" "$selected"; filtered=$FILTER_OUTPUT_MILLIC; calculate_pid "$filtered" || return 1; requested_pwm=$REQUESTED_PWM ;;
		curve) SELECTED_TEMPERATURE_SOURCE=$selected_source; temperature_filter_update "$now" "$selected"; filtered=$FILTER_OUTPUT_MILLIC; if [ "$CFG_CURVE_STYLE" = step ]; then calculate_step_curve "$filtered"; else calculate_smooth_curve "$filtered"; fi; requested_pwm=$REQUESTED_PWM ;;
		manual) selected=null; filtered=null; requested_pwm=$MANUAL_PWM ;;
	esac
	if [ "$ACTIVE_MODE" = kernel ]; then
		effective_pwm=null
		HW_REQUESTED_PWM=$POLICY_FLOOR_PWM
		HW_PWM_STATE=applied
	else
		requested_demand=$requested_pwm
		requested_pwm=$(policy_demand_to_pwm "$requested_demand") || return 1
		effective_demand=$requested_demand
		[ "$effective_demand" -ge "$POLICY_FLOOR_DEMAND" ] || effective_demand=$POLICY_FLOOR_DEMAND
		effective_pwm=$(policy_demand_to_pwm "$effective_demand") || return 1
		if ! pwm_apply_verified "$effective_pwm"; then
			pwm_force_full "$POLICY_FULL_PWM" || true
			state=failsafe; reason=pwm_write_failed; effective_pwm=$POLICY_FULL_PWM
		fi
	fi
	previous_fan=$FANWATCH_STATE
	actual_demand=$(policy_pwm_to_demand "${HW_ACTUAL_PWM:-}" 2>/dev/null || true)
	if [ "$ACTIVE_MODE" = kernel ]; then
		fan_watch_update "$now" "${actual_demand:-0}" "$actual_demand" \
			"$([ -n "$actual_demand" ] && printf applied || printf unavailable)" \
			"${HW_RPM:-}" "$HW_TACH_STATE" || true
	else
		fan_watch_update "$now" "${effective_demand:-255}" "$actual_demand" \
			"$HW_PWM_STATE" "${HW_RPM:-}" "$HW_TACH_STATE" || true
	fi
	record_fan_transition "$previous_fan"
	if [ "$FANWATCH_STATE" = fan_failed ] && [ "$ACTIVE_MODE" != kernel ]; then
		pwm_force_full "$POLICY_FULL_PWM" || true
		state=failsafe; reason=fan_stopped; effective_pwm=$POLICY_FULL_PWM
	fi
	raw=${HW_ACTUAL_PWM:-null}; rpm=${HW_RPM:-null}
	snapshot_set "$state" "$reason" "$cpu" "$selected" "$filtered" "$modem" \
		"${requested_pwm:-null}" "${effective_pwm:-null}" "$raw" "$rpm"
	status_write_tracked || true
	history_record_if_due "$now" || true
	record_control_recovery
}

handle_hup() { RELOAD_REQUESTED=1; }
handle_stop() { STOP_REQUESTED=1; }

reload_config()
{
	local previous_mode previous_manual_timeout previous_config previous_hwmon_name previous_thermal_zone
	local old_pid old_filter old_curve old_wifi_config old_modem old_fan old_paths
	local old_hwmon old_hwmon_device old_thermal old_thermal_node old_cooling old_fan_node old_tach old_discovery
	local old_wifi_sensors old_wifi_readings old_wifi_temperature old_wifi_source old_wifi_state
	local old_policy_available old_policy_levels old_policy_points old_policy_max old_policy_direction old_policy_full
	local old_policy_state old_policy_floor old_policy_floor_demand
	local now candidate_mode
	previous_mode=$ACTIVE_MODE
	previous_manual_timeout=$CFG_MANUAL_TIMEOUT_MIN
	previous_hwmon_name=$CFG_HWMON_NAME
	previous_thermal_zone=$CFG_THERMAL_ZONE
	old_pid="$CFG_PID_TARGET_C|$CFG_PID_KP|$CFG_PID_KI|$CFG_PID_KD|$CFG_PID_INTEGRAL_LIMIT"
	old_filter="$CFG_TEMPERATURE_FILTER|$CFG_TEMPERATURE_FILTER_DURATION_S|$CFG_CONTROL_INTERVAL_S"
	old_curve="$CFG_CURVE_STYLE|$CFG_CURVE_HYSTERESIS_C|$CFG_CURVE_POINTS"
	old_wifi_config=$CFG_WIFI_SOURCE
	old_modem="$CFG_MODE|$CFG_MODEM_SOURCE|$CFG_MODEM_HTTP_HOST|$CFG_MODEM_AT_DEVICE|$CFG_MODEM_INTERVAL_S"
	old_fan="$CFG_MODE|$CFG_TACH_ENABLED|$CFG_HWMON_NAME|$CFG_THERMAL_ZONE"
	old_paths="$HW_HWMON|$HW_THERMAL|$HW_COOLING"
	old_hwmon=$HW_HWMON; old_hwmon_device=$HW_HWMON_DEVICE
	old_thermal=$HW_THERMAL; old_thermal_node=$HW_THERMAL_OF_NODE
	old_cooling=$HW_COOLING; old_fan_node=$HW_FAN_OF_NODE; old_tach=$HW_TACH
	old_discovery=$HW_DISCOVERY_ERROR
	old_wifi_sensors=$HW_WIFI_SENSORS; old_wifi_readings=$HW_WIFI_READINGS
	old_wifi_temperature=$HW_WIFI_TEMPERATURE_MILLIC; old_wifi_source=$HW_WIFI_TEMPERATURE_SOURCE
	old_wifi_state=$HW_WIFI_STATE
	old_policy_available=$POLICY_AVAILABLE; old_policy_levels=$POLICY_LEVELS
	old_policy_points=$POLICY_POINTS; old_policy_max=$POLICY_MAX_STATE
	old_policy_direction=$POLICY_DIRECTION; old_policy_full=$POLICY_FULL_PWM
	old_policy_state=$POLICY_STATE; old_policy_floor=$POLICY_FLOOR_PWM
	old_policy_floor_demand=$POLICY_FLOOR_DEMAND
	previous_config=$(config_render) || return 1
	if ! parse_config "$CONFIG_FILE" || ! validate_config; then
		restore_active_config "$previous_config" || return 1
		log_event warning configuration_reload_rejected
		return 1
	fi
	if [ "$CFG_HWMON_NAME" != "$previous_hwmon_name" ] ||
		[ "$CFG_THERMAL_ZONE" != "$previous_thermal_zone" ]; then
		restore_active_config "$previous_config" || return 1
		log_event warning configuration_reload_rejected 'reason=hardware_change_requires_restart'
		return 1
	fi
	case $CFG_MODE in
		disabled) ;;
		*) refresh_hardware || {
			restore_active_config "$previous_config" || return 1
			HW_HWMON=$old_hwmon; HW_HWMON_DEVICE=$old_hwmon_device
			HW_THERMAL=$old_thermal; HW_THERMAL_OF_NODE=$old_thermal_node
			HW_COOLING=$old_cooling; HW_FAN_OF_NODE=$old_fan_node; HW_TACH=$old_tach
			HW_DISCOVERY_ERROR=$old_discovery
			HW_WIFI_SENSORS=$old_wifi_sensors; HW_WIFI_READINGS=$old_wifi_readings
			HW_WIFI_TEMPERATURE_MILLIC=$old_wifi_temperature
			HW_WIFI_TEMPERATURE_SOURCE=$old_wifi_source; HW_WIFI_STATE=$old_wifi_state
			POLICY_AVAILABLE=$old_policy_available; POLICY_LEVELS=$old_policy_levels
			POLICY_POINTS=$old_policy_points; POLICY_MAX_STATE=$old_policy_max
			POLICY_DIRECTION=$old_policy_direction; POLICY_FULL_PWM=$old_policy_full
			POLICY_STATE=$old_policy_state; POLICY_FLOOR_PWM=$old_policy_floor
			POLICY_FLOOR_DEMAND=$old_policy_floor_demand
			log_event warning configuration_reload_rejected 'reason=hardware_discovery'
			return 1
		} ;;
	esac
	candidate_mode=$CFG_MODE
	case $candidate_mode in
		kernel)
			if [ "$previous_mode" != kernel ] && ! perform_handoff; then
			restore_active_config "$previous_config" || return 1
			HW_HWMON=$old_hwmon; HW_HWMON_DEVICE=$old_hwmon_device
			HW_THERMAL=$old_thermal; HW_THERMAL_OF_NODE=$old_thermal_node
			HW_COOLING=$old_cooling; HW_FAN_OF_NODE=$old_fan_node; HW_TACH=$old_tach
			HW_DISCOVERY_ERROR=$old_discovery
			HW_WIFI_SENSORS=$old_wifi_sensors; HW_WIFI_READINGS=$old_wifi_readings
			HW_WIFI_TEMPERATURE_MILLIC=$old_wifi_temperature
			HW_WIFI_TEMPERATURE_SOURCE=$old_wifi_source; HW_WIFI_STATE=$old_wifi_state
			POLICY_AVAILABLE=$old_policy_available; POLICY_LEVELS=$old_policy_levels
			POLICY_POINTS=$old_policy_points; POLICY_MAX_STATE=$old_policy_max
			POLICY_DIRECTION=$old_policy_direction; POLICY_FULL_PWM=$old_policy_full
			POLICY_STATE=$old_policy_state; POLICY_FLOOR_PWM=$old_policy_floor
			POLICY_FLOOR_DEMAND=$old_policy_floor_demand
			write_full_output
			log_event error kernel_handoff_failed
			return 1
		fi ;;
		disabled)
			case $previous_mode in
				auto|curve|manual) if ! perform_handoff; then
					restore_active_config "$previous_config" || return 1
					HW_HWMON=$old_hwmon; HW_HWMON_DEVICE=$old_hwmon_device
					HW_THERMAL=$old_thermal; HW_THERMAL_OF_NODE=$old_thermal_node
					HW_COOLING=$old_cooling; HW_FAN_OF_NODE=$old_fan_node; HW_TACH=$old_tach
					HW_DISCOVERY_ERROR=$old_discovery
					HW_WIFI_SENSORS=$old_wifi_sensors; HW_WIFI_READINGS=$old_wifi_readings
					HW_WIFI_TEMPERATURE_MILLIC=$old_wifi_temperature
					HW_WIFI_TEMPERATURE_SOURCE=$old_wifi_source; HW_WIFI_STATE=$old_wifi_state
					POLICY_AVAILABLE=$old_policy_available; POLICY_LEVELS=$old_policy_levels
					POLICY_POINTS=$old_policy_points; POLICY_MAX_STATE=$old_policy_max
					POLICY_DIRECTION=$old_policy_direction; POLICY_FULL_PWM=$old_policy_full
					POLICY_STATE=$old_policy_state; POLICY_FLOOR_PWM=$old_policy_floor
					POLICY_FLOOR_DEMAND=$old_policy_floor_demand
					write_full_output
					log_event error kernel_handoff_failed
					return 1
				fi ;;
			esac ;;
	esac
	ACTIVE_MODE=$candidate_mode
	now=$(read_uptime)
	if [ "$previous_mode" != "$ACTIVE_MODE" ]; then
		reset_control_state
	else
		[ "$old_pid" = "$CFG_PID_TARGET_C|$CFG_PID_KP|$CFG_PID_KI|$CFG_PID_KD|$CFG_PID_INTEGRAL_LIMIT" ] || pid_reset
		[ "$old_filter" = "$CFG_TEMPERATURE_FILTER|$CFG_TEMPERATURE_FILTER_DURATION_S|$CFG_CONTROL_INTERVAL_S" ] || temperature_filter_reset
		[ "$old_curve" = "$CFG_CURVE_STYLE|$CFG_CURVE_HYSTERESIS_C|$CFG_CURVE_POINTS" ] || curve_reset
		if [ "$old_wifi_config" != "$CFG_WIFI_SOURCE" ]; then
			temperature_filter_reset
			pid_reset
			curve_reset
		fi
	fi
	if [ "$ACTIVE_MODE" = manual ]; then
		if [ "$previous_mode" != manual ] || [ "$previous_manual_timeout" != "$CFG_MANUAL_TIMEOUT_MIN" ]; then
			MANUAL_START_UPTIME=$now
			MANUAL_TIMEOUT_FAILED=0
		fi
	else
		MANUAL_START_UPTIME=0
		MANUAL_TIMEOUT_FAILED=0
	fi
	if [ "$old_modem" != "$CFG_MODE|$CFG_MODEM_SOURCE|$CFG_MODEM_HTTP_HOST|$CFG_MODEM_AT_DEVICE|$CFG_MODEM_INTERVAL_S" ]; then
		case $ACTIVE_MODE in auto|curve) temperature_filter_reset ;; esac
		modem_sample_reset
	fi
	if [ "$old_fan" != "$CFG_MODE|$CFG_TACH_ENABLED|$CFG_HWMON_NAME|$CFG_THERMAL_ZONE" ] ||
		[ "$old_paths" != "$HW_HWMON|$HW_THERMAL|$HW_COOLING" ]; then
		fan_watch_reset
	fi
	HARDWARE_NEXT_DISCOVERY=0
	WIFI_NEXT_DISCOVERY=0
	log_event info configuration_reloaded "mode=$ACTIVE_MODE previous_mode=$previous_mode"
	case $ACTIVE_MODE in
		kernel)
			HANDOFF_ON_EXIT=0 ;;
		disabled)
			HANDOFF_ON_EXIT=0
			STOP_REQUESTED=1 ;;
		*) HANDOFF_ON_EXIT=1 ;;
	esac
}

run_loop()
{
	local now cycle_deadline
	START_UPTIME=$(read_uptime)
	cycle_deadline=$START_UPTIME
	HISTORY_NEXT_UPTIME=$((START_UPTIME + 60))
	if [ "$ACTIVE_MODE" = manual ]; then
		MANUAL_START_UPTIME=$START_UPTIME
	else
		MANUAL_START_UPTIME=0
	fi
	REQUESTED_PWM=0
	snapshot_set starting none null null null null null null \
		"$(read_uint "$HW_HWMON/pwm1" 2>/dev/null || printf 'null\n')" \
		"$(read_uint "$HW_TACH" 2>/dev/null || printf 'null\n')"
	status_write || true
	log_event info controller_started "mode=$ACTIVE_MODE interval_s=$CFG_CONTROL_INTERVAL_S"
	while [ "$STOP_REQUESTED" -eq 0 ]; do
		if [ "$RELOAD_REQUESTED" -eq 1 ]; then
			RELOAD_REQUESTED=0
			reload_config || true
			[ "$STOP_REQUESTED" -eq 0 ] || break
		fi
		control_step || true
		if [ "$ACTIVE_MODE" = manual ] && [ "$CFG_MANUAL_TIMEOUT_MIN" -gt 0 ]; then
			now=$(read_uptime)
			if [ $((now - MANUAL_START_UPTIME)) -ge $((CFG_MANUAL_TIMEOUT_MIN * 60)) ]; then
				if perform_handoff && replace_mode_with_kernel; then
					CFG_MODE=kernel
					ACTIVE_MODE=kernel
					log_event info manual_timeout 'mode=kernel'
					HANDOFF_ON_EXIT=0
					reset_control_state
					fan_watch_reset
					MANUAL_START_UPTIME=0
					MANUAL_TIMEOUT_FAILED=0
				else
					if [ "$MANUAL_TIMEOUT_FAILED" -eq 0 ]; then
						log_event error manual_timeout_failed
						MANUAL_TIMEOUT_FAILED=1
					fi
				fi
			fi
		fi
		if [ "$STOP_REQUESTED" -eq 0 ]; then
			cycle_deadline=$((cycle_deadline + CFG_CONTROL_INTERVAL_S))
			now=$(read_uptime 2>/dev/null || printf '%s\n' "$cycle_deadline")
			while [ "$cycle_deadline" -le "$now" ]; do
				cycle_deadline=$((cycle_deadline + CFG_CONTROL_INTERVAL_S))
			done
			deadline_sleep "$cycle_deadline" || true
		fi
	done
}

cleanup()
{
	local exit_status=$?
	trap - EXIT INT TERM HUP
	if [ "$RUNNING" -eq 1 ]; then
		snapshot_set stopping none null null null null null null null null
		status_write >/dev/null 2>&1 || true
		if [ "$HANDOFF_ON_EXIT" -eq 1 ]; then
			perform_handoff >/dev/null 2>&1 || write_full_output
		fi
		rm -f "$STATUS_FILE"
		rm -f "$LOCK_DIR/pid"
		rmdir "$LOCK_DIR" 2>/dev/null || true
		log_event info controller_stopped
	fi
	exit "$exit_status"
}

acquire_controller_lock()
{
	local lock_pid
	mkdir -p "$RUN_DIR" || return 1
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		lock_pid=$(read_uint "$LOCK_DIR/pid" 2>/dev/null || printf '0\n')
		if [ "$lock_pid" -gt 1 ] && kill -0 "$lock_pid" 2>/dev/null; then
			die "another controller instance is running"
			return 1
		fi
		rm -f "$LOCK_DIR/pid"
		rmdir "$LOCK_DIR" 2>/dev/null || { die "controller lock is unavailable"; return 1; }
		mkdir "$LOCK_DIR" || return 1
	fi
	printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

release_startup_lock()
{
	rm -f "$LOCK_DIR/pid"
	rmdir "$LOCK_DIR" 2>/dev/null || true
}

run_controller()
{
	if ! parse_config "$CONFIG_FILE" || ! validate_config; then
		log_event error controller_start_failed 'reason=invalid_configuration'
		return 1
	fi
	ACTIVE_MODE=$CFG_MODE
	case $CFG_MODE in
		disabled)
			log_event info controller_started "mode=$CFG_MODE interval_s=$CFG_CONTROL_INTERVAL_S"
			return 0 ;;
	esac
	if ! hardware_check; then
		log_event error controller_start_failed "reason=${HW_DISCOVERY_ERROR:-hardware_unavailable}"
		return 1
	fi
	acquire_controller_lock || return 1
	modem_sample_reset
	fan_watch_reset
	if [ "$KERNEL_MONITOR_ONLY" -eq 1 ]; then
		ACTIVE_MODE=kernel
		HANDOFF_ON_EXIT=0
		log_event warning kernel_monitor_fallback "reason=kernel_policy_invalid configured_mode=$CFG_MODE"
	elif [ "$CFG_MODE" = kernel ]; then
		if ! perform_handoff; then
			log_event error controller_start_failed 'reason=kernel_handoff_failed'
			release_startup_lock
			return 1
		fi
		HANDOFF_ON_EXIT=0
	fi
	RUNNING=1
	trap cleanup EXIT
	trap handle_hup HUP
	trap handle_stop INT TERM
	run_loop
}
