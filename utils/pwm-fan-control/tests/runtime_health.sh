#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

. "$PWM_FAN_LIB_DIR/common.sh"
. "$PWM_FAN_LIB_DIR/config.sh"
. "$PWM_FAN_LIB_DIR/runtime.sh"

RUN_DIR=$TEST_TMP/run
STATUS_FILE=$RUN_DIR/status.json
STATUS_VERSION=1
START_UPTIME=0
CFG_MODE=manual
ACTIVE_MODE=manual
SNAP_TIMESTAMP=1
SNAP_UPDATED_UPTIME=1
SNAP_STATE=running
SNAP_REASON=none
SNAP_CPU=50000
SNAP_MODEM=null
SNAP_SELECTED=null
SNAP_SELECTED_SOURCE=null
SNAP_FILTERED=null
SNAP_REQUESTED_PWM=128
SNAP_EFFECTIVE_PWM=128
SNAP_ACTUAL_PWM=128
SNAP_RPM=1200
POLICY_STATE=0
POLICY_FLOOR_PWM=0
HW_TACH_STATE=running
MODEM_STATE=disabled
HISTORY_STATE=healthy
CFG_PID_TARGET_C=55
CFG_PID_KP=0.15
CFG_PID_KI=0.0005
CFG_PID_KD=0.05
CFG_PID_INTEGRAL_LIMIT=0.60
CFG_CURVE_STYLE=smooth
CFG_TEMPERATURE_FILTER=median
CFG_TEMPERATURE_FILTER_DURATION_S=10
CFG_TACH_ENABLED=1
CFG_MODEM_SOURCE=off
CFG_MODEM_HTTP_HOST=192.168.224.1
CFG_MODEM_AT_DEVICE=/dev/ttyUSB2
CFG_MODEM_INTERVAL_S=15
CFG_HWMON_NAME=pwmfan
CFG_THERMAL_ZONE=cpu-thermal
HW_TACH=/sys/class/hwmon/hwmon0/fan1_input

assert_health()
{
	FANWATCH_STATE=$1
	status_write
	python3 - "$STATUS_FILE" "$2" "$3" "$4" "$5" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())['health']
assert (s['monitoring']['state'], s['monitoring']['code']) == (sys.argv[2], sys.argv[3]), s
assert (s['controller']['state'], s['controller']['code']) == (sys.argv[4], sys.argv[5]), s
PY
}

assert_health running healthy none healthy none
assert_health fan_failed error fan_stopped warning cooling_unverified
assert_health pwm_not_applied error pwm_not_applied warning cooling_unverified
assert_health pwm_unavailable error pwm_unavailable warning cooling_unverified
assert_health tach_unavailable warning tach_unavailable healthy none
assert_health tach_read_error warning tach_read_error healthy none
pass 'daemon owns every fan-watch health mapping'

status_write
python3 - "$STATUS_FILE" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['curve_style'] == 'smooth'
assert s['temperature_filter'] == 'median'
assert s['tach_enabled'] is True
assert s['modem_source'] == 'off'
assert s['modem_http_host'] == '192.168.224.1'
assert s['modem_at_device'] == '/dev/ttyUSB2'
assert s['modem_interval_s'] == 15
assert s['hwmon_name'] == 'pwmfan'
assert s['thermal_zone'] == 'cpu-thermal'
assert s['tachometer_available'] is True
PY
pass 'status publishes active configuration and hardware metadata'

ACTIVE_MODE=auto
CFG_MODE=auto
SNAP_FILTERED=54000
PID_TARGET_MILLI=55000
PID_COOLING_ACTIVE=0
status_write
python3 - "$STATUS_FILE" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['pid']['state'] == 'idle'
assert 'hysteresis_c' not in s['pid']
assert 'stop_temperature_millic' not in s['pid']
PY
PID_COOLING_ACTIVE=1
status_write
python3 - "$STATUS_FILE" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['pid']['state'] == 'active'
PY
pass 'status distinguishes active and idle PID state'

ACTIVE_MODE=kernel
CFG_MODE=kernel
SNAP_REQUESTED_PWM=null
SNAP_EFFECTIVE_PWM=null
assert_health running healthy none healthy none
pass 'Kernel observation remains healthy without a userspace PWM target'
