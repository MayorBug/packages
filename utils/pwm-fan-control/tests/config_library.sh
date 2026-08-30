#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

. "$PACKAGE_DIR/files/usr/lib/pwm-fan/common.sh"
before=$(trap)
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/config.sh"
after=$(trap)
assert_eq "$after" "$before" 'sourcing config library installs no traps'

config_defaults
assert_eq "$(config_default pid_kp)" 0.1 'default proportional gain'
assert_eq "$(config_default pid_ki)" 0.0005 'default integral gain'
assert_eq "$(config_default pid_kd)" 0.10 'default derivative gain'
config_render > "$TEST_TMP/rendered"
cmp -s "$TEST_TMP/rendered" "$DEFAULT_CONFIG" || fail 'canonical defaults differ from shipped config'
pass 'canonical renderer matches shipped config'

cat > "$TEST_TMP/partial.conf" <<'EOF'
config_version=2
mode=curve
EOF
config_parse "$TEST_TMP/partial.conf"
config_validate
assert_eq "$CFG_MODE" curve 'present value overrides default'
assert_eq "$CFG_CONTROL_INTERVAL_S" 2 'missing key receives effective default'
printf '%s\n' "$CFG_DIAGNOSTICS" | grep -q '^warning|missing_key_defaulted|control_interval_s|' ||
	fail 'missing key warning is absent'
pass 'missing key warning retains operational config'

sed 's/^pid_kp=.*/pid_kp=invalid/' "$DEFAULT_CONFIG" > "$TEST_TMP/invalid.conf"
config_parse "$TEST_TMP/invalid.conf"
expect_failure config_validate
assert_eq "$CFG_PID_KP" invalid 'invalid present value is preserved'
printf '%s\n' "$CFG_DIAGNOSTICS" | grep -q '^error|invalid_value|pid_kp|' ||
	fail 'invalid value diagnostic is absent'
pass 'invalid present value remains visible and invalid'

cp "$DEFAULT_CONFIG" "$TEST_TMP/legacy.conf"
printf '%s\n' 'pid_hysteresis_c=9' >> "$TEST_TMP/legacy.conf"
config_parse "$TEST_TMP/legacy.conf"
config_validate
printf '%s\n' "$CFG_DIAGNOSTICS" | grep -q '^warning|obsolete_key_ignored|pid_hysteresis_c|' ||
	fail 'obsolete PID hysteresis setting is not ignored'
config_render | grep -q '^pid_hysteresis_c=' &&
	fail 'canonical configuration retained obsolete PID hysteresis'
pass 'obsolete PID hysteresis does not affect the active configuration'

cat > "$TEST_TMP/duplicate.conf" <<'EOF'
mode=kernel
mode=curve
unknown=value
EOF
expect_failure config_parse "$TEST_TMP/duplicate.conf"
printf '%s\n' "$CFG_DIAGNOSTICS" | grep -q '^error|duplicate_key|mode|2|' ||
	fail 'duplicate diagnostic is absent'
printf '%s\n' "$CFG_DIAGNOSTICS" | grep -q '^error|unknown_key|unknown|3|' ||
	fail 'unknown-key diagnostic is absent'
pass 'structural errors report line and value'

config_defaults
i=1
while [ "$i" -le 65 ]; do
	config_diag warning synthetic "key$i" "$i" value default message
	i=$((i + 1))
done
assert_eq "$(printf '%s\n' "$CFG_DIAGNOSTICS" | wc -l)" 64 \
	'configuration diagnostics are capped at 64 entries'
assert_eq "$(printf '%s\n' "$CFG_DIAGNOSTICS" | grep -c 'diagnostics_truncated')" 1 \
	'diagnostic overflow emits one truncation marker'

target=$TEST_TMP/installed.conf
PWM_FAN_CONFIG_LOCK=$TEST_TMP/config.lock
expected_kp=$(config_default pid_kp)
revision=$(config_install "$TEST_TMP/partial.conf" missing "$target")
[ -n "$revision" ] || fail 'config install returned no revision'
grep -q '^mode=curve$' "$target" || fail 'config install lost candidate mode'
grep -q "^pid_kp=$expected_kp$" "$target" || fail 'config install did not persist missing defaults'
! grep -q '^pid_hysteresis_c=' "$target" || fail 'config install retained obsolete PID hysteresis'
[ "$(stat -c %a "$target")" = 600 ] || fail 'installed config mode is not 0600'
pass 'config install is canonical and mode 0600'

before_sum=$(md5sum "$target")
if config_install "$DEFAULT_CONFIG" wrong-revision "$target" >/dev/null 2>&1; then
	fail 'revision conflict unexpectedly installed candidate'
fi
assert_eq "$(md5sum "$target")" "$before_sum" 'revision conflict preserves config'

config_defaults
CFG_MODE=curve
config_set mode manual "$target"
grep -q '^mode=manual$' "$target" || fail 'config_set did not update one canonical value'
assert_eq "$CFG_MODE" curve 'config_set does not mutate caller configuration state'
pass 'config_set uses canonical write path'

mkdir "$PWM_FAN_CONFIG_LOCK"
printf '1\n' > "$PWM_FAN_CONFIG_LOCK/created"
config_set mode curve "$target"
grep -q '^mode=curve$' "$target" || fail 'stale config lock was not recovered'
pass 'stale config lock recovery is bounded'

revision=$(config_revision "$target")
config_reset "$revision" "$target" >/dev/null
grep -q '^mode=kernel$' "$target" || fail 'config reset did not restore Kernel mode'
cmp -s "$target" "$DEFAULT_CONFIG" || fail 'config reset differs from current defaults'
pass 'config reset installs current defaults'

legacy=$TEST_TMP/version1.conf
sed -e 's/^config_version=.*/config_version=1/' \
	-e 's/^mode=.*/mode=manual/' \
	-e 's/^temperature_filter=.*/temperature_filter=none/' \
	-e '/^temperature_filter_duration_s=/c\temperature_samples=15' \
	"$DEFAULT_CONFIG" > "$legacy"
PWM_FAN_CONFIG_TMP_DIR=$TEST_TMP
config_upgrade_v1 "$legacy"
grep -q '^config_version=2$' "$legacy" || fail 'upgrade did not install format version 2'
grep -q '^mode=manual$' "$legacy" || fail 'upgrade did not preserve unrelated settings'
grep -q '^temperature_filter=median$' "$legacy" || fail 'upgrade did not reset the filter'
grep -q '^temperature_filter_duration_s=10$' "$legacy" || fail 'upgrade did not install the duration default'
! grep -q '^temperature_samples=' "$legacy" || fail 'upgrade retained the obsolete sample count'
pass 'version 1 upgrade resets only temperature filter settings'
