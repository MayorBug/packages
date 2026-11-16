#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lifecycle_fixture.sh"

# Fail after direction and maximum output were calculated, not during parsing.
printf '1\n' > "$sys/class/thermal/cooling_device0/max_state"
printf '77\n' > "$sys/class/hwmon/hwmon0/pwm1"
printf '0\n' > "$TEST_TMP/count"
cat > "$bin/sleep" <<'SLEEP'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_COUNT"); count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_COUNT"
case $count in
	1)
		cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_TEST_FALLBACK_STATUS"
		cat "$PWM_FAN_TEST_PWM" > "$PWM_FAN_TEST_FALLBACK_PWM"
		printf '2\n' > "$PWM_FAN_TEST_MAX_STATE"
		kill -HUP "$PPID" ;;
	*)
		cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
		kill -TERM "$PPID" ;;
esac
SLEEP
chmod +x "$bin/sleep"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/events \
	PWM_FAN_TEST_COUNT=$TEST_TMP/count \
	PWM_FAN_TEST_FALLBACK_STATUS=$TEST_TMP/fallback.json \
	PWM_FAN_TEST_FALLBACK_PWM=$TEST_TMP/fallback-pwm \
	PWM_FAN_TEST_PWM=$sys/class/hwmon/hwmon0/pwm1 \
	PWM_FAN_TEST_MAX_STATE=$sys/class/thermal/cooling_device0/max_state \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/recovered.json \
	"$CONTROLLER" run -c "$config"
assert_eq "$(cat "$TEST_TMP/fallback-pwm")" 77 'late policy failure keeps PWM untouched'
python3 - "$TEST_TMP/fallback.json" "$TEST_TMP/recovered.json" <<'PY'
import json, pathlib, sys
fallback, recovered = [json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:]]
assert fallback['active_mode'] == 'kernel'
assert fallback['control_reason'] == 'kernel_policy_invalid'
for key in ['kernel_policy_direction', 'kernel_strongest_pwm', 'kernel_floor_state', 'kernel_floor_pwm']:
    assert fallback[key] is None, (key, fallback[key])
assert recovered['active_mode'] == 'manual'
assert recovered['control_state'] == 'running'
assert recovered['control_reason'] == 'none'
assert recovered['effective_pwm'] == 128
assert recovered['actual_pwm'] == 128
PY
pass 'late policy failure clears unvalidated policy fields and reload resumes control'
