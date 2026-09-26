#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lifecycle_fixture.sh"

PWM_FAN_SYS_ROOT=$TEST_TMP/missing-sys PWM_FAN_RUN_DIR=$run \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_HISTORY_FILE=$run/history.tsv \
	PWM_FAN_LOGGER=$bin/logger PWM_FAN_TEST_LOG=$TEST_TMP/disabled-events \
	"$CONTROLLER" run -c "$disabled_config"
[ ! -e "$run/status.json" ] || fail 'Disabled created a runtime snapshot'
[ ! -e "$run/history.tsv" ] || fail 'Disabled created router history'
pass 'Disabled exits without hardware access or runtime telemetry'

before=$(cat "$sys/class/hwmon/hwmon0/pwm1")
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	"$CONTROLLER" probe -c "$config" --json >/dev/null
	assert_eq "$(cat "$sys/class/hwmon/hwmon0/pwm1")" "$before" 'probe performs no PWM write'

PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/events \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/status.json \
	"$CONTROLLER" run -c "$config"

python3 - "$TEST_TMP/status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['contract_version'] == 1
assert status['configured_mode'] == 'manual'
assert status['active_mode'] == 'manual'
assert status['runtime_role'] == 'control'
assert status['requested_pwm'] == 128
assert status['effective_pwm'] == 128
assert status['actual_pwm'] == 128
assert status['control_state'] == 'running'
assert isinstance(status['process_id'], int)
assert status['tach_state'] == 'disabled'
assert status['modem_temperature_millic'] is None
assert status['selected_temperature_millic'] is None
assert status['filtered_temperature_millic'] is None
assert status['pid'] is None
PY
pass 'manual mode publishes a valid runtime snapshot'
assert_eq "$(cat "$sys/class/hwmon/hwmon0/pwm1")" 0 'normal stop hands output back to kernel floor'
[ ! -e "$run/status.json" ] || fail 'runtime status remained after normal stop'
pass 'normal stop removes runtime status'

# An unnormalizable kernel policy must leave PWM untouched and keep a live,
# read-only observer even when the saved mode requests userspace control.
python3 - "$sys/firmware/devicetree/base/fan/cooling-levels" <<'PY'
import pathlib, struct, sys
pathlib.Path(sys.argv[1]).write_bytes(b''.join(struct.pack('>I', value) for value in (0, 255, 128)))
PY
printf '77\n' > "$sys/class/hwmon/hwmon0/pwm1"
printf '0\n' > "$TEST_TMP/uptime"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/fallback-events \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/fallback-status.json \
	"$CONTROLLER" run -c "$config"
python3 - "$TEST_TMP/fallback-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['configured_mode'] == 'manual'
assert status['active_mode'] == 'kernel'
assert status['runtime_role'] == 'observe'
assert status['control_state'] == 'error'
assert status['control_reason'] == 'kernel_policy_invalid'
assert status['cpu_temperature_millic'] == 50000
assert status['actual_pwm'] == 77
assert status['requested_pwm'] is None
assert status['effective_pwm'] is None
assert status['kernel_floor_pwm'] is None
assert status['kernel_policy_direction'] is None
assert status['kernel_strongest_pwm'] is None
PY
assert_eq "$(cat "$sys/class/hwmon/hwmon0/pwm1")" 77 \
	'kernel monitor fallback never writes PWM'
assert_eq "$(grep -c 'code=kernel_monitor_fallback' "$TEST_TMP/fallback-events")" 1 \
	'kernel monitor fallback logs one startup transition'
pass 'invalid kernel policy falls back to live kernel-owned monitoring'
python3 - "$sys/firmware/devicetree/base/fan/cooling-levels" <<'PY'
import pathlib, struct, sys
pathlib.Path(sys.argv[1]).write_bytes(b''.join(struct.pack('>I', value) for value in (255, 40, 0)))
PY
printf '255\n' > "$sys/class/hwmon/hwmon0/pwm1"
printf '0\n' > "$TEST_TMP/uptime"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/inverted-events \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/inverted-status.json \
	"$CONTROLLER" run -c "$config"
python3 - "$TEST_TMP/inverted-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['kernel_policy_direction'] == 'descending'
assert status['kernel_strongest_pwm'] == 0
assert status['requested_pwm'] == 127
assert status['effective_pwm'] == 127
assert status['actual_pwm'] == 127
PY
assert_eq "$(cat "$sys/class/hwmon/hwmon0/pwm1")" 255 \
	'inverted normal stop hands output back to kernel state zero'
pass 'manual cooling demand is converted to inverted raw PWM'
python3 - "$sys/firmware/devicetree/base/fan/cooling-levels" <<'PY'
import pathlib, struct, sys
pathlib.Path(sys.argv[1]).write_bytes(b''.join(struct.pack('>I', value) for value in (0, 128, 255)))
PY

auto_config=$TEST_TMP/auto.conf
sed -e 's/^mode=.*/mode=auto/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	-e 's/^pid_kp=.*/pid_kp=0.07/' -e 's/^pid_ki=.*/pid_ki=0.0002/' \
	-e 's/^pid_kd=.*/pid_kd=0.1/' -e 's/^pid_integral_limit=.*/pid_integral_limit=0.44/' \
	"$DEFAULT_CONFIG" > "$auto_config"
printf '0\n' > "$TEST_TMP/uptime"
cat > "$bin/sleep" <<'EOF'
#!/bin/sh
cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
kill -TERM "$PPID"
EOF
chmod +x "$bin/sleep"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/auto-events \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/auto-status.json \
	"$CONTROLLER" run -c "$auto_config"
python3 - "$TEST_TMP/auto-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['configured_mode'] == 'auto'
assert status['selected_temperature_millic'] == 50000
assert status['filtered_temperature_millic'] == 50000
assert status['requested_pwm'] == 0
assert status['pid'] == {
    'state': 'idle',
    'target_c': 55,
    'temperature_millic': 50000,
    'error_millic': -5000,
    'kp': 0.07,
    'ki': 0.0002,
    'kd': 0.1,
    'integral_limit': 0.44,
}
PY
pass 'Auto status exposes exact configured PID constants and inputs'

filter_config=$TEST_TMP/filter.conf
sed -e 's/^mode=.*/mode=curve/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	-e 's/^temperature_filter_duration_s=.*/temperature_filter_duration_s=5/' \
	"$DEFAULT_CONFIG" > "$filter_config"
printf '50000\n' > "$sys/class/thermal/thermal_zone0/temp"
printf '0\n' > "$TEST_TMP/uptime"
printf '0\n' > "$TEST_TMP/filter-sleep-count"
cat > "$bin/sleep" <<'EOF'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_SLEEP_COUNT"); count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_SLEEP_COUNT"
case $count in
	1) printf '70000\n' > "$PWM_FAN_TEST_TEMPERATURE" ;;
	2) printf '60000\n' > "$PWM_FAN_TEST_TEMPERATURE" ;;
	*) cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"; kill -TERM "$PPID" ;;
esac
EOF
chmod +x "$bin/sleep"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/filter-events \
	PWM_FAN_TEST_SLEEP_COUNT=$TEST_TMP/filter-sleep-count \
	PWM_FAN_TEST_TEMPERATURE=$sys/class/thermal/thermal_zone0/temp \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/filter-status.json \
	"$CONTROLLER" run -c "$filter_config"
grep -q '"filtered_temperature_millic":60000' "$TEST_TMP/filter-status.json" || \
	fail 'daemon control loop did not retain the median filter window'
pass 'daemon control loop retains sequential median samples'
printf '50000\n' > "$sys/class/thermal/thermal_zone0/temp"
kernel_config=$TEST_TMP/kernel.conf
sed -e 's/^mode=.*/mode=kernel/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	"$DEFAULT_CONFIG" > "$kernel_config"
printf '0\n' > "$TEST_TMP/uptime"
printf '0\n' > "$TEST_TMP/kernel-sleep-count"
cat > "$bin/sleep" <<'EOF'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_SLEEP_COUNT"); count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_SLEEP_COUNT"
case $count in
	1)
		mv "$PWM_FAN_TEST_SYS/class/hwmon/hwmon0" "$PWM_FAN_TEST_SYS/class/hwmon/hwmon2"
		printf '77\n' > "$PWM_FAN_TEST_SYS/class/hwmon/hwmon2/pwm1"
		printf '2\n' > "$PWM_FAN_UPTIME_FILE" ;;
	2)
		cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_TEST_KERNEL_FAILED_STATUS"
		printf '11\n' > "$PWM_FAN_UPTIME_FILE" ;;
	3) printf '12\n' > "$PWM_FAN_UPTIME_FILE" ;;
	*)
		cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
		kill -TERM "$PPID" ;;
esac
EOF
chmod +x "$bin/sleep"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/kernel-events \
	PWM_FAN_TEST_SLEEP_COUNT=$TEST_TMP/kernel-sleep-count PWM_FAN_TEST_SYS=$sys \
	PWM_FAN_TEST_KERNEL_FAILED_STATUS=$TEST_TMP/kernel-failed-status.json \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/kernel-status.json \
	"$CONTROLLER" run -c "$kernel_config"
assert_eq "$(cat "$sys/class/hwmon/hwmon2/pwm1")" 77 \
	'Kernel observe performs no PWM write after handoff'
grep -q '"actual_pwm":77' "$TEST_TMP/kernel-status.json" || \
	fail 'ten-second rediscovery did not restore telemetry'
python3 - "$TEST_TMP/kernel-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['runtime_role'] == 'observe'
assert status['requested_pwm'] is None
assert status['effective_pwm'] is None
assert status['cpu_temperature_millic'] == 50000, status
assert status['history_state'] == 'healthy', status
PY
pass 'Kernel status preserves observe-role null semantics'
python3 - "$TEST_TMP/kernel-failed-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['runtime_role'] == 'observe'
assert status['control_state'] == 'error'
assert status['requested_pwm'] is None
assert status['effective_pwm'] is None
PY
grep -q 'temperature_unavailable.*full_output=0' "$TEST_TMP/kernel-events" || \
	fail 'Kernel telemetry failure falsely claimed a full-output write'
pass 'Kernel telemetry failure reports no unperformed PWM write'
pass 'failed telemetry paths rediscover after ten monotonic seconds'
mv "$sys/class/hwmon/hwmon2" "$sys/class/hwmon/hwmon0"
printf '0\n' > "$sys/class/hwmon/hwmon0/pwm1"
