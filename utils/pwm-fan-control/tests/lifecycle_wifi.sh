#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lifecycle_fixture.sh"

wifi_config=$TEST_TMP/auto-wifi.conf
sed -e 's/^mode=.*/mode=auto/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	-e 's/^temperature_filter=.*/temperature_filter=none/' \
	-e 's/^wifi_source=.*/wifi_source=auto/' \
	"$DEFAULT_CONFIG" > "$wifi_config"
mkdir -p "$sys/class/hwmon/hwmon3" "$sys/class/hwmon/hwmon4"
printf 'mt7915_phy0\n' > "$sys/class/hwmon/hwmon3/name"
printf '57000\n' > "$sys/class/hwmon/hwmon3/temp1_input"
printf 'mt7915_phy1\n' > "$sys/class/hwmon/hwmon4/name"
printf '76000\n' > "$sys/class/hwmon/hwmon4/temp1_input"
printf '50000\n' > "$sys/class/thermal/thermal_zone0/temp"
printf '1\n' > "$TEST_TMP/uptime"

cat > "$bin/controller-sleep" <<'EOF'
#!/bin/sh
cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
kill -TERM "$PPID"
EOF
chmod +x "$bin/controller-sleep"

run_controller_capture()
{
	local output=$1 config=$2
	PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
		PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_MODEM_SAMPLE_FILE=$run/modem.sample \
		PWM_FAN_LOGGER=$bin/logger PWM_FAN_SLEEP=$bin/controller-sleep \
		PWM_FAN_TEST_LOG=$TEST_TMP/wifi-events PWM_FAN_CAPTURED_STATUS=$output \
		"$CONTROLLER" run -c "$config"
}

run_controller_capture "$TEST_TMP/auto-status.json" "$wifi_config"
python3 - "$TEST_TMP/auto-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['wifi_source'] == 'auto'
assert status['wifi_temperature_millic'] == 76000
assert status['wifi_temperature_source'] == 'mt7915_phy1'
assert status['selected_temperature_millic'] == 76000
assert status['selected_temperature_source'] == 'wifi:mt7915_phy1'
assert len(status['wifi_sensors']) == 2
PY
pass 'automatic hottest Wi-Fi radio controls Auto'

all_sources_config=$TEST_TMP/all-sources.conf
sed 's/^modem_source=.*/modem_source=qmanager_http/' "$wifi_config" > "$all_sources_config"
printf 'qmanager_http@192.168.224.1|1|80000\n' > "$run/modem.sample"
run_controller_capture "$TEST_TMP/modem-wins-status.json" "$all_sources_config"
python3 - "$TEST_TMP/modem-wins-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['selected_temperature_millic'] == 80000
assert status['selected_temperature_source'] == 'modem'
PY
printf 'qmanager_http@192.168.224.1|1|76000\n' > "$run/modem.sample"
run_controller_capture "$TEST_TMP/wifi-tie-status.json" "$all_sources_config"
python3 - "$TEST_TMP/wifi-tie-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['selected_temperature_millic'] == 76000
assert status['selected_temperature_source'] == 'wifi:mt7915_phy1'
PY
rm -f "$run/modem.sample"
pass 'CPU Wi-Fi and modem arbitration preserves deterministic priority'

exact_config=$TEST_TMP/exact-wifi.conf
sed 's/^wifi_source=.*/wifi_source=mt7915_phy0/' "$wifi_config" > "$exact_config"
run_controller_capture "$TEST_TMP/exact-status.json" "$exact_config"
python3 - "$TEST_TMP/exact-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['wifi_temperature_millic'] == 57000
assert status['wifi_temperature_source'] == 'mt7915_phy0'
assert status['selected_temperature_source'] == 'wifi:mt7915_phy0'
PY
pass 'exact Wi-Fi radio selection controls Auto'

missing_config=$TEST_TMP/missing-wifi.conf
sed 's/^wifi_source=.*/wifi_source=mt7915_phy9/' "$wifi_config" > "$missing_config"
run_controller_capture "$TEST_TMP/missing-status.json" "$missing_config"
python3 - "$TEST_TMP/missing-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['wifi_temperature_millic'] is None
assert status['wifi_state'] == 'unavailable'
assert status['selected_temperature_millic'] == 50000
assert status['selected_temperature_source'] == 'cpu'
assert status['control_state'] != 'failsafe'
PY
pass 'missing optional Wi-Fi source falls back to required CPU'

kernel_config=$TEST_TMP/kernel-wifi.conf
sed 's/^mode=.*/mode=kernel/' "$wifi_config" > "$kernel_config"
run_controller_capture "$TEST_TMP/kernel-wifi-status.json" "$kernel_config"
python3 - "$TEST_TMP/kernel-wifi-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['wifi_temperature_millic'] == 76000
assert status['selected_temperature_source'] is None
assert status['requested_pwm'] is None
PY
manual_config=$TEST_TMP/manual-wifi.conf
sed 's/^mode=.*/mode=manual/' "$wifi_config" > "$manual_config"
run_controller_capture "$TEST_TMP/manual-wifi-status.json" "$manual_config"
python3 - "$TEST_TMP/manual-wifi-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['wifi_temperature_millic'] == 76000
assert status['selected_temperature_source'] is None
assert status['requested_pwm'] == 128
PY
pass 'Wi-Fi telemetry does not alter Kernel or Manual output selection'

printf 'invalid\n' > "$sys/class/thermal/thermal_zone0/temp"
run_controller_capture "$TEST_TMP/cpu-failure-status.json" "$wifi_config" || true
python3 - "$TEST_TMP/cpu-failure-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['control_state'] == 'failsafe'
assert status['control_reason'] == 'temperature_unavailable'
assert status['wifi_temperature_millic'] is None
assert status['wifi_temperature_source'] is None
assert status['wifi_state'] == 'unavailable'
assert status['effective_pwm'] == status['kernel_strongest_pwm']
PY
pass 'healthy Wi-Fi never masks required CPU failure'
