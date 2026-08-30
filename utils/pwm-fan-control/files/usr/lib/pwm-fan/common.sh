#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Georg Seema <georgseema@gmail.com>

# Generic helpers only. Sourcing this file must have no side effects.

read_value()
{
	local value
	[ -r "$1" ] || return 1
	IFS= read -r value < "$1" || [ -n "$value" ] || return 1
	printf '%s\n' "$value"
}

is_uint()
{
	case ${1:-} in ''|*[!0-9]*) return 1 ;; esac
}

read_uint()
{
	local value
	value=$(read_value "$1") || return 1
	is_uint "$value" || return 1
	printf '%s\n' "$value"
}

monotonic_now()
{
	local value file=${PWM_FAN_UPTIME_FILE:-/proc/uptime}
	value=$(read_value "$file") || return 1
	value=${value%%.*}
	is_uint "$value" || return 1
	printf '%s\n' "$value"
}

deadline_sleep()
{
	local deadline=$1 now remaining sleeper=${PWM_FAN_SLEEP:-sleep}
	is_uint "$deadline" || return 1
	now=$(monotonic_now) || return 1
	[ "$deadline" -gt "$now" ] || return 0
	remaining=$((deadline - now))
	"$sleeper" "$remaining"
}

atomic_replace()
{
	local target=$1 mode=${2:-0600} directory temporary
	[ -n "$target" ] || return 1
	case $mode in *[!0-7]*|'') return 1 ;; esac
	directory=${target%/*}
	[ "$directory" != "$target" ] || directory=.
	[ -d "$directory" ] || return 1
	temporary=$directory/.${target##*/}.tmp.$$
	if ! (umask 077; cat > "$temporary" && chmod "$mode" "$temporary"); then
		rm -f "$temporary"
		return 1
	fi
	if ! mv -f "$temporary" "$target"; then
		rm -f "$temporary"
		return 1
	fi
}

json_escape()
{
	awk 'BEGIN {
		ORS=""
		# Construct these bytes numerically. Passing backslashes through awk -v
		# is interpreted differently by gawk, mawk, and BusyBox awk.
		backslash=sprintf("%c", 92)
		quote=sprintf("%c", 34)
	}
	{
		if (NR > 1) printf "%sn", backslash
		for (i = 1; i <= length($0); i++) {
			character = substr($0, i, 1)
			if (character == backslash) printf "%s%s", backslash, backslash
			else if (character == quote) printf "%s%s", backslash, quote
			else if (character == "\r") printf "%sr", backslash
			else if (character == "\t") printf "%st", backslash
			else if (character == "\b") printf "%sb", backslash
			else if (character == "\f") printf "%sf", backslash
			else printf "%s", character
		}
	}'
}

percent_to_pwm()
{
	local percent=${1:-}
	is_uint "$percent" || return 1
	[ "$percent" -le 100 ] || return 1
	printf '%s\n' $(((percent * 255 + 50) / 100))
}
