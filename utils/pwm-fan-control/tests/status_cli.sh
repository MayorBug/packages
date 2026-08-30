#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

run=$TEST_TMP/run
mkdir -p "$run"
printf '100\n' > "$TEST_TMP/uptime"

disabled=$TEST_TMP/disabled.conf
sed 's/^mode=.*/mode=disabled/' "$DEFAULT_CONFIG" > "$disabled"
PWM_FAN_CONFIG_FILE=$disabled PWM_FAN_STATUS_FILE=$run/status.json \
	PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime "$CONTROLLER" status-json > "$TEST_TMP/disabled.json"
python3 - "$TEST_TMP/disabled.json" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['configured_mode'] == 'disabled'
assert s['runtime_role'] == 'off'
assert s['control_state'] == 'disabled'
assert s['cpu_temperature_millic'] is None
assert s['health']['monitoring'] == {'state': 'disabled', 'code': 'disabled'}
assert s['health']['controller'] == {'state': 'disabled', 'code': 'disabled'}
assert s['health']['history'] == {'state': 'disabled', 'code': 'disabled'}
PY
pass 'status-json reports Disabled without hardware telemetry'

cat > "$run/status.json" <<EOF
{
  "contract_version":1,
  "process_id":$$,
  "updated_uptime":100,
  "controller_running":true,
  "configured_mode":"curve",
  "active_mode":"curve",
  "configuration_state":"valid",
  "actual_pwm":128
}
EOF
PWM_FAN_CONFIG_FILE=$disabled PWM_FAN_STATUS_FILE=$run/status.json \
	PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime "$CONTROLLER" status-json > "$TEST_TMP/disabled-saved.json"
python3 - "$TEST_TMP/disabled-saved.json" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['configured_mode'] == 'disabled'
assert s['active_mode'] == 'curve'
assert s['actual_pwm'] == 128
assert s['controller_running'] is True
PY
pass 'fresh daemon status wins over saved Disabled until Apply'

rm -f "$run/status.json"

if PWM_FAN_CONFIG_FILE=$DEFAULT_CONFIG PWM_FAN_STATUS_FILE=$run/missing.json \
	PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime "$CONTROLLER" status-json > "$TEST_TMP/stopped.json"; then
	fail 'stopped active controller returned success'
fi
python3 - "$TEST_TMP/stopped.json" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['control_reason'] == 'controller_stopped'
assert s['actual_pwm'] is None
PY
pass 'status-json reports stopped controller without stale telemetry'

cat > "$run/status.json" <<EOF
{"contract_version":1,"process_id":$$,"updated_uptime":0,"actual_pwm":222,"cpu_temperature_millic":99000}
EOF
if PWM_FAN_CONFIG_FILE=$DEFAULT_CONFIG PWM_FAN_STATUS_FILE=$run/status.json \
	PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime "$CONTROLLER" status-json > "$TEST_TMP/stale.json"; then
	fail 'stale controller returned success'
fi
python3 - "$TEST_TMP/stale.json" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['control_reason'] == 'controller_stale'
assert s['actual_pwm'] is None
assert s['cpu_temperature_millic'] is None
PY
pass 'status-json never exposes stale daemon telemetry as current'

cat > "$run/status.json" <<EOF
{"contract_version":1,"process_id":$$,"updated_uptime":100,"actual_pwm":128}
EOF
PWM_FAN_CONFIG_FILE=$DEFAULT_CONFIG PWM_FAN_STATUS_FILE=$run/status.json \
	PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime "$CONTROLLER" status-json > "$TEST_TMP/fresh.json"
assert_eq "$(cat "$TEST_TMP/fresh.json")" "$(cat "$run/status.json")" \
	'status-json passes through a fresh contract snapshot'

invalid=$TEST_TMP/invalid.conf
sed 's/^temperature_filter_duration_s=.*/temperature_filter_duration_s=abc/' "$DEFAULT_CONFIG" > "$invalid"
cat > "$run/status.json" <<EOF
{
  "contract_version":1,
  "process_id":$$,
  "updated_uptime":100,
  "configured_mode":"curve",
  "active_mode":"curve",
  "configuration_state":"valid",
  "actual_pwm":128
}
EOF
if PWM_FAN_CONFIG_FILE=$invalid PWM_FAN_STATUS_FILE=$run/status.json \
	PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime "$CONTROLLER" status-json > "$TEST_TMP/invalid-running.json"; then
	fail 'invalid disk configuration returned success'
fi
python3 - "$TEST_TMP/invalid-running.json" <<'PY'
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert s['configuration_state'] == 'invalid'
assert s['configured_mode'] == 'kernel'
assert s['active_mode'] == 'curve'
assert s['actual_pwm'] == 128
assert any(item['key'] == 'temperature_filter_duration_s'
           for item in s['configuration_diagnostics'])
PY
pass 'invalid disk config preserves fresh active telemetry and diagnostics'

pass 'status JSON freshness contract'
