#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

valid_json=$TEST_TMP/valid.json
"$CONTROLLER" validate -c "$DEFAULT_CONFIG" --json > "$valid_json"
python3 - "$valid_json" <<'PY'
import json, pathlib, sys
document = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert document['valid'] is True
assert document['raw_values']['mode'] == 'kernel'
assert document['effective_values']['mode'] == 'kernel'
assert document['defaults']['mode'] == 'kernel'
assert document['defaults']['pid_kp'] == '0.1'
assert document['defaults']['pid_ki'] == '0.0005'
assert document['defaults']['pid_kd'] == '0.10'
assert document['diagnostics'] == []
PY
pass 'validate emits the complete configuration JSON contract'

candidate=$TEST_TMP/invalid.conf
sed 's/^pid_kp=.*/pid_kp=invalid/' "$DEFAULT_CONFIG" > "$candidate"
if "$CONTROLLER" validate -c "$candidate" --json > "$TEST_TMP/invalid.json"; then
	fail 'invalid configuration returned success'
fi
python3 - "$TEST_TMP/invalid.json" <<'PY'
import json, pathlib, sys
document = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert document['valid'] is False
assert document['raw_values']['pid_kp'] == 'invalid'
assert document['effective_values']['pid_kp'] is None
item = next(item for item in document['diagnostics']
            if item['code'] == 'invalid_value' and item['key'] == 'pid_kp')
assert item['severity'] == 'error'
assert item['line'] > 0
assert item['value'] == 'invalid'
assert item['default_value'] == document['defaults']['pid_kp']
assert item['message']
assert len(item['value']) <= 240 and len(item['message']) <= 240
PY
pass 'invalid present values remain visible without fake effective defaults'

for key in control_interval_s temperature_filter_duration_s modem_interval_s \
	manual_output_percent manual_timeout_min; do
	sed "s/^$key=.*/$key=abc/" "$DEFAULT_CONFIG" > "$TEST_TMP/$key.conf"
	if "$CONTROLLER" validate -c "$TEST_TMP/$key.conf" --json > "$TEST_TMP/$key.json"; then
		fail "nonnumeric $key returned success"
	fi
	python3 - "$TEST_TMP/$key.json" "$key" <<'PY'
import json, pathlib, sys
document = json.loads(pathlib.Path(sys.argv[1]).read_text())
key = sys.argv[2]
assert document['valid'] is False
assert any(item['key'] == key and item['code'] == 'invalid_value'
           for item in document['diagnostics'])
PY
done
pass 'nonnumeric integer fields return structured diagnostics'

pass 'configuration CLI contract'
