#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

. "$PACKAGE_DIR/files/usr/lib/pwm-fan/common.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/config.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/hardware.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/policy.sh"
. "$PACKAGE_DIR/files/usr/lib/pwm-fan/api.sh"

sys=$TEST_TMP/sys
mkdir -p "$sys/class/hwmon/hwmon0" "$sys/class/hwmon/hwmon3" \
	"$sys/class/hwmon/hwmon4"
printf 'mdio_bus:06\n' > "$sys/class/hwmon/hwmon0/name"
printf '41000\n' > "$sys/class/hwmon/hwmon0/temp1_input"
printf 'mt7915_phy0\n' > "$sys/class/hwmon/hwmon3/name"
printf '37000\n' > "$sys/class/hwmon/hwmon3/temp1_input"
printf 'mt7915_phy1\n' > "$sys/class/hwmon/hwmon4/name"
printf '76000\n' > "$sys/class/hwmon/hwmon4/temp1_input"
PWM_FAN_SYS_ROOT=$sys

config_defaults
hardware_state_reset
CFG_WIFI_SOURCE=off
hardware_wifi_discover
assert_eq "$HW_WIFI_STATE" disabled 'disabled Wi-Fi skips temperature discovery'

CFG_WIFI_SOURCE=auto
hardware_wifi_discover
hardware_wifi_read
assert_eq "$HW_WIFI_TEMPERATURE_SOURCE" mt7915_phy1 'automatic Wi-Fi selects hottest radio'
assert_eq "$HW_WIFI_TEMPERATURE_MILLIC" 76000 'automatic Wi-Fi publishes hottest temperature'
case "$HW_WIFI_READINGS" in *mdio_bus*) fail 'automatic Wi-Fi included Ethernet PHY temperature' ;; esac
wifi_probe_json > "$TEST_TMP/wifi-probe.json"
python3 - "$TEST_TMP/wifi-probe.json" <<'PY'
import json, pathlib, sys
sensors = json.loads(pathlib.Path(sys.argv[1]).read_text())
selected = [sensor for sensor in sensors if sensor['selected']]
assert len(selected) == 1
assert selected[0]['name'] == 'mt7915_phy1'
PY
pass 'automatic probe marks only the hottest radio selected'
pass 'automatic Wi-Fi ignores non-Wi-Fi hwmon temperatures'

CFG_WIFI_SOURCE=mt7915_phy0
hardware_wifi_discover
hardware_wifi_read
assert_eq "$HW_WIFI_TEMPERATURE_SOURCE" mt7915_phy0 'exact Wi-Fi source uses stable hwmon name'
assert_eq "$HW_WIFI_TEMPERATURE_MILLIC" 37000 'exact Wi-Fi source reads selected radio'
printf 'mt7915_phy1\n' > "$sys/class/hwmon/hwmon3/name"
if hardware_wifi_read; then
	fail 'cached Wi-Fi path accepted a changed hwmon identity'
fi
assert_eq "$HW_WIFI_STATE" unavailable 'changed cached Wi-Fi identity becomes unavailable'
printf 'mt7915_phy0\n' > "$sys/class/hwmon/hwmon3/name"
pass 'cached Wi-Fi paths revalidate stable identity before sampling'

mv "$sys/class/hwmon/hwmon3" "$sys/class/hwmon/hwmon9"
hardware_wifi_discover
hardware_wifi_read
assert_eq "$HW_WIFI_TEMPERATURE_SOURCE" mt7915_phy0 'exact Wi-Fi survives hwmon index changes'
pass 'Wi-Fi identity does not depend on hwmon number'

CFG_WIFI_SOURCE=auto
printf '37000\n' > "$sys/class/hwmon/hwmon4/temp1_input"
hardware_wifi_discover
hardware_wifi_read
assert_eq "$HW_WIFI_TEMPERATURE_SOURCE" mt7915_phy0 'equal Wi-Fi temperatures use canonical name order'

mkdir -p "$sys/class/hwmon/hwmon8"
printf 'mt7915_phy0\n' > "$sys/class/hwmon/hwmon8/name"
printf '90000\n' > "$sys/class/hwmon/hwmon8/temp1_input"
CFG_WIFI_SOURCE=mt7915_phy0
if hardware_wifi_discover; then
	fail 'duplicate exact Wi-Fi source was accepted'
fi
assert_eq "$HW_WIFI_STATE" ambiguous 'duplicate stable Wi-Fi identity is ambiguous'
rm -f "$sys/class/hwmon/hwmon8/temp1_input"
CFG_WIFI_SOURCE=auto
if hardware_wifi_discover; then
	fail 'automatic Wi-Fi accepted duplicate identity with one unreadable sensor'
fi
assert_eq "$HW_WIFI_STATE" ambiguous 'automatic Wi-Fi counts unreadable duplicate identities'
pass 'duplicate Wi-Fi names are never guessed'

rm -rf "$sys/class/hwmon/hwmon8"
CFG_WIFI_SOURCE=mt7915_phy0
printf 'invalid\n' > "$sys/class/hwmon/hwmon9/temp1_input"
hardware_wifi_discover
if hardware_wifi_read; then
	fail 'malformed Wi-Fi temperature was accepted'
fi
assert_eq "$HW_WIFI_STATE" unavailable 'malformed Wi-Fi temperature is unavailable'
pass 'invalid Wi-Fi telemetry is excluded'

mkdir -p "$sys/class/hwmon/hwmon7"
printf 'nvme\n' > "$sys/class/hwmon/hwmon7/name"
printf '99000\n' > "$sys/class/hwmon/hwmon7/temp1_input"
CFG_WIFI_SOURCE=nvme
if hardware_wifi_discover; then
	fail 'non-Wi-Fi exact hwmon source was accepted'
fi
assert_eq "$HW_WIFI_STATE" unavailable 'unsupported exact hwmon source is unavailable'
pass 'exact Wi-Fi mode rejects non-Wi-Fi hwmon devices'

policy_state_reset
HW_WIFI_SENSORS='mt7915_phy0|/old/temp1_input'
HW_WIFI_READINGS='mt7915_phy0|37000'
HW_WIFI_TEMPERATURE_MILLIC=37000
HW_WIFI_TEMPERATURE_SOURCE=mt7915_phy0
HW_WIFI_STATE=available
hardware_discover()
{
	HW_WIFI_SENSORS='mt7915_phy1|/new/temp1_input'
	HW_WIFI_READINGS='mt7915_phy1|76000'
	HW_WIFI_TEMPERATURE_MILLIC=76000
	HW_WIFI_TEMPERATURE_SOURCE=mt7915_phy1
	HW_WIFI_STATE=available
	return 0
}
policy_build() { return 1; }
if hardware_policy_refresh; then
	fail 'failed policy refresh unexpectedly succeeded'
fi
assert_eq "$HW_WIFI_SENSORS" 'mt7915_phy0|/old/temp1_input' 'failed policy refresh restores Wi-Fi paths'
assert_eq "$HW_WIFI_READINGS" 'mt7915_phy0|37000' 'failed policy refresh restores Wi-Fi readings'
assert_eq "$HW_WIFI_TEMPERATURE_SOURCE" mt7915_phy0 'failed policy refresh restores Wi-Fi source'
pass 'failed policy refresh restores complete Wi-Fi discovery state'
