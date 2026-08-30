# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>
modem_parse_scalar_temperature()
{
	awk '{
		gsub(/\r/, "")
		gsub(/^[[:space:]]+|[[:space:]]+$/, "")
		if ($0 ~ /^[0-9]+([.][0-9]+)?$/ && $0 + 0 >= 0 && $0 + 0 <= 125) {
			printf "%.0f\n", ($0 + 0) * 1000; found=1; exit
		}
	} END { if (!found) exit 1 }'
}
modem_qmanager_once()
{
	local timeout=${PWM_FAN_TIMEOUT:-timeout} client=${PWM_FAN_HTTP_CLIENT:-uclient-fetch}
	local jsonfilter=${PWM_FAN_JSONFILTER:-jsonfilter} directory response fields state reachable temperature records
	directory=${PWM_FAN_MODEM_TMP_DIR:-/tmp}
	response=$directory/.pwm-fan-qmanager.$$
	fields=$directory/.pwm-fan-qmanager-fields.$$
	(umask 077; : > "$response") || return 1
	if ! (ulimit -f 128; "$timeout" 5 "$client" -q --no-check-certificate -O "$response" \
		"http://$CFG_MODEM_HTTP_HOST/cgi-bin/quecmanager/public/overview.sh" 2>/dev/null); then
		rm -f "$response"; return 1
	fi
	[ "$(wc -c < "$response" 2>/dev/null || printf '999999\n')" -le 65536 ] || { rm -f "$response"; return 1; }
	if ! (umask 077; "$jsonfilter" -i "$response" -e '@.state' \
		-e '@.modem_reachable' -e '@.temperature' > "$fields" 2>/dev/null); then
		rm -f "$response" "$fields"; return 1
	fi
	rm -f "$response"
	records=$(awk 'END { print NR + 0 }' "$fields" 2>/dev/null) || records=0
	[ "$records" -eq 3 ] || { rm -f "$fields"; return 1; }
	state=$(sed -n '1p' "$fields")
	reachable=$(sed -n '2p' "$fields")
	temperature=$(sed -n '3p' "$fields")
	rm -f "$fields"
	[ "$state" = ok ] && [ "$reachable" = true ] || return 1
	printf '%s\n' "$temperature" | modem_parse_scalar_temperature
}

modem_at_configure()
{
	local stty=${PWM_FAN_STTY:-stty}
	[ "${MODEM_AT_CONFIGURED_DEVICE:-}" = "$CFG_MODEM_AT_DEVICE" ] && return 0
	"$stty" -F "$CFG_MODEM_AT_DEVICE" 115200 raw -echo cs8 -cstopb -parenb \
		-ixon -ixoff -crtscts clocal >/dev/null 2>&1 ||
	"$stty" -F "$CFG_MODEM_AT_DEVICE" 115200 raw -echo cs8 -cstopb -parenb \
		-ixon -ixoff clocal >/dev/null 2>&1 ||
	"$stty" -F "$CFG_MODEM_AT_DEVICE" 115200 raw -echo cs8 -cstopb -parenb \
		>/dev/null 2>&1 || return 1
	MODEM_AT_CONFIGURED_DEVICE=$CFG_MODEM_AT_DEVICE
}

modem_quectel_once()
{
	local timeout=${PWM_FAN_TIMEOUT:-timeout} directory response_file response
	modem_at_configure || return 1
	directory=${PWM_FAN_MODEM_TMP_DIR:-/tmp}
	response_file=$directory/.pwm-fan-at.$$
	(umask 077; : > "$response_file") || return 1
	if ! (ulimit -f 128; "$timeout" 5 sh -c '
		device=$1
		exec 3<>"$device" || exit 1
		printf "AT+QTEMP\r" >&3 || exit 1
		while IFS= read -r line <&3; do
			line=${line%"$(printf "\r")"}
			printf "%s\n" "$line"
			case $line in OK) exit 0 ;; ERROR|+CME\ ERROR:*|+CMS\ ERROR:*) exit 1 ;; esac
		done
		exit 1
	' sh "$CFG_MODEM_AT_DEVICE" > "$response_file" 2>/dev/null); then
		rm -f "$response_file"; MODEM_AT_CONFIGURED_DEVICE=; return 1
	fi
	response=$(cat "$response_file") || { rm -f "$response_file"; return 1; }
	rm -f "$response_file"
	printf '%s\n' "$response" | modem_parse_quectel || {
		MODEM_AT_CONFIGURED_DEVICE=; return 1;
	}
}

modem_parse_quectel()
{
	awk '
		/^\+QTEMP:/ {
			line=$0; sub(/^\+QTEMP:[[:space:]]*/, "", line); split(line, field, ",")
			sensor=field[1]; value=field[2]
			gsub(/[\r"[:space:]]/, "", sensor); gsub(/[\r"[:space:]]/, "", value)
			if (sensor ~ /^cpuss-[0-4]$/ && value ~ /^[-+]?[0-9]+([.][0-9]+)?$/ && value + 0 >= 0 && value + 0 <= 125) {
				if (!found || value + 0 > maximum) maximum=value + 0
				found=1
			}
		}
		$0 == "OK" { ok=1 }
		END { if (!found || !ok) exit 1; printf "%.0f\n", maximum * 1000 }'
}

modem_source_identity()
{
	case $CFG_MODEM_SOURCE in
		qmanager_http) printf 'qmanager_http@%s\n' "$CFG_MODEM_HTTP_HOST" ;;
		quectel_at) printf 'quectel_at@%s\n' "$CFG_MODEM_AT_DEVICE" ;;
		*) return 1 ;;
	esac
}

modem_publish_sample()
{
	local now=$1 temperature=$2 identity
	identity=$(modem_source_identity) || return 1
	mkdir -p "$RUN_DIR" || return 1
	printf '%s|%s|%s\n' "$identity" "$now" "$temperature" |
		atomic_replace "$MODEM_SAMPLE_FILE" 0600
}

modem_acquire_once()
{
	local temperature=
	case $CFG_MODEM_SOURCE in
		qmanager_http) temperature=$(modem_qmanager_once) || temperature= ;;
		quectel_at) temperature=$(modem_quectel_once) || temperature= ;;
		*) return 1 ;;
	esac
	is_uint "$temperature" || return 1
	printf '%s\n' "$temperature"
}

modem_sample_reset()
{
	MODEM_TEMPERATURE_MILLIC=
	MODEM_SAMPLED_UPTIME=
	MODEM_AT_CONFIGURED_DEVICE=
	if [ "$CFG_MODEM_SOURCE" = off ]; then MODEM_STATE=disabled; else MODEM_STATE=waiting; fi
}

modem_sample_read()
{
	local now=$1 expected source sampled temperature extra previous=$MODEM_STATE
	MODEM_TEMPERATURE_MILLIC=
	MODEM_SAMPLED_UPTIME=
	if [ "$CFG_MODEM_SOURCE" = off ]; then MODEM_STATE=disabled; return 1; fi
	expected=$(modem_source_identity) || return 1
	IFS='|' read -r source sampled temperature extra < "$MODEM_SAMPLE_FILE" 2>/dev/null || source=
	if [ -n "$source" ] && [ "$source" = "$expected" ] && [ -z "$extra" ] &&
		is_uint "$sampled" && is_uint "$temperature" && [ "$sampled" -le "$now" ] &&
		[ "$now" -le $((sampled + CFG_MODEM_INTERVAL_S * 2)) ]; then
		MODEM_STATE=available
		MODEM_SAMPLED_UPTIME=$sampled
		MODEM_TEMPERATURE_MILLIC=$temperature
		return 0
	fi
	if [ "$previous" = available ] || [ "$previous" = lost ]; then MODEM_STATE=lost; else MODEM_STATE=waiting; fi
	return 1
}

modem_sampler_reload() { MODEM_RELOAD_REQUESTED=1; }
modem_sampler_stop() { MODEM_STOP_REQUESTED=1; }

run_modem_sampler()
{
	local now deadline temperature
	config_parse "$CONFIG_FILE" && config_validate || return 1
	[ "$CFG_MODE" != disabled ] && [ "$CFG_MODEM_SOURCE" != off ] || return 0
	MODEM_STOP_REQUESTED=0
	MODEM_RELOAD_REQUESTED=0
	trap modem_sampler_reload HUP
	trap modem_sampler_stop INT TERM
	while [ "$MODEM_STOP_REQUESTED" -eq 0 ]; do
		now=$(read_uptime) || return 1
		temperature=$(modem_acquire_once) || temperature=
		[ -z "$temperature" ] || modem_publish_sample "$now" "$temperature" || true
		deadline=$((now + CFG_MODEM_INTERVAL_S))
		while [ "$MODEM_STOP_REQUESTED" -eq 0 ]; do
			[ "$MODEM_RELOAD_REQUESTED" -eq 0 ] || {
				MODEM_RELOAD_REQUESTED=0
				config_parse "$CONFIG_FILE" && config_validate || return 1
				[ "$CFG_MODE" != disabled ] && [ "$CFG_MODEM_SOURCE" != off ] || return 0
				break
			}
			now=$(read_uptime) || return 1
			[ "$now" -lt "$deadline" ] || break
			deadline_sleep "$deadline" || true
		done
	done
}
