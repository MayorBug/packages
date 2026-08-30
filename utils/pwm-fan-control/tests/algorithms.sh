#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

. "$PWM_FAN_LIB_DIR/common.sh"
. "$PWM_FAN_LIB_DIR/config.sh"
. "$PWM_FAN_LIB_DIR/control.sh"
PROC_UPTIME=$TEST_TMP/uptime
read_uptime() { PWM_FAN_UPTIME_FILE=$PROC_UPTIME monotonic_now; }
validate_config()
{
	config_validate || return 1
	activate_control_config
}
config_defaults
validate_config
assert_eq "$PID_RELEASE_MILLI" 53000 'Auto uses the fixed two-degree idle margin'

CFG_TEMPERATURE_FILTER=median
CFG_TEMPERATURE_FILTER_DURATION_S=10
FILTER_BUFFER=
temperature_filter_update 0 50000
temperature_filter_update 4 70000
temperature_filter_update 8 60000
median=$FILTER_OUTPUT_MILLIC
assert_eq "$median" 60000 'median filter selects middle sample'

temperature_filter_update 20 80000
assert_eq "$FILTER_OUTPUT_MILLIC" 80000 'median filter discards readings outside its duration'

for duration in 5 10 15; do
	CFG_TEMPERATURE_FILTER_DURATION_S=$duration
	FILTER_BUFFER=
	temperature_filter_update 0 10000
	temperature_filter_update "$duration" 20000
	assert_eq "$FILTER_OUTPUT_MILLIC" 10000 "${duration}-second filter retains its boundary reading"
	temperature_filter_update $((duration + 1)) 30000
	assert_eq "$FILTER_OUTPUT_MILLIC" 20000 "${duration}-second filter expires its old reading"
done
pass 'all filter durations use timestamped median windows'

CURVE_HYSTERESIS_MILLI=2000
curve_cases=0
while IFS='|' read -r style points temperature expected; do
	case $style in ''|'#'*) continue ;; esac
	CFG_CURVE_POINTS=$points
	validate_config
	LAST_CURVE_PWM=
	LAST_CURVE_THRESHOLD=0
	case $style in
		step) calculate_step_curve "$temperature" ;;
		smooth) calculate_smooth_curve "$temperature" ;;
		*) fail "unknown shared curve style: $style" ;;
	esac
	expected_pwm=$(percent_to_pwm "$expected")
	difference=$((REQUESTED_PWM - expected_pwm)); [ "$difference" -ge 0 ] || difference=$((-difference))
	[ "$difference" -le 1 ] ||
		fail "$style curve at $temperature expected raw $expected_pwm, got $REQUESTED_PWM"
	curve_cases=$((curve_cases + 1))
done < "$TEST_DIR/curve_cases.tsv"
pass "$curve_cases shared curve results match the shell controller"

CFG_CURVE_POINTS='40:0,50:20,65:100'
validate_config
previous=-1
temperature=40000
while [ "$temperature" -le 65000 ]; do
	calculate_smooth_curve "$temperature"
	[ "$REQUESTED_PWM" -ge "$previous" ] ||
		fail 'smooth curve decreased between configured points'
	[ "$REQUESTED_PWM" -ge 0 ] && [ "$REQUESTED_PWM" -le 255 ] ||
		fail 'smooth curve exceeded configured output bounds'
	previous=$REQUESTED_PWM
	temperature=$((temperature + 500))
done
pass 'dense smooth curve remains monotone and bounded'

assert_eq "$(percent_to_pwm 0)" 0 'zero percent maps to zero PWM'
assert_eq "$(percent_to_pwm 100)" 255 'full percent maps to full PWM'

mkdir -p "$TEST_TMP/hwmon"
printf '84\n' > "$TEST_TMP/hwmon/pwm1"
printf '10\n' > "$TEST_TMP/uptime"
HWMON=$TEST_TMP/hwmon
PROC_UPTIME=$TEST_TMP/uptime
KERNEL_PWM=0
PID_TARGET_MILLI=55000
PID_RELEASE_MILLI=53000
PID_KP_FIXED=60000
PID_KI_FIXED=167
PID_KD_FIXED=0
PID_LIMIT_FIXED=600000
CFG_CONTROL_INTERVAL_S=2
reset_control_state
calculate_pid 52000
assert_eq "$REQUESTED_PWM" 0 \
	'Auto stays idle below the release temperature'
assert_eq "$PID_COOLING_ACTIVE" 0 'Auto is idle below the release temperature'

calculate_pid 54000
assert_eq "$REQUESTED_PWM" 0 'idle Auto stays idle between release and target'
assert_eq "$PID_COOLING_ACTIVE" 0 'Auto does not start inside the idle deadband'

printf '0\n' > "$TEST_TMP/hwmon/pwm1"
printf '20\n' > "$TEST_TMP/uptime"
reset_control_state
calculate_pid 60000
[ "$REQUESTED_PWM" -gt 0 ] || fail 'Auto did not cool immediately above target'
pass 'Auto requests positive output immediately above target'

PID_I_FIXED=150000
PID_LAST_TEMP=56000
PID_LAST_UPTIME=20
printf '22\n' > "$TEST_TMP/uptime"
calculate_pid 54000
[ "$REQUESTED_PWM" -gt 0 ] || fail 'Auto cut output inside the idle deadband'
assert_eq "$PID_COOLING_ACTIVE" 1 'Auto remains active inside the idle deadband'
[ "$PID_I_FIXED" -lt 150000 ] || fail 'PID integral did not decrease inside the idle deadband'
pass 'Auto output decreases below target inside the idle deadband'

printf '24\n' > "$TEST_TMP/uptime"
PID_I_FIXED=150000
PID_LAST_TEMP=54000
PID_LAST_UPTIME=22
calculate_pid 53000
assert_eq "$REQUESTED_PWM" 0 'Auto stops output at the fixed release temperature'
assert_eq "$PID_COOLING_ACTIVE" 0 'Auto enters idle at the release temperature'
assert_eq "$PID_I_FIXED" 0 'entering PID idle clears the integral'
assert_eq "$PID_LAST_TEMP" '' 'entering PID idle clears derivative temperature state'
assert_eq "$PID_LAST_UPTIME" '' 'entering PID idle clears derivative time state'
printf '26\n' > "$TEST_TMP/uptime"
calculate_pid 54000
assert_eq "$REQUESTED_PWM" 0 'idle Auto remains idle inside the deadband'

printf '28\n' > "$TEST_TMP/uptime"
calculate_pid 56000
assert_eq "$PID_COOLING_ACTIVE" 1 'Auto leaves idle above target'
[ "$REQUESTED_PWM" -gt 0 ] || fail 'Auto did not request output after leaving idle'
pass 'Auto starts PID calculation above target'

PID_KP_FIXED=0
PID_KI_FIXED=0
PID_KD_FIXED=100000
printf '30\n' > "$TEST_TMP/uptime"
reset_control_state
calculate_pid 56000
printf '32\n' > "$TEST_TMP/uptime"
calculate_pid 58000
[ "$REQUESTED_PWM" -gt 0 ] || fail 'rising temperature produced no derivative cooling'
pass 'rising temperature adds positive derivative output'

PID_I_FIXED=123456
PID_COOLING_ACTIVE=1
PID_LAST_TEMP=60000
PID_LAST_UPTIME=32
reset_control_state
assert_eq "$PID_I_FIXED" 0 'entering Auto resets accumulated integral state'
assert_eq "$PID_COOLING_ACTIVE" 0 'entering Auto resets PID idle state'
assert_eq "$PID_LAST_UPTIME" '' 'entering Auto resets prior PID timing state'

PID_I_FIXED=200000
PID_LAST_TEMP=60000
PID_LAST_UPTIME=1
printf '20\n' > "$TEST_TMP/uptime"
calculate_pid 60000
assert_eq "$PID_I_FIXED" 0 'excessive sample gap resets PID integral state'

PID_KP_FIXED=0
PID_KI_FIXED=1000
PID_KD_FIXED=0
PID_LIMIT_FIXED=600000
PID_I_FIXED=599000
PID_LAST_TEMP=60000
PID_LAST_UPTIME=10
printf '12\n' > "$TEST_TMP/uptime"
calculate_pid 60000
assert_eq "$PID_I_FIXED" 600000 'PID integral is capped at its configured limit'

PID_KP_FIXED=200000
PID_I_FIXED=125000
PID_LAST_TEMP=60000
PID_LAST_UPTIME=12
printf '14\n' > "$TEST_TMP/uptime"
calculate_pid 60000
assert_eq "$PID_I_FIXED" 125000 \
	'PID integral freezes while proportional output is saturated'

printf '16\n' > "$TEST_TMP/uptime"
calculate_pid 54000
assert_eq "$REQUESTED_PWM" 0 'Auto requests zero while integral unwinds below target'
assert_eq "$PID_I_FIXED" 123000 'negative error naturally unwinds stored PID integral'
PID_I_FIXED=1000
PID_LAST_TEMP=54000
PID_LAST_UPTIME=16
printf '18\n' > "$TEST_TMP/uptime"
calculate_pid 54000
assert_eq "$PID_I_FIXED" 0 'PID integral stops unwinding at zero'

FILTER_BUFFER='49000 50000'
PID_I_FIXED=120000
PID_LAST_TEMP=56000
PID_LAST_UPTIME=18
LAST_CURVE_PWM=128
LAST_CURVE_THRESHOLD=55000
temperature_filter_reset
assert_eq "$FILTER_BUFFER" '' 'filter reset clears only filter samples'
assert_eq "$PID_I_FIXED" 120000 'filter reset preserves PID state'
assert_eq "$LAST_CURVE_PWM" 128 'filter reset preserves Curve state'

FILTER_BUFFER='50000'
pid_reset
assert_eq "$PID_I_FIXED" 0 'PID reset clears integral state'
assert_eq "$PID_LAST_TEMP" '' 'PID reset clears derivative temperature'
assert_eq "$PID_LAST_UPTIME" '' 'PID reset clears derivative time'
assert_eq "$FILTER_BUFFER" 50000 'PID reset preserves filter samples'
assert_eq "$LAST_CURVE_PWM" 128 'PID reset preserves Curve state'

PID_I_FIXED=100000
curve_reset
assert_eq "$LAST_CURVE_PWM" '' 'Curve reset clears previous output'
assert_eq "$LAST_CURVE_THRESHOLD" 0 'Curve reset clears hysteresis threshold'
assert_eq "$PID_I_FIXED" 100000 'Curve reset preserves PID state'
assert_eq "$FILTER_BUFFER" 50000 'Curve reset preserves filter samples'
