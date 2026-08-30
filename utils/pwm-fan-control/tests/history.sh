#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

. "$PWM_FAN_LIB_DIR/common.sh"
. "$PWM_FAN_LIB_DIR/config.sh"
. "$PWM_FAN_LIB_DIR/control.sh"
. "$PWM_FAN_LIB_DIR/runtime.sh"
read_uptime() { PWM_FAN_UPTIME_FILE=$PROC_UPTIME monotonic_now; }
log_event() { :; }
config_defaults
activate_control_config

RUN_DIR=$TEST_TMP/run
STATUS_FILE=$RUN_DIR/status.json
HISTORY_FILE=$RUN_DIR/history.tsv
HISTORY_LOCK=$RUN_DIR/history.lock
PROC_UPTIME=$TEST_TMP/uptime
mkdir -p "$RUN_DIR"
printf '60\n' > "$PROC_UPTIME"

START_UPTIME=0
POLICY_STATE=1
POLICY_FLOOR_PWM=128
FANWATCH_STATE=running
HW_TACH_STATE=running
MODEM_STATE=available
HISTORY_STATE=healthy
HISTORY_NEXT_UPTIME=60
snapshot_set running none 50000 52000 51000 52000 100 128 128 1400
history_record_if_due 60
assert_eq "$(wc -l < "$HISTORY_FILE")" 1 'history appends one due snapshot'
assert_eq "$(cut -f 3-10 "$HISTORY_FILE")" \
	'50000	52000	100	128	128	128	1400	running' \
	'history reuses raw values from the current snapshot'
history_record_if_due 61
assert_eq "$(wc -l < "$HISTORY_FILE")" 1 'history does not append before the next deadline'

printf 'malformed\n' >> "$HISTORY_FILE"
printf '120\n' > "$PROC_UPTIME"
snapshot_set running none 51000 53000 52000 53000 110 128 128 1450
history_record_if_due 120
assert_eq "$(wc -l < "$HISTORY_FILE")" 2 'history pruning removes malformed records'

awk 'BEGIN { for (i=1; i<=1440; i++) print i "\tkernel\t50000\tnull\tnull\t128\tnull\t128\t1200\trunning" }' \
	> "$HISTORY_FILE"
HISTORY_NEXT_UPTIME=180
printf '180\n' > "$PROC_UPTIME"
snapshot_set running none 52000 null null null null null 128 1500
history_record_if_due 180
assert_eq "$(wc -l < "$HISTORY_FILE")" 1440 'history retains the newest 1440 valid records'
assert_eq "$(tail -n 1 "$HISTORY_FILE" | cut -f 3)" 52000 \
	'history retention keeps the newest snapshot'

history_clear
assert_eq "$(wc -c < "$HISTORY_FILE")" 0 'clear-history atomically empties router history'

EVENTS=$TEST_TMP/history-events
log_event() { printf '%s\n' "$2" >> "$EVENTS"; }
HISTORY_FILE=$RUN_DIR/history-directory
mkdir "$HISTORY_FILE"
HISTORY_NEXT_UPTIME=240
snapshot_set running none 53000 null 53000 null 120 128 128 1500
expect_failure history_record_if_due 240
expect_failure history_record_if_due 300
assert_eq "$HISTORY_STATE" error 'history failure is isolated in history state'
assert_eq "$(grep -c '^history_write_failed$' "$EVENTS")" 1 \
	'repeated history failure logs one transition'
rmdir "$HISTORY_FILE"
history_record_if_due 360
assert_eq "$HISTORY_STATE" healthy 'history storage recovers independently'
assert_eq "$(grep -c '^history_recovered$' "$EVENTS")" 1 \
	'history recovery logs one transition'
mkdir "$HISTORY_LOCK"
expect_failure history_clear
rmdir "$HISTORY_LOCK"
pass 'append and clear share a bounded nonblocking history lock'

mkdir "$HISTORY_LOCK"
printf '99999999\n' > "$HISTORY_LOCK/owner"
history_clear
assert_eq "$(wc -c < "$HISTORY_FILE")" 0 'stale owner lock is recovered safely'
pass 'history lock recovers after an interrupted owner exits'

pass 'router-side history contract'
