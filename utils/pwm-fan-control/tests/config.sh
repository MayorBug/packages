#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

disabled=$TEST_TMP/disabled.conf
sed 's/^mode=.*/mode=disabled/' "$DEFAULT_CONFIG" > "$disabled"
"$CONTROLLER" validate -c "$disabled" --json >/dev/null
pass 'canonical disabled configuration validates without hardware'

minimal=$TEST_TMP/minimal.conf
printf 'mode=disabled\n' > "$minimal"
"$CONTROLLER" validate -c "$minimal" --json >/dev/null
pass 'missing known settings inherit controller defaults'

duplicate=$TEST_TMP/duplicate.conf
cp "$disabled" "$duplicate"
printf 'mode=curve\n' >> "$duplicate"
expect_failure "$CONTROLLER" validate -c "$duplicate" --json
pass 'duplicate keys are rejected'

unknown=$TEST_TMP/unknown.conf
cp "$disabled" "$unknown"
printf 'mystery=1\n' >> "$unknown"
expect_failure "$CONTROLLER" validate -c "$unknown" --json
pass 'unknown keys are rejected'

duration=$TEST_TMP/filter-duration.conf
for seconds in 5 10 15; do
	sed "s/^temperature_filter_duration_s=.*/temperature_filter_duration_s=$seconds/" \
		"$disabled" > "$duration"
	"$CONTROLLER" validate -c "$duration" --json >/dev/null
done
pass 'all supported median filter durations validate'

sed 's/^temperature_filter_duration_s=.*/temperature_filter_duration_s=6/' "$disabled" > "$duration"
expect_failure "$CONTROLLER" validate -c "$duration" --json
pass 'unsupported median filter duration is rejected'

wifi=$TEST_TMP/wifi-source.conf
sed 's/^wifi_source=.*/wifi_source=nvme/' "$disabled" > "$wifi"
expect_failure "$CONTROLLER" validate -c "$wifi" --json
sed 's/^wifi_source=.*/wifi_source=mt7915_phy0x/' "$disabled" > "$wifi"
expect_failure "$CONTROLLER" validate -c "$wifi" --json
pass 'unsupported exact Wi-Fi hwmon names are rejected'

obsolete=$TEST_TMP/obsolete-samples.conf
cp "$disabled" "$obsolete"
printf 'temperature_samples=5\n' >> "$obsolete"
expect_failure "$CONTROLLER" validate -c "$obsolete" --json
pass 'obsolete sample count is rejected after the version 2 upgrade'

syntax=$TEST_TMP/syntax.conf
sed 's/^hwmon_name=.*/hwmon_name=$(uname)/' "$disabled" > "$syntax"
expect_failure "$CONTROLLER" validate -c "$syntax" --json
pass 'shell syntax is rejected as data'
