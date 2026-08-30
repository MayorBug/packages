#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lifecycle_fixture.sh"

modem_config=$TEST_TMP/auto-modem.conf
sed -e 's/^mode=.*/mode=auto/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	-e 's/^temperature_filter=.*/temperature_filter=none/' \
	-e 's/^modem_source=.*/modem_source=qmanager_http/' \
	"$DEFAULT_CONFIG" > "$modem_config"

printf '0\n' > "$TEST_TMP/uptime"
printf '0\n' > "$TEST_TMP/sampler-sleep-count"
printf '{"state":"ok","modem_reachable":true,"temperature":60}\n' > "$TEST_TMP/qmanager.json"
cat > "$bin/timeout" <<'EOF'
#!/bin/sh
[ "$1" = 5 ] || exit 1
shift
exec "$@"
EOF
cat > "$bin/uclient-fetch" <<'EOF'
#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -O ]; then output=$2; shift 2; else shift; fi
done
cp "$PWM_FAN_TEST_QMANAGER" "$output"
EOF
cat > "$bin/jsonfilter" <<'EOF'
#!/bin/sh
printf 'ok\ntrue\n60\n'
EOF
cat > "$bin/modem-sleep" <<'EOF'
#!/bin/sh
count=$(cat "$PWM_FAN_TEST_SLEEP_COUNT"); count=$((count + 1))
printf '%s\n' "$count" > "$PWM_FAN_TEST_SLEEP_COUNT"
if [ "$count" -eq 1 ]; then
	cp "$PWM_FAN_MODEM_SAMPLE_FILE" "$PWM_FAN_CAPTURED_SAMPLE"
	kill -TERM "$PPID"
fi
EOF
chmod +x "$bin/timeout" "$bin/uclient-fetch" "$bin/jsonfilter" "$bin/modem-sleep"
PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_MODEM_SAMPLE_FILE=$run/modem.sample PWM_FAN_SLEEP=$bin/modem-sleep \
	PWM_FAN_TIMEOUT=$bin/timeout PWM_FAN_HTTP_CLIENT=$bin/uclient-fetch \
	PWM_FAN_JSONFILTER=$bin/jsonfilter PWM_FAN_MODEM_TMP_DIR=$TEST_TMP \
	PWM_FAN_TEST_QMANAGER=$TEST_TMP/qmanager.json \
	PWM_FAN_TEST_SLEEP_COUNT=$TEST_TMP/sampler-sleep-count \
	PWM_FAN_CAPTURED_SAMPLE=$TEST_TMP/published.sample \
	"$CONTROLLER" modem-run -c "$modem_config"
assert_eq "$(cat "$TEST_TMP/published.sample")" 'qmanager_http@192.168.224.1|0|60000' \
	'modem sampler publishes source, monotonic time, and temperature atomically'
[ "$(stat -c %a "$TEST_TMP/published.sample")" = 600 ] || fail 'published modem sample is not private'
pass 'modem sampler runs independently from fan control'

cat > "$bin/controller-sleep" <<'EOF'
#!/bin/sh
cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
kill -TERM "$PPID"
EOF
chmod +x "$bin/controller-sleep"
printf '50000\n' > "$sys/class/thermal/thermal_zone0/temp"
printf '1\n' > "$TEST_TMP/uptime"
cp "$TEST_TMP/published.sample" "$run/modem.sample"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_MODEM_SAMPLE_FILE=$run/modem.sample \
	PWM_FAN_LOGGER=$bin/logger PWM_FAN_SLEEP=$bin/controller-sleep \
	PWM_FAN_TEST_LOG=$TEST_TMP/modem-events \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/fresh-status.json \
	"$CONTROLLER" run -c "$modem_config"
python3 - "$TEST_TMP/fresh-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['modem_temperature_millic'] == 60000
assert status['selected_temperature_millic'] == 60000
assert status['selected_temperature_source'] == 'modem'
assert status['requested_pwm'] > 0
PY
pass 'fresh hotter modem data controls Auto without a controller request'

printf '31\n' > "$TEST_TMP/uptime"
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_STATUS_FILE=$run/status.json PWM_FAN_MODEM_SAMPLE_FILE=$run/modem.sample \
	PWM_FAN_LOGGER=$bin/logger PWM_FAN_SLEEP=$bin/controller-sleep \
	PWM_FAN_TEST_LOG=$TEST_TMP/modem-events \
	PWM_FAN_CAPTURED_STATUS=$TEST_TMP/stale-status.json \
	"$CONTROLLER" run -c "$modem_config"
python3 - "$TEST_TMP/stale-status.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert status['modem_temperature_millic'] is None
assert status['selected_temperature_millic'] == 50000
assert status['selected_temperature_source'] == 'cpu'
assert status['requested_pwm'] == 0
assert status['effective_pwm'] != 255
PY
pass 'expired modem data falls back to CPU without fail-safe output'

disabled=$TEST_TMP/disabled-modem.conf
sed -e 's/^mode=.*/mode=disabled/' \
	-e 's/^modem_source=.*/modem_source=qmanager_http/' "$DEFAULT_CONFIG" > "$disabled"
PWM_FAN_RUN_DIR=$run PWM_FAN_UPTIME_FILE=$TEST_TMP/uptime \
	PWM_FAN_MODEM_SAMPLE_FILE=$run/disabled.sample \
	"$CONTROLLER" modem-run -c "$disabled"
[ ! -e "$run/disabled.sample" ] || fail 'Disabled mode started modem sampling'
pass 'Disabled mode does not run modem sampling'
