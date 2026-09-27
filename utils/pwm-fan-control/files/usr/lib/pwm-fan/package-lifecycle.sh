#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu

INIT=${PWM_FAN_PACKAGE_INIT:-/etc/init.d/pwm-fan-control}
PID_FILE=${PWM_FAN_PACKAGE_PID_FILE:-/var/run/pwm-fan-control/daemon.lock/pid}

[ -z "${IPKG_INSTROOT:-}" ] || exit 0
[ -x "$INIT" ] || exit 0

pid=$(cat "$PID_FILE" 2>/dev/null || true)
case $pid in
	''|*[!0-9]*) pid= ;;
	*) [ "$pid" -gt 1 ] || pid= ;;
esac

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
	# An upgrade replaces sourced shell libraries underneath the old process.
	# Reload cannot replace already-loaded functions, so perform a full restart.
	"$INIT" restart
elif [ "${PKG_UPGRADE:-0}" != 1 ]; then
	# A first installation should become usable without a reboot or manual setup.
	"$INIT" enable
	"$INIT" start
fi
