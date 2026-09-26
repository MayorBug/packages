#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

. "$PACKAGE_DIR/files/usr/lib/pwm-fan/common.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/config.sh"
before=$(trap)
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/hardware.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/policy.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/modem.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/fan_watch.sh"
after=$(trap)
assert_eq "$after" "$before" 'sourcing hardware libraries installs no traps'

be32()
{
	local value=$1 a b c d
	a=$((value / 16777216 % 256)); b=$((value / 65536 % 256))
	c=$((value / 256 % 256)); d=$((value % 256))
	printf '%b%b%b%b' "\\$(printf '%03o' "$a")" "\\$(printf '%03o' "$b")" \
		"\\$(printf '%03o' "$c")" "\\$(printf '%03o' "$d")"
}

sys=$TEST_TMP/sys
fan_node=$sys/firmware/devicetree/base/fan
thermal_node=$sys/firmware/devicetree/base/thermal-zones/cpu-thermal
device=$sys/devices/pwmfan
hwmon=$sys/class/hwmon/hwmon0
cooling=$sys/class/thermal/cooling_device0
zone=$sys/class/thermal/thermal_zone0
mkdir -p "$fan_node" "$thermal_node/trips/trip0" "$thermal_node/trips/trip1" \
	"$thermal_node/cooling-maps/map0" "$thermal_node/cooling-maps/map1" \
	"$device" "$hwmon" "$cooling" "$zone"
ln -s "$device" "$hwmon/device"
ln -s "$fan_node" "$device/of_node"
ln -s "$device" "$cooling/device"
printf 'pwmfan\n' > "$hwmon/name"
printf '0\n' > "$hwmon/pwm1"
printf '1200\n' > "$hwmon/fan1_input"
printf 'pwm-fan\n' > "$cooling/type"
printf '2\n' > "$cooling/max_state"
printf 'cpu-thermal\n' > "$zone/type"
printf '59000\n' > "$zone/temp"
{ be32 0; be32 128; be32 255; } > "$fan_node/cooling-levels"
be32 1 > "$fan_node/phandle"
be32 10 > "$thermal_node/trips/trip0/phandle"
be32 60000 > "$thermal_node/trips/trip0/temperature"
be32 2000 > "$thermal_node/trips/trip0/hysteresis"
be32 20 > "$thermal_node/trips/trip1/phandle"
be32 80000 > "$thermal_node/trips/trip1/temperature"
be32 3000 > "$thermal_node/trips/trip1/hysteresis"
{ be32 1; be32 1; be32 1; } > "$thermal_node/cooling-maps/map0/cooling-device"
be32 10 > "$thermal_node/cooling-maps/map0/trip"
{ be32 1; be32 2; be32 2; } > "$thermal_node/cooling-maps/map1/cooling-device"
be32 20 > "$thermal_node/cooling-maps/map1/trip"

config_defaults
hardware_state_reset
policy_state_reset
PWM_FAN_SYS_ROOT=$sys
hardware_discover
assert_eq "$HW_HWMON" "$hwmon" 'unique PWM hwmon is discovered'
assert_eq "$HW_THERMAL" "$zone" 'unique thermal zone is discovered'
assert_eq "$HW_COOLING" "$cooling" 'matching cooling device is discovered'

policy_build
assert_eq "$POLICY_LEVELS" '0 128 255' 'raw DTS cooling levels are preserved'
assert_eq "$POLICY_POINTS" '60000:2000:58000:1:128
80000:3000:77000:2:255' 'multi-point DTS policy includes trip, release, state and raw PWM'

probe_before=$(cat "$hwmon/pwm1")
PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$TEST_TMP/probe-run \
	PWM_FAN_STATUS_FILE=$TEST_TMP/probe-run/status.json \
	PWM_FAN_HISTORY_FILE=$TEST_TMP/probe-run/history.tsv \
	"$CONTROLLER" probe -c "$DEFAULT_CONFIG" --json > "$TEST_TMP/probe.json"
python3 - "$TEST_TMP/probe.json" <<'PY'
import json, pathlib, sys
p = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert p['valid'] is True and p['applicable'] is True
assert p['hardware']['tachometer_available'] is True
assert p['hardware']['pwm_readable'] is True
assert [point['pwm'] for point in p['kernel_policy']['points']] == [128, 255]
assert [point['trip_temperature_millic'] for point in p['kernel_policy']['points']] == [60000, 80000]
PY
assert_eq "$(cat "$hwmon/pwm1")" "$probe_before" 'read-only probe does not write PWM'
[ ! -e "$TEST_TMP/probe-run" ] || fail 'probe created runtime state or cache'
pass 'read-only probe creates no status, history, cache, or service state'
pass 'probe publishes the complete normalized DTS policy'

# Real device trees do not guarantee cooling-map directory order. The WS1610
# exposes its fan maps as 115C, 60C, 85C and BusyBox sort must normalize them.
mkdir -p "$thermal_node/trips/trip2" "$thermal_node/cooling-maps/map2"
{ be32 0; be32 128; be32 192; be32 255; } > "$fan_node/cooling-levels"
printf '3\n' > "$cooling/max_state"
be32 115000 > "$thermal_node/trips/trip0/temperature"
be32 60000 > "$thermal_node/trips/trip1/temperature"
be32 30 > "$thermal_node/trips/trip2/phandle"
be32 85000 > "$thermal_node/trips/trip2/temperature"
be32 2000 > "$thermal_node/trips/trip2/hysteresis"
{ be32 1; be32 3; be32 3; } > "$thermal_node/cooling-maps/map0/cooling-device"
be32 10 > "$thermal_node/cooling-maps/map0/trip"
{ be32 1; be32 1; be32 1; } > "$thermal_node/cooling-maps/map1/cooling-device"
be32 20 > "$thermal_node/cooling-maps/map1/trip"
{ be32 1; be32 2; be32 2; } > "$thermal_node/cooling-maps/map2/cooling-device"
be32 30 > "$thermal_node/cooling-maps/map2/trip"
policy_build
assert_eq "$POLICY_POINTS" '60000:3000:57000:1:128
85000:2000:83000:2:192
115000:2000:113000:3:255' \
	'unordered WS1610 cooling maps are normalized by temperature'

rm -rf "$thermal_node/trips/trip2" "$thermal_node/cooling-maps/map2"
{ be32 0; be32 128; be32 255; } > "$fan_node/cooling-levels"
printf '2\n' > "$cooling/max_state"
be32 60000 > "$thermal_node/trips/trip0/temperature"
be32 80000 > "$thermal_node/trips/trip1/temperature"
{ be32 1; be32 1; be32 1; } > "$thermal_node/cooling-maps/map0/cooling-device"
be32 10 > "$thermal_node/cooling-maps/map0/trip"
{ be32 1; be32 2; be32 2; } > "$thermal_node/cooling-maps/map1/cooling-device"
be32 20 > "$thermal_node/cooling-maps/map1/trip"
policy_build

# Mixed electrical polarity cannot be normalized safely.
{ be32 0; be32 255; be32 128; } > "$fan_node/cooling-levels"
expect_failure policy_build
pass 'mixed DTS PWM policy is rejected'
invalid_probe_before=$(cat "$hwmon/pwm1")
if PWM_FAN_SYS_ROOT=$sys PWM_FAN_RUN_DIR=$TEST_TMP/invalid-probe-run \
	PWM_FAN_STATUS_FILE=$TEST_TMP/invalid-probe-run/status.json \
	"$CONTROLLER" probe -c "$DEFAULT_CONFIG" --json > "$TEST_TMP/invalid-probe.json"; then
	fail 'invalid policy probe unexpectedly reported userspace control applicable'
fi
python3 - "$TEST_TMP/invalid-probe.json" "$invalid_probe_before" <<'PY'
import json, pathlib, sys
probe = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected_pwm = int(sys.argv[2])
assert probe['valid'] is True
assert probe['applicable'] is False
assert probe['observation_available'] is True
assert probe['diagnostics'][0]['code'] == 'kernel_policy_invalid'
assert probe['hardware']['actual_pwm'] == expected_pwm
assert probe['hardware']['cpu_temperature_millic'] == 59000
assert probe['kernel_policy']['available'] is False
assert probe['kernel_policy']['direction'] is None
assert probe['kernel_policy']['strongest_pwm'] is None
PY
assert_eq "$(cat "$hwmon/pwm1")" "$invalid_probe_before" \
	'invalid policy probe observes hardware without writing PWM'

# BPI-R3-style PWM is electrically inverted: lower raw values mean stronger cooling.
{ be32 255; be32 40; be32 0; } > "$fan_node/cooling-levels"
policy_build
assert_eq "$POLICY_DIRECTION" descending 'inverted DTS PWM policy is detected'
assert_eq "$POLICY_FULL_PWM" 0 'inverted policy derives strongest raw PWM from maximum state'
assert_eq "$POLICY_POINTS" '60000:2000:58000:1:40
80000:3000:77000:2:0' 'inverted policy preserves raw PWM points in cooling-state order'
policy_floor_reset
policy_floor_update 81000
assert_eq "$POLICY_FLOOR_PWM" 0 'inverted policy floor uses maximum cooling raw PWM'
assert_eq "$POLICY_FLOOR_DEMAND" 255 'inverted policy floor exposes normalized cooling demand'
assert_eq "$(policy_demand_to_pwm 128)" 127 'normalized cooling demand converts to inverted raw PWM'
policy_handoff 81000
assert_eq "$(cat "$hwmon/pwm1")" 0 'inverted policy handoff writes maximum cooling raw PWM'

{ be32 0; be32 128; be32 255; } > "$fan_node/cooling-levels"
policy_build

mkdir -p "$thermal_node/cooling-maps/map2"
{ be32 1; be32 2; be32 2; } > "$thermal_node/cooling-maps/map2/cooling-device"
be32 10 > "$thermal_node/cooling-maps/map2/trip"
policy_build
assert_eq "$POLICY_POINTS" '60000:2000:58000:2:255' \
	'duplicate trips choose the highest deterministic cooling state'
rm -rf "$thermal_node/cooling-maps/map2"
policy_build

policy_floor_reset
policy_floor_update 59000
assert_eq "$POLICY_STATE" 1 'startup inside hysteresis band chooses conservative state'
assert_eq "$POLICY_FLOOR_PWM" 128 'startup floor uses exact raw cooling level'
policy_floor_update 81000
assert_eq "$POLICY_STATE" 2 'heating crosses the higher trip'
policy_floor_update 78000
assert_eq "$POLICY_STATE" 2 'cooling holds state above release temperature'
policy_floor_update 76000
assert_eq "$POLICY_STATE" 1 'cooling releases state below release temperature'
printf '2\n' > "$cooling/cur_state"
policy_floor_reset
policy_floor_update 59000
assert_eq "$POLICY_FLOOR_PWM" 128 'cur_state does not affect evaluated kernel floor'

pwm_apply_verified 128
assert_eq "$(cat "$hwmon/pwm1")" 128 'verified PWM path writes raw target'
assert_eq "$HW_PWM_STATE" applied 'verified PWM path reports applied state'
policy_handoff 81000
assert_eq "$(cat "$hwmon/pwm1")" 255 'policy handoff uses loaded policy state'

telemetry_read
assert_eq "$HW_CPU_TEMPERATURE_MILLIC" 59000 'telemetry reads raw CPU temperature'
assert_eq "$HW_ACTUAL_PWM" 255 'telemetry reads actual raw PWM'
assert_eq "$HW_TACH_STATE" running 'telemetry distinguishes running tachometer'

fan_watch_reset
fan_watch_update 0 0 0 applied 0 zero
assert_eq "$FANWATCH_STATE" idle 'zero requested PWM and zero RPM is idle'
fan_watch_update 1 128 128 applied 0 zero
assert_eq "$FANWATCH_STATE" spinup 'new running output starts spin-up allowance'
fan_watch_update 6 128 128 applied 0 zero
fan_watch_update 7 128 128 applied 0 zero
fan_watch_update 8 128 128 applied 0 zero
assert_eq "$FANWATCH_STATE" fan_failed 'three zero-RPM samples latch fan failure'
fan_watch_update 9 128 128 applied 1200 running
assert_eq "$FANWATCH_STATE" running 'valid RPM recovers fan state'
fan_watch_update 10 128 64 applied 1200 running
assert_eq "$FANWATCH_STATE" pwm_not_applied 'PWM mismatch is distinct from fan failure'
fan_watch_update 11 128 '' unavailable '' unavailable
assert_eq "$FANWATCH_STATE" pwm_unavailable 'missing PWM is distinct from tachometer state'

mkdir -p "$sys/class/hwmon/hwmon1"
printf 'pwmfan\n' > "$sys/class/hwmon/hwmon1/name"
printf '0\n' > "$sys/class/hwmon/hwmon1/pwm1"
expect_failure hardware_refresh
assert_eq "$HW_HWMON" "$hwmon" 'ambiguous refresh preserves prior hardware paths'
assert_eq "$HW_DISCOVERY_ERROR" fan_ambiguous 'ambiguous refresh reports stable error'

printf '%s\n' \
	'+QTEMP: "cpuss-0","35"' \
	'+QTEMP: "cpuss-3","39"' \
	'+QTEMP: "mmw0","-273"' \
	'OK' > "$TEST_TMP/at-response"
assert_eq "$(modem_parse_quectel < "$TEST_TMP/at-response")" 39000 \
	'Quectel parser selects highest cpuss-0 through cpuss-4 reading'
sed '/^OK$/d' "$TEST_TMP/at-response" > "$TEST_TMP/at-response-no-ok"
expect_failure sh -c '. "$1"; modem_parse_quectel < "$2"' sh \
	"$PACKAGE_DIR/files/usr/lib/pwm-fan/modem.sh" "$TEST_TMP/at-response-no-ok"
pass 'Quectel parser requires a final OK response'

timeout_test() { [ "$1" = 5 ] || return 1; shift; "$@"; }
http_test()
{
	local output=
	while [ "$#" -gt 0 ]; do
		if [ "$1" = -O ]; then output=$2; shift 2; else shift; fi
	done
	[ -n "$output" ] || return 1
	cp "$TEST_TMP/qmanager.json" "$output"
}
jsonfilter_test() { printf 'ok\ntrue\n60\n'; }
printf '{"state":"ok","modem_reachable":true,"temperature":50}\n' > "$TEST_TMP/qmanager.json"
PWM_FAN_TIMEOUT=timeout_test
PWM_FAN_HTTP_CLIENT=http_test
PWM_FAN_JSONFILTER=jsonfilter_test
PWM_FAN_MODEM_TMP_DIR=$TEST_TMP
CFG_MODEM_SOURCE=qmanager_http
CFG_MODEM_INTERVAL_S=15
CFG_MODEM_HTTP_HOST=192.168.224.1
RUN_DIR=$TEST_TMP/run
MODEM_SAMPLE_FILE=$RUN_DIR/modem.sample
mkdir -p "$RUN_DIR"
modem_sample_reset
temperature=$(modem_acquire_once)
assert_eq "$temperature" 60000 'QManager sample is read in millidegrees'
modem_publish_sample 20 "$temperature"
[ "$(stat -c %a "$MODEM_SAMPLE_FILE")" = 600 ] || fail 'modem sample file is not private'
modem_sample_read 20
assert_eq "$MODEM_TEMPERATURE_MILLIC" 60000 'controller reads the atomic modem sample'
pass 'RM520N/RM551 QManager public response is accepted through a five-second transaction'
CFG_MODEM_HTTP_HOST=192.168.225.1
expect_failure modem_sample_read 21
assert_eq "$MODEM_STATE" lost 'source changes reject an old modem sample'
CFG_MODEM_HTTP_HOST=192.168.224.1
modem_sample_read 21
assert_eq "$MODEM_STATE" available 'matching fresh modem data recovers automatically'
pass 'modem sample identity follows the active source configuration'
modem_sample_read 49 || fail 'modem sample expired early'
modem_sample_read 50 || fail 'modem sample expired at its polling boundary'
expect_failure modem_sample_read 51
pass 'modem freshness expires at its monotonic deadline'
printf '{}\n' > "$TEST_TMP/qmanager.json"
jsonfilter_test() { return 1; }
expect_failure modem_acquire_once
modem_sample_read 35
assert_eq "$MODEM_STATE" available 'failed polling leaves the published fresh sample usable'
assert_eq "$MODEM_TEMPERATURE_MILLIC" 60000 'failed polling does not erase the published sample'
expect_failure modem_sample_read 51
assert_eq "$MODEM_STATE" lost 'repeated failures after expiry transition modem to lost'
assert_eq "$MODEM_TEMPERATURE_MILLIC" '' 'expired modem failure clears stale temperature'

modem_sample_reset
rm -f "$MODEM_SAMPLE_FILE"
expect_failure modem_sample_read 40
assert_eq "$MODEM_STATE" waiting 'initial modem failure remains in silent waiting state'

jsonfilter_test() { printf 'ok\ntrue\n'; }
expect_failure modem_qmanager_once
pass 'QManager response with a missing field is rejected'
jsonfilter_test() { printf 'ok\ntrue\n60\nextra\n'; }
expect_failure modem_qmanager_once
pass 'QManager response with an extra field is rejected'

dd if=/dev/zero of="$TEST_TMP/qmanager.json" bs=1024 count=65 2>/dev/null
expect_failure modem_qmanager_once
pass 'oversized QManager response is rejected'

pass 'hardware and policy foundation contract'
