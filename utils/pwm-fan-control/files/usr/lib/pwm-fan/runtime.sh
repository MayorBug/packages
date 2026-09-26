#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

snapshot_set()
{
	SNAP_STATE=$1; SNAP_REASON=$2; SNAP_CPU=$3; SNAP_SELECTED=$4; SNAP_FILTERED=$5
	SNAP_MODEM=$6; SNAP_REQUESTED_PWM=$7; SNAP_EFFECTIVE_PWM=$8
	SNAP_ACTUAL_PWM=$9; SNAP_RPM=${10}
	SNAP_SELECTED_SOURCE=${SELECTED_TEMPERATURE_SOURCE:-null}
	SNAP_TIMESTAMP=$(date +%s 2>/dev/null || printf "0\n")
	SNAP_UPDATED_UPTIME=$(read_uptime 2>/dev/null || printf "0\n")
}

status_write()
{
	local temporary role hardware_state pid_temperature=null pid_error=null pid_state=idle active_mode=${ACTIVE_MODE:-$CFG_MODE}
	local monitoring_state=healthy monitoring_code=none controller_state=healthy controller_code=none
	local history_health=healthy history_code=none
	case $active_mode in kernel) role=observe ;; *) role=control ;; esac
	case $SNAP_STATE in failsafe|error) hardware_state=error ;; *) hardware_state=healthy ;; esac
	case $SNAP_STATE in failsafe|error) controller_state=error; controller_code=$SNAP_REASON ;; esac
	case $FANWATCH_STATE in
		fan_failed) monitoring_state=error; monitoring_code=fan_stopped; controller_state=warning; controller_code=cooling_unverified ;;
		pwm_not_applied) monitoring_state=error; monitoring_code=pwm_not_applied; controller_state=warning; controller_code=cooling_unverified ;;
		pwm_unavailable) monitoring_state=error; monitoring_code=pwm_unavailable; controller_state=warning; controller_code=cooling_unverified ;;
		tach_unavailable) monitoring_state=warning; monitoring_code=tach_unavailable ;;
		tach_read_error) monitoring_state=warning; monitoring_code=tach_read_error ;;
	esac
	if [ "$monitoring_state" = healthy ] && [ "$hardware_state" = error ]; then monitoring_state=error; monitoring_code=$SNAP_REASON; fi
	if [ "$monitoring_state" = healthy ] && [ "$MODEM_STATE" = lost ]; then monitoring_state=warning; monitoring_code=modem_unavailable; fi
	if [ "$HISTORY_STATE" = error ]; then history_health=error; history_code=history_write_failed; fi
	if [ "$active_mode" = auto ] && is_uint "$SNAP_FILTERED"; then
		pid_temperature=$SNAP_FILTERED
		pid_error=$((SNAP_FILTERED - PID_TARGET_MILLI))
		[ "$PID_COOLING_ACTIVE" -ne 1 ] || pid_state=active
	fi
	mkdir -p "$RUN_DIR" || return 1
	temporary=$STATUS_FILE.$$
	if ! (umask 077; {
		printf "{\n"
		printf "  \"contract_version\":%s,\n" "$STATUS_VERSION"
		printf "  \"process_id\":%s,\n" "$$"
		printf "  \"timestamp\":%s,\n" "$SNAP_TIMESTAMP"
		printf "  \"started_uptime\":%s,\n" "$START_UPTIME"
		printf "  \"updated_uptime\":%s,\n" "$SNAP_UPDATED_UPTIME"
		printf "  \"controller_running\":true,\n"
		printf "  \"controller_fresh\":true,\n"
		printf "  \"configured_mode\":\"%s\",\n" "$CFG_MODE"
		printf "  \"active_mode\":\"%s\",\n" "$active_mode"
		printf "  \"curve_style\":\"%s\",\n" "$CFG_CURVE_STYLE"
		printf "  \"temperature_filter\":\"%s\",\n" "$CFG_TEMPERATURE_FILTER"
		printf "  \"temperature_filter_duration_s\":%s,\n" "$CFG_TEMPERATURE_FILTER_DURATION_S"
		printf "  \"tach_enabled\":%s,\n" "$([ "$CFG_TACH_ENABLED" = 1 ] && printf true || printf false)"
		printf "  \"modem_source\":\"%s\",\n" "$CFG_MODEM_SOURCE"
		printf "  \"modem_http_host\":\"%s\",\n" "$(printf '%s' "$CFG_MODEM_HTTP_HOST" | json_escape)"
		printf "  \"modem_at_device\":\"%s\",\n" "$(printf '%s' "$CFG_MODEM_AT_DEVICE" | json_escape)"
		printf "  \"modem_interval_s\":%s,\n" "$CFG_MODEM_INTERVAL_S"
		printf "  \"hwmon_name\":\"%s\",\n" "$(printf '%s' "$CFG_HWMON_NAME" | json_escape)"
		printf "  \"thermal_zone\":\"%s\",\n" "$(printf '%s' "$CFG_THERMAL_ZONE" | json_escape)"
		printf "  \"tachometer_available\":%s,\n" "$([ -n "${HW_TACH:-}" ] && printf true || printf false)"
		printf "  \"runtime_role\":\"%s\",\n" "$role"
		printf "  \"configuration_state\":\"valid\",\n"
		printf "  \"hardware_state\":\"%s\",\n" "$hardware_state"
		printf "  \"control_state\":\"%s\",\n" "$SNAP_STATE"
		printf "  \"control_reason\":\"%s\",\n" "$(printf "%s" "$SNAP_REASON" | json_escape)"
		printf "  \"history_state\":\"%s\",\n" "$HISTORY_STATE"
		printf "  \"cpu_temperature_millic\":%s,\n" "$SNAP_CPU"
		printf "  \"modem_temperature_millic\":%s,\n" "$SNAP_MODEM"
		printf "  \"selected_temperature_millic\":%s,\n" "$SNAP_SELECTED"
		if [ "$SNAP_SELECTED_SOURCE" = null ]; then
			printf "  \"selected_temperature_source\":null,\n"
		else
			printf "  \"selected_temperature_source\":\"%s\",\n" "$SNAP_SELECTED_SOURCE"
		fi
		printf "  \"filtered_temperature_millic\":%s,\n" "$SNAP_FILTERED"
		printf "  \"requested_pwm\":%s,\n" "$SNAP_REQUESTED_PWM"
		printf "  \"kernel_policy_direction\":"
		if [ -n "${POLICY_DIRECTION:-}" ]; then printf '"%s",\n' "$POLICY_DIRECTION"; else printf 'null,\n'; fi
		printf "  \"kernel_strongest_pwm\":%s,\n" "${POLICY_FULL_PWM:-null}"
		printf "  \"kernel_floor_state\":%s,\n" "${POLICY_STATE:-null}"
		printf "  \"kernel_floor_pwm\":%s,\n" "${POLICY_FLOOR_PWM:-null}"
		printf "  \"effective_pwm\":%s,\n" "$SNAP_EFFECTIVE_PWM"
		printf "  \"actual_pwm\":%s,\n" "$SNAP_ACTUAL_PWM"
		printf "  \"rpm\":%s,\n" "$SNAP_RPM"
		printf "  \"tach_state\":\"%s\",\n" "$HW_TACH_STATE"
		printf "  \"fan_state\":\"%s\",\n" "$FANWATCH_STATE"
		printf "  \"modem_state\":\"%s\",\n" "$MODEM_STATE"
		printf '  "health":{"monitoring":{"state":"%s","code":"%s"},' "$monitoring_state" "$monitoring_code"
		printf '"controller":{"state":"%s","code":"%s"},' "$controller_state" "$controller_code"
		printf '"history":{"state":"%s","code":"%s"}},\n' "$history_health" "$history_code"
		if [ "$active_mode" = auto ]; then
			printf "  \"pid\":{\"state\":\"%s\",\"target_c\":%s,\"temperature_millic\":%s,\"error_millic\":%s," "$pid_state" "$CFG_PID_TARGET_C" "$pid_temperature" "$pid_error"
			printf "\"kp\":%s,\"ki\":%s,\"kd\":%s,\"integral_limit\":%s}\n" "$CFG_PID_KP" "$CFG_PID_KI" "$CFG_PID_KD" "$CFG_PID_INTEGRAL_LIMIT"
		else
			printf '  "pid":null\n'
		fi
		printf "}\n"
	} > "$temporary" && chmod 0600 "$temporary"); then rm -f "$temporary"; return 1; fi
	mv -f "$temporary" "$STATUS_FILE"
}

history_lock_acquire()
{
	local owner
	mkdir -p "$RUN_DIR" || return 1
	if ! mkdir "$HISTORY_LOCK" 2>/dev/null; then
		owner=$(cat "$HISTORY_LOCK/owner" 2>/dev/null || true)
		is_uint "$owner" || return 1
		kill -0 "$owner" 2>/dev/null && return 1
		rm -f "$HISTORY_LOCK/owner" 2>/dev/null || return 1
		rmdir "$HISTORY_LOCK" 2>/dev/null || return 1
		mkdir "$HISTORY_LOCK" 2>/dev/null || return 1
	fi
	printf '%s\n' "$$" > "$HISTORY_LOCK/owner" || {
		rmdir "$HISTORY_LOCK" 2>/dev/null || true
		return 1
	}
}

history_lock_release()
{
	[ "$(cat "$HISTORY_LOCK/owner" 2>/dev/null || true)" = "$$" ] || return 0
	rm -f "$HISTORY_LOCK/owner" 2>/dev/null || true
	rmdir "$HISTORY_LOCK" 2>/dev/null || true
}

history_append_snapshot()
{
	local total valid normalized=$RUN_DIR/.history-normalized.$$ mode=${ACTIVE_MODE:-$CFG_MODE}
	history_lock_acquire || return 1
	[ -e "$HISTORY_FILE" ] || printf '' | atomic_replace "$HISTORY_FILE" 0600 || {
		history_lock_release
		return 1
	}
	if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$SNAP_TIMESTAMP" "$mode" "$SNAP_CPU" "$SNAP_MODEM" \
		"$SNAP_REQUESTED_PWM" "${POLICY_FLOOR_PWM:-null}" "$SNAP_EFFECTIVE_PWM" \
		"$SNAP_ACTUAL_PWM" "$SNAP_RPM" "$FANWATCH_STATE" >> "$HISTORY_FILE"; then
		history_lock_release
		return 1
	fi
	total=$(wc -l < "$HISTORY_FILE" 2>/dev/null || printf '0\n')
	valid=$(awk -F '\t' '
		NF == 10 && $1 ~ /^[0-9]+$/ && $2 ~ /^(kernel|auto|curve|manual)$/ &&
		$3 ~ /^(null|[0-9]+)$/ && $4 ~ /^(null|[0-9]+)$/ &&
		$5 ~ /^(null|[0-9]+)$/ && $6 ~ /^(null|[0-9]+)$/ &&
		$7 ~ /^(null|[0-9]+)$/ && $8 ~ /^(null|[0-9]+)$/ &&
		$9 ~ /^(null|[0-9]+)$/ && $10 ~ /^[a-z_]+$/ { count++ }
		END { print count + 0 }' "$HISTORY_FILE" 2>/dev/null || printf '0\n')
	if [ "$total" -gt 1440 ] || [ "$valid" -ne "$total" ]; then
		if ! awk -F '\t' '
			NF == 10 && $1 ~ /^[0-9]+$/ && $2 ~ /^(kernel|auto|curve|manual)$/ &&
			$3 ~ /^(null|[0-9]+)$/ && $4 ~ /^(null|[0-9]+)$/ &&
			$5 ~ /^(null|[0-9]+)$/ && $6 ~ /^(null|[0-9]+)$/ &&
			$7 ~ /^(null|[0-9]+)$/ && $8 ~ /^(null|[0-9]+)$/ &&
			$9 ~ /^(null|[0-9]+)$/ && $10 ~ /^[a-z_]+$/ { print }' \
			"$HISTORY_FILE" | tail -n 1440 > "$normalized" ||
			! atomic_replace "$HISTORY_FILE" 0600 < "$normalized"; then
			rm -f "$normalized"
			history_lock_release
			return 1
		fi
		rm -f "$normalized"
	fi
	history_lock_release
}

history_record_if_due()
{
	local now=$1 previous=$HISTORY_STATE
	[ "$now" -ge "$HISTORY_NEXT_UPTIME" ] || return 0
	while [ "$HISTORY_NEXT_UPTIME" -le "$now" ]; do
		HISTORY_NEXT_UPTIME=$((HISTORY_NEXT_UPTIME + 60))
	done
	if history_append_snapshot; then
		HISTORY_STATE=healthy
		[ "$previous" != error ] || log_event info history_recovered
	else
		HISTORY_STATE=error
		[ "$previous" = error ] || log_event warning history_write_failed
		return 1
	fi
}

history_clear()
{
	history_lock_acquire || return 1
	if ! printf '' | atomic_replace "$HISTORY_FILE" 0600; then
		history_lock_release
		return 1
	fi
	history_lock_release
}
