#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lifecycle_fixture.sh"

timeout_config=$TEST_TMP/manual-timeout.conf
sed -e 's/^mode=.*/mode=curve/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	"$DEFAULT_CONFIG" > "$timeout_config"
printf '0\n' > "$TEST_TMP/uptime"
printf '0\n' > "$TEST_TMP/sleep-count"
: > "$TEST_TMP/timeout-events"

cat > "$bin/sleep" <<'EOF'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_SLEEP_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_SLEEP_COUNT"
case $count in
	1)
		printf '1000\n' > "$PWM_FAN_UPTIME_FILE"
		sed -e 's/^mode=.*/mode = manual/' \
			-e 's/^manual_timeout_min=.*/manual_timeout_min=1/' \
			"$PWM_FAN_TEST_CONFIG" > "$PWM_FAN_TEST_CONFIG.tmp"
		mv "$PWM_FAN_TEST_CONFIG.tmp" "$PWM_FAN_TEST_CONFIG"
		kill -HUP "$PPID" ;;
	2) printf '1059\n' > "$PWM_FAN_UPTIME_FILE" ;;
	3) printf '1060\n' > "$PWM_FAN_UPTIME_FILE" ;;
	*) kill -TERM "$PPID" ;;
esac
EOF
chmod +x "$bin/sleep"

PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_CONFIG_LOCK=$TEST_TMP/config.lock \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/timeout-events \
	PWM_FAN_TEST_SLEEP_COUNT=$TEST_TMP/sleep-count \
	PWM_FAN_TEST_SYS=$sys \
	PWM_FAN_TEST_CONFIG=$timeout_config \
	"$CONTROLLER" run -c "$timeout_config"

assert_eq "$(cat "$TEST_TMP/sleep-count")" 4 \
	'manual timeout transitions into persistent Kernel observation'
grep -q '^mode=kernel$' "$timeout_config" || \
	fail 'manual timeout did not replace a whitespace-padded mode setting'
grep -q 'manual_timeout' "$TEST_TMP/timeout-events" || \
	fail 'manual timeout event was not logged'
pass 'manual timeout safely rewrites whitespace-padded mode setting'
if grep -q 'temperature_unavailable' "$TEST_TMP/timeout-events"; then
	fail 'HUP reload continued using stale hardware paths'
fi
pass 'HUP reload preserves hardware paths for ordinary changes'

restart_config=$TEST_TMP/restart-only.conf
sed -e 's/^mode=.*/mode=manual/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	"$DEFAULT_CONFIG" > "$restart_config"
printf '0\n' > "$TEST_TMP/uptime"
printf '0\n' > "$TEST_TMP/restart-sleep-count"
: > "$TEST_TMP/restart-events"
cat > "$bin/sleep" <<'EOF'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_SLEEP_COUNT"); count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_SLEEP_COUNT"
case $count in
	1)
		sed 's/^hwmon_name=.*/hwmon_name=replacement-fan/' \
			"$PWM_FAN_TEST_CONFIG" > "$PWM_FAN_TEST_CONFIG.tmp"
		mv "$PWM_FAN_TEST_CONFIG.tmp" "$PWM_FAN_TEST_CONFIG"
		kill -HUP "$PPID" ;;
	*)
		cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
		kill -TERM "$PPID" ;;
esac
EOF
chmod +x "$bin/sleep"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_CONFIG_LOCK=$TEST_TMP/restart-config.lock \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/restart-events \
	PWM_FAN_TEST_SLEEP_COUNT=$TEST_TMP/restart-sleep-count \
	PWM_FAN_TEST_CONFIG=$restart_config \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/restart-status.json \
	"$CONTROLLER" run -c "$restart_config"
grep -q 'hardware_change_requires_restart' "$TEST_TMP/restart-events" ||
	fail 'hardware target reload was not rejected explicitly'
grep -q '"configured_mode":"manual"' "$TEST_TMP/restart-status.json" ||
	fail 'hardware target rejection lost the active controller state'
grep -q '"actual_pwm":128' "$TEST_TMP/restart-status.json" ||
	fail 'hardware target rejection stopped controlling the original fan'
pass 'hardware target changes require restart and preserve the active target'

wifi_reload_config=$TEST_TMP/wifi-reload.conf
sed -e 's/^mode=.*/mode=auto/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	-e 's/^temperature_filter=.*/temperature_filter=none/' \
	-e 's/^wifi_source=.*/wifi_source=mt7915_phy0/' \
	"$DEFAULT_CONFIG" > "$wifi_reload_config"
mkdir -p "$sys/class/hwmon/hwmon3" "$sys/class/hwmon/hwmon4"
printf 'mt7915_phy0\n' > "$sys/class/hwmon/hwmon3/name"
printf '57000\n' > "$sys/class/hwmon/hwmon3/temp1_input"
printf 'mt7915_phy1\n' > "$sys/class/hwmon/hwmon4/name"
printf '76000\n' > "$sys/class/hwmon/hwmon4/temp1_input"
printf '0\n' > "$TEST_TMP/uptime"
printf '0\n' > "$TEST_TMP/wifi-reload-sleep-count"
cooling_levels=$sys/firmware/devicetree/base/fan/cooling-levels
cp "$cooling_levels" "$TEST_TMP/cooling-levels"
cat > "$bin/sleep" <<'EOF'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_SLEEP_COUNT"); count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_SLEEP_COUNT"
case $count in
	1)
		sed 's/^wifi_source=.*/wifi_source=mt7915_phy1/' \
			"$PWM_FAN_TEST_CONFIG" > "$PWM_FAN_TEST_CONFIG.tmp"
		mv "$PWM_FAN_TEST_CONFIG.tmp" "$PWM_FAN_TEST_CONFIG"
		: > "$PWM_FAN_TEST_COOLING_LEVELS"
		kill -HUP "$PPID" ;;
	*)
		cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
		kill -TERM "$PPID" ;;
esac
EOF
chmod +x "$bin/sleep"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_CONFIG_LOCK=$TEST_TMP/wifi-reload.lock \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/wifi-reload-events \
	PWM_FAN_TEST_SLEEP_COUNT=$TEST_TMP/wifi-reload-sleep-count \
	PWM_FAN_TEST_CONFIG=$wifi_reload_config \
	PWM_FAN_TEST_COOLING_LEVELS=$cooling_levels \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/wifi-reload-status.json \
	"$CONTROLLER" run -c "$wifi_reload_config"
cp "$TEST_TMP/cooling-levels" "$cooling_levels"
python3 - "$TEST_TMP/wifi-reload-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['wifi_source'] == 'mt7915_phy0'
assert status['wifi_temperature_source'] == 'mt7915_phy0'
assert status['wifi_temperature_millic'] == 57000
PY
pass 'rejected reload restores active Wi-Fi discovery state'

failure_config=$TEST_TMP/manual-timeout-failure.conf
sed -e 's/^mode=.*/mode=manual/' \
	-e 's/^manual_timeout_min=.*/manual_timeout_min=1/' \
	-e 's/^tach_enabled=.*/tach_enabled=0/' \
	"$DEFAULT_CONFIG" > "$failure_config"
printf '0\n' > "$TEST_TMP/uptime"
printf '0\n' > "$TEST_TMP/failure-sleep-count"
: > "$TEST_TMP/failure-events"
cat > "$bin/sleep" <<'EOF'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_SLEEP_COUNT"); count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_SLEEP_COUNT"
case $count in
	1)
		mkdir "$PWM_FAN_TEST_CONFIG_LOCK"
		date +%s > "$PWM_FAN_TEST_CONFIG_LOCK/created"
		printf '60\n' > "$PWM_FAN_UPTIME_FILE" ;;
	*)
		cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
		kill -TERM "$PPID" ;;
esac
EOF
chmod +x "$bin/sleep"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_LOGGER=$bin/logger \
	PWM_FAN_CONFIG_LOCK=$TEST_TMP/failure.lock \
	PWM_FAN_SLEEP=$bin/sleep PWM_FAN_TEST_LOG=$TEST_TMP/failure-events \
	PWM_FAN_TEST_SLEEP_COUNT=$TEST_TMP/failure-sleep-count \
	PWM_FAN_TEST_CONFIG_LOCK=$TEST_TMP/failure.lock \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/failure-status.json \
	"$CONTROLLER" run -c "$failure_config"
grep -q '^mode=manual$' "$failure_config" || \
	fail 'failed timeout config write changed the saved mode'
grep -q '"configured_mode":"manual"' "$TEST_TMP/failure-status.json" || \
	fail 'failed timeout left the current Manual role'
grep -q '"actual_pwm":128' "$TEST_TMP/failure-status.json" || \
	fail 'failed Manual timeout did not retain configured safe output'
assert_eq "$(grep -c 'code=manual_timeout_failed' "$TEST_TMP/failure-events")" 1 \
	'repeated Manual timeout failure logs once'
pass 'failed Manual timeout retains configured safe output'
